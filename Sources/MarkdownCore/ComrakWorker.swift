import Foundation
import JavaScriptCore
import CComrak

/// Swift owns retained document state. Each native call parses one source
/// slice and returns immutable output buffers whose lifetime is owned by Swift.
/// Rust retains no parser or document state between calls.
public final class ComrakWorker: @unchecked Sendable {
    private let queue=DispatchQueue(label:"org.astramarkdown.comrak",qos:.userInitiated)
    private let lock=NSLock()
    private var generation=0,documentEpoch=0,latestRevision = -1
    private var pendingEdits=[(revision:Int,edit:SourceEdit)]()
    private var initial:(revision:Int,result:ParseResult)?
    private var nextBlockID:UInt64=1
    private let math=MathEngine()
    #if DEBUG
    private var debugFailuresRemaining=0
    public func debugFailNextRequests(_ count:Int = 1) {
        lock.lock();debugFailuresRemaining=max(0,count);lock.unlock()
    }
    public func debugFailNextMathRender() {math.debugFailNextRender()}
    #endif

    public init() {}
    public func record(_ edit:SourceEdit,revision:Int) {
        lock.lock();pendingEdits.append((revision,edit));latestRevision=max(latestRevision,revision);lock.unlock()
    }
    public func reset() {
        lock.lock();generation += 1;documentEpoch += 1;let epoch=documentEpoch
        latestRevision = -1;pendingEdits.removeAll();lock.unlock()
        queue.async { [self] in lock.lock();if documentEpoch==epoch {initial=nil};lock.unlock() }
    }
    /// Starts the one complete parse as soon as NSDocument has decoded the
    /// file. Rope construction can proceed concurrently on the caller. Swift
    /// retains the resulting records for the initial viewport request.
    public func prepareInitial(_ units:[UInt16],revision:Int) {
        lock.lock();generation += 1;documentEpoch += 1
        let epoch=documentEpoch;latestRevision=revision;pendingEdits.removeAll();lock.unlock()
        queue.async { [self] in
            #if DEBUG
            let work=TimingDiagnostics.shared.begin("parse.initial")
            defer {TimingDiagnostics.shared.end(work,values:["documentCharacters":Double(units.count)])}
            #endif
            let prepared=try? parse(units:units,base:0,revision:revision)
            lock.lock();let current=documentEpoch==epoch && latestRevision==revision;lock.unlock()
            guard current else{return}
            guard let prepared else {return}
            lock.lock();if documentEpoch==epoch && latestRevision==revision {initial=(revision,prepared)};lock.unlock()
        }
    }
    public func request(rope:TextRope,revision:Int,visible:NSRange,
                        renderHTML:Bool = true,includeFragments:Bool = true,
                        regionalContext:RegionalParseContext? = nil,
                        completion:@escaping(Result<ParseResult,Error>)->Void) {
        #if DEBUG
        let waiting=TimingDiagnostics.shared.begin("parse.queue.wait")
        #endif
        lock.lock();generation += 1;let requestedGeneration=generation;latestRevision=max(latestRevision,revision);lock.unlock()
        queue.async { [self] in
            #if DEBUG
            TimingDiagnostics.shared.end(waiting)
            #endif
            lock.lock();let current=generation==requestedGeneration
            let changes=current ? pendingEdits.filter{$0.revision<=revision}.map{$0.edit}:[]
            #if DEBUG
            let injectedFailure=current && debugFailuresRemaining>0
            if injectedFailure {debugFailuresRemaining -= 1}
            #endif
            lock.unlock()
            guard current else{return}
            #if DEBUG
            if injectedFailure {
                DispatchQueue.main.async {completion(.failure(WorkerError.message("Injected parser failure")))}
                return
            }
            #endif
            #if DEBUG
            let work=TimingDiagnostics.shared.begin("parse.viewport.work")
            defer {TimingDiagnostics.shared.end(work,values:["revision":Double(revision),"documentCharacters":Double(rope.count),"viewportCharacters":Double(visible.length),"renderHTML":renderHTML ? 1:0])}
            #endif
            do {
                let result:ParseResult
                lock.lock()
                let cached=changes.isEmpty && initial?.revision==revision ? initial?.result:nil
                lock.unlock()
                if let cached {result=cached}
                else if changes.count==1,let context=regionalContext,
                        let regional=try regionalResult(rope:rope,revision:revision,edit:changes[0],context:context) {
                    result=regional
                } else {
                    #if DEBUG
                    let native=TimingDiagnostics.shared.begin("parse.comrak")
                    #endif
                    let units=rope.units(in:NSRange(location:0,length:rope.count))
                    let parsed=try parse(units:units,base:0,revision:revision)
                    #if DEBUG
                    TimingDiagnostics.shared.end(native,values:["regional":0,"parsedCharacters":Double(rope.count)])
                    #endif
                    result=parsed
                }
                lock.lock();pendingEdits.removeAll{$0.revision<=revision};lock.unlock()
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
                    }
                }
            } catch {
                lock.lock();let latest=generation==requestedGeneration;lock.unlock()
                if latest {DispatchQueue.main.async {completion(.failure(error))}}
            }
        }
    }
    /// Complete parses populate Swift's retained tree, so this path is only a
    /// recovery fallback for an uncovered range.
    public func prepare(rope:TextRope,revision:Int,from:Int,includeFragments:Bool = true,
                        completion:@escaping(Result<(ParseResult,NSRange),Error>)->Void) {
        queue.async { [self] in
            lock.lock();let current=latestRevision==revision;lock.unlock()
            guard current else{return}
            let line=rope.line(at:from),range=rope.lines(line,min(rope.lineCount,line+100))
            do {
                let result=try parse(units:rope.units(in:range),base:range.location,revision:revision)
                DispatchQueue.main.async {completion(.success((result,range)))}
            } catch {DispatchQueue.main.async {completion(.failure(error))}}
        }
    }
    private func allocateBlockID()->BlockID {
        defer {nextBlockID &+= 1}
        return BlockID(nextBlockID)
    }
    private func parse(units:[UInt16],base:Int,revision:Int)throws->ParseResult {
        #if DEBUG
        let nativeWork=TimingDiagnostics.shared.begin("parse.native")
        #endif
        let nativeResult=units.withUnsafeBufferPointer({source in
            astra_comrak_parse_records(source.baseAddress,source.count,base,Int64(revision),
                renderMath,Unmanaged.passUnretained(math).toOpaque())
        })
        #if DEBUG
        TimingDiagnostics.shared.end(nativeWork,values:["parsedCharacters":Double(units.count)])
        #endif
        guard let result=nativeResult else {throw WorkerError.message(nativeError())}
        let owner=NativeResultOwner(result)
        #if DEBUG
        let recordsWork=TimingDiagnostics.shared.begin("parse.records")
        defer {TimingDiagnostics.shared.end(recordsWork)}
        #endif
        var view=AstraComrakResultView()
        guard astra_comrak_result_view(result,&view) else {
            throw WorkerError.message("Comrak returned an invalid record view")
        }
        func kind(_ value:UInt8)->MarkdownKind {MarkdownKind(rawValue:value) ?? .paragraph}
        var htmlViews=[HTMLArena.View]();htmlViews.reserveCapacity(view.block_count)
        if view.block_count>0,let records=view.blocks {
            for record in UnsafeBufferPointer(start:records,count:view.block_count) {
                htmlViews.append(.init(bytes:record.html.bytes,count:record.html.length))
            }
        }
        let arena=HTMLArena(owner:owner,views:htmlViews)
        var blocks=[PreparedBlock](),spans=[SyntaxSpan]()
        blocks.reserveCapacity(view.block_count)
        spans.reserveCapacity(view.span_count)
        if view.span_count>0,let records=view.spans {
            for record in UnsafeBufferPointer(start:records,count:view.span_count) {
                spans.append(SyntaxSpan(kind:kind(record.kind),from:record.from,to:record.to))
            }
        }
        let syntaxArena=SyntaxArena(spans)
        if view.block_count>0,let records=view.blocks {
            for (index,record) in UnsafeBufferPointer(start:records,count:view.block_count).enumerated() {
                blocks.append(PreparedBlock(id:allocateBlockID(),kind:kind(record.kind),from:record.from,to:record.to,
                    html:HTMLPayload(arena:arena,index:index),
                    syntax:SyntaxPayload(arena:syntaxArena,range:record.span_start..<(record.span_start+record.span_count))))
            }
        }
        return ParseResult(revision:Int(view.revision),spans:spans,blocks:blocks,
                           from:view.from,to:view.to,hasReferences:view.has_references)
    }
    private func regionalResult(rope:TextRope,revision:Int,edit:SourceEdit,
                                context:RegionalParseContext)throws->ParseResult? {
        #if DEBUG
        let native=TimingDiagnostics.shared.begin("parse.comrak")
        defer {TimingDiagnostics.shared.end(native,values:["regional":1,"parsedCharacters":Double(context.range.length)])}
        #endif
        let parsed=try parse(units:rope.units(in:context.range),base:context.range.location,revision:revision)
        guard parsed.hasReferences != true,let blocks=parsed.blocks else{return nil}
        var used=Set<BlockID>(),mapped=[BlockID:BlockID]()
        func shiftedStart(_ offset:Int)->Int {
            if offset<=edit.range.location {return offset}
            if offset>=NSMaxRange(edit.range) {return offset+context.shift}
            return edit.range.location
        }
        func shiftedEnd(_ offset:Int)->Int {
            if offset<edit.range.location {return offset}
            if offset>=NSMaxRange(edit.range) {return offset+context.shift}
            return edit.range.location+edit.insertedLength
        }
        for block in blocks {
            let html=block.html?.string() ?? ""
            let old=context.blocks.filter{!used.contains($0.id) && $0.kind==block.kind && $0.html==html}.min {
                let left=abs(shiftedStart($0.from)-block.from)+abs(shiftedEnd($0.to)-block.to)
                let right=abs(shiftedStart($1.from)-block.from)+abs(shiftedEnd($1.to)-block.to)
                return left<right
            }
            if let old {
                mapped[block.id]=old.id;used.insert(old.id)
            } else {
                mapped[block.id]=allocateBlockID()
            }
        }
        if let guardID=context.firstGuardID,!used.contains(guardID) {return nil}
        if let guardID=context.lastGuardID,!used.contains(guardID) {return nil}
        let changed=blocks.map{PreparedBlock(id:mapped[$0.id]!,kind:$0.kind,from:$0.from,to:$0.to,html:$0.html,syntax:$0.syntax)}
        return ParseResult(revision:revision,spans:parsed.spans,
            blockChange:PreparedBlockChange(prefix:context.prefix,suffix:context.suffix,shift:context.shift,blocks:changed),
            from:parsed.from,to:parsed.to,hasReferences:false)
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

private final class NativeResultOwner:@unchecked Sendable {
    private let result:OpaquePointer
    init(_ result:OpaquePointer) {self.result=result}
    deinit {astra_comrak_result_free(result)}
}

/// KaTeX is a typesetter only. It receives parser-recognized equations, never
/// source Markdown, and does not build a second document syntax tree.
private final class MathEngine {
    private struct Key:Hashable {let tex:String;let display:Bool}
    private var context:JSContext?
    private var cache=[Key:String]()
    #if DEBUG
    private let debugLock=NSLock()
    private var debugFailurePending=false
    func debugFailNextRender() {debugLock.lock();debugFailurePending=true;debugLock.unlock()}
    #endif
    func render(_ tex:String,display:Bool)->String? {
        #if DEBUG
        debugLock.lock();let fail=debugFailurePending;debugFailurePending=false;debugLock.unlock()
        if fail {return nil}
        #endif
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
    let html=engine.render(tex,display:display) ?? mathErrorHTML(tex,display:display)
    return html.withCString{strdup($0)}
}
private func mathErrorHTML(_ tex:String,display:Bool)->String {
    let escaped=tex.replacingOccurrences(of:"&",with:"&amp;")
        .replacingOccurrences(of:"<",with:"&lt;")
        .replacingOccurrences(of:">",with:"&gt;")
        .replacingOccurrences(of:"\"",with:"&quot;")
    return display
        ? "<pre class=\"math-error\" title=\"Mathematics could not be rendered\"><code>\(escaped)</code></pre>"
        : "<code class=\"math-error\" title=\"Mathematics could not be rendered\">\(escaped)</code>"
}
