import AppKit
import MarkdownCore

/// Opt-in geometry-only trace for reproducing AppKit resize event order.
/// Enable with `defaults write org.astramarkdown.editor ResizeTraceEnabled -bool YES`.
@MainActor enum ResizeTrace {
    private static let file:FileHandle? = {
        guard UserDefaults.standard.bool(forKey:"ResizeTraceEnabled") else{return nil}
        let path="/private/tmp/markato-resize.log"
        FileManager.default.createFile(atPath:path,contents:Data(),attributes:nil)
        return try? FileHandle(forWritingTo:URL(fileURLWithPath:path))
    }()
    static func record(_ event:String,_ state:String="") {
        guard let file else{return}
        let line="\(ProcessInfo.processInfo.systemUptime) \(event) \(state)\n"
        try? file.write(contentsOf:Data(line.utf8))
    }
}

final class FlippedView:NSView {override var isFlipped:Bool {true}}
/// The two panes share one resize transaction. Anchors are captured once;
/// geometry callbacks may update origins, while mouse-up only ends the drag.
@MainActor final class ViewportResizeSession {
    let sourceOffset:Int
    let sourceDisplacement:CGFloat
    let previewEntryID:String?
    let previewDisplacement:CGFloat
    var sourceOrigin:CGFloat
    var previewOrigin:CGFloat
    var isDragging=true
    var protectsViewport=true
    init(sourceOffset:Int,sourceDisplacement:CGFloat,sourceOrigin:CGFloat,
         previewEntryID:String?,previewDisplacement:CGFloat,previewOrigin:CGFloat) {
        self.sourceOffset=sourceOffset;self.sourceDisplacement=sourceDisplacement
        self.sourceOrigin=sourceOrigin
        self.previewEntryID=previewEntryID;self.previewDisplacement=previewDisplacement
        self.previewOrigin=previewOrigin
    }
}
private final class SourceScrollView:NSScrollView {
    override class var isCompatibleWithResponsiveScrolling:Bool {true}
    var consumeScroll:((NSEvent)->Bool)?
    var userWillScroll:(()->Void)?
    override func scrollWheel(with event:NSEvent) {
        userWillScroll?()
        if consumeScroll?(event) != true {super.scrollWheel(with:event)}
    }
}
private final class SourceScroller:NSScroller {
    var userWillScroll:(()->Void)?
    override func mouseDown(with event:NSEvent) {
        userWillScroll?()
        super.mouseDown(with:event)
    }
}
private final class SourceClipView:NSClipView {
    var resizeSession:ViewportResizeSession?
    override func setBoundsOrigin(_ newOrigin:NSPoint) {
        var origin=newOrigin
        // The source wraps to the clip width; horizontal scrolling is never
        // meaningful, even while AppKit retile centers a stale document width.
        origin.x=0
        if let session=resizeSession,session.protectsViewport {origin.y=session.sourceOrigin}
        if abs(newOrigin.y-bounds.minY)>0.1 || abs(newOrigin.x-bounds.minX)>0.1 {
            ResizeTrace.record("clip.setBoundsOrigin", "old=\(bounds.origin) proposed=\(newOrigin) applied=\(origin) pin=\(resizeSession?.protectsViewport == true)")
        }
        super.setBoundsOrigin(origin)
    }
    override func constrainBoundsRect(_ proposedBounds:NSRect)->NSRect {
        var constrained=super.constrainBoundsRect(proposedBounds)
        constrained.origin.x=0
        if let session=resizeSession,session.protectsViewport {constrained.origin.y=session.sourceOrigin}
        return constrained
    }
}
final class SourceTextView:NSTextView {
    weak var owner:SourceEditor?
    override func mouseDown(with event:NSEvent) {
        owner?.prepareForUserInteraction()
        super.mouseDown(with:event)
    }
    override func insertText(_ insertString:Any,replacementRange:NSRange) {
        // AppKit otherwise uses the editor-wide typing attributes for direct
        // insertText calls. Seed the transaction from the replaced/adjacent
        // source character so ordinary typing preserves the already-prepared
        // block typography; Comrak will correct it if the edit changes syntax.
        if replacementRange.location != NSNotFound,let storage=textStorage,storage.length>0 {
            let offset=min(replacementRange.location,storage.length-1)
            let inherited=storage.attributes(at:offset,effectiveRange:nil)
            typingAttributes=inherited.filter{$0.key == .font || $0.key == .foregroundColor}
        }
        if let text=insertString as? String,owner?.document.newline=="\r\n" {
            super.insertText(text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\n",with:"\r\n"),replacementRange:replacementRange)
        } else {super.insertText(insertString,replacementRange:replacementRange)}
    }
    override func paste(_ sender:Any?) {
        if let text=NSPasteboard.general.string(forType:.string) {insertText(text,replacementRange:selectedRange())}
    }
    override func scrollToEndOfDocument(_ sender:Any?) {if let owner {owner.reveal(owner.document.source.count)}}
    override func scrollToBeginningOfDocument(_ sender:Any?) {owner?.reveal(0)}
    override func moveToBeginningOfDocument(_ sender:Any?) {owner?.reveal(0)}
    override func moveToEndOfDocument(_ sender:Any?) {if let owner {owner.reveal(owner.document.source.count)}}
    override func keyDown(with event:NSEvent) {
        owner?.prepareForUserInteraction()
        if event.modifierFlags.contains(.command),!event.modifierFlags.contains(.shift) {
            if event.keyCode==125,let owner {owner.reveal(owner.document.source.count);return}
            if event.keyCode==126 {owner?.reveal(0);return}
        }
        super.keyDown(with:event)
    }
}

/// One retained Swift document tree. Navigation never reloads text or invents geometry.
final class SourceEditor:NSView,NSTextViewDelegate,NSTextStorageDelegate,ScrollSource {
    let scroll:NSScrollView=SourceScrollView()
    let canvas=FlippedView()
    let textView=SourceTextView(usingTextLayoutManager:false)
    unowned let document:MarkdownDocument
    private let prepared:PreparedDocument
    private var dirtyRange:NSRange?=NSRange(location:0,length:0)
    private var measuredWidth:CGFloat = -1
    var viewportChanged:((NSRange)->Void)?
    var scrollGestureChanged:((Bool)->Void)?
    var geometryChanged:(()->Void)?
    var scrollOverflow:((NSEvent)->Bool)?
    var navigationRequested:((Int)->Void)?
    private(set) var isScrolling=false
    private(set) var geometryRevision=0
    private var changingLayout=false,localEdit=false
    private var nativeLayoutRevision:Int?
    private var observations=[NSObjectProtocol]()
    var resizeSession:ViewportResizeSession?
    private var highlightedRanges=[NSRange]()
    private var highlightRevision = -1
    private var deferredHighlights=[(Int,[SyntaxSpan],NSRange)]()
    private var loadedRevision = -1
    private var initialStylesReady:Bool
    private struct MeasuredLine {
        let range:NSRange,rect:NSRect
    }
    #if DEBUG
    var debugResizeState:String {
        return "viewport=\(viewportOrigin), clipX=\(scroll.contentView.bounds.minX), textX=\(debugTextViewportX), resizeOrigin=\(String(describing:resizeSession?.sourceOrigin)), canvas=\(canvas.frame.height), visible=\(scroll.contentSize.height), measuredWidth=\(measuredWidth), frame=\(frame.size), scrollFrame=\(scroll.frame.size)"
    }
    var debugTextViewportX:CGFloat {
        textView.convert(NSPoint(x:textView.textContainerOrigin.x,y:0),to:scroll.contentView).x
    }
    var debugFirstLineViewportY:CGFloat {
        guard textView.string.count>0 else {
            let point=textView.convert(NSPoint(x:0,y:textView.textContainerOrigin.y),to:scroll.contentView)
            return point.y
        }
        let glyph=textView.layoutManager!.glyphIndexForCharacter(at:0)
        let line=textView.layoutManager!.lineFragmentUsedRect(forGlyphAt:glyph,effectiveRange:nil)
        return textView.convert(NSPoint(x:0,y:textView.textContainerOrigin.y+line.minY),to:scroll.contentView).y
    }
    #endif
    var contentRevision:Int {document.revision}
    var hasMeasuredLayout:Bool {(initialStylesReady || document.source.count==0) && nativeLayoutRevision==nil && !localEdit && !changingLayout && loadedRevision==document.revision}
    var viewportOrigin:CGFloat {scroll.contentView.bounds.minY}
    var contentHeight:CGFloat {canvas.bounds.height}
    var sourceLength:Int {document.source.count}
    var isResizePositionPinned:Bool {resizeSession?.protectsViewport == true}
    var selection:NSRange {textView.selectedRange()}
    var documentRange:NSRange {NSRange(location:0,length:document.source.count)}
    var viewportAnchor:Int {renderedViewportAnchor}
    var alignmentAnchor:Int {renderedOffset(atCanvasY:scroll.contentView.bounds.minY+alignmentOffset)}
    var editAnchor:Int {selection.location}
    var visibleSourceRange:NSRange {
        if !initialStylesReady {return NSRange(location:0,length:0)}
        let top=scroll.contentView.bounds.minY,bottom=top+scroll.contentSize.height
        let rope=document.source
        let start=renderedOffset(atCanvasY:top+2)
        let end=max(start,renderedOffset(atCanvasY:bottom-2))
        // Parsing/highlight coverage uses complete logical lines even though
        // the visual hit test can return a wrapped-line continuation. Logical
        // boundaries are also valid retained-layout replacement boundaries.
        let first=rope.line(at:start),last=min(rope.lineCount,rope.line(at:end)+1)
        return rope.lines(first,last)
    }
    var fontSize:CGFloat=13 {
        didSet {
            guard fontSize != oldValue else{return}
            endScrollGesture()
            dirtyRange=NSRange(location:0,length:prepared.sourceLayout.length)
            relayoutPreservingViewport {
                let storage=self.textView.textStorage!
                storage.beginEditing()
                storage.enumerateAttribute(.font,in:self.documentRange) {value,range,_ in
                    guard let font=value as? NSFont else{return}
                    storage.addAttribute(.font,value:NSFontManager.shared.convert(font,toSize:font.pointSize*self.fontSize/oldValue),range:range)
                }
                storage.endEditing()
            }
        }
    }
    init(document:MarkdownDocument,prepared:PreparedDocument = PreparedDocument(),deferInitialLayout:Bool=false) {
        self.document=document;self.prepared=prepared;initialStylesReady = !deferInitialLayout;super.init(frame:.zero)
        scroll.contentView=SourceClipView()
        scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=false;scroll.autohidesScrollers=true
        let verticalScroller=SourceScroller()
        verticalScroller.userWillScroll={ [weak self] in self?.prepareForUserInteraction() }
        scroll.verticalScroller=verticalScroller
        scroll.backgroundColor = .textBackgroundColor;scroll.documentView=canvas
        addSubview(scroll);canvas.addSubview(textView)
        textView.owner=self;textView.delegate=self;textView.textStorage!.delegate=self
        textView.isRichText=false;textView.allowsUndo=false
        textView.isAutomaticQuoteSubstitutionEnabled=false;textView.isAutomaticDashSubstitutionEnabled=false
        textView.isAutomaticTextReplacementEnabled=false;textView.isAutomaticSpellingCorrectionEnabled=false
        textView.isContinuousSpellCheckingEnabled=false
        textView.textContainerInset=NSSize(width:16,height:16)
        textView.isVerticallyResizable=false;textView.isHorizontallyResizable=false
        textView.textContainer!.widthTracksTextView=true;textView.textContainer!.heightTracksTextView=false
        // TextKit lays out exact geometry only where it is needed. The retained
        // layout tree carries an estimate for untouched regions and replaces it
        // with measured lines without changing the scrolling interfaces.
        textView.layoutManager!.allowsNonContiguousLayout=true
        textView.layoutManager!.backgroundLayoutEnabled=false
        textView.autoresizingMask=[];textView.backgroundColor = .textBackgroundColor
        textView.setAccessibilityLabel("Markdown source")
        scroll.contentView.postsBoundsChangedNotifications=true
        scroll.contentView.postsFrameChangedNotifications=true
        let sourceScroll=scroll as! SourceScrollView
        sourceScroll.userWillScroll={ [weak self] in self?.prepareForUserInteraction() }
        sourceScroll.consumeScroll={ [weak self] event in self?.scrollOverflow?(event) ?? false }
        let center=NotificationCenter.default
        observations.append(center.addObserver(forName:NSView.boundsDidChangeNotification,object:scroll.contentView,queue:.main) { [weak self] _ in self?.clipBoundsDidChange() })
        observations.append(center.addObserver(forName:NSView.frameDidChangeNotification,object:scroll.contentView,queue:.main) { [weak self] _ in self?.needsLayout=true })
        observations.append(center.addObserver(forName:NSScrollView.willStartLiveScrollNotification,object:scroll,queue:.main) { [weak self] _ in self?.beginScrollGesture() })
        observations.append(center.addObserver(forName:NSScrollView.didEndLiveScrollNotification,object:scroll,queue:.main) { [weak self] _ in self?.endScrollGesture() })
    }
    required init?(coder:NSCoder) {fatalError()}
    deinit {for observation in observations {NotificationCenter.default.removeObserver(observation)}}
    func captureResizeAnchor()->(offset:Int,displacement:CGFloat,origin:CGFloat) {
        let origin=scroll.contentView.bounds.minY
        let offset=renderedViewportAnchor
        let y=renderedVerticalPosition(for:offset) ?? origin
        traceResize("source.capture",anchorY:y)
        return (offset,origin-y,origin)
    }
    func beginResize(_ session:ViewportResizeSession) {
        resizeSession=session
        (scroll.contentView as? SourceClipView)?.resizeSession=session
        traceResize("source.begin")
    }
    func finishResizeLayout() {
        guard let session=resizeSession,session.protectsViewport else{return}
        layoutSubtreeIfNeeded()
        guard let y=renderedVerticalPosition(for:session.sourceOffset) else{return}
        traceResize("source.finish.before",anchorY:y)
        let origin=max(0,y+session.sourceDisplacement)
        session.sourceOrigin=origin
        canvas.frame.size.height=max(canvas.frame.height,origin+scroll.contentSize.height)
        let clip=scroll.contentView
        clip.scroll(to:NSPoint(x:clip.bounds.minX,y:origin))
        scroll.reflectScrolledClipView(clip)
        traceResize("source.finish.after",anchorY:y)
    }
    private func clearResizePin() {
        if resizeSession != nil {traceResize("source.clearPin")}
        resizeSession?.protectsViewport=false
        resizeSession=nil
        (scroll.contentView as? SourceClipView)?.resizeSession=nil
    }
    fileprivate func prepareForUserInteraction() {clearResizePin()}
    func beginScrollGesture() {
        guard !isScrolling else{return}
        isScrolling=true;scrollGestureChanged?(true)
    }
    func endScrollGesture() {
        guard isScrolling else{return}
        isScrolling=false;applyDeferredHighlights();scrollGestureChanged?(false)
    }
    override func setFrameSize(_ size:NSSize) {
        if size != frame.size {endScrollGesture()}
        super.setFrameSize(size);needsLayout=true
    }
    override func layout() {
        super.layout()
        // Updating the document's edited state can synchronously redraw its
        // window title inside a native character transaction. Defer geometry
        // until that transaction has closed, including pending pane resizing.
        guard nativeLayoutRevision==nil,!localEdit,!changingLayout else{return}
        let changed=scroll.frame.size != bounds.size || abs(canvas.frame.width-scroll.contentSize.width)>0.1
        guard changed || loadedRevision<0 else{return}
        traceResize("source.layout.begin")
        changingLayout=true
        let session=resizeSession?.protectsViewport == true ? resizeSession:nil
        if let session {canvas.frame.size.height=max(canvas.frame.height,session.sourceOrigin+bounds.height)}
        scroll.frame=bounds
        if loadedRevision<0 {reload(preserving:NSRange(location:0,length:0))}else{updateDimensions()}
        if let session,let y=renderedVerticalPosition(for:session.sourceOffset) {
            traceResize("source.layout.anchor",anchorY:y)
            session.sourceOrigin=max(0,y+session.sourceDisplacement)
            scroll.contentView.scroll(to:NSPoint(x:0,y:session.sourceOrigin))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        changingLayout=false;geometryChanged?();notifyViewport()
        traceResize("source.layout.end")
    }
    func traceResize(_ event:String,anchorY:CGFloat?=nil) {
        let clip=scroll.contentView.bounds
        let session=resizeSession
        ResizeTrace.record(event,"clip=\(clip.origin) clipSize=\(clip.size) pane=\(bounds.size) scroll=\(scroll.frame.size) canvas=\(canvas.frame.size) text=\(textView.frame) textInset=\(textView.textContainerOrigin) width=\(measuredWidth) anchorOffset=\(String(describing:session?.sourceOffset)) anchorY=\(String(describing:anchorY)) pinnedOrigin=\(String(describing:session?.sourceOrigin)) displacement=\(String(describing:session?.sourceDisplacement)) drag=\(String(describing:session?.isDragging)) protect=\(String(describing:session?.protectsViewport))")
    }
    private var baseAttributes:[NSAttributedString.Key:Any] {
        [.font:NSFont.monospacedSystemFont(ofSize:fontSize,weight:.regular),.foregroundColor:NSColor.textColor]
    }
    private func seedEstimatedLayout(width:CGFloat) {
        let rope=document.source
        guard rope.count>0 else {
            prepared.sourceLayout.replaceSuffix(at:0,with:[],origin:Double(textView.textContainerInset.height));return
        }
        let font=baseAttributes[.font] as! NSFont
        let lineHeight=ceil(textView.layoutManager!.defaultLineHeight(for:font))
        let characterWidth=max(1,("0" as NSString).size(withAttributes:[.font:font]).width)
        let columns=max(1,floor(width/characterWidth))
        // The larger of logical lines and packed character rows is a stable
        // whole-document estimate. Adding them would count every short line
        // twice and put TextKit's noncontiguous fragments far from the canvas.
        let visualLines=max(1,max(Double(rope.lineCount),Double(rope.count)/Double(columns)))
        prepared.sourceLayout.replaceSuffix(at:0,with:[LayoutIndex.Line(length:rope.count,advance:visualLines*lineHeight,height:lineHeight,estimated:true)],origin:Double(textView.textContainerInset.height))
    }
    /// Source syntax is deliberately paint-only. Changing font metrics here
    /// would invalidate wrapped-line geometry and turn coloring a viewport into
    /// a TextKit layout operation. The preview retains semantic typography.
    private func syntaxColor(_ kind:MarkdownKind)->NSColor? {
        if kind.isHeading {return .systemIndigo}
        if kind == .strongEmphasis || kind == .emphasis || kind == .strikethrough {return .systemOrange}
        if kind.isMark {return .secondaryLabelColor}
        if kind == .link || kind == .url {return .linkColor}
        if kind == .mathBlock || kind == .mathInline {return .systemPurple}
        return nil
    }
    private func updateDimensions() {
        #if DEBUG
        let work=TimingDiagnostics.shared.begin("source.layout")
        var timingValues=["documentCharacters":Double(document.source.count),"width":Double(scroll.contentSize.width)]
        defer {TimingDiagnostics.shared.end(work,values:timingValues)}
        #endif
        let width=max(1,scroll.contentSize.width-32)
        if abs(width-measuredWidth)>0.001 {
            if prepared.sourceLayout.hasEstimates(in:NSRange(location:0,length:prepared.sourceLayout.length)) {
                seedEstimatedLayout(width:width)
                let rope=document.source
                dirtyRange=rope.lines(0,min(rope.lineCount,80))
            } else {dirtyRange=NSRange(location:0,length:prepared.sourceLayout.length)}
            measuredWidth=width
        }
        guard let dirtyRange else {
            setCanvasSize(width:scroll.contentSize.width,
                naturalHeight:max(scroll.contentSize.height,textView.frame.maxY+32))
            return
        }
        guard initialStylesReady || document.source.count==0 else {
            textView.frame.size.width=max(1,scroll.contentSize.width)
            setCanvasSize(width:scroll.contentSize.width,naturalHeight:scroll.contentSize.height)
            return
        }
        geometryRevision += 1
        textView.typingAttributes=baseAttributes
        textView.frame.size.width=max(1,scroll.contentSize.width)
        textView.textContainer!.containerSize=NSSize(width:width,height:.greatestFiniteMagnitude)
        let manager=textView.layoutManager!,container=textView.textContainer!
        // Measure only affected paragraphs. The tree retains both sides, and
        // changes to source length/height shift its suffix through subtree sums.
        let replacingCompleteIndex=dirtyRange.location==0 && dirtyRange.length==prepared.sourceLayout.length
            && !prepared.sourceLayout.hasEstimates(in:dirtyRange)
        let boundary=dirtyRange.location
        let end=min(document.source.count,NSMaxRange(dirtyRange)+document.source.count-prepared.sourceLayout.length)
        let characters=NSRange(location:boundary,length:max(0,end-boundary))
        if replacingCompleteIndex {manager.ensureLayout(for:container)}
        else {manager.ensureLayout(forCharacterRange:characters)}
        let glyphs=manager.glyphRange(forCharacterRange:characters,actualCharacterRange:nil)
        var measured=[MeasuredLine]()
        manager.enumerateLineFragments(forGlyphRange:glyphs) {_,used,_,glyphs,_ in
            let characters=manager.characterRange(forGlyphRange:glyphs,actualGlyphRange:nil)
            if characters.length>0 {
                measured.append(MeasuredLine(range:characters,rect:used.offsetBy(dx:self.textView.textContainerInset.width,dy:self.textView.textContainerInset.height)))
            }
        }
        let followingY:CGFloat?
        if NSMaxRange(characters)<document.source.count {
            let followingGlyph=manager.glyphIndexForCharacter(at:NSMaxRange(characters))
            followingY=manager.lineFragmentUsedRect(forGlyphAt:followingGlyph,effectiveRange:nil).minY+textView.textContainerInset.height
        } else {followingY=nil}
        let lines=measured.enumerated().map {index,line in
            let next=index+1<measured.count ? measured[index+1].rect.minY:followingY ?? line.rect.maxY
            // AppKit can report overlapping character ranges for neighboring
            // fragments after a CRLF/Unicode edit followed by full reflow.
            // For a complete measurement, partition by successive line starts
            // so the index covers every UTF-16 unit exactly once.
            let length:Int
            if replacingCompleteIndex {
                let end=index+1<measured.count ? measured[index+1].range.location:document.source.count
                length=end-line.range.location
            } else {length=line.range.length}
            return LayoutIndex.Line(length:length,advance:Double(next-line.rect.minY),height:Double(line.rect.height))
        }
        prepared.sourceLayout.replace(dirtyRange,with:lines,origin:measured.first.map{Double($0.rect.minY)})
        if NSMaxRange(characters)==document.source.count,let last=measured.last {
            prepared.sourceLayout.fitEstimatedHeight(to:Double(last.rect.maxY))
        }
        self.dirtyRange=nil
        #if DEBUG
        timingValues["measuredLines"]=Double(lines.count)
        timingValues["retainedCharacters"]=Double(prepared.sourceLayout.length-lines.reduce(0){$0+$1.length})
        #endif
        let frameHeight:CGFloat
        if replacingCompleteIndex {
            let height=max(manager.usedRect(for:container).maxY,manager.extraLineFragmentRect.maxY)
            frameHeight=height+textView.textContainerInset.height*2+32
        } else {
            frameHeight=max(scroll.contentSize.height,CGFloat(prepared.sourceLayout.height)+textView.textContainerInset.height+32)
        }
        textView.frame=NSRect(x:0,y:0,width:scroll.contentSize.width,height:frameHeight)
        setCanvasSize(width:scroll.contentSize.width,
            naturalHeight:max(scroll.contentSize.height,textView.frame.maxY+32))
    }
    private func setCanvasSize(width:CGFloat,naturalHeight:CGFloat) {
        let pinnedBottom=resizeSession.flatMap{$0.protectsViewport ? $0.sourceOrigin+scroll.contentSize.height:nil} ?? 0
        canvas.frame.size=NSSize(width:width,height:max(naturalHeight,pinnedBottom))
    }
    func reload(preserving selection:NSRange) {
        guard !textView.hasMarkedText() else{return}
        let previousChanging=changingLayout;changingLayout=true
        if loadedRevision != document.revision {
            dirtyRange=NSRange(location:0,length:prepared.sourceLayout.length)
            #if DEBUG
            let materializeWork=TimingDiagnostics.shared.begin("source.text.materialize")
            #endif
            let text=document.takeInitialText(for:document.revision) ?? document.source.string
            #if DEBUG
            TimingDiagnostics.shared.end(materializeWork)
            let assignWork=TimingDiagnostics.shared.begin("source.text.assign")
            #endif
            textView.string=text
            #if DEBUG
            TimingDiagnostics.shared.end(assignWork)
            let attributesWork=TimingDiagnostics.shared.begin("source.text.attributes")
            #endif
            textView.textStorage!.setAttributes(baseAttributes,range:documentRange)
            #if DEBUG
            TimingDiagnostics.shared.end(attributesWork)
            #endif
            highlightedRanges.removeAll();deferredHighlights.removeAll();highlightRevision=document.revision
        }
        loadedRevision=document.revision
        precondition(selection.location>=0 && NSMaxRange(selection)<=document.source.count)
        textView.setSelectedRange(selection)
        updateDimensions();changingLayout=previousChanging
    }
    private func invalidateLayout(in range:NSRange) {
        let rope=document.source,index=prepared.sourceLayout
        let start=rope.lineStart(max(0,rope.line(at:range.location)-1))
        let lastLine=rope.line(at:min(rope.count,NSMaxRange(range)))+2
        let end=lastLine>=rope.lineCount ? rope.count:rope.lineStart(lastLine)
        // Pending character transactions use current source coordinates; the
        // retained layout still uses the previous revision's coordinates.
        let delta=rope.count-index.length
        func oldPosition(_ offset:Int,end:Bool)->Int {
            guard let dirty=dirtyRange,delta != 0 else{return min(offset,index.length)}
            if offset<=dirty.location {return offset}
            if offset>=NSMaxRange(dirty)+delta {return offset-delta}
            return end ? NSMaxRange(dirty):dirty.location
        }
        let a=max(0,min(index.length,oldPosition(start,end:false)))
        let b=max(a,min(index.length,oldPosition(end,end:true)))
        let first=index.position(at:a)?.range.location ?? a
        let last=b<index.length ? index.position(at:b).map{NSMaxRange($0.range)} ?? b:b
        let affected=NSRange(location:first,length:last-first)
        dirtyRange=dirtyRange.map{NSUnionRange($0,affected)} ?? affected
    }
    private func offset(atCanvasY y:CGFloat,endOfLine:Bool=false)->Int {
        guard let line=prepared.sourceLayout.position(atY:Double(y)) else{return document.source.count}
        return endOfLine ? NSMaxRange(line.range):line.range.location
    }
    private func rect(for offset:Int)->NSRect? {
        guard let line=prepared.sourceLayout.position(at:offset) else{return nil}
        return NSRect(x:textView.textContainerInset.width,y:line.y,width:1,height:line.height)
    }
    private func renderedOffset(atCanvasY canvasY:CGFloat)->Int {
        guard document.source.count>0 else{return 0}
        guard let manager=textView.layoutManager,let container=textView.textContainer else{return 0}
        guard (textView.textStorage?.length ?? 0)>0 else{return 0}
        // Work in the text-container coordinate system. NSTextView's insertion
        // hit test can resolve an inset point against a nearby laid fragment,
        // which is not necessarily the line painted at the clip edge when
        // noncontiguous layout is enabled. TextKit's glyph hit test identifies
        // that visual line directly, including a wrapped continuation line.
        let local=textView.convert(NSPoint(x:0,y:canvasY),from:canvas)
        let point=NSPoint(x:1,y:max(0,local.y-textView.textContainerOrigin.y))
        let glyph=manager.glyphIndex(for:point,in:container)
        var lineGlyphs=NSRange()
        manager.lineFragmentUsedRect(forGlyphAt:glyph,effectiveRange:&lineGlyphs)
        return min(document.source.count,manager.characterIndexForGlyph(at:lineGlyphs.location))
    }
    private var renderedViewportAnchor:Int {renderedOffset(atCanvasY:scroll.contentView.bounds.minY+3)}
    private func renderedVerticalPosition(for offset:Int)->CGFloat? {
        if offset==document.source.count {return canvas.bounds.height}
        guard document.source.count>0 else{return nil}
        let character=min(max(0,offset),document.source.count-1)
        guard let manager=textView.layoutManager else{return nil}
        manager.ensureLayout(forCharacterRange:NSRange(location:character,length:1))
        let glyph=manager.glyphIndexForCharacter(at:character)
        let line=manager.lineFragmentUsedRect(forGlyphAt:glyph,effectiveRange:nil)
        let local=NSPoint(x:textView.textContainerOrigin.x,y:textView.textContainerOrigin.y+line.minY)
        return textView.convert(local,to:canvas).y
    }
    private func refineLayout(around requested:NSRange) {
        let rope=document.source,index=prepared.sourceLayout
        guard requested.length>0,index.hasEstimates(in:requested),nativeLayoutRevision==nil,!localEdit else{return}
        let first=max(0,rope.line(at:requested.location)-12)
        let last=min(rope.lineCount,rope.line(at:NSMaxRange(requested))+80)
        let range=rope.lines(first,last)
        guard range.length>0,index.hasEstimates(in:range) else{return}
        // Exact viewport coverage is expressed in source/logical-line bounds.
        // Expand it to the retained tree's current visual-line boundaries
        // before replacement; a wrapped measured line cannot be split.
        let boundary=index.position(at:range.location)?.range.location ?? range.location
        let rangeEnd=NSMaxRange(range)
        let boundaryEnd=rangeEnd<index.length
            ? index.position(at:rangeEnd).map{NSMaxRange($0.range)} ?? rangeEnd
            : index.length
        let affected=NSRange(location:boundary,length:max(0,boundaryEnd-boundary))
        let currentAnchor=renderedViewportAnchor
        let session=resizeSession?.protectsViewport == true ? resizeSession:nil
        let anchor=session?.sourceOffset ?? currentAnchor
        let displacement=session?.sourceDisplacement ??
            scroll.contentView.bounds.minY-(renderedVerticalPosition(for:currentAnchor) ?? scroll.contentView.bounds.minY)
        changingLayout=true;dirtyRange=affected;updateDimensions()
        let restoredY=renderedVerticalPosition(for:anchor)
        if let y=restoredY {
            let origin=max(0,y+displacement)
            session?.sourceOrigin=origin
            scroll.contentView.scroll(to:NSPoint(x:0,y:origin))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        changingLayout=false;geometryChanged?()
    }
    func verticalPosition(for offset:Int)->CGFloat? {
        // EOF has no glyph. Its coordinate is the explicit document boundary.
        if offset==document.source.count {return canvas.bounds.height}
        return rect(for:offset)?.minY
    }
    func alignmentVerticalPosition(for offset:Int)->CGFloat? {renderedVerticalPosition(for:offset)}
    #if DEBUG
    func debugMeasuredPosition(for offset:Int)->CGFloat {
        guard let y=verticalPosition(for:offset) else{preconditionFailure("Missing native position at \(offset)")}
        return y
    }
    func debugAlignViewport(at offset:Int,viewportY:CGFloat) {
        clearResizePin()
        let position=min(max(0,offset),document.source.count)
        refineLayout(around:NSRange(location:position,length:max(1,min(1024,document.source.count-position))))
        guard let y=renderedVerticalPosition(for:position) else{preconditionFailure("Missing native resize anchor")}
        changingLayout=true
        scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,y-viewportY)))
        scroll.reflectScrolledClipView(scroll.contentView)
        changingLayout=false;notifyViewport()
    }
    func debugScrollViewport(by delta:CGFloat) {
        clearResizePin()
        changingLayout=true
        let end=max(0,canvas.bounds.height-scroll.contentSize.height)
        let origin=min(end,max(0,scroll.contentView.bounds.minY+delta))
        scroll.contentView.scroll(to:NSPoint(x:0,y:origin))
        scroll.reflectScrolledClipView(scroll.contentView)
        changingLayout=false;notifyViewport()
    }
    func debugClickInsertionPoint(at offset:Int) {
        let position=min(max(0,offset),document.source.count)
        prepareForUserInteraction()
        textView.setSelectedRange(NSRange(location:position,length:0))
        textView.scrollRangeToVisible(NSRange(location:position,length:0))
    }
    func debugRenderedOffset(atViewportY y:CGFloat)->Int {
        renderedOffset(atCanvasY:scroll.contentView.bounds.minY+y)
    }
    var debugPinnedViewportIsRepresentable:Bool {
        guard let session=resizeSession,session.protectsViewport else{return true}
        let origin=session.sourceOrigin
        return canvas.bounds.height+0.01>=origin+scroll.contentSize.height
    }
    func debugApplyNaturalCanvasHeight(_ height:CGFloat) {
        setCanvasSize(width:scroll.contentSize.width,naturalHeight:height)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    func debugViewportY(for offset:Int)->CGFloat? {
        verticalPosition(for:offset).map{$0-scroll.contentView.bounds.minY}
    }
    func debugRenderedViewportY(for offset:Int)->CGFloat? {
        renderedVerticalPosition(for:offset).map{$0-scroll.contentView.bounds.minY}
    }
    var debugRenderedViewportAnchor:Int {renderedViewportAnchor}
    func debugRelayoutVisibleViewport() {
        dirtyRange=visibleSourceRange
        relayoutPreservingViewport {}
    }
    func debugLineHeight(for offset:Int)->CGFloat? {rect(for:offset)?.height}
    #endif
    var alignmentOffset:CGFloat {
        CGFloat(ScrollLandmarks.alignmentOffset(at:Double(scroll.contentView.bounds.minY),sourceHeight:Double(canvas.bounds.height),viewportHeight:Double(scroll.contentSize.height)))
    }
    private func relayoutPreservingViewport(_ change:()->Void) {
        let anchor=renderedViewportAnchor,oldOrigin=scroll.contentView.bounds.minY
        let oldPosition=renderedVerticalPosition(for:anchor)
        changingLayout=true;change();updateDimensions()
        if let session=resizeSession,session.protectsViewport,
           let y=renderedVerticalPosition(for:session.sourceOffset) {
            let origin=max(0,y+session.sourceDisplacement)
            session.sourceOrigin=origin
            scroll.contentView.scroll(to:NSPoint(x:0,y:origin))
        } else if oldOrigin<=0.001 {scroll.contentView.scroll(to:.zero)}
        else if let before=oldPosition,let after=renderedVerticalPosition(for:anchor) {scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,after+oldOrigin-before)))}
        scroll.reflectScrolledClipView(scroll.contentView)
        changingLayout=false;geometryChanged?();notifyViewport()
    }
    func documentEdited(selection:NSRange,edit:SourceEdit) {
        // Any document edit starts a new center-synchronized positioning
        // event. Resize pinning lasts through resize completion and queued
        // resize layout only; it must not survive into an edit.
        clearResizePin()
        highlightRevision=document.revision;deferredHighlights.removeAll()
        let delta=edit.insertedLength-edit.range.length,end=NSMaxRange(edit.range)
        highlightedRanges=highlightedRanges.flatMap {range -> [NSRange] in
            if NSMaxRange(range)<=edit.range.location {return [range]}
            if range.location>=end {return [NSRange(location:range.location+delta,length:range.length)]}
            var retained=[NSRange]()
            if range.location<edit.range.location {retained.append(NSRange(location:range.location,length:edit.range.location-range.location))}
            if NSMaxRange(range)>end {retained.append(NSRange(location:end+delta,length:NSMaxRange(range)-end))}
            return retained
        }
        if localEdit {loadedRevision=document.revision}
        else {
            // Undo and model-driven replacements edit the retained native text,
            // just like typing. Reloading it would discard all cached typography.
            let old=textView.string as NSString
            let paragraph=old.paragraphRange(for:edit.range)
            let start=max(0,paragraph.location-1),end=min(old.length,NSMaxRange(paragraph)+1)
            let affected=old.paragraphRange(for:NSRange(location:start,length:end-start))
            if old.length==prepared.sourceLayout.length {dirtyRange=dirtyRange.map{NSUnionRange($0,affected)} ?? affected}
            else {dirtyRange=NSRange(location:0,length:prepared.sourceLayout.length)}
            nativeLayoutRevision=nil;changingLayout=true
            let replacement=document.source.string(in:NSRange(location:edit.range.location,length:edit.insertedLength))
            textView.textStorage!.replaceCharacters(in:edit.range,with:replacement)
            loadedRevision=document.revision;textView.setSelectedRange(selection)
            updateDimensions();changingLayout=false
            geometryChanged?();reveal(selection.location)
            textView.setSelectedRange(selection);notifyViewport()
        }
    }
    func reconcilePreparedHighlights() {
        let applied=highlightedRanges
        highlightedRanges.removeAll(keepingCapacity:true)
        let valid=prepared.styleCoverage
        var cursor=0
        for range in applied {
            while cursor<valid.count,NSMaxRange(valid[cursor])<=range.location {cursor += 1}
            var i=cursor
            while i<valid.count,valid[i].location<NSMaxRange(range) {
                let overlap=NSIntersectionRange(range,valid[i])
                if overlap.length>0 {recordHighlightCoverage(overlap)}
                i += 1
            }
        }
    }
    func reveal(_ offset:Int,alignTop:Bool=false) {
        clearResizePin()
        endScrollGesture()
        let position=min(max(0,offset),document.source.count)
        if position<document.source.count {
            refineLayout(around:NSRange(location:position,length:max(1,min(1024,document.source.count-position))))
        } else if position>0 {
            refineLayout(around:NSRange(location:max(0,position-1024),length:min(1024,position)))
        }
        if !alignTop {textView.setSelectedRange(NSRange(location:position,length:0))}
        changingLayout=true
        if position==0 {scroll.contentView.scroll(to:.zero)}
        else if position==document.source.count {scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,canvas.bounds.height-scroll.contentSize.height)))}
        else if let y=renderedVerticalPosition(for:position) {
            let target=NSRect(x:textView.textContainerInset.width,y:y,width:1,height:1)
            if alignTop {scroll.contentView.scroll(to:NSPoint(x:0,y:y))}
            else {canvas.scrollToVisible(target.insetBy(dx:0,dy:-30))}
        }
        scroll.reflectScrolledClipView(scroll.contentView);changingLayout=false
        navigationRequested?(position)
        notifyViewport()
    }
    override func scrollWheel(with event:NSEvent) {scroll.scrollWheel(with:event)}
    private func clipBoundsDidChange() {
        guard let clip=scroll.contentView as? SourceClipView,
              let session=resizeSession,session.protectsViewport,
              abs(clip.bounds.minY-session.sourceOrigin)>0.5 else {
            notifyViewport();return
        }
        traceResize("source.clipDrift")
        clip.setBoundsOrigin(NSPoint(x:clip.bounds.minX,y:session.sourceOrigin))
        scroll.reflectScrolledClipView(clip)
        notifyViewport()
    }
    private func notifyViewport() {
        guard !changingLayout,!localEdit,nativeLayoutRevision==nil else{return}
        refineLayout(around:visibleSourceRange)
        // NSClipView minimizes invalidation when its origin changes. That is
        // normally desirable, but a simultaneous TextKit reflow means copied
        // rows no longer describe the geometry now under the clip. Explicitly
        // repaint only the visible source rectangle so the displayed top and
        // the anchor used for resize synchronization cannot diverge.
        let visible=textView.convert(scroll.contentView.bounds,from:canvas)
        textView.setNeedsDisplay(visible)
        viewportChanged?(visibleSourceRange)
    }
    func textView(_ textView:NSTextView,shouldChangeTextIn range:NSRange,replacementString:String?)->Bool {
        // Mark geometry unavailable before AppKit begins its character batch.
        if !changingLayout {nativeLayoutRevision=document.revision}
        return true
    }
    func textStorage(_ storage:NSTextStorage,didProcessEditing mask:NSTextStorageEditActions,range editedRange:NSRange,changeInLength delta:Int) {
        guard !changingLayout,mask.contains(.editedCharacters) else{return}
        // An edit is a new synchronization event, not continuation of a resize.
        clearResizePin()
        // Observe actual native character transactions, including provisional
        // marked text. Delegate proposals can refer to an uncommitted IME range
        // and are not a reliable edit against the document model.
        precondition(document.source.count==storage.length-delta)
        let original=NSRange(location:editedRange.location,length:editedRange.length-delta)
        let replacement=(storage.string as NSString).substring(with:editedRange)
        nativeLayoutRevision=document.revision+1
        invalidateLayout(in:original)
        localEdit=true;document.replace(original,with:replacement);localEdit=false
        DispatchQueue.main.async { [weak self] in self?.finishNativeLayout()}
    }
    private func finishNativeLayout() {
        guard let revision=nativeLayoutRevision,revision==document.revision,!changingLayout else{return}
        changingLayout=true;scroll.frame=bounds;updateDimensions();changingLayout=false
        nativeLayoutRevision=nil
        needsLayout=true
        geometryChanged?();notifyViewport();applyDeferredHighlights()
    }
    func textViewDidChangeSelection(_ notification:Notification) {
        // AppKit can announce selection inside a still-open native text batch.
        DispatchQueue.main.async { [weak self] in self?.notifyViewport() }
    }
    func hasAppliedHighlights(in range:NSRange)->Bool {
        highlightRevision==document.revision && highlightedRanges.contains{ $0.location<=range.location && NSMaxRange($0)>=NSMaxRange(range) }
    }
    /// Only uncovered native attributes need applying after a prepared revision.
    func unappliedHighlightRanges(in requested:NSRange)->[NSRange] {
        let range=NSIntersectionRange(documentRange,requested)
        guard range.length>0 else{return []}
        guard highlightRevision==document.revision else{return [range]}
        var cursor=range.location,result=[NSRange]()
        for covered in highlightedRanges {
            if NSMaxRange(covered)<=cursor {continue}
            if covered.location>=NSMaxRange(range) {break}
            if covered.location>cursor {result.append(NSRange(location:cursor,length:covered.location-cursor))}
            cursor=max(cursor,min(NSMaxRange(range),NSMaxRange(covered)))
        }
        if cursor<NSMaxRange(range) {result.append(NSRange(location:cursor,length:NSMaxRange(range)-cursor))}
        return result
    }
    private func recordHighlightCoverage(_ range:NSRange) {
        var union=range,result=[NSRange]()
        for existing in highlightedRanges {
            if NSMaxRange(existing)<union.location || existing.location>NSMaxRange(union) {result.append(existing)}
            else {union=NSUnionRange(union,existing)}
        }
        result.append(union);highlightedRanges=result.sorted{$0.location<$1.location}
    }
    private func applyDeferredHighlights() {
        guard !isScrolling,!localEdit,!textView.hasMarkedText(),nativeLayoutRevision==nil else{return}
        let pending=deferredHighlights;deferredHighlights.removeAll()
        applyHighlightBatch(pending.filter{$0.0==document.revision}.map{($0.1,$0.2)})
    }
    var isAwaitingInitialHighlights:Bool {!initialStylesReady}
    func applyInitialHighlights(_ spans:[SyntaxSpan],in range:NSRange) {
        initialStylesReady=true
        applyHighlightBatch([(spans,range)])
        let width=max(1,scroll.contentSize.width-32)
        seedEstimatedLayout(width:width)
        let rope=document.source
        // A fixed number of logical lines bounds first-view work while covering
        // several screens. Exact lines replace the estimate in the same tree.
        dirtyRange=rope.lines(0,min(rope.lineCount,80))
        relayoutPreservingViewport {}
    }
    func applyHighlights(_ spans:[SyntaxSpan],in requestedRange:NSRange) {
        // Syntax colors are temporary layout-manager attributes and cannot
        // change glyph metrics. Apply them while scrolling so the newly visible
        // source does not remain unpainted until the gesture ends. Native text
        // transactions still defer them because their coordinates are unstable.
        if textView.hasMarkedText() || nativeLayoutRevision != nil {
            deferredHighlights.append((document.revision,spans,requestedRange));return
        }
        applyHighlightBatch([(spans,requestedRange)])
    }
    private func applyHighlightBatch(_ batches:[([SyntaxSpan],NSRange)]) {
        var changes=[([SyntaxSpan],NSRange)]()
        for (spans,range) in batches {
            // An edit cuts only its replaced interval out of highlightCoverage.
            // Keep the attributes on both retained sides and apply Comrak's
            // result only to the resulting gap. Reapplying the whole visible
            // margin invalidates TextKit's otherwise-retained suffix layout.
            for covered in unappliedHighlightRanges(in:range) {
                recordHighlightCoverage(covered)
                changes.append((spans,covered))
            }
        }
        guard !changes.isEmpty else{return}
        #if DEBUG
        let work=TimingDiagnostics.shared.begin("source.highlight")
        defer {TimingDiagnostics.shared.end(work,values:["spans":Double(changes.reduce(0){$0+$1.0.count}),"batches":Double(changes.count)])}
        #endif
        // Temporary layout-manager attributes are paint annotations. Unlike
        // NSTextStorage attribute edits, they never invalidate glyph metrics.
        let manager=textView.layoutManager!
        for (spans,covered) in changes {
            manager.removeTemporaryAttribute(.foregroundColor,forCharacterRange:covered)
            for span in spans {
                let range=NSIntersectionRange(covered,span.range)
                guard range.length>0,let color=syntaxColor(span.kind) else{continue}
                manager.addTemporaryAttribute(.foregroundColor,value:color,forCharacterRange:range)
            }
        }
        textView.needsDisplay=true
    }
}
