import AppKit
import MarkdownCore

final class FlippedView:NSView {override var isFlipped:Bool {true}}
private final class SourceScrollView:NSScrollView {
    override class var isCompatibleWithResponsiveScrolling:Bool {true}
    var consumeScroll:((NSEvent)->Bool)?
    override func scrollWheel(with event:NSEvent) {
        if consumeScroll?(event) != true {super.scrollWheel(with:event)}
    }
}
final class SourceTextView:NSTextView {
    weak var owner:SourceEditor?
    override func insertText(_ insertString:Any,replacementRange:NSRange) {
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
        if event.modifierFlags.contains(.command),!event.modifierFlags.contains(.shift) {
            if event.keyCode==125,let owner {owner.reveal(owner.document.source.count);return}
            if event.keyCode==126 {owner?.reveal(0);return}
        }
        super.keyDown(with:event)
    }
}

/// One retained native document. Navigation never reloads text or invents geometry.
final class SourceEditor:NSView,NSTextViewDelegate,NSTextStorageDelegate,ScrollSource {
    let scroll:NSScrollView=SourceScrollView()
    let canvas=FlippedView()
    let textView=SourceTextView(usingTextLayoutManager:false)
    unowned let document:MarkdownDocument
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
    private var resizeAnchor:(Int,CGFloat)?
    private var highlightedRanges=[NSRange]()
    private var highlightRevision = -1
    private var deferredHighlights=[(Int,[SyntaxSpan],NSRange)]()
    private var loadedRevision = -1
    private struct MeasuredLine {
        let range:NSRange,rect:NSRect
    }
    private var measuredLines=[MeasuredLine]()
    #if DEBUG
    private(set) var highlightApplications=0
    #endif
    var contentRevision:Int {document.revision}
    var hasMeasuredLayout:Bool {nativeLayoutRevision==nil && !localEdit && !changingLayout && loadedRevision==document.revision}
    var viewportOrigin:CGFloat {scroll.contentView.bounds.minY}
    var contentHeight:CGFloat {canvas.bounds.height}
    var sourceLength:Int {document.source.count}
    var selection:NSRange {textView.selectedRange()}
    var documentRange:NSRange {NSRange(location:0,length:document.source.count)}
    var viewportAnchor:Int {offset(atCanvasY:scroll.contentView.bounds.minY+3)}
    var alignmentAnchor:Int {offset(atCanvasY:scroll.contentView.bounds.minY+alignmentOffset)}
    var visibleSourceRange:NSRange {
        let top=scroll.contentView.bounds.minY,bottom=top+scroll.contentSize.height
        let start=offset(atCanvasY:top+2),end=max(start,offset(atCanvasY:bottom-2,endOfLine:true))
        return NSRange(location:start,length:end-start)
    }
    var fontSize:CGFloat=13 {
        didSet {
            guard fontSize != oldValue else{return}
            endScrollGesture()
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
    init(document:MarkdownDocument) {
        self.document=document;super.init(frame:.zero)
        scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true
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
        // This editor prepares a complete, contiguous native layout. Scrolling
        // only exposes its glyphs; no viewport layout can replace its geometry.
        textView.layoutManager!.allowsNonContiguousLayout=false
        textView.layoutManager!.backgroundLayoutEnabled=false
        textView.autoresizingMask=[];textView.backgroundColor = .textBackgroundColor
        textView.setAccessibilityLabel("Markdown source")
        scroll.contentView.postsBoundsChangedNotifications=true
        (scroll as! SourceScrollView).consumeScroll={ [weak self] event in self?.scrollOverflow?(event) ?? false }
        let center=NotificationCenter.default
        observations.append(center.addObserver(forName:NSView.boundsDidChangeNotification,object:scroll.contentView,queue:.main) { [weak self] _ in self?.notifyViewport() })
        observations.append(center.addObserver(forName:NSScrollView.willStartLiveScrollNotification,object:scroll,queue:.main) { [weak self] _ in self?.beginScrollGesture() })
        observations.append(center.addObserver(forName:NSScrollView.didEndLiveScrollNotification,object:scroll,queue:.main) { [weak self] _ in self?.endScrollGesture() })
    }
    required init?(coder:NSCoder) {fatalError()}
    deinit {for observation in observations {NotificationCenter.default.removeObserver(observation)}}
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
        if loadedRevision>=0,nativeLayoutRevision==nil,abs(size.width-frame.width)>0.5,resizeAnchor==nil,let y=verticalPosition(for:viewportAnchor) {
            resizeAnchor=(viewportAnchor,scroll.contentView.bounds.minY-y)
        }
        super.setFrameSize(size);needsLayout=true
    }
    override func layout() {
        super.layout()
        // Updating the document's edited state can synchronously redraw its
        // window title inside a native character transaction. Defer geometry
        // until that transaction has closed, including pending pane resizing.
        guard nativeLayoutRevision==nil,!localEdit,!changingLayout else{return}
        let changed=scroll.frame.size != bounds.size
        guard changed || loadedRevision<0 else{return}
        changingLayout=true
        let anchor=resizeAnchor;resizeAnchor=nil
        scroll.frame=bounds
        if loadedRevision<0 {reload(preserving:NSRange(location:0,length:0))}else{updateDimensions()}
        if let (offset,displacement)=anchor,let y=verticalPosition(for:offset) {
            scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,y+displacement)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        changingLayout=false;geometryChanged?();notifyViewport()
    }
    private var baseAttributes:[NSAttributedString.Key:Any] {
        [.font:NSFont.monospacedSystemFont(ofSize:fontSize,weight:.regular),.foregroundColor:NSColor.textColor]
    }
    private func updateDimensions() {
        #if DEBUG
        let work=TimingDiagnostics.shared.begin("source.layout")
        defer {TimingDiagnostics.shared.end(work,values:["documentCharacters":Double(document.source.count),"width":Double(scroll.contentSize.width)])}
        #endif
        geometryRevision += 1
        textView.typingAttributes=baseAttributes
        textView.frame.size.width=max(1,scroll.contentSize.width)
        textView.textContainer!.containerSize=NSSize(width:max(1,scroll.contentSize.width-32),height:.greatestFiniteMagnitude)
        let manager=textView.layoutManager!,container=textView.textContainer!
        manager.ensureLayout(for:container)
        measuredLines.removeAll(keepingCapacity:true)
        manager.enumerateLineFragments(forGlyphRange:manager.glyphRange(for:container)) {_,used,_,glyphs,_ in
            let characters=manager.characterRange(forGlyphRange:glyphs,actualGlyphRange:nil)
            self.measuredLines.append(MeasuredLine(range:characters,rect:used.offsetBy(dx:self.textView.textContainerInset.width,dy:self.textView.textContainerInset.height)))
        }
        let height=max(manager.usedRect(for:container).maxY,manager.extraLineFragmentRect.maxY)
        textView.frame=NSRect(x:0,y:0,width:scroll.contentSize.width,height:height+textView.textContainerInset.height*2+32)
        canvas.frame.size=NSSize(width:scroll.contentSize.width,height:max(scroll.contentSize.height,textView.frame.maxY+32))
    }
    func reload(preserving selection:NSRange) {
        guard !textView.hasMarkedText() else{return}
        let previousChanging=changingLayout;changingLayout=true
        if loadedRevision != document.revision {
            textView.string=document.source.string
            textView.textStorage!.setAttributes(baseAttributes,range:documentRange)
            highlightedRanges.removeAll();deferredHighlights.removeAll();highlightRevision=document.revision
        }
        loadedRevision=document.revision
        precondition(selection.location>=0 && NSMaxRange(selection)<=document.source.count)
        textView.setSelectedRange(selection)
        updateDimensions();changingLayout=previousChanging
    }
    private func offset(atCanvasY y:CGFloat,endOfLine:Bool=false)->Int {
        var low=0,high=measuredLines.count
        while low<high {
            let middle=(low+high)/2
            if measuredLines[middle].rect.maxY<=y {low=middle+1}else{high=middle}
        }
        guard low<measuredLines.count else{return document.source.count}
        let range=measuredLines[low].range
        return endOfLine ? NSMaxRange(range):range.location
    }
    private func rect(for offset:Int)->NSRect? {
        guard offset>=0,offset<document.source.count else{return nil}
        var low=0,high=measuredLines.count
        while low<high {
            let middle=(low+high)/2
            if NSMaxRange(measuredLines[middle].range)<=offset {low=middle+1}else{high=middle}
        }
        guard low<measuredLines.count,NSLocationInRange(offset,measuredLines[low].range) else{return nil}
        let rect=measuredLines[low].rect
        return NSRect(x:textView.textContainerInset.width,y:rect.minY,width:1,height:rect.height)
    }
    func verticalPosition(for offset:Int)->CGFloat? {
        // EOF has no glyph. Its coordinate is the explicit document boundary.
        if offset==document.source.count {return canvas.bounds.height}
        return rect(for:offset)?.minY
    }
    #if DEBUG
    func debugMeasuredPosition(for offset:Int)->CGFloat {
        guard let y=verticalPosition(for:offset) else{preconditionFailure("Missing native position at \(offset)")}
        return y
    }
    #endif
    var alignmentOffset:CGFloat {
        CGFloat(ScrollLandmarks.alignmentOffset(at:Double(scroll.contentView.bounds.minY),sourceHeight:Double(canvas.bounds.height),viewportHeight:Double(scroll.contentSize.height)))
    }
    private func relayoutPreservingViewport(_ change:()->Void) {
        let anchor=viewportAnchor,oldOrigin=scroll.contentView.bounds.minY,oldPosition=verticalPosition(for:anchor)
        changingLayout=true;change();updateDimensions()
        if oldOrigin<=0.001 {scroll.contentView.scroll(to:.zero)}
        else if let before=oldPosition,let after=verticalPosition(for:anchor) {scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,after+oldOrigin-before)))}
        scroll.reflectScrolledClipView(scroll.contentView)
        changingLayout=false;geometryChanged?();notifyViewport()
    }
    func documentEdited(selection:NSRange) {
        highlightRevision=document.revision;highlightedRanges.removeAll();deferredHighlights.removeAll()
        if localEdit {loadedRevision=document.revision}
        else {nativeLayoutRevision=nil;reload(preserving:selection);reveal(selection.location);textView.setSelectedRange(selection);notifyViewport()}
    }
    func reveal(_ offset:Int,alignTop:Bool=false) {
        endScrollGesture()
        let position=min(max(0,offset),document.source.count)
        if !alignTop {textView.setSelectedRange(NSRange(location:position,length:0))}
        changingLayout=true
        if position==0 {scroll.contentView.scroll(to:.zero)}
        else if position==document.source.count {
            scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,canvas.bounds.height-scroll.contentSize.height)))
        } else if let target=rect(for:position) {
            if alignTop {scroll.contentView.scroll(to:NSPoint(x:0,y:target.minY))}
            else {canvas.scrollToVisible(target.insetBy(dx:0,dy:-30))}
        }
        scroll.reflectScrolledClipView(scroll.contentView);changingLayout=false
        navigationRequested?(position)
        notifyViewport()
    }
    override func scrollWheel(with event:NSEvent) {scroll.scrollWheel(with:event)}
    private func notifyViewport() {
        guard !changingLayout,!localEdit,nativeLayoutRevision==nil else{return}
        viewportChanged?(visibleSourceRange)
    }
    func textView(_ textView:NSTextView,shouldChangeTextIn range:NSRange,replacementString:String?)->Bool {
        // Mark geometry unavailable before AppKit begins its character batch.
        if !changingLayout {nativeLayoutRevision=document.revision}
        return true
    }
    func textStorage(_ storage:NSTextStorage,didProcessEditing mask:NSTextStorageEditActions,range editedRange:NSRange,changeInLength delta:Int) {
        guard !changingLayout,mask.contains(.editedCharacters) else{return}
        // Observe actual native character transactions, including provisional
        // marked text. Delegate proposals can refer to an uncommitted IME range
        // and are not a reliable edit against the document model.
        precondition(document.source.count==storage.length-delta)
        let original=NSRange(location:editedRange.location,length:editedRange.length-delta)
        let replacement=(storage.string as NSString).substring(with:editedRange)
        nativeLayoutRevision=document.revision+1
        localEdit=true;document.replace(original,with:replacement);localEdit=false
        DispatchQueue.main.async { [weak self] in self?.finishNativeLayout()}
    }
    private func finishNativeLayout() {
        guard let revision=nativeLayoutRevision,revision==document.revision,!changingLayout else{return}
        changingLayout=true;scroll.frame=bounds;updateDimensions();changingLayout=false
        nativeLayoutRevision=nil
        resizeAnchor=nil;needsLayout=true
        geometryChanged?();notifyViewport();applyDeferredHighlights()
    }
    func textViewDidChangeSelection(_ notification:Notification) {
        // AppKit can announce selection inside a still-open native text batch.
        DispatchQueue.main.async { [weak self] in self?.notifyViewport() }
    }
    func hasAppliedHighlights(in range:NSRange)->Bool {
        highlightRevision==document.revision && highlightedRanges.contains{ $0.location<=range.location && NSMaxRange($0)>=NSMaxRange(range) }
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
        guard !isScrolling,!localEdit,!textView.hasMarkedText() else{return}
        let pending=deferredHighlights;deferredHighlights.removeAll()
        for (revision,spans,range) in pending where revision==document.revision {applyHighlights(spans,in:range)}
    }
    func applyHighlights(_ spans:[SyntaxSpan],in requestedRange:NSRange) {
        let covered=NSIntersectionRange(documentRange,spans.reduce(requestedRange){NSUnionRange($0,$1.range)})
        guard covered.length>0,!hasAppliedHighlights(in:covered) else{return}
        if isScrolling || textView.hasMarkedText() {deferredHighlights.append((document.revision,spans,requestedRange));return}
        #if DEBUG
        highlightApplications += 1
        let work=TimingDiagnostics.shared.begin("source.highlight")
        defer {TimingDiagnostics.shared.end(work,values:["spans":Double(spans.count)])}
        #endif
        relayoutPreservingViewport {
            let storage=self.textView.textStorage!
            storage.beginEditing();storage.setAttributes(self.baseAttributes,range:covered)
            for span in spans {
                let range=NSIntersectionRange(self.documentRange,span.range)
                guard range.length>0 else{continue}
                var attrs=[NSAttributedString.Key:Any]()
                if (span.kind.hasPrefix("ATXHeading") || span.kind.hasPrefix("SetextHeading")),let level=Int(span.kind.suffix(1)),(1...6).contains(level) {
                    attrs[.font]=NSFont.monospacedSystemFont(ofSize:level==1 ? self.fontSize*18/13:level==2 ? self.fontSize*16/13:self.fontSize*14/13,weight:.bold)
                } else if span.kind=="StrongEmphasis" || span.kind=="Emphasis" {
                    let font=storage.attribute(.font,at:range.location,effectiveRange:nil) as! NSFont
                    attrs[.font]=NSFontManager.shared.convert(font,toHaveTrait:span.kind=="StrongEmphasis" ? .boldFontMask:.italicFontMask)
                } else if span.kind.contains("Mark") {attrs[.foregroundColor]=NSColor.secondaryLabelColor}
                else if span.kind=="Link" || span.kind=="URL" {attrs[.foregroundColor]=NSColor.linkColor}
                else if span.kind.hasPrefix("Math") {attrs[.foregroundColor]=NSColor.systemPurple}
                storage.addAttributes(attrs,range:range)
            }
            storage.endEditing()
            self.recordHighlightCoverage(covered)
        }
    }
}
