import AppKit
import MarkdownCore

final class EditorWindowController: NSWindowController, NSSplitViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation, NSWindowDelegate {
    let source: SourceEditor
    let preview = PreviewPane(frame:.zero)
    let split = NSSplitView()
    private let content = FlippedView()
    private let findBar = NSView()
    private let findField = NSSearchField()
    private var findVisible = false
    private var findGeneration = 0
    private var lastRequest: (Int,NSRange)?
    private var presentationRange: (Int,NSRange)?
    private var preservedEditPresentationRevision:Int?
    private var pendingViewport:NSRange?
    private var viewportScheduled = false
    private var applyingHighlights = false
    private var sourceFontSize: CGFloat = 13
    private var savedDivider: CGFloat = 0.5
    // Prepared document content is retained. Viewport movement never evicts it.
    private let preparedDocument=PreparedDocument()
    private var backgroundRevision = -1
    private var presentationPending=false
    private var isClosed=false
    private var openingRequested=false
    private var hasShownWindow=false
    #if DEBUG
    // Debug checks can stop preparation at an exact source boundary.
    var scheduleBackgroundPreparation: (@escaping ()->Void)->Void = { work in
        DispatchQueue.main.asyncAfter(deadline:.now()+0.005,execute:work)
    }
    private(set) var parserRequests=0
    var cachedPageCount:Int {preparedDocument.count}
    var cachedByteCost:Int {preparedDocument.byteCost}
    var hasCompleteSourceLayout:Bool {source.hasCompletePreparedLayout}
    var hasPreparedViewport:Bool {
        guard source.hasMeasuredLayout else{return false}
        let visible=source.visibleSourceRange
        return preview.lastRevision==markdownDocument.revision && preview.coversSourceViewport
            && preparedDocument.entries(covering:visible) != nil
    }
    #endif
    private func enqueueBackgroundPreparation(_ work:@escaping ()->Void) {
        #if DEBUG
        scheduleBackgroundPreparation(work)
        #else
        DispatchQueue.main.asyncAfter(deadline:.now()+0.005,execute:work)
        #endif
    }
    var hasPreparedDocument:Bool {preparedDocument.revision==markdownDocument.revision && preparedDocument.firstUnpreparedOffset(from:0)>=markdownDocument.source.count}
    private var markdownDocument: MarkdownDocument { document as! MarkdownDocument }
    init(document:MarkdownDocument) {
        source = SourceEditor(document:document,prepared:preparedDocument,deferInitialLayout:true)
        var initialSize=NSSize(width:1120,height:760)
        #if DEBUG
        if let option=CommandLine.arguments.first(where:{$0.hasPrefix("--integration-window=")}) {
            let dimensions=option.dropFirst("--integration-window=".count).split(separator:"x").compactMap{Double($0)}
            precondition(dimensions.count==2 && dimensions.allSatisfy{$0>0},"Invalid integration window dimensions")
            initialSize=NSSize(width:dimensions[0],height:dimensions[1])
        }
        #endif
        let window = NSWindow(contentRect:NSRect(origin:.zero,size:initialSize),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init(window:window)
        window.delegate = self
        window.minSize = NSSize(width:640,height:380); window.center()
        window.tabbingMode = .preferred
        // Native checks use a reproducible fixture and must not read or overwrite
        // the user's saved document-window dimensions.
        #if DEBUG
        if !CommandLine.arguments.contains("--integration-test") && !CommandLine.arguments.contains("--smoke-test") {
            window.setFrameAutosaveName("MarkdownDocument")
        }
        #else
        window.setFrameAutosaveName("MarkdownDocument")
        #endif
        window.contentView = content
        split.isVertical = true; split.dividerStyle = .thin; split.delegate = self
        split.addArrangedSubview(source); split.addArrangedSubview(preview); content.addSubview(split)
        findBar.isHidden = true; content.addSubview(findBar)
        findField.placeholderString = "Find"; findField.delegate = self; findBar.addSubview(findField)
        let next = NSButton(title:"Next",target:self,action:#selector(findNext(_:)))
        let previous = NSButton(title:"Previous",target:self,action:#selector(findPrevious(_:)))
        let done = NSButton(title:"Done",target:self,action:#selector(closeFind(_:)))
        for button in [previous,next,done] { button.bezelStyle = .rounded; findBar.addSubview(button) }
        content.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self,selector:#selector(contentResized(_:)),name:NSView.frameDidChangeNotification,object:content)
        source.viewportChanged = { [weak self] range in self?.viewportChanged(range) }
        source.scrollGestureChanged = { [weak self] active in
            if active {self?.preview.beginScrollGesture()}else{
                self?.preview.endScrollGesture()
                if let self,self.presentationPending {self.showPreparedDocument(revision:self.markdownDocument.revision)}
            }
        }
        preview.preparedDocument=preparedDocument
        preview.presentationSettled = { [weak self] in
            guard let self,!self.isClosed,let document=self.document as? MarkdownDocument else{return}
            if self.openingRequested {self.showWindow(nil)}
            if self.presentationPending,!self.preview.isScrollMappingFrozen {self.showPreparedDocument(revision:document.revision)}
            self.prepareDocument(rope:document.source,revision:document.revision)
        }
        source.geometryChanged = { [weak self] in self?.preview.sourceLayoutChanged() }
        source.scrollOverflow = { [weak self] event in self?.preview.scrollOverflow(event) ?? false }
        source.navigationRequested = { [weak self] position in
            guard let self else{return}
            self.preview.navigatePreview(toEnd:position>0 && position==self.markdownDocument.source.count)
        }
        preview.scrolling = .synchronized(source)
        preview.baseURL = document.fileURL?.deletingLastPathComponent()
        document.edited = { [weak self] selection,_,edit in
            guard let self,!self.isClosed else { return }
            if let presented=self.presentationRange {
                let range=presented.1,editEnd=NSMaxRange(edit.range),rangeEnd=NSMaxRange(range)
                let delta=edit.insertedLength-edit.range.length
                let shifted:NSRange
                if editEnd<=range.location,edit.range.length>0 {
                    shifted=NSRange(location:range.location+delta,length:range.length)
                } else if edit.range.location>=rangeEnd {
                    shifted=range
                } else {
                    let start=min(range.location,edit.range.location)
                    let end=max(edit.range.location+edit.insertedLength,rangeEnd+delta)
                    shifted=NSRange(location:start,length:max(0,end-start))
                }
                self.presentationRange=(document.revision,shifted)
                self.preservedEditPresentationRevision=document.revision
            }
            self.lastRequest = nil
            self.source.endScrollGesture()
            self.presentationPending=false
            self.preview.invalidate()
            self.source.documentEdited(selection:selection,edit:edit)
        }
        layoutContent(); split.setPosition(window.frame.width*0.5,ofDividerAt:0)
        // Materialize TextKit only after the pane and its scroll view have
        // their actual sizes. A zero-width initial layout wraps every character.
        content.layoutSubtreeIfNeeded()
        source.reveal(0,alignTop:true);window.makeFirstResponder(source.textView)
    }
    required init?(coder:NSCoder) { fatalError() }
    override func showWindow(_ sender:Any?) {
        guard !isClosed else{return}
        // Opening publishes the same ready viewport as scrolling. Do not expose
        // a source-only first frame while the browser is still starting up.
        guard hasShownWindow || (preview.displayedDocumentRevision==source.contentRevision && !preview.isShowingLoadingState && preview.coversSourceViewport) else {
            openingRequested=true
            return
        }
        openingRequested=false;hasShownWindow=true
        super.showWindow(sender)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    func windowWillClose(_ notification:Notification) {
        isClosed=true;pendingViewport=nil;openingRequested=false
        source.viewportChanged=nil;source.geometryChanged=nil
        source.scrollGestureChanged=nil;source.navigationRequested=nil
        source.scrollOverflow=nil
        preview.presentationSettled=nil
    }
    @objc private func contentResized(_ notification:Notification) { layoutContent() }
    private func layoutContent() {
        let bar:CGFloat = findVisible ? 38 : 0
        findBar.frame = NSRect(x:0,y:0,width:content.bounds.width,height:bar)
        findField.frame = NSRect(x:12,y:6,width:max(180,content.bounds.width-300),height:26)
        let buttons = findBar.subviews.compactMap{$0 as? NSButton}
        for (index,button) in buttons.enumerated() { button.frame = NSRect(x:content.bounds.width-276+CGFloat(index)*88,y:5,width:82,height:28) }
        split.frame = NSRect(x:0,y:bar,width:content.bounds.width,height:content.bounds.height-bar)
        split.adjustSubviews(); source.needsLayout = true; preview.needsLayout = true
    }
    private func viewportChanged(_ range:NSRange) {
        guard !isClosed else{return}
        preview.moveViewport()
        guard !applyingHighlights else { return }
        pendingViewport = range
        if !viewportScheduled {
            viewportScheduled = true
            DispatchQueue.main.async { [weak self] in self?.prepareViewport() }
        }
    }
    private func prepareViewport() {
        guard !isClosed else{return}
        #if DEBUG
        let work=TimingDiagnostics.shared.begin("viewport.prepare")
        defer {TimingDiagnostics.shared.end(work,values:["revision":Double(markdownDocument.revision),"cachePages":Double(preparedDocument.count)])}
        #endif
        viewportScheduled = false
        guard let visible = pendingViewport else { return }; pendingViewport = nil
        let doc = markdownDocument, rope = doc.source
        let margin=rope.lines(max(0,rope.line(at:visible.location)-5),min(rope.lineCount,rope.line(at:NSMaxRange(visible))+6))
        if preparedDocument.revision==doc.revision,let styles=preparedDocument.styles(in:margin),
           preparedDocument.entries(covering:margin) != nil {
                if !source.hasAppliedHighlights(in:margin) {applyingHighlights=true;source.applyHighlights(styles,in:margin);applyingHighlights=false}
                // Cached preparation and displayed coverage are separate. A
                // new destination must publish even if no parsing is needed.
                if !preview.coversSourceViewport {showPreparedDocument(revision:doc.revision)}
                return
        }
        let firstVisibleLine=rope.line(at:visible.location),lastVisibleLine=rope.line(at:NSMaxRange(visible))
        // Cover both directions by a viewport, including tall windows. A fixed
        // twenty-line lead is too small for fast reverse scrolling.
        let overscan=max(40,lastVisibleLine-firstVisibleLine+1)
        let startLine = max(0,firstVisibleLine-overscan)
        let endLine = min(rope.lineCount,lastVisibleLine+overscan)
        let range = rope.lines(startLine,endLine)
        if let lastRequest, lastRequest.0 == doc.revision, NSEqualRanges(lastRequest.1,range) { return }
        lastRequest = (doc.revision,range)
        let cached=preparedDocument.revision==doc.revision ? preparedDocument.entries(covering:range):nil
        let revision = doc.revision
        #if DEBUG
        parserRequests += 1
        #endif
        doc.parser.request(rope:rope,revision:revision,visible:range,renderHTML:cached==nil,includeFragments:cached==nil) { [weak self] result in
            guard let self,!self.isClosed, self.markdownDocument.revision == revision, self.lastRequest?.0 == revision, self.lastRequest?.1 == range else { return }
            switch result {
            case .success(let parsed):
                if self.preparedDocument.revision != revision {
                    if let change=parsed.blockChange,self.preparedDocument.revision>=0 {
                        self.preparedDocument.apply(change,revision:revision,length:rope.count)
                    } else if let blocks=parsed.blocks {
                        self.preparedDocument.adopt(blocks,revision:revision,length:rope.count)
                    }
                    self.source.reconcilePreparedHighlights()
                }
                self.preparedDocument.store(parsed,range:range)
                self.applyingHighlights=true
                if self.source.isAwaitingInitialHighlights {self.source.applyInitialHighlights(parsed.spans,in:range)}
                else {
                    // Store may merge this request with retained syntax pages.
                    // Apply the normalized result from that same tree so the
                    // source view follows the preserved pre-startup path.
                    let styles=self.preparedDocument.styles(in:range) ?? parsed.spans
                    self.source.applyHighlights(styles,in:range)
                }
                self.applyingHighlights=false
                self.preview.baseURL = self.markdownDocument.fileURL?.deletingLastPathComponent()
                self.showPreparedDocument(revision:revision)
                self.source.needsLayout = true
                self.prepareDocument(rope:rope,revision:revision)
            case .failure(let error): NSLog("Markdown parsing failed: %@",error.localizedDescription)
            }
        }
    }
    private func showPreparedDocument(revision:Int,background:Bool=false) {
        guard !isClosed else{return}
        if background,preview.isPreparingPresentation {
            // Background progress is additive, not a reason to reject the
            // complete foreground presentation currently awaiting paint.
            presentationPending=true
            return
        }
        let rope=markdownDocument.source
        let visible=source.visibleSourceRange
        let requestedRange:NSRange
        let usesPreservedEditRange=preservedEditPresentationRevision==revision
        if usesPreservedEditRange,let presented=presentationRange,presented.0==revision,
           presented.1.location<=visible.location,NSMaxRange(presented.1)>=NSMaxRange(visible),
           preparedDocument.entries(covering:presented.1) != nil {
            requestedRange=presented.1
        } else if let request=lastRequest,request.0==revision,
           request.1.location<=visible.location,NSMaxRange(request.1)>=NSMaxRange(visible) {
            requestedRange=request.1
        } else {requestedRange=visible}
        guard let page=preparedDocument.page(covering:requestedRange) else {
            viewportChanged(visible);return
        }
        let pages=[page]
        presentationRange=(revision,page.range)
        if usesPreservedEditRange {preservedEditPresentationRevision=nil}
        var entries=[RenderedEntry](),position=0
        // Unprepared intervals occupy their document position. Foreground
        // rendering fills the destination rather than replacing a moving window.
        func gap(_ from:Int,_ to:Int,_ id:String) {
            guard to>from else{return}
            let lines=max(1,rope.line(at:to)-rope.line(at:from))
            let height=Double(lines)*24
            let fragment=PreviewFragment(kind:"Pending",from:from,to:to,
                markdown:"",html:"<div aria-busy='true' style='height:\(height)px'></div>")
            entries.append(RenderedEntry(id:"pending:\(id)",fragment:fragment))
        }
        for page in pages {
            gap(position,page.range.location,"before:\(page.entries.first?.id ?? "end")")
            entries.append(contentsOf:page.entries)
            position=max(position,NSMaxRange(page.range))
        }
        gap(position,rope.count,"after:\(pages.last?.entries.last?.id ?? "start")")
        // Progress outside an already rendered viewport waits for the gesture.
        // Only outrunning the displayed preparation may publish during scrolling.
        if preview.isScrollMappingFrozen,preview.coversSourceViewport,preview.displayedDocumentRevision==revision {
            presentationPending=true
            return
        }
        presentationPending=false
        preview.show(entries,revision:revision)
    }
    private func prepareDocument(rope:TextRope,revision:Int) {
        guard !isClosed else{return}
        guard preparedDocument.revision==revision,backgroundRevision != revision,preview.displayedDocumentRevision==revision,
              !preview.isShowingLoadingState else{return}
        backgroundRevision=revision
        enqueueBackgroundPreparation { [weak self] in self?.prepareBatch(rope:rope,revision:revision,from:0) }
    }
    private func prepareBatch(rope:TextRope,revision:Int,from:Int) {
        guard !isClosed else{return}
        let from=preparedDocument.firstUnpreparedOffset(from:from)
        guard markdownDocument.revision==revision else{return}
        guard from<rope.count else {
            showPreparedDocument(revision:revision,background:true)
            return
        }
        let line=rope.line(at:from),batchRange=rope.lines(line,min(rope.lineCount,line+100))
        let includeFragments=preparedDocument.entries(covering:batchRange)==nil
        markdownDocument.parser.prepare(rope:rope,revision:revision,from:from,includeFragments:includeFragments) { [weak self] result in
            guard let self,!self.isClosed,self.markdownDocument.revision==revision else{return}
            switch result {
            case .success(let (parsed,range)):
                self.preparedDocument.store(parsed,range:range)
                let next=NSMaxRange(range)
                self.enqueueBackgroundPreparation { [weak self] in self?.prepareBatch(rope:rope,revision:revision,from:max(from+1,next)) }
            case .failure(let error):NSLog("Background preview preparation failed: %@",error.localizedDescription)
            }
        }
    }
    @objc func undo(_ sender:Any?) { markdownDocument.undoManager?.undo() }
    @objc func redo(_ sender:Any?) { markdownDocument.undoManager?.redo() }
    @objc func togglePreview(_ sender:Any?) {
        preview.isHidden.toggle()
        if preview.isHidden { savedDivider = source.frame.width/max(1,split.bounds.width); split.setPosition(split.bounds.width,ofDividerAt:0) }
        else { split.setPosition(split.bounds.width*savedDivider,ofDividerAt:0) }
        layoutContent()
    }
    @objc func increaseFont(_ sender:Any?) { setFont(sourceFontSize+1) }
    @objc func decreaseFont(_ sender:Any?) { setFont(max(9,sourceFontSize-1)) }
    private func setFont(_ size:CGFloat) { lastRequest = nil;sourceFontSize = size; source.fontSize = size; preview.fontSize = size+1 }
    @objc func showFind(_ sender:Any?) { findVisible = true; findBar.isHidden = false; layoutContent(); window?.makeFirstResponder(findField) }
    @objc private func closeFind(_ sender:Any?) { findVisible = false; findBar.isHidden = true; layoutContent(); window?.makeFirstResponder(source.textView) }
    @objc func findNext(_ sender:Any?) { find(backwards:false) }
    @objc func findPrevious(_ sender:Any?) { find(backwards:true) }
    func controlTextDidChange(_ notification:Notification) { find(backwards:false,fromStart:true) }
    private func find(backwards:Bool,fromStart:Bool = false) {
        let query = findField.stringValue; guard !query.isEmpty else { return }
        findGeneration += 1; let generation = findGeneration
        let rope = markdownDocument.source, revision = markdownDocument.revision, selection = source.selection
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let text = rope.string as NSString
            let start = min(text.length,fromStart ? 0 : backwards ? selection.location : NSMaxRange(selection))
            let search = backwards ? NSRange(location:0,length:start) : NSRange(location:start,length:text.length-start)
            let options: NSString.CompareOptions = backwards ? [.caseInsensitive,.backwards] : [.caseInsensitive]
            var found = text.range(of:query,options:options,range:search)
            if found.location == NSNotFound { found = text.range(of:query,options:options) }
            DispatchQueue.main.async {
                guard let self,!self.isClosed,self.findGeneration == generation,self.markdownDocument.revision == revision else { return }
                if found.location != NSNotFound {
                    self.source.reveal(found.location);self.source.textView.setSelectedRange(found)
                } else { NSSound.beep() }
            }
        }
    }
    func validateMenuItem(_ menuItem:NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): menuItem.title = markdownDocument.undoManager?.undoMenuItemTitle ?? "Undo"; return markdownDocument.undoManager?.canUndo == true
        case #selector(redo(_:)): menuItem.title = markdownDocument.undoManager?.redoMenuItemTitle ?? "Redo"; return markdownDocument.undoManager?.canRedo == true
        case #selector(togglePreview(_:)): menuItem.state = preview.isHidden ? .off : .on; return true
        default:return true
        }
    }
}
