import Foundation
import JavaScriptCore
import CComrak

/// The native parser prepares the complete revision in one run. The first
/// publication carries the lightweight block manifest plus records for the
/// requested viewport; later viewport requests query the same prepared AST.
public final class ComrakWorker: @unchecked Sendable {
    private let queue=DispatchQueue(label:"org.astramarkdown.comrak",qos:.userInitiated)
    private let lock=NSLock()
    private var generation=0,documentEpoch=0,latestRevision = -1
    private var pendingEdits=[(revision:Int,edit:SourceEdit)]()
    private var document:OpaquePointer?
    private var preparedRevision = -1,publishedRevision = -1
    private var manifestBlocks:[PreparedBlock]?
    private var identity=UUID().uuidString
    private let math=MathEngine()

    public init() {}
    deinit {if let document {astra_comrak_document_free(document)}}
    public func record(_ edit:SourceEdit,revision:Int) {
        lock.lock();pendingEdits.append((revision,edit));latestRevision=max(latestRevision,revision);lock.unlock()
    }
    public func reset() {
        lock.lock();generation += 1;documentEpoch += 1;let epoch=documentEpoch
        latestRevision = -1;pendingEdits.removeAll();lock.unlock()
        queue.async { [self] in
            lock.lock();let current=documentEpoch==epoch;lock.unlock()
            guard current else{return}
            if let document {astra_comrak_document_free(document)}
            document=nil;preparedRevision = -1;publishedRevision = -1;manifestBlocks=nil;identity=UUID().uuidString
        }
    }
    /// Starts the one complete parse as soon as NSDocument has decoded the
    /// file. Rope construction can proceed concurrently on the caller. Later
    /// viewport requests are serialized behind this job and reuse its AST.
    public func prepareInitial(_ units:[UInt16],revision:Int) {
        lock.lock();generation += 1;documentEpoch += 1
        let epoch=documentEpoch;latestRevision=revision;pendingEdits.removeAll();lock.unlock()
        queue.async { [self] in
            #if DEBUG
            let work=TimingDiagnostics.shared.begin("parse.initial")
            defer {TimingDiagnostics.shared.end(work,values:["documentCharacters":Double(units.count)])}
            #endif
            let prepared=units.withUnsafeBufferPointer {source in
                astra_comrak_parse(source.baseAddress,source.count,nil,nil,0,
                    renderMath,Unmanaged.passUnretained(math).toOpaque())
            }
            lock.lock();let current=documentEpoch==epoch && latestRevision==revision;lock.unlock()
            guard current else {if let prepared {astra_comrak_document_free(prepared)};return}
            guard let prepared else {return}
            if let document {astra_comrak_document_free(document)}
            document=prepared;preparedRevision=revision;publishedRevision = -1
            manifestBlocks=nil;identity=UUID().uuidString
        }
    }
    public func request(rope:TextRope,revision:Int,visible:NSRange,edit:SourceEdit? = nil,
                        renderHTML:Bool = true,includeFragments:Bool = true,
                        completion:@escaping(Result<ParseResult,Error>)->Void) {
        #if DEBUG
        let waiting=TimingDiagnostics.shared.begin("parse.queue.wait")
        #endif
        lock.lock();generation += 1;let requestedGeneration=generation;latestRevision=max(latestRevision,revision)
        if let edit {pendingEdits.append((revision,edit))};lock.unlock()
        queue.async { [self] in
            #if DEBUG
            TimingDiagnostics.shared.end(waiting)
            #endif
            lock.lock();let current=generation==requestedGeneration
            let changes=current ? pendingEdits.filter{$0.revision<=revision}.map{$0.edit}:[]
            if current {pendingEdits.removeAll{$0.revision<=revision}};lock.unlock()
            guard current else{return}
            #if DEBUG
            let work=TimingDiagnostics.shared.begin("parse.viewport.work")
            defer {TimingDiagnostics.shared.end(work,values:["revision":Double(revision),"documentCharacters":Double(rope.count),"viewportCharacters":Double(visible.length),"renderHTML":renderHTML ? 1:0])}
            #endif
            do {
                if preparedRevision != revision {
                    #if DEBUG
                    let input=TimingDiagnostics.shared.begin("parse.input")
                    #endif
                    let edits=changes.map{AstraComrakEdit(from:$0.range.location,to:NSMaxRange($0.range),inserted:$0.insertedLength)}
                    #if DEBUG
                    TimingDiagnostics.shared.end(input)
                    let native=TimingDiagnostics.shared.begin("parse.comrak")
                    #endif
                    let prepared=rope.withContiguousUTF16 {source in
                        edits.withUnsafeBufferPointer {edits in
                            astra_comrak_parse(source.baseAddress,source.count,document,edits.baseAddress,edits.count,
                                renderMath,Unmanaged.passUnretained(math).toOpaque())
                        }
                    }
                    #if DEBUG
                    TimingDiagnostics.shared.end(native)
                    #endif
                    guard let prepared else {throw WorkerError.message(nativeError())}
                    if let document {astra_comrak_document_free(document)}
                    document=prepared;preparedRevision=revision
                }
                // The first publication fills the existing retained document
                // structures exactly as the Lezer implementation did. Later
                // edits publish only their manifest delta and visible records.
                let manifest:UInt8 = renderHTML && includeFragments
                    ? (publishedRevision < 0 ? 1 : publishedRevision != revision ? 2 : 0) : 0
                // The complete lightweight manifest seeds the retained block
                // tree, but syntax and HTML records stay bounded to the
                // requested viewport. Background queries fill the same nodes.
                let queryRange=visible
                guard let document,let json=astra_comrak_query(document,Int64(revision),queryRange.location,NSMaxRange(queryRange),manifest,renderHTML,includeFragments) else {
                    throw WorkerError.message(nativeError())
                }
                defer {astra_comrak_string_free(json)}
                #if DEBUG
                let records=TimingDiagnostics.shared.begin("parse.records")
                #endif
                let data=Data(bytes:json,count:strlen(json))
                let decoded=try JSONDecoder().decode(ParseResult.self,from:data)
                func block(_ value:PreparedBlock)->PreparedBlock {
                    PreparedBlock(id:identity+":"+value.id,kind:value.kind,from:value.from,to:value.to)
                }
                let full=decoded.blocks?.map(block)
                let change=decoded.blockChange.map{PreparedBlockChange(prefix:$0.prefix,suffix:$0.suffix,shift:$0.shift,blocks:$0.blocks.map(block))}
                if let full {manifestBlocks=full}
                let result=ParseResult(revision:decoded.revision,spans:decoded.spans,
                    fragments:decoded.fragments.map{PreviewFragment(kind:$0.kind,from:$0.from,to:$0.to,markdown:$0.markdown,html:$0.html,id:$0.id.map{identity+":"+$0})},
                    blocks:full != nil ? manifestBlocks:nil,blockChange:change,complete:false)
                #if DEBUG
                TimingDiagnostics.shared.end(records)
                #endif
                lock.lock();let latest=generation==requestedGeneration;lock.unlock()
                if latest {
                    #if DEBUG
                    let delivery=TimingDiagnostics.shared.begin("parse.callback.wait")
                    #endif
                    DispatchQueue.main.async { [self] in
                        lock.lock();let latest=generation==requestedGeneration;lock.unlock()
                        guard latest else{return}
                        #if DEBUG
                        TimingDiagnostics.shared.end(delivery)
                        #endif
                        completion(.success(result))
                        if manifest != 0 {queue.async { [self] in if preparedRevision==revision {publishedRevision=revision}}}
                    }
                }
            } catch {
                lock.lock();let latest=generation==requestedGeneration;lock.unlock()
                if latest {DispatchQueue.main.async {completion(.failure(error))}}
            }
        }
    }
    /// Query already prepared Comrak output. Background and jump requests do
    /// not parse or render Markdown again.
    public func prepare(rope:TextRope,revision:Int,from:Int,includeFragments:Bool = true,
                        completion:@escaping(Result<(ParseResult,NSRange),Error>)->Void) {
        queue.async { [self] in
            lock.lock();let current=latestRevision==revision;lock.unlock()
            guard current,preparedRevision==revision,let document else{return}
            let line=rope.line(at:from),range=rope.lines(line,min(rope.lineCount,line+100))
            guard let json=astra_comrak_query(document,Int64(revision),range.location,NSMaxRange(range),0,true,includeFragments) else {
                let message=nativeError();DispatchQueue.main.async {completion(.failure(WorkerError.message(message)))};return
            }
            defer {astra_comrak_string_free(json)}
            do {
                let data=Data(bytes:json,count:strlen(json))
                let decoded=try JSONDecoder().decode(ParseResult.self,from:data)
                let fragments=decoded.fragments.map {fragment in
                    PreviewFragment(kind:fragment.kind,from:fragment.from,to:fragment.to,markdown:fragment.markdown,
                        html:fragment.html,id:fragment.id.map{identity+":"+$0})
                }
                let result=ParseResult(revision:decoded.revision,spans:decoded.spans,fragments:fragments,complete:false)
                DispatchQueue.main.async {completion(.success((result,range)))}
            } catch {DispatchQueue.main.async {completion(.failure(error))}}
        }
    }
    private func nativeError()->String {
        guard let text=astra_comrak_error() else{return "Comrak failed"}
        defer {astra_comrak_string_free(text)}
        return String(cString:text)
    }
    public enum WorkerError:Error,LocalizedError {
        case message(String)
        public var errorDescription:String? {if case .message(let text)=self{return text};return nil}
    }
}

/// KaTeX is a typesetter only. It receives parser-recognized equations, never
/// source Markdown, and does not build a second document syntax tree.
private final class MathEngine {
    private struct Key:Hashable {let tex:String;let display:Bool}
    private var context:JSContext?
    private var cache=[Key:String]()
    func render(_ tex:String,display:Bool)->String? {
        let key=Key(tex:tex,display:display)
        if let cached=cache[key] {return cached}
        if context==nil {
            guard let url=Bundle.module.url(forResource:"katex",withExtension:"js"),let script=try? String(contentsOf:url,encoding:.utf8),let c=JSContext() else{return nil}
            c.evaluateScript(script);guard c.exception==nil else{return nil};context=c
        }
        let c=context!;c.exception=nil
        guard let html=c.objectForKeyedSubscript("astraMath")?.call(withArguments:[tex,display])?.toString(),c.exception==nil else{return nil}
        if cache.count>=4096 {cache.removeAll(keepingCapacity:true)}
        cache[key]=html;return html
    }
}
private let renderMath:AstraMathRenderer = {opaque,bytes,length,display in
    guard let opaque,let bytes else{return nil}
    let engine=Unmanaged<MathEngine>.fromOpaque(opaque).takeUnretainedValue()
    let tex=String(decoding:UnsafeBufferPointer(start:bytes,count:length),as:UTF8.self)
    #if DEBUG
    let timing=TimingDiagnostics.shared.begin("math.katex")
    defer {TimingDiagnostics.shared.end(timing)}
    #endif
    guard let html=engine.render(tex,display:display) else{return nil}
    return html.withCString{strdup($0)}
}
