import AppKit
import MarkdownCore

final class FlippedView: NSView { override var isFlipped: Bool { true } }
private final class SourceScrollView:NSScrollView {
    // Observing wheel phases does not change AppKit's scrolling or drawing.
    // A scrollWheel override otherwise opts the view out of responsive scrolling.
    override class var isCompatibleWithResponsiveScrolling:Bool {true}
    var willScroll:((NSEvent)->Void)?
    var didScroll:((NSEvent)->Void)?
    override func scrollWheel(with event:NSEvent) {
        willScroll?(event);super.scrollWheel(with:event);didScroll?(event)
    }
}
final class SourceTextView: NSTextView {
    weak var owner: SourceEditor?
    override var shouldDrawInsertionPoint:Bool {
        guard let owner else { return super.shouldDrawInsertionPoint }
        return super.shouldDrawInsertionPoint && owner.selection.location>=owner.windowRange.location && owner.selection.location<=NSMaxRange(owner.windowRange)
    }
    override func selectAll(_ sender: Any?) { owner?.selectEntireDocument() }
    override func copy(_ sender: Any?) { owner?.copySelection() }
    override func cut(_ sender: Any?) { owner?.copySelection(); owner?.replaceSelection("") }
    override func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType:.string) { owner?.replaceSelection(text) }
    }
    override func insertText(_ insertString:Any,replacementRange:NSRange) {
        if let text = insertString as? String, owner?.document.newline == "\r\n" {
            super.insertText(text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\n",with:"\r\n"),replacementRange:replacementRange)
        } else { super.insertText(insertString,replacementRange:replacementRange) }
    }
    override func mouseDown(with event:NSEvent) { owner?.clearGlobalSelection(); super.mouseDown(with:event) }
    override func scrollToEndOfDocument(_ sender:Any?) { if let owner { owner.reveal(owner.document.source.count) } }
    override func scrollToBeginningOfDocument(_ sender:Any?) { owner?.reveal(0) }
    override func moveToBeginningOfDocument(_ sender:Any?) { owner?.reveal(0) }
    override func moveToEndOfDocument(_ sender:Any?) { if let owner { owner.reveal(owner.document.source.count) } }
    override func keyDown(with event: NSEvent) {
        if owner?.entireDocumentSelected == true, [123,124,125,126].contains(event.keyCode), !event.modifierFlags.contains(.shift) {
            owner?.collapseSelection(toEnd:event.keyCode == 124 || event.keyCode == 125); return
        }
        if owner?.entireDocumentSelected == true, event.charactersIgnoringModifiers != nil,
           !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) {
            if event.keyCode == 51 || event.keyCode == 117 { owner?.replaceSelection(""); return }
            if let characters = event.characters, characters.unicodeScalars.allSatisfy({!($0.value>=0xf700 && $0.value<=0xf8ff)}) {
                owner?.replaceSelection(characters); return
            }
        }
        if event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift), event.keyCode == 125 {
            owner?.reveal(owner?.document.source.count ?? 0); return
        }
        if event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift), event.keyCode == 126 {
            owner?.reveal(0); return
        }
        owner?.ensureSelectionVisible()
        super.keyDown(with:event)
    }
}

/// TextKit 2 sees a local working set; global coordinates live in the persistent source model.
final class SourceEditor: NSView, NSTextViewDelegate {
    let scroll:NSScrollView = SourceScrollView()
    let canvas = FlippedView()
    let textView = SourceTextView(usingTextLayoutManager:true)
    unowned let document: MarkdownDocument
    var viewportChanged: ((NSRange, Int, CGFloat) -> Void)?
    var scrollGestureChanged:((Bool)->Void)?
    var geometryRebased:((CGFloat)->Void)?
    private(set) var isScrolling=false
    private var scrollEnd:DispatchWorkItem?
    private var liveScrollObservations=[NSObjectProtocol]()
    private(set) var windowRange = NSRange(location:0,length:0)
    private var loading = false
    private var localEdit = false
    private var changingBounds = false
    private var resizeAnchor:Int?
    private var pendingEdit: (NSRange,String)?
    private var observation: NSObjectProtocol?
    private(set) var geometryRevision=0
    private(set) var entireDocumentSelected = false
    private var storedSelection = NSRange(location:0,length:0)
    var viewportAnchor:Int { currentAnchor() ?? windowRange.location }
    var fontSize: CGFloat = 13 { didSet { endScrollGesture();refresh(preserving: selection) } }
    var selection: NSRange {
        if entireDocumentSelected { return NSRange(location:0,length:document.source.count) }
        return storedSelection
    }
    func clearGlobalSelection() { entireDocumentSelected = false }
    func collapseSelection(toEnd:Bool) {
        let position = toEnd ? NSMaxRange(selection) : selection.location
        entireDocumentSelected = false; storedSelection = NSRange(location:position,length:0); reveal(position)
    }
    func ensureSelectionVisible() {
        let selected = selection
        if selected.location<windowRange.location || NSMaxRange(selected)>NSMaxRange(windowRange) {
            load(around:selected.location,preserving:selected); reveal(selected.location)
        }
    }
    private var lineHeight: CGFloat { fontSize * 1.4 }
    private var columns: CGFloat { max(12,(scroll.contentSize.width-32)/(fontSize*0.61)) }
    init(document: MarkdownDocument) {
        self.document = document; super.init(frame:.zero)
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = true; scroll.backgroundColor = .textBackgroundColor
        scroll.documentView = canvas; addSubview(scroll); canvas.addSubview(textView)
        textView.owner = self; textView.delegate = self
        textView.isRichText = false; textView.isEditable = true; textView.isSelectable = true
        textView.allowsUndo = false; textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false; textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false; textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width:16,height:16)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.autoresizingMask = []; textView.backgroundColor = .textBackgroundColor
        textView.setAccessibilityLabel("Markdown source")
        scroll.contentView.postsBoundsChangedNotifications = true
        observation = NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:scroll.contentView,queue:.main) { [weak self] _ in self?.scrolled() }
        let wheelScroll=scroll as! SourceScrollView
        wheelScroll.willScroll={ [weak self] event in
            guard abs(event.scrollingDeltaY)>=abs(event.scrollingDeltaX) else{return}
            self?.beginScrollGesture()
        }
        wheelScroll.didScroll={ [weak self] event in
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) || event.phase.contains(.cancelled) {
                self?.endScrollGesture()
            } else if event.phase.contains(.ended) || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
                self?.scheduleScrollEnd()
            }
        }
        let center=NotificationCenter.default
        liveScrollObservations.append(center.addObserver(forName:NSScrollView.willStartLiveScrollNotification,object:scroll,queue:.main) { [weak self] _ in self?.beginScrollGesture() })
        liveScrollObservations.append(center.addObserver(forName:NSScrollView.didEndLiveScrollNotification,object:scroll,queue:.main) { [weak self] _ in self?.scheduleScrollEnd() })
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit {
        scrollEnd?.cancel()
        if let observation { NotificationCenter.default.removeObserver(observation) }
        for observer in liveScrollObservations {NotificationCenter.default.removeObserver(observer)}
    }
    func beginScrollGesture() {
        scrollEnd?.cancel();scrollEnd=nil
        guard !isScrolling else{return}
        isScrolling=true;scrollGestureChanged?(true)
    }
    func endScrollGesture() {
        scrollEnd?.cancel();scrollEnd=nil
        guard isScrolling else{return}
        isScrolling=false;scrollGestureChanged?(false)
    }
    private func scheduleScrollEnd() {
        scrollEnd?.cancel()
        // A trackpad's finger phase ends just before momentum begins. Also
        // group phase-less mouse-wheel ticks into one gesture.
        let end=DispatchWorkItem { [weak self] in self?.endScrollGesture() }
        scrollEnd=end;DispatchQueue.main.asyncAfter(deadline:.now()+0.15,execute:end)
    }
    override func setFrameSize(_ newSize:NSSize) {
        if newSize != frame.size {endScrollGesture()}
        if abs(newSize.width-frame.width)>0.5, resizeAnchor == nil { resizeAnchor = currentAnchor() }
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func layout() {
        let previousBoundsChange = changingBounds
        changingBounds = true
        defer { changingBounds = previousBoundsChange }
        super.layout(); let oldSize = scroll.frame.size
        let anchor = resizeAnchor ?? currentAnchor()
        let restoringResize = resizeAnchor != nil
        resizeAnchor = nil
        scroll.frame = bounds
        if restoringResize || abs(oldSize.width-scroll.frame.width)>0.5 || abs(oldSize.height-scroll.frame.height)>0.5 || windowRange.length == 0 {
            updateDimensions()
            if windowRange.length == 0 { load(around:0) }
            if let anchor { reveal(anchor,alignTop:true) }
        }
        notifyViewport()
    }
    private func estimate(_ offset: Int) -> CGFloat {
        let source = document.source
        return CGFloat(source.line(at:offset))*lineHeight + CGFloat(offset)*lineHeight/columns
    }
    private func updateDimensions() {
        let work=TimingDiagnostics.shared.begin("source.layout")
        defer {TimingDiagnostics.shared.end(work,values:["windowCharacters":Double(windowRange.length),"width":Double(scroll.contentSize.width)])}
        geometryRevision += 1
        textView.typingAttributes = [.font:NSFont.monospacedSystemFont(ofSize:fontSize,weight:.regular),.foregroundColor:NSColor.textColor]
        textView.frame.size.width = max(1,scroll.contentSize.width)
        textView.textContainer?.containerSize = NSSize(width:max(1,scroll.contentSize.width-32),height:CGFloat.greatestFiniteMagnitude)
        textView.textLayoutManager?.ensureLayout(for:textView.textLayoutManager!.documentRange)
        let height = max(lineHeight+32,textView.textLayoutManager?.usageBoundsForTextContainer.height ?? lineHeight)+32
        textView.frame = NSRect(x:0,y:estimate(windowRange.location),width:scroll.contentSize.width,height:height)
        let estimatedWindow = estimate(NSMaxRange(windowRange))-estimate(windowRange.location)
        let totalHeight = NSMaxRange(windowRange)==document.source.count
            ? textView.frame.maxY+32 : estimate(document.source.count)+height-estimatedWindow+32
        canvas.frame.size = NSSize(width:scroll.contentSize.width,height:max(scroll.contentSize.height,totalHeight))
    }
    func load(around offset: Int, preserving globalSelection: NSRange? = nil) {
        guard !textView.hasMarkedText() else { return }
        loading = true; defer { loading = false }
        let globalSelection = globalSelection ?? storedSelection
        let source = document.source, line = source.line(at:offset)
        // A viewport-sized working set also covers tall windows at small fonts.
        let visibleLines = Int(ceil(scroll.contentSize.height / max(1,fontSize)))
        var first = max(0,line-60), end = min(source.lineCount,line+max(121,visibleLines+61))
        if globalSelection.length>0, !entireDocumentSelected {
            first = min(first,source.line(at:globalSelection.location))
            end = max(end,min(source.lineCount,source.line(at:NSMaxRange(globalSelection))+2))
        }
        windowRange = source.lines(first,end)
        textView.string = source.string(in:windowRange)
        textView.textStorage?.setAttributes([.font:NSFont.monospacedSystemFont(ofSize:fontSize,weight:.regular),.foregroundColor:NSColor.textColor],range:NSRange(location:0,length:windowRange.length))
        let selection = globalSelection
        if selection.location >= windowRange.location, NSMaxRange(selection) <= NSMaxRange(windowRange) {
            textView.setSelectedRange(NSRange(location:selection.location-windowRange.location,length:selection.length))
        } else if entireDocumentSelected {
            textView.setSelectedRange(NSRange(location:0,length:windowRange.length))
        } else {
            textView.setSelectedRange(NSRange(location:0,length:0))
        }
        updateDimensions()
    }
    private func currentAnchor() -> Int? {
        guard windowRange.length > 0 else { return nil }
        return windowRange.location + offset(atCanvasY:scroll.contentView.bounds.minY+3)
    }
    private func offset(atCanvasY y:CGFloat, endOfLine:Bool = false)->Int {
        guard let manager = textView.textLayoutManager,let content = manager.textContentManager else { return 0 }
        let localY = y-textView.frame.minY-textView.textContainerInset.height
        var result = windowRange.length
        manager.enumerateTextLayoutFragments(from:content.documentRange.location,options:[.ensuresLayout]) { fragment in
            let start = content.offset(from:content.documentRange.location,to:fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                if fragment.layoutFragmentFrame.minY+line.typographicBounds.maxY>localY {
                    result = start+(endOfLine ? NSMaxRange(line.characterRange) : line.characterRange.location)
                    return false
                }
            }
            return true
        }
        return max(0,min(windowRange.length,result))
    }
    private func scrolled() {
        let work=TimingDiagnostics.shared.begin("source.scroll")
        defer {TimingDiagnostics.shared.end(work,values:["sourceY":Double(scroll.contentView.bounds.minY)])}
        guard !loading && !changingBounds && resizeAnchor == nil else { return }
        let top = scroll.contentView.bounds.minY
        let bottom = top+scroll.contentSize.height
        if top < textView.frame.minY || bottom > textView.frame.maxY-30 {
            // Preserve actual TextKit coordinates while replenishing a known passage.
            // Estimates are only for jumps outside the currently laid-out text.
            let known = top >= textView.frame.minY && top < textView.frame.maxY
            let offset = known ? (currentAnchor() ?? windowRange.location)
                : document.source.estimatedOffset(at:Double(top),lineHeight:Double(lineHeight),columns:Double(columns))
            let displacement = known ? top-verticalPosition(for:offset) : 0
            let selected = selection
            if selected.length == 0 || NSMaxRange(selected) <= NSMaxRange(windowRange) {
                changingBounds = true
                let oldPosition=verticalPosition(for:offset)
                load(around:offset,preserving:selected)
                geometryRebased?(verticalPosition(for:offset)-oldPosition)
                scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,verticalPosition(for:offset)+displacement)))
                scroll.reflectScrolledClipView(scroll.contentView)
                changingBounds = false
            }
        }
        notifyViewport()
    }
    func scrollWheel(_ event: NSEvent, fromPreview: Bool) { scroll.scrollWheel(with:event) }
    override func scrollWheel(with event:NSEvent) { scroll.scrollWheel(with:event) }
    private func notifyViewport() {
        let work=TimingDiagnostics.shared.begin("viewport.sync")
        defer {TimingDiagnostics.shared.end(work,values:["sourceY":Double(scroll.contentView.bounds.minY)])}
        guard !loading, windowRange.length > 0 else { viewportChanged?(windowRange,windowRange.location,0); return }
        let top = scroll.contentView.bounds.minY, bottom = top+scroll.contentSize.height
        let start = offset(atCanvasY:top+2)
        let end = max(start,offset(atCanvasY:bottom-2,endOfLine:true))
        let global = windowRange.location+start
        let offset = rect(for:global)?.minY ?? top
        viewportChanged?(NSRange(location:global,length:end-start),global,offset-top)
    }
    private func rect(for global:Int)->NSRect? {
        guard global>=windowRange.location,global<=NSMaxRange(windowRange),
              let manager = textView.textLayoutManager,let content = manager.textContentManager,
              let location = content.location(content.documentRange.location,offsetBy:global-windowRange.location),
              let fragment = manager.textLayoutFragment(for:location) else { return nil }
        let offset = content.offset(from:fragment.rangeInElement.location,to:location)
        let line = fragment.textLineFragments.first { offset >= $0.characterRange.location && offset < NSMaxRange($0.characterRange) }
            ?? fragment.textLineFragments.last
        guard let line else { return nil }
        return NSRect(x:textView.frame.minX+textView.textContainerInset.width,
                      y:textView.frame.minY+textView.textContainerInset.height+fragment.layoutFragmentFrame.minY+line.typographicBounds.minY,
                      width:1,height:line.typographicBounds.height)
    }
    func fraction(through range:NSRange,at anchor:Int)->CGFloat? {
        guard let start = rect(for:range.location),let end = rect(for:NSMaxRange(range)),let position = rect(for:anchor) else { return nil }
        return min(1,max(0,(position.minY-start.minY)/max(lineHeight,end.maxY-start.minY)))
    }
    /// Exact local TextKit geometry, with the same estimate used by the source
    /// canvas for anchors outside its working set.
    func verticalPosition(for offset:Int)->CGFloat {
        rect(for:offset)?.minY ?? estimate(offset)
    }
    /// MacDown's midpoint alignment, tapered to the document edges.
    var alignmentOffset:CGFloat {
        let height=max(1,scroll.contentSize.height), y=scroll.contentView.bounds.minY
        let top=min(1,max(0,y/height))
        let bottom=min(1,max(0,(canvas.bounds.height-height-y)/height))
        return top*bottom*height/2
    }
    func refresh(preserving selection: NSRange? = nil) {
        let anchor = currentAnchor() ?? selection?.location ?? 0
        load(around:anchor,preserving:selection); notifyViewport()
    }
    func documentEdited(selection:NSRange, edit:SourceEdit) {
        entireDocumentSelected = false
        storedSelection = selection
        if localEdit {
            windowRange.length += edit.insertedLength-edit.range.length
            updateDimensions(); notifyViewport()
        } else {
            load(around:selection.location,preserving:selection); reveal(selection.location); notifyViewport()
        }
    }
    func reveal(_ offset:Int, alignTop:Bool = false) {
        endScrollGesture()
        let position = min(max(0,offset),document.source.count)
        if position < windowRange.location || position > NSMaxRange(windowRange) { load(around:position,preserving:alignTop ? selection : NSRange(location:position,length:0)) }
        let local = NSRange(location:position-windowRange.location,length:0)
        if !alignTop { textView.setSelectedRange(local) }
        guard let rect = rect(for:position) ?? (position==document.source.count ? rect(for:max(windowRange.location,position-1)) : nil) else { return }
        changingBounds = true
        if alignTop { scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,rect.minY))) }
        else if position == document.source.count {
            scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,canvas.bounds.height-scroll.contentSize.height)))
        } else { canvas.scrollToVisible(rect.insetBy(dx:0,dy:-30)) }
        scroll.reflectScrolledClipView(scroll.contentView); changingBounds = false; scrolled()
    }
    func selectEntireDocument() { entireDocumentSelected = true; textView.setSelectedRange(NSRange(location:0,length:windowRange.length)) }
    func copySelection() {
        let value = document.source.string(in:selection)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value,forType:.string)
    }
    func replaceSelection(_ text:String) {
        if entireDocumentSelected { document.replace(selection,with:text,name:"Replace"); return }
        ensureSelectionVisible()
        textView.insertText(text,replacementRange:textView.selectedRange())
    }
    func textView(_ textView:NSTextView, shouldChangeTextIn affectedCharRange:NSRange, replacementString:String?) -> Bool {
        guard !loading else { return true }
        entireDocumentSelected = false
        pendingEdit = (NSRange(location:windowRange.location+affectedCharRange.location,length:affectedCharRange.length),replacementString ?? "")
        return true
    }
    func textDidChange(_ notification:Notification) {
        guard !loading, let (range,text) = pendingEdit else { return }; pendingEdit = nil
        localEdit = true; document.replace(range,with:text); localEdit = false
    }
    func textViewDidChangeSelection(_ notification:Notification) {
        if !loading && !entireDocumentSelected {
            let range = textView.selectedRange()
            storedSelection = NSRange(location:windowRange.location+range.location,length:range.length)
            notifyViewport()
        }
    }
    func applyHighlights(_ spans:[SyntaxSpan]) {
        let work=TimingDiagnostics.shared.begin("source.highlight")
        defer {TimingDiagnostics.shared.end(work,values:["spans":Double(spans.count)])}
        guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
        let anchor=currentAnchor()
        let oldPosition=anchor.map{verticalPosition(for:$0)}
        let displacement=anchor.map {scroll.contentView.bounds.minY-verticalPosition(for:$0)} ?? 0
        loading = true
        storage.beginEditing()
        storage.setAttributes([.font:NSFont.monospacedSystemFont(ofSize:fontSize,weight:.regular),.foregroundColor:NSColor.textColor],range:NSRange(location:0,length:storage.length))
        for span in spans {
            let overlap = NSIntersectionRange(windowRange,span.range); guard overlap.length>0 else { continue }
            let r = NSRange(location:overlap.location-windowRange.location,length:overlap.length)
            var attrs = [NSAttributedString.Key:Any]()
            if span.kind.contains("Heading") {
                let level = Int(span.kind.suffix(1)) ?? 2
                attrs[.font] = NSFont.monospacedSystemFont(ofSize:level==1 ? fontSize*18/13 : level==2 ? fontSize*16/13 : fontSize*14/13,weight:.bold)
            } else if span.kind == "StrongEmphasis" || span.kind == "Emphasis" {
                let existing = storage.attribute(.font,at:r.location,effectiveRange:nil) as? NSFont ?? .monospacedSystemFont(ofSize:fontSize,weight:.regular)
                attrs[.font] = NSFontManager.shared.convert(existing,toHaveTrait:span.kind == "StrongEmphasis" ? .boldFontMask : .italicFontMask)
            }
            else if span.kind.contains("Mark") { attrs[.foregroundColor] = NSColor.secondaryLabelColor }
            else if span.kind == "Link" || span.kind == "URL" { attrs[.foregroundColor] = NSColor.linkColor }
            else if span.kind.hasPrefix("Math") { attrs[.foregroundColor] = NSColor.systemPurple }
            if !attrs.isEmpty { storage.addAttributes(attrs,range:r) }
        }
        storage.endEditing()
        updateDimensions()
        if let anchor {
            if let oldPosition {geometryRebased?(verticalPosition(for:anchor)-oldPosition)}
            scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,verticalPosition(for:anchor)+displacement)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        loading = false
    }
}
