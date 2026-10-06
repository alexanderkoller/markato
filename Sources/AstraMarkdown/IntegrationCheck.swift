import AppKit
import MarkdownCore

/// Runs against an actual window and TextKit network, without modifying user documents.
@MainActor enum IntegrationCheck {
    private static func check(_ condition:@autoclosure()->Bool,_ message:String) {
        if !condition() { fail(message) }
    }
    private static func fail(_ message:String)->Never {
        FileHandle.standardError.write(Data("INTEGRATION FAILED: \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }
    static func run(_ document:MarkdownDocument) {
        guard let controller = document.windowControllers.first as? EditorWindowController else { fail("Missing editor window") }
        controller.window?.orderBack(nil)
        controller.window?.makeFirstResponder(controller.source.textView)
        let original = document.source.string
        controller.source.textView.setSelectedRange(NSRange(location:0,length:0))
        document.undoManager?.beginUndoGrouping()
        controller.source.textView.insertText("Edited ",replacementRange:NSRange(location:0,length:0))
        document.undoManager?.endUndoGrouping()
        check(document.source.string == "Edited "+original,"Native text edits must update source")
        check(NSApp.sendAction(#selector(EditorWindowController.undo(_:)),to:nil,from:nil),"Undo must be available through the responder chain")
        check(document.source.string == original,"Undo must restore source across working-set reloads")
        document.undoManager?.redo()
        check(document.source.string == "Edited "+original,"Redo must restore edits")
        document.undoManager?.undo()

        do {
            let encoded = try document.data(ofType:"Markdown")
            let copy = MarkdownDocument(); try copy.read(from:encoded,ofType:"Markdown")
            check(copy.source.string == original,"File encoding round trip")
            let crlf = MarkdownDocument(); try crlf.read(from:Data("one\r\ntwo\r\n".utf8),ofType:"Markdown")
            let roundTrip = try crlf.data(ofType:"Markdown")
            check(roundTrip == Data("one\r\ntwo\r\n".utf8),"CRLF preservation")
        } catch { fail("File round trip failed: \(error)") }

        let large = (0..<6000).map { "## Passage \($0)\n\nA **bold** paragraph with *emphasis* and an inline equation $x^2$.\n\n" }.joined()
        document.setInitialText(large)
        let oldCaret = controller.source.selection
        let target = document.source.lineStart(12000)
        controller.source.reveal(target,alignTop:true)
        check(NSEqualRanges(controller.source.selection,oldCaret),"Scrolling must preserve the global caret")
        check(controller.source.windowRange.location>0,"Distant navigation must replace the source working set")
        check(controller.source.windowRange.length<30000,"TextKit working set must stay local")
        let anchorLine = document.source.line(at:controller.source.viewportAnchor)
        check(abs(anchorLine-12000)<8,"Navigation must show the requested passage")
        for width:CGFloat in [920,1120,760,1040,920] {
            controller.window?.setContentSize(NSSize(width:width,height:650))
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            print("RESIZE: width=\(width), beforeLine=\(anchorLine), afterLine=\(document.source.line(at:controller.source.viewportAnchor)), window=\(controller.source.windowRange), bounds=\(controller.source.scroll.contentView.bounds), frame=\(controller.source.textView.frame)"); fflush(stdout)
            check(abs(document.source.line(at:controller.source.viewportAnchor)-anchorLine)<8,"Resizing must preserve the distant passage")
        }
        waitForPreview(controller,document:document,remaining:100)
    }
    private static func waitForPreview(_ controller:EditorWindowController,document:MarkdownDocument,remaining:Int) {
        if controller.hasPreparedViewport && controller.preview.lastRevision == document.revision && controller.preview.preparedFragmentCount>0 {
            print("VIEWPORT CHECK: fragments=\(controller.preview.preparedFragmentCount), sourceWindow=\(controller.source.windowRange), caret=\(controller.source.selection), scroll=\(controller.source.scroll.contentView.bounds), textFrame=\(controller.source.textView.frame)")
            fflush(stdout)
            check(controller.preview.preparedFragmentCount<80,"Preview must contain only a viewport window")
            check(controller.source.windowRange.location>0,"Highlighting must preserve the distant viewport")
            check(controller.source.textView.textLayoutManager != nil,"Keep TextKit 2 active")
            verifyWebPreview(controller,document:document)
        } else if remaining == 0 { fail("Preview did not finish for latest document revision") }
        else { DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { waitForPreview(controller,document:document,remaining:remaining-1) } }
    }
    private static func verifyWebPreview(_ controller:EditorWindowController,document:MarkdownDocument) {
        verifyContinuousScroll(controller,document:document)
        verifyFrozenScroll(controller)
        verifyGesturePhases(controller) {verifyCachedScroll(controller,document:document)}
    }
    private static func verifyCachedScroll(_ controller:EditorWindowController,document:MarkdownDocument) {
        let patches=controller.preview.patchCount,origin=controller.preview.clipOrigin
        let next=document.source.lineStart(document.source.line(at:controller.source.viewportAnchor)+2)
        controller.source.reveal(next,alignTop:true)
        check(controller.preview.patchCount==patches,"Cached scroll must not issue a JavaScript patch")
        check(controller.preview.clipOrigin != origin,"Cached scroll must move the native preview clip immediately")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15) {
            check(controller.preview.patchCount==patches,"Cached scrolling must keep the existing DOM")
            controller.preview.webView.evaluateJavaScript("JSON.stringify({count:document.querySelectorAll('#preview>section').length,math:document.querySelectorAll('.katex').length,text:document.getElementById('preview').innerText})") {value,error in
                guard error==nil,let string=value as? String,let data=string.data(using:.utf8),let result=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else {fail("WebKit did not return preview content")}
                check((result["count"] as? Int ?? 0)>0 && (result["count"] as? Int ?? 1000)<80,"DOM must stay limited to the viewport")
                check((result["math"] as? Int ?? 0)>0,"KaTeX must render the visible math")
                check((result["text"] as? String ?? "").contains("Passage 3000"),"Preview must correspond to the distant source passage")
                verifyEditedPreview(controller,document:document)
            }
        }
    }
    private static func verifyContinuousScroll(_ controller:EditorWindowController,document:MarkdownDocument) {
        let source=controller.source,start=source.scroll.contentView.bounds.minY
        let patches=controller.preview.patchCount
        var previous=controller.preview.clipOrigin
        var distances=[CGFloat]()
        // Move the actual source clip in fractional-pixel increments across
        // wrapped lines, blank lines and a heading boundary in a prepared region.
        for i in 1...160 {
            source.scroll.contentView.scroll(to:NSPoint(x:0,y:start+CGFloat(i)*0.5))
            source.scroll.reflectScrolledClipView(source.scroll.contentView)
            let current=controller.preview.clipOrigin
            distances.append(current-previous);previous=current
        }
        check(distances.allSatisfy{$0>0},"Every sub-line source scroll must advance the preview smoothly")
        check((distances.max() ?? 100)<5,"Crossing source line/block boundaries must not jump the preview")
        check(controller.preview.patchCount==patches,"Sub-line scrolling must not patch the DOM")
        source.scroll.contentView.scroll(to:NSPoint(x:0,y:start))
        source.scroll.reflectScrolledClipView(source.scroll.contentView)
        print("CONTINUOUS SCROLL: 160 half-pixel steps, preview step min=\(distances.min() ?? 0), max=\(distances.max() ?? 0), DOM patches=0")
    }
    private static func verifyFrozenScroll(_ controller:EditorWindowController) {
        let source=controller.source,preview=controller.preview
        check(preview.scrollLandmarkCount>0 && preview.scrollLandmarkCount<preview.preparedFragmentCount,"Scroll landmarks must be sparse headings/images")
        let position=preview.sourcePosition,revision=preview.sourceGeometryRevision
        source.beginScrollGesture()
        check(preview.isScrollMappingFrozen,"Native source gesture must freeze preview mapping")
        let origin=preview.clipOrigin
        // A new layout report must not alter the captured mapping mid-gesture.
        preview.sourcePosition={offset in (position?(offset) ?? 0)*2}
        preview.sourceGeometryRevision={ (revision?() ?? 0)+1000 }
        preview.setAnchor(source.viewportAnchor)
        check(abs(preview.clipOrigin-origin)<0.001,"Layout changes must not replace frozen landmark coordinates")
        preview.sourcePosition=position;preview.sourceGeometryRevision=revision
        source.endScrollGesture()
        check(!preview.isScrollMappingFrozen,"Gesture completion must release the mapping")
        preview.setAnchor(source.viewportAnchor)
        print("FROZEN SCROLL: sparse landmarks, changed geometry ignored during gesture, released after gesture")
    }
    private static func verifyGesturePhases(_ controller:EditorWindowController,completion:@escaping()->Void) {
        let source=controller.source,preview=controller.preview
        func event(_ phase:Int64,_ momentum:Int64=0)->NSEvent {
            guard let cg=CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:0,wheel2:0,wheel3:0) else {fail("Cannot create scroll event")}
            cg.setIntegerValueField(.scrollWheelEventScrollPhase,value:phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase,value:momentum)
            guard let event=NSEvent(cgEvent:cg) else {fail("Cannot bridge scroll event")}
            return event
        }
        source.scroll.scrollWheel(with:event(1))
        check(preview.isScrollMappingFrozen,"Wheel began must capture the mapping before movement")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
            check(preview.isScrollMappingFrozen,"A pause with fingers down must not end a phased gesture")
            source.scroll.scrollWheel(with:event(4))
            check(preview.isScrollMappingFrozen,"Finger release must allow the transition to momentum")
            source.scroll.scrollWheel(with:event(0,1))
            DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
                check(preview.isScrollMappingFrozen,"Momentum must keep the same snapshot")
                source.scroll.scrollWheel(with:event(0,3))
                check(!preview.isScrollMappingFrozen,"Momentum ended must release the snapshot")
                // Phase-less wheels are grouped until the tick stream is idle.
                source.scroll.scrollWheel(with:event(0))
                check(preview.isScrollMappingFrozen,"Mouse-wheel ticks must capture a mapping")
                DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
                    check(!preview.isScrollMappingFrozen,"An idle mouse-wheel burst must release its snapshot")
                    print("GESTURE PHASES: finger pause, finger-to-momentum transition, momentum end, mouse-wheel idle")
                    completion()
                }
            }
        }
    }
    private static func verifyEditedPreview(_ controller:EditorWindowController,document:MarkdownDocument) {
        let at=document.source.lineStart(document.source.line(at:controller.source.viewportAnchor)+2)
        document.replace(NSRange(location:at,length:0),with:"VISIBLE_EDIT ")
        pollEditedPreview(controller,document:document,remaining:100)
    }
    private static func pollEditedPreview(_ controller:EditorWindowController,document:MarkdownDocument,remaining:Int) {
        guard remaining>0 else {fail("Edited WebKit preview did not catch up")}
        if controller.preview.lastRevision==document.revision {
            controller.preview.webView.evaluateJavaScript("document.getElementById('preview').innerText") {value,error in
                if error==nil,(value as? String)?.contains("VISIBLE_EDIT")==true {
                    verifyExampleAssets(controller,document:document)
                } else {DispatchQueue.main.asyncAfter(deadline:.now()+0.1) {pollEditedPreview(controller,document:document,remaining:remaining-1)}}
            }
        } else {DispatchQueue.main.asyncAfter(deadline:.now()+0.1) {pollEditedPreview(controller,document:document,remaining:remaining-1)}}
    }
    private static func verifyExampleAssets(_ controller:EditorWindowController,document:MarkdownDocument) {
        document.setInitialText(AppDelegate.sample)
        let text=document.source.string as NSString
        let at=text.range(of:"![A smooth").location
        check(at != NSNotFound,"Bundled sample must contain its local image")
        controller.source.reveal(at,alignTop:true)
        pollExampleAssets(controller,document:document,remaining:100)
    }
    private static func pollExampleAssets(_ controller:EditorWindowController,document:MarkdownDocument,remaining:Int) {
        guard remaining>0 else{
            controller.preview.webView.evaluateJavaScript("JSON.stringify({images:[...document.images].map(i=>({src:i.src,width:i.naturalWidth,complete:i.complete})),text:document.getElementById('preview').innerText})") {value,_ in
                print("IMAGE DIAGNOSTIC: \(value ?? "none")");fflush(stdout);fail("Bundled image did not load")
            }
            return
        }
        controller.preview.webView.evaluateJavaScript("[...document.images].some(i=>i.complete&&i.naturalWidth>0)") {value,error in
            if error==nil,(value as? Bool)==true,controller.hasPreparedViewport,controller.preview.lastRevision==document.revision {
                let text=document.source.string as NSString
                let at=text.range(of:"| 500 |").location
                check(at != NSNotFound,"Bundled sample must contain table row 500")
                controller.window?.setContentSize(NSSize(width:1600,height:1200))
                controller.window?.contentView?.layoutSubtreeIfNeeded()
                controller.source.reveal(at,alignTop:true)
                let source=controller.source
                var previousLine=document.source.line(at:source.viewportAnchor)
                for _ in 0..<100 {
                    let y=source.scroll.contentView.bounds.minY+20
                    source.scroll.contentView.scroll(to:NSPoint(x:0,y:y))
                    source.scroll.reflectScrolledClipView(source.scroll.contentView)
                    let line=document.source.line(at:source.viewportAnchor)
                    check(line>=previousLine && line-previousLine<5,"Working-window rollover must preserve the visible table passage")
                    check(source.textView.frame.maxY>=source.scroll.contentView.bounds.maxY,"Tall table viewport must remain filled with source text")
                    previousLine=line
                }
                check(abs(source.alignmentOffset-source.scroll.contentSize.height/2)<1,"Interior passages must use midpoint alignment")
                print("TABLE SOURCE: tall viewport, 100 scroll steps across working-window boundaries, no blank source tail")
                controller.source.reveal(at,alignTop:true)
                pollTable(controller,document:document,remaining:100)
            } else {DispatchQueue.main.asyncAfter(deadline:.now()+0.1) {pollExampleAssets(controller,document:document,remaining:remaining-1)}}
        }
    }
    private static func pollTable(_ controller:EditorWindowController,document:MarkdownDocument,remaining:Int) {
        guard remaining>0 else{fail("Table viewport did not render")}
        controller.preview.webView.evaluateJavaScript("JSON.stringify({tables:[...document.querySelectorAll('table')].filter(t=>t.getBoundingClientRect().height>0).length,headers:[...document.querySelectorAll('thead')].filter(t=>t.getBoundingClientRect().height>0).length,rows:document.querySelectorAll('tbody tr').length,text:document.getElementById('preview').innerText})") {value,error in
            if error==nil,controller.hasPreparedViewport,controller.preview.lastRevision==document.revision,let string=value as? String,let data=string.data(using:.utf8),let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],(object["text"] as? String ?? "").contains("500"),(object["rows"] as? Int ?? 0)>0 {
                check((object["rows"] as? Int ?? 1000)<200,"Large table must render a row window, not all 800 rows")
                check((object["tables"] as? Int)==1 && (object["headers"] as? Int)==1,"Cached table batches must form one continuous table with one header")
                verifyEndNavigation(controller,document:document)
            } else {DispatchQueue.main.asyncAfter(deadline:.now()+0.1) {pollTable(controller,document:document,remaining:remaining-1)}}
        }
    }
    private static func verifyEndNavigation(_ controller:EditorWindowController,document:MarkdownDocument) {
        let source=controller.source
        guard let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:controller.window?.windowNumber ?? 0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:125) else {fail("Could not create Cmd-Down event")}
        source.textView.keyDown(with:event)
        check(source.selection.location==document.source.count,"Cmd-Down must move the global caret to EOF")
        check(source.viewportAnchor<document.source.count,"Cmd-Down must show text, not an empty estimated region")
        check(source.verticalPosition(for:document.source.count-2)<source.scroll.contentView.bounds.maxY-16,"Final source line must be fully visible")
        pollEndPreview(controller,document:document,remaining:100)
    }
    private static func pollEndPreview(_ controller:EditorWindowController,document:MarkdownDocument,remaining:Int) {
        guard remaining>0 else {fail("End preview did not become fully visible")}
        controller.preview.webView.evaluateJavaScript("JSON.stringify({text:document.getElementById('preview').innerText,bottom:document.getElementById('preview').lastElementChild.getBoundingClientRect().bottom})") {value,error in
            if error==nil,controller.hasPreparedViewport,let string=value as? String,let data=string.data(using:.utf8),let result=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],(result["text"] as? String ?? "").contains("your own documents."),let bottom=result["bottom"] as? Double {
                check(CGFloat(bottom)<=controller.preview.visibleWebRange.upperBound-8,"Final preview line must be fully visible")
                print("END NAVIGATION: Cmd-Down moved caret to EOF; source and preview final lines fully visible")
                pollPlotPreparation(controller,document:document,remaining:100)
            }else {DispatchQueue.main.asyncAfter(deadline:.now()+0.1) {pollEndPreview(controller,document:document,remaining:remaining-1)}}
        }
    }
    private static func pollPlotPreparation(_ controller:EditorWindowController,document:MarkdownDocument,remaining:Int) {
        guard remaining>0 else {fail("Background preparation did not finish before plot scroll check")}
        if controller.hasPreparedDocument {
            let at=(document.source.string as NSString).range(of:"## Section 60").location
            controller.source.reveal(at,alignTop:true)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
                controller.source.beginScrollGesture()
                scrollPastPlot(controller,document:document,remaining:300,observations:0)
            }
        }else {DispatchQueue.main.asyncAfter(deadline:.now()+0.1) {pollPlotPreparation(controller,document:document,remaining:remaining-1)}}
    }
    private static func scrollPastPlot(_ controller:EditorWindowController,document:MarkdownDocument,remaining:Int,observations:Int) {
        guard remaining>0 else {fail("Plot scrolling did not reach Section 65")}
        let text=document.source.string as NSString
        let section63=text.range(of:"## Section 63").location,section65=text.range(of:"## Section 65").location
        let source=controller.source
        if source.viewportAnchor>=section65 {
            source.endScrollGesture()
            check(observations>5,"Plot test must sample multiple frames after Section 63")
            print("PLOT SCROLL: \(observations) observations after Section 63, no reappearing image")
            pollPreparedDocument(controller,remaining:100);return
        }
        source.scroll.contentView.scroll(to:NSPoint(x:0,y:source.scroll.contentView.bounds.minY+15))
        source.scroll.reflectScrolledClipView(source.scroll.contentView)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.02) {
            controller.preview.webView.evaluateJavaScript("JSON.stringify([...document.images].map(i=>({top:i.getBoundingClientRect().top,bottom:i.getBoundingClientRect().bottom})))") {value,error in
                guard error==nil,let string=value as? String,let data=string.data(using:.utf8),let images=(try? JSONSerialization.jsonObject(with:data)) as? [[String:Double]] else {fail("Cannot measure plot geometry")}
                let past=source.viewportAnchor>=section63
                if past {
                    let visible=controller.preview.visibleWebRange
                    check(!images.contains{CGFloat($0["bottom"] ?? 0)>visible.lowerBound && CGFloat($0["top"] ?? 0)<visible.upperBound},"Plot must not flash back after Section 63 reaches the top")
                }
                scrollPastPlot(controller,document:document,remaining:remaining-1,observations:observations+(past ? 1:0))
            }
        }
    }
    private static func pollPreparedDocument(_ controller:EditorWindowController,remaining:Int) {
        guard remaining>0 else{fail("Background preparation did not cover the document")}
        if controller.hasPreparedDocument {
            controller.source.reveal(0,alignTop:true)
            pollCachedJump(controller,remaining:100)
        } else {DispatchQueue.main.asyncAfter(deadline:.now()+0.1) {pollPreparedDocument(controller,remaining:remaining-1)}}
    }
    private static func pollCachedJump(_ controller:EditorWindowController,remaining:Int) {
        guard remaining>0 else{fail("Cached destination did not appear")}
        controller.preview.webView.evaluateJavaScript("document.getElementById('preview').innerText") {value,error in
            if error==nil,(value as? String)?.contains("AstraMarkdown — a long example")==true {
                check(controller.preview.preparedFragmentCount<80,"Warm jumps must keep the DOM bounded")
                print("INTEGRATION PASSED: native editing, undo/redo, encoding, CRLF, distant navigation, bounded source and DOM, resizing, KaTeX, synchronous clip scrolling without DOM updates, edited WebKit preview, local image, table row window, whole-document background HTML cache (\(controller.cachedPageCount) pages), cached destination jump")
                if CommandLine.arguments.contains("--diagnostics") {
                    TimingDiagnostics.shared.stop()
                    let snapshot=TimingDiagnostics.shared.snapshot()
                    for name in ["source.scroll","preview.clip.move","web.patch.roundtrip","web.dom.layout","parse.viewport.work","html.background.work"] {
                        check(snapshot.events.contains{$0.name==name},"Diagnostics must record \(name)")
                    }
                    do {
                        let url=URL(fileURLWithPath:"/private/tmp/astra-timings.json")
                        try snapshot.json(metadata:["fixture":"integration-test"]).write(to:url,options:.atomic)
                        print("DIAGNOSTICS PASSED: \(snapshot.events.count) events exported to \(url.path)")
                    } catch {fail("Diagnostics export failed: \(error)")}
                }
                exit(EXIT_SUCCESS)
            } else {DispatchQueue.main.asyncAfter(deadline:.now()+0.1) {pollCachedJump(controller,remaining:remaining-1)}}
        }
    }
}
