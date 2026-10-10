import Foundation
import JavaScriptCore

/// The context, immutable revision input and tree stay on this serial queue.
/// Source crosses into JavaScript once per revision; only requested records return.
public final class LezerWorker: @unchecked Sendable {
    private struct BlockChange:Decodable {
        let prefix:Int,suffix:Int,shift:Int
        let blocks:[PreparedBlock]
    }
    private struct Response:Decodable {
        let revision:Int
        let spans:[SyntaxSpan]
        let fragments:[PreviewFragment]
        let blocks:[PreparedBlock]?
        let blockChange:BlockChange?
    }
    private let queue = DispatchQueue(label: "org.astramarkdown.syntax", qos: .userInitiated)
    private var context: JSContext?
    private var input:JSValue?
    private var inputRevision = -1
    private var lastRevision = -1
    private var preparedBlocks:[PreparedBlock]?
    private var preparedBlocksRevision = -1
    private var pendingEdits = [(revision:Int,edit:SourceEdit)]()
    private let lock = NSLock()
    private var generation = 0
    private var latestRevision = -1
    public init() {}
    public func record(_ edit:SourceEdit,revision:Int) {
        lock.lock(); pendingEdits.append((revision,edit)); latestRevision = max(latestRevision,revision); lock.unlock()
    }
    public func reset() {
        lock.lock(); generation += 1; latestRevision = -1; pendingEdits.removeAll(); lock.unlock()
        queue.async { [self] in context = nil; input=nil; inputRevision = -1; lastRevision = -1;preparedBlocks=nil;preparedBlocksRevision = -1 }
    }
    public func request(rope: TextRope, revision: Int, visible: NSRange, edit: SourceEdit? = nil,
                        renderHTML:Bool = true, includeFragments:Bool = true,
                        completion: @escaping (Result<ParseResult, Error>) -> Void) {
        #if DEBUG
        let waiting=TimingDiagnostics.shared.begin("parse.queue.wait")
        #endif
        lock.lock(); generation += 1; let requestedGeneration = generation; latestRevision = max(latestRevision,revision)
        if let edit { pendingEdits.append((revision,edit)) }; lock.unlock()
        queue.async { [self] in
            #if DEBUG
            TimingDiagnostics.shared.end(waiting)
            #endif
            lock.lock(); let current = generation == requestedGeneration
            let edits = current ? pendingEdits.filter{$0.revision<=revision}.map{$0.edit} : []
            if current { pendingEdits.removeAll{$0.revision<=revision} }; lock.unlock()
            guard current else { return }
            #if DEBUG
            let work=TimingDiagnostics.shared.begin("parse.viewport.work")
            defer {TimingDiagnostics.shared.end(work,values:["revision":Double(revision),"documentCharacters":Double(rope.count),"viewportCharacters":Double(visible.length),"renderHTML":renderHTML ? 1:0])}
            #endif
            do {
                if context == nil {
                    let c = JSContext()!
                    c.setObject(UUID().uuidString,forKeyedSubscript:"nativeDocumentIdentity" as NSString)
                    guard let url = Bundle.module.url(forResource: "lezer", withExtension: "js") else { throw WorkerError.message("Missing bundled Lezer parser") }
                    c.evaluateScript(try String(contentsOf: url, encoding: .utf8)); context = c
                }
                let c = context!; c.exception = nil
                let isCurrent: @convention(block) () -> Bool = { [weak self] in
                    guard let self else { return false }; self.lock.lock(); defer { self.lock.unlock() }; return self.latestRevision == revision
                }
                c.setObject(isCurrent,forKeyedSubscript:"nativeIsCurrent" as NSString)
                if inputRevision != revision || input == nil {
                    let units=rope.units(in:NSRange(location:0,length:rope.count))
                    let string=units.withUnsafeBufferPointer {JSStringCreateWithCharacters($0.baseAddress,$0.count)!}
                    let value=JSValue(jsValueRef:JSValueMakeString(c.jsGlobalContextRef,string),in:c)!
                    input=c.objectForKeyedSubscript("astraInput")!.call(withArguments:[value])
                    JSStringRelease(string);inputRevision=revision
                }
                let changes = edits.map { ["from": $0.range.location, "to": NSMaxRange($0.range), "inserted": $0.insertedLength] }
                #if DEBUG
                let javascript=TimingDiagnostics.shared.begin("parse.javascript")
                #endif
                let manifest:Any=preparedBlocksRevision==revision ? false:preparedBlocks==nil ? true:"delta"
                let json = c.objectForKeyedSubscript("astraParse")!.call(withArguments: [input!, revision, visible.location, NSMaxRange(visible), changes, lastRevision,true,renderHTML,includeFragments,manifest])
                #if DEBUG
                TimingDiagnostics.shared.end(javascript)
                #endif
                if let exception = c.exception { throw WorkerError.message(exception.toString() ?? "Parser exception") }
                guard let string = json?.toString(), let data = string.data(using: .utf8) else { throw WorkerError.message("Invalid parser response") }
                let decoded = try JSONDecoder().decode(Response.self, from: data)
                if let blocks=decoded.blocks {preparedBlocks=blocks;preparedBlocksRevision=revision}
                if let change=decoded.blockChange,let previous=preparedBlocks {
                    guard change.prefix>=0,change.suffix>=0,change.prefix+change.suffix<=previous.count else {throw WorkerError.message("Invalid prepared block change")}
                    var next=Array(previous.prefix(change.prefix))
                    next.reserveCapacity(change.prefix+change.blocks.count+change.suffix)
                    next.append(contentsOf:change.blocks)
                    next.append(contentsOf:previous.suffix(change.suffix).map {PreparedBlock(id:$0.id,kind:$0.kind,from:$0.from+change.shift,to:$0.to+change.shift)})
                    preparedBlocks=next;preparedBlocksRevision=revision
                }
                let result=ParseResult(revision:decoded.revision,spans:decoded.spans,fragments:decoded.fragments,blocks:preparedBlocks)
                lastRevision = revision
                lock.lock(); let isLatest = generation == requestedGeneration; lock.unlock()
                if isLatest {
                    #if DEBUG
                    let delivery=TimingDiagnostics.shared.begin("parse.callback.wait")
                    #endif
                    DispatchQueue.main.async {
                        #if DEBUG
                        TimingDiagnostics.shared.end(delivery)
                        #endif
                        completion(.success(result))
                    }
                }
            } catch {
                context = nil; input=nil; inputRevision = -1; lastRevision = -1;preparedBlocks=nil;preparedBlocksRevision = -1
                lock.lock(); let isLatest = generation == requestedGeneration; lock.unlock()
                if isLatest { DispatchQueue.main.async { completion(.failure(error)) } }
            }
        }
    }
    public enum WorkerError: Error, LocalizedError { case message(String)
        public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
    }
    /// One background batch at a time allows newly enqueued viewport requests to go first.
    /// The full tree is already prepared; only bounded records/HTML cross to the main thread.
    public func prepare(rope:TextRope,revision:Int,from:Int,includeFragments:Bool = true,completion:@escaping(Result<(ParseResult,NSRange),Error>)->Void) {
        #if DEBUG
        let waiting=TimingDiagnostics.shared.begin("html.background.queue.wait")
        #endif
        queue.async { [self] in
            #if DEBUG
            TimingDiagnostics.shared.end(waiting)
            #endif
            lock.lock();let current=latestRevision==revision;lock.unlock()
            guard current,let c=context,let input,inputRevision==revision,lastRevision==revision else {return}
            #if DEBUG
            let work=TimingDiagnostics.shared.begin("html.background.work")
            defer {TimingDiagnostics.shared.end(work,values:["revision":Double(revision),"sourceFrom":Double(from),"documentCharacters":Double(rope.count)])}
            #endif
            do {
                let line=rope.line(at:from),range=rope.lines(line,min(rope.lineCount,line+100))
                c.exception=nil
                let value=c.objectForKeyedSubscript("astraParse")!.call(withArguments:[input,revision,range.location,NSMaxRange(range),[],revision,true,true,includeFragments,false])
                if let error=c.exception {throw WorkerError.message(error.toString())}
                guard let string=value?.toString(),let data=string.data(using:.utf8) else {throw WorkerError.message("Invalid prepared HTML")}
                let result=try JSONDecoder().decode(ParseResult.self,from:data)
                DispatchQueue.main.async {completion(.success((result,range)))}
            } catch {DispatchQueue.main.async {completion(.failure(error))}}
        }
    }
}
