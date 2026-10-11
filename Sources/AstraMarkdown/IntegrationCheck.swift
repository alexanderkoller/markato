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
            preview.previewView.debugText.contains("AstraMarkdown")},"Ultralight did not publish the first viewport") {
            check(preview.coversSourceViewport,"The first Ultralight window must cover the source viewport")
            check(preview.preparedFragmentCount<350,"The first Ultralight window must remain bounded")
            check(preview.previewView.debugCount("section[data-id]")==preview.preparedFragmentCount,
                "Ultralight DOM and retained presentation must contain the same blocks")
            check(preview.previewView.debugRect("h1",containing:"AstraMarkdown") != nil,
                "The first heading must have measured Ultralight geometry")
            check(preview.previewView.debugCount(".katex")>0,"Ultralight must retain Comrak's KaTeX output")
            check(preview.previewView.debugCount("tbody tr")>0,"Ultralight must render complete table markup")
            check(preview.previewView.debugCount("img")>0 && (preview.previewView.debugRect("img")?.height ?? 0)>0,
                "Ultralight must resolve and lay out the bundled local image")
            let startupCount=preview.preparedFragmentCount
            verifyPresentationFailureRecovery(controller,wait:wait) {
                verifyTopResizeAnchor(controller) {
                    verifyMiddleResizeAnchor(controller,document:document,wait:wait) {
                        continueAfterTopResize(controller,document:document,startupCount:startupCount,wait:wait)
                    }
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
            check(preview.previewView.debugText.contains("AstraMarkdown"),
                "Recovery must publish the requested document through the normal presentation path")
            completion()
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
            check(controller.preview.previewView.debugPaintedBitmapTop==0,
                "Cached preview bitmap moved away from the viewport top during resize")
            // Width changes schedule TextKit layout and an Ultralight frame.
            // Inspect after both have had an opportunity to adjust their clips.
            DispatchQueue.main.asyncAfter(deadline:.now()+0.03) {
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
            wait(800,{preview.coversSourceViewport && !preview.isShowingLoadingState &&
                preview.displayedSourceRange.map{NSMaxRange($0)>=document.source.count-1}==true},
                "A cached deep jump did not publish") {
                check(preview.preparedFragmentCount<350,"A deep jump must keep the mounted DOM bounded")
                check(controller.hasPreparedDocument,"The deep jump should use the fully prepared retained tree")
                let retainedSurface=preview.debugCommittedSurfaceIndex
                let crossRevisionCommits=preview.crossRevisionCommitCount
                let inPlaceCrossRevisionCommits=preview.inPlaceCrossRevisionCommitCount
                let transientRevision=document.revision+1
                document.parser.debugFailNextRequests()
                document.replace(NSRange(location:document.source.count,length:0),with:"\n\n## TRANSIENT_PARSE_EDIT\n\nRecovered automatically.\n")
                check(!preview.isShowingLoadingState,
                    "An edit must retain the committed preview without flashing the loading layer")
                check(preview.debugCommittedSurfaceIndex==retainedSurface,
                    "An edit must leave the committed surface visible while its replacement prepares")
                source.reveal(document.source.count,alignTop:false)
                wait(800,{document.revision==transientRevision && preview.lastRevision==transientRevision &&
                    preview.previewView.debugText.contains("TRANSIENT_PARSE_EDIT")},"Transient parser failure did not recover") {
                    check(preview.crossRevisionCommitCount>crossRevisionCommits,
                        "The edit did not commit a cross-revision preview replacement")
                    check(preview.inPlaceCrossRevisionCommitCount==inPlaceCrossRevisionCommits,
                        "A cross-revision edit mutated the displayed preview surface")
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
        source.debugAlignViewport(at:document.source.count/2,viewportY:source.bounds.height/2)
        wait(800,{preview.coversSourceViewport &&
            abs((preview.previewView.geometry()?.width ?? 0)-preview.bounds.width)<1 &&
            preview.debugScrollMapError.map{abs($0)<0.01}==true},
            "The middle viewport did not align before resize") {
            let original=window.contentLayoutRect.size
            let initialRendererWidth=preview.previewView.geometry()?.width
            let topAnchor=source.debugRenderedViewportAnchor
            guard let sourceTopY=source.debugRenderedViewportY(for:topAnchor) else {
                fail("Missing middle source resize anchor")
            }
            let sizes=[NSSize(width:original.width-190,height:original.height-100)]
            let finalSize=NSSize(width:original.width+170,height:original.height+80)
            controller.windowWillStartLiveResize(Notification(name:NSWindow.willStartLiveResizeNotification,object:window))
            guard let previewAnchorY=preview.debugResizeAnchorViewportY else {
                fail("Missing middle preview resize anchor")
            }
            let previewAnchorState=preview.debugResizeAnchorState
            @MainActor func step(_ index:Int) {
                guard index<sizes.count else {
                    // Deliberately do not force layout for the final, different
                    // size. The end-resize path itself must materialize the
                    // final split/source geometry before in-place finalization.
                    window.setContentSize(finalSize)
                    controller.windowDidEndLiveResize(Notification(name:NSWindow.didEndLiveResizeNotification,object:window))
                    check(preview.debugResizeAnchorViewportY.map{abs($0-previewAnchorY)<0.01}==true,
                        "Mouse-up repositioned the preview (\(previewAnchorY) -> \(String(describing:preview.debugResizeAnchorViewportY)))")
                    // Queued source work after mouse-up must preserve the same
                    // rendered source top and must not reposition the preview.
                    source.debugRelayoutVisibleViewport()
                    check(preview.debugResizeAnchorViewportY.map{abs($0-previewAnchorY)<0.01}==true,
                        "Post-resize source layout repositioned the preview (\(previewAnchorY) -> \(String(describing:preview.debugResizeAnchorViewportY)), sourcePinned \(source.isResizePositionPinned), previewPin \(String(describing:preview.debugResizePinnedOrigin)), clip \(preview.clipOrigin), start {\(previewAnchorState)}, end {\(preview.debugResizeAnchorState)})")
                    preview.sourceLayoutChanged()
                    wait(800,{abs((preview.previewView.geometry()?.width ?? 0)-preview.bounds.width)<1 &&
                        preview.lastRevision==document.revision},
                        "The resized middle viewport did not commit against current geometry") {
                        let finalSourceY=source.debugRenderedViewportY(for:topAnchor)
                        check(finalSourceY.map{abs($0-sourceTopY)<1}==true,
                            "The source top position moved during resize completion")
                        check(preview.debugResizeAnchorViewportY.map{abs($0-previewAnchorY)<0.01}==true,
                            "The preview semantic top moved after resize finalization (\(previewAnchorY) -> \(String(describing:preview.debugResizeAnchorViewportY)), origin \(preview.clipOrigin))")
                        let beforeScroll=preview.clipOrigin
                        source.debugScrollViewport(by:90)
                        wait(800,{abs(preview.clipOrigin-beforeScroll)>1 &&
                            preview.debugScrollMapError.map{abs($0)<0.01}==true},
                            "The first post-resize scroll did not restore center alignment",completion)
                    }
                    return
                }
                window.setContentSize(sizes[index])
                window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
                DispatchQueue.main.asyncAfter(deadline:.now()+0.03) {
                    window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
                    check(preview.debugResizeAnchorViewportY.map{abs($0-previewAnchorY)<0.01}==true,
                        "The preview semantic top moved during live resize")
                    let sourceY=source.debugRenderedViewportY(for:topAnchor)
                    check(sourceY.map{abs($0-sourceTopY)<1}==true,
                        "The source top position moved during live resize (\(sourceTopY) -> \(String(describing:sourceY)), anchor \(topAnchor), origin \(source.viewportOrigin))")
                    if let initialRendererWidth {
                        let currentWidth=preview.previewView.geometry()?.width ?? 0
                        check(abs(currentWidth-preview.bounds.width)<1 && abs(currentWidth-initialRendererWidth)>1,
                            "The displayed preview did not reflow during live resize (\(initialRendererWidth) -> \(currentWidth), pane \(preview.bounds.width))")
                    }
                    step(index+1)
                }
            }
            step(0)
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
    private static func verifyParagraphInsertionStability(_ controller:EditorWindowController,document:MarkdownDocument,
        wait:@escaping(Int,@escaping()->Bool,String,@escaping()->Void)->Void,completion:@escaping()->Void) {
        let preview=controller.preview,source=controller.source,following="Recovered manually."
        let location=(document.source.string as NSString).range(of:following).location
        guard location != NSNotFound else{fail("Missing paragraph insertion fixture")}
        source.reveal(location,alignTop:true)
        wait(800,{preview.coversSourceViewport && preview.debugParagraphViewportY(containing:following) != nil},
            "The following paragraph was not visible before insertion") {
            let retainedSurface=preview.debugCommittedSurfaceIndex
            var committedPositions=[CGFloat]()
            preview.debugPresentationCommitted = {
                if preview.displayedDocumentRevision==document.revision,
                   let y=preview.debugParagraphViewportY(containing:following) {committedPositions.append(y)}
            }
            source.textView.setSelectedRange(NSRange(location:location,length:0))
            source.textView.insertText("Inserted paragraph.\n\n",replacementRange:source.textView.selectedRange())
            check(!preview.isShowingLoadingState,
                "A paragraph insertion must retain the committed preview without a loading flash")
            check(preview.debugCommittedSurfaceIndex==retainedSurface,
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
                        check(high-low<0.01,
                            "The following paragraph oscillated across committed insertion frames")
                    }
                    check(abs(after-settled)<0.01,
                        "The following paragraph moved after the insertion frame committed")
                    // The paragraph now exists. A second Enter only adds one
                    // more separator line, so the rendered IDs and HTML are
                    // unchanged and the existing bitmap must be reusable.
                    let paragraph="Inserted paragraph."
                    let paragraphEnd=location+(paragraph as NSString).length
                    let reused=preview.pixelReuseCommitCount
                    let beforeEnter=after
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
                        check(preview.pixelReuseCommitCount==reused+1,
                            "An extra paragraph separator must reuse the unchanged preview pixels")
                        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
                            preview.debugPresentationCommitted=nil
                            guard let afterEnter=preview.debugParagraphViewportY(containing:following) else {
                                fail("The following paragraph disappeared after the extra Enter")
                            }
                            for y in enterPositions {
                                check(abs(y-beforeEnter)<0.01,
                                    "The following paragraph moved during the extra Enter")
                            }
                            check(abs(afterEnter-beforeEnter)<0.01,
                                "The following paragraph moved after the extra Enter settled")
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
            let retainedSurface=preview.debugCommittedSurfaceIndex
            let crossRevisionCommits=preview.crossRevisionCommitCount
            let inPlaceCrossRevisionCommits=preview.inPlaceCrossRevisionCommitCount
            expected.append(characters[index])
            source.textView.insertText(String(characters[index]),replacementRange:source.textView.selectedRange())
            check(document.revision==previousRevision+1,"A simulated keystroke must create one document revision")
            check(!preview.isShowingLoadingState,
                "A keystroke must retain the committed preview without flashing the loading layer")
            check(preview.debugCommittedSurfaceIndex==retainedSurface,
                "A keystroke must not replace the visible surface before rendering finishes")
            wait(800,{preview.lastRevision==document.revision && preview.previewView.debugText.contains(expected)},
                "A simulated keystroke did not reach the preview") {
                check(preview.crossRevisionCommitCount>crossRevisionCommits,
                    "A simulated keystroke did not commit a preview replacement")
                check(preview.inPlaceCrossRevisionCommitCount==inPlaceCrossRevisionCommits,
                    "A simulated keystroke mutated the displayed preview surface")
                step(index+1)
            }
        }
        step(0)
    }
    private static func continueAfterTyping(_ controller:EditorWindowController,document:MarkdownDocument,
        startupCount:Int,wait:@escaping(Int,@escaping()->Bool,String,@escaping()->Void)->Void) {
        let preview=controller.preview,source=controller.source
        check(preview.preparedFragmentCount<350,"A visible edit must not expand the mounted DOM")
        let oldWidth=preview.bounds.width
        preview.beginLiveResize()
        preview.frame.size.width=max(320,oldWidth-73)
        preview.layoutSubtreeIfNeeded()
        preview.endLiveResize()
        wait(300,{abs((preview.previewView.geometry()?.width ?? 0)-preview.bounds.width)<=1},
            "Ultralight did not settle after resize") {
            source.reveal(0,alignTop:true)
            wait(800,{preview.coversSourceViewport && preview.previewView.debugText.contains("AstraMarkdown")},
                "Return to the cached first viewport failed") {
                check(preview.preparedFragmentCount<350,"Returning to the top must remain bounded")
                check(startupCount>0,"Startup must mount semantic entries")
                print("INTEGRATION PASSED: bounded first view, presentation recovery, automatic and manual parse recovery, retained stale preview, cached navigation, stable paragraph insertion, rapid typing, edit, resize, and return-to-top scrolling")
                if CommandLine.arguments.contains("--diagnostics") {
                    try? TimingDiagnostics.shared.snapshot().json().write(to:URL(fileURLWithPath:"/private/tmp/astra-ultralight-integration-timings.json"),options:.atomic)
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
