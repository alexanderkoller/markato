import AppKit
import MarkdownCore

/// NSSplitView preserves pixels from the preceding frame during a live resize
/// by default. The source and HTML panes redraw independently, so those stale
/// pixels make their shared top edge visibly alternate between two positions.
final class EditorSplitView:NSSplitView {
    override var preservesContentDuringLiveResize:Bool {false}
}

final class EditorWindowController: NSWindowController, NSSplitViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation, NSWindowDelegate {
    private struct ParseRequest:Equatable {
        let revision:Int
        let range:NSRange
        var isRetry=false
    }
    let source: SourceEditor
    let preview = PreviewPane(frame:.zero)
    let split = EditorSplitView()
    private let content = FlippedView()
    private let findBar = NSView()
    private let findField = NSSearchField()
    private let parseErrorBar = NSView()
    private let parseErrorLabel = NSTextField(labelWithString:"")
    private let parseRetryButton = NSButton(title:"Retry",target:nil,action:nil)
    private var findVisible = false
    private var findGeneration = 0
    private var lastRequest:ParseRequest?
    private var parseRetryWork:DispatchWorkItem?
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
    private var completePresentationPendingRevision:Int?
    private var completeEditRevision:Int?
    private var pendingRegional:(revision:Int,context:RegionalParseContext)?
    private var isClosed=false
    private var openingRequested=false
    private var hasShownWindow=false
    private var resizeSession:ViewportResizeSession?
    #if DEBUG
    var cachedBlockCount:Int {preparedDocument.count}
    var cachedByteCost:Int {preparedDocument.byteCost}
    var isShowingParseError:Bool {!parseErrorBar.isHidden}
    func debugRetryFailedParse() {retryFailedParse(nil)}
    var hasPreparedViewport:Bool {
        guard source.hasMeasuredLayout else{return false}
        let visible=source.visibleSourceRange
        return preview.lastRevision==markdownDocument.revision && preview.coversSourceViewport
            && preparedDocument.entries(covering:visible) != nil
    }
    #endif
    private func enqueueBackgroundPreparation(_ work:@escaping ()->Void) {
        DispatchQueue.main.asyncAfter(deadline:.now()+0.005,execute:work)
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
        window.tabbingMode = .disallowed
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
        parseErrorBar.isHidden=true;parseErrorBar.wantsLayer=true
        parseErrorBar.layer?.backgroundColor=NSColor.systemRed.withAlphaComponent(0.12).cgColor
        parseErrorLabel.lineBreakMode = .byTruncatingTail
        parseRetryButton.target=self;parseRetryButton.action=#selector(retryFailedParse(_:));parseRetryButton.bezelStyle = .rounded
        parseErrorBar.addSubview(parseErrorLabel);parseErrorBar.addSubview(parseRetryButton);content.addSubview(parseErrorBar)
        content.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self,selector:#selector(contentResized(_:)),name:NSView.frameDidChangeNotification,object:content)
        source.viewportChanged = { [weak self] range in self?.viewportChanged(range) }
        source.scrollGestureChanged = { [weak self] active in
            if active {self?.preview.beginScrollGesture()}else{
                self?.preview.endScrollGesture()
                if let self {
                    if self.presentationPending {self.showPreparedDocument(revision:self.markdownDocument.revision)}
                    else if self.completePresentationPendingRevision==self.markdownDocument.revision {
                        self.showCompletePreparedDocument(revision:self.markdownDocument.revision)
                    }
                }
            }
        }
        preview.preparedDocument=preparedDocument
        preview.presentationSettled = { [weak self] in
            guard let self,!self.isClosed,let document=self.document as? MarkdownDocument else{return}
            if self.openingRequested {self.showWindow(nil)}
            // A settled render frees the renderer for the latest coalesced
            // viewport even during a gesture. PreviewPane keeps the landmark
            // map frozen while it prepares and atomically anchors the new window.
            if self.preview.displaysCompleteDocument,self.preview.displayedDocumentRevision==document.revision {
                self.presentationPending=false;self.completePresentationPendingRevision=nil
            } else if self.presentationPending {self.showPreparedDocument(revision:document.revision)}
            else if self.completePresentationPendingRevision==document.revision {
                self.showCompletePreparedDocument(revision:document.revision)
            }
            if self.preview.needsWindowTrimming {self.showPreparedDocument(revision:document.revision)}
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
            if self.preparedDocument.revision==document.revision-1,
               let context=self.preparedDocument.regionalContext(for:edit,newLength:document.source.count) {
                self.pendingRegional=(document.revision,context)
            } else {self.pendingRegional=nil}
            self.cancelParseRetry();self.hideParseError()
            self.completePresentationPendingRevision=nil
            if self.preview.displaysCompleteDocument {
                // Retain the complete DOM. Once Comrak publishes the manifest
                // delta and the changed visible fragment, patch that block in
                // place; its suffix geometry is refreshed asynchronously.
                self.completeEditRevision=document.revision
                self.presentationRange=nil;self.preservedEditPresentationRevision=nil
            } else if let presented=self.presentationRange {
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
            if self.completeEditRevision != document.revision {self.preview.invalidate()}
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
    func windowWillStartLiveResize(_ notification:Notification) {
        source.traceResize("window.willStart.before")
        let previewAnchor=preview.captureResizeAnchor()
        let sourceAnchor=source.captureResizeAnchor()
        let session=ViewportResizeSession(sourceOffset:sourceAnchor.offset,
            sourceDisplacement:sourceAnchor.displacement,sourceOrigin:sourceAnchor.origin,
            previewEntryID:previewAnchor.entryID,previewDisplacement:previewAnchor.displacement,
            previewOrigin:previewAnchor.origin)
        resizeSession=session
        preview.beginResize(session);source.beginResize(session)
        source.traceResize("window.willStart.after")
    }
    func windowDidEndLiveResize(_ notification:Notification) {
        guard resizeSession != nil else{return}
        source.traceResize("window.didEnd.before")
        // A final TextKit layout can move the rendered anchor even when the
        // clip origin is unchanged. Restore the saved source anchor after all
        // release-time layout, while the resize session still owns the view.
        window?.contentView?.layoutSubtreeIfNeeded()
        source.traceResize("window.didEnd.afterLayout")
        preview.finishResizeLayout()
        source.finishResizeLayout()
        source.traceResize("window.didEnd.afterPreview")
        DispatchQueue.main.async { [weak self] in self?.source.traceResize("window.didEnd.nextTurn") }
    }
    func windowWillClose(_ notification:Notification) {
        isClosed=true;pendingViewport=nil;openingRequested=false
        cancelParseRetry()
        source.viewportChanged=nil;source.geometryChanged=nil
        source.scrollGestureChanged=nil;source.navigationRequested=nil
        source.scrollOverflow=nil
        preview.presentationSettled=nil
    }
    @objc private func contentResized(_ notification:Notification) { layoutContent() }
    private func layoutContent() {
        let findHeight:CGFloat = findVisible ? 38 : 0
        let errorHeight:CGFloat = parseErrorBar.isHidden ? 0 : 36
        let bar=findHeight+errorHeight
        findBar.frame = NSRect(x:0,y:0,width:content.bounds.width,height:findHeight)
        findField.frame = NSRect(x:12,y:6,width:max(180,content.bounds.width-300),height:26)
        let buttons = findBar.subviews.compactMap{$0 as? NSButton}
        for (index,button) in buttons.enumerated() { button.frame = NSRect(x:content.bounds.width-276+CGFloat(index)*88,y:5,width:82,height:28) }
        parseErrorBar.frame=NSRect(x:0,y:findHeight,width:content.bounds.width,height:errorHeight)
        parseErrorLabel.frame=NSRect(x:12,y:8,width:max(100,content.bounds.width-104),height:20)
        parseRetryButton.frame=NSRect(x:content.bounds.width-82,y:4,width:70,height:28)
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
    private func prepareViewport(retrying failedRequest:ParseRequest?=nil) {
        guard !isClosed else{return}
        #if DEBUG
        let work=TimingDiagnostics.shared.begin("viewport.prepare")
        defer {TimingDiagnostics.shared.end(work,values:["revision":Double(markdownDocument.revision),"cachedBlocks":Double(preparedDocument.count)])}
        #endif
        viewportScheduled = false
        guard let visible = pendingViewport else { return }; pendingViewport = nil
        // Layout changes caused by the error bar must not become unbounded
        // implicit retries. Editing or the Retry action clears the bar first.
        guard parseErrorBar.isHidden else{return}
        let doc = markdownDocument, rope = doc.source
        let margin=rope.lines(max(0,rope.line(at:visible.location)-5),min(rope.lineCount,rope.line(at:NSMaxRange(visible))+6))
        if preparedDocument.revision==doc.revision,let styles=preparedDocument.styles(in:margin),
           preparedDocument.entries(covering:margin) != nil {
                if !source.hasAppliedHighlights(in:margin) {applyingHighlights=true;source.applyHighlights(styles,in:margin);applyingHighlights=false}
                // Cached preparation and displayed coverage are separate. A
                // new destination must publish even if no parsing is needed.
                if !preview.coversSourceViewport ||
                   (preview.isScrollMappingFrozen && preview.needsWindowReplenishment) {
                    showPreparedDocument(revision:doc.revision)
                }
                return
        }
        let firstVisibleLine=rope.line(at:visible.location),lastVisibleLine=rope.line(at:NSMaxRange(visible))
        // Cover both directions by a viewport, including tall windows. A fixed
        // twenty-line lead is too small for fast reverse scrolling.
        let overscan=max(40,lastVisibleLine-firstVisibleLine+1)
        let startLine = max(0,firstVisibleLine-overscan)
        let endLine = min(rope.lineCount,lastVisibleLine+overscan)
        let range = rope.lines(startLine,endLine)
        let isRetry=failedRequest?.revision==doc.revision && failedRequest?.range==range
        if !isRetry,lastRequest?.revision==doc.revision,lastRequest?.range==range {return}
        cancelParseRetry()
        let request=ParseRequest(revision:doc.revision,range:range,isRetry:isRetry)
        lastRequest=request
        let cached=preparedDocument.revision==doc.revision ? preparedDocument.entries(covering:range):nil
        let revision = doc.revision
        let regional=pendingRegional?.revision==revision ? pendingRegional?.context:nil
        doc.parser.request(rope:rope,revision:revision,visible:range,renderHTML:cached==nil,
            includeFragments:cached==nil,regionalContext:regional) { [weak self] result in
            guard let self,!self.isClosed,self.markdownDocument.revision==revision,self.lastRequest==request else{return}
            switch result {
            case .success(let parsed):
                self.cancelParseRetry();self.hideParseError()
                self.pendingRegional=nil
                if self.preparedDocument.revision != revision {
                    if let change=parsed.blockChange,self.preparedDocument.revision>=0 {
                        self.preparedDocument.apply(change,revision:revision,length:rope.count)
                    } else if let blocks=parsed.blocks {
                        self.preparedDocument.adopt(blocks,revision:revision,length:rope.count,
                            hasReferences:parsed.hasReferences ?? false)
                    }
                    self.source.reconcilePreparedHighlights()
                }
                let parsedRange=NSRange(location:parsed.from ?? range.location,
                    length:max(0,(parsed.to ?? NSMaxRange(range))-(parsed.from ?? range.location)))
                self.preparedDocument.store(parsed,range:parsedRange)
                self.applyingHighlights=true
                // The retained blocks point into the native span arena, so
                // initial paint clips only the selected blocks instead of
                // scanning the complete document-sized span array.
                let styles=self.preparedDocument.styles(in:range) ?? parsed.spans
                if self.source.isAwaitingInitialHighlights {self.source.applyInitialHighlights(styles,in:range)}
                else {self.source.applyHighlights(styles,in:range)}
                self.applyingHighlights=false
                self.preview.baseURL = self.markdownDocument.fileURL?.deletingLastPathComponent()
                if self.completeEditRevision==revision,parsed.blockChange != nil {
                    // The Swift tree already contains every retained fragment
                    // and height. Publish its cached viewport on the spare
                    // HTML surface; keep the stale complete surface visible
                    // until that bounded replacement is painted. This avoids
                    // asking the renderer to repaint a document-sized view for one
                    // changed block.
                    self.completeEditRevision=nil;self.preview.invalidate()
                    self.showPreparedDocument(revision:revision)
                    if !self.preparedDocument.hasCompleteFragments {
                        self.prepareDocument(rope:rope,revision:revision)
                    }
                } else if self.completeEditRevision==revision {
                    // Whole-document replacement has no local manifest splice.
                    // Publish its prepared viewport, then fill the new tree.
                    self.completeEditRevision=nil;self.preview.invalidate()
                    self.showPreparedDocument(revision:revision)
                    self.prepareDocument(rope:rope,revision:revision)
                }
                else {self.showPreparedDocument(revision:revision)}
                self.source.needsLayout = true
                self.prepareDocument(rope:rope,revision:revision)
            case .failure(let error):
                self.handleParseFailure(error,request:request)
            }
        }
    }
    private func handleParseFailure(_ error:Error,request:ParseRequest) {
        NSLog("Markdown parsing failed at revision %d: %@",request.revision,error.localizedDescription)
        if request.isRetry {
            lastRequest=nil;cancelParseRetry()
            preview.showParseFailure(revision:request.revision)
            parseErrorLabel.stringValue="Preview could not be updated: \(error.localizedDescription)"
            parseErrorBar.isHidden=false;layoutContent()
            return
        }
        let work=DispatchWorkItem { [weak self] in
            guard let self,!self.isClosed,self.markdownDocument.revision==request.revision,
                  self.lastRequest==request else{return}
            self.pendingViewport=self.source.visibleSourceRange
            self.prepareViewport(retrying:request)
        }
        parseRetryWork=work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.1,execute:work)
    }
    private func cancelParseRetry() {
        parseRetryWork?.cancel();parseRetryWork=nil
    }
    private func hideParseError() {
        preview.clearParseFailure()
        guard !parseErrorBar.isHidden else{return}
        parseErrorBar.isHidden=true;layoutContent()
    }
    @objc private func retryFailedParse(_ sender:Any?) {
        cancelParseRetry();hideParseError();lastRequest=nil
        pendingViewport=source.visibleSourceRange;prepareViewport()
    }
    private func showPreparedDocument(revision:Int) {
        guard !isClosed else{return}
        if preview.displaysCompleteDocument,preview.displayedDocumentRevision==revision,
           !preview.needsWindowTrimming {
            presentationPending=false;completePresentationPendingRevision=nil
            preview.moveViewport();return
        }
        if preview.isRenderingPresentation,preview.displayedDocumentRevision==revision {
            // Keep one same-revision window in flight and coalesce movement to
            // the latest source viewport after that presentation settles.
            presentationPending=true
            return
        }
        let visible=source.visibleSourceRange
        let requestedRange:NSRange
        let usesPreservedEditRange=preservedEditPresentationRevision==revision
        let reusesPresentedWindow:Bool
        if usesPreservedEditRange,let presented=presentationRange,presented.0==revision,
           presented.1.location<=visible.location,NSMaxRange(presented.1)>=NSMaxRange(visible),
           preparedDocument.entries(covering:presented.1) != nil {
            requestedRange=presented.1
            reusesPresentedWindow=true
        } else if let request=lastRequest,request.revision==revision,
           request.range.location<=visible.location,NSMaxRange(request.range)>=NSMaxRange(visible) {
            requestedRange=request.range
            reusesPresentedWindow=false
        } else {requestedRange=visible;reusesPresentedWindow=false}
        // presentationRange already includes the scroll reserve. Re-expanding
        // it after every edit changes the DOM shape and prevents the renderer
        // from replacing only the changed block at its stable index.
        // Twelve viewports on each side give a roughly 24-viewport runway.
        let reach=reusesPresentedWindow ? 0 : max(1,Double(preview.bounds.height))*12
        guard let window=preparedDocument.window(covering:requestedRange,before:reach,after:reach) else {
            viewportChanged(visible);return
        }
        presentationRange=(revision,window.range)
        if usesPreservedEditRange {preservedEditPresentationRevision=nil}
        // A covered viewport with adequate reserve needs no new publication.
        // Outrunning the mounted window continues through the live render queue.
        if preview.isScrollMappingFrozen,preview.coversSourceViewport,
           !preview.needsWindowReplenishment,preview.displayedDocumentRevision==revision {
            // The mounted window already contains the viewport and its reserve.
            // There is no deferred publication to replay at gesture end.
            presentationPending=false
            return
        }
        presentationPending=false
        preview.show(window.entries,revision:revision,sourceRange:window.range,
            previewTop:window.previewTop,previewHeight:window.previewHeight)
    }
    private func prepareDocument(rope:TextRope,revision:Int,allowUnpresented:Bool=false) {
        guard !isClosed else{return}
        guard preparedDocument.revision==revision,backgroundRevision != revision,
              (allowUnpresented || preview.displayedDocumentRevision==revision),
              (allowUnpresented || !preview.isShowingLoadingState) else{return}
        backgroundRevision=revision
        enqueueBackgroundPreparation { [weak self] in self?.prepareBatch(rope:rope,revision:revision,from:0) }
    }
    private func prepareBatch(rope:TextRope,revision:Int,from:Int) {
        guard !isClosed else{return}
        let from=preparedDocument.firstUnpreparedOffset(from:from)
        guard markdownDocument.revision==revision else{return}
        guard from<rope.count else {
            showCompletePreparedDocument(revision:revision);return
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
            case .failure(let error):
                // Let the next foreground success restart background filling.
                self.backgroundRevision = -1
                NSLog("Background preview preparation failed: %@",error.localizedDescription)
            }
        }
    }
    private func showCompletePreparedDocument(revision:Int) {
        guard !isClosed,markdownDocument.revision==revision,
              preparedDocument.revision==revision,
              preparedDocument.hasCompleteFragments else{return}
        if source.isScrolling || preview.isRenderingPresentation {
            completePresentationPendingRevision=revision;return
        }
        completePresentationPendingRevision=nil;presentationPending=false
        completeEditRevision=nil
        // Completion means every semantic unit is cached in PreparedDocument.
        // Keep the mounted HTML bounded; scrolling can now refill it entirely
        // from the retained tree without parsing or rendering Markdown.
        showPreparedDocument(revision:revision)
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
    private func setFont(_ size:CGFloat) { lastRequest = nil;sourceFontSize = size; source.fontSize = size; preview.fontSize = size+2 }
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
