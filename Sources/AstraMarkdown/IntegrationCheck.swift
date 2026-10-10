#if DEBUG
import AppKit
import WebKit
import MarkdownCore

/// Runs against an actual window and TextKit network, without modifying user documents.
@MainActor enum IntegrationCheck {
    // Document windows and their queued AppKit callbacks may outlive a check.
    // Keep isolated fixtures alive until the native test process exits.
    private static var fixtureDocuments=[MarkdownDocument]()
    @MainActor private final class FixtureScrollSource:ScrollSource {
        var contentRevision=1,geometryRevision=0,sourceLength=100,wheelEvents=0
        var hasMeasuredLayout=true
        private(set) var measurementAttempts=0
        var viewportOrigin:CGFloat=0,contentHeight:CGFloat=200
        var visibleSourceRange=NSRange(location:0,length:100)
        var alignmentAnchor:Int {visibleSourceRange.location}
        var position:(Int)->CGFloat?={CGFloat($0)}
        func verticalPosition(for offset:Int)->CGFloat? {measurementAttempts += 1;return position(offset)}
        func scrollWheel(with event:NSEvent) {wheelEvents += 1}
        func setLayout(height:CGFloat,scale:CGFloat,origin:CGFloat) {
            contentHeight=height;viewportOrigin=origin;position={CGFloat($0)*scale};geometryRevision += 1
        }
    }
    private static func fixtureSource(_ pane:PreviewPane)->FixtureScrollSource {
        guard case .synchronized(let source)=pane.scrolling,let fixture=source as? FixtureScrollSource else{fail("Missing measured fixture source")}
        return fixture
    }
    private static func presentFixture(_ pane:PreviewPane,_ result:ParseResult) {
        let source=fixtureSource(pane)
        source.contentRevision=result.revision;source.sourceLength=result.fragments.last!.to
        source.visibleSourceRange=NSRange(location:0,length:min(100,source.sourceLength))
        pane.show(result)
    }
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
        if !CommandLine.arguments.contains("--integration-source-paint") {verifyNativeComposition()}
        waitForDemoTop(controller,document:document,remaining:100)
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
    private static func waitForDemoTop(_ controller:EditorWindowController,document:MarkdownDocument,remaining:Int) {
        guard remaining>0 else {fail("Startup preview did not reach the demo title: preparedViewport=\(controller.hasPreparedViewport), preparedDocument=\(controller.hasPreparedDocument), pending=\(controller.preview.hasPendingContent), \(controller.preview.debugGeometry())")}
        controller.preview.webView.evaluateJavaScript("JSON.stringify({title:document.querySelector('h1')?.textContent,top:document.querySelector('h1')?.getBoundingClientRect().top})") {value,error in
            if error==nil,controller.hasPreparedViewport,controller.preview.lastRevision==document.revision,
               let string=value as? String,let data=string.data(using:.utf8),
               let result=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
               (result["title"] as? String)?.contains("AstraMarkdown")==true,let titleTop=result["top"] as? Double {
                let source=controller.source,preview=controller.preview
                check(source.scroll.contentView.bounds.minY<0.001,"Opening the demo must leave the source at zero")
                check(abs(preview.visibleWebRange.lowerBound)<0.001,"Opening the demo must leave the preview at zero")
                check(titleTop>=8,"The demo title must be visible at startup")
                if CommandLine.arguments.contains("--integration-source-paint") {
                    verifySourcePaint(controller,document:document) {exit(EXIT_SUCCESS)}
                    return
                }
                let heading=source.textView.textStorage?.attribute(.font,at:2,effectiveRange:nil) as? NSFont
                let headingColor=source.textView.layoutManager?.temporaryAttribute(.foregroundColor,atCharacterIndex:2,effectiveRange:nil) as? NSColor
                check(heading?.pointSize==source.fontSize && headingColor != NSColor.textColor,"Startup heading must already have fixed-metric syntax color")
                source.applyHighlights([],in:document.source.lines(1,2))
                let retained=source.textView.textStorage?.attribute(.font,at:2,effectiveRange:nil) as? NSFont
                let retainedColor=source.textView.layoutManager?.temporaryAttribute(.foregroundColor,atCharacterIndex:2,effectiveRange:nil) as? NSColor
                check(heading?.pointSize==retained?.pointSize && heading?.fontName==retained?.fontName && retainedColor==headingColor,"Partial highlighting must preserve earlier heading paint")
                let passage=source.viewportAnchor,oldY=source.debugMeasuredPosition(for:passage)
                source.reload(preserving:source.selection)
                let reloaded=source.textView.textStorage?.attribute(.font,at:2,effectiveRange:nil) as? NSFont
                let reloadedColor=source.textView.layoutManager?.temporaryAttribute(.foregroundColor,atCharacterIndex:2,effectiveRange:nil) as? NSColor
                check(reloaded?.pointSize==heading?.pointSize && reloadedColor==headingColor,"Reloading the same document must preserve heading paint")
                check(abs(source.debugMeasuredPosition(for:passage)-oldY)<0.001,"Reloading the same document must preserve its measured coordinates")
                source.beginScrollGesture()
                var previous=preview.clipOrigin,maximum:CGFloat=0
                for step in 1...640 {
                    source.scroll.contentView.scroll(to:NSPoint(x:0,y:CGFloat(step)*0.5))
                    source.scroll.reflectScrolledClipView(source.scroll.contentView)
                    let delta=preview.clipOrigin-previous
                    check(delta>0 && delta<3,"Near-top forward scrolling must move continuously forward across source gaps")
                    maximum=max(maximum,delta);previous=preview.clipOrigin
                }
                for step in stride(from:639,through:0,by:-1) {
                    source.scroll.contentView.scroll(to:NSPoint(x:0,y:CGFloat(step)*0.5))
                    source.scroll.reflectScrolledClipView(source.scroll.contentView)
                    let delta=preview.clipOrigin-previous
                    check(delta<=0 && delta>(-3),"Near-top reverse scrolling must not reverse direction or snap at zero")
                    previous=preview.clipOrigin
                }
                source.endScrollGesture();preview.moveViewport()
                check(abs(preview.visibleWebRange.lowerBound)<0.001,"Returning to source zero must also return preview zero")
                print("STARTUP/TOP: full title visible, 1280 half-pixel steps without direction reversals, maximum forward step=\(maximum), exact return to zero")
                verifySourcePaint(controller,document:document) {waitForIdlePreparation(controller) {verifyReadOnlyScrolling(controller,document:document) {verifyHeadingAlignment(controller,document:document) {verifySectionFourTable(controller,document:document) {verifyTableMomentum(controller,document:document) {verifyFullPreparation {verifyReplacementPresentation {verifyMeasurementValidity {verifyIndependentTable(document:document) {performDocumentChecks(document)}}}}}}}}}}
            } else {DispatchQueue.main.asyncAfter(deadline:.now()+0.05) {waitForDemoTop(controller,document:document,remaining:remaining-1)}}
        }
    }

    private static func waitForIdlePreparation(_ controller:EditorWindowController,remaining:Int=300,completion:@escaping()->Void) {
        guard remaining>0 else{fail("Idle document preparation did not settle before scrolling: document=\(controller.hasPreparedDocument), pending=\(controller.preview.hasPendingContent), pages=\(controller.cachedPageCount), bytes=\(controller.cachedByteCost), \(controller.preview.debugGeometry())")}
        if controller.hasPreparedDocument,!controller.hasCompleteSourceLayout {
            _ = controller.source.completePreparedLayout()
        }
        guard controller.hasPreparedDocument,controller.hasCompleteSourceLayout else {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.02){waitForIdlePreparation(controller,remaining:remaining-1,completion:completion)};return
        }
        completion()
    }

    private static func verifyReadOnlyScrolling(_ controller:EditorWindowController,document:MarkdownDocument,completion:@escaping()->Void) {
        let source=controller.source
        check(source.hasAppliedHighlights(in:source.visibleSourceRange),"Visible source syntax must be ready before scrolling")
        let requests=controller.parserRequests,highlights=source.highlightApplications
        let end=max(0,source.contentHeight-source.scroll.contentSize.height)
        let positions=Array(0...160)+Array((0...160).reversed())
        source.beginScrollGesture()
        func step(_ index:Int) {
            if index==positions.count {
                source.endScrollGesture()
                check(controller.parserRequests>=requests && source.highlightApplications>=highlights,
                      "Viewport-driven syntax preparation counters must remain monotonic")
                print("READ-ONLY SCROLL: full forward/reverse traversal; \(controller.parserRequests-requests) prepared-AST viewport queries, \(source.highlightApplications-highlights) visible style applications")
                completion();return
            }
            source.scroll.contentView.scroll(to:NSPoint(x:0,y:end*CGFloat(positions[index])/160))
            source.scroll.reflectScrolledClipView(source.scroll.contentView)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.002){step(index+1)}
        }
        step(0)
    }
    private static func verifySourcePaint(_ controller:EditorWindowController,document:MarkdownDocument,completion:@escaping()->Void) {
        let source=controller.source
        let initialLength=source.preparedLayoutLength
        let manager=source.textView.layoutManager!
        func capture(_ label:String) {
            let view=source.scroll,rect=view.bounds
            guard let bitmap=view.bitmapImageRepForCachingDisplay(in:rect) else{fail("Missing source bitmap")}
            view.cacheDisplay(in:rect,to:bitmap)
            let background=NSColor.textBackgroundColor.usingColorSpace(.deviceRGB)!
            var inkRows=0
            for y in 0..<bitmap.pixelsHigh {
                var ink=0
                for x in stride(from:40,to:bitmap.pixelsWide-40,by:3) {
                    guard let pixel=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else{continue}
                    if abs(pixel.redComponent-background.redComponent)+abs(pixel.greenComponent-background.greenComponent)+abs(pixel.blueComponent-background.blueComponent)>0.6 {ink += 1}
                }
                if ink>5 {inkRows += 1}
            }
            check(inkRows>bitmap.pixelsHigh/5,"Source text must paint immediately after \(label); blank or mostly missing rows are unacceptable")
            check(source.preparedLayoutLength==initialLength && initialLength==document.source.count,"Viewport refinement must retain complete source-layout coverage")
            try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/private/tmp/astra-source-\(label).png"))
            print("SOURCE PAINT \(label): \(inkRows) painted rows of \(bitmap.pixelsHigh); retained coverage complete")
        }
        source.reveal(0,alignTop:true)
        source.textView.displayIfNeeded()
        capture("top")
        source.reveal(document.source.count)
        capture("immediate")
        for step in [1,3,2,0] {
            source.scroll.contentView.scroll(to:NSPoint(x:0,y:source.contentHeight-source.scroll.contentSize.height-CGFloat(step)*source.scroll.contentSize.height/2))
            source.scroll.reflectScrolledClipView(source.scroll.contentView)
            capture("paragraph-\(step)")
        }
        // The index must agree with independently queried native glyph geometry.
        for offset in stride(from:max(0,document.source.count-16000),to:document.source.count,by:97) {
            let glyph=manager.glyphIndexForCharacter(at:offset)
            let rect=manager.lineFragmentUsedRect(forGlyphAt:glyph,effectiveRange:nil)
            check(abs(source.debugMeasuredPosition(for:offset)-rect.minY-source.textView.textContainerInset.height)<0.001,"Indexed source position must match native wrapped-line geometry")
        }
        let start=DispatchTime.now().uptimeNanoseconds
        for _ in 0..<100 {_ = source.visibleSourceRange;_ = source.alignmentAnchor}
        print("SOURCE QUERIES: \(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6/100) ms per viewport query group")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.1) {
            capture("settled");source.reveal(0,alignTop:true);completion()
        }
    }
    private static func verifyMeasurementValidity(completion:@escaping()->Void) {
        let pane=PreviewPane(frame:NSRect(x:0,y:0,width:500,height:380))
        let window=NSWindow(contentRect:pane.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=pane;window.setFrameOrigin(NSPoint(x:-10000,y:0));window.orderBack(nil)
        let source=FixtureScrollSource();source.setLayout(height:2000,scale:10,origin:100)
        source.position={_ in nil};pane.scrolling = .synchronized(source)
        let result=ParseResult(revision:1,spans:[],fragments:[PreviewFragment(kind:"Paragraph",from:0,to:50,markdown:"Body",html:"<p style='height:600px'>Body</p>"),PreviewFragment(kind:"ATXHeading2",from:50,to:100,markdown:"## Landmark",html:"<h2>Landmark</h2><p style='height:1400px'>More</p>")])
        presentFixture(pane,result)
        func waitForRejectedMeasurement(_ remaining:Int) {
            check(remaining>0,"Missing measurement test must reach WebKit geometry")
            guard source.measurementAttempts>0 else {
                DispatchQueue.main.asyncAfter(deadline:.now()+0.03){waitForRejectedMeasurement(remaining-1)};return
            }
            check(pane.lastRevision == -1 && visiblePreviews(pane).isEmpty && pane.isShowingLoadingState,"An unavailable interior measurement must prevent initial publication")
            source.setLayout(height:2000,scale:10,origin:100);pane.sourceLayoutChanged()
            waitForPane(pane,revision:1) {
                let origin=pane.clipOrigin,web=pane.webView
                source.position={_ in nil};source.geometryRevision += 1;source.viewportOrigin=300
                pane.moveViewport()
                check(abs(pane.clipOrigin-origin)<0.001 && pane.isShowingLoadingState && pane.webView === web,"Unavailable changed geometry must not move using an old map or estimate")
                source.setLayout(height:2000,scale:10,origin:300);pane.sourceLayoutChanged()
                check(!pane.isShowingLoadingState && abs(pane.clipOrigin-origin)>1,"Restored measured geometry must resume synchronized movement")
                print("MEASUREMENTS: missing interior geometry rejects publication and movement; valid geometry resumes without estimates")
                window.close();completion()
            }
        }
        waitForRejectedMeasurement(200)
    }
    private static func verifyIndependentTable(document:MarkdownDocument,completion:@escaping()->Void) {
        let text=document.source.string as NSString
        let from=text.range(of:"| Row | Station | Value | Comment |").location
        check(from != NSNotFound,"Demo must contain its long table")
        let end=text.range(of:"\n\n",options:[],range:NSRange(location:from,length:text.length-from)).location
        check(end != NSNotFound,"Long table must have a measured source extent")
        let parser=ComrakWorker()
        parser.request(rope:document.source,revision:document.revision,visible:NSRange(location:from,length:end-from)) {result in
            guard case .success(let parsed)=result,let fragment=parsed.fragments.first(where:{$0.kind=="Table" && $0.from<=from && $0.to>from}),let controller=document.windowControllers.first as? EditorWindowController else{fail("Cannot prepare inspector table")}
            let inspector=controller.preview.showInspector(for:fragment)
            inspector.window?.orderBack(nil)
            guard let pane=inspector.window?.contentView as? PreviewPane else{fail("Inspector must use the retained preview")}
            waitForPane(pane,revision:0,remaining:200) {
                check({if case .independent=pane.scrolling{return true};return false}(),"Inspector must explicitly use independent native scrolling")
                let web=pane.webView,patches=pane.patchCount
                pane.webView.evaluateJavaScript("document.querySelectorAll('tbody tr').length") {value,error in
                    check(error==nil && (value as? Int)==800,"Inspector must retain the entire 800-row table")
                    guard let cg=CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:-60,wheel2:0,wheel3:0),let event=NSEvent(cgEvent:cg) else{fail("Cannot create independent wheel event")}
                    for _ in 0..<100 {pane.webView.scrollWheel(with:event)}
                    check(pane.visibleWebRange.lowerBound>1000 && pane.webView === web && pane.patchCount==patches,"Inspector movement must retain its complete table without patches")
                    pane.navigatePreview(toEnd:true)
                    pane.webView.evaluateJavaScript("document.getElementById('preview').offsetHeight") {value,error in
                        check(error==nil && abs(Double(pane.visibleWebRange.upperBound)-(value as? Double ?? 0))<1,"Independent table must reach its true endpoint")
                        pane.navigatePreview(toEnd:false)
                        check(abs(pane.visibleWebRange.lowerBound)<0.001,"Independent table must return to zero")
                        print("TABLE INSPECTOR: all 800 rows retained, independent native movement without patches, both endpoints reachable")
                        inspector.window?.close();completion()
                    }
                }
            }
        }
    }
    private static func verifyHeadingAlignment(_ controller:EditorWindowController,document:MarkdownDocument,completion:@escaping()->Void) {
        // Derive targets from source text, independently of the preview's map.
        var offset=0,headings=[(String,Int)]()
        for line in document.source.string.components(separatedBy:"\n") {
            if line.hasPrefix("## ") || line.hasPrefix("### ") {headings.append((line,offset))}
            offset += (line as NSString).length+1
        }
        let fixtures=headings+headings.reversed()
        let originalSize=controller.window!.contentView!.bounds.size
        controller.window?.setContentSize(NSSize(width:1760,height:1200))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        func step(_ index:Int) {
            guard index<fixtures.count else {
                controller.source.endScrollGesture()
                controller.window?.setContentSize(originalSize)
                controller.window?.contentView?.layoutSubtreeIfNeeded()
                controller.source.reveal(0,alignTop:true)
                print("HEADING ALIGNMENT: all \(headings.count) demo headings agree at the reading reference in both directions")
                completion();return
            }
            let (label,offset)=fixtures[index]
            let source=controller.source,preview=controller.preview
            var movements=0
            func approach() {
                movements += 1
                check(movements<10000,"Heading traversal must reach its target")
                let destination=CGFloat(ScrollLandmarks.viewportOrigin(for:Double(source.debugMeasuredPosition(for:offset)),
                    sourceHeight:Double(source.canvas.bounds.height),viewportHeight:Double(source.scroll.contentSize.height)))
                let current=source.scroll.contentView.bounds.minY
                if abs(destination-current)>0.001 {
                    let delta=min(80,max(-80,destination-current))
                    source.scroll.contentView.scroll(to:NSPoint(x:0,y:current+delta))
                    source.scroll.reflectScrolledClipView(source.scroll.contentView)
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.001) {approach()};return
                }
                // NSTextInputClient supplies a native screen rectangle independently
                // of SourceEditor.verticalPosition and the preview's mapping code.
                let screenRect=source.textView.firstRect(forCharacterRange:NSRange(location:offset,length:1),actualRange:nil)
                let nativeRect=source.canvas.convert(controller.window!.convertFromScreen(screenRect),from:nil)
                check(screenRect.height>0,"Native heading character must have a measured rectangle")
                let editorY=nativeRect.minY-source.scroll.contentView.bounds.minY
                let script="JSON.stringify([...document.querySelectorAll('#preview section[data-id]')].find(n=>Number(n._from)===\(offset))?.querySelector('h1,h2,h3,h4,h5,h6')?.getBoundingClientRect().top)"
                func checkPreview(_ remaining:Int) {
                    guard remaining>0 else{fail("Preview did not mount heading at the scrolling destination: \(label)")}
                    guard controller.hasPreparedViewport,preview.coversSourceViewport else {
                        DispatchQueue.main.asyncAfter(deadline:.now()+0.01){checkPreview(remaining-1)};return
                    }
                    preview.webView.evaluateJavaScript(script) {value,error in
                        guard error==nil,let string=value as? String,let documentY=Double(string) else {
                            DispatchQueue.main.asyncAfter(deadline:.now()+0.01){checkPreview(remaining-1)};return
                        }
                        let renderedY=documentY-Double(preview.visibleWebRange.lowerBound)
                        print("HEADING CHECK: \(label), editor=\(editorY), preview=\(renderedY)");fflush(stdout)
                        check(abs(renderedY-Double(editorY))<2,"Measured editor and preview heading positions must agree at the reading reference: \(label)")
                        step(index+1)
                    }
                }
                checkPreview(200)
            }
            if index==0 {
                source.reveal(0,alignTop:true)
                func begin(_ remaining:Int) {
                    guard remaining>0 else{fail("Top preview did not settle before heading traversal")}
                    guard controller.hasPreparedViewport,preview.coversSourceViewport else {
                        DispatchQueue.main.asyncAfter(deadline:.now()+0.01){begin(remaining-1)};return
                    }
                    source.beginScrollGesture();approach()
                }
                begin(200);return
            }
            approach()
        }
        step(0)
    }
    private static func verifySectionFourTable(_ controller:EditorWindowController,document:MarkdownDocument,completion:@escaping()->Void) {
        func ready(_ remaining:Int) {
            guard remaining>0 else {fail("Section 4 preview did not prepare: ready=\(controller.preview.lastRevision), prepared=\(controller.hasPreparedViewport), revision=\(document.revision), \(controller.preview.debugGeometry())")}
            if !controller.hasPreparedViewport || controller.preview.lastRevision != document.revision {
                DispatchQueue.main.asyncAfter(deadline:.now()+0.05) {ready(remaining-1)};return
            }
            let source=controller.source,preview=controller.preview
            source.scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,0)))
            source.scroll.reflectScrolledClipView(source.scroll.contentView)
            source.beginScrollGesture()
            var previousDocumentY:Double?,maximum=0.0,swaps=0,lastPatches=preview.patchCount
            func step(_ index:Int) {
                if index==400 {
                    source.endScrollGesture()
                    print("SECTION 4 TABLE: 400 paced forward/reverse steps, peak asynchronous displacement=\(maximum), replacements=\(swaps)")
                    completion();return
                }
                let direction:CGFloat=index<200 ? 1:-1
                source.scroll.contentView.scroll(to:NSPoint(x:0,y:source.scroll.contentView.bounds.minY+direction*8))
                source.scroll.reflectScrolledClipView(source.scroll.contentView)
                let expectedScreenY=previousDocumentY.map{$0-Double(preview.visibleWebRange.lowerBound)}
                DispatchQueue.main.asyncAfter(deadline:.now()+0.025) {
                    preview.webView.evaluateJavaScript("[...document.querySelectorAll('h3')].find(n=>n.textContent==='Measurements at station 4')?.getBoundingClientRect().top") {value,error in
                        if let y=value as? Double,error==nil {
                            let screenY=y-Double(preview.visibleWebRange.lowerBound)
                            if let expectedScreenY {
                                let delta=screenY-expectedScreenY
                                maximum=max(maximum,abs(delta))
                                if abs(delta)>2 {print("SECTION 4 DISCONTINUITY: step=\(index), asyncDelta=\(delta), patches=\(preview.patchCount), frozen=\(preview.isScrollMappingFrozen), sourceY=\(source.scroll.contentView.bounds.minY), \(preview.debugGeometry())");fflush(stdout)}
                                check(abs(delta)<2,"Section 4 table must not reposition asynchronously during a window replacement")
                            }
                            previousDocumentY=y
                        }
                        if preview.patchCount != lastPatches {swaps += 1;lastPatches=preview.patchCount}
                        step(index+1)
                    }
                }
            }
            step(0)
        }
        ready(100)
    }
    private static func verifyTableMomentum(_ controller:EditorWindowController,document:MarkdownDocument,completion:@escaping()->Void) {
        let target=(document.source.string as NSString).range(of:"| 400 | Station").location
        check(target != NSNotFound,"Missing momentum table fixture")
        controller.source.reveal(target,alignTop:true)
        @MainActor func ready(_ remaining:Int) {
            guard remaining>0 else{fail("Momentum table destination did not prepare")}
            guard controller.hasPreparedViewport else {
                DispatchQueue.main.asyncAfter(deadline:.now()+0.03){ready(remaining-1)};return
            }
            let source=controller.source,preview=controller.preview,web=preview.webView,patches=preview.patchCount
            let deltas:[CGFloat]=[80,64,48,32,20,12,6,3,1]+Array(repeating:0,count:25)
            var gains=[CGFloat](),rest:CGFloat?,previousDocumentTop:Double?
            source.beginScrollGesture()
            @MainActor func step(_ index:Int) {
                if index==deltas.count {
                    check((gains.max() ?? 0)-(gains.min() ?? 0)<0.00001,"Linear interpolation must keep table travel speed constant between its surrounding references")
                    check(preview.patchCount==patches && preview.webView === web,"Table momentum and its ending must preserve the same presentation")
                    print("TABLE MOMENTUM: nine decelerating inputs, 25 resting observations, constant interval gain and no presentation replacement")
                    source.reveal(0,alignTop:true);completion();return
                }
                let beforeSource=source.scroll.contentView.bounds.minY,beforePreview=preview.clipOrigin
                source.scroll.contentView.scroll(to:NSPoint(x:0,y:beforeSource+deltas[index]))
                source.scroll.reflectScrolledClipView(source.scroll.contentView)
                let travel=source.scroll.contentView.bounds.minY-beforeSource
                if travel>0 {gains.append((preview.clipOrigin-beforePreview)/travel)}
                if index==9 {source.endScrollGesture();rest=preview.clipOrigin}
                DispatchQueue.main.asyncAfter(deadline:.now()+0.02) {
                    web.evaluateJavaScript("[...document.querySelectorAll('table')].find(n=>n.tBodies[0]?.rows.length===800)?.getBoundingClientRect().top") {value,error in
                        check(error==nil && value is Double,"Whole table must remain present through momentum")
                        if let y=value as? Double,let previousDocumentTop {check(abs(y-previousDocumentTop)<0.001,"Table geometry must not change while scrolling")}
                        previousDocumentTop=value as? Double
                        if let rest {check(abs(preview.clipOrigin-rest)<0.001,"Ending momentum on a table must not cause settling or drift")}
                        step(index+1)
                    }
                }
            }
            step(0)
        }
        ready(300)
    }
    /// Comrak's first publication fills the existing retained document trees;
    /// navigation then uses the calibrated read-only scrolling path.
    private static func verifyFullPreparation(completion:@escaping()->Void) {
        let document=MarkdownDocument();fixtureDocuments.append(document)
        document.setInitialText(String(repeating:"\n",count:100)+(0..<240).map{"## Prepared passage \($0)\n\nText for passage \($0).\n\n"}.joined()+String(repeating:"\n",count:100))
        let controller=EditorWindowController(document:document)
        document.addWindowController(controller)
        controller.window?.setFrameOrigin(NSPoint(x:-10000,y:0));controller.showWindow(nil)
        check(controller.window?.isVisible==false,"Opening must wait for complete parsing and a ready preview")
        @MainActor func wait(_ remaining:Int) {
            guard remaining>0 else{fail("Complete first presentation did not prepare: viewport=\(controller.hasPreparedViewport), document=\(controller.hasPreparedDocument), \(controller.preview.debugGeometry())")}
            guard controller.hasPreparedViewport,controller.hasPreparedDocument else {
                DispatchQueue.main.asyncAfter(deadline:.now()+0.02){wait(remaining-1)};return
            }
            let preview=controller.preview,source=controller.source
            check(source.hasAppliedHighlights(in:source.visibleSourceRange),"Visible syntax must be ready with the retained document")
            check(controller.window?.isVisible==true,"A complete ready revision must show its window")
            let requests=controller.parserRequests,patches=preview.patchCount
            preview.webView.evaluateJavaScript("({headings:[...document.querySelectorAll('h2')].map(n=>n.textContent).join('|'),maximumFanout:Math.max(...[document.getElementById('preview'),...document.querySelectorAll('.paint-group')].map(n=>n.children.length)),blocks:document.querySelectorAll('section[data-id]').length})") {value,error in
                let result=value as? [String:Any]
                check((result?["maximumFanout"] as? Int ?? 100)>0 && (result?["maximumFanout"] as? Int ?? 100)<=32,"Paint hierarchy must have bounded fanout")
                check((result?["blocks"] as? Int ?? 0)>0 && (result?["blocks"] as? Int ?? 0)<480,"First presentation must keep WebKit bounded to the viewport")
                check(error==nil && (result?["headings"] as? String)?.contains("Prepared passage 0")==true,"First view must contain its prepared destination")
                source.reveal(document.source.count)
                DispatchQueue.main.asyncAfter(deadline:.now()+0.1) {
                    check(controller.hasPreparedViewport && controller.parserRequests==requests,"Deep cached navigation must not request another parse")
                    check(preview.patchCount>patches,"Deep cached navigation must publish its retained destination")
                    print("COMPLETE PREPARATION: one retained native revision, cached deep jump, viewport-bounded WebKit presentation")
                    controller.window?.close();completion()
                }
            }
        }
        wait(300)
    }
    private static func waitForPane(_ pane:PreviewPane,revision:Int,remaining:Int=100,completion:@escaping()->Void) {
        guard remaining>0 else {fail("Replacement preview did not finish")}
        if pane.lastRevision==revision {completion()}
        else {DispatchQueue.main.asyncAfter(deadline:.now()+0.05) {waitForPane(pane,revision:revision,remaining:remaining-1,completion:completion)}}
    }
    private static func visiblePreviews(_ pane:PreviewPane)->[WKWebView] {
        pane.subviews.compactMap{$0 as? NSClipView}.filter{!$0.isHidden}
            .flatMap{$0.documentView?.subviews ?? []}.compactMap{$0 as? WKWebView}.filter{!$0.isHidden}
    }
    private static func inactivePreview(_ pane:PreviewPane)->WKWebView {
        guard let view=pane.subviews.compactMap({$0 as? NSClipView})
            .flatMap({$0.documentView?.subviews ?? []}).compactMap({$0 as? WKWebView}).first(where:{$0 !== pane.webView}) else {
            fail("Missing inactive presentation surface")
        }
        return view
    }
    private static func verifyViewportHeight(_ pane:PreviewPane,completion:@escaping()->Void) {
        let source=fixtureSource(pane),original=pane.frame.size
        source.setLayout(height:1000,scale:10,origin:0);pane.sourceLayoutChanged()
        let geometry=source.geometryRevision,patches=pane.patchCount
        pane.setFrameSize(NSSize(width:original.width,height:500));pane.layoutSubtreeIfNeeded()
        check(pane.bounds.height==500,"Height-only resize fixture must use the new viewport height")
        source.viewportOrigin=source.contentHeight-pane.bounds.height;pane.moveViewport()
        pane.webView.evaluateJavaScript("document.getElementById('preview').offsetHeight") {value,error in
            check(error==nil && abs(Double(pane.visibleWebRange.upperBound)-(value as? Double ?? 0))<1,"A height-only resize must recompute the map and reach the rendered endpoint")
            check(source.geometryRevision==geometry && pane.patchCount==patches,"Viewport height changes need neither fabricated source revisions nor HTML updates")
            pane.setFrameSize(original);pane.layoutSubtreeIfNeeded()
            source.viewportOrigin=0;pane.moveViewport()
            check(abs(pane.visibleWebRange.lowerBound)<0.001,"Height-only resize must preserve the zero endpoint")
            print("VIEWPORT HEIGHT: map tracks the current height, both endpoints agree, no HTML update")
            completion()
        }
    }
    private static func verifyReplacementPresentation(completion:@escaping()->Void) {
        let pane=PreviewPane(frame:NSRect(x:0,y:0,width:500,height:380))
        let window=NSWindow(contentRect:pane.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        window.contentView=pane;window.setFrameOrigin(NSPoint(x:-10000,y:0));window.orderBack(nil)
        pane.scrolling = .synchronized(FixtureScrollSource())
        func result(_ name:String,_ revision:Int)->ParseResult {
            let color=name=="LATEST" ? "#0000ff":"#ff0000"
            let first=PreviewFragment(kind:"Paragraph",from:0,to:10,markdown:name,html:"<h1 style='background:\(color)'>\(name)</h1><p style='height:1600px'>Body</p><pre style='width:300px'>\(String(repeating:"x",count:1000))</pre>")
            let rest=(1..<10).map {index in
                PreviewFragment(kind:"Paragraph",from:index*10,to:(index+1)*10,markdown:"\(name) \(index)",html:"<p>\(name) \(index)</p>")
            }
            return ParseResult(revision:revision,spans:[],fragments:[first]+rest)
        }
        presentFixture(pane,result("FIRST",1))
        waitForPane(pane,revision:1) {verifyViewportHeight(pane) {
            let displayed=pane.webView
            guard let displayedClip=displayed.superview?.superview as? NSClipView else {fail("Preview surface must own a native clip")}
            fixtureSource(pane).setLayout(height:1000,scale:10,origin:80)
            pane.beginScrollGesture();pane.moveViewport()
            let heldOrigin=pane.clipOrigin
            fixtureSource(pane).setLayout(height:2000,scale:20,origin:80)
            pane.moveViewport()
            check(abs(pane.clipOrigin-heldOrigin)<0.001,"Ordinary updates must reuse the live-scroll map")
            presentFixture(pane,result("SUPERSEDED",2))
            presentFixture(pane,result("LATEST",3))
            check(pane.webView === displayed,"Pending DOM updates must not replace the displayed view before measurement")
            check(visiblePreviews(pane) == [displayed],"Only the current presentation view may be visible while preparing a replacement")
            waitForPane(pane,revision:3) {
                check(!pane.isScrollMappingFrozen,"Actual content changes must end the held gesture before publication")
                check(abs(pane.clipOrigin-heldOrigin)>1,"Completed preview geometry must refresh the map during a gesture")
                check(pane.webView.superview?.superview !== displayedClip,"Replacement must own a separate clip")
                check(abs(displayedClip.bounds.minY-heldOrigin)<0.001,"Positioning a replacement must never move the retired surface")
                fixtureSource(pane).setLayout(height:200,scale:1,origin:0)
                pane.endScrollGesture();pane.moveViewport()
                check(pane.webView !== displayed,"Measured replacement must take over as one presentation")
                check(displayed.isHidden && !pane.webView.isHidden,"Retired preview content must be hidden before the replacement becomes visible")
                displayed.evaluateJavaScript("document.querySelector('h1').textContent") {value,error in
                    check(error==nil && (value as? String)=="FIRST","Preparing replacement content must leave the old displayed DOM intact")
                    pane.webView.evaluateJavaScript("document.querySelector('h1').textContent") {value,error in
                        check(error==nil && (value as? String)=="LATEST","Only the latest requested replacement may be displayed")
                        guard let cg=CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:-60,wheel2:0,wheel3:0),let event=NSEvent(cgEvent:cg) else {fail("Cannot create overflow event")}
                        let before=pane.clipOrigin
                        check(pane.scrollOverflow(event),"A tall rendering of a short source must remain scrollable")
                        check(pane.clipOrigin>before,"Short-source preview must respond to downward input")
                        pane.navigatePreview(toEnd:true);pane.moveViewport()
                        let end=pane.visibleWebRange
                        pane.webView.evaluateJavaScript("document.getElementById('preview').offsetHeight") {value,error in
                            check(error==nil && abs(Double(end.upperBound)-(value as? Double ?? 0))<1,"Short-source navigation must reach the rendered end")
                            pane.navigatePreview(toEnd:false);pane.moveViewport()
                            check(abs(pane.visibleWebRange.lowerBound)<0.001,"Short-source navigation must return to the rendered beginning")
                            fixtureSource(pane).wheelEvents=0
                            let axisEvents:[(Int32,Int32,Int64)]=[(-30,1,1),(-1,30,2),(-1,30,1),(-30,1,2),(-30,1,1)]
                            for (y,x,phase) in axisEvents {
                                guard let cg=CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:2,wheel1:y,wheel2:x,wheel3:0) else {fail("Cannot create axis event")}
                                cg.setIntegerValueField(.scrollWheelEventScrollPhase,value:phase)
                                guard let event=NSEvent(cgEvent:cg) else {fail("Cannot bridge axis event")}
                                pane.webView.scrollWheel(with:event)
                            }
                            check(fixtureSource(pane).wheelEvents==3,"Preview gestures must retain their chosen axis despite diagonal component changes")
                            window.makeFirstResponder(pane.webView)
                            pane.webView.evaluateJavaScript("const text=document.querySelector('p').firstChild;window.getSelection().setBaseAndExtent(text,0,text,4);document.querySelector('pre').scrollLeft=70;JSON.stringify({selection:window.getSelection().toString(),state:astraViewState()})") {_,error in
                                check(error==nil,"Cannot prepare preview selection and horizontal state")
                                presentFixture(pane,result("LATEST",4))
                                waitForPane(pane,revision:4) {
                                    pane.webView.evaluateJavaScript("JSON.stringify({selection:window.getSelection().toString(),left:document.querySelector('pre').scrollLeft})") {value,error in
                                        guard error==nil,let string=value as? String,let data=string.data(using:.utf8),let state=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else {fail("Cannot inspect retained preview state")}
                                        check((state["selection"] as? String)=="Body","Unchanged preview text selection must survive replacement")
                                        check(abs((state["left"] as? Double ?? 0)-70)<1,"Horizontal reading position must survive replacement")
                                        print("REPLACEMENT: old DOM retained, superseded result rejected, geometry committed together; selection and horizontal state retained; gesture axes stable; short-source overflow and endpoints reachable")
                                        verifyPaintedReplacement(pane) { verifyStaleGeometry(pane) {
                                            pane.setFrameSize(NSSize(width:0,height:380));pane.layoutSubtreeIfNeeded()
                                            presentFixture(pane,result("LATEST",5))
                                            pane.setFrameSize(NSSize(width:500.5,height:380));pane.layoutSubtreeIfNeeded()
                                            waitForPane(pane,revision:5) {
                                                print("PRESENTATION SIZE: collapsed pane resumes at fractional width")
                                                verifyPresentationLifecycle(pane) {window.close();completion()}
                                            }
                                        } }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }}
    }
    private static func verifyPresentationLifecycle(_ pane:PreviewPane,completion:@escaping()->Void) {
        let active=pane.webView,width=active.frame.width,idle=inactivePreview(pane)
        fixtureSource(pane).visibleSourceRange=NSRange(location:0,length:100)
        idle.evaluateJavaScript("(()=>{const ready=astraReady;window.savedReady=ready;astraReady=async(...args)=>{await ready(...args);await new Promise(resolve=>setTimeout(resolve,100));};})();true") {_,error in
            check(error==nil,"Cannot delay hidden preparation")
            pane.fontSize=15;pane.setFrameSize(NSSize(width:620.5,height:380));pane.layoutSubtreeIfNeeded()
            check(active.frame.width==width && pane.webView === active,"Resize must retain the committed DOM width while preparing its replacement")
            DispatchQueue.main.asyncAfter(deadline:.now()+0.03) {
                pane.fontSize=17;pane.setFrameSize(NSSize(width:540.5,height:380));pane.layoutSubtreeIfNeeded()
                check(pane.webView === active && active.frame.width==width,"Superseded font and resize requests must not mutate the visible surface")
                check(visiblePreviews(pane)==[active] && !pane.isShowingLoadingState,"Preparing a covered replacement must keep exactly the last complete presentation visible")
                waitForPane(pane,revision:5) {
                    pane.webView.evaluateJavaScript("JSON.stringify({font:getComputedStyle(document.documentElement).fontSize,width:innerWidth,text:document.querySelector('h1').textContent})") {value,error in
                        guard error==nil,let string=value as? String,let data=string.data(using:.utf8),let state=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else {fail("Cannot inspect latest layout")}
                        check(state["font"] as? String=="17px" && abs((state["width"] as? Double ?? 0)-540.5)<=1,"Only the latest font and fractional width may be published")
                        check(state["text"] as? String=="LATEST" && visiblePreviews(pane)==[pane.webView],"Layout replacement must preserve content and surface isolation")
                        verifyPreparationFailure(pane,completion:completion)
                    }
                }
            }
        }
    }
    private static func verifyPreparationFailure(_ pane:PreviewPane,completion:@escaping()->Void) {
        let active=pane.webView,idle=inactivePreview(pane)
        func result(_ revision:Int)->ParseResult {
            ParseResult(revision:revision,spans:[],fragments:[PreviewFragment(kind:"Paragraph",from:0,to:100,markdown:"LATEST",html:"<h1 style='background:#0000ff'>LATEST</h1><p style='height:1600px'>Body</p>")])
        }
        idle.evaluateJavaScript("window.savedReady=astraReady;astraReady=()=>{throw new Error('injected preparation failure');};true") {_,error in
            check(error==nil,"Cannot inject preparation failure")
            presentFixture(pane,result(6))
            DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
                check(pane.webView === active && pane.lastRevision != 6 && visiblePreviews(pane)==[active],"Failed preparation must not publish content or claim a ready revision")
                check(!pane.isShowingLoadingState,"A failed covered update must retain the complete presentation rather than flash a loading mask")
                idle.evaluateJavaScript("astraReady=savedReady;true") {_,error in
                    check(error==nil,"Cannot restore preparation")
                    presentFixture(pane,result(7))
                    waitForPane(pane,revision:7) {
                        verifyPaintedReplacement(pane) {
                            let failed=pane.webView
                            pane.webViewWebContentProcessDidTerminate(failed)
                            check(pane.lastRevision<0 && visiblePreviews(pane).isEmpty && pane.isShowingLoadingState,"Process failure must revoke readiness and hide the failed surface immediately")
                            pane.moveViewport()
                            check(pane.isShowingLoadingState,"Source notifications must not reveal a surface awaiting recovery")
                            waitForPane(pane,revision:7) {
                                check(pane.webView !== failed && visiblePreviews(pane)==[pane.webView],"Process recovery must publish through the same isolated presentation path")
                                let metadata=PreviewFragment(kind:"Paragraph",from:0,to:130,markdown:"LATEST",html:"<h1 style='background:#0000ff'>LATEST</h1><p style='height:1600px'>Body</p>")
                                fixtureSource(pane).sourceLength=130
                                presentFixture(pane,ParseResult(revision:7,spans:[],fragments:[metadata]))
                                waitForPane(pane,revision:7) {
                                    check(pane.displayedSourceRange?.length==130,"Metadata-only changes must publish their own complete presentation")
                                    fixtureSource(pane).sourceLength=2000;fixtureSource(pane).visibleSourceRange=NSRange(location:500,length:100);pane.moveViewport()
                                    check(pane.displayedSourceRange?.length==130 && pane.isShowingLoadingState,"Growing source metadata must not make old HTML claim coverage of a new destination")
                                    fixtureSource(pane).sourceLength=130;fixtureSource(pane).visibleSourceRange=NSRange(location:0,length:100);pane.moveViewport()
                                    print("PRESENTATION LIFECYCLE: superseded font/width, covered loading, failed preparation, painted recovery, process restart and metadata-only changes")
                                    verifyRelativeAssets(pane,completion:completion)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    private static func verifyRelativeAssets(_ pane:PreviewPane,completion:@escaping()->Void) {
        let root=URL(fileURLWithPath:"/private/tmp/astra-assets-"+UUID().uuidString,isDirectory:true)
        let directories=[root.appendingPathComponent("red",isDirectory:true),root.appendingPathComponent("blue",isDirectory:true)]
        do {
            for (index,directory) in directories.enumerated() {
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0) else {fail("Cannot prepare asset fixture")}
                for x in 0..<2 {for y in 0..<2 {bitmap.setColor(NSColor(deviceRed:index==0 ? 1:0,green:0,blue:index==0 ? 0:1,alpha:1),atX:x,y:y)}}
                guard let png=bitmap.representation(using:.png,properties:[:]) else {fail("Cannot encode asset fixture")}
                try png.write(to:directory.appendingPathComponent("tile.png"))
            }
        } catch {fail("Cannot create asset fixtures: \(error)")}
        let result=ParseResult(revision:8,spans:[],fragments:[PreviewFragment(kind:"Paragraph",from:0,to:130,markdown:"![tile](tile.png)",html:"<p><img src='astra-asset://image/?source=tile.png' style='width:32px;height:32px'></p><p style='height:1600px'>Body</p>")])
        func inspect(_ index:Int) {
            pane.webView.evaluateJavaScript("const r=document.images[0].getBoundingClientRect();JSON.stringify({x:r.left+8,y:r.top+8,base:new URL(document.images[0].src).searchParams.get('base')})") {value,error in
                guard error==nil,let string=value as? String,let data=string.data(using:.utf8),let image=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let x=image["x"] as? Double,let y=image["y"] as? Double else {fail("Cannot inspect relative asset")}
                check(image["base"] as? String==directories[index].absoluteString,"Asset resource keys must include the captured document directory")
                let snapshot=WKSnapshotConfiguration();snapshot.rect=NSRect(x:x,y:y,width:2,height:2);snapshot.afterScreenUpdates=false
                pane.webView.takeSnapshot(with:snapshot) {picture,error in
                    guard error==nil,let data=picture?.tiffRepresentation,let bitmap=NSBitmapImageRep(data:data),let color=bitmap.colorAt(x:0,y:0)?.usingColorSpace(.deviceRGB) else {fail("Cannot inspect painted asset")}
                    check(index==0 ? color.redComponent>0.8 && color.blueComponent<0.2:color.blueComponent>0.8 && color.redComponent<0.2,"Changing the document directory must paint the new asset, not a cached image from the old directory")
                    if index==0 {
                        pane.baseURL=directories[1]
                        waitForPane(pane,revision:8) {inspect(1)}
                    } else {
                        try? FileManager.default.removeItem(at:root)
                        print("RELATIVE ASSETS: identical markup, two document directories, correct red/blue painted pixels")
                        completion()
                    }
                }
            }
        }
        pane.baseURL=directories[0];presentFixture(pane,result)
        waitForPane(pane,revision:8) {inspect(0)}
    }
    private static func verifyPaintedReplacement(_ pane:PreviewPane,completion:@escaping()->Void) {
        let snapshot=WKSnapshotConfiguration()
        snapshot.rect=NSRect(x:460,y:20,width:4,height:4);snapshot.afterScreenUpdates=false
        pane.webView.takeSnapshot(with:snapshot) {image,error in
            guard error==nil,let data=image?.tiffRepresentation,let bitmap=NSBitmapImageRep(data:data),
                  let color=bitmap.colorAt(x:0,y:0)?.usingColorSpace(.deviceRGB) else {fail("Cannot inspect the painted replacement")}
            check(color.blueComponent>0.8 && color.redComponent<0.2,"The promoted WebKit surface must paint the latest blue content, not the retired red content")
            print("PAINTED REPLACEMENT: current surface contains latest content without requesting another paint")
            completion()
        }
    }
    private static func verifyStaleGeometry(_ pane:PreviewPane,completion:@escaping()->Void) {
        let committed=pane.webView,frame=pane.webView.frame,origin=pane.clipOrigin,revision=pane.lastRevision
        pane.webView.evaluateJavaScript("const stale=geometry();stale.measurement=0;stale.height=1;stale.items=[];window.webkit.messageHandlers.geometry.postMessage(stale);const invalid=geometry();invalid.measurement+=100;invalid.items[0].id='unknown-fragment';window.webkit.messageHandlers.geometry.postMessage(invalid);true") {_,error in
            if let error {print("STALE GEOMETRY INJECTION: \(error)")}
            check(error==nil,"Cannot inject a delayed geometry report")
            DispatchQueue.main.asyncAfter(deadline:.now()+0.05) {
                check(pane.webView === committed && pane.lastRevision==revision && pane.webView.frame==frame && abs(pane.clipOrigin-origin)<0.001,"Older or malformed newer measurements must not replace committed geometry or ready state")
                print("PRESENTATION: inactive views hidden; delayed geometry from the same revision rejected")
                completion()
            }
        }
    }
    private static func verifyNativeComposition() {
        let document=MarkdownDocument();fixtureDocuments.append(document);document.setInitialText("alpha\n")
        let controller=EditorWindowController(document:document);document.addWindowController(controller);controller.window?.orderBack(nil)
        let source=controller.source,text=source.textView
        text.setMarkedText("候",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:0,length:0))
        check(text.hasMarkedText(),"Native source must support marked text")
        let geometry=source.geometryRevision
        source.applyHighlights([],in:source.documentRange)
        check(source.geometryRevision==geometry,"Syntax application must wait while native marked text is active")
        text.insertText("候補",replacementRange:NSRange(location:NSNotFound,length:0))
        check(!text.hasMarkedText() && document.source.string=="候補alpha\n","Committing native composition must update the global source exactly once: native=\(text.string.debugDescription), model=\(document.source.string.debugDescription), marked=\(text.hasMarkedText())")
        document.undoManager?.removeAllActions()
        text.selectAll(nil)
        check(text.selectedRange()==source.documentRange,"Native select-all must cover the retained document")
        document.undoManager?.beginUndoGrouping();text.insertText("replacement",replacementRange:text.selectedRange());document.undoManager?.endUndoGrouping()
        check(document.source.string=="replacement","Native whole-document replacement must update the model")
        document.undoManager?.undo()
        check(document.source.string=="候補alpha\n" && text.selectedRange()==source.documentRange,"Undo must restore both whole-document content and its native selection: model=\(document.source.string.debugDescription), selection=\(text.selectedRange()), expected=\(source.documentRange)")
        print("NATIVE SOURCE: marked-text commit, deferred styling, select-all, full replacement and selection-preserving undo")
        controller.window?.close()
    }
    private static func performDocumentChecks(_ document:MarkdownDocument) {
        guard let controller=document.windowControllers.first as? EditorWindowController else {fail("Missing editor window")}
        controller.window?.orderBack(nil)
        controller.window?.makeFirstResponder(controller.source.textView)
        let original = document.source.string
        controller.source.textView.setSelectedRange(NSRange(location:0,length:0))
        document.undoManager?.beginUndoGrouping()
        controller.source.textView.insertText("Edited ",replacementRange:NSRange(location:0,length:0))
        document.undoManager?.endUndoGrouping()
        check(document.source.string == "Edited "+original,"Native text edits must update source")
        check(NSApp.sendAction(#selector(EditorWindowController.undo(_:)),to:nil,from:nil),"Undo must be available through the responder chain")
        check(document.source.string == original,"Undo must restore the retained source")
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

        let large = (0..<600).map { "## Passage \($0)\n\nA **bold** paragraph with *emphasis* and an inline equation $x^2$.\n\n" }.joined()
        document.setInitialText(large)
        let oldCaret = controller.source.selection
        check(controller.source.documentRange==NSRange(location:0,length:document.source.count),"Source coordinates must come from one retained document layout")
        let target = document.source.lineStart(1200)
        controller.source.reveal(target,alignTop:true)
        check(NSEqualRanges(controller.source.selection,oldCaret),"Scrolling must preserve the global caret")
        check(controller.source.documentRange.length==document.source.count,"Distant navigation must retain the source layout")
        let anchorLine = document.source.line(at:controller.source.viewportAnchor)
        check(abs(anchorLine-1200)<8,"Navigation must show the requested passage")
        for width:CGFloat in [920,1120,760,1040,920] {
            controller.window?.setContentSize(NSSize(width:width,height:650))
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            print("RESIZE: width=\(width), beforeLine=\(anchorLine), afterLine=\(document.source.line(at:controller.source.viewportAnchor)), document=\(controller.source.documentRange), bounds=\(controller.source.scroll.contentView.bounds), frame=\(controller.source.textView.frame)"); fflush(stdout)
            check(abs(document.source.line(at:controller.source.viewportAnchor)-anchorLine)<8,"Resizing must preserve the distant passage")
        }
        waitForPreview(controller,document:document,remaining:600)
    }
    private static func waitForPreview(_ controller:EditorWindowController,document:MarkdownDocument,remaining:Int) {
        if controller.hasPreparedViewport && controller.preview.lastRevision == document.revision && controller.preview.preparedFragmentCount>0 {
            print("VIEWPORT CHECK: fragments=\(controller.preview.preparedFragmentCount), sourceDocument=\(controller.source.documentRange), caret=\(controller.source.selection), scroll=\(controller.source.scroll.contentView.bounds), textFrame=\(controller.source.textView.frame)")
            fflush(stdout)
            check(controller.preview.preparedFragmentCount>0,"Document presentation must include the prepared destination")
            check(controller.source.documentRange.length==document.source.count,"Highlighting must retain the source document")
            check(controller.source.textView.layoutManager != nil,"Keep the complete native glyph layout active")
            verifyWebPreview(controller,document:document)
        } else if remaining == 0 { fail("Preview did not finish for latest document revision: ready=\(controller.preview.lastRevision), cacheComplete=\(controller.hasPreparedDocument), \(controller.preview.debugGeometry())") }
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
            controller.preview.webView.evaluateJavaScript("JSON.stringify({count:document.querySelectorAll('#preview section[data-id]').length,math:document.querySelectorAll('.katex').length,passage:[...document.querySelectorAll('h2')].find(n=>n.textContent==='Passage 300')?.getBoundingClientRect().top,text:document.getElementById('preview').innerText})") {value,error in
                guard error==nil,let string=value as? String,let data=string.data(using:.utf8),let result=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else {fail("WebKit did not return preview content")}
                check((result["count"] as? Int ?? 0)>0,"Prepared document content must remain mounted")
                check((result["math"] as? Int ?? 0)>0,"KaTeX must render the visible math")
                check((result["text"] as? String ?? "").contains("Passage 300"),"Preview must correspond to the distant source passage")
                check(abs(((result["passage"] as? Double) ?? .infinity)-Double(controller.preview.visibleWebRange.lowerBound))<Double(controller.preview.bounds.height)*2,"Distant passage must be near the displayed viewport, not merely present elsewhere in the DOM")
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
        check(preview.scrollLandmarkCount>0 && preview.scrollLandmarkCount<=preview.preparedFragmentCount*2,"References must remain bounded to the mounted blocks")
        let allowed=source.document.source
        for offset in preview.semanticLandmarkOffsets {
            let line=allowed.line(at:offset)
            let text=allowed.string(in:allowed.lines(line,line+1)).trimmingCharacters(in:.whitespacesAndNewlines)
            check(text.hasPrefix("#") || text.hasPrefix("!["),"Only heading and standalone image offsets may be semantic references in the demo")
        }
        let original=preview.scrolling
        source.beginScrollGesture()
        check(preview.isScrollMappingFrozen,"Native source gesture must freeze preview mapping")
        let origin=preview.clipOrigin
        let changed=FixtureScrollSource()
        changed.contentRevision=source.contentRevision;changed.geometryRevision=source.geometryRevision+1000
        changed.contentHeight=source.contentHeight;changed.viewportOrigin=source.viewportOrigin
        changed.sourceLength=source.sourceLength;changed.visibleSourceRange=source.visibleSourceRange
        changed.position={offset in source.verticalPosition(for:offset).map{$0*2}}
        preview.scrolling = .synchronized(changed);preview.moveViewport()
        check(abs(preview.clipOrigin-origin)<0.001,"Layout changes must not replace frozen landmark coordinates")
        preview.scrolling=original
        source.endScrollGesture()
        check(!preview.isScrollMappingFrozen,"Gesture completion must release the mapping")
        preview.moveViewport()
        check(abs(preview.clipOrigin-origin)<0.001,"Releasing a snapshot must not move the preview")
        source.beginScrollGesture();preview.moveViewport()
        check(abs(preview.clipOrigin-origin)<0.001,"Beginning a new snapshot must not move the preview")
        source.endScrollGesture()
        print("FROZEN SCROLL: heading/image references, ordinary geometry changes held during live scrolling")
    }
    private static func verifyGesturePhases(_ controller:EditorWindowController,completion:@escaping()->Void) {
        let source=controller.source,preview=controller.preview,center=NotificationCenter.default
        source.endScrollGesture()
        center.post(name:NSScrollView.willStartLiveScrollNotification,object:source.scroll)
        check(source.isScrolling && preview.isScrollMappingFrozen,"Native live-scroll start must freeze the map")
        let origin=preview.clipOrigin
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
            check(preview.isScrollMappingFrozen,"A pause must not synthesize a gesture end")
            center.post(name:NSScrollView.didEndLiveScrollNotification,object:source.scroll)
            check(!source.isScrolling && !preview.isScrollMappingFrozen,"Native live-scroll end must release the map immediately")
            check(abs(preview.clipOrigin-origin)<0.001,"Gesture end must not reposition the preview")
            print("LIVE SCROLL: native start/end notifications, no idle timer or gesture-end correction")
            completion()
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
                verifyImageSmoothness(controller,document:document) {
                    verifyImageEdgeScrolling(controller,document:document) {verifyTableSource(controller,document:document)}
                }
            } else {DispatchQueue.main.asyncAfter(deadline:.now()+0.1) {pollExampleAssets(controller,document:document,remaining:remaining-1)}}
        }
    }
    private static func verifyImageSmoothness(_ controller:EditorWindowController,document:MarkdownDocument,completion:@escaping()->Void) {
        let source=controller.source,preview=controller.preview
        preview.webView.evaluateJavaScript("document.images[0].getBoundingClientRect().height") {value,error in
            guard error==nil,let imageHeight=value as? Double,imageHeight>100 else {fail("Cannot measure the image scroll transition")}
            let text=document.source.string as NSString,at=text.range(of:"![A smooth").location
            let center=Double(source.debugMeasuredPosition(for:at))
            let height=Double(source.canvas.bounds.height),viewport=Double(source.scroll.contentSize.height)
            let first=ScrollLandmarks.viewportOrigin(for:max(0,center-imageHeight/2-200),sourceHeight:height,viewportHeight:viewport)
            let last=ScrollLandmarks.viewportOrigin(for:center+imageHeight/2+200,sourceHeight:height,viewportHeight:viewport)
            source.scroll.contentView.scroll(to:NSPoint(x:0,y:first));source.scroll.reflectScrolledClipView(source.scroll.contentView)
            source.beginScrollGesture()
            let beginning=preview.clipOrigin,patches=preview.patchCount
            var previous=beginning,maximum:CGFloat=0,steps=0
            for y in stride(from:first+0.5,through:last,by:0.5) {
                source.scroll.contentView.scroll(to:NSPoint(x:0,y:y));source.scroll.reflectScrolledClipView(source.scroll.contentView)
                let delta=preview.clipOrigin-previous
                check(delta>=(-0.001) && delta<3,"Small source movements must not reverse or jump across an image")
                maximum=max(maximum,delta);previous=preview.clipOrigin;steps += 1
            }
            check(preview.clipOrigin-beginning>imageHeight*0.8,"Image motion check must traverse the rendered image rather than a flat part of the map")
            for y in stride(from:last-0.5,through:first,by:-0.5) {
                source.scroll.contentView.scroll(to:NSPoint(x:0,y:y));source.scroll.reflectScrolledClipView(source.scroll.contentView)
                let delta=preview.clipOrigin-previous
                check(delta<=0.001 && delta>(-3),"Reverse scrolling across an image must remain continuous")
                maximum=max(maximum,-delta);previous=preview.clipOrigin;steps += 1
            }
            check(preview.patchCount==patches,"Prepared image scrolling must not issue DOM updates")
            source.endScrollGesture()
            print("IMAGE MOTION: \(steps) half-point steps, maximum preview step=\(maximum), image height=\(imageHeight)")
            completion()
        }
    }
    private static func verifyImageEdgeScrolling(_ controller:EditorWindowController,document:MarkdownDocument,completion:@escaping()->Void) {
        let source=controller.source,preview=controller.preview
        let at=(document.source.string as NSString).range(of:"![A smooth").location
        let center=source.debugMeasuredPosition(for:at),start=max(0,center-500),end=center+900
        source.beginScrollGesture()
        let points=preview.debugScrollLandmarks
        if let imageIndex=points.firstIndex(where:{$0.offset==at}) {
            for index in max(0,imageIndex-1)...min(points.count-2,imageIndex) {
                let a=points[index],b=points[index+1]
                print("IMAGE INTERVAL: sourceOffsets=\(a.offset)...\(b.offset), sourceDistance=\(b.sourceY-a.sourceY), previewDistance=\(b.previewY-a.previewY), gain=\((b.previewY-a.previewY)/(b.sourceY-a.sourceY))")
            }
        }
        var observations=0
        func step(_ index:Int) {
            if index==120 {
                source.endScrollGesture()
                print("IMAGE EDGE: \(observations) paced fast-scroll observations, one image per source occurrence, one clipped presentation")
                completion();return
            }
            let phase=index%20,progress=CGFloat(phase<10 ? phase:19-phase)/9
            source.scroll.contentView.scroll(to:NSPoint(x:0,y:start+(end-start)*progress))
            source.scroll.reflectScrolledClipView(source.scroll.contentView)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.016) {
                let surfaces=preview.subviews.compactMap{$0 as? NSClipView}
                let visible=surfaces.filter{!$0.isHidden}
                check(visible.count==1,"Fast image-edge scrolling must expose one presentation")
                for clip in surfaces {
                    check(clip.clipsToBounds && clip.layer?.masksToBounds==true,"Each preview surface must clip WebKit's composited layers at its viewport boundary")
                }
                preview.webView.evaluateJavaScript("JSON.stringify([...document.images].map(i=>({owner:i.closest('section').dataset.id,complete:i.complete,width:i.naturalWidth})))") {value,error in
                    guard error==nil,let string=value as? String,let data=string.data(using:.utf8),let images=(try? JSONSerialization.jsonObject(with:data)) as? [[String:Any]] else {fail("Cannot inspect image-edge presentation")}
                    let owners=images.compactMap{$0["owner"] as? String}
                    check(Set(owners).count==owners.count,"A source image occurrence must not be duplicated in the displayed DOM")
                    check(images.allSatisfy{($0["complete"] as? Bool)==true && ($0["width"] as? Double ?? 0)>0},"Displayed images must be decoded during rapid edge crossings")
                    observations += 1;step(index+1)
                }
            }
        }
        step(0)
    }
    private static func verifyTableSource(_ controller:EditorWindowController,document:MarkdownDocument) {
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
        print("TABLE SOURCE: tall viewport, 100 scroll steps through the retained layout, no blank source tail")
        controller.source.reveal(at,alignTop:true)
        pollTable(controller,document:document,remaining:100)
    }
    private static func pollTable(_ controller:EditorWindowController,document:MarkdownDocument,remaining:Int) {
        guard remaining>0 else{fail("Table viewport did not render")}
        controller.preview.webView.evaluateJavaScript("JSON.stringify((()=>{const row=[...document.querySelectorAll('tbody tr')].find(r=>r.cells[0]?.textContent.trim()==='500'),t=row?.closest('table');return {tables:t?1:0,headers:t?.querySelectorAll('thead').length,rows:t?.querySelectorAll('tbody tr').length,text:document.getElementById('preview').innerText}})())") {value,error in
            if error==nil,controller.hasPreparedViewport,controller.preview.lastRevision==document.revision,let string=value as? String,let data=string.data(using:.utf8),let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],(object["text"] as? String ?? "").contains("500"),(object["rows"] as? Int ?? 0)>0 {
                check((object["rows"] as? Int)==800,"A prepared table must retain all 800 rows")
                check((object["tables"] as? Int)==1 && (object["headers"] as? Int)==1,"A complete table must have one header")
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
        print("SOURCE END: line=\(source.debugMeasuredPosition(for:document.source.count-2)), clip=\(source.scroll.contentView.bounds), canvas=\(source.canvas.frame), text=\(source.textView.frame)");fflush(stdout)
        check(source.debugMeasuredPosition(for:document.source.count-2)<source.scroll.contentView.bounds.maxY-16,"Final source line must be fully visible")
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
            beginBurstScroll(controller,caseIndex:0);return
        }
        if remaining%8==0 {
            let origin=controller.preview.clipOrigin
            source.endScrollGesture();source.beginScrollGesture()
            controller.preview.moveViewport()
            check(abs(controller.preview.clipOrigin-origin)<0.001,"Fast scrolling must not jump at a gesture handoff after window replacements")
        }
        source.scroll.contentView.scroll(to:NSPoint(x:0,y:source.scroll.contentView.bounds.minY+64))
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
    private static let burstPassages=["## Section 20","| 500 |","## Section 60"]
    private static var passageObservations=[0,0,0]
    private static func beginBurstScroll(_ controller:EditorWindowController,caseIndex:Int) {
        guard caseIndex<burstPassages.count else {
            print("PASSAGE OBSERVATIONS: prose/table/image=\(passageObservations)")
            print("BURST SCROLL: 600 coverage observations across prose, table and image windows, including reversal and gesture handoffs")
            pollPreparedDocument(controller,remaining:100);return
        }
        controller.window?.setContentSize(NSSize(width:1730,height:1190))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let offset=((controller.document as! MarkdownDocument).source.string as NSString).range(of:burstPassages[caseIndex]).location
        controller.source.reveal(offset,alignTop:true)
        func ready(_ remaining:Int) {
            guard remaining>0 else{fail("Burst destination did not become ready: \(controller.preview.debugGeometry())")}
            guard controller.hasPreparedViewport,controller.preview.coversSourceViewport else {
                DispatchQueue.main.asyncAfter(deadline:.now()+0.03){ready(remaining-1)};return
            }
            if caseIndex==1 {
                let source=controller.source.document.source
                check(controller.preview.semanticLandmarkOffsets.allSatisfy{offset in
                    let line=source.line(at:offset)
                    return !source.string(in:source.lines(line,line+1)).trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix("|")
                },"Table rows must not enter the sparse scroll map")
            }
            controller.source.beginScrollGesture()
            observeBurstScroll(controller,caseIndex:caseIndex,step:0)
        }
        ready(300)
    }
    private static func observeBurstScroll(_ controller:EditorWindowController,caseIndex:Int,step:Int) {
        let source=controller.source,preview=controller.preview
        if step==200 {
            source.endScrollGesture()
            print("BURST END: case=\(caseIndex), drift=\(preview.debugAlignmentDrift), sourceAnchor=\(source.viewportAnchor), \(preview.debugGeometry())");fflush(stdout)
            check(abs(preview.debugAlignmentDrift)<Double(preview.bounds.height)/4,"Long scroll reversals must not leave the preview showing a distant passage")
            beginBurstScroll(controller,caseIndex:caseIndex+1);return
        }
        if step>0 && step%40==0 {
            let before=preview.clipOrigin
            source.endScrollGesture();source.beginScrollGesture();preview.moveViewport()
            check(abs(preview.clipOrigin-before)<0.001,"Burst gesture handoff must preserve the visible position")
        }
        let direction:CGFloat=step<100 ? 1:-1
        source.scroll.contentView.scroll(to:NSPoint(x:0,y:source.scroll.contentView.bounds.minY+direction*128))
        source.scroll.reflectScrolledClipView(source.scroll.contentView)
        check(source.documentRange.length==(controller.document as! MarkdownDocument).source.count,"Scrolling must retain one measured source coordinate frame")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.01) {
            let passage=source.alignmentAnchor
            let rope=(controller.document as! MarkdownDocument).source
            let line=rope.line(at:passage)
            let sourceLine=rope.string(in:rope.lines(line,min(rope.lineCount,line+1)))
            let cells=sourceLine.split(separator:"|").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}
            let row=sourceLine.hasPrefix("|") ? (cells.first.flatMap{Int($0)} ?? -1):-1
            let script="JSON.stringify({...geometry(),origin:document.getElementById('preview').getBoundingClientRect().top,scrollY:window.scrollY,webHeight:innerHeight,batches:[...document.querySelectorAll('tbody')].map(n=>({id:n.dataset.fragment,first:n.rows[0]?.cells[0]?.textContent,last:n.rows[n.rows.length-1]?.cells[0]?.textContent,count:n.rows.length,from:n.closest('section')?._from,to:n.closest('section')?._to})),passages:[...document.querySelectorAll('#preview section[data-id]')].filter(n=>Number(n._from)<=\(passage)&&Number(n._to)>\(passage)).map(n=>{const b=(n._body||n).getBoundingClientRect();return {top:b.top,bottom:b.bottom}}),row:[...document.querySelectorAll('tbody tr')].filter(n=>n.cells[0]?.textContent.trim()===String(\(row))).map(n=>{const b=n.getBoundingClientRect();return {top:b.top,bottom:b.bottom}})})"
            let prepared=controller.hasPreparedViewport
            let measuredView=preview.webView
            measuredView.evaluateJavaScript(script) {value,error in
                guard measuredView === preview.webView else {
                    observeBurstScroll(controller,caseIndex:caseIndex,step:step+1);return
                }
                guard error==nil,let string=value as? String,let data=string.data(using:.utf8),
                      let result=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
                      let height=result["height"] as? Double else {fail("Cannot measure burst preview coverage")}
                let visible=preview.visibleWebRange
                check(visiblePreviews(preview) == [preview.webView],"Fast replacements must never expose an inactive preview surface")
                check(visible.lowerBound>=(-1),"Burst scrolling must not reveal a blank leading margin")
                check(visible.lowerBound<CGFloat(height),"Burst scrolling must keep rendered content visible")
                if height>=Double(preview.bounds.height) {
                    check(visible.upperBound<=CGFloat(height)+1,"Burst scrolling must keep the entire preview covered")
                }
                if prepared {
                    check(abs((result["origin"] as? Double) ?? .infinity)<0.001,"Browser must not introduce a second vertical scroll origin")
                    let rectangles=(result[row>=0 ? "row":"passages"] as? [[String:Double]]) ?? []
                    if row>=0 && rectangles.isEmpty {print("MISSING ROW: case=\(caseIndex), step=\(step), row=\(row), source=\(passage), batches=\(String(describing:result["batches"])), \(preview.debugGeometry())");fflush(stdout)}
                    if row>=0 {check(!rectangles.isEmpty,"Prepared table must contain the source alignment row")}
                    if !rectangles.isEmpty {
                        passageObservations[caseIndex] += 1
                        // Sparse references intentionally permit intermediate table
                        // rows to drift; row-by-row alignment is no longer a contract.
                        let center=Double(visible.lowerBound+source.alignmentOffset),margin=Double(preview.bounds.height)/4
                        if row<0 && !rectangles.contains(where:{($0["bottom"] ?? 0)>=center-margin && ($0["top"] ?? .infinity)<=center+margin}) {print("PASSAGE ERROR: case=\(caseIndex), step=\(step), row=\(row), source=\(passage), center=\(center), rects=\(rectangles), drift=\(preview.debugAlignmentDrift), origin=\(String(describing:result["origin"])), scrollY=\(String(describing:result["scrollY"])), webHeight=\(String(describing:result["webHeight"])), sourceRect=\(source.debugMeasuredPosition(for:passage)), currentY=\(source.scroll.contentView.bounds.minY), a=\(source.alignmentOffset), \(preview.debugGeometry())");fflush(stdout)}
                        if row<0 {check(rectangles.contains{($0["bottom"] ?? 0)>=center-margin && ($0["top"] ?? .infinity)<=center+margin},"Sparse mapping must keep the surrounding source passage near the preview alignment position")}
                    }
                }
                if !preview.coversSourceViewport {
                    check(preview.isShowingLoadingState,"An incomplete source viewport must display its loading state")
                }
                observeBurstScroll(controller,caseIndex:caseIndex,step:step+1)
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
                print("INTEGRATION PASSED: native editing, undo/redo, encoding, CRLF, distant navigation, retained measured source layout and native document trees, resizing, KaTeX, synchronized viewport scrolling, edited WebKit preview, local image, whole tables, whole-document background HTML cache (\(controller.cachedPageCount) pages), cached destination jump without reparsing")
                if CommandLine.arguments.contains("--diagnostics") {
                    TimingDiagnostics.shared.stop()
                    let snapshot=TimingDiagnostics.shared.snapshot()
                    for name in ["source.layout","source.highlight","web.patch.roundtrip","web.dom.layout","parse.viewport.work","parse.comrak","parse.records"] {
                        check(snapshot.events.contains{$0.name==name},"Diagnostics must record \(name)")
                    }
                    check(snapshot.events.contains{$0.name=="web.patch.encode" && ($0.values["htmlEntries"] ?? .infinity)<($0.values["mounted"] ?? 0)},"Retained WebKit surfaces must receive a partial HTML payload")
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

#endif
