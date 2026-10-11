#if DEBUG
import AppKit
import HTMLPreview
import MarkdownCore

/// Runs against an actual window and TextKit network, without modifying user documents.
@MainActor enum IntegrationCheck {
    // Document windows and their queued AppKit callbacks may outlive a check.
    // Keep isolated fixtures alive until the native test process exits.
    private static var fixtureDocuments=[MarkdownDocument]()
    private static func check(_ condition:@autoclosure()->Bool,_ message:String) {
        if !condition() { fail(message) }
    }
    private static func fail(_ message:String)->Never {
        FileHandle.standardError.write(Data("INTEGRATION FAILED: \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }
    static func run(_ document:MarkdownDocument) {
        guard let controller=document.windowControllers.first as? EditorWindowController else {fail("Missing editor window")}
        if CommandLine.arguments.contains("--integration-layout-index") {
            verifyLayoutIndex();return
        }
        if CommandLine.arguments.contains("--integration-preview-jump") {
            controller.source.reveal(0,alignTop:true)
            controller.source.reveal(document.source.count)
            let started=DispatchTime.now().uptimeNanoseconds
            print("PREVIEW JUMP: fullCache=\(controller.hasPreparedDocument), \(controller.preview.debugGeometry())")
            func wait(_ remaining:Int) {
                guard remaining>0 else{fail("Jump preview did not become ready: \(controller.preview.debugGeometry())")}
                if !controller.preview.isShowingLoadingState,controller.preview.coversSourceViewport {
                    print("PREVIEW JUMP READY: \(Double(DispatchTime.now().uptimeNanoseconds-started)/1e6) ms, fullCache=\(controller.hasPreparedDocument), \(controller.preview.debugGeometry())")
                    try? TimingDiagnostics.shared.snapshot().json().write(to:URL(fileURLWithPath:"/private/tmp/astra-preview-jump-timings.json"))
                    exit(EXIT_SUCCESS)
                }
                DispatchQueue.main.asyncAfter(deadline:.now()+0.001){wait(remaining-1)}
            }
            wait(3000);return
        }
        verifyUltralightPreview(controller,document:document)
    }
    private static func verifyUltralightPreview(_ controller:EditorWindowController,document:MarkdownDocument) {
        let preview=controller.preview
        func wait(_ remaining:Int,_ ready:@escaping()->Bool,_ failure:String,_ completion:@escaping()->Void) {
            guard remaining>0 else{fail("\(failure): \(preview.debugGeometry())")}
            if ready() {completion()}
            else {DispatchQueue.main.asyncAfter(deadline:.now()+0.01){wait(remaining-1,ready,failure,completion)}}
        }
        wait(500,{controller.hasPreparedViewport && preview.lastRevision==document.revision &&
            preview.webView.debugText.contains("AstraMarkdown")},"Ultralight did not publish the first viewport") {
            check(preview.coversSourceViewport,"The first Ultralight window must cover the source viewport")
            check(preview.preparedFragmentCount<350,"The first Ultralight window must remain bounded")
            check(preview.webView.debugCount("section[data-id]")==preview.preparedFragmentCount,
                "Ultralight DOM and retained presentation must contain the same blocks")
            check(preview.webView.debugRect("h1",containing:"AstraMarkdown") != nil,
                "The first heading must have measured Ultralight geometry")
            check(preview.webView.debugCount(".katex")>0,"Ultralight must retain Comrak's KaTeX output")
            check(preview.webView.debugCount("tbody tr")>0,"Ultralight must render complete table markup")
            check(preview.webView.debugCount("img")>0 && (preview.webView.debugRect("img")?.height ?? 0)>0,
                "Ultralight must resolve and lay out the bundled local image")
            let startupCount=preview.preparedFragmentCount
            verifyTopResizeAnchor(controller) {
                continueAfterTopResize(controller,document:document,startupCount:startupCount,wait:wait)
            }
        }
    }
    private static func verifyTopResizeAnchor(_ controller:EditorWindowController,completion:@escaping()->Void) {
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
                DispatchQueue.main.asyncAfter(deadline:.now()+0.05) {
                    window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
                    check(controller.source.debugFirstLineViewportY==sourceTop,
                        "Source top moved when the resized presentation committed")
                    check(controller.preview.debugFirstHeadingViewportY==previewTop,
                        "Preview top moved when the resized presentation committed")
                    completion()
                }
                return
            }
            window.setContentSize(sizes[index])
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            check(controller.preview.webView.debugPaintedBitmapTop==0,
                "Cached preview bitmap moved away from the viewport top during resize")
            // Width changes schedule TextKit layout and an Ultralight frame.
            // Inspect after both have had an opportunity to adjust their clips.
            DispatchQueue.main.asyncAfter(deadline:.now()+0.03) {
                window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
                check(controller.preview.webView.debugPaintedBitmapTop==0,
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
            wait(800,{preview.coversSourceViewport && !preview.isShowingLoadingState &&
                preview.displayedSourceRange.map{NSMaxRange($0)>=document.source.count-1}==true},
                "A cached deep jump did not publish") {
                check(preview.preparedFragmentCount<350,"A deep jump must keep the mounted DOM bounded")
                check(controller.hasPreparedDocument,"The deep jump should use the fully prepared retained tree")
                let editRevision=document.revision+1
                document.replace(NSRange(location:document.source.count,length:0),with:"\n\n## ULTRALIGHT_EDIT\n\nVisible edit.\n")
                source.reveal(document.source.count,alignTop:false)
                wait(800,{document.revision==editRevision && preview.lastRevision==editRevision &&
                    preview.webView.debugText.contains("ULTRALIGHT_EDIT")},"Visible edit did not update Ultralight") {
                    check(preview.preparedFragmentCount<350,"A visible edit must not expand the mounted DOM")
                    let oldWidth=preview.bounds.width
                    preview.beginLiveResize()
                    preview.frame.size.width=max(320,oldWidth-73)
                    preview.layoutSubtreeIfNeeded()
                    preview.endLiveResize()
                    wait(300,{abs((preview.webView.geometry()?.width ?? 0)-preview.bounds.width)<=1},
                        "Ultralight did not settle after resize") {
                        source.reveal(0,alignTop:true)
                        wait(800,{preview.coversSourceViewport && preview.webView.debugText.contains("AstraMarkdown")},
                            "Return to the cached first viewport failed") {
                            check(preview.preparedFragmentCount<350,"Returning to the top must remain bounded")
                            check(startupCount>0,"Startup must mount semantic entries")
                            print("INTEGRATION PASSED: Ultralight bounded first view, cached deep jump, retained-tree edit, resize, and return-to-top scrolling")
                            if CommandLine.arguments.contains("--diagnostics") {
                                try? TimingDiagnostics.shared.snapshot().json().write(to:URL(fileURLWithPath:"/private/tmp/astra-ultralight-integration-timings.json"),options:.atomic)
                            }
                            exit(EXIT_SUCCESS)
                        }
                    }
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
            check(model.sourceLayout.length==doc.source.count,"Measured index must cover the current source after edit \(stage)")
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
                    try? TimingDiagnostics.shared.snapshot().json().write(to:URL(fileURLWithPath:"/private/tmp/astra-layout-index-timings.json"))
                }
                exit(EXIT_SUCCESS)
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.05){step(stage+1)}
        }
        step(0)
    }
}

#endif
