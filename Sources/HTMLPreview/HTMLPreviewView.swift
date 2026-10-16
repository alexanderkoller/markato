import AppKit
import CUltralightPreview
import ImageIO
import MarkdownCore

public enum HTMLPreviewResources {
    public static let stylesheetGeneration:UInt64=2
    public static let stylesheet:String = {
        func resource(_ name:String)->String {
            guard let url=Bundle.module.url(forResource:name,withExtension:"css"),
                  let text=try? String(contentsOf:url,encoding:.utf8) else {
                preconditionFailure("Missing HTMLPreview resource: \(name).css")
            }
            return text
        }
        return resource("KaTeX")+resource("Preview")+resource("CodeHighlight")
    }()
}

/// Resolves parser asset tokens to original URLs and reserves local image
/// geometry without decoding image pixels.
public final class HTMLAssetPreparer {
    private var dimensions=[URL:(width:Int,height:Int)?]()
    private let delayImages:Bool
    public init(delayImages:Bool=false) {self.delayImages=delayImages}
    public func prepare(_ html:String,baseURL:URL?)->String {
        guard let tags=try? NSRegularExpression(pattern:#"<img\b[^>]*>"#,options:[.caseInsensitive]),
              let assets=try? NSRegularExpression(pattern:#"astra-asset://[^\"']+"#) else{return html}
        var result=html
        let source=html as NSString
        for tagMatch in tags.matches(in:html,range:NSRange(location:0,length:source.length)).reversed() {
            let original=source.substring(with:tagMatch.range),originalNS=original as NSString
            var prepared=original
            var resolvedURL:URL?
            if let asset=assets.firstMatch(in:original,range:NSRange(location:0,length:originalNS.length)) {
                let token=originalNS.substring(with:asset.range).replacingOccurrences(of:"&amp;",with:"&")
                if let components=URLComponents(string:token),
                   let source=components.queryItems?.first(where:{$0.name=="source"})?.value,
                   let url=URL(string:source,relativeTo:baseURL)?.absoluteURL {
                    resolvedURL=url
                    prepared=originalNS.replacingCharacters(in:asset.range,with:escapeAttribute(url.absoluteString))
                }
            } else if let source=imageSource(in:original) {
                resolvedURL=URL(string:source,relativeTo:baseURL)?.absoluteURL
            }
            if let url=resolvedURL,url.isFileURL,!containsDimension(in:original),let size=imageDimensions(at:url),
               let close=prepared.lastIndex(of:">") {
                prepared.insert(contentsOf:" width=\"\(size.width)\" height=\"\(size.height)\"",at:close)
            }
            if delayImages {prepared=deferImageSource(in:prepared)}
            if let range=Range(tagMatch.range,in:result) {result.replaceSubrange(range,with:prepared)}
        }
        return result
    }
    private func imageSource(in tag:String)->String? {
        guard let expression=try? NSRegularExpression(
            pattern:#"\bsrc\s*=\s*(?:\"([^\"]*)\"|'([^']*)')"#,options:[.caseInsensitive]),
              let match=expression.firstMatch(in:tag,range:NSRange(tag.startIndex...,in:tag)) else{return nil}
        let capture=match.range(at:1).location != NSNotFound ? match.range(at:1):match.range(at:2)
        guard let range=Range(capture,in:tag) else{return nil}
        return String(tag[range]).replacingOccurrences(of:"&amp;",with:"&")
    }
    private func deferImageSource(in tag:String)->String {
        guard tag.range(of:#"\bdata-astra-delayed-src\s*="#,
                        options:[.regularExpression,.caseInsensitive]) == nil,
              let expression=try? NSRegularExpression(
                pattern:#"\bsrc\s*=\s*(?:\"([^\"]*)\"|'([^']*)')"#,
                options:[.caseInsensitive]),
              let match=expression.firstMatch(in:tag,range:NSRange(tag.startIndex...,in:tag)),
              let range=Range(match.range,in:tag) else{return tag}
        let capture=match.range(at:1).location != NSNotFound ? match.range(at:1):match.range(at:2)
        guard let valueRange=Range(capture,in:tag) else{return tag}
        let value=tag[valueRange].replacingOccurrences(of:"\"",with:"&quot;")
        var result=tag
        result.replaceSubrange(range,with:"src=\"\" data-astra-delayed-src=\"\(value)\"")
        return result
    }
    private func containsDimension(in tag:String)->Bool {
        tag.range(of:#"\b(width|height)\s*="#,options:[.regularExpression,.caseInsensitive]) != nil
    }
    private func imageDimensions(at url:URL)->(width:Int,height:Int)? {
        if let cached=dimensions[url] {return cached}
        let value=url.pathExtension.lowercased()=="svg" ? svgDimensions(at:url):rasterDimensions(at:url)
        dimensions[url]=value;return value
    }
    private func rasterDimensions(at url:URL)->(width:Int,height:Int)? {
        guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              var width=(properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              var height=(properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width>0,height>0 else{return nil}
        let orientation=(properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5...8).contains(orientation) {swap(&width,&height)}
        return (width,height)
    }
    private func svgDimensions(at url:URL)->(width:Int,height:Int)? {
        guard let data=try? Data(contentsOf:url,options:.mappedIfSafe),
              let text=String(data:data.prefix(65536),encoding:.utf8),
              let svg=text.range(of:#"<svg\b[^>]*>"#,options:[.regularExpression,.caseInsensitive]) else{return nil}
        let tag=String(text[svg])
        func number(_ name:String)->Double? {
            guard let match=tag.range(of:"\\b\(name)\\s*=\\s*['\"]([0-9]+(?:\\.[0-9]+)?)",
                options:[.regularExpression,.caseInsensitive]) else{return nil}
            return tag[match].split(whereSeparator:{$0=="=" || $0=="\"" || $0=="'"}).last.flatMap{Double($0)}
        }
        if let width=number("width"),let height=number("height"),width>0,height>0 {
            return (Int(width.rounded()),Int(height.rounded()))
        }
        guard let match=tag.range(of:#"\bviewBox\s*=\s*['\"][^'\"]+['\"]"#,
            options:[.regularExpression,.caseInsensitive]) else{return nil}
        let numbers=tag[match].split(whereSeparator:{" ='\"\t\r\n".contains($0)}).compactMap{Double($0)}
        guard numbers.count>=4,numbers[2]>0,numbers[3]>0 else{return nil}
        return (Int(numbers[2].rounded()),Int(numbers[3].rounded()))
    }
    private func escapeAttribute(_ value:String)->String {
        value.replacingOccurrences(of:"&",with:"&amp;")
            .replacingOccurrences(of:"\"",with:"&quot;")
            .replacingOccurrences(of:"'",with:"&#39;")
    }
}

public struct HTMLPreviewGeometry:Equatable,Sendable {
    public struct Item:Equatable,Sendable {
        public let id:String
        public let y:CGFloat
        public let height:CGFloat
        /// Offset from this block's top, never from the document root.
        public let landmark:CGFloat?
    }
    public let width:CGFloat
    public let height:CGFloat
    public let items:[Item]
}

public struct HTMLPreviewFlowDisplacement:Sendable {
    public let firstShiftedIndex:Int
    public let delta:CGFloat
}

public struct HTMLPreviewRenderRequest:Sendable {
    public let token:Int
    public let revision:Int
    public let layoutID:PreviewLayoutID
    public let entries:[RenderedEntry]
    public let fontSize:CGFloat
    public let baseURL:URL?
    public let viewportSize:NSSize
    public let scale:CGFloat
    public let scrollPoint:NSPoint
    public init(token:Int,revision:Int,layoutID:PreviewLayoutID,entries:[RenderedEntry],fontSize:CGFloat,
        baseURL:URL?,viewportSize:NSSize,scale:CGFloat,scrollPoint:NSPoint) {
        self.token=token;self.revision=revision;self.layoutID=layoutID;self.entries=entries
        self.fontSize=fontSize;self.baseURL=baseURL;self.viewportSize=viewportSize
        self.scale=scale;self.scrollPoint=scrollPoint
    }
}

public struct HTMLPreviewLayout:Sendable {
    public let token:Int
    public let revision:Int
    public let layoutID:PreviewLayoutID
    public let geometry:HTMLPreviewGeometry
    public let measurements:[PreviewBlockMeasurement]
    public let baseURL:URL?
}

public final class HTMLPreviewFrame:@unchecked Sendable {
    public enum Cause:Equatable,Sendable {case request,resource}
    public let token:Int
    public let revision:Int
    public let layoutID:PreviewLayoutID
    public let geometry:HTMLPreviewGeometry
    public let measurements:[PreviewBlockMeasurement]
    public let image:CGImage
    public let imageSize:NSSize
    public let baseURL:URL?
    public let cause:Cause
    public let scrollPoint:NSPoint
    public let flowDisplacements:[HTMLPreviewFlowDisplacement]
    public let createdDuringViewportGesture:Bool
    fileprivate let pixels:Data
    fileprivate init(token:Int,revision:Int,layoutID:PreviewLayoutID,geometry:HTMLPreviewGeometry,
        measurements:[PreviewBlockMeasurement],pixels:Data,image:CGImage,imageSize:NSSize,
        baseURL:URL?,cause:Cause,scrollPoint:NSPoint,
        flowDisplacements:[HTMLPreviewFlowDisplacement],createdDuringViewportGesture:Bool) {
        self.token=token;self.revision=revision;self.layoutID=layoutID;self.geometry=geometry
        self.measurements=measurements;self.pixels=pixels;self.image=image;self.imageSize=imageSize
        self.baseURL=baseURL;self.cause=cause;self.scrollPoint=scrollPoint
        self.flowDisplacements=flowDisplacements
        self.createdDuringViewportGesture=createdDuringViewportGesture
    }
}

private struct HTMLPreviewBitmap {
    let pixels:Data
    let image:CGImage
    let size:NSSize
}

private struct HTMLPreviewPaintResult {
    let bitmap:HTMLPreviewBitmap?
    let frame:HTMLPreviewFrame?
    let scrollPoint:NSPoint
}

private enum HTMLPreviewScrollStep {
    case pending
    case ready(HTMLPreviewPaintResult?)
}

/// All Ultralight state lives on this object's dedicated thread. Tasks are
/// closures over ThreadState so no engine or DOM handle crosses the boundary.
private final class HTMLRendererExecutor {
    fileprivate final class ThreadState {
        var engine:OpaquePointer?
        var entryIDs=[String]()
        var entries=[RenderedEntry]()
        var geometryItems=[HTMLPreviewGeometry.Item]()
        var exactItemYs=[CGFloat]()
        var flowDisplacements=[HTMLPreviewFlowDisplacement]()
        var viewportGestureActive=false
        var rootWidth:CGFloat=0
        var rootHeight:CGFloat=0
        var pixelSize=(width:UInt32(0),height:UInt32(0),scale:CGFloat(1))
        var pixelData=Data()
        var paintedScrollPoint:NSPoint?
        var pendingScrollPoint:NSPoint?
        var request:HTMLPreviewRenderRequest?
        var resourceStarted:Date?
        var delayedImagesReadyAt:Date?
        let imageLoadDelay:TimeInterval
        let assets:HTMLAssetPreparer

        init(sdkRoot:String,css:String,imageLoadDelay:TimeInterval) {
            self.imageLoadDelay=max(0,imageLoadDelay)
            assets=HTMLAssetPreparer(delayImages:imageLoadDelay>0)
            sdkRoot.withCString {root in css.withCString {style in
                engine=astra_ul_surface_create(root,style,1,1,1)
            }}
        }
        deinit {if let engine {astra_ul_surface_destroy(engine)}}

        func layout(_ request:HTMLPreviewRenderRequest)->HTMLPreviewLayout? {
            guard let engine else{return nil}
            self.request=request
            let scale=max(1,request.scale)
            let width=UInt32(max(1,ceil(request.viewportSize.width*scale)))
            let height=UInt32(max(1,ceil(request.viewportSize.height*scale)))
            if width != pixelSize.width || height != pixelSize.height || scale != pixelSize.scale {
                pixelSize=(width,height,scale);astra_ul_surface_resize(engine,width,height,scale)
            }
            astra_ul_surface_begin_update(engine,request.entries.count,request.fontSize)
            for entry in request.entries {
                guard let html=entry.fragment.html else{return nil}
                let prepared=assets.prepare(html,baseURL:request.baseURL)
                entry.id.withCString {id in prepared.withCString {body in
                    astra_ul_surface_add_entry(engine,id,body,entry.fragment.from==0)
                }}
            }
            guard astra_ul_surface_commit_update(engine) else{return nil}
            entries=request.entries;entryIDs=request.entries.map(\.id)
            guard updateGeometry(ids:Set(entryIDs)) else{return nil}
            _=drainDirtyIDs()
            if astra_ul_surface_pending_resource_count(engine)>0 {
                let now=Date();resourceStarted=now
                delayedImagesReadyAt=imageLoadDelay>0 ? now.addingTimeInterval(imageLoadDelay):nil
            } else {resourceStarted=nil;delayedImagesReadyAt=nil}
            let measurements=makeMeasurements(ids:Set(entryIDs))
            return HTMLPreviewLayout(token:request.token,revision:request.revision,layoutID:request.layoutID,
                geometry:geometry(),measurements:measurements,baseURL:request.baseURL)
        }

        func capture(token:Int,point:NSPoint)->HTMLPreviewFrame? {
            guard let engine,request?.token==token else{return nil}
            scrollAndRender(engine,to:point)
            let dirty=drainDirtyIDs()
            if !dirty.isEmpty,!updateGeometry(ids:dirty) {return nil}
            if astra_ul_surface_pending_resource_count(engine)>0,resourceStarted==nil {resourceStarted=Date()}
            guard let bitmap=makeBitmap() else{return nil}
            paintedScrollPoint=point
            return makeFrame(bitmap:bitmap,measuredIDs:dirty.isEmpty ? Set(entryIDs):dirty,cause:.request)
        }

        /// Paints resource-updated layout at the viewport-compensated offset.
        /// Only changes that occurred during this settlement are re-reported.
        func captureResource(token:Int,point:NSPoint)->HTMLPreviewFrame? {
            guard let engine,request?.token==token else{return nil}
            // Layout-changing resources are rare and require pixels for the
            // compensated offset immediately. Ordinary source scrolling does
            // not take this full-repaint path.
            astra_ul_surface_invalidate(engine)
            scrollAndRender(engine,to:point)
            let dirty=drainDirtyIDs()
            if !dirty.isEmpty,!updateGeometry(ids:dirty) {return nil}
            guard let bitmap=makeBitmap() else{return nil}
            paintedScrollPoint=point
            return makeFrame(bitmap:bitmap,measuredIDs:dirty,cause:.resource)
        }

        func resourceTick()->HTMLPreviewFrame? {
            guard let engine,request != nil else{return nil}
            updateResourceClock(engine)
            _=astra_ul_surface_pump(engine)
            let dirty=drainDirtyIDs()
            if astra_ul_surface_pending_resource_count(engine)==0 {
                resourceStarted=nil;delayedImagesReadyAt=nil
            }
            guard !dirty.isEmpty,updateGeometry(ids:dirty),let bitmap=makeBitmap() else{return nil}
            return makeFrame(bitmap:bitmap,measuredIDs:dirty,cause:.resource)
        }
        private func updateResourceClock(_ engine:OpaquePointer) {
            let now=Date()
            if let ready=delayedImagesReadyAt,now>=ready {
                astra_ul_surface_activate_delayed_images(engine);delayedImagesReadyAt=nil
            }
            if let started=resourceStarted,now.timeIntervalSince(started)>imageLoadDelay+10 {
                astra_ul_surface_abandon_pending_resources(engine)
                resourceStarted=nil;delayedImagesReadyAt=nil
            }
        }

        var needsResourceTicks:Bool {
            guard let engine else{return false}
            return astra_ul_surface_pending_resource_count(engine)>0
        }
        func abandonResources() {
            if let engine {astra_ul_surface_abandon_pending_resources(engine)}
            resourceStarted=nil;delayedImagesReadyAt=nil
        }

        private func drainDirtyIDs()->Set<String> {
            guard let engine else{return []}
            var result=Set<String>()
            while astra_ul_surface_dirty_count(engine)>0,let raw=astra_ul_surface_take_dirty_id(engine) {
                result.insert(String(cString:raw));astra_ul_string_free(raw)
            }
            return result
        }
        private func updateGeometry(ids:Set<String>)->Bool {
            guard let engine else{return false}
            var root=AstraULGeometry()
            guard astra_ul_surface_geometry(engine,&root),root.item_count==entryIDs.count else{return false}
            let refreshAll=geometryItems.count != entryIDs.count || geometryItems.map(\.id) != entryIDs
            if refreshAll {
                geometryItems=entryIDs.map{.init(id:$0,y:0,height:0,landmark:nil)}
                exactItemYs=Array(repeating:0,count:entryIDs.count)
                var y:CGFloat=32
                for index in entryIDs.indices {
                    var value=AstraULGeometryItem()
                    guard astra_ul_surface_geometry_item(engine,index,&value) else{return false}
                    exactItemYs[index]=value.y
                    geometryItems[index] = .init(id:entryIDs[index],y:y,height:value.height,
                        landmark:value.has_landmark ? value.landmark_y:nil)
                    y += value.height
                }
            } else {
                // Query the changed box and the following flow boundary. The
                // DOM moves the suffix; mirror that one displacement in the
                // retained coordinates without reconstructing their Ys.
                let changed=entryIDs.indices.filter{ids.contains(entryIDs[$0])}
                for index in changed {
                    var value=AstraULGeometryItem()
                    guard astra_ul_surface_geometry_item(engine,index,&value) else{return false}
                    exactItemYs[index]=value.y
                    let next=index+1
                    let strideDelta=CGFloat(value.height)-geometryItems[index].height
                    var delta:CGFloat=0
                    if next<entryIDs.count {
                        var boundary=AstraULGeometryItem()
                        guard astra_ul_surface_geometry_item(engine,next,&boundary) else{return false}
                        delta=CGFloat(boundary.y)-exactItemYs[next]
                    }
                    let old=geometryItems[index]
                    geometryItems[index] = .init(id:entryIDs[index],y:old.y,height:value.height,
                        landmark:value.has_landmark ? value.landmark_y:nil)
                    if strideDelta != 0,next<geometryItems.count {
                        for suffix in next..<geometryItems.count {
                            let item=geometryItems[suffix]
                            geometryItems[suffix] = .init(id:item.id,y:item.y+strideDelta,
                                height:item.height,landmark:item.landmark)
                        }
                    }
                    if delta != 0 {
                        for suffix in next..<exactItemYs.count {exactItemYs[suffix] += delta}
                        flowDisplacements.append(.init(firstShiftedIndex:next,delta:delta))
                    }
                }
            }
            let estimatedBottom=(geometryItems.last.map{$0.y+$0.height} ?? 32)+32
            guard abs(CGFloat(root.height)-estimatedBottom)<1 else{return false}
            rootWidth=root.width;rootHeight=root.height
            return true
        }
        private func makeFrame(bitmap:HTMLPreviewBitmap,measuredIDs:Set<String>,cause:HTMLPreviewFrame.Cause)->HTMLPreviewFrame? {
            guard let request else{return nil}
            let displacements=flowDisplacements
            flowDisplacements.removeAll(keepingCapacity:true)
            return HTMLPreviewFrame(token:request.token,revision:request.revision,layoutID:request.layoutID,
                geometry:geometry(),measurements:makeMeasurements(ids:measuredIDs),pixels:bitmap.pixels,
                image:bitmap.image,imageSize:bitmap.size,baseURL:request.baseURL,cause:cause,
                scrollPoint:NSPoint(x:0,y:astra_ul_surface_scroll_y(engine)),
                flowDisplacements:displacements,
                createdDuringViewportGesture:viewportGestureActive)
        }
        private func geometry()->HTMLPreviewGeometry {
            .init(width:rootWidth,height:rootHeight,items:geometryItems)
        }
        private func makeMeasurements(ids:Set<String>)->[PreviewBlockMeasurement] {
            let versions=Dictionary(uniqueKeysWithValues:entries.map{($0.id,$0.contentVersion)})
            let blocks=Dictionary(uniqueKeysWithValues:entries.map{($0.id,$0.blockID)})
            let heights=Dictionary(uniqueKeysWithValues:geometryItems.map{($0.id,$0.height)})
            return ids.compactMap {id -> PreviewBlockMeasurement? in
                guard let block=blocks[id],let version=versions[id],let height=heights[id] else{return nil}
                return PreviewBlockMeasurement(blockID:block,contentVersion:version,stride:height)
            }
        }
        private func inputPaintResult()->HTMLPreviewPaintResult? {
            let dirty=drainDirtyIDs()
            guard dirty.isEmpty else {
                guard updateGeometry(ids:dirty),let bitmap=makeBitmap(),
                      let frame=makeFrame(bitmap:bitmap,measuredIDs:dirty,cause:.resource) else{return nil}
                return HTMLPreviewPaintResult(bitmap:nil,frame:frame,scrollPoint:frame.scrollPoint)
            }
            let scroll=engine.map{NSPoint(x:0,y:astra_ul_surface_scroll_y($0))} ?? .zero
            return HTMLPreviewPaintResult(bitmap:makeBitmap(),frame:nil,scrollPoint:scroll)
        }
        func beginScrollPaint(_ point:NSPoint,token:Int)->HTMLPreviewScrollStep {
            guard let engine,request?.token==token else{return .ready(nil)}
            if let paintedScrollPoint,
               abs(paintedScrollPoint.x-point.x)<0.01,abs(paintedScrollPoint.y-point.y)<0.01 {
                // A superseded in-flight scroll may have moved the DOM while
                // the retained bitmap still represents this requested point.
                // Restore the DOM coordinate, but the existing pixels are
                // already the correct publication.
                _=astra_ul_surface_scroll(engine,point.x,point.y)
                pendingScrollPoint=nil
                let scroll=NSPoint(x:0,y:astra_ul_surface_scroll_y(engine))
                return .ready(HTMLPreviewPaintResult(bitmap:makeBitmap(),frame:nil,scrollPoint:scroll))
            }
            astra_ul_surface_clear_dirty_pixels(engine)
            guard astra_ul_surface_scroll(engine,point.x,point.y) else {
                paintedScrollPoint=point
                return .ready(inputPaintResult())
            }
            pendingScrollPoint=point
            return .pending
        }
        func continueScrollPaint(token:Int)->HTMLPreviewScrollStep {
            guard let engine,request?.token==token else{return .ready(nil)}
            updateResourceClock(engine)
            // Ultralight applies the pixel shift on one renderer cycle and
            // settles the newly exposed strip on the next. Both operations are
            // viewport-bounded; neither revisits document layout.
            _=astra_ul_surface_render(engine)
            _=astra_ul_surface_render(engine)
            let result=inputPaintResult()
            paintedScrollPoint=pendingScrollPoint
            pendingScrollPoint=nil
            return .ready(result)
        }
        func settleScrollPaint(_ point:NSPoint,token:Int)->HTMLPreviewPaintResult? {
            guard let engine,request?.token==token else{return nil}
            astra_ul_surface_clear_dirty_pixels(engine)
            _=astra_ul_surface_scroll(engine,point.x,point.y)
            astra_ul_surface_invalidate(engine)
            _=astra_ul_surface_render(engine)
            paintedScrollPoint=point;pendingScrollPoint=nil
            return inputPaintResult()
        }
        private func scrollAndRender(_ engine:OpaquePointer,to point:NSPoint) {
            guard astra_ul_surface_scroll(engine,point.x,point.y) else{return}
            // Ultralight updates DOM scroll metrics in its first cycle but may
            // not repaint the software surface until a later scheduler tick.
            // Do not copy and publish the preceding scroll position. This is a
            // bounded renderer wait, independent of document size.
            for attempt in 0..<12 {
                if astra_ul_surface_render(engine) {return}
                if attempt<11 {Thread.sleep(forTimeInterval:0.002)}
            }
        }
        func horizontalScroll(_ delta:Int32,point:NSPoint,token:Int)->HTMLPreviewPaintResult? {
            guard let engine,request?.token==token else{return nil}
            astra_ul_surface_horizontal_scroll(engine,delta,Int32(point.x),Int32(point.y))
            _ = astra_ul_surface_render(engine);return inputPaintResult()
        }
        func mouse(type:Int32,point:NSPoint,button:Int32,token:Int)->HTMLPreviewPaintResult? {
            guard let engine,request?.token==token else{return nil}
            astra_ul_surface_mouse(engine,type,Int32(point.x),Int32(point.y),button)
            _ = astra_ul_surface_render(engine);return inputPaintResult()
        }
        func toggleFirstDetails(token:Int)->HTMLPreviewPaintResult? {
            guard let engine,request?.token==token,astra_ul_surface_toggle_first_details(engine) else{return nil}
            return inputPaintResult()
        }
        func link(at point:NSPoint,token:Int)->(String,NSRect)? {
            guard let engine,request?.token==token,
                  let raw=astra_ul_surface_link_at(engine,point.x,point.y) else{return nil}
            let value=String(cString:raw);astra_ul_string_free(raw)
            var x=Double(point.x),y=Double(point.y),width=0.0,height=0.0
            _=astra_ul_surface_link_rect_at(engine,Double(point.x),Double(point.y),&x,&y,&width,&height)
            return (value,NSRect(x:x,y:y,width:width,height:height))
        }
        func selectedText(token:Int)->String? {
            guard let engine,request?.token==token,let raw=astra_ul_surface_selected_text(engine) else{return nil}
            defer {astra_ul_string_free(raw)};return String(cString:raw)
        }
        func rect(_ selector:String,containing text:String,token:Int)->NSRect? {
            guard let engine,request?.token==token else{return nil}
            var x=0.0,y=0.0,width=0.0,height=0.0
            let found=selector.withCString {selector in text.withCString {text in
                astra_ul_surface_text_rect(engine,selector,text,&x,&y,&width,&height)
            }}
            return found ? NSRect(x:x,y:y,width:width,height:height):nil
        }
        func text(token:Int)->String {
            guard let engine,request?.token==token,let raw=astra_ul_surface_text(engine) else{return ""}
            defer {astra_ul_string_free(raw)};return String(cString:raw)
        }
        func count(_ selector:String,token:Int)->Int {
            guard let engine,request?.token==token else{return 0}
            return selector.withCString{Int(astra_ul_surface_selector_count(engine,$0))}
        }
        private func makeBitmap()->HTMLPreviewBitmap? {
            guard let engine else{return nil}
            let count=astra_ul_surface_pixel_bytes(engine)
            guard count>0 else{return nil}
            var pixels=pixelData.count==count ? pixelData:Data(count:count)
            var width:UInt32=0,height:UInt32=0,stride:UInt32=0
            let copied=pixels.withUnsafeMutableBytes {bytes in
                astra_ul_surface_copy_pixels(engine,bytes.baseAddress,count,&width,&height,&stride)
            }
            guard copied,let provider=CGDataProvider(data:pixels as CFData) else{return nil}
            let info=CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little)
            guard let image=CGImage(width:Int(width),height:Int(height),bitsPerComponent:8,bitsPerPixel:32,
                bytesPerRow:Int(stride),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:info,
                provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else{return nil}
            pixelData=pixels
            let scale=max(1,pixelSize.scale)
            return HTMLPreviewBitmap(pixels:pixels,image:image,
                size:NSSize(width:CGFloat(width)/scale,height:CGFloat(height)/scale))
        }
    }

    private final class QueueState {
        private struct ScrollWork {
            let generation:Int
            let token:Int
            let point:NSPoint
            let settles:Bool
            let completion:(HTMLPreviewPaintResult?)->Void
        }
        let condition=NSCondition()
        var tasks=[(ThreadState)->Void]()
        private var pendingScroll:ScrollWork?
        private var latestScrollGeneration=0
        let sdkRoot:String,css:String
        let imageLoadDelay:TimeInterval
        var resourceFrame:((HTMLPreviewFrame)->Void)?
        var ready:(()->Void)?
        var isReady=false
        init(sdkRoot:String,css:String,imageLoadDelay:TimeInterval) {
            self.sdkRoot=sdkRoot;self.css=css;self.imageLoadDelay=imageLoadDelay
        }
        func run() {
            let renderer=ThreadState(sdkRoot:sdkRoot,css:css,imageLoadDelay:imageLoadDelay)
            var activeScroll:ScrollWork?
            var nextResourceTick=Date()
            condition.lock();isReady=true;let callback=ready;condition.unlock()
            if let callback {DispatchQueue.main.async(execute:callback)}
            while true {
                if activeScroll == nil,renderer.needsResourceTicks,Date()>=nextResourceTick {
                    let frame=autoreleasepool(invoking:{renderer.resourceTick()})
                    nextResourceTick=Date(timeIntervalSinceNow:1/60)
                    if let frame {DispatchQueue.main.async { [weak self] in self?.resourceFrame?(frame) }}
                    continue
                }
                condition.lock()
                while tasks.isEmpty,pendingScroll == nil {
                    if activeScroll != nil {
                        _ = condition.wait(until:Date(timeIntervalSinceNow:1/240));break
                    }
                    if renderer.needsResourceTicks {_ = condition.wait(until:nextResourceTick);break}
                    condition.wait()
                }
                let task=tasks.isEmpty ? nil:tasks.removeFirst()
                // Once Ultralight has started a surface scroll, finish that
                // bounded paint before applying another DOM position. New
                // positions still coalesce to one latest value, but they must
                // not continually restart the paint and starve publication.
                let scroll=task == nil && activeScroll == nil ? pendingScroll:nil
                if scroll != nil {pendingScroll=nil}
                condition.unlock()
                if let task {autoreleasepool {task(renderer)}}
                else if let scroll {
                    if scroll.settles {
                        let result=autoreleasepool(invoking:{renderer.settleScrollPaint(scroll.point,token:scroll.token)})
                        finish(scroll,result:result);activeScroll=nil
                        continue
                    }
                    switch autoreleasepool(invoking:{renderer.beginScrollPaint(scroll.point,token:scroll.token)}) {
                    case .ready(let result):finish(scroll,result:result);activeScroll=nil
                    case .pending:
                        activeScroll=scroll
                        switch autoreleasepool(invoking:{renderer.continueScrollPaint(token:scroll.token)}) {
                        case .pending: break
                        case .ready(let result):
                            finish(scroll,result:result);activeScroll=nil
                        }
                    }
                }
                else if let active=activeScroll {
                    switch autoreleasepool(invoking:{renderer.continueScrollPaint(token:active.token)}) {
                    case .pending: break
                    case .ready(let result):
                        finish(active,result:result);activeScroll=nil
                    }
                }
                else if renderer.needsResourceTicks {
                    let frame=autoreleasepool(invoking:{renderer.resourceTick()})
                    nextResourceTick=Date(timeIntervalSinceNow:1/60)
                    if let frame {DispatchQueue.main.async { [weak self] in self?.resourceFrame?(frame) }}
                }
            }
        }
        private func finish(_ work:ScrollWork,result:HTMLPreviewPaintResult?) {
            DispatchQueue.main.async { [weak self] in
                // A resource may finish during any paint. Its measurements
                // belong to the retained layout even if a newer scroll has
                // superseded this bitmap; resource settlement will recapture
                // at the current anchored position before publishing pixels.
                if let frame=result?.frame {self?.resourceFrame?(frame);return}
                guard self?.isCurrentScroll(work.generation) == true else{return}
                work.completion(result)
            }
        }
        func enqueueScroll(token:Int,point:NSPoint,completion:@escaping(HTMLPreviewPaintResult?)->Void) {
            condition.lock()
            latestScrollGeneration += 1
            pendingScroll=ScrollWork(generation:latestScrollGeneration,token:token,point:point,
                settles:false,completion:completion)
            condition.signal();condition.unlock()
        }
        func enqueueScrollSettlement(token:Int,point:NSPoint,
            completion:@escaping(HTMLPreviewPaintResult?)->Void) {
            condition.lock()
            latestScrollGeneration += 1
            pendingScroll=ScrollWork(generation:latestScrollGeneration,token:token,point:point,
                settles:true,completion:completion)
            condition.signal();condition.unlock()
        }
        private func isCurrentScroll(_ generation:Int)->Bool {
            condition.lock();defer{condition.unlock()}
            return generation == latestScrollGeneration
        }
    }

    private let queue:QueueState
    private let thread:Thread
    init(sdkRoot:String,css:String,imageLoadDelay:TimeInterval) {
        let queue=QueueState(sdkRoot:sdkRoot,css:css,imageLoadDelay:imageLoadDelay);self.queue=queue
        thread=Thread {queue.run()};thread.name="Astra HTML renderer";thread.qualityOfService = .userInitiated
        thread.start()
    }
    var ready:(()->Void)? {
        get{queue.condition.lock();defer{queue.condition.unlock()};return queue.ready}
        set {
            queue.condition.lock();queue.ready=newValue;let callNow=queue.isReady;queue.condition.unlock()
            if callNow,let newValue {DispatchQueue.main.async(execute:newValue)}
        }
    }
    var resourceFrame:((HTMLPreviewFrame)->Void)? {get{queue.resourceFrame} set{queue.resourceFrame=newValue}}
    func async(_ task:@escaping(ThreadState)->Void) {
        queue.condition.lock();queue.tasks.append(task);queue.condition.signal();queue.condition.unlock()
    }
    func scroll(token:Int,point:NSPoint,completion:@escaping(HTMLPreviewPaintResult?)->Void) {
        queue.enqueueScroll(token:token,point:point,completion:completion)
    }
    func settleScroll(token:Int,point:NSPoint,completion:@escaping(HTMLPreviewPaintResult?)->Void) {
        queue.enqueueScrollSettlement(token:token,point:point,completion:completion)
    }
    func sync<T>(_ task:@escaping(ThreadState)->T)->T {
        let semaphore=DispatchSemaphore(value:0);var result:T!
        async {state in result=task(state);semaphore.signal()};semaphore.wait();return result
    }
}

/// AppKit display and input forwarding only. It owns no Ultralight object.
@MainActor public final class HTMLPreviewView:NSView {
    public var verticalWheel:((NSEvent)->Void)?
    public var openURL:((URL,NSRect)->Void)?
    public var engineReady:(()->Void)?
    public var resourceFrame:((HTMLPreviewFrame)->Void)?
    public var scrollApplied:((NSPoint)->Void)?
    public private(set) var isEngineReady=false
    public private(set) var hasUncommittedPresentation=false
    private let renderer:HTMLRendererExecutor
    private var image:CGImage?
    private var imageSize:NSSize = .zero
    private var imageOffsetY:CGFloat=0
    private var pixels=Data()
    private var baseURL:URL?
    private var committedToken:Int?
    private var committedGeometry:HTMLPreviewGeometry?
    private var scrollSettlement:DispatchWorkItem?
    private var scrollGeneration=0
    private var horizontalGesture:Bool?
    private var axisReset:DispatchWorkItem?
    private static let processRenderer=HTMLRendererExecutor(
        sdkRoot:sdkRoot.path,css:HTMLPreviewResources.stylesheet,imageLoadDelay:imageLoadDelay)
    private static let imageLoadDelay:TimeInterval = {
        if let value=ProcessInfo.processInfo.environment["ASTRA_IMAGE_LOAD_DELAY_SECONDS"].flatMap(Double.init) {
            return max(0,value)
        }
        #if DEBUG
        let delayedChecks=["--integration-height-stability","--integration-delayed-image-stability",
            "--integration-delayed-image-bottom","--integration-delayed-image-bottom-untouched"]
        if delayedChecks.contains(where:CommandLine.arguments.contains) {return 5}
        #endif
        return 0
    }()
    #if DEBUG
    public private(set) var debugPaintedBitmapTop:CGFloat?
    public var debugScrollPublished:((NSPoint)->Void)?
    public var debugScrollSettled:((NSPoint)->Void)?
    public var debugDidDraw:(()->Void)?
    private var debugFailsNextPresentation=false
    #endif

    public override var isFlipped:Bool {true}
    public override var acceptsFirstResponder:Bool {true}
    public override init(frame:NSRect) {
        renderer=Self.processRenderer
        super.init(frame:frame);wantsLayer=true;setAccessibilityLabel("Markdown preview")
        renderer.ready={ [weak self] in guard let self else{return};self.isEngineReady=true;self.engineReady?() }
        renderer.resourceFrame={ [weak self] frame in self?.resourceFrame?(frame) }
    }
    required init?(coder:NSCoder) {fatalError()}
    deinit {scrollSettlement?.cancel();renderer.ready=nil;renderer.resourceFrame=nil}

    private static var sdkRoot:URL {
        if let value=ProcessInfo.processInfo.environment["ASTRA_ULTRALIGHT_SDK"] {return URL(fileURLWithPath:value)}
        if let resources=Bundle.main.resourceURL?.appendingPathComponent("Ultralight"),
           FileManager.default.fileExists(atPath:resources.appendingPathComponent("resources/icudt67l.dat").path) {return resources}
        let vendor=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Vendor/Ultralight")
        precondition(FileManager.default.fileExists(atPath:vendor.appendingPathComponent("resources/icudt67l.dat").path),
            "Ultralight runtime not found; bundle the runtime or set ASTRA_ULTRALIGHT_SDK")
        return vendor
    }

    public func requestLayout(_ request:HTMLPreviewRenderRequest,completion:@escaping(HTMLPreviewLayout?)->Void) {
        #if DEBUG
        if debugFailsNextPresentation {debugFailsNextPresentation=false;completion(nil);return}
        #endif
        hasUncommittedPresentation=true
        renderer.async {state in
            let layout=state.layout(request)
            DispatchQueue.main.async {completion(layout)}
        }
    }
    public func capture(token:Int,scrollPoint:NSPoint,completion:@escaping(HTMLPreviewFrame?)->Void) {
        renderer.async {state in
            let frame=state.capture(token:token,point:scrollPoint)
            DispatchQueue.main.async {completion(frame)}
        }
    }
    public func captureResource(token:Int,scrollPoint:NSPoint,completion:@escaping(HTMLPreviewFrame?)->Void) {
        renderer.async {state in
            let frame=state.captureResource(token:token,point:scrollPoint)
            DispatchQueue.main.async {completion(frame)}
        }
    }
    public func beginViewportGesture() {renderer.async{$0.viewportGestureActive=true}}
    public func endViewportGesture() {renderer.async{$0.viewportGestureActive=false}}
    public func publish(_ frame:HTMLPreviewFrame,preservePixels:Bool=false,
        preservedImageOffsetY:CGFloat=0) {
        if preservePixels {imageOffsetY=preservedImageOffsetY}
        else {pixels=frame.pixels;image=frame.image;imageSize=frame.imageSize;imageOffsetY=0}
        baseURL=frame.baseURL
        committedToken=frame.token;committedGeometry=frame.geometry;hasUncommittedPresentation=false;needsDisplay=true
    }
    public func discard(_ frame:HTMLPreviewFrame?) {hasUncommittedPresentation=false}
    public func geometry()->HTMLPreviewGeometry? {committedGeometry}
    public func elementRect(_ selector:String,containing text:String="")->NSRect? {
        guard let token=committedToken,!hasUncommittedPresentation else{return nil}
        return renderer.sync{$0.rect(selector,containing:text,token:token)}
    }
    public func scroll(to point:NSPoint) {
        guard let token=committedToken,!hasUncommittedPresentation else{return}
        scrollGeneration += 1
        let generation=scrollGeneration
        scrollSettlement?.cancel()
        renderer.scroll(token:token,point:point) { [weak self] result in
            self?.publish(result,token:token)
            #if DEBUG
            if result?.bitmap != nil {self?.debugScrollPublished?(point)}
            #endif
        }
        let settlement=DispatchWorkItem { [weak self] in
            guard let self,self.scrollGeneration==generation,self.committedToken==token else{return}
            self.renderer.settleScroll(token:token,point:point) { [weak self] result in
                guard let self,self.scrollGeneration==generation else{return}
                self.publish(result,token:token)
                #if DEBUG
                if result?.bitmap != nil {self.debugScrollSettled?(point)}
                #endif
            }
        }
        scrollSettlement=settlement
        DispatchQueue.main.asyncAfter(deadline:.now()+0.04,execute:settlement)
    }
    private func publish(_ result:HTMLPreviewPaintResult?,token:Int) {
        guard committedToken==token,!hasUncommittedPresentation,let result else{return}
        if let frame=result.frame {resourceFrame?(frame);return}
        guard let bitmap=result.bitmap else{return}
        scrollApplied?(result.scrollPoint)
        pixels=bitmap.pixels;image=bitmap.image;imageSize=bitmap.size;imageOffsetY=0;needsDisplay=true
    }

    public override func draw(_ dirtyRect:NSRect) {
        NSColor.textBackgroundColor.setFill();dirtyRect.fill()
        guard let image,let context=NSGraphicsContext.current?.cgContext else{return}
        context.saveGState();context.translateBy(x:0,y:imageOffsetY);let translationY=imageSize.height
        #if DEBUG
        debugPaintedBitmapTop=translationY-imageSize.height
        debugDidDraw?()
        #endif
        context.translateBy(x:0,y:translationY);context.scaleBy(x:1,y:-1)
        context.interpolationQuality = .none;context.draw(image,in:NSRect(origin:.zero,size:imageSize));context.restoreGState()
    }

    #if DEBUG
    public func debugFailNextPresentation() {debugFailsNextPresentation=true}
    public func debugToggleFirstDetails() {
        guard let token=committedToken,!hasUncommittedPresentation else{return}
        renderer.async { [weak self] state in
            let result=state.toggleFirstDetails(token:token)
            DispatchQueue.main.async {self?.publish(result,token:token)}
        }
    }
    public var debugText:String {
        guard let token=committedToken,!hasUncommittedPresentation else{return ""}
        return renderer.sync{$0.text(token:token)}
    }
    @objc public var benchmarkVisibleText:String {debugText}
    public func debugCount(_ selector:String)->Int {
        guard let token=committedToken,!hasUncommittedPresentation else{return 0}
        return renderer.sync{$0.count(selector,token:token)}
    }
    public func debugRect(_ selector:String,containing text:String="")->NSRect? {elementRect(selector,containing:text)}
    #endif

    public override func scrollWheel(with event:NSEvent) {
        axisReset?.cancel();axisReset=nil
        if event.phase.contains(.began) {horizontalGesture=nil}
        let phased = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        if phased,horizontalGesture==nil,event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            horizontalGesture=abs(event.scrollingDeltaX)>abs(event.scrollingDeltaY)
        }
        if horizontalGesture ?? (abs(event.scrollingDeltaX)>abs(event.scrollingDeltaY)) {
            if let token=committedToken,!hasUncommittedPresentation {
                let point=convert(event.locationInWindow,from:nil),delta=Int32(event.scrollingDeltaX)
                renderer.async { [weak self] state in
                    let result=state.horizontalScroll(delta,point:point,token:token)
                    DispatchQueue.main.async {self?.publish(result,token:token)}
                }
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
        guard let token=committedToken,!hasUncommittedPresentation else{return}
        let point=convert(event.locationInWindow,from:nil)
        renderer.async { [weak self] state in
            let result=state.mouse(type:type,point:point,button:button,token:token)
            DispatchQueue.main.async {self?.publish(result,token:token)}
        }
    }
    public override func mouseMoved(with event:NSEvent) {fireMouse(event,type:0,button:0)}
    public override func mouseDragged(with event:NSEvent) {fireMouse(event,type:0,button:1)}
    public override func mouseDown(with event:NSEvent) {window?.makeFirstResponder(self);fireMouse(event,type:1,button:1)}
    public override func mouseUp(with event:NSEvent) {
        fireMouse(event,type:2,button:1)
        guard let token=committedToken,!hasUncommittedPresentation else{return}
        let point=convert(event.locationInWindow,from:nil)
        renderer.async { [weak self] state in
            let link=state.link(at:point,token:token)
            DispatchQueue.main.async {
                guard let self,let (value,anchor)=link,self.committedToken==token,
                      let url=URL(string:value,relativeTo:self.baseURL)?.absoluteURL else{return}
                self.openURL?(url,anchor)
            }
        }
    }
    public override func rightMouseDown(with event:NSEvent) {
        fireMouse(event,type:1,button:3);NSMenu.popUpContextMenu(menu(for:event) ?? NSMenu(),with:event,for:self)
    }
    public override func rightMouseUp(with event:NSEvent) {fireMouse(event,type:2,button:3)}
    public override func menu(for event:NSEvent)->NSMenu? {
        let menu=NSMenu(),copy=NSMenuItem(title:"Copy",action:#selector(copySelection(_:)),keyEquivalent:"")
        copy.target=self;menu.addItem(copy);return menu
    }
    @objc private func copySelection(_ sender:Any?) {
        guard let token=committedToken,!hasUncommittedPresentation else{return}
        renderer.async {state in
            let value=state.selectedText(token:token)
            DispatchQueue.main.async {
                guard let value else{return}
                NSPasteboard.general.clearContents();NSPasteboard.general.setString(value,forType:.string)
            }
        }
    }
}
