import Foundation
import JavaScriptCore

@objc private protocol RopeInputExport: JSExport {
    var length: Int { get }
    func read(_ from: Int, _ to: Int) -> String
    func chunk(_ position: Int) -> String
    func lineAt(_ position: Int) -> Int
    func lineStart(_ line: Int) -> Int
}
private final class RopeInput: NSObject, RopeInputExport {
    let rope: TextRope
    init(_ rope: TextRope) { self.rope = rope }
    var length: Int { rope.count }
    func lineAt(_ position: Int) -> Int { rope.line(at: position) }
    func lineStart(_ line: Int) -> Int { line >= rope.lineCount ? rope.count : rope.lineStart(line) }
    func read(_ from: Int, _ to: Int) -> String {
        let start = min(max(0, from), length), end = min(max(start, to), length)
        return rope.string(in: NSRange(location: start, length: end - start))
    }
    func chunk(_ position: Int) -> String {
        let end = min(length, rope.lineStart(rope.line(at: position) + 1))
        if end > position, rope.units(in:NSRange(location:end-1,length:1)).first == 10 {
            return read(position, position == end-1 ? end : end-1)
        }
        return read(position, end > position ? end : length)
    }
}

/// JSContext and trees are confined to this serial queue. Only requested viewport records cross the bridge.
public final class LezerWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.astramarkdown.syntax", qos: .userInitiated)
    private var context: JSContext?
    private var lastRevision = -1
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
        queue.async { [self] in context = nil; lastRevision = -1 }
    }
    public func request(rope: TextRope, revision: Int, visible: NSRange, edit: SourceEdit? = nil,
                        renderHTML:Bool = true,
                        completion: @escaping (Result<ParseResult, Error>) -> Void) {
        let waiting=TimingDiagnostics.shared.begin("parse.queue.wait")
        lock.lock(); generation += 1; let requestedGeneration = generation; latestRevision = max(latestRevision,revision)
        if let edit { pendingEdits.append((revision,edit)) }; lock.unlock()
        queue.async { [self] in
            TimingDiagnostics.shared.end(waiting)
            lock.lock(); let current = generation == requestedGeneration
            let edits = current ? pendingEdits.filter{$0.revision<=revision}.map{$0.edit} : []
            if current { pendingEdits.removeAll{$0.revision<=revision} }; lock.unlock()
            guard current else { return }
            let work=TimingDiagnostics.shared.begin("parse.viewport.work")
            defer {TimingDiagnostics.shared.end(work,values:["revision":Double(revision),"documentCharacters":Double(rope.count),"viewportCharacters":Double(visible.length),"renderHTML":renderHTML ? 1:0])}
            do {
                if context == nil {
                    let c = JSContext()!
                    guard let url = Bundle.module.url(forResource: "lezer", withExtension: "js") else { throw WorkerError.message("Missing bundled Lezer parser") }
                    c.evaluateScript(try String(contentsOf: url, encoding: .utf8)); context = c
                }
                let c = context!; c.exception = nil
                let isCurrent: @convention(block) () -> Bool = { [weak self] in
                    guard let self else { return false }; self.lock.lock(); defer { self.lock.unlock() }; return self.latestRevision == revision
                }
                c.setObject(isCurrent,forKeyedSubscript:"nativeIsCurrent" as NSString)
                let input = RopeInput(rope)
                let changes = edits.map { ["from": $0.range.location, "to": NSMaxRange($0.range), "inserted": $0.insertedLength] }
                let javascript=TimingDiagnostics.shared.begin("parse.javascript")
                let json = c.objectForKeyedSubscript("astraParse")!.call(withArguments: [input, revision, visible.location, NSMaxRange(visible), changes, lastRevision,true,renderHTML])
                TimingDiagnostics.shared.end(javascript)
                if let exception = c.exception { throw WorkerError.message(exception.toString() ?? "Parser exception") }
                guard let string = json?.toString(), let data = string.data(using: .utf8) else { throw WorkerError.message("Invalid parser response") }
                let result = try JSONDecoder().decode(ParseResult.self, from: data)
                lastRevision = revision
                lock.lock(); let isLatest = generation == requestedGeneration; lock.unlock()
                if isLatest {
                    let delivery=TimingDiagnostics.shared.begin("parse.callback.wait")
                    DispatchQueue.main.async {TimingDiagnostics.shared.end(delivery);completion(.success(result))}
                }
            } catch {
                context = nil; lastRevision = -1
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
    public func prepare(rope:TextRope,revision:Int,from:Int,completion:@escaping(Result<(ParseResult,NSRange),Error>)->Void) {
        let waiting=TimingDiagnostics.shared.begin("html.background.queue.wait")
        queue.async { [self] in
            TimingDiagnostics.shared.end(waiting)
            lock.lock();let current=latestRevision==revision;lock.unlock()
            guard current,let c=context,lastRevision==revision else {return}
            let work=TimingDiagnostics.shared.begin("html.background.work")
            defer {TimingDiagnostics.shared.end(work,values:["revision":Double(revision),"sourceFrom":Double(from),"documentCharacters":Double(rope.count)])}
            do {
                let line=rope.line(at:from),range=rope.lines(line,min(rope.lineCount,line+100))
                c.exception=nil
                let value=c.objectForKeyedSubscript("astraParse")!.call(withArguments:[RopeInput(rope),revision,range.location,NSMaxRange(range),[],revision,false])
                if let error=c.exception {throw WorkerError.message(error.toString())}
                guard let string=value?.toString(),let data=string.data(using:.utf8) else {throw WorkerError.message("Invalid prepared HTML")}
                let result=try JSONDecoder().decode(ParseResult.self,from:data)
                DispatchQueue.main.async {completion(.success((result,range)))}
            } catch {DispatchQueue.main.async {completion(.failure(error))}}
        }
    }
}
