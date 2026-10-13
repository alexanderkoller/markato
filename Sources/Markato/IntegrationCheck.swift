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
    private static func writeVisualCapture(_ capture:PixelCapture,suffix:String) {
        guard let base=visualResizeOutput else{return}
        try? capture.png.write(to:URL(fileURLWithPath:"\(base)-\(suffix).png"))
    }
    static func run(_ document:MarkdownDocument) {
        guard let controller=document.windowControllers.first as? EditorWindowController else {fail("Missing editor window")}
        check(!MarkdownDocument.autosavesInPlace,"Markdown documents must require an explicit save")
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
        if CommandLine.arguments.contains("--integration-preview-jump") {
            controller.source.reveal(0,alignTop:true)
            controller.source.reveal(document.source.count)
            let started=DispatchTime.now().uptimeNanoseconds
            print("PREVIEW JUMP: fullCache=\(controller.hasPreparedDocument), \(controller.preview.debugGeometry())")
            func wait(_ remaining:Int) {
                guard remaining>0 else{fail("Jump preview did not become ready: \(controller.preview.debugGeometry())")}
                if !controller.preview.isShowingLoadingState,controller.preview.coversSourceViewport {
                    print("PREVIEW JUMP READY: \(Double(DispatchTime.now().uptimeNanoseconds-started)/1e6) ms, fullCache=\(controller.hasPreparedDocument), \(controller.preview.debugGeometry())")
                    try? TimingDiagnostics.shared.snapshot().json().write(to:URL(fileURLWithPath:"/private/tmp/markato-preview-jump-timings.json"))
                    exit(EXIT_SUCCESS)
                }
                DispatchQueue.main.asyncAfter(deadline:.now()+0.001){wait(remaining-1)}
            }
            wait(3000);return
        }
        verifyUltralightPreview(controller,document:document)
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
                                let text=preview.previewView.debugText
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
            check(controller.window?.toolbar?.items.contains(where:{
                $0.action == #selector(EditorWindowController.toggleSidebar(_:)) && $0.isEnabled
            })==true,"The window must keep an enabled sidebar toggle in its toolbar")
            controller.toggleSidebar(nil)
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
                    check(controller.preview.preparedFragmentCount<350,"Outline jump must keep the preview DOM bounded")
                    controller.toggleSidebar(nil)
                    check(!controller.isSidebarVisible,"Sidebar toggle must collapse the outline")
                    controller.toggleSidebar(nil)
                    check(controller.isSidebarVisible,"Sidebar toggle must restore the outline")
                    print("OUTLINE INTEGRATION PASSED: semantic headings, deep jump, bounded preview, collapse and restore")
                    exit(EXIT_SUCCESS)
                }
                DispatchQueue.main.asyncAfter(deadline:.now()+0.01){waitForJump(remaining-1)}
            }
            waitForJump(500)
        }
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
            guard remaining>0 else{fail("\(failure): \(preview.debugGeometry())")}
            if ready() {completion()}
            else {DispatchQueue.main.asyncAfter(deadline:.now()+0.01){wait(remaining-1,ready,failure,completion)}}
        }
        wait(500,{controller.hasPreparedViewport && preview.lastRevision==document.revision &&
            preview.previewView.debugText.contains("Markato")},"Ultralight did not publish the first viewport") {
            check(abs(controller.source.canvas.frame.width-controller.source.scroll.contentSize.width)<0.1,
                "Initial source width did not follow the clip after its vertical scroller appeared")
            check(preview.coversSourceViewport,"The first Ultralight window must cover the source viewport")
            check(preview.preparedFragmentCount<350,"The first Ultralight window must remain bounded")
            check(preview.previewView.debugCount("section[data-id]")==preview.preparedFragmentCount,
                "Ultralight DOM and retained presentation must contain the same blocks")
            check(preview.previewView.debugRect("h1",containing:"Markato") != nil,
                "The first heading must have measured Ultralight geometry")
            check(preview.previewView.debugCount(".katex")>0,"Ultralight must retain Comrak's KaTeX output")
            check(preview.previewView.debugCount("tbody tr")>0,"Ultralight must render complete table markup")
            check(preview.previewView.debugCount("img")>0 && (preview.previewView.debugRect("img")?.height ?? 0)>0,
                "Ultralight must resolve and lay out the bundled local image")
            let startupCount=preview.preparedFragmentCount
            verifyPresentationFailureRecovery(controller,wait:wait) {
                verifyTopResizeAnchor(controller) {
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
                let revision=document.revision+1
                document.replace(NSRange(location:document.source.count,length:0),with:"\n")
                wait(800,{document.revision==revision && preview.lastRevision==revision &&
                    !preview.debugIsIndependentlyScrolled &&
                    preview.debugScrollMapError.map{abs($0)<0.01}==true},
                    "A source edit did not restore source/preview alignment") {
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
                    check(controller.source.isResizePositionPinned,
                        "Source top lock was dropped after resize completion")
                    check(controller.preview.debugFirstHeadingViewportY==previewTop,
                        "Preview top moved when the resized presentation committed")
                    check(controller.preview.debugResizePinnedOrigin != nil,
                        "Preview top lock was dropped after resize completion")
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
            wait(800,{controller.hasPreparedDocument && preview.coversSourceViewport && !preview.isShowingLoadingState &&
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
            "The middle viewport did not settle before resize") {
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
                    let previewSurface=preview.debugCommittedSurfaceIndex
                    writeVisualCapture(before,suffix:"before-release")
                    writeVisualCapture(previewBefore,suffix:"preview-before-release")
                    controller.windowDidEndLiveResize(Notification(name:NSWindow.didEndLiveResizeNotification,object:window))
                    check(preview.debugCommittedSurfaceIndex==previewSurface && !preview.isShowingLoadingState,
                        "Resize release replaced or masked the already reflowed preview")
                    assertAnchors("at mouse-up")
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.12) {
                        window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
                        let after=capture(source.scroll.contentView)
                        let previewAfter=capture(preview)
                        check(preview.debugCommittedSurfaceIndex==previewSurface && !preview.isShowingLoadingState,
                            "Deferred resize release replaced or masked the preview")
                        writeVisualCapture(after,suffix:"after-release")
                        writeVisualCapture(previewAfter,suffix:"preview-after-release")
                        check(visualVerticalShift(before,after)==0,
                            "Visible source pixels shifted after mouse-up")
                        // The HTML engine can repaint and slightly alter
                        // within-element spacing after release. Its captured
                        // top element, not every downstream pixel, is pinned.
                        assertAnchors("after deferred layout")
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
                            if let low=enterPositions.min(),let high=enterPositions.max() {
                                check(high-low<0.01,
                                    "The following paragraph oscillated across extra-Enter frames")
                            }
                            check(enterPositions.last.map{abs(afterEnter-$0)<0.01}==true,
                                "The following paragraph moved after the extra Enter settled")
                            check(preview.debugScrollMapError.map{abs($0)<0.01}==true,
                                "The extra Enter did not publish the center-aligned scroll map")
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
                check(preview.preparedFragmentCount<350,"Returning to the top must remain bounded")
                check(startupCount>0,"Startup must mount semantic entries")
                print("INTEGRATION PASSED: bounded first view, presentation recovery, automatic and manual parse recovery, retained stale preview, cached navigation, stable paragraph insertion, rapid typing, edit, resize, and return-to-top scrolling")
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
