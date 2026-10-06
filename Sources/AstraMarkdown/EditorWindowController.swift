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
    private var pendingViewport: (NSRange,Int,CGFloat)?
    private var viewportScheduled = false
    private var applyingHighlights = false
    private var sourceFontSize: CGFloat = 13
    private var savedDivider: CGFloat = 0.5
    private var tableInspector:TableInspector?
    private let htmlWorker=HTMLWorker()
    private let renderCache=RenderedCache()
    private var mountedRange:NSRange?
    private var mountedRevision = -1
    private var backgroundRevision = -1
    private var viewportGeneration=0
    var cachedPageCount:Int {renderCache.count}
    var cachedByteCost:Int {renderCache.byteCost}
    var hasPreparedViewport:Bool {mountedRevision==markdownDocument.revision}
    var hasPreparedDocument:Bool {renderCache.firstUnpreparedOffset(from:0)>=markdownDocument.source.count}
    private var markdownDocument: MarkdownDocument { document as! MarkdownDocument }
    init(document:MarkdownDocument) {
        source = SourceEditor(document:document)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1120,height:760),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init(window:window)
        window.delegate = self
        window.minSize = NSSize(width:640,height:380); window.center()
        window.tabbingMode = .preferred; window.setFrameAutosaveName("MarkdownDocument")
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
        source.viewportChanged = { [weak self] range,anchor,fraction in self?.viewportChanged(range,anchor:anchor,fraction:fraction) }
        source.scrollGestureChanged = { [weak self] active in
            if active {self?.preview.beginScrollGesture()}else{self?.preview.endScrollGesture()}
        }
        source.geometryRebased = { [weak self] delta in self?.preview.rebaseSource(by:delta) }
        preview.wheel = { [weak self] event in self?.source.scrollWheel(event,fromPreview:true) }
        preview.sourceFraction = { [weak self] range,anchor in self?.source.fraction(through:range,at:anchor) }
        preview.sourcePosition = { [weak self] offset in self?.source.verticalPosition(for:offset) ?? 0 }
        preview.sourceBottomDistance = { [weak self] in
            guard let source=self?.source else {return .greatestFiniteMagnitude}
            return max(0,source.canvas.bounds.height-source.scroll.contentView.bounds.maxY)
        }
        preview.sourceAlignmentOffset = { [weak self] in self?.source.alignmentOffset ?? 0 }
        preview.sourceViewportY = { [weak self] in self?.source.scroll.contentView.bounds.minY ?? 0 }
        preview.sourceGeometryRevision = { [weak self] in self?.source.geometryRevision ?? 0 }
        preview.sourceContentHeight = { [weak self] in self?.source.canvas.bounds.height ?? 0 }
        preview.inspectItem = { [weak self] fragment in
            guard let self else { return }
            self.tableInspector = TableInspector(fragment:fragment,source:self.markdownDocument.source,baseURL:self.markdownDocument.fileURL?.deletingLastPathComponent(),fontSize:self.preview.fontSize)
            self.tableInspector?.showWindow(nil)
        }
        preview.baseURL = document.fileURL?.deletingLastPathComponent()
        document.edited = { [weak self,weak document] selection,_,edit in
            guard let self,let document else { return }; self.lastRequest = nil
            self.source.endScrollGesture()
            self.viewportGeneration += 1;self.mountedRevision = -1
            // Fences, math delimiters and reference definitions can change distant semantics.
            if document.lastEditInvalidatesContext {self.renderCache.clear()}
            else {self.renderCache.invalidate(edit)}
            self.preview.invalidate(edit,source:document.source,revision:document.revision,structural:document.lastEditChangesStructure)
            self.source.documentEdited(selection:selection,edit:edit)
        }
        layoutContent(); split.setPosition(window.frame.width*0.5,ofDividerAt:0)
        source.refresh(); window.makeFirstResponder(source.textView)
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
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
    private func viewportChanged(_ range:NSRange,anchor:Int,fraction:CGFloat) {
        preview.setAnchor(anchor,fraction:fraction)
        guard !applyingHighlights else { return }
        pendingViewport = (range,anchor,fraction)
        if !viewportScheduled {
            viewportScheduled = true
            DispatchQueue.main.async { [weak self] in self?.prepareViewport() }
        }
    }
    private func prepareViewport() {
        let work=TimingDiagnostics.shared.begin("viewport.prepare")
        defer {TimingDiagnostics.shared.end(work,values:["revision":Double(markdownDocument.revision),"cachePages":Double(renderCache.count)])}
        viewportScheduled = false
        guard let (visible,anchor,_) = pendingViewport else { return }; pendingViewport = nil
        let doc = markdownDocument, rope = doc.source
        if mountedRevision==doc.revision,let mountedRange {
            let margin=rope.lines(max(0,rope.line(at:visible.location)-5),min(rope.lineCount,rope.line(at:NSMaxRange(visible))+6))
            if mountedRange.location<=margin.location && NSMaxRange(mountedRange)>=NSMaxRange(margin) {return}
        }
        let startLine = max(0,rope.line(at:visible.location)-20)
        let endLine = min(rope.lineCount,rope.line(at:NSMaxRange(visible))+40)
        let range = rope.lines(startLine,endLine)
        if let lastRequest, lastRequest.0 == doc.revision, NSEqualRanges(lastRequest.1,range) { return }
        lastRequest = (doc.revision,range)
        viewportGeneration += 1;let generation=viewportGeneration
        let cached=renderCache.entries(covering:range)
        if let cached {
            showCached(cached,range:range,revision:doc.revision)
            preview.setAnchor(anchor)
        } else {
            // Immediate provisional viewport HTML does not wait for a whole-document syntax parse.
            htmlWorker.request(text:rope.string(in:range),from:range.location,revision:doc.revision) { [weak self] result in
                guard let self,self.viewportGeneration==generation,self.markdownDocument.revision==doc.revision,
                      self.mountedRevision != doc.revision,case .success(let parsed)=result else{return}
                self.preview.show(parsed)
            }
        }
        let revision = doc.revision
        doc.parser.request(rope:rope,revision:revision,visible:range,renderHTML:cached==nil) { [weak self] result in
            guard let self, self.markdownDocument.revision == revision, self.lastRequest?.0 == revision, self.lastRequest?.1 == range else { return }
            switch result {
            case .success(let parsed):
                self.applyingHighlights = true; self.source.applyHighlights(parsed.spans); self.applyingHighlights = false
                self.preview.baseURL = self.markdownDocument.fileURL?.deletingLastPathComponent()
                if cached==nil {
                    let entries=self.renderCache.store(parsed,range:range)
                    self.showCached(entries,range:range,revision:revision)
                }
                self.source.needsLayout = true
                self.prepareDocument(rope:rope,revision:revision)
            case .failure(let error): NSLog("Markdown parsing failed: %@",error.localizedDescription)
            }
        }
    }
    private func showCached(_ entries:[RenderedEntry],range:NSRange,revision:Int) {
        let selected=entries.filter{NSIntersectionRange($0.fragment.range,range).length>0}
        preview.show(selected,revision:revision);mountedRange=range;mountedRevision=revision
    }
    private func prepareDocument(rope:TextRope,revision:Int) {
        guard backgroundRevision != revision else{return};backgroundRevision=revision
        prepareBatch(rope:rope,revision:revision,from:0)
    }
    private func prepareBatch(rope:TextRope,revision:Int,from:Int) {
        let from=renderCache.firstUnpreparedOffset(from:from)
        guard markdownDocument.revision==revision,from<rope.count else{return}
        markdownDocument.parser.prepare(rope:rope,revision:revision,from:from) { [weak self] result in
            guard let self,self.markdownDocument.revision==revision else{return}
            switch result {
            case .success(let (parsed,range)):
                self.renderCache.store(parsed,range:range)
                let next=max(NSMaxRange(range),parsed.fragments.last?.to ?? 0)
                // Yield between batches. A new viewport request can take priority on the worker.
                DispatchQueue.main.asyncAfter(deadline:.now()+0.005) { [weak self] in self?.prepareBatch(rope:rope,revision:revision,from:max(from+1,next)) }
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
    private func setFont(_ size:CGFloat) { sourceFontSize = size; source.fontSize = size; preview.fontSize = size+1; lastRequest = nil; source.refresh() }
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
                guard let self,self.findGeneration == generation,self.markdownDocument.revision == revision else { return }
                if found.location != NSNotFound {
                    self.source.load(around:found.location,preserving:found); self.source.reveal(found.location)
                    self.source.textView.setSelectedRange(NSRange(location:found.location-self.source.windowRange.location,length:found.length))
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
