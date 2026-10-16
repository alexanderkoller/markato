#if DEBUG
import AppKit
import HTMLPreview
import MarkdownCore
import PDFKit

/// Runs against an actual window and TextKit network, without modifying user documents.
@MainActor enum IntegrationCheck {
    // Document windows and their queued AppKit callbacks may outlive a check.
    // Keep isolated fixtures alive until the native test process exits.
    private static var fixtureDocuments=[MarkdownDocument]()
    private final class HeightTestScrollSource:ScrollSource {
        var contentRevision:Int
        var hasMeasuredLayout=true
        var geometryRevision=0
        var viewportOrigin:CGFloat
        var contentHeight:CGFloat=1800
        let sourceLength=42
        var visibleSourceRange:NSRange {
            let location=min(sourceLength-1,max(0,Int(viewportOrigin/contentHeight*CGFloat(sourceLength))))
            return NSRange(location:location,length:1)
        }
        var alignmentAnchor:Int {visibleSourceRange.location}
        init(revision:Int,origin:CGFloat) {contentRevision=revision;viewportOrigin=origin}
        func verticalPosition(for offset:Int)->CGFloat? {
            CGFloat(offset)/CGFloat(sourceLength)*contentHeight
        }
        func alignmentVerticalPosition(for offset:Int)->CGFloat? {verticalPosition(for:offset)}
    }
    private static func check(_ condition:@autoclosure()->Bool,_ message:String) {
        if !condition() { fail(message) }
    }
    private static func fail(_ message:String)->Never {
        FileHandle.standardError.write(Data("INTEGRATION FAILED: \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }
    private struct PixelCapture {
        let width:Int,height:Int,bytes:Data,png:Data,inkRows:[Int]
    }
    private static func capture(_ view:NSView,rect:NSRect? = nil)->PixelCapture {
        let region=rect ?? view.bounds
        guard let rep=view.bitmapImageRepForCachingDisplay(in:region) else {
            fail("Could not allocate visual resize capture")
        }
        view.cacheDisplay(in:region,to:rep)
        guard let pointer=rep.bitmapData,
              let png=rep.representation(using:.png,properties:[:]) else {
            fail("Could not encode visual resize capture")
        }
        // A vertical ink profile is insensitive to harmless color/antialias
        // repaint differences but makes even a one-line viewport jump obvious.
        // Sample every fourth horizontal pixel to keep the native integration
        // check cheap at Retina resolutions.
        var inkRows=[Int](repeating:0,count:rep.pixelsHigh)
        for y in 0..<rep.pixelsHigh {
            var ink=0
            for x in stride(from:0,to:rep.pixelsWide,by:4) {
                guard let color=rep.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else{continue}
                let luminance=0.2126*color.redComponent+0.7152*color.greenComponent+0.0722*color.blueComponent
                if color.alphaComponent>0.1 && luminance<0.86 {ink += 1}
            }
            inkRows[y]=ink
        }
        return PixelCapture(width:rep.pixelsWide,height:rep.pixelsHigh,
            bytes:Data(bytes:pointer,count:rep.bytesPerRow*rep.pixelsHigh),png:png,inkRows:inkRows)
    }
    private static func click(_ view:HTMLPreviewView,selector:String)->Bool {
        guard let rect=view.debugRect(selector),let window=view.window else{return false}
        let location=view.convert(NSPoint(x:rect.midX,y:rect.midY),to:nil)
        guard let down=NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:0,
                  windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1),
              let up=NSEvent.mouseEvent(with:.leftMouseUp,location:location,modifierFlags:[],timestamp:0.01,
                  windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:0) else{return false}
        view.mouseDown(with:down);view.mouseUp(with:up);return true
    }
    private static func clickSource(_ view:SourceTextView,at point:NSPoint)->Bool {
        guard let window=view.window else{return false}
        let location=view.convert(point,to:nil)
        guard let down=NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:0,
                  windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1),
              let up=NSEvent.mouseEvent(with:.leftMouseUp,location:location,modifierFlags:[],timestamp:0.01,
                  windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:0) else{return false}
        NSApp.postEvent(up,atStart:true)
        view.mouseDown(with:down)
        return true
    }
    private static func visualVerticalShift(_ before:PixelCapture,_ after:PixelCapture,maxShift:Int=160)->Int? {
        guard before.width==after.width,before.height==after.height,before.inkRows.count==after.inkRows.count else{return nil}
        var best:(shift:Int,error:Double)?
        for shift in -maxShift...maxShift {
            let start=max(12,-shift+12),end=min(before.height-12,after.height-shift-12)
            guard end>start else{continue}
            var error=0.0,weight=0.0
            for y in start..<end {
                let a=before.inkRows[y],b=after.inkRows[y+shift]
                error += Double(abs(a-b));weight += Double(max(1,a+b))
            }
            let normalized=error/weight
            if best == nil || normalized<best!.error {best=(shift,normalized)}
        }
        return best?.shift
    }
    private static var visualResizeOutput:String? {
        CommandLine.arguments.first(where:{$0.hasPrefix("--visual-resize-output=")}).map {
            String($0.dropFirst("--visual-resize-output=".count))
        }
    }
    private static var commentsScreenshotOutput:String? {
        CommandLine.arguments.first(where:{$0.hasPrefix("--comments-screenshot-output=")}).map {
            String($0.dropFirst("--comments-screenshot-output=".count))
        }
    }
    private static func writeVisualCapture(_ capture:PixelCapture,suffix:String) {
        guard let base=visualResizeOutput else{return}
        try? capture.png.write(to:URL(fileURLWithPath:"\(base)-\(suffix).png"))
    }
    static func run(_ document:MarkdownDocument) {
        guard let controller=document.windowControllers.first as? EditorWindowController else {fail("Missing editor window")}
        check(!MarkdownDocument.autosavesInPlace,"Markdown documents must require an explicit save")
        check(controller.window?.isRestorable == false,"Document windows must not be restored across launches")
        guard let sampleURL=Bundle.main.url(forResource:"Example",withExtension:"md") else{fail("Missing example document")}
        var restorationRefused=false
        NSDocumentController.shared.reopenDocument(for:sampleURL,withContentsOf:sampleURL,display:false) {restored,_,error in
            restorationRefused = restored == nil && (error as? NSError)?.code == NSUserCancelledError
        }
        check(restorationRefused,"The document controller must refuse saved-state document restoration")
        check(DocumentOpenOrigin.inApplication.animationBehavior == .none
                && !DocumentOpenOrigin.inApplication.displaysWhileOpening,
            "File Open must suppress animation before presenting its document window")
        check(DocumentOpenOrigin.external.animationBehavior == .default
                && DocumentOpenOrigin.external.displaysWhileOpening,
            "Finder document requests must retain AppKit's default window animation")
        let openItem=NSApp.mainMenu?.item(withTitle:"File")?.submenu?.item(withTitle:"Open…")
        check(openItem?.action == #selector(AppDelegate.openDocument(_:)) && openItem?.target === NSApp.delegate,
            "File Open must route through the in-application presentation path")
        let recentItem=NSApp.mainMenu?.item(withTitle:"File")?.submenu?.item(withTitle:"Open Recent")
        let recentMenu=recentItem?.submenu
        check(recentMenu?.delegate === NSApp.delegate,
            "Open Recent must be maintained by Markato's controlled presentation path")
        check(recentMenu?.items.last?.action == #selector(NSDocumentController.clearRecentDocuments(_:))
                && recentMenu?.items.last?.target === NSDocumentController.shared,
            "Open Recent must provide the standard Clear Menu action")
        if CommandLine.arguments.contains("--integration-empty-edits") {
            verifyEmptyDocumentEdits(controller,document:document);return
        }
        if CommandLine.arguments.contains("--integration-highlighting") {
            verifyHighlighting(controller,document:document);return
        }
        if CommandLine.arguments.contains("--integration-mermaid") {
            verifyMermaid(controller,document:document);return
        }
        if CommandLine.arguments.contains("--integration-layout-index") {
            verifyLayoutIndex();return
        }
        if CommandLine.arguments.contains("--integration-outline") {
            verifyOutline(controller,document:document);return
        }
        if CommandLine.arguments.contains("--integration-comments") {
            verifyComments(controller,document:document);return
        }
        if CommandLine.arguments.contains("--integration-comment-edit-stability") {
            verifyCommentEditStability(controller,document:document);return
        }
        if CommandLine.arguments.contains("--integration-paragraph-edit-stability") {
            verifyParagraphEditStability(controller,document:document);return
        }
        if CommandLine.arguments.contains("--integration-height-stability") {
            verifyAsyncHeightStability(controller);return
        }
        if CommandLine.arguments.contains("--integration-delayed-image-stability") {
            verifySampleDelayedImageStability(controller,document:document);return
        }
        if CommandLine.arguments.contains("--integration-delayed-image-bottom") {
            verifySampleDelayedImageBottom(controller,document:document,clickBeforeEnd:true);return
        }
        if CommandLine.arguments.contains("--integration-delayed-image-bottom-untouched") {
            verifySampleDelayedImageBottom(controller,document:document,clickBeforeEnd:false);return
        }
        if CommandLine.arguments.contains("--integration-scroll-throughput") {
            verifyScrollThroughput(controller);return
        }
        if CommandLine.arguments.contains("--integration-preview-jump") {
            let started=DispatchTime.now().uptimeNanoseconds
            func awaitComplete(_ remaining:Int) {
                guard remaining>0 else{fail("Complete preview did not become ready: \(controller.preview.debugGeometry())")}
                guard controller.hasPreparedDocument,controller.preview.displaysCompleteDocument,
                      controller.preview.lastRevision==document.revision else {
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.001){awaitComplete(remaining-1)};return
                }
                let frame=controller.preview.committedFrameID
                let positions=[0,document.source.count/4,document.source.count/2,
                    document.source.count*3/4,document.source.count]
                func jump(_ index:Int) {
                    guard index<positions.count else {
                        print("PREVIEW JUMP READY: \(Double(DispatchTime.now().uptimeNanoseconds-started)/1e6) ms, fullCache=\(controller.hasPreparedDocument), \(controller.preview.debugGeometry())")
                        try? TimingDiagnostics.shared.snapshot().json().write(to:URL(fileURLWithPath:"/private/tmp/markato-preview-jump-timings.json"))
                        exit(EXIT_SUCCESS)
                    }
                    controller.source.reveal(positions[index],alignTop:index==0)
                    check(controller.preview.displaysCompleteDocument,
                        "A deep scroll replaced the complete preview presentation")
                    check(!controller.preview.isShowingLoadingState,
                        "A deep scroll exposed Loading preview after background completion")
                    check(controller.preview.committedFrameID==frame,
                        "A deep scroll rendered a replacement presentation instead of using lookup")
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.01){jump(index+1)}
                }
                jump(0)
            }
            awaitComplete(3000);return
        }
        verifyUltralightPreview(controller,document:document)
    }

    private static func verifyScrollThroughput(_ controller:EditorWindowController) {
        let preview=controller.preview
        let source=controller.source
        func wait(_ remaining:Int,_ ready:@escaping()->Bool,_ failure:String,_ completion:@escaping()->Void) {
            guard remaining>0 else{fail("\(failure): \(preview.debugGeometry())")}
            if ready() {completion()}
            else {DispatchQueue.main.asyncAfter(deadline:.now()+0.01){wait(remaining-1,ready,failure,completion)}}
        }
        // Exercise steady-state scrolling: the complete retained document and
        // its intentionally delayed sample image must both be settled first.
        wait(900,{controller.hasPreparedDocument && preview.displaysCompleteDocument &&
            preview.previewView.debugCount("img[data-astra-delayed-src]")==0},
            "Steady-state preview did not become ready") {
            var publications=[UInt64]()
            var draws=[UInt64]()
            var lastPoint:NSPoint?
            preview.previewView.debugScrollPublished={point in
                publications.append(DispatchTime.now().uptimeNanoseconds);lastPoint=point
            }
            preview.previewView.debugDidDraw={draws.append(DispatchTime.now().uptimeNanoseconds)}
            source.reveal(0,alignTop:true)
            wait(300,{abs(preview.visibleWebRange.lowerBound)<0.01 &&
                preview.debugScrollMapError.map{abs($0)<1}==true},
                "Preview did not reach the scroll benchmark start") {
                publications.removeAll(keepingCapacity:true)
                draws.removeAll(keepingCapacity:true)
                lastPoint=nil
                let started=DispatchTime.now().uptimeNanoseconds
                let frequency=max(1,CommandLine.arguments.first(where:{$0.hasPrefix("--integration-scroll-hz=")})
                    .flatMap{Int($0.dropFirst("--integration-scroll-hz=".count))} ?? 60)
                let steps=frequency*2
                let period=UInt64(1_000_000_000/frequency)
                source.beginScrollGesture()
                @MainActor func step(_ index:Int) {
                    guard index<steps else {
                        let gestureEnded=DispatchTime.now().uptimeNanoseconds
                        source.endScrollGesture()
                        let expected=preview.visibleWebRange.lowerBound
                        wait(400,{lastPoint.map{abs($0.y-expected)<0.01}==true &&
                            preview.debugScrollMapError.map{abs($0)<1}==true},
                            "Preview did not settle at the latest source viewport " +
                            "(expected=\(expected), published=\(String(describing:lastPoint?.y)), " +
                            "mapError=\(String(describing:preview.debugScrollMapError)))") {
                            preview.previewView.debugScrollPublished=nil
                            preview.previewView.debugDidDraw=nil
                            let elapsed=Double(gestureEnded-started)/1e9
                            let active=publications.filter{$0>=started && $0<=gestureEnded}
                            let activeDraws=draws.filter{$0>=started && $0<=gestureEnded}
                            let timeline=[started]+active+[gestureEnded]
                            let gaps=zip(timeline,timeline.dropFirst()).map{Double($1-$0)/1e9}
                            let longestGap=gaps.max() ?? elapsed
                            let rate=Double(active.count)/elapsed
                            let drawTimeline=[started]+activeDraws+[gestureEnded]
                            let drawGaps=zip(drawTimeline,drawTimeline.dropFirst()).map{Double($1-$0)/1e9}
                            let longestDrawGap=drawGaps.max() ?? elapsed
                            let drawRate=Double(activeDraws.count)/elapsed
                            check(active.count>=30,
                                "Preview published only \(active.count) frames during sustained source scrolling (\(rate) fps)")
                            check(activeDraws.count>=30,
                                "Preview drew only \(activeDraws.count) frames during sustained source scrolling (\(drawRate) fps)")
                            check(longestGap<0.1 && longestDrawGap<0.1,
                                "Preview stalled during sustained source scrolling " +
                                "(publication \(longestGap) s, draw \(longestDrawGap) s)")
                            print(String(format:
                                "SCROLL THROUGHPUT PASSED: %d publications (%.1f fps), %d draws (%.1f fps), " +
                                "longest gaps %.1f/%.1f ms",
                                active.count,rate,activeDraws.count,drawRate,longestGap*1000,longestDrawGap*1000))
                            exit(EXIT_SUCCESS)
                        }
                        return
                    }
                    source.debugScrollViewport(by:18)
                    DispatchQueue.main.asyncAfter(
                        deadline:DispatchTime(uptimeNanoseconds:started+UInt64(index+1)*period)) {
                        step(index+1)
                    }
                }
                step(0)
            }
        }
    }

    private static func verifySampleDelayedImageStability(_ controller:EditorWindowController,
        document:MarkdownDocument) {
        let preview=controller.preview
        let targetHeading="Section 05 — observing a changing landscape"
        let range=(document.source.string as NSString).range(of:targetHeading)
        check(range.location != NSNotFound,"Sample delayed-image heading is missing")
        func wait(_ remaining:Int,_ ready:@escaping()->Bool,_ failure:String,_ completion:@escaping()->Void) {
            guard remaining>0 else{fail("\(failure): \(preview.debugGeometry())")}
            if ready() {completion()}
            else {DispatchQueue.main.asyncAfter(deadline:.now()+0.01){wait(remaining-1,ready,failure,completion)}}
        }
        wait(500,{controller.hasPreparedDocument && preview.displaysCompleteDocument &&
            preview.previewView.debugCount("img[data-astra-delayed-src]")>0},
            "Complete sample placeholder did not become ready") {
            var publishedScrollPoint:NSPoint?
            preview.previewView.debugScrollSettled={publishedScrollPoint=$0}
            controller.source.reveal(range.location,alignTop:true)
            wait(300,{publishedScrollPoint.map{abs($0.y-preview.visibleWebRange.lowerBound)<0.01}==true &&
                preview.debugScrollMapError.map{abs($0)<0.01}==true},
                "Sample did not settle below its delayed image") {
                preview.previewView.debugScrollSettled=nil
                let visibleHeadings=(4...10).compactMap { index -> (String,CGFloat)? in
                    let value=String(format:"Section %02d — observing a changing landscape",index)
                    guard let y=preview.debugHeadingViewportY(containing:value),
                          y>35,y<preview.bounds.height-35 else{return nil}
                    return (value,y)
                }
                guard let (heading,headingY)=visibleHeadings.first else {
                    fail("Sample delayed-image viewport contains no test heading")
                }
                let region=NSRect(x:20,y:headingY-28,width:max(1,preview.bounds.width-60),height:56)
                let before=capture(preview,rect:region)
                let beforeFrame=preview.committedFrameID
                let beforeOrigin=preview.clipOrigin
                var commits=[PixelCapture]()
                var commitOrigins=[CGFloat](),commitHeadingYs=[CGFloat]()
                preview.debugPresentationCommitted={
                    if preview.committedFrameID>beforeFrame {
                        commits.append(capture(preview,rect:region))
                        commitOrigins.append(preview.clipOrigin)
                        commitHeadingYs.append(preview.debugHeadingViewportY(containing:heading) ?? .nan)
                    }
                }
                wait(800,{preview.committedFrameID>beforeFrame &&
                    preview.previewView.debugCount("img[data-astra-delayed-src]")==0},
                    "Sample delayed image did not finish") {
                    preview.debugPresentationCommitted=nil
                    check(!commits.isEmpty,"Sample delayed image produced no observable commit")
                    for (index,frame) in commits.enumerated() {
                        guard let shift=visualVerticalShift(before,frame,maxShift:80) else {
                            fail("Could not compare sample image frame \(index)")
                        }
                        check(abs(shift)<=1,
                            "Sample delayed image shifted the viewport by \(shift) px in frame \(index); " +
                            "origin \(beforeOrigin) -> \(commitOrigins[index]), heading \(headingY) -> \(commitHeadingYs[index])")
                    }
                    guard let afterY=preview.debugHeadingViewportY(containing:heading) else {
                        fail("Sample heading disappeared after delayed image load")
                    }
                    check(abs(afterY-headingY)<1,
                        "Sample delayed image changed the heading position from \(headingY) to \(afterY)")
                    verifyCoalescedScroll(preview,heading:heading,headingY:afterY) {
                        print("SAMPLE DELAYED IMAGE STABILITY PASSED: \(commits.count) committed frame(s) stayed fixed")
                        exit(EXIT_SUCCESS)
                    }
                }
            }
        }
    }

    private static func verifySampleDelayedImageBottom(_ controller:EditorWindowController,
        document:MarkdownDocument,clickBeforeEnd:Bool) {
        let preview=controller.preview
        let marker="End of the example"
        func wait(_ remaining:Int,_ ready:@escaping()->Bool,_ failure:String,_ completion:@escaping()->Void) {
            guard remaining>0 else{fail("\(failure): \(preview.debugGeometry())")}
            if ready() {completion()}
            else {DispatchQueue.main.asyncAfter(deadline:.now()+0.01){wait(remaining-1,ready,failure,completion)}}
        }
        guard let window=controller.window else{fail("Missing integration window")}
        var settled:NSPoint?
        preview.previewView.debugScrollSettled={settled=$0}
        func jumpToEnd(clickFirst:Bool) {
            check(window.makeFirstResponder(controller.source.textView),
                "Could not focus the source editor before Cmd-End")
            if clickFirst {
                check(clickSource(controller.source.textView,at:NSPoint(x:80,y:80)),
                    "Could not synthesize the source click before Cmd-End")
            }
            controller.source.textView.moveToEndOfDocument(nil)
        }
        // The untouched path models a command sent as soon as the document
        // window opens, before a first preview presentation or placeholder is
        // available. Clicking first naturally moves this command later.
        if !clickBeforeEnd,controller.source.selection.location != document.source.count {
            jumpToEnd(clickFirst:false)
        }
        wait(500,{controller.hasPreparedDocument &&
            preview.previewView.debugCount("img[data-astra-delayed-src]")>0},
            "Sample placeholder did not become ready for early end navigation") {
            if clickBeforeEnd {
                // Let the click's deferred selection callback run before the
                // responder command, as it does for a real click then keypress.
                DispatchQueue.main.async {jumpToEnd(clickFirst:true)}
            }
            wait(500,{preview.displaysCompleteDocument &&
                controller.source.selection.location==document.source.count &&
                settled.map{abs($0.y-preview.visibleWebRange.lowerBound)<0.01}==true &&
                abs(preview.clipOrigin-preview.debugMaximumOrigin)<0.01},
                "Cmd-End did not settle at the document boundary") {
                preview.previewView.debugScrollSettled=nil
                guard let beforeY=preview.debugHeadingViewportY(containing:marker) else {
                    fail("End marker is not mounted after Cmd-End")
                }
                let region=NSRect(x:20,y:max(0,beforeY-30),width:max(1,preview.bounds.width-60),
                    height:min(90,preview.bounds.height-max(0,beforeY-30)))
                let before=capture(preview,rect:region)
                let beforeFrame=preview.committedFrameID
                let beforeMaximum=preview.debugMaximumOrigin
                var observations=[(origin:CGFloat,maximum:CGFloat,y:CGFloat,pixels:PixelCapture)]()
                preview.debugPresentationCommitted={
                    guard preview.committedFrameID>beforeFrame,
                          let y=preview.debugHeadingViewportY(containing:marker) else{return}
                    observations.append((preview.clipOrigin,preview.debugMaximumOrigin,y,
                        capture(preview,rect:region)))
                }
                wait(800,{preview.committedFrameID>beforeFrame &&
                    preview.previewView.debugCount("img[data-astra-delayed-src]")==0},
                    "Delayed image did not finish while pinned at the end") {
                    preview.debugPresentationCommitted=nil
                    check(!observations.isEmpty,"Delayed image produced no end-viewport commit")
                    for (index,observation) in observations.enumerated() {
                        check(observation.maximum>=observation.origin,
                            "Bottom commit \(index) exceeded the scrollbar maximum: " +
                            "origin=\(observation.origin), maximum=\(observation.maximum)")
                        check(observation.maximum>beforeMaximum,
                            "Delayed image did not increase the retained document extent")
                        check(abs(observation.y-beforeY)<0.01,
                            "Bottom commit \(index) moved the end marker from \(beforeY) to \(observation.y)")
                        guard let shift=visualVerticalShift(before,observation.pixels,maxShift:12) else {
                            fail("Could not compare end-viewport image frame \(index)")
                        }
                        check(shift==0,
                            "Bottom commit \(index) shifted visible pixels by \(shift) px")
                        if before.bytes != observation.pixels.bytes {
                            try? before.png.write(to:URL(fileURLWithPath:"/tmp/astra-bottom-before.png"))
                            try? observation.pixels.png.write(to:URL(fileURLWithPath:"/tmp/astra-bottom-after.png"))
                            fail("Bottom commit \(index) changed the end-marker glyph pixels without moving its geometry")
                        }
                    }
                    preview.moveViewport()
                    guard let afterY=preview.debugHeadingViewportY(containing:marker) else {
                        fail("End marker disappeared after source alignment")
                    }
                    guard let committedOrigin=observations.last?.origin else {
                        fail("Missing the final delayed-image observation")
                    }
                    check(abs(preview.clipOrigin-committedOrigin)<0.01,
                        "Source alignment snapped the stable viewport from \(committedOrigin) " +
                        "to \(preview.clipOrigin)")
                    check(abs(afterY-beforeY)<0.01,
                        "Source alignment moved the bottom viewport from \(beforeY) to \(afterY)")
                    // A focused NSTextView can settle its clip origin after
                    // the resource commit to keep the active insertion point
                    // visible. That is not a new scroll/navigation request and
                    // must not release the resource-settlement anchor.
                    controller.source.debugApplyPassiveViewportCorrection(by:-0.25)
                    window.displayIfNeeded()
                    guard let correctedY=preview.debugHeadingViewportY(containing:marker) else {
                        fail("End marker disappeared after passive source clip correction")
                    }
                    check(abs(correctedY-beforeY)<0.01,
                        "Passive focused-source correction moved the bottom viewport from " +
                        "\(beforeY) to \(correctedY)")
                    let corrected=capture(preview,rect:region)
                    guard let correctionShift=visualVerticalShift(before,corrected,maxShift:12) else {
                        fail("Could not compare the passive source-correction frame")
                    }
                    check(correctionShift==0,
                        "Passive focused-source correction shifted visible pixels by \(correctionShift) px")
                    var samplesRemaining=60
                    @MainActor func verifyPostCommitStability() {
                        window.displayIfNeeded()
                        guard let sampledY=preview.debugHeadingViewportY(containing:marker) else {
                            fail("End marker disappeared during post-commit display settlement")
                        }
                        check(abs(sampledY-beforeY)<0.01,
                            "A post-commit callback moved the focused Cmd-End viewport from \(beforeY) to \(sampledY)")
                        let sampled=capture(preview,rect:region)
                        guard let shift=visualVerticalShift(before,sampled,maxShift:12) else {
                            fail("Could not compare a post-commit focused-source frame")
                        }
                        check(shift==0,"A post-commit callback shifted visible pixels by \(shift) px")
                        samplesRemaining -= 1
                        if samplesRemaining>0 {
                            DispatchQueue.main.asyncAfter(deadline:.now()+0.01) {verifyPostCommitStability()}
                        } else {
                            let lockedOrigin=preview.clipOrigin
                            preview.beginScrollGesture()
                            controller.source.debugScrollViewport(by:-40)
                            preview.endScrollGesture()
                            wait(200,{preview.debugScrollMapError.map{abs($0)<0.01}==true &&
                                preview.clipOrigin<lockedOrigin-1},
                                "Explicit source scroll did not release the resource-settlement anchor") {
                                let path=clickBeforeEnd ? "clicked source":"untouched startup source"
                                print("DELAYED IMAGE BOTTOM PASSED: \(path) Cmd-End stayed exact through \(observations.count) resource commit(s), passive source correction, and explicit-scroll release")
                                exit(EXIT_SUCCESS)
                            }
                        }
                    }
                    verifyPostCommitStability()
                }
            }
        }
    }

    private static func verifyCoalescedScroll(_ preview:PreviewPane,heading:String,headingY:CGFloat,
        completion:@escaping()->Void) {
        let distance=min(120,max(40,headingY-70))
        let regionSize=NSSize(width:max(1,preview.bounds.width-60),height:48)
        let before=capture(preview,rect:NSRect(
            x:20,y:headingY-regionSize.height/2,width:regionSize.width,height:regionSize.height))
        var published=[NSPoint]()
        var settled:NSPoint?
        preview.previewView.debugScrollPublished={published.append($0)}
        preview.previewView.debugScrollSettled={settled=$0}
        for _ in 0..<40 {preview.debugScrollViewport(by:distance/40)}
        let expected=preview.visibleWebRange.lowerBound
        func awaitLatest(_ remaining:Int) {
            guard remaining>0 else {fail("Coalesced scroll did not publish its latest position: \(preview.debugGeometry())")}
            guard settled.map({abs($0.y-expected)<0.01}) == true else {
                DispatchQueue.main.asyncAfter(deadline:.now()+0.005){awaitLatest(remaining-1)};return
            }
            preview.previewView.debugScrollPublished=nil
            preview.previewView.debugScrollSettled=nil
            check(published.allSatisfy{abs($0.y-expected)<0.01},
                "A superseded scroll bitmap was published during a coalesced scroll burst: \(published)")
            guard let afterY=preview.debugHeadingViewportY(containing:heading) else {
                fail("Coalesced scroll lost its reference heading")
            }
            check(abs((headingY-afterY)-distance)<1,
                "Coalesced scroll moved the DOM by \(headingY-afterY), expected \(distance)")
            let after=capture(preview,rect:NSRect(
                x:20,y:afterY-regionSize.height/2,width:regionSize.width,height:regionSize.height))
            guard let shift=visualVerticalShift(before,after,maxShift:12) else {
                fail("Could not compare coalesced-scroll pixels")
            }
            check(abs(shift)<=1,
                "Coalesced scroll published pixels displaced by \(shift) px from the DOM")
            completion()
        }
        awaitLatest(400)
    }

    private static func verifyAsyncHeightStability(_ controller:EditorWindowController) {
        let preview=controller.preview
        preview.preparedDocument=nil
        preview.scrolling = .independent

        func wait(_ remaining:Int,_ ready:@escaping()->Bool,_ failure:String,_ completion:@escaping()->Void) {
            guard remaining>0 else{fail("\(failure): \(preview.debugGeometry())")}
            if ready() {completion()}
            else {DispatchQueue.main.asyncAfter(deadline:.now()+0.01){wait(remaining-1,ready,failure,completion)}}
        }
        func runScenario(revision:Int,duringGesture:Bool,completion:@escaping()->Void) {
            let scrollSource=HeightTestScrollSource(revision:revision,origin:160)
            preview.scrolling = duringGesture ? .synchronized(scrollSource):.independent
            let initiallyOpen=duringGesture
            let details=RenderedEntry(id:BlockID(UInt64(revision*100)),fragment:.init(kind:"RawHTML",from:0,to:1,
                html:"<details\(initiallyOpen ? " open":"")><summary>Expandable block</summary><div style=\"height:360px\">Expanded body</div></details>",
                id:"details-\(revision)"))
            var entries=[details]
            for index in 0..<40 {
                let marker=index==4 ? "Stable viewport marker \(revision)":"Filler paragraph \(revision)-\(index)"
                entries.append(RenderedEntry(id:BlockID(UInt64(revision*100+index+1)),fragment:.init(kind:"Paragraph",
                    from:index+2,to:index+3,html:"<p>\(marker)</p>",id:"p-\(revision)-\(index)")))
            }
            preview.show(entries,revision:revision,sourceRange:NSRange(location:0,length:entries.count))
            let marker="Stable viewport marker \(revision)"
            wait(500,{preview.lastRevision==revision && preview.debugParagraphViewportY(containing:marker) != nil},
                "Height-change fixture did not publish its collapsed layout") {
                if duringGesture {
                    let startOrigin=preview.clipOrigin,beforeFrame=preview.committedFrameID
                    var committedOrigins=[CGFloat]()
                    preview.debugPresentationCommitted={
                        if preview.displayedDocumentRevision==revision {committedOrigins.append(preview.clipOrigin)}
                    }
                    preview.beginScrollGesture()
                    scrollSource.viewportOrigin=620;preview.moveViewport()
                    check(preview.clipOrigin>startOrigin+100,
                        "Synthetic momentum did not advance the synchronized preview")
                    scrollSource.contentHeight=1980;scrollSource.geometryRevision += 1
                    preview.sourceLayoutChanged()
                    check(preview.debugMapGeometryRevision==scrollSource.geometryRevision,
                        "Source geometry refinement left a stale map active during momentum")
                    check(preview.debugScrollMapError.map{abs($0)<0.01}==true,
                        "Source geometry refinement desynchronized the preview during momentum")
                    preview.previewView.debugToggleFirstDetails()
                    wait(500,{(preview.previewView.debugRect("details")?.height ?? 100)<100},
                        "Element did not shrink during momentum") {
                        check(preview.committedFrameID==beforeFrame,
                            "A height-change frame committed in the middle of a scroll gesture")
                        scrollSource.viewportOrigin=760;preview.moveViewport()
                        let gestureEndOrigin=preview.clipOrigin
                        check(gestureEndOrigin>startOrigin+150,
                            "Momentum stopped before reaching its final source position")
                        preview.endScrollGesture()
                        wait(500,{preview.committedFrameID>beforeFrame &&
                            preview.debugScrollMapError.map{abs($0)<0.01}==true},
                            "Gesture-end height change did not settle at the final source position") {
                            preview.debugPresentationCommitted=nil
                            guard let committedOrigin=committedOrigins.last else {
                                fail("Deferred height change did not commit a frame")
                            }
                            check(abs(committedOrigin-preview.clipOrigin)<0.01,
                                "Gesture end exposed an intermediate jump before final source alignment")
                            check(gestureEndOrigin>startOrigin,
                                "Gesture-end reconciliation reversed the completed momentum")
                            completion()
                        }
                    }
                    return
                }
                guard let documentY=preview.debugParagraphViewportY(containing:marker) else {
                    fail("Missing height-change viewport marker")
                }
                // Force a non-integral logical origin. Ultralight may quantize
                // its painted scroll point, but an element-height correction
                // must preserve this fractional native viewport coordinate.
                var fractionalScrollSettled:NSPoint?
                preview.previewView.debugScrollSettled={fractionalScrollSettled=$0}
                preview.debugScrollViewport(by:max(0,documentY-48)+0.1875)
                let fractionalOrigin=preview.clipOrigin
                wait(300,{fractionalScrollSettled != nil},
                    "Fractional baseline scroll did not settle") {
                    preview.previewView.debugScrollSettled=nil
                    check(abs(preview.clipOrigin-fractionalOrigin)<0.01,
                        "Fractional baseline changed its logical origin while settling")
                    guard let beforeY=preview.debugParagraphViewportY(containing:marker),
                          let beforeDetails=preview.previewView.debugRect("details")?.height else {
                        fail("Could not capture collapsed element geometry")
                    }
                    let pixelRegion=NSRect(x:20,y:beforeY-28,
                        width:max(1,preview.bounds.width-60),height:56)
                    let beforePixels=capture(preview,rect:pixelRegion)
                    let beforeOrigin=preview.clipOrigin,beforeFrame=preview.committedFrameID
                    var committedY=[CGFloat]()
                    preview.debugPresentationCommitted={
                        if preview.displayedDocumentRevision==revision,
                           let y=preview.debugParagraphViewportY(containing:marker) {committedY.append(y)}
                    }
                    preview.previewView.debugToggleFirstDetails()
                    wait(500,{
                        guard let height=preview.previewView.debugRect("details")?.height else{return false}
                        return initiallyOpen ? height<100:height>300
                    },"Element height did not change") {
                        wait(500,{preview.committedFrameID>beforeFrame},
                            "Element height change did not publish a replacement frame") {
                            preview.debugPresentationCommitted=nil
                            guard let afterY=preview.debugParagraphViewportY(containing:marker),
                                  let afterDetails=preview.previewView.debugRect("details")?.height else {
                                fail("Missing expanded element geometry")
                            }
                            let growth=afterDetails-beforeDetails
                            check(abs(growth)>300,"Fixture did not materially change element height")
                            check(abs(afterY-beforeY)<0.01,
                                "Element height change jumped the visible viewport: before=\(beforeY), after=\(afterY)")
                            check(abs((preview.clipOrigin-beforeOrigin)-growth)<0.01,
                                "Viewport compensation did not match element growth")
                            check(committedY.allSatisfy{abs($0-beforeY)<0.01},
                                "An intermediate height-change frame exposed a viewport jump")
                            let afterPixels=capture(preview,rect:pixelRegion)
                            check(beforePixels.bytes==afterPixels.bytes,
                                "Fractionally anchored text changed rasterization despite stable geometry")
                            completion()
                        }
                    }
                }
            }
        }
        func runDelayedImageScenario(completion:@escaping()->Void) {
            let revision=9003
            guard let imageURL=Bundle.main.url(forResource:"ExampleImage",withExtension:"png") else {
                fail("Missing delayed-image fixture")
            }
            let scrollSource=HeightTestScrollSource(revision:revision,origin:420)
            preview.scrolling = .synchronized(scrollSource)
            let image=RenderedEntry(id:BlockID(900300),fragment:.init(kind:"RawHTML",from:0,to:1,
                html:"<img src=\"\(imageURL.absoluteString)\" width=\"640\" alt=\"Delayed image\">",
                id:"delayed-image"))
            var entries=[image]
            for index in 0..<40 {
                let marker=index==10 ? "Delayed image viewport marker":"Delayed filler \(index)"
                entries.append(RenderedEntry(id:BlockID(UInt64(900301+index)),fragment:.init(kind:"Paragraph",
                    from:index+2,to:index+3,html:"<p>\(marker)</p>",id:"delayed-p-\(index)")))
            }
            preview.show(entries,revision:revision,sourceRange:NSRange(location:0,length:entries.count))
            wait(500,{preview.lastRevision==revision &&
                preview.debugParagraphViewportY(containing:"Delayed image viewport marker") != nil},
                "Delayed-image fixture did not publish its placeholder") {
                var published:NSPoint?
                preview.previewView.debugScrollSettled={published=$0}
                preview.beginScrollGesture()
                scrollSource.viewportOrigin -= 40
                preview.moveViewport()
                preview.endScrollGesture()
                wait(300,{published.map{abs($0.y-preview.visibleWebRange.lowerBound)<0.01}==true},
                    "Delayed-image fixture did not publish its baseline scroll") {
                    preview.previewView.debugScrollSettled=nil
                    guard let beforeY=preview.debugParagraphViewportY(containing:"Delayed image viewport marker"),
                          let beforeHeight=preview.previewView.debugRect("img")?.height else {
                        fail("Could not capture delayed-image placeholder geometry")
                    }
                    check(beforeY>40 && beforeY<preview.bounds.height-40,
                        "Delayed-image marker is not inside the test viewport")
                    let pixelRegion=NSRect(x:20,y:beforeY-35,width:max(1,preview.bounds.width-60),height:70)
                    let beforePixels=capture(preview,rect:pixelRegion)
                    let sourceOrigin=scrollSource.viewportOrigin
                    let beforeFrame=preview.committedFrameID
                    var pixelsAtCommit:PixelCapture?
                    preview.debugPresentationCommitted={
                        if preview.displayedDocumentRevision==revision,
                           preview.committedFrameID>beforeFrame,pixelsAtCommit==nil {
                            pixelsAtCommit=capture(preview,rect:pixelRegion)
                        }
                    }
                    wait(900,{
                        preview.committedFrameID>beforeFrame &&
                        (preview.previewView.debugRect("img")?.height ?? 0)>beforeHeight+100
                    },"Delayed image did not load and publish its height change (beforeHeight=\(beforeHeight), " +
                        "beforeFrame=\(beforeFrame))") {
                        preview.debugPresentationCommitted=nil
                        guard let afterY=preview.debugParagraphViewportY(containing:"Delayed image viewport marker") else {
                            fail("Delayed image displaced the viewport marker out of the presentation")
                        }
                        check(scrollSource.viewportOrigin==sourceOrigin,
                            "Delayed image changed the source viewport")
                        check(abs(afterY-beforeY)<1,
                            "Delayed image load jumped the visible preview: before=\(beforeY), after=\(afterY)")
                        guard let pixelsAtCommit else {fail("Delayed image did not expose its atomic commit")}
                        guard let pixelShift=visualVerticalShift(beforePixels,pixelsAtCommit,maxShift:60) else {
                            fail("Could not compare delayed-image commit pixels")
                        }
                        check(abs(pixelShift)<=1,
                            "Delayed image published pixels shifted by \(pixelShift) px at commit")
                        // Exercise the callback that previously discarded the
                        // one-frame anchor and remapped the unchanged source.
                        preview.moveViewport()
                        guard let settledY=preview.debugParagraphViewportY(containing:"Delayed image viewport marker") else {
                            fail("Delayed image lost the marker after source alignment")
                        }
                        check(abs(settledY-beforeY)<1,
                            "Post-load source alignment discarded viewport stability: before=\(beforeY), after=\(settledY)")
                        completion()
                    }
                }
            }
        }
        runScenario(revision:9001,duringGesture:false) {
            runScenario(revision:9002,duringGesture:true) {
                runDelayedImageScenario {
                    print("HEIGHT STABILITY INTEGRATION PASSED: delayed images, idle anchoring, and momentum-end reconciliation remain stable")
                    exit(EXIT_SUCCESS)
                }
            }
        }
    }
    private static func verifyParagraphEditStability(_ controller:EditorWindowController,document:MarkdownDocument) {
        let intro="This document is here to explore the editor. Scroll through both panes, resize the window, drag the divider, and edit a paragraph. **Bold**"
        let introRange=(document.source.string as NSString).range(of:intro)
        check(introRange.location != NSNotFound,"Paragraph edit stability fixture is missing its introduction")
        let insertion=NSMaxRange(introRange)+2
        controller.source.reveal(0,alignTop:true)
        @MainActor func waitForStart(_ remaining:Int) {
            guard remaining>0 else{fail("Paragraph edit stability fixture did not settle")}
            guard controller.preview.lastRevision==document.revision,controller.preview.coversSourceViewport,
                  let headingY=controller.preview.debugFirstHeadingViewportY,headingY>=0,headingY<100 else {
                DispatchQueue.main.asyncAfter(deadline:.now()+0.01){waitForStart(remaining-1)};return
            }
            type("a",at:insertion,referenceY:headingY) { firstY in
                type(" ",at:insertion+1,referenceY:firstY) { _ in
                    print("PARAGRAPH EDIT STABILITY INTEGRATION PASSED: a new paragraph keeps preview alignment before and after trailing space")
                    exit(EXIT_SUCCESS)
                }
            }
        }
        @MainActor func type(_ text:String,at location:Int,referenceY:CGFloat,
                             completion:@escaping(CGFloat)->Void) {
            controller.source.textView.setSelectedRange(NSRange(location:location,length:0))
            controller.source.textView.insertText(text,replacementRange:NSRange(location:location,length:0))
            let revision=document.revision
            @MainActor func awaitEdit(_ remaining:Int) {
                guard remaining>0 else{fail("Paragraph edit stability revision \(revision) did not settle")}
                if let transientY=controller.preview.debugFirstHeadingViewportY {
                    check(abs(transientY-referenceY)<4,
                        "Preview shifted while inserting \(text.debugDescription): before=\(referenceY), after=\(transientY), \(controller.preview.debugGeometry())")
                }
                if controller.preview.lastRevision==revision,let headingY=controller.preview.debugFirstHeadingViewportY {
                    check(abs(headingY-referenceY)<4,
                        "Preview remained shifted after inserting \(text.debugDescription): before=\(referenceY), after=\(headingY), \(controller.preview.debugGeometry())")
                    completion(headingY);return
                }
                DispatchQueue.main.asyncAfter(deadline:.now()+0.002){awaitEdit(remaining-1)}
            }
            awaitEdit(2000)
        }
        waitForStart(1000)
    }
    private static func verifyCommentEditStability(_ controller:EditorWindowController,document:MarkdownDocument) {
        let suffix=(1...35).map{"Paragraph \($0) after the comments keeps this fixture tall enough to scroll."}
            .joined(separator:"\n\n")
        let firstText="First commented paragraph is deliberately long enough to wrap across several source and preview lines while remaining anchored at the top."
        let secondText="Second commented paragraph is also long enough to wrap, matching the editing case where a new paragraph is typed between two comments."
        let base="# Comment edit stability\n\n\(firstText)\n\nMiddle paragraph.\n\n\(secondText)\n\n\(suffix)"
        let first=(base as NSString).range(of:firstText)
        let second=(base as NSString).range(of:secondText)
        let author="Integration Test",created="2026-10-13T19:00:00Z"
        let firstComment=MarkdownComments.comment(in:base,selection:first,body:"First",author:author,created:created)
        let secondComment=MarkdownComments.comment(in:base,selection:second,body:"Second",author:author,created:created)
        var fixture=base
        fixture += MarkdownComments.insertion(for:firstComment,in:fixture)
        fixture += MarkdownComments.insertion(for:secondComment,in:fixture)
        document.replace(NSRange(location:0,length:document.source.count),with:fixture)
        let commentSelectors=[firstComment.id,secondComment.id].flatMap {id in
            [".markato-comment-highlight[data-comment-id=\"\(id)\"]",
             ".markato-comment-bubble[data-comment-id=\"\(id)\"]"]
        }
        func commentRects()->[NSRect]? {
            let values=commentSelectors.compactMap {controller.preview.previewView.debugRect($0)}
            return values.count==commentSelectors.count ? values:nil
        }
        func sameRects(_ lhs:[NSRect],_ rhs:[NSRect])->Bool {
            lhs.count==rhs.count && zip(lhs,rhs).allSatisfy {
                abs($0.0.minX-$0.1.minX)<0.05 && abs($0.0.minY-$0.1.minY)<0.05 &&
                abs($0.0.width-$0.1.width)<0.05 && abs($0.0.height-$0.1.height)<0.05
            }
        }
        @MainActor func type(_ characters:[Character],at location:Int,referenceY:CGFloat,
                             referenceRects:[NSRect],index:Int) {
            guard index<characters.count else {
                print("COMMENT EDIT STABILITY INTEGRATION PASSED: character edits between commented paragraphs keep preview position")
                exit(EXIT_SUCCESS)
            }
            let insertion=String(characters[index])
            controller.source.textView.setSelectedRange(NSRange(location:location,length:0))
            controller.source.textView.insertText(insertion,replacementRange:NSRange(location:location,length:0))
            let revision=document.revision
            @MainActor func awaitCharacter(_ remaining:Int) {
                guard remaining>0 else{fail("Comment edit stability character \(index+1) did not settle")}
                if index>0,let transientY=controller.preview.debugParagraphViewportY(containing:"First commented paragraph") {
                    check(abs(transientY-referenceY)<8,
                        "Preview jumped transiently while typing character \(index+1) between comments: before=\(referenceY), after=\(transientY), \(controller.preview.debugGeometry())")
                }
                if let transientRects=commentRects() {
                    check(sameRects(transientRects,referenceRects),
                        "Visible comment geometry jittered while typing character \(index+1): before=\(referenceRects), after=\(transientRects)")
                }
                if controller.preview.lastRevision==revision,
                   let y=controller.preview.debugParagraphViewportY(containing:"First commented paragraph") {
                    if index>0 {
                        check(abs(y-referenceY)<8,
                            "Preview jumped while typing character \(index+1) between comments: before=\(referenceY), after=\(y), \(controller.preview.debugGeometry())")
                    }
                    guard let settledRects=commentRects() else{fail("Comment geometry disappeared after character \(index+1)")}
                    check(sameRects(settledRects,referenceRects),
                        "Visible comment geometry moved after typing character \(index+1): before=\(referenceRects), after=\(settledRects)")
                    type(characters,at:location+insertion.utf16.count,referenceY:y,
                        referenceRects:referenceRects,index:index+1);return
                }
                DispatchQueue.main.asyncAfter(deadline:.now()+0.005){awaitCharacter(remaining-1)}
            }
            awaitCharacter(1000)
        }
        @MainActor func waitForSetup(_ remaining:Int) {
            guard remaining>0 else{fail("Comment edit stability fixture did not settle: \(controller.preview.debugGeometry())")}
            if controller.debugComments.count==2,controller.preview.lastRevision==document.revision,
               controller.preview.previewView.debugText.contains("Second commented paragraph") {
                let middle=(document.source.string as NSString).range(of:"Middle paragraph.")
                controller.source.reveal(0,alignTop:true)
                @MainActor func waitForPosition(_ positionRemaining:Int) {
                    guard positionRemaining>0 else{fail("Could not position the comment edit stability fixture")}
                    guard let y=controller.preview.debugParagraphViewportY(containing:"First commented paragraph"),
                          let firstRect=controller.preview.previewView.debugRect("p",containing:"First commented paragraph"),
                          let middleRect=controller.preview.previewView.debugRect("p",containing:"Middle paragraph"),
                          let secondRect=controller.preview.previewView.debugRect("p",containing:"Second commented paragraph"),
                          let rects=commentRects(),y>=0,y<300,controller.preview.coversSourceViewport else {
                        DispatchQueue.main.asyncAfter(deadline:.now()+0.01){waitForPosition(positionRemaining-1)};return
                    }
                    let commentedGap=middleRect.minY-firstRect.maxY
                    let plainGap=secondRect.minY-middleRect.maxY
                    check(abs(commentedGap-plainGap)<0.5,
                        "A commented paragraph changed paragraph spacing: commented=\(commentedGap), plain=\(plainGap)")
                    type(Array("typing"),at:NSMaxRange(middle),referenceY:y,referenceRects:rects,index:0)
                }
                waitForPosition(500);return
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.01){waitForSetup(remaining-1)}
        }
        waitForSetup(1000)
    }
    private static func verifyEmptyDocumentEdits(_ controller:EditorWindowController,document:MarkdownDocument) {
        let preview=controller.preview
        func wait(_ remaining:Int,_ ready:@escaping()->Bool,_ failure:String,_ completion:@escaping()->Void) {
            guard remaining>0 else{fail("\(failure): \(preview.debugGeometry())")}
            if ready() {completion()}
            else {DispatchQueue.main.asyncAfter(deadline:.now()+0.01){wait(remaining-1,ready,failure,completion)}}
        }
        func waitForText(_ text:String,_ completion:@escaping()->Void) {
            wait(500,{preview.lastRevision==document.revision && !preview.isShowingLoadingState &&
                preview.previewView.debugText.contains(text)},"Single-block preview did not settle",completion)
        }
        wait(500,{preview.lastRevision==document.revision && !preview.isShowingLoadingState &&
            preview.preparedFragmentCount==0},"Fresh empty preview did not settle") {
            document.replace(NSRange(location:0,length:0),with:"# Heading")
            waitForText("Heading") {
                check(preview.preparedFragmentCount==1,"A heading-only document must mount one fragment")
                document.replace(NSRange(location:0,length:document.source.count),with:"Plain text")
                waitForText("Plain text") {
                    check(preview.preparedFragmentCount==1,"A paragraph-only document must mount one fragment")
                    let fixture="# Section\n\nBody\n\n## Subsection\n\nMore text\n\n### Tail\n\nExisting paragraph"
                    document.replace(NSRange(location:0,length:document.source.count),with:fixture)
                    waitForText("Existing paragraph") {
                        @MainActor func typeNewParagraph(_ characters:[Character],_ index:Int=0) {
                            guard index<characters.count else {
                                document.replace(NSRange(location:0,length:document.source.count),with:"")
                                wait(500,{preview.lastRevision==document.revision && !preview.isShowingLoadingState &&
                                    preview.preparedFragmentCount==0 && preview.previewView.debugText.isEmpty},
                                    "Deleting all source did not clear the preview") {
                                    print("EMPTY EDITS INTEGRATION PASSED: empty startup, single blocks, character-by-character new paragraph, and delete-all")
                                    exit(EXIT_SUCCESS)
                                }
                                return
                            }
                            let prefix=index==0 ? "\n\n":""
                            let insertion="\(prefix)\(characters[index])"
                            controller.source.textView.setSelectedRange(NSRange(location:document.source.count,length:0))
                            controller.source.textView.insertText(insertion,
                                replacementRange:controller.source.textView.selectedRange())
                            let expected=String(characters[0...index])
                            let retained=index>0 ? String(characters[0..<index]):""
                            @MainActor func awaitCharacter(_ remaining:Int) {
                                guard remaining>0 else {
                                    fail("New paragraph character \(index+1) did not commit: \(preview.debugGeometry())")
                                }
                                let text=preview.debugCommittedHTML
                                check(!preview.isShowingLoadingState,
                                    "Typing character \(index+1) flashed the loading preview")
                                if !retained.isEmpty {
                                    check(text.contains(retained),
                                        "New paragraph disappeared while character \(index+1) rendered: retained \(retained.debugDescription), got \(text.debugDescription)")
                                }
                                if preview.lastRevision==document.revision {
                                    check(text.contains(expected),
                                        "New paragraph disappeared after character \(index+1): expected \(expected.debugDescription), got \(text.debugDescription)")
                                    guard let rect=preview.previewView.debugRect("p",containing:expected) else {
                                        fail("New paragraph has no geometry after character \(index+1)")
                                    }
                                    let pixels=capture(preview.previewView,rect:rect)
                                    check(pixels.inkRows.reduce(0,+)>2,
                                        "New paragraph has geometry but no painted pixels after character \(index+1)")
                                    typeNewParagraph(characters,index+1)
                                } else {
                                    DispatchQueue.main.asyncAfter(deadline:.now()+0.001){awaitCharacter(remaining-1)}
                                }
                            }
                            awaitCharacter(5000)
                        }
                        typeNewParagraph(Array("zyx"))
                    }
                }
            }
        }
    }
    private static func verifyOutline(_ controller:EditorWindowController,document:MarkdownDocument) {
        @MainActor func wait(_ remaining:Int,_ completion:@escaping()->Void) {
            guard remaining>0 else{fail("Outline did not settle: headings=\(controller.sidebar.debugHeadingCount), \(controller.preview.debugGeometry())")}
            if controller.sidebar.debugHeadingCount>80,controller.hasPreparedDocument,
               controller.preview.lastRevision==document.revision {completion()}
            else {DispatchQueue.main.asyncAfter(deadline:.now()+0.01){wait(remaining-1,completion)}}
        }
        wait(500) {
            check(!controller.isSidebarVisible,"Outline sidebar must be hidden initially")
            guard let sidebarButton=controller.window?.toolbar?.items.lazy.compactMap({$0.view as? NSButton}).first(where:{
                $0.action == #selector(EditorWindowController.toggleSidebar(_:))
                    && $0.bezelStyle == .toolbar && $0.isBordered
                    && $0.showsBorderOnlyWhileMouseInside
            }) else{fail("The window must keep an AppKit hover-revealed sidebar button in its toolbar")}
            sidebarButton.performClick(nil)
            check(controller.isSidebarVisible,"Sidebar toggle must reveal the outline")
            check(controller.sidebar.debugHeadingTitles.first=="Markato — a long example",
                "Outline must use parser-produced plain heading titles")
            let selected=controller.sidebar.debugHeading(containing:"Section 56")
            check(controller.sidebar.debugActivateHeading(containing:"Section 56"),"Missing deep outline heading")
            let expected=(document.source.string as NSString).range(of:"## Section 56 —").location
            check(selected?.range.location==expected,
                "Outline heading range is wrong: expected=\(expected), heading=\(String(describing:selected))")
            @MainActor func waitForJump(_ remaining:Int) {
                guard remaining>0 else{fail("Outline jump did not settle: \(controller.preview.debugGeometry())")}
                if controller.source.visibleSourceRange.location<=expected,
                   NSMaxRange(controller.source.visibleSourceRange)>expected,
                   controller.preview.coversSourceViewport {
                    check(controller.preview.displaysCompleteDocument,
                        "Background completion must retain the complete preview presentation")
                    controller.toggleSidebar(nil)
                    check(!controller.isSidebarVisible,"Sidebar toggle must collapse the outline")
                    controller.toggleSidebar(nil)
                    check(controller.isSidebarVisible,"Sidebar toggle must restore the outline")
                    print("OUTLINE INTEGRATION PASSED: semantic headings, complete background preview, deep jump, collapse and restore")
                    exit(EXIT_SUCCESS)
                }
                DispatchQueue.main.asyncAfter(deadline:.now()+0.01){waitForJump(remaining-1)}
            }
            waitForJump(500)
        }
    }
    private static func verifyComments(_ controller:EditorWindowController,document:MarkdownDocument) {
        controller.window?.setContentSize(commentsScreenshotOutput != nil
            ? NSSize(width:1400,height:820):NSSize(width:1760,height:1120))
        let source=document.source.string as NSString
        let selection=source.range(of:"This document is here to explore the editor. Scroll through both panes, resize the window, drag the divider, and edit a paragraph. **Bold**")
        check(selection.location != NSNotFound,"Comment fixture selection is missing")
        let body="""
        Could we make this introduction more concrete?

        Please mention what makes long-document editing feel fast, and link to the benchmark methodology.

        There is no length limit on this comment. Reviewers can include lists, code, or detailed revision notes.

        - Verify the claim
        - Add the link

        The sequence a--b stays valid.
        """
        controller.debugBeginAddComment(selection:selection)
        check(controller.debugCommentPopoverIsShown,"Adding a comment must open the inline yellow editor")
        check(controller.debugCommentPopoverEditorIsEditable,"The new-comment card must contain an editable text view")
        check(controller.debugComments.isEmpty,"Opening the editor must not store an empty draft")
        controller.debugSetCommentPopoverText(body)
        check(controller.debugPressCommentReturn(shift:false),"Could not send Return to the comment editor")
        check(!controller.debugCommentPopoverIsShown,"Return must close the new-comment editor")
        @MainActor func waitForComment(_ remaining:Int) {
            guard remaining>0 else{fail("Comment UI did not settle: comments=\(controller.sidebar.debugCommentCount), \(controller.preview.debugGeometry())")}
            let web=controller.preview.previewView
            if controller.sidebar.debugCommentCount==1,controller.source.debugCommentRangeCount==1,
               controller.preview.lastRevision==document.revision,
               web.debugCount(".markato-comment-bubble")==1,
               web.debugCount(".markato-comment-highlight")>0 {
                check(!controller.isSidebarVisible,"Adding a comment must not reveal the sidebar")
                check(controller.sidebar.mode == .comments,"Adding a comment must select the Comments sidebar")
                check(controller.source.debugCollapsedCommentFooterRange?.length ?? 0>0,
                    "Stored comment records must collapse in the source editor")
                check((controller.source.debugCollapsedCommentFontSize ?? 13)<1,
                    "Collapsed comment records must not retain normal source-line metrics")
                check(controller.source.debugCommentFooterControlVisible,
                    "Collapsed comment records must show a source disclosure summary")
                controller.source.debugToggleCommentFooter()
                check(controller.source.debugCommentFooterExpanded,
                    "The source comment disclosure must expand the stored records")
                check((controller.source.debugCollapsedCommentFontSize ?? 0)>1,
                    "Expanded comment records must restore editable source typography")
                controller.source.debugToggleCommentFooter()
                check(!controller.source.debugCommentFooterExpanded,
                    "The source comment disclosure must collapse the records again")
                let text=document.source.string
                check(text.contains(MarkdownComments.marker),"The comment record must be stored in the Markdown source")
                check(text.contains("a-\\u002db"),"Unsafe double hyphens must be escaped in the HTML comment")
                check(controller.sidebar.debugCommentSnippets.first?.hasPrefix("Could we make this introduction") == true,
                    "The sidebar must summarize the comment body")
                check(controller.sidebar.debugCommentSnippets.contains(where:{$0.contains("This document is here")}) == false,
                    "The sidebar must not repeat document text")
                guard let id=controller.debugComments.first?.comment.id else{fail("Missing stored comment")}
                check(controller.debugComments.first?.comment.anchor.extent == nil,
                    "A selection crossing inline syntax must retain its precise extent")
                if let footerStart=controller.debugComments.first?.recordRange.location {
                    controller.source.debugScrollViewport(by:.greatestFiniteMagnitude)
                    let bottom=controller.source.debugRenderedOffset(
                        atViewportY:max(0,controller.source.scroll.contentSize.height-2))
                    check(bottom>=footerStart-1,
                        "Collapsed comments must not shorten source scrolling: bottom=\(bottom), contentEnd=\(footerStart), \(controller.source.debugResizeState)")
                }
                controller.toggleSidebar(nil)
                check(controller.isSidebarVisible,"The sidebar must still open when explicitly requested")
                if let path=commentsScreenshotOutput,let content=controller.window?.contentView {
                    check(click(web,selector:".markato-comment-bubble"),"Could not open the comment bubble")
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.25) {
                        check(controller.debugCommentPopoverIsShown,"The native comment popover did not open")
                        check(controller.source.debugHasSelectedCommentRange,"Selecting a comment must outline its source highlight")
                        check(web.debugCount(".markato-comment-highlight.is-selected")>0,
                            "Selecting a comment must outline its preview highlight")
                        check(web.debugCount(".markato-comment-bubble.is-selected")==1,
                            "Selecting a comment must outline its preview bubble")
                        guard let popover=controller.debugCommentPopoverView else{fail("Missing native comment popover view")}
                        content.layoutSubtreeIfNeeded()
                        popover.layoutSubtreeIfNeeded()
                        do {try capture(content).png.write(to:URL(fileURLWithPath:path),options:.atomic)}
                        catch {fail("Could not write comments screenshot: \(error.localizedDescription)")}
                        let url=URL(fileURLWithPath:path)
                        let popoverURL=url.deletingPathExtension().appendingPathExtension("popover.png")
                        do {try capture(popover).png.write(to:popoverURL,options:.atomic)}
                        catch {fail("Could not write comment popover screenshot: \(error.localizedDescription)")}
                        print("COMMENTS SCREENSHOT: \(path)")
                        print("COMMENT POPOVER SCREENSHOT: \(popoverURL.path)");exit(EXIT_SUCCESS)
                    }
                    return
                }
                check(!controller.sidebar.debugCommentTextIsSelectable,
                    "Sidebar comment-card text must not be selectable")
                controller.sidebar.debugSelectComment(id:id)
                check(controller.source.debugHasSelectedCommentRange,
                    "Clicking a sidebar comment must select and reveal its source anchor")
                controller.sidebar.debugOpenSelectedComment()
                @MainActor func waitForTrackedPopover(_ remaining:Int) {
                    guard remaining>0 else {
                        let selectedBubbles=web.debugCount(".markato-comment-bubble.is-selected")
                        fail("Comment popover did not acquire its rendered bubble anchor: shown=\(controller.debugCommentPopoverIsShown), selectedBubbles=\(selectedBubbles), \(controller.preview.debugGeometry())")
                    }
                    if controller.debugCommentPopoverIsShown,
                       controller.preview.lastRevision==document.revision,
                       let bubble=controller.preview.debugSelectedCommentAnchor,
                       let positioning=controller.debugCommentPopoverPositioningRect {
                        check(abs(bubble.midX-positioning.midX)<0.5 && abs(bubble.midY-positioning.midY)<0.5,
                            "Comment popover must initially align with the rendered bubble: bubble=\(bubble), positioning=\(positioning)")
                        let originalY=bubble.minY
                        controller.preview.debugScrollViewport(by:20)
                        DispatchQueue.main.asyncAfter(deadline:.now()+0.05) {
                            guard let moved=controller.preview.debugSelectedCommentAnchor,
                                  let movedPositioning=controller.debugCommentPopoverPositioningRect else {
                                fail("Visible comment popover disappeared while tracking a small scroll")
                            }
                            check(moved.minY<originalY-1,
                                "The selected comment bubble did not move with preview scrolling: before=\(originalY), after=\(moved.minY)")
                            check(abs(moved.midX-movedPositioning.midX)<0.5 && abs(moved.midY-movedPositioning.midY)<0.5,
                                "Comment popover positioning did not follow the bubble while scrolling: bubble=\(moved), positioning=\(movedPositioning)")
                            controller.preview.debugScrollViewport(by:controller.preview.bounds.height)
                            DispatchQueue.main.asyncAfter(deadline:.now()+0.05) {
                                check(!controller.debugCommentPopoverIsShown,
                                    "Comment popover must close when its bubble leaves the viewport")
                                controller.debugClearCommentSelection()
                                resolveComment()
                            }
                        }
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.01){waitForTrackedPopover(remaining-1)}
                }
                @MainActor func waitForSidebarPopover(_ remaining:Int) {
                    guard remaining>0 else{fail("Double-clicking a sidebar comment did not open its popup")}
                    if controller.debugCommentPopoverIsShown {
                        check(controller.debugCommentPopoverEditorIsEditable,
                            "An existing comment popup must be editable")
                        check(controller.debugCommentPopoverCanDelete,
                            "An existing comment popup must contain its delete button")
                        guard let editorView=controller.debugCommentPopoverEditorView else {
                            fail("Existing comment popup is missing its editor view")
                        }
                        editorView.layoutSubtreeIfNeeded()
                        let editorPixels=capture(editorView)
                        check(editorView.bounds.width>100 && editorView.bounds.width<400 && editorView.bounds.height>100,
                            "Comment editor must have a visible document frame: bounds=\(editorView.bounds), container=\(String(describing:controller.debugCommentPopoverTextContainerWidth))")
                        check((controller.debugCommentPopoverTextContainerWidth ?? .greatestFiniteMagnitude)
                                <= editorView.bounds.width+1,
                            "Comment editor text must wrap within the yellow card")
                        check(editorPixels.inkRows.reduce(0,+)>20,
                            "Existing comment text must paint visibly inside the popup")
                        controller.debugSetCommentPopoverText(body)
                        check(controller.debugPressCommentReturn(shift:true),
                            "Could not send Shift-Return to the comment editor")
                        check(controller.debugCommentPopoverIsShown,
                            "Shift-Return must keep the comment editor open")
                        check(controller.debugCommentPopoverText == body+"\n",
                            "Shift-Return must insert a newline in the comment body")
                        let editedBody=body+"\nEdited in place."
                        controller.debugSetCommentPopoverText(editedBody)
                        check(controller.debugPressCommentReturn(shift:false),
                            "Could not save the edited comment with Return")
                        check(!controller.debugCommentPopoverIsShown,
                            "Return must close an existing comment editor")
                        @MainActor func waitForEditedComment(_ editRemaining:Int) {
                            guard editRemaining>0 else{fail("Edited comment body did not reach the model")}
                            if controller.debugComments.first?.comment.body==editedBody {
                                controller.sidebar.debugOpenSelectedComment()
                                @MainActor func waitForReopenedComment(_ reopenRemaining:Int) {
                                    guard reopenRemaining>0 else{fail("Edited comment could not be reopened")}
                                    if controller.debugCommentPopoverIsShown {
                                        check(controller.debugCommentPopoverText==editedBody,
                                            "Reopened comment editor must show the saved body")
                                        controller.source.debugBeginSourceClick()
                                        check(!controller.debugCommentPopoverIsShown,
                                            "Clicking the source editor must close the comment popup")
                                        check(!controller.source.debugHasSelectedCommentRange,
                                            "Clicking the source editor must clear the selected comment")
                                        @MainActor func waitForBubble(_ bubbleRemaining:Int) {
                                            guard bubbleRemaining>0 else {
                                                fail("Could not locate the comment bubble for tracking")
                                            }
                                            if let bubble=web.debugRect(".markato-comment-bubble") {
                                                controller.preview.openComment?(id,web,bubble)
                                                waitForTrackedPopover(500);return
                                            }
                                            DispatchQueue.main.asyncAfter(deadline:.now()+0.01) {
                                                waitForBubble(bubbleRemaining-1)
                                            }
                                        }
                                        waitForBubble(500);return
                                    }
                                    DispatchQueue.main.asyncAfter(deadline:.now()+0.01) {
                                        waitForReopenedComment(reopenRemaining-1)
                                    }
                                }
                                waitForReopenedComment(500);return
                            }
                            DispatchQueue.main.asyncAfter(deadline:.now()+0.01) {
                                waitForEditedComment(editRemaining-1)
                            }
                        }
                        waitForEditedComment(500);return
                    }
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.01){waitForSidebarPopover(remaining-1)}
                }
                @MainActor func resolveComment() {
                    controller.debugToggleCommentResolved(id)
                @MainActor func waitForResolution(_ remaining:Int) {
                    guard remaining>0 else {
                        let bubbles=controller.preview.previewView.debugCount(".markato-comment-bubble")
                        fail("Resolving a comment did not settle: revision=\(document.revision), preview=\(controller.preview.lastRevision), bubbles=\(bubbles), ranges=\(controller.source.debugCommentRangeCount), status=\(String(describing:controller.debugComments.first?.comment.status)), \(controller.preview.debugGeometry())")
                    }
                    if controller.preview.lastRevision==document.revision,
                       controller.preview.previewView.debugCount(".markato-comment-bubble")==0,
                       controller.source.debugCommentRangeCount==0,
                       controller.debugComments.first?.comment.status == .resolved {
                        check(controller.sidebar.debugVisibleCommentCount==0,
                            "The default Open filter must hide resolved comments")
                        controller.sidebar.debugSetCommentFilter(.resolved)
                        check(controller.sidebar.debugVisibleCommentCount==1,
                            "The Resolved filter must reveal resolved comments")
                        let output=URL(fileURLWithPath:"/private/tmp/markato-comments-integration.pdf")
                        try? FileManager.default.removeItem(at:output);document.debugExportPDF(to:output)
                        @MainActor func waitForPDF(_ remaining:Int) {
                            guard remaining>0 else{fail("Commented PDF export did not finish")}
                            if !document.isProducingOutput,let pdf=PDFDocument(url:output) {
                                let annotations=(0..<pdf.pageCount).flatMap{pdf.page(at:$0)?.annotations ?? []}
                                check(annotations.contains{$0.type?.lowercased().contains("highlight") == true},
                                    "PDF export must contain a standard highlight annotation")
                                check(annotations.contains{$0.contents?.contains("Could we make this introduction") == true},
                                    "PDF annotation must preserve the comment body")
                                try? FileManager.default.removeItem(at:output)
                                controller.sidebar.debugSelectComment(id:id)
                                controller.debugOpenCommentPopover(id)
                                @MainActor func waitForDeletePopover(_ deletePopoverRemaining:Int) {
                                    guard deletePopoverRemaining>0 else{fail("Resolved comment popup did not open for deletion")}
                                    if controller.debugCommentPopoverIsShown {
                                        check(controller.debugCommentPopoverCanDelete,
                                            "Resolved comment popup must contain its delete button")
                                        let selectionBeforeDelete=controller.source.selection
                                        let viewportBeforeDelete=controller.source.viewportOrigin
                                        check(controller.debugDeleteCommentFromPopover(),
                                            "Comment delete button could not be activated")
                                        @MainActor func waitForDeletion(_ deletionRemaining:Int) {
                                            guard deletionRemaining>0 else{fail("Deleted comment remained in the document")}
                                            if controller.debugComments.isEmpty &&
                                               !document.source.string.contains(MarkdownComments.marker) {
                                                document.undoManager?.undo()
                                                @MainActor func waitForUndo(_ undoRemaining:Int) {
                                                    guard undoRemaining>0 else{fail("Deleted comment could not be restored with Undo")}
                                                    if controller.debugComments.count==1 &&
                                                       document.source.string.contains(MarkdownComments.marker) {
                                                        check(controller.source.selection==selectionBeforeDelete,
                                                            "Undoing comment deletion moved the source selection: before=\(selectionBeforeDelete), after=\(controller.source.selection)")
                                                        check(abs(controller.source.viewportOrigin-viewportBeforeDelete)<0.5,
                                                            "Undoing comment deletion moved the source viewport: before=\(viewportBeforeDelete), after=\(controller.source.viewportOrigin)")
                                                        if let footerStart=controller.debugComments.first?.recordRange.location {
                                                            controller.source.debugScrollViewport(by:.greatestFiniteMagnitude)
                                                            let bottom=controller.source.debugRenderedOffset(
                                                                atViewportY:max(0,controller.source.scroll.contentSize.height-2))
                                                            check(bottom>=footerStart-1,
                                                                "Undoing comment deletion shortened source scrolling: bottom=\(bottom), contentEnd=\(footerStart), \(controller.source.debugResizeState)")
                                                        }
                                                        print("COMMENTS INTEGRATION PASSED: inline add/edit/delete, storage, highlighting, sidebar, resolve, undo, and annotated PDF export")
                                                        exit(EXIT_SUCCESS)
                                                    }
                                                    DispatchQueue.main.asyncAfter(deadline:.now()+0.01){waitForUndo(undoRemaining-1)}
                                                }
                                                waitForUndo(500);return
                                            }
                                            DispatchQueue.main.asyncAfter(deadline:.now()+0.01){waitForDeletion(deletionRemaining-1)}
                                        }
                                        waitForDeletion(500);return
                                    }
                                    DispatchQueue.main.asyncAfter(deadline:.now()+0.01){waitForDeletePopover(deletePopoverRemaining-1)}
                                }
                                waitForDeletePopover(500);return
                            }
                            DispatchQueue.main.asyncAfter(deadline:.now()+0.02){waitForPDF(remaining-1)}
                        }
                        waitForPDF(500);return
                    }
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.01){waitForResolution(remaining-1)}
                }
                waitForResolution(500);return
                }
                waitForSidebarPopover(500);return
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.01){waitForComment(remaining-1)}
        }
        waitForComment(500)
    }
    private static func verifyMermaid(_ controller:EditorWindowController,document:MarkdownDocument) {
        let preview=controller.preview
        let fixture=URL(fileURLWithPath:#filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/fixtures/mermaid/native.md")
        guard let text=try? String(contentsOf:fixture,encoding:.utf8) else{fail("Missing Mermaid native fixture")}
        document.setInitialText(text)
        func wait(_ remaining:Int,_ images:Int,_ errors:Int,_ completion:@escaping()->Void) {
            guard remaining>0 else{fail("Mermaid native preview did not settle: \(preview.debugGeometry())")}
            let web=preview.previewView
            if preview.lastRevision==document.revision,
               web.debugCount(".mermaid-diagram img")==images,web.debugCount(".mermaid-error")==errors,
               (web.debugRect(".mermaid-diagram img")?.height ?? 0)>0 {
                completion()
            } else {DispatchQueue.main.asyncAfter(deadline:.now()+0.02){wait(remaining-1,images,errors,completion)}}
        }
        wait(500,3,1) {
            let web=preview.previewView
            check(web.debugCount(".katex")>0,"Mermaid must coexist with KaTeX in Ultralight")
            check(web.debugText.contains("surrounding paragraph survives"),"Mermaid errors must preserve neighboring Markdown")
            check(web.debugCount("svg")==0,"Diagram SVGs must be isolated in images")
            let before=capture(web)
            check(before.inkRows.filter{$0>10}.count>30,"Mermaid preview must paint content")
            try? before.png.write(to:URL(fileURLWithPath:"/private/tmp/markato-mermaid-native.png"))
            guard let window=controller.window,let original=web.debugRect(".mermaid-diagram img") else {
                fail("Missing Mermaid window/image geometry")
            }
            let diagram=capture(web,rect:original)
            check(diagram.inkRows.filter{$0>5}.count>8,"The SVG image itself must paint nodes, labels and arrows")
            let size=window.contentLayoutRect.size
            window.setContentSize(NSSize(width:700,height:size.height))
            wait(500,3,1) {
                guard let resized=preview.previewView.debugRect(".mermaid-diagram img") else{fail("Missing resized Mermaid image")}
                check(resized.width<=preview.previewView.bounds.width,"Mermaid must fit the preview width")
                check(abs(original.width/original.height-resized.width/resized.height)<0.02,
                    "Mermaid resize must preserve aspect ratio")
                let range=(text as NSString).range(of:"unknownDiagram")
                document.replace(range,with:"flowchart LR")
                wait(500,4,0) {
                    check(preview.previewView.debugText.contains("surrounding paragraph survives"),
                        "Editing Mermaid must preserve the surrounding preview")
                    document.undoManager?.undo()
                    wait(500,3,1) {
                        document.undoManager?.redo()
                        wait(500,4,0) {
                            print("MERMAID INTEGRATION PASSED: SVG image painting, repeated diagrams, math, resize, edit, undo and redo")
                            exit(EXIT_SUCCESS)
                        }
                    }
                }
            }
        }
    }
    private static func verifyHighlighting(_ controller:EditorWindowController,document:MarkdownDocument) {
        let preview=controller.preview
        let fixture=URL(fileURLWithPath:#filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/fixtures/highlighting/native.md")
        guard let text=try? String(contentsOf:fixture,encoding:.utf8) else{fail("Missing highlighting native fixture")}
        document.setInitialText(text)
        func wait(_ remaining:Int,_ label:String,_ completion:@escaping()->Void) {
            guard remaining>0 else{fail("Code highlighting preview did not settle: \(preview.debugGeometry())")}
            let web=preview.previewView
            if preview.lastRevision==document.revision,web.debugText.contains(label),
               web.debugCount("code .syntax-string")>0 {
                completion()
            } else {DispatchQueue.main.asyncAfter(deadline:.now()+0.02){wait(remaining-1,label,completion)}}
        }
        wait(500,"NATIVE_HIGHLIGHT_STRING") {
            let web=preview.previewView
            check(web.debugCount("code.language-swift .syntax-string")>0 &&
                  web.debugCount("code.language-typst .syntax-string")>0,
                "Extended Swift and Typst grammars must render token spans")
            check(web.debugText.contains("NATIVE_SWIFT_STRING") && web.debugText.contains("NATIVE_TYPST_STRING"),
                "Extended languages must preserve literal source")
            check(web.debugCount("code.language-unknown-language span")==0,"Unknown languages must stay plain text")
            check(web.debugText.contains("<script>NATIVE_LITERAL_HTML</script>"),"Source HTML must remain literal code")
            check(web.debugCount("script")==0,"Code must never create executable elements")
            check(web.debugCount(".mermaid-diagram img")==1 && web.debugCount(".katex")>0,
                "Highlighting must coexist with math and Mermaid")
            guard let rect=web.debugRect("pre",containing:"NATIVE_HIGHLIGHT_STRING"),
                  let rep=web.bitmapImageRepForCachingDisplay(in:rect) else{fail("Missing highlighted code geometry")}
            web.cacheDisplay(in:rect,to:rep)
            let backgroundX=max(0,rep.pixelsWide-20),backgroundY=rep.pixelsHigh/2
            guard let background=rep.colorAt(x:backgroundX,y:backgroundY)?.usingColorSpace(.deviceRGB) else {
                fail("Missing highlighted code background pixel")
            }
            check(max(background.redComponent,background.greenComponent,background.blueComponent)<0.99,
                "Highlighted code block must paint its muted background")
            var colored=0
            for y in stride(from:0,to:rep.pixelsHigh,by:2) {
                for x in stride(from:0,to:rep.pixelsWide,by:2) {
                    guard let color=rep.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else{continue}
                    let components=[color.redComponent,color.greenComponent,color.blueComponent]
                    if (components.max() ?? 0)-(components.min() ?? 0)>0.15 {colored += 1}
                }
            }
            check(colored>20,"Highlighted code must paint colored token pixels")
            try? capture(web).png.write(to:URL(fileURLWithPath:"/private/tmp/markato-highlighting-native.png"))
            guard let window=controller.window else{fail("Missing highlighting window")}
            window.setContentSize(NSSize(width:700,height:window.contentLayoutRect.height))
            wait(500,"NATIVE_HIGHLIGHT_STRING") {
                check(preview.previewView.debugText.contains("NATIVE_HIGHLIGHT_COMMENT"),"Resize must preserve code text")
                let range=(text as NSString).range(of:"NATIVE_HIGHLIGHT_STRING")
                document.replace(range,with:"CHANGED_HIGHLIGHT_STRING")
                wait(500,"CHANGED_HIGHLIGHT_STRING") {
                    document.undoManager?.undo()
                    wait(500,"NATIVE_HIGHLIGHT_STRING") {
                        document.undoManager?.redo()
                        wait(500,"CHANGED_HIGHLIGHT_STRING") {
                            print("HIGHLIGHT INTEGRATION PASSED: token colors, literal code, math, Mermaid, resize, edit, undo and redo")
                            exit(EXIT_SUCCESS)
                        }
                    }
                }
            }
        }
    }
    private static func verifyUltralightPreview(_ controller:EditorWindowController,document:MarkdownDocument) {
        let preview=controller.preview
        func wait(_ remaining:Int,_ ready:@escaping()->Bool,_ failure:String,_ completion:@escaping()->Void) {
            guard remaining>0 else {
                fail("\(failure): \(preview.debugGeometry()), images=\(preview.previewView.debugCount("img")), " +
                    "delayedImages=\(preview.previewView.debugCount("img[data-astra-delayed-src]")), " +
                    "imageRect=\(String(describing:preview.previewView.debugRect("img")))")
            }
            if ready() {completion()}
            else {DispatchQueue.main.asyncAfter(deadline:.now()+0.01){wait(remaining-1,ready,failure,completion)}}
        }
        wait(500,{controller.hasPreparedViewport && preview.lastRevision==document.revision &&
            preview.previewView.debugText.contains("Markato")},"Ultralight did not publish the first viewport") {
            check(abs(controller.source.canvas.frame.width-controller.source.scroll.contentSize.width)<0.1,
                "Initial source width did not follow the clip after its vertical scroller appeared")
            check(preview.coversSourceViewport,"The first Ultralight window must cover the source viewport")
            check(preview.preparedFragmentCount>0,"The first Ultralight presentation must contain semantic blocks")
            check(preview.previewView.debugCount("section[data-id]")==preview.preparedFragmentCount,
                "Ultralight DOM and retained presentation must contain the same blocks")
            let firstHeading=preview.previewView.debugRect("h1",containing:"Markato")
            check(firstHeading != nil && abs((firstHeading?.minY ?? 0)-32)<1,
                "The first heading must begin at the document padding without inter-section spacing")
            check(preview.previewView.debugCount(".katex")>0,"Ultralight must retain Comrak's KaTeX output")
            check(preview.previewView.debugCount("tbody tr")>0,"Ultralight must render complete table markup")
            wait(1500,{preview.previewView.debugCount("img[data-astra-delayed-src]")==0 &&
                preview.previewView.debugCount("img")>0 && (preview.previewView.debugRect("img")?.height ?? 0)>100},
                "Ultralight did not resolve and lay out the bundled local image") {
                let startupCount=preview.preparedFragmentCount
                verifyPresentationFailureRecovery(controller,wait:wait) {
                    verifyTopResizeAnchor(controller,wait:wait) {
                        verifyMiddleResizeAnchor(controller,document:document,wait:wait) {
                            verifyPreviewSideScrolling(controller,document:document,wait:wait) {
                                verifyClickEditAlignment(controller,document:document,wait:wait) {
                                    continueAfterTopResize(controller,document:document,startupCount:startupCount,wait:wait)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    private static func verifyPreviewSideScrolling(_ controller:EditorWindowController,document:MarkdownDocument,
        wait:@escaping(Int,@escaping()->Bool,String,@escaping()->Void)->Void,completion:@escaping()->Void) {
        let source=controller.source,preview=controller.preview
        let marker=(document.source.string as NSString).range(of:"## Section 36 —").location
        guard marker != NSNotFound else{fail("Missing preview-scroll regression fixture")}
        source.debugAlignViewport(at:marker,viewportY:source.bounds.height/2)
        wait(800,{preview.coversSourceViewport && preview.debugScrollMapError.map{abs($0)<0.01}==true},
            "Preview-scroll regression did not reach its aligned starting point") {
            let sourceOrigin=source.viewportOrigin,previewOrigin=preview.clipOrigin
            preview.debugScrollViewport(by:120)
            check(abs(source.viewportOrigin-sourceOrigin)<0.01,
                "Scrolling over the preview moved the source viewport")
            check(preview.debugIsIndependentlyScrolled && preview.clipOrigin>previewOrigin+100,
                "Scrolling over the preview did not move the preview independently")
            let detachedOrigin=preview.clipOrigin
            preview.moveViewport()
            check(abs(preview.clipOrigin-detachedOrigin)<0.01,
                "An unrelated preview update discarded the independent preview position")
            source.debugScrollViewport(by:80)
            wait(800,{!preview.debugIsIndependentlyScrolled &&
                preview.debugScrollMapError.map{abs($0)<0.01}==true},
                "Source movement did not restore source/preview alignment") {
                preview.debugScrollViewport(by:120)
                check(preview.debugIsIndependentlyScrolled,
                    "The preview could not detach again before the edit regression")
                let editedPreviewOrigin=preview.clipOrigin
                let revision=document.revision+1
                document.replace(NSRange(location:document.source.count,length:0),with:"\n")
                wait(800,{document.revision==revision && preview.lastRevision==revision &&
                    abs(preview.clipOrigin-editedPreviewOrigin)<0.01},
                    "A source edit did not preserve the preview origin (expectedRevision=\(revision), documentRevision=\(document.revision), previewRevision=\(preview.lastRevision), before=\(editedPreviewOrigin), after=\(preview.clipOrigin))") {
                    completion()
                }
            }
        }
    }
    private static func verifyPresentationFailureRecovery(_ controller:EditorWindowController,
        wait:@escaping(Int,@escaping()->Bool,String,@escaping()->Void)->Void,completion:@escaping()->Void) {
        let preview=controller.preview
        let failures=preview.presentationFailureCount,revision=preview.lastRevision
        preview.debugFailNextPresentation()
        preview.fontSize += 0.5
        wait(100,{preview.presentationFailureCount==failures+1 &&
            preview.lastRevision==revision},"Ultralight did not recover from a failed presentation") {
            check(preview.retainedPresentationAfterFailure,
                "A failed replacement must retain the committed presentation without a loading mask")
            check(preview.previewView.debugText.contains("Markato"),
                "Recovery must publish the requested document through the normal presentation path")
            completion()
        }
    }
    private static func verifyTopResizeAnchor(_ controller:EditorWindowController,
        wait:@escaping(Int,@escaping()->Bool,String,@escaping()->Void)->Void,completion:@escaping()->Void) {
        guard let window=controller.window,let previewTop=controller.preview.debugFirstHeadingViewportY else {
            fail("Missing first heading geometry before resize")
        }
        check(!controller.split.preservesContentDuringLiveResize,
            "The editor split must redraw its panes instead of preserving stale live-resize pixels")
        let original=window.contentLayoutRect.size
        let sourceTop=controller.source.debugFirstLineViewportY
        let sizes=[NSSize(width:original.width-240,height:original.height-135),
            NSSize(width:original.width-160,height:original.height-90),
            NSSize(width:original.width-80,height:original.height-45),original,
            NSSize(width:original.width+80,height:original.height+45),
            NSSize(width:original.width+160,height:original.height+90),
            NSSize(width:original.width+240,height:original.height+135)]
        let notification=Notification(name:NSWindow.willStartLiveResizeNotification,object:window)
        controller.windowWillStartLiveResize(notification)
        func step(_ index:Int) {
            guard index<sizes.count else {
                controller.windowDidEndLiveResize(Notification(name:NSWindow.didEndLiveResizeNotification,object:window))
                wait(500,{controller.preview.debugFirstHeadingViewportY==previewTop},
                    "Preview top did not settle after live resize") {
                    window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
                    check(controller.source.debugFirstLineViewportY==sourceTop,
                        "Source top moved when the resized presentation committed")
                    check(controller.source.isResizePositionPinned,
                        "Source top lock was dropped after resize completion")
                    let resizedPreviewTop=controller.preview.debugFirstHeadingViewportY
                    check(resizedPreviewTop==previewTop,
                        "Preview top moved when the resized presentation committed: before=\(previewTop), after=\(String(describing:resizedPreviewTop)), \(controller.preview.debugResizeAnchorState)")
                    completion()
                }
                return
            }
            window.setContentSize(sizes[index])
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            check(controller.preview.previewView.debugPaintedBitmapTop==0,
                "Cached preview bitmap moved away from the viewport top during resize")
            // Width changes schedule TextKit layout and an Ultralight frame.
            // Inspect after both have had an opportunity to adjust their clips.
            wait(500,{controller.preview.debugFirstHeadingViewportY==previewTop},
                "Preview first heading did not settle during live resize") {
                window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
                check(controller.preview.previewView.debugPaintedBitmapTop==0,
                    "Replacement preview bitmap moved away from the viewport top after resize")
                check(controller.source.debugFirstLineViewportY==sourceTop,
                    "Source first heading moved after deferred top-anchored live-resize work")
                guard let currentPreviewTop=controller.preview.debugFirstHeadingViewportY else {
                    fail("Preview first heading disappeared during top-anchored live resize")
                }
                check(currentPreviewTop==previewTop,
                    "Preview first heading moved after deferred top-anchored live-resize work")
                step(index+1)
            }
        }
        step(0)
    }
    private static func continueAfterTopResize(_ controller:EditorWindowController,document:MarkdownDocument,
        startupCount:Int,wait:@escaping(Int,@escaping()->Bool,String,@escaping()->Void)->Void) {
        let preview=controller.preview,source=controller.source
            source.reveal(document.source.count,alignTop:false)
            wait(800,{controller.hasPreparedDocument && preview.coversSourceViewport && !preview.isShowingLoadingState &&
                preview.displayedSourceRange.map{NSMaxRange($0)>=document.source.count-1}==true},
                "A cached deep jump did not publish") {
                check(preview.displaysCompleteDocument,
                    "A deep jump after background completion must use the complete retained presentation")
                check(controller.hasPreparedDocument,"The deep jump should use the fully prepared retained tree")
                let retainedFrame=preview.committedFrameID
                let crossRevisionCommits=preview.crossRevisionCommitCount
                let transientRevision=document.revision+1
                document.parser.debugFailNextRequests()
                document.replace(NSRange(location:document.source.count,length:0),with:"\n\n## TRANSIENT_PARSE_EDIT\n\nRecovered automatically.\n")
                check(!preview.isShowingLoadingState,
                    "An edit must retain the committed preview without flashing the loading layer")
                check(preview.committedFrameID==retainedFrame,
                    "An edit must leave the committed frame visible while its replacement prepares")
                source.reveal(document.source.count,alignTop:false)
                wait(800,{document.revision==transientRevision && preview.lastRevision==transientRevision &&
                    preview.previewView.debugText.contains("TRANSIENT_PARSE_EDIT")},"Transient parser failure did not recover") {
                    check(preview.crossRevisionCommitCount>crossRevisionCommits,
                        "The edit did not commit a cross-revision preview replacement")
                    check(preview.committedFrameID>retainedFrame,
                        "A cross-revision edit did not publish a new atomic preview frame")
                    check(!controller.isShowingParseError,"A successful automatic retry must clear the parse error")
                    let retainedRevision=preview.displayedDocumentRevision,repeatedRevision=document.revision+1
                    document.parser.debugFailNextRequests(2)
                    document.replace(NSRange(location:document.source.count,length:0),with:"\n\n## REPEATED_PARSE_EDIT\n\nRecovered manually.\n")
                    source.reveal(document.source.count,alignTop:false)
                    wait(800,{controller.isShowingParseError},"Repeated parser failure did not expose Retry") {
                        check(preview.displayedDocumentRevision==retainedRevision,
                            "Repeated parser failure must retain the last successful preview revision")
                        check(preview.previewView.debugText.contains("TRANSIENT_PARSE_EDIT") && !preview.isShowingLoadingState,
                            "Repeated parser failure must leave the last successful preview visible")
                        controller.debugRetryFailedParse()
                        wait(800,{document.revision==repeatedRevision && preview.lastRevision==repeatedRevision &&
                            preview.previewView.debugText.contains("REPEATED_PARSE_EDIT")},"Manual parser retry did not recover") {
                            continueAfterRecoveredParse(controller,document:document,startupCount:startupCount,wait:wait)
                        }
                    }
                }
            }
    }
    private static func verifyMiddleResizeAnchor(_ controller:EditorWindowController,document:MarkdownDocument,
        wait:@escaping(Int,@escaping()->Bool,String,@escaping()->Void)->Void,completion:@escaping()->Void) {
        guard let window=controller.window else{fail("Missing resize regression window")}
        let source=controller.source,preview=controller.preview
        source.reveal(0,alignTop:true)
        window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
        let beforeNoMotionX=source.debugTextViewportX
        controller.windowWillStartLiveResize(Notification(name:NSWindow.willStartLiveResizeNotification,object:window))
        controller.windowDidEndLiveResize(Notification(name:NSWindow.didEndLiveResizeNotification,object:window))
        window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
        check(abs(source.debugTextViewportX-beforeNoMotionX)<0.1,
            "No-motion resize shifted source text horizontally: before=\(beforeNoMotionX), after=\(source.debugResizeState)")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.06) {
        window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
        check(abs(source.debugTextViewportX-beforeNoMotionX)<0.1,
            "Deferred no-motion resize shifted source text horizontally: before=\(beforeNoMotionX), after=\(source.debugResizeState)")
        check(abs(source.canvas.frame.width-source.scroll.contentSize.width)<0.1,
            "Source document width did not track the scrollable viewport after scroller retile")
        let heading=(document.source.string as NSString).range(of:"## Section 56 — observing a changing landscape")
        guard heading.location != NSNotFound else{fail("Missing Section 56 fixture")}
        source.debugAlignViewport(at:heading.location,viewportY:source.bounds.height/2)
        preview.moveViewport()
        wait(800,{preview.coversSourceViewport &&
            abs((preview.previewView.geometry()?.width ?? 0)-preview.bounds.width)<1 &&
            preview.debugScrollMapError.map{abs($0)<0.01}==true},
            "The middle viewport did not settle before resize: covers=\(preview.coversSourceViewport), webWidth=\(preview.previewView.geometry()?.width ?? -1), boundsWidth=\(preview.bounds.width), mapError=\(String(describing:preview.debugScrollMapError)), \(preview.debugGeometry())") {
            let original=window.contentLayoutRect.size
            controller.windowWillStartLiveResize(Notification(name:NSWindow.willStartLiveResizeNotification,object:window))
            let anchor=source.debugRenderedViewportAnchor
            guard let sourceY=source.debugRenderedViewportY(for:anchor),
                  let previewY=preview.debugResizeAnchorViewportY else {
                fail("Could not capture both resize anchors")
            }
            @MainActor func assertAnchors(_ stage:String) {
                check(source.debugRenderedViewportY(for:anchor).map{abs($0-sourceY)<1}==true,
                    "Source visible top moved \(stage): \(source.debugResizeState)")
                check(preview.debugResizeAnchorViewportY.map{abs($0-previewY)<1}==true,
                    "Preview visible top moved \(stage): \(preview.debugResizeAnchorState)")
            }
            let sizes=[NSSize(width:original.width-190,height:original.height-100),
                       NSSize(width:original.width+170,height:original.height+80)]
            @MainActor func step(_ index:Int) {
                guard index<sizes.count else {
                    window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
                    let before=capture(source.scroll.contentView)
                    let previewBefore=capture(preview)
                    writeVisualCapture(before,suffix:"before-release")
                    writeVisualCapture(previewBefore,suffix:"preview-before-release")
                    controller.windowDidEndLiveResize(Notification(name:NSWindow.didEndLiveResizeNotification,object:window))
                    check(!preview.isShowingLoadingState,
                        "Resize release masked the already reflowed preview")
                    assertAnchors("at mouse-up")
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.12) {
                        window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
                        let after=capture(source.scroll.contentView)
                        let previewAfter=capture(preview)
                        check(!preview.isShowingLoadingState,
                            "Deferred resize release masked the preview")
                        writeVisualCapture(after,suffix:"after-release")
                        writeVisualCapture(previewAfter,suffix:"preview-after-release")
                        // Layout completes asynchronously after release. The
                        // semantic anchor, rather than an exact bitmap match,
                        // is the stability contract.
                        check(preview.debugResizeAnchorViewportY.map{abs($0-previewY)<1}==true,
                            "Preview visible top moved after deferred layout: \(preview.debugResizeAnchorState)")
                        window.setContentSize(NSSize(width:sizes[index-1].width-60,
                            height:sizes[index-1].height-30))
                        window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
                        DispatchQueue.main.asyncAfter(deadline:.now()+0.06) {
                            window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
                            assertAnchors("after a late frame")
                            completion()
                        }
                    }
                    return
                }
                window.setContentSize(sizes[index])
                window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
                DispatchQueue.main.asyncAfter(deadline:.now()+0.04) {
                    window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
                    assertAnchors("during resize frame \(index)")
                    step(index+1)
                }
            }
            step(0)
        }
        }
    }
    private static func continueAfterRecoveredParse(_ controller:EditorWindowController,document:MarkdownDocument,
        startupCount:Int,wait:@escaping(Int,@escaping()->Bool,String,@escaping()->Void)->Void) {
        verifyParagraphInsertionStability(controller,document:document,wait:wait) {
            verifyTypingStability(controller,document:document,wait:wait) {
                continueAfterTyping(controller,document:document,startupCount:startupCount,wait:wait)
            }
        }
    }
    private static func verifyClickEditAlignment(_ controller:EditorWindowController,document:MarkdownDocument,
        wait:@escaping(Int,@escaping()->Bool,String,@escaping()->Void)->Void,completion:@escaping()->Void) {
        guard let window=controller.window else{fail("Missing click/edit regression window")}
        let source=controller.source,preview=controller.preview
        let marker="### Measurements at station 36"
        let initial=(document.source.string as NSString).range(of:marker).location
        guard initial != NSNotFound else{fail("Missing Section 36 click/edit regression fixture")}
        source.debugAlignViewport(at:initial,viewportY:source.bounds.height/2)
        wait(800,{preview.coversSourceViewport && preview.debugScrollMapError.map{abs($0)<0.01}==true},
            "Mid-document viewport did not center before click/edit regression") {
            let size=window.contentLayoutRect.size
            controller.windowWillStartLiveResize(Notification(name:NSWindow.willStartLiveResizeNotification,object:window))
            window.setContentSize(NSSize(width:size.width-96,height:size.height))
            window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
            controller.windowDidEndLiveResize(Notification(name:NSWindow.didEndLiveResizeNotification,object:window))
            wait(800,{abs((preview.previewView.geometry()?.width ?? 0)-preview.bounds.width)<1},
                "Click/edit regression resize did not settle") {
                let center=source.debugRenderedOffset(atViewportY:source.bounds.height/2)
                let text=document.source.string as NSString
                let search=NSRange(location:max(0,center-2000),length:min(text.length,center+2000)-max(0,center-2000))
                var cursor=search.location,candidates=[(offset:Int,distance:CGFloat)]()
                while cursor<NSMaxRange(search) {
                    let range=text.range(of:"\n\n",options:[],range:NSRange(location:cursor,length:NSMaxRange(search)-cursor))
                    if range.location==NSNotFound {break}
                    let offset=NSMaxRange(range)
                    if let y=source.debugRenderedViewportY(for:offset) {
                        candidates.append((offset,abs(y-source.bounds.height/2)))
                    }
                    cursor=max(cursor+1,offset)
                }
                guard let insertion=candidates.min(by:{$0.distance<$1.distance})?.offset else {
                    fail("Missing centered paragraph boundary")
                }
                let beforeClick=source.viewportOrigin
                source.debugClickInsertionPoint(at:insertion)
                check(abs(source.viewportOrigin-beforeClick)<0.01,
                    "Clicking the editor after resize moved its viewport (\(beforeClick) -> \(source.viewportOrigin))")
                source.textView.insertText("What's\n\n",replacementRange:source.textView.selectedRange())
                wait(800,{preview.lastRevision==document.revision &&
                    preview.debugParagraphViewportY(containing:"What's") != nil},
                    "Typed click/edit paragraph did not reach the preview") {
                    let sourceY=source.debugRenderedViewportY(for:insertion)
                    let previewY=preview.debugParagraphViewportY(containing:"What's")
                    check(sourceY.flatMap{a in previewY.map{abs(a-$0)<32}}==true,
                        "Typed paragraph is not visually center-aligned (source \(String(describing:sourceY)), preview \(String(describing:previewY)), mapError \(String(describing:preview.debugScrollMapError)))")
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
                        window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
                        let settledSourceY=source.debugRenderedViewportY(for:insertion)
                        let settledPreviewY=preview.debugParagraphViewportY(containing:"What's")
                        check(settledSourceY.flatMap{a in settledPreviewY.map{abs(a-$0)<32}}==true,
                            "Typed paragraph moved out of alignment after painting")
                        if let content=window.contentView {
                            writeVisualCapture(capture(content),suffix:"after-click-edit")
                        }
                        completion()
                    }
                }
            }
        }
    }
    private static func verifyParagraphInsertionStability(_ controller:EditorWindowController,document:MarkdownDocument,
        wait:@escaping(Int,@escaping()->Bool,String,@escaping()->Void)->Void,completion:@escaping()->Void) {
        let preview=controller.preview,source=controller.source,following="Recovered manually."
        let location=(document.source.string as NSString).range(of:following).location
        guard location != NSNotFound else{fail("Missing paragraph insertion fixture")}
        source.reveal(location,alignTop:true)
        wait(800,{preview.coversSourceViewport && preview.debugParagraphViewportY(containing:following) != nil},
            "The following paragraph was not visible before insertion") {
            let retainedFrame=preview.committedFrameID
            var committedPositions=[CGFloat]()
            preview.debugPresentationCommitted = {
                if preview.displayedDocumentRevision==document.revision,
                   let y=preview.debugParagraphViewportY(containing:following) {committedPositions.append(y)}
            }
            source.textView.setSelectedRange(NSRange(location:location,length:0))
            source.textView.insertText("Inserted paragraph.\n\n",replacementRange:source.textView.selectedRange())
            check(!preview.isShowingLoadingState,
                "A paragraph insertion must retain the committed preview without a loading flash")
            check(preview.committedFrameID==retainedFrame,
                "A paragraph insertion must remain offscreen until its replacement is ready")
            wait(800,{preview.lastRevision==document.revision &&
                preview.previewView.debugText.contains("Inserted paragraph.")},
                "The inserted paragraph did not reach the preview") {
                guard let settled=preview.debugParagraphViewportY(containing:following) else {
                    fail("The following paragraph disappeared after insertion")
                }
                DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
                    guard let after=preview.debugParagraphViewportY(containing:following) else {
                        fail("The following paragraph disappeared while geometry settled")
                    }
                    check(!committedPositions.isEmpty,
                        "The paragraph insertion did not publish a measured preview frame")
                    if let low=committedPositions.min(),let high=committedPositions.max() {
                        check(high-low<0.5,
                            "The following paragraph oscillated across committed insertion frames: \(committedPositions)")
                    }
                    check(abs(after-settled)<0.5,
                        "The following paragraph moved after the insertion frame committed")
                    // The paragraph now exists. A second Enter changes source
                    // metadata but must still publish one coherent frame.
                    let paragraph="Inserted paragraph."
                    let paragraphEnd=location+(paragraph as NSString).length
                    let previousFrame=preview.committedFrameID
                    let extraEnterOrigin=preview.clipOrigin
                    var enterPositions=[CGFloat]()
                    preview.debugPresentationCommitted = {
                        if preview.displayedDocumentRevision==document.revision,
                           let y=preview.debugParagraphViewportY(containing:following) {enterPositions.append(y)}
                    }
                    source.textView.setSelectedRange(NSRange(location:paragraphEnd,length:0))
                    source.textView.insertText("\n",replacementRange:source.textView.selectedRange())
                    check(!preview.isShowingLoadingState,
                        "An extra paragraph separator must not flash the loading layer")
                    wait(800,{preview.lastRevision==document.revision},
                        "The extra paragraph separator did not reach the preview") {
                        check(preview.committedFrameID>previousFrame,
                            "An extra paragraph separator must publish a coherent preview frame")
                        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
                            preview.debugPresentationCommitted=nil
                            guard let afterEnter=preview.debugParagraphViewportY(containing:following) else {
                                fail("The following paragraph disappeared after the extra Enter")
                            }
                            if let low=enterPositions.min(),let high=enterPositions.max() {
                                check(high-low<0.5,
                                    "The following paragraph oscillated across extra-Enter frames")
                            }
                            check(enterPositions.last.map{abs(afterEnter-$0)<0.5}==true,
                                "The following paragraph moved after the extra Enter settled")
                            check(abs(preview.clipOrigin-extraEnterOrigin)<0.01,
                                "The extra Enter changed the preview scroll origin")
                            completion()
                        }
                    }
                }
            }
        }
    }
    private static func verifyTypingStability(_ controller:EditorWindowController,document:MarkdownDocument,
        wait:@escaping(Int,@escaping()->Bool,String,@escaping()->Void)->Void,completion:@escaping()->Void) {
        let preview=controller.preview,source=controller.source
        source.reveal(document.source.count,alignTop:false)
        source.textView.setSelectedRange(NSRange(location:document.source.count,length:0))
        let characters=Array(" flickercheck")
        var expected=""
        func step(_ index:Int) {
            guard index<characters.count else {completion();return}
            let previousRevision=document.revision
            let retainedFrame=preview.committedFrameID
            let crossRevisionCommits=preview.crossRevisionCommitCount
            expected.append(characters[index])
            source.textView.insertText(String(characters[index]),replacementRange:source.textView.selectedRange())
            check(document.revision==previousRevision+1,"A simulated keystroke must create one document revision")
            check(!preview.isShowingLoadingState,
                "A keystroke must retain the committed preview without flashing the loading layer")
            check(preview.committedFrameID==retainedFrame,
                "A keystroke must not replace the visible frame before rendering finishes")
            wait(800,{preview.lastRevision==document.revision && preview.previewView.debugText.contains(expected)},
                "A simulated keystroke did not reach the preview") {
                check(preview.crossRevisionCommitCount>crossRevisionCommits,
                    "A simulated keystroke did not commit a preview replacement")
                check(preview.committedFrameID>retainedFrame,
                    "A simulated keystroke did not publish a new coherent frame")
                step(index+1)
            }
        }
        step(0)
    }
    private static func continueAfterTyping(_ controller:EditorWindowController,document:MarkdownDocument,
        startupCount:Int,wait:@escaping(Int,@escaping()->Bool,String,@escaping()->Void)->Void) {
        let preview=controller.preview,source=controller.source
        check(preview.preparedFragmentCount>0,"A visible edit must retain a rendered presentation")
        guard let window=controller.window else{fail("Missing resize window")}
        let oldSize=window.contentLayoutRect.size
        controller.windowWillStartLiveResize(Notification(name:NSWindow.willStartLiveResizeNotification,object:window))
        window.setContentSize(NSSize(width:oldSize.width-146,height:oldSize.height))
        window.contentView?.layoutSubtreeIfNeeded()
        controller.windowDidEndLiveResize(Notification(name:NSWindow.didEndLiveResizeNotification,object:window))
        wait(300,{abs((preview.previewView.geometry()?.width ?? 0)-preview.bounds.width)<=1},
            "Ultralight did not settle after resize") {
            source.reveal(0,alignTop:true)
            wait(800,{preview.coversSourceViewport && preview.previewView.debugText.contains("Markato")},
                "Return to the cached first viewport failed") {
                check(preview.displaysCompleteDocument,
                    "Returning to the top after background completion must retain the complete presentation")
                check(startupCount>0,"Startup must mount semantic entries")
                print("INTEGRATION PASSED: prioritized first view, complete background presentation, presentation recovery, automatic and manual parse recovery, retained stale preview, cached navigation, stable paragraph insertion, rapid typing, edit, resize, and return-to-top scrolling")
                if CommandLine.arguments.contains("--diagnostics") {
                    try? TimingDiagnostics.shared.snapshot().json().write(to:URL(fileURLWithPath:"/private/tmp/markato-ultralight-integration-timings.json"),options:.atomic)
                }
                exit(EXIT_SUCCESS)
            }
        }
    }
    private static func verifyLayoutIndex() {
        let doc=MarkdownDocument();fixtureDocuments.append(doc)
        doc.setInitialText((0..<2000).map{"Line \($0): "+String(repeating:"wrapped Unicode 🧮 text ",count:5)+"\r\n"}.joined())
        let model=PreparedDocument(),source=SourceEditor(document:doc,prepared:model)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:520,height:400),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView=source;source.frame=window.contentLayoutRect;source.layoutSubtreeIfNeeded()
        doc.edited={selection,_,edit in source.documentEdited(selection:selection,edit:edit)}
        let prefix=source.debugMeasuredPosition(for:500)
        func validate(_ stage:Int) {
            check(model.sourceLayout.length==doc.source.count,"Measured index must cover the current source after edit \(stage): index=\(model.sourceLayout.length), source=\(doc.source.count), dirty=\(source.debugResizeState)")
            let manager=source.textView.layoutManager!
            for offset in stride(from:0,to:doc.source.count,by:137) {
                let glyph=manager.glyphIndexForCharacter(at:offset)
                let native=manager.lineFragmentUsedRect(forGlyphAt:glyph,effectiveRange:nil)
                check(abs(source.debugMeasuredPosition(for:offset)-native.minY-source.textView.textContainerInset.height)<0.001,"Local edit \(stage): cached wrapped-line coordinates must equal native geometry at \(offset)")
            }
            if stage<4 {check(source.debugMeasuredPosition(for:500)==prefix,"Local edits must retain the measured prefix")}
        }
        func step(_ stage:Int) {
            validate(stage)
            switch stage {
            case 0:
                source.textView.insertText("a long inserted line\r\n**new text**",replacementRange:NSRange(location:doc.source.lineStart(1500)+7,length:4))
            case 1:
                source.textView.insertText("joined",replacementRange:doc.source.lines(1800,1803))
                source.textView.insertText("another\r\nline",replacementRange:NSRange(location:doc.source.lineStart(1000)+3,length:1))
            case 2:
                source.textView.insertText("\r\nLast 🧮 paragraph.",replacementRange:NSRange(location:doc.source.count,length:0))
            case 3:
                source.applyHighlights([SyntaxSpan(kind:"ATXHeading1",from:doc.source.lineStart(1600),to:doc.source.lineStart(1601))],in:doc.source.lines(1600,1601))
            case 4:
                source.frame.size.width=380;source.layoutSubtreeIfNeeded()
            case 5:
                doc.replace(NSRange(location:doc.source.lineStart(900)+4,length:3),with:"model edit\r\n")
            default:
                print("LAYOUT INDEX PASSED: local multiline edits, deletion, Unicode/CRLF, append, typography and resize match independent native glyph coordinates")
                if CommandLine.arguments.contains("--diagnostics") {
                    try? TimingDiagnostics.shared.snapshot().json().write(to:URL(fileURLWithPath:"/private/tmp/markato-layout-index-timings.json"))
                }
                exit(EXIT_SUCCESS)
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.05){step(stage+1)}
        }
        step(0)
    }
}

#endif
