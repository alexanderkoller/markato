import AppKit
import CUltralightPreview
import MarkdownCore

public struct HTMLPreviewGeometry: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let id:String
        public let y:CGFloat
        public let height:CGFloat
        public let landmark:CGFloat?
    }
    public let measurement:Int
    public let width:CGFloat
    public let height:CGFloat
    public let items:[Item]
}

#if DEBUG
public struct HTMLPreviewSnapshotConfiguration:Sendable {
    public var rect:NSRect
    public var afterScreenUpdates:Bool
    public init(rect:NSRect,afterScreenUpdates:Bool) {self.rect=rect;self.afterScreenUpdates=afterScreenUpdates}
}
#endif

/// The complete HTML-engine boundary for AstraMarkdown. The rest of the app
/// supplies retained semantic entries and consumes geometry plus pixels; it
/// does not know about Ultralight DOM, resources, input, or bitmap formats.
@MainActor public final class HTMLPreviewView:NSView {
    public var verticalWheel:((NSEvent)->Void)?
    public var openURL:((URL)->Void)?
    public private(set) var isEngineReady=false
    private var engine:OpaquePointer?
    private var image:CGImage?
    private var imageSize:NSSize = .zero
    private var entries=[RenderedEntry]()
    private var fontSize:CGFloat=14
    private var baseURL:URL?
    private var embeddedAssets=[URL:String]()
    private var horizontalGesture:Bool?
    private var axisReset:DispatchWorkItem?
    private var resourcePump:Timer?
    private var resourcePumpTicks=0
    private var pendingFlush:DispatchWorkItem?
    private var engineDirty=false
    private var pixelSize=(width:UInt32(0),height:UInt32(0),scale:CGFloat(0))
    private var scrollPoint:NSPoint?
    private var pixelData=Data()
    #if DEBUG
    public private(set) var debugPaintedBitmapTop:CGFloat?
    #endif

    public override var isFlipped:Bool {true}
    public override var acceptsFirstResponder:Bool {true}

    public convenience override init(frame:NSRect) {
        func resource(_ name:String)->String {
            guard let url=Bundle.module.url(forResource:name,withExtension:"css"),
                  let text=try? String(contentsOf:url,encoding:.utf8) else {
                preconditionFailure("Missing HTMLPreview resource: \(name).css")
            }
            return text
        }
        self.init(frame:frame,css:resource("KaTeX")+resource("Preview"))
    }

    init(frame:NSRect,css:String) {
        super.init(frame:frame)
        wantsLayer=true
        setAccessibilityLabel("Markdown preview")
        let root=Self.sdkRoot.path
        let scale=max(1,window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
        root.withCString {root in css.withCString {style in
            engine=astra_ul_surface_create(root,style,1,1,scale)
        }}
        isEngineReady=engine != nil
    }
    required init?(coder:NSCoder) {fatalError()}
    deinit {resourcePump?.invalidate();pendingFlush?.cancel();if let engine {astra_ul_surface_destroy(engine)}}

    private static var sdkRoot:URL {
        if let value=ProcessInfo.processInfo.environment["ASTRA_ULTRALIGHT_SDK"] {return URL(fileURLWithPath:value)}
        if let resources=Bundle.main.resourceURL?.appendingPathComponent("Ultralight"),
           FileManager.default.fileExists(atPath:resources.appendingPathComponent("resources/icudt67l.dat").path) {return resources}
        return URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            .appendingPathComponent("research/2026-10-11/html-renderer-benchmark/third_party/ultralight")
    }

    public func present(_ next:[RenderedEntry],fontSize:CGFloat,baseURL:URL?=nil)->HTMLPreviewGeometry? {
        guard let engine else{return nil}
        entries=next;self.fontSize=fontSize;self.baseURL=baseURL
        astra_ul_surface_begin_update(engine,next.count,fontSize)
        for entry in next {
            guard let html=entry.fragment.html else{return nil}
            let resolved=resolveAssets(in:html,baseURL:baseURL)
            entry.id.withCString {id in resolved.withCString {body in
                astra_ul_surface_add_entry(engine,id,body)
            }}
        }
        guard astra_ul_surface_commit_update(engine) else{return nil}
        didRender()
        refreshImage()
        if next.contains(where:{$0.fragment.html?.contains("<img") == true}) {beginResourcePump()}
        return geometry()
    }

    public func patch(_ replacements:[(index:Int,entry:RenderedEntry)])->HTMLPreviewGeometry? {
        guard let engine else{return nil}
        for replacement in replacements {
            guard replacement.index>=0,replacement.index<entries.count,
                  let html=replacement.entry.fragment.html else{return nil}
            let resolved=resolveAssets(in:html,baseURL:baseURL)
            let success=replacement.entry.id.withCString {id in resolved.withCString {body in
                astra_ul_surface_patch_entry(engine,replacement.index,id,body)
            }}
            guard success else{return nil}
            entries[replacement.index]=replacement.entry
        }
        didRender()
        refreshImage()
        return geometry()
    }

    public func geometry()->HTMLPreviewGeometry? {
        guard let engine else{return nil}
        var value=AstraULGeometry()
        guard astra_ul_surface_geometry(engine,&value),value.item_count==entries.count else{return nil}
        var items=[HTMLPreviewGeometry.Item]();items.reserveCapacity(entries.count)
        for index in entries.indices {
            var item=AstraULGeometryItem()
            guard astra_ul_surface_geometry_item(engine,index,&item) else{return nil}
            items.append(.init(id:entries[index].id,y:item.y,height:item.height,
                landmark:item.has_landmark ? item.landmark_y:nil))
        }
        return HTMLPreviewGeometry(measurement:Int(value.measurement),width:value.width,
            height:value.height,items:items)
    }

    private func resolveAssets(in html:String,baseURL:URL?)->String {
        let pattern=#"astra-asset://[^\"']+"#
        guard let expression=try? NSRegularExpression(pattern:pattern) else{return html}
        let ns=html as NSString
        var result=html
        for match in expression.matches(in:html,range:NSRange(location:0,length:ns.length)).reversed() {
            let token=ns.substring(with:match.range).replacingOccurrences(of:"&amp;",with:"&")
            guard let components=URLComponents(string:token),
                  let source=components.queryItems?.first(where:{$0.name=="source"})?.value,
                  let url=URL(string:source,relativeTo:baseURL)?.absoluteURL else{continue}
            let replacement:String
            if url.isFileURL {
                if let cached=embeddedAssets[url] {replacement=cached}
                else if let data=try? Data(contentsOf:url,options:.mappedIfSafe) {
                    let mime:[String:String]=["png":"image/png","jpg":"image/jpeg","jpeg":"image/jpeg",
                        "gif":"image/gif","webp":"image/webp","svg":"image/svg+xml"]
                    replacement="data:\(mime[url.pathExtension.lowercased()] ?? "application/octet-stream");base64,\(data.base64EncodedString())"
                    embeddedAssets[url]=replacement
                } else {continue}
            } else {replacement=url.absoluteString}
            if let range=Range(match.range,in:result) {result.replaceSubrange(range,with:replacement)}
        }
        return result
    }

    public func scroll(to point:NSPoint) {
        guard let engine else{return}
        if let previous=scrollPoint,abs(previous.x-point.x)<0.01,abs(previous.y-point.y)<0.01 {return}
        scrollPoint=point;astra_ul_surface_scroll(engine,point.x,point.y)
        engineDirty=true;scheduleFlush()
    }

    public override func setFrameSize(_ newSize:NSSize) {
        super.setFrameSize(newSize)
        resizeEngine()
    }
    public override func viewDidMoveToWindow() {super.viewDidMoveToWindow();resizeEngine()}
    public override func viewDidChangeBackingProperties() {super.viewDidChangeBackingProperties();resizeEngine()}
    private func resizeEngine() {
        guard let engine,bounds.width>0,bounds.height>0 else{return}
        let scale=max(1,window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
        let width=UInt32(ceil(bounds.width*scale)),height=UInt32(ceil(bounds.height*scale))
        guard width != pixelSize.width || height != pixelSize.height || scale != pixelSize.scale else{return}
        pixelSize=(width,height,scale);astra_ul_surface_resize(engine,width,height,scale)
        engineDirty=true;scheduleFlush()
    }

    private func scheduleFlush() {
        guard pendingFlush==nil else{return}
        let work=DispatchWorkItem { [weak self] in self?.flush() }
        pendingFlush=work
        // AppKit stretches the last frame immediately. Reflow at most once per
        // display interval while live resize events continue to arrive.
        DispatchQueue.main.asyncAfter(deadline:.now()+1/60,execute:work)
    }

    public func flush() {
        pendingFlush?.cancel();pendingFlush=nil
        guard engineDirty,let engine else{return}
        #if DEBUG
        let work=TimingDiagnostics.shared.begin("html.flush")
        defer {TimingDiagnostics.shared.end(work,values:["width":Double(bounds.width),"height":Double(bounds.height)])}
        #endif
        engineDirty=false
        if astra_ul_surface_render(engine) {refreshImage()}
    }

    private func didRender() {
        pendingFlush?.cancel();pendingFlush=nil;engineDirty=false
    }

    private func refreshImage() {
        guard let engine else{return}
        #if DEBUG
        let work=TimingDiagnostics.shared.begin("html.bitmap.copy")
        defer {TimingDiagnostics.shared.end(work)}
        #endif
        let count=astra_ul_surface_pixel_bytes(engine)
        guard count>0 else{return}
        image=nil
        if pixelData.count != count {pixelData=Data(count:count)}
        var width:UInt32=0,height:UInt32=0,stride:UInt32=0
        let copied=pixelData.withUnsafeMutableBytes {bytes in
            astra_ul_surface_copy_pixels(engine,bytes.baseAddress,count,&width,&height,&stride)
        }
        guard copied,let provider=CGDataProvider(data:pixelData as CFData) else{return}
        let scale=max(1,pixelSize.scale)
        imageSize=NSSize(width:CGFloat(width)/scale,height:CGFloat(height)/scale)
        let info=CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)
        image=CGImage(width:Int(width),height:Int(height),bitsPerComponent:8,bitsPerPixel:32,
            bytesPerRow:Int(stride),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:info,
            provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)
        needsDisplay=true
    }

    private func beginResourcePump() {
        resourcePump?.invalidate();resourcePumpTicks=0
        resourcePump=Timer.scheduledTimer(withTimeInterval:1/60,repeats:true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self,let engine=self.engine else{timer.invalidate();return}
                if astra_ul_surface_pump(engine) {self.refreshImage()}
                self.resourcePumpTicks += 1
                if self.resourcePumpTicks>=180 {timer.invalidate();self.resourcePump=nil}
            }
        }
    }

    public override func draw(_ dirtyRect:NSRect) {
        NSColor.textBackgroundColor.setFill();dirtyRect.fill()
        guard let image,let context=NSGraphicsContext.current?.cgContext else{return}
        context.saveGState()
        // CGImage rows run bottom-to-top in this flipped NSView. Translate by
        // the cached image's height, not the current viewport height: during
        // live resize those heights intentionally differ until Ultralight's
        // next frame arrives. Using bounds.height bottom-anchored the old frame
        // and made its top jump by every viewport-height delta.
        let translationY=imageSize.height
        #if DEBUG
        debugPaintedBitmapTop=translationY-imageSize.height
        #endif
        context.translateBy(x:0,y:translationY);context.scaleBy(x:1,y:-1)
        // Never resample text merely because AppKit has delivered the new
        // bounds before Ultralight's next frame. Keep the last frame pixel
        // aligned and let the freshly reflowed frame replace it atomically.
        context.interpolationQuality = .none
        context.draw(image,in:NSRect(origin:.zero,size:imageSize))
        context.restoreGState()
    }

    #if DEBUG
    /// Transitional hook for explicitly selected legacy integration tests.
    /// The default integration path uses renderer-neutral native probes.
    public func evaluateJavaScript(_ script:String,completionHandler:((Any?,Error?)->Void)?=nil) {
        let error=NSError(domain:"AstraMarkdown.HTMLPreview",code:1,
            userInfo:[NSLocalizedDescriptionKey:"JavaScript probes are unavailable in the Ultralight preview module"])
        completionHandler?(nil,error)
    }

    public var debugText:String {
        guard let engine,let raw=astra_ul_surface_text(engine) else{return ""}
        defer {astra_ul_string_free(raw)};return String(cString:raw)
    }
    @objc public var benchmarkVisibleText:String {debugText}
    public func debugCount(_ selector:String)->Int {
        guard let engine else{return 0}
        return selector.withCString{Int(astra_ul_surface_selector_count(engine,$0))}
    }
    public func debugRect(_ selector:String,containing text:String="")->NSRect? {
        guard let engine else{return nil}
        var x=0.0,y=0.0,width=0.0,height=0.0
        let found=selector.withCString {selector in text.withCString {text in
            astra_ul_surface_text_rect(engine,selector,text,&x,&y,&width,&height)
        }}
        return found ? NSRect(x:x,y:y,width:width,height:height):nil
    }

    public func takeSnapshot(with configuration:HTMLPreviewSnapshotConfiguration,completionHandler:@escaping(NSImage?,Error?)->Void) {
        guard let image else {
            completionHandler(nil,NSError(domain:"AstraMarkdown.HTMLPreview",code:2,
                userInfo:[NSLocalizedDescriptionKey:"Preview has no painted frame"]));return
        }
        let full=NSImage(cgImage:image,size:bounds.size)
        guard configuration.rect != bounds,let cg=full.cgImage(forProposedRect:nil,context:nil,hints:nil),
              let cropped=cg.cropping(to:NSRect(x:configuration.rect.minX,
                y:bounds.height-configuration.rect.maxY,width:configuration.rect.width,
                height:configuration.rect.height)) else {completionHandler(full,nil);return}
        completionHandler(NSImage(cgImage:cropped,size:configuration.rect.size),nil)
    }
    #endif

    public override func scrollWheel(with event:NSEvent) {
        axisReset?.cancel();axisReset=nil
        if event.phase.contains(.began) {horizontalGesture=nil}
        let phased = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        if phased,horizontalGesture==nil,event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            horizontalGesture=abs(event.scrollingDeltaX)>abs(event.scrollingDeltaY)
        }
        if horizontalGesture ?? (abs(event.scrollingDeltaX)>abs(event.scrollingDeltaY)) {
            if let engine {
                let p=convert(event.locationInWindow,from:nil)
                astra_ul_surface_horizontal_scroll(engine,Int32(event.scrollingDeltaX),Int32(p.x),Int32(p.y))
                refreshImage()
            }
        } else {verticalWheel?(event)}
        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) ||
            event.phase.contains(.cancelled) || !phased {horizontalGesture=nil}
        else if event.phase.contains(.ended) {
            let reset=DispatchWorkItem { [weak self] in self?.horizontalGesture=nil }
            axisReset=reset;DispatchQueue.main.asyncAfter(deadline:.now()+0.15,execute:reset)
        }
    }

    private func fireMouse(_ event:NSEvent,type:Int32,button:Int32) {
        guard let engine else{return}
        let point=convert(event.locationInWindow,from:nil)
        astra_ul_surface_mouse(engine,type,Int32(point.x),Int32(point.y),button)
        refreshImage()
    }
    public override func mouseMoved(with event:NSEvent) {fireMouse(event,type:0,button:0)}
    public override func mouseDragged(with event:NSEvent) {fireMouse(event,type:0,button:1)}
    public override func mouseDown(with event:NSEvent) {window?.makeFirstResponder(self);fireMouse(event,type:1,button:1)}
    public override func mouseUp(with event:NSEvent) {
        fireMouse(event,type:2,button:1)
        guard let engine else{return}
        let point=convert(event.locationInWindow,from:nil)
        if let raw=astra_ul_surface_link_at(engine,point.x,point.y) {
            let value=String(cString:raw);astra_ul_string_free(raw)
            if let url=URL(string:value,relativeTo:baseURL)?.absoluteURL {openURL?(url)}
        }
    }
    public override func rightMouseDown(with event:NSEvent) {fireMouse(event,type:1,button:3);NSMenu.popUpContextMenu(menu(for:event) ?? NSMenu(),with:event,for:self)}
    public override func rightMouseUp(with event:NSEvent) {fireMouse(event,type:2,button:3)}

    public override func menu(for event:NSEvent)->NSMenu? {
        let menu=NSMenu();let copy=NSMenuItem(title:"Copy",action:#selector(copySelection(_:)),keyEquivalent:"")
        copy.target=self;menu.addItem(copy);return menu
    }
    @objc private func copySelection(_ sender:Any?) {
        guard let engine,let raw=astra_ul_surface_selected_text(engine) else{return}
        let value=String(cString:raw);astra_ul_string_free(raw)
        NSPasteboard.general.clearContents();NSPasteboard.general.setString(value,forType:.string)
    }
}
