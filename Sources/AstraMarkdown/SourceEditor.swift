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
    private let prepared:PreparedDocument
    private var dirtyRange:NSRange?=NSRange(location:0,length:0)
    private var measuredWidth:CGFloat = -1
    private var highlightScheduled=false
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
    init(document:MarkdownDocument,prepared:PreparedDocument = PreparedDocument()) {
        self.document=document;self.prepared=prepared;super.init(frame:.zero)
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
        let width=max(1,scroll.contentSize.width-32)
        if abs(width-measuredWidth)>0.001 {dirtyRange=NSRange(location:0,length:prepared.sourceLayout.length);measuredWidth=width}
        guard let dirtyRange else {
            canvas.frame.size.height=max(scroll.contentSize.height,textView.frame.maxY+32)
            return
        }
        geometryRevision += 1
        textView.typingAttributes=baseAttributes
        textView.frame.size.width=max(1,scroll.contentSize.width)
        textView.textContainer!.containerSize=NSSize(width:width,height:.greatestFiniteMagnitude)
        let manager=textView.layoutManager!,container=textView.textContainer!
        // Measure only affected paragraphs. The tree retains both sides, and
        // changes to source length/height shift its suffix through subtree sums.
        let boundary=dirtyRange.location
        let end=min(document.source.count,NSMaxRange(dirtyRange)+document.source.count-prepared.sourceLayout.length)
        manager.ensureLayout(for:container)
        let characters=NSRange(location:boundary,length:max(0,end-boundary))
        let glyphs=manager.glyphRange(forCharacterRange:characters,actualCharacterRange:nil)
        var measured=[MeasuredLine]()
        manager.enumerateLineFragments(forGlyphRange:glyphs) {_,used,_,glyphs,_ in
            let characters=manager.characterRange(forGlyphRange:glyphs,actualGlyphRange:nil)
            if characters.length>0 {
                measured.append(MeasuredLine(range:characters,rect:used.offsetBy(dx:self.textView.textContainerInset.width,dy:self.textView.textContainerInset.height)))
            }
        }
        let followingY:CGFloat?
        if NSMaxRange(glyphs)<manager.numberOfGlyphs {
            followingY=manager.lineFragmentUsedRect(forGlyphAt:NSMaxRange(glyphs),effectiveRange:nil).minY+textView.textContainerInset.height
        } else {followingY=nil}
        let lines=measured.enumerated().map {index,line in
            let next=index+1<measured.count ? measured[index+1].rect.minY:followingY ?? line.rect.maxY
            return LayoutIndex.Line(length:line.range.length,advance:Double(next-line.rect.minY),height:Double(line.rect.height))
        }
        prepared.sourceLayout.replace(dirtyRange,with:lines,origin:measured.first.map{Double($0.rect.minY)})
        self.dirtyRange=nil
        #if DEBUG
        TimingDiagnostics.shared.reported("source.layout.lines",milliseconds:0,values:["measured":Double(lines.count),"retainedCharacters":Double(prepared.sourceLayout.length-lines.reduce(0){$0+$1.length})])
        #endif
        let height=max(manager.usedRect(for:container).maxY,manager.extraLineFragmentRect.maxY)
        textView.frame=NSRect(x:0,y:0,width:scroll.contentSize.width,height:height+textView.textContainerInset.height*2+32)
        canvas.frame.size=NSSize(width:scroll.contentSize.width,height:max(scroll.contentSize.height,textView.frame.maxY+32))
    }
    func reload(preserving selection:NSRange) {
        guard !textView.hasMarkedText() else{return}
        let previousChanging=changingLayout;changingLayout=true
        if loadedRevision != document.revision {
            dirtyRange=NSRange(location:0,length:prepared.sourceLayout.length)
            textView.string=document.source.string
            textView.textStorage!.setAttributes(baseAttributes,range:documentRange)
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
    func documentEdited(selection:NSRange,edit:SourceEdit) {
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
        invalidateLayout(in:original)
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
        guard !isScrolling,!localEdit,!textView.hasMarkedText(),nativeLayoutRevision==nil else{return}
        let pending=deferredHighlights;deferredHighlights.removeAll()
        applyHighlightBatch(pending.filter{$0.0==document.revision}.map{($0.1,$0.2)})
    }
    func queueHighlights(_ spans:[SyntaxSpan],in range:NSRange) {
        deferredHighlights.append((document.revision,spans,range))
        guard !highlightScheduled else{return}
        highlightScheduled=true
        DispatchQueue.main.asyncAfter(deadline:.now()+0.025) { [weak self] in
            guard let self else{return};self.highlightScheduled=false;self.applyDeferredHighlights()
        }
    }
    func applyHighlights(_ spans:[SyntaxSpan],in requestedRange:NSRange) {
        if isScrolling || textView.hasMarkedText() || nativeLayoutRevision != nil {
            deferredHighlights.append((document.revision,spans,requestedRange));return
        }
        applyHighlightBatch([(spans,requestedRange)])
    }
    private func applyHighlightBatch(_ batches:[([SyntaxSpan],NSRange)]) {
        var changes=[([SyntaxSpan],NSRange)]()
        for (spans,range) in batches {
            let covered=NSIntersectionRange(documentRange,range)
            guard covered.length>0,!hasAppliedHighlights(in:covered) else{continue}
            recordHighlightCoverage(covered);changes.append((spans,covered))
        }
        guard !changes.isEmpty else{return}
        #if DEBUG
        highlightApplications += 1
        let work=TimingDiagnostics.shared.begin("source.highlight")
        defer {TimingDiagnostics.shared.end(work,values:["spans":Double(changes.reduce(0){$0+$1.0.count}),"batches":Double(changes.count)])}
        #endif
        for (_,range) in changes {invalidateLayout(in:range)}
        relayoutPreservingViewport {
            let storage=self.textView.textStorage!
            storage.beginEditing()
            for (spans,covered) in changes {
                storage.setAttributes(self.baseAttributes,range:covered)
                for span in spans {
                    let range=NSIntersectionRange(covered,span.range)
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
            }
            storage.endEditing()
        }
    }
}
