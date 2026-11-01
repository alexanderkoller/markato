import AppKit
import MarkdownCore
import UniformTypeIdentifiers

/// NSSplitView preserves pixels from the preceding frame during a live resize
/// by default. The source and HTML panes redraw independently, so those stale
/// pixels make their shared top edge visibly alternate between two positions.
final class EditorSplitView:NSSplitView {
    override var preservesContentDuringLiveResize:Bool {false}
    var dividerGestureChanged:((Bool)->Void)?
    override func mouseDown(with event:NSEvent) {
        dividerGestureChanged?(true)
        defer {dividerGestureChanged?(false)}
        super.mouseDown(with:event)
    }
    #if DEBUG
    func debugSetDividerGestureActive(_ active:Bool) {dividerGestureChanged?(active)}
    #endif
}

private final class CommentTextView:NSTextView {
    private static let bodyFont=NSFont.systemFont(ofSize:13)
    private static let bodyColor=NSColor(calibratedWhite:0.18,alpha:1)
    var submit:(()->Void)?,cancel:(()->Void)?
    func setBody(_ body:String) {
        let attributes:[NSAttributedString.Key:Any]=[.font:Self.bodyFont,.foregroundColor:Self.bodyColor]
        textStorage?.setAttributedString(NSAttributedString(string:body,attributes:attributes))
        typingAttributes=attributes
    }
    override func keyDown(with event:NSEvent) {
        if event.keyCode==36 || event.keyCode==76 {
            if event.modifierFlags.contains(.shift) {insertNewline(nil)} else {submit?()}
            return
        }
        if event.keyCode==53 {cancel?();return}
        super.keyDown(with:event)
    }
}

private final class CommentPopoverViewController:NSViewController {
    let editor=CommentTextView()
    let deleteButton=NSButton()
    var submit:(()->Void)? {didSet {editor.submit=submit}}
    var cancel:(()->Void)? {didSet {editor.cancel=cancel}}
    var delete:(()->Void)?
    private let focusOnShow:Bool
    var body:String {editor.string}
    init(comment:MarkdownComment,focusOnShow:Bool=false,canDelete:Bool=false) {
        self.focusOnShow=focusOnShow
        super.init(nibName:nil,bundle:nil)
        let container=NSView(frame:NSRect(x:0,y:0,width:360,height:280))
        container.wantsLayer=true
        container.layer?.backgroundColor=NSColor(calibratedRed:0.98,green:0.91,blue:0.68,alpha:1).cgColor
        let header=NSTextField(labelWithString:Self.header(for:comment))
        header.font=NSFont.systemFont(ofSize:11,weight:.medium);header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingTail;header.translatesAutoresizingMaskIntoConstraints=false
        deleteButton.image=NSImage(systemSymbolName:"trash",accessibilityDescription:"Delete Comment")
        deleteButton.isBordered=false;deleteButton.bezelStyle = .inline
        deleteButton.imageScaling = .scaleProportionallyDown
        deleteButton.toolTip="Delete Comment";deleteButton.isHidden = !canDelete
        deleteButton.target=self;deleteButton.action=#selector(deleteComment)
        deleteButton.translatesAutoresizingMaskIntoConstraints=false
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true
        scroll.drawsBackground=false;scroll.translatesAutoresizingMaskIntoConstraints=false
        // The popover has a fixed width. Giving its document view a flexible
        // width before Auto Layout sizes the scroll view doubles that width
        // (the scroll view starts at zero), leaving half the text offscreen.
        editor.frame=NSRect(x:0,y:0,width:344,height:240);editor.autoresizingMask=[]
        editor.isRichText=false;editor.allowsUndo=true
        editor.textColor=NSColor(calibratedWhite:0.18,alpha:1);editor.insertionPointColor=editor.textColor
        editor.backgroundColor = .clear;editor.drawsBackground=false
        editor.textContainerInset=NSSize(width:4,height:5)
        editor.isVerticallyResizable=true;editor.isHorizontallyResizable=false
        editor.minSize=NSSize(width:0,height:0);editor.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.containerSize=NSSize(width:344,height:CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView=true;editor.textContainer?.heightTracksTextView=false
        editor.setBody(comment.body);editor.setAccessibilityLabel("Comment")
        scroll.documentView=editor;container.addSubview(header);container.addSubview(deleteButton);container.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo:container.leadingAnchor,constant:12),
            header.trailingAnchor.constraint(equalTo:deleteButton.leadingAnchor,constant:-5),
            header.topAnchor.constraint(equalTo:container.topAnchor,constant:10),
            header.heightAnchor.constraint(equalToConstant:17),
            deleteButton.trailingAnchor.constraint(equalTo:container.trailingAnchor,constant:-8),
            deleteButton.centerYAnchor.constraint(equalTo:header.centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant:20),
            deleteButton.heightAnchor.constraint(equalToConstant:20),
            scroll.leadingAnchor.constraint(equalTo:container.leadingAnchor,constant:8),
            scroll.trailingAnchor.constraint(equalTo:container.trailingAnchor,constant:-8),
            scroll.topAnchor.constraint(equalTo:header.bottomAnchor,constant:3),
            scroll.bottomAnchor.constraint(equalTo:container.bottomAnchor,constant:-8)
        ])
        view=container;preferredContentSize=container.frame.size
    }
    @objc private func deleteComment(_ sender:Any?) {delete?()}
    required init?(coder:NSCoder) {fatalError()}
    override func viewDidAppear() {
        super.viewDidAppear()
        guard focusOnShow else{return}
        view.window?.makeFirstResponder(editor);editor.setSelectedRange(NSRange(location:editor.string.utf16.count,length:0))
    }
    private static func header(for comment:MarkdownComment)->String {
        guard !comment.author.isEmpty else{return "Comment"}
        guard let date=ISO8601DateFormatter().date(from:comment.created) else{return comment.author}
        let formatter=DateFormatter();formatter.dateStyle = .medium;formatter.timeStyle = .short
        return "\(comment.author) · \(formatter.string(from:date))"
    }
}

final class EditorWindowController: NSWindowController, NSSplitViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation, NSWindowDelegate, NSToolbarDelegate, NSPopoverDelegate {
    private static let sidebarToolbarItem=NSToolbarItem.Identifier("MarkatoSidebar")
    private struct ParseRequest:Equatable {
        let revision:Int
        let range:NSRange
        var isRetry=false
    }
    let source: SourceEditor
    let preview = PreviewPane(frame:.zero)
    let sidebar = SidebarPane(frame:.zero)
    private let workspaceSplit = EditorSplitView()
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
    private var savedSidebarWidth:CGFloat = 240
    private(set) var isSidebarVisible=false
    private var comments=[ResolvedMarkdownComment]()
    private var selectedCommentID:String?
    private var hoveredCommentID:String?
    private var commentPopover:NSPopover?
    private var commentPopoverController:CommentPopoverViewController?
    private var commentOutsideClickMonitor:Any?
    private var commentPopoverID:String?
    private var pendingCommentPopoverID:String?
    private enum CommentEditTarget {
        case new(selection:NSRange)
        case existing(id:String)
    }
    private var commentEditTarget:CommentEditTarget?
    private var finishingCommentPopover=false
    private var commentRefreshGeneration=0
    private var synchronizingCommentRecord=false
    private var insertingCommentRecord=false
    private var pendingCommentAnchorSyncIDs=Set<String>()
    private var commentAnchorSyncScheduled=false
    // Prepared document content is retained. Viewport movement never evicts it.
    private let preparedDocument=PreparedDocument()
    private var backgroundRevision = -1
    private var presentationPending=false
    private var pendingRegional:(revision:Int,edit:SourceEdit,context:RegionalParseContext)?
    private var pendingCommentInsertion:(body:String,selection:NSRange)?
    private var publishedOutlineGeneration = -1
    private var isClosed=false
    private var openingRequested=false
    private var hasShownWindow=false
    private var resizeSession:ViewportResizeSession?
    private var previewMeasurementGeneration=0
    private var previewMeasurementRevision = -1
    private var completedPreviewMeasurementRevision = -1
    #if DEBUG
    var cachedBlockCount:Int {preparedDocument.count}
    var cachedByteCost:Int {preparedDocument.byteCost}
    func debugBlockID(at offset:Int)->String? {
        preparedDocument.entries(covering:NSRange(location:offset,length:1))?.first?.id
    }
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
    #if DEBUG
    var hasMeasuredPreviewDocument:Bool {
        completedPreviewMeasurementRevision==markdownDocument.revision &&
            preparedDocument.previewLayoutID==preview.currentLayoutID
    }
    var debugPreparationState:String {
        "preparedComplete=\(preparedDocument.hasCompleteFragments), backgroundRevision=\(backgroundRevision), presentationPending=\(presentationPending)"
    }
    #endif
    private var markdownDocument: MarkdownDocument {(document as? MarkdownDocument) ?? source.document}
    init(document:MarkdownDocument) {
        source = SourceEditor(document:document,prepared:preparedDocument,deferInitialLayout:true)
        var initialSize=NSSize(width:1360,height:760)
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
        window.minSize = NSSize(width:760,height:380); window.center()
        window.isRestorable=false
        window.tabbingMode = .disallowed
        let toolbar=NSToolbar(identifier:"MarkatoDocumentToolbar")
        toolbar.delegate=self;toolbar.displayMode = .iconOnly
        window.toolbarStyle = .unified;window.toolbar=toolbar
        // Native checks use a reproducible fixture and must not read or overwrite
        // the user's saved document-window dimensions.
        #if DEBUG
        if !CommandLine.arguments.contains("--integration-test") && !CommandLine.arguments.contains("--smoke-test") {
            window.setFrameAutosaveName("MarkdownDocument")
        }
        #else
        window.setFrameAutosaveName("MarkdownDocument")
        #endif
        if let screen=window.screen ?? NSScreen.main {
            window.setFrame(window.constrainFrameRect(window.frame,to:screen),display:false)
        }
        window.contentView = workspaceSplit
        workspaceSplit.isVertical=true;workspaceSplit.dividerStyle = .thin;workspaceSplit.delegate=self
        workspaceSplit.addArrangedSubview(sidebar);workspaceSplit.addArrangedSubview(content)
        sidebar.isHidden=true
        workspaceSplit.setHoldingPriority(.defaultHigh,forSubviewAt:0)
        split.isVertical = true; split.dividerStyle = .thin; split.delegate = self
        split.dividerGestureChanged = { [weak self] active in
            if active {self?.beginViewportResize()} else {self?.finishViewportResize()}
        }
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
        NotificationCenter.default.addObserver(self,selector:#selector(applicationDidResignActive(_:)),
            name:NSApplication.didResignActiveNotification,object:NSApp)
        sidebar.activateHeading = { [weak self] id,focusSource in
            guard let self,let heading=self.preparedDocument.heading(id:id) else{return}
            self.source.reveal(heading.range.location,alignment:.readingAnchor)
            if focusSource {self.window?.makeFirstResponder(self.source.textView)}
        }
        sidebar.activateComment = { [weak self] id,focusSource in self?.revealComment(id,focusSource:focusSource) }
        sidebar.openComment = { [weak self] id in self?.openSidebarComment(id) }
        sidebar.clearCommentSelection = { [weak self] in self?.clearCommentSelection() }
        sidebar.toggleCommentResolved = { [weak self] id in self?.toggleCommentResolved(id) }
        source.viewportChanged = { [weak self] range in self?.viewportChanged(range) }
        source.sourceClicked = { [weak self] in self?.clearCommentSelection() }
        source.sourceNavigationIntent = { [weak self] in self?.preview.captureSourceScrolling() }
        source.scrollGestureChanged = { [weak self] active in
            if active {self?.preview.beginScrollGesture()}else{
                self?.preview.endScrollGesture()
                if let self {
                    if self.presentationPending {self.showPreparedDocument(revision:self.markdownDocument.revision)}
                }
            }
        }
        preview.preparedDocument=preparedDocument
        preview.previewView.commentHovered = { [weak self] id in self?.setCommentHover(id) }
        source.commentHoverChanged = { [weak self] offset in
            guard let self else{return}
            let hovered=offset.flatMap {offset in
                self.comments.filter {value in
                    guard let range=value.anchorRange else{return false}
                    return range.length==0 ? range.location==offset:NSLocationInRange(offset,range)
                }.min {first,second in
                    let a=first.anchorRange!,b=second.anchorRange!
                    return a.length != b.length ? a.length<b.length:a.location<b.location
                }?.comment.id
            }
            self.setCommentHover(hovered)
        }
        preview.openComment = { [weak self] id,view,anchor in
            guard let self else{return}
            let stableAnchor=self.preview.convert(anchor,from:view)
            self.sidebar.selectComment(id:id,activate:false)
            self.revealComment(id,focusSource:false)
            self.showCommentPopover(id:id,relativeTo:self.preview.selectedCommentAnchor ?? stableAnchor)
        }
        preview.commentAnchorChanged = { [weak self] anchor in self?.commentAnchorDidChange(anchor) }
        preview.independentViewportChanged = { [weak self] in
            guard let self else{return}
            self.showPreparedDocument(revision:self.markdownDocument.revision)
        }
        preview.presentationSettled = { [weak self] in
            guard let self,!self.isClosed,let document=self.document as? MarkdownDocument else{return}
            if self.openingRequested {self.showWindow(nil)}
            // A settled render frees the renderer for the latest coalesced
            // viewport even during a gesture. PreviewPane keeps the landmark
            // map frozen while it prepares and atomically anchors the new window.
            if self.presentationPending || (self.preview.followsIndependentViewport && self.preview.needsWindowReplenishment) {
                self.showPreparedDocument(revision:document.revision,
                    forceViewportWindow:self.resizeSession != nil)
            }
            self.prepareDocument(rope:document.source,revision:document.revision)
        }
        source.geometryChanged = { [weak self] in self?.preview.sourceLayoutChanged() }
        source.scrollOverflow = { [weak self] event in self?.preview.scrollOverflow(event) ?? false }
        source.navigationRequested = { [weak self] position in
            guard let self else{return}
            self.preview.navigatePreview(toEnd:position>0 && position==self.markdownDocument.source.count)
            // Semantic navigation is not merely another scroll notification:
            // it may cross the entire bounded browser window in one turn.
            // Explicitly publish the destination window so background
            // measurement or a coalesced viewport callback cannot strand the
            // preview on the previous range.
            self.showPreparedDocument(revision:self.markdownDocument.revision,
                forceViewportWindow:true)
        }
        preview.scrolling = .synchronized(source)
        preview.baseURL = document.fileURL?.deletingLastPathComponent()
        document.edited = { [weak self] selection,_,edit in
            guard let self,!self.isClosed else { return }
            #if DEBUG
            let editCallbackWork=TimingDiagnostics.shared.begin("editor.edit.callback")
            defer {TimingDiagnostics.shared.end(editCallbackWork,values:["revision":Double(document.revision)])}
            self.preview.beginEditTiming(revision:document.revision,edit:edit)
            #endif
            let inserted=edit.insertedLength>0
                ? document.source.string(in:NSRange(location:edit.range.location,length:edit.insertedLength)):""
            let editedComment=self.comments.first {value in
                edit.range.length==0 ? NSLocationInRange(edit.range.location,value.recordRange)
                    : NSIntersectionRange(edit.range,value.recordRange).length>0
            }
            let commentAnchor=editedComment?.anchorRange.map {
                MarkdownComments.transformedAnchorRange($0,through:edit)
            }.map {range in
                range.length>0 ? NSMaxRange(range)-1:range.location
            }
            let editedRecord=editedComment != nil
            let visibleBeforeEdit=self.source.visibleSourceRange
            let editWasVisible=edit.range.length==0
                ? edit.range.location>=visibleBeforeEdit.location &&
                    edit.range.location<=NSMaxRange(visibleBeforeEdit)
                : NSIntersectionRange(edit.range,visibleBeforeEdit).length>0
            let regionalEdit:SourceEdit?
            if self.preparedDocument.revision==document.revision-1 {regionalEdit=edit}
            else if let pending=self.pendingRegional,pending.revision==document.revision-1 {
                regionalEdit=pending.edit.composed(with:edit)
            } else {regionalEdit=nil}
            if let regionalEdit,
               let context=self.preparedDocument.regionalContext(for:regionalEdit,
                    newLength:document.source.count) {
                self.pendingRegional=(document.revision,regionalEdit,context)
            } else {self.pendingRegional=nil}
            self.cancelParseRetry();self.hideParseError()
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
            #if DEBUG
            let invalidateWork=TimingDiagnostics.shared.begin("editor.edit.invalidate")
            #endif
            self.preview.invalidate()
            #if DEBUG
            TimingDiagnostics.shared.end(invalidateWork,values:["revision":Double(document.revision)])
            let sourceWork=TimingDiagnostics.shared.begin("editor.edit.source")
            #endif
            self.source.documentEdited(selection:selection,edit:edit,semanticAnchor:commentAnchor)
            #if DEBUG
            TimingDiagnostics.shared.end(sourceWork,values:["revision":Double(document.revision)])
            #endif
            // Persisting a derived rendered-text selector is not a user edit
            // destination. It may finish after the user has already scrolled;
            // treating it as one would reacquire the edit viewport and pull
            // the preview back to the comment record.
            if editWasVisible && !self.synchronizingCommentRecord && !self.insertingCommentRecord {
                #if DEBUG
                let navigationWork=TimingDiagnostics.shared.begin("editor.edit.navigation")
                #endif
                self.preview.navigate(toSourceOffset:self.source.editAnchor,
                    viewportY:self.source.editAnchorViewportY)
                #if DEBUG
                TimingDiagnostics.shared.end(navigationWork,values:["revision":Double(document.revision)])
                #endif
            }
            self.shiftResolvedComments(for:edit)
            if let pending=self.pendingCommentInsertion {
                self.pendingCommentInsertion=(pending.body,
                    MarkdownComments.transformedAnchorRange(pending.selection,through:edit))
            }
            if !self.synchronizingCommentRecord && (editedRecord || inserted.contains(MarkdownComments.marker)) {
                self.scheduleCommentRefresh(insertedText:inserted,force:editedRecord)
                if editedRecord {
                    // Native storage is still completing its transaction here.
                    // A next-turn refresh is the authoritative record parse,
                    // especially when several adjacent records shift together.
                    DispatchQueue.main.async { [weak self] in
                        self?.scheduleCommentRefresh(force:true)
                    }
                }
            }
        }
        workspaceSplit.adjustSubviews()
        workspaceSplit.setPosition(0,ofDividerAt:0)
        layoutContent();split.setPosition(content.bounds.width*0.5,ofDividerAt:0)
        // Materialize TextKit only after the pane and its scroll view have
        // their actual sizes. A zero-width initial layout wraps every character.
        content.layoutSubtreeIfNeeded()
        source.reveal(0,alignment:.top);window.makeFirstResponder(source.textView)
        scheduleCommentRefresh(force:true)
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
    private func beginViewportResize() {
        source.traceResize("window.willStart.before")
        let previewAnchor=preview.captureResizeAnchor()
        let sourceAnchor=source.captureResizeAnchor()
        let session=ViewportResizeSession(sourceOffset:sourceAnchor.offset,
            sourceDisplacement:sourceAnchor.displacement,sourceOrigin:sourceAnchor.origin,
            previewAnchor:previewAnchor)
        resizeSession=session
        preview.beginResize(session);source.beginResize(session)
        showPreparedDocument(revision:markdownDocument.revision,forceViewportWindow:true)
        source.traceResize("window.willStart.after")
    }
    private func finishViewportResize() {
        guard resizeSession != nil else{return}
        source.traceResize("window.didEnd.before")
        // A final TextKit layout can move the rendered anchor even when the
        // clip origin is unchanged. Restore the saved source anchor after all
        // release-time layout, while the resize session still owns the view.
        window?.contentView?.layoutSubtreeIfNeeded()
        source.traceResize("window.didEnd.afterLayout")
        resizeSession?.finishDragging()
        preview.finishResizeLayout()
        source.finishResizeLayout()
        resizeSession=nil
        presentationPending=false
        // Mouse-up ends the gesture; it is not a navigation event. The final
        // width was already requested by the drag and PreviewPane keeps its
        // captured anchor until that request settles. Starting another bounded
        // presentation here can replace the anchored DOM after release and
        // visibly move the viewport.
        startPreviewMeasurement(revision:markdownDocument.revision)
        source.traceResize("window.didEnd.afterPreview")
        DispatchQueue.main.async { [weak self] in self?.source.traceResize("window.didEnd.nextTurn") }
    }
    func windowWillStartLiveResize(_ notification:Notification) {beginViewportResize()}
    func windowDidEndLiveResize(_ notification:Notification) {finishViewportResize()}
    func windowWillClose(_ notification:Notification) {
        finishCommentPopover(save:true)
        isClosed=true;pendingViewport=nil;openingRequested=false
        cancelParseRetry()
        source.viewportChanged=nil;source.geometryChanged=nil;source.sourceClicked=nil
        source.scrollGestureChanged=nil;source.navigationRequested=nil
        source.scrollOverflow=nil
        preview.presentationSettled=nil
        preview.independentViewportChanged=nil
        sidebar.activateHeading=nil
        sidebar.activateComment=nil;sidebar.openComment=nil;sidebar.clearCommentSelection=nil;sidebar.toggleCommentResolved=nil
        preview.openComment=nil;preview.commentAnchorChanged=nil
        preview.previewView.commentHovered=nil;source.commentHoverChanged=nil
    }
    @objc private func contentResized(_ notification:Notification) { layoutContent() }
    @objc private func applicationDidResignActive(_ notification:Notification) {
        finishCommentPopover(save:true)
    }
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
        sidebar.selectHeading(id:preparedDocument.heading(at:source.alignmentAnchor)?.id)
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
                if self.publishedOutlineGeneration != self.preparedDocument.outlineGeneration {
                    self.publishedOutlineGeneration=self.preparedDocument.outlineGeneration
                    let active=self.preparedDocument.heading(at:self.source.alignmentAnchor)?.id
                    self.sidebar.setHeadings(self.preparedDocument.headings,activeID:active)
                }
                self.applyingHighlights=true
                // The retained blocks point into the native span arena, so
                // initial paint clips only the selected blocks instead of
                // scanning the complete document-sized span array.
                let styles=self.preparedDocument.styles(in:range) ?? parsed.spans
                if self.source.isAwaitingInitialHighlights {self.source.applyInitialHighlights(styles,in:range)}
                else {self.source.applyHighlights(styles,in:range)}
                self.applyingHighlights=false
                self.preview.baseURL = self.markdownDocument.fileURL?.deletingLastPathComponent()
                self.showPreparedDocument(revision:revision)
                self.source.needsLayout = true
                self.prepareDocument(rope:rope,revision:revision)
                self.flushPendingCommentInsertionIfReady()
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
    private func showPreparedDocument(revision:Int,forceViewportWindow:Bool=false) {
        guard !isClosed else{return}
        // A source navigation can arrive before the parser publishes this
        // revision. Never hand stale retained fragments to Ultralight under a
        // new revision: layout preparation mutates the engine DOM before its
        // frame is atomically committed, so even a rejected request could
        // otherwise overwrite the retained successful preview.
        guard preparedDocument.revision==revision else {
            viewportChanged(source.visibleSourceRange);return
        }
        if preview.isRenderingPresentation,preview.displayedDocumentRevision==revision {
            // Keep one same-revision window in flight and coalesce movement to
            // the latest source viewport after that presentation settles.
            presentationPending=true
            return
        }
        let independentRange=preview.independentSourceRange
        let visible=independentRange ?? source.visibleSourceRange
        let requestedRange:NSRange
        let usesPreservedEditRange=preservedEditPresentationRevision==revision
        let reusesPresentedWindow:Bool
        let selectionKind:Double
        if forceViewportWindow || independentRange != nil {requestedRange=visible;reusesPresentedWindow=false;selectionKind=1}
        else if usesPreservedEditRange,let presented=presentationRange,presented.0==revision,
           presented.1.location<=visible.location,NSMaxRange(presented.1)>=NSMaxRange(visible),
           preparedDocument.entries(covering:presented.1) != nil {
            requestedRange=presented.1
            reusesPresentedWindow=true
            selectionKind=2
        } else if let request=lastRequest,request.revision==revision,
           request.range.location<=visible.location,NSMaxRange(request.range)>=NSMaxRange(visible) {
            requestedRange=request.range
            reusesPresentedWindow=false
            selectionKind=3
        } else {requestedRange=visible;reusesPresentedWindow=false;selectionKind=0}
        // presentationRange already includes the scroll reserve. Re-expanding
        // it after every edit changes the DOM shape and prevents the renderer
        // from replacing only the changed block at its stable index.
        // Three viewports on each side keep ordinary scrolling prepared while
        // bounding a destination layout tightly enough for immediate edits.
        let reach=reusesPresentedWindow ? 0 : max(1,Double(preview.bounds.height))*3
        guard let window=preparedDocument.window(covering:requestedRange,before:reach,after:reach) else {
            viewportChanged(visible);return
        }
        #if DEBUG
        let selectionWork=TimingDiagnostics.shared.begin("preview.window.select")
        TimingDiagnostics.shared.end(selectionWork,values:[
            "revision":Double(revision),"kind":selectionKind,
            "usesPreserved":usesPreservedEditRange ? 1:0,
            "visibleLocation":Double(visible.location),"visibleLength":Double(visible.length),
            "requestedLocation":Double(requestedRange.location),"requestedLength":Double(requestedRange.length),
            "reach":reach,"windowLocation":Double(window.range.location),
            "windowLength":Double(window.range.length),"entries":Double(window.entries.count)
        ])
        #endif
        refreshRenderedCommentAnchors(in:window.entries)
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
    private func refreshRenderedCommentAnchors(in entries:[RenderedEntry],sourceText:String?=nil) {
        guard !comments.isEmpty,!entries.isEmpty else{return}
        let sourceText=sourceText ?? markdownDocument.source.string
        var dirty=Set<String>()
        comments=comments.map {value in
            guard let range=value.anchorRange,range.length>0,
                  let entry=entries.first(where:{
                      range.location >= $0.fragment.from && NSMaxRange(range) <= $0.fragment.to
                  }) else{return value}
            let comment=MarkdownComments.updateRenderedAnchor(of:value.comment,to:range,
                in:sourceText,entry:entry)
            guard comment != value.comment else{return value}
            dirty.insert(comment.id)
            return ResolvedMarkdownComment(comment:comment,recordRange:value.recordRange,anchorRange:range)
        }
        guard !dirty.isEmpty else{return}
        sidebar.setComments(comments)
        preview.comments=comments
        pendingCommentAnchorSyncIDs.formUnion(dirty)
        scheduleCommentAnchorSync()
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
        startPreviewMeasurement(revision:revision)
    }
    /// Completes the retained preview geometry with bounded, non-visible
    /// Ultralight windows. The visible DOM remains viewport-sized.
    private func startPreviewMeasurement(revision:Int) {
        guard !isClosed,markdownDocument.revision==revision,
              preparedDocument.revision==revision,preparedDocument.hasCompleteFragments else{return}
        previewMeasurementGeneration += 1
        previewMeasurementRevision=revision
        completedPreviewMeasurementRevision = -1
        continuePreviewMeasurement(revision:revision,generation:previewMeasurementGeneration,cursor:0)
    }
    private func continuePreviewMeasurement(revision:Int,generation:Int,cursor:Int) {
        guard !isClosed,generation==previewMeasurementGeneration,
              revision==previewMeasurementRevision,markdownDocument.revision==revision,
              preview.preparedDocument === preparedDocument else{return}
        if source.isLiveResizeDragging {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.016) { [weak self] in
                self?.continuePreviewMeasurement(revision:revision,generation:generation,cursor:cursor)
            }
            return
        }
        let layoutID=preview.currentLayoutID
        guard let window=preparedDocument.measurementWindow(from:cursor,layoutID:layoutID,
            // Ultralight layout is non-preemptible on its thread. Keep each
            // background slice comfortably below a frame budget. Queued slices
            // are discarded by a new visible revision; at most this in-flight
            // slice can delay it.
            maximumBlocks:4) else {
            previewMeasurementRevision = -1
            completedPreviewMeasurementRevision=revision
            // Measurement refines retained offscreen geometry only. Replacing
            // the visible window here used to turn completion of background
            // work into a second, unrelated presentation after every edit.
            // The next navigation or scroll consumes the refined geometry.
            return
        }
        let expected=Dictionary(uniqueKeysWithValues:window.entries.map{($0.blockID,$0.contentVersion)})
        preview.measure(window.entries,revision:revision) { [weak self] layout in
            guard let self,!self.isClosed,generation==self.previewMeasurementGeneration,
                  revision==self.markdownDocument.revision,
                  self.preview.preparedDocument === self.preparedDocument else{return}
            guard let layout,layout.layoutID==self.preview.currentLayoutID,
                  self.preparedDocument.applyPreviewMeasurements(layout.measurements,revision:revision,
                    layoutID:layout.layoutID,expectedContentVersions:expected) != nil else {
                self.startPreviewMeasurement(revision:revision)
                return
            }
            self.preview.updateScrollbar()
            let next=NSMaxRange(window.range)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.002) { [weak self] in
                self?.continuePreviewMeasurement(revision:revision,generation:generation,cursor:next)
            }
        }
    }
    @objc func undo(_ sender:Any?) { markdownDocument.undoManager?.undo() }
    @objc func redo(_ sender:Any?) { markdownDocument.undoManager?.redo() }
    @objc func addComment(_ sender:Any?) {
        guard let selected=selectionForNewComment else{return}
        let draft=MarkdownComment(anchor:MarkdownComments.anchor(in:markdownDocument.source.string,selection:selected),
            author:"",created:"",body:"")
        presentCommentPopover(comment:draft,target:.new(selection:selected),
            relativeTo:source.commentPopoverAnchor(for:selected),of:source,focus:true)
    }
    private var canAddComment:Bool {selectionForNewComment != nil}
    private var selectionForNewComment:NSRange? {
        guard !source.textView.hasMarkedText(),let selection=source.commentSelection,
              selection.location>=0,NSMaxRange(selection)<=markdownDocument.source.count else{return nil}
        guard !comments.contains(where:{value in
            selection.length==0 ? NSLocationInRange(selection.location,value.recordRange)
                : NSIntersectionRange(selection,value.recordRange).length>0
        }) else{return nil}
        return selection
    }
    private func insertComment(body:String,selection:NSRange) {
        guard preparedDocument.revision==markdownDocument.revision else {
            // A just-typed line may not exist in the retained block map yet.
            // Queue the semantic action until that exact source revision has
            // been parsed; using the previous block would widen the selector
            // or place its record on the wrong side of the anchor.
            pendingCommentInsertion=(body,selection)
            pendingViewport=source.visibleSourceRange
            if !viewportScheduled {
                viewportScheduled=true
                DispatchQueue.main.async { [weak self] in self?.prepareViewport() }
            }
            return
        }
        let sourceText=markdownDocument.source.string
        let probe:NSRange
        if selection.length>0 {probe=selection}
        else if sourceText.isEmpty {probe=selection}
        else {probe=NSRange(location:min(selection.location,max(0,sourceText.utf16.count-1)),length:1)}
        let rendered=preparedDocument.entries(covering:probe) ?? []
        let comment=MarkdownComments.comment(in:sourceText,selection:selection,body:body,
            author:"",created:"",renderedEntries:rendered)
        var location=rendered.last?.fragment.to ?? NSMaxRange(selection)
        // Never insert one comment's metadata inside another live anchor. This
        // matters when a short line is commented inside a multi-block comment:
        // both records belong after the outer anchor, not between its blocks.
        for value in comments {
            guard let anchor=value.anchorRange,
                  location>anchor.location,
                  location<NSMaxRange(anchor) else{continue}
            location=NSMaxRange(anchor)
        }
        let insertion=MarkdownComments.insertion(for:comment,in:sourceText,at:location,newline:markdownDocument.newline)
        insertingCommentRecord=true
        markdownDocument.replace(NSRange(location:location,length:0),with:insertion,
            selection:selection,name:"Add Comment")
        insertingCommentRecord=false
        // Anchor metadata for an enclosing comment may already have a queued
        // refresh from the preceding keystroke. Publish one final parse after
        // this insertion so that stale refresh cannot hide the new record.
        DispatchQueue.main.async { [weak self] in self?.scheduleCommentRefresh(force:true) }
        // Prepare the relevant pane for the next explicit sidebar reveal, but
        // never change the user's sidebar visibility as a side effect.
        sidebar.showMode(.comments)
    }
    private func flushPendingCommentInsertionIfReady() {
        guard preparedDocument.revision==markdownDocument.revision,
              let pending=pendingCommentInsertion else{return}
        pendingCommentInsertion=nil
        insertComment(body:pending.body,selection:pending.selection)
    }
    private func scheduleCommentRefresh(insertedText:String="",force:Bool=false) {
        guard force || insertedText.contains(MarkdownComments.marker) else{return}
        commentRefreshGeneration &+= 1
        let generation=commentRefreshGeneration,revision=markdownDocument.revision,rope=markdownDocument.source
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let parsed=MarkdownComments.records(in:rope.string)
            DispatchQueue.main.async {
                guard let self,!self.isClosed,self.commentRefreshGeneration==generation else{return}
                guard self.markdownDocument.revision==revision else {
                    // Undo can restore a record and then change its anchor in
                    // the same group. If no newer scan was requested, retry
                    // against the final revision instead of losing the record.
                    self.scheduleCommentRefresh(force:true)
                    return
                }
                let reconciled=parsed.map {value -> ResolvedMarkdownComment in
                    guard let previous=self.comments.first(where:{old in
                        old.recordRange.location==value.recordRange.location ||
                            NSIntersectionRange(old.recordRange,value.recordRange).length>0
                    }) else{return value}
                    var comment=value.comment;comment.id=previous.comment.id
                    return ResolvedMarkdownComment(comment:comment,recordRange:value.recordRange,
                        anchorRange:value.anchorRange)
                }
                self.comments=reconciled
                if let presented=self.presentationRange,
                   presented.0==revision,
                   let entries=self.preparedDocument.entries(covering:presented.1) {
                    self.refreshRenderedCommentAnchors(in:entries,sourceText:rope.string)
                }
                self.sidebar.setComments(self.comments)
                self.source.setCommentRecordRanges(reconciled.map(\.recordRange))
                let active=reconciled.filter{$0.comment.status == .open}.compactMap(\.anchorRange)
                let selectedComment=self.selectedCommentID.flatMap {id in reconciled.first(where:{$0.comment.id==id})}
                if self.selectedCommentID != nil && selectedComment == nil {
                    self.selectedCommentID=nil
                }
                let selected=selectedComment.map {
                    $0.anchorRange ?? NSRange(location:min($0.comment.anchor.position ?? 0,self.markdownDocument.source.count),length:0)
                }
                let hoveredComment=self.hoveredCommentID.flatMap {id in reconciled.first(where:{$0.comment.id==id})}
                if self.hoveredCommentID != nil && hoveredComment == nil {
                    self.hoveredCommentID=nil;self.preview.previewView.setHoveredCommentID(nil)
                }
                let hovered=hoveredComment.map {
                    $0.anchorRange ?? NSRange(location:min($0.comment.anchor.position ?? 0,self.markdownDocument.source.count),length:0)
                }
                self.source.setCommentRanges(active);self.source.setSelectedCommentRange(selected)
                self.source.setHoveredCommentRange(hovered)
                self.preview.comments=self.comments;self.preview.selectedCommentID=self.selectedCommentID
                // Migrate verbose v3 selectors in place once their full range
                // has resolved. This is a bounded metadata replacement per
                // affected record; the surrounding Markdown is retained.
                let parsedSource=rope.string as NSString
                let verboseIDs=reconciled.compactMap {value -> String? in
                    let raw=parsedSource.substring(with:value.recordRange)
                    let canonical=MarkdownComments.serialize(value.comment,newline:self.markdownDocument.newline)
                    return canonical.contains(" ... ") && !raw.contains(" ... ") ? value.comment.id:nil
                }
                if !verboseIDs.isEmpty {
                    self.pendingCommentAnchorSyncIDs.formUnion(verboseIDs)
                    self.scheduleCommentAnchorSync()
                }
            }
        }
    }
    private func shiftResolvedComments(for edit:SourceEdit) {
        guard !comments.isEmpty else{return}
        let delta=edit.insertedLength-edit.range.length
        func shifted(_ range:NSRange)->NSRange? {
            if edit.range.length==0 {
                if edit.range.location<=range.location {
                    return NSRange(location:range.location+delta,length:range.length)
                }
                if edit.range.location>=NSMaxRange(range) {return range}
                return nil
            }
            if NSMaxRange(edit.range)<=range.location {
                return NSRange(location:range.location+delta,length:range.length)
            }
            if edit.range.location>=NSMaxRange(range) {return range}
            return nil
        }
        var dirty=[ResolvedMarkdownComment]()
        let currentSource=markdownDocument.source.string
        comments=comments.map {value in
            let record:NSRange
            if synchronizingCommentRecord,MarkdownComments.editTouchesAnchor(edit,anchor:value.recordRange) {
                record=NSRange(location:edit.range.location,length:edit.insertedLength)
            } else {record=shifted(value.recordRange) ?? value.recordRange}
            guard let anchor=value.anchorRange,
                  !MarkdownComments.editTouchesAnchor(edit,anchor:value.recordRange) else {
                return ResolvedMarkdownComment(comment:value.comment,recordRange:record,
                    anchorRange:value.anchorRange.flatMap(shifted))
            }
            let insertedBeforeAnchor:Bool
            if edit.range.length==0,edit.range.location==anchor.location,edit.insertedLength>0 {
                let inserted=currentSource as NSString
                let value=inserted.substring(with:NSRange(location:edit.range.location,
                    length:edit.insertedLength))
                insertedBeforeAnchor=value.hasSuffix("\n") || value.hasSuffix("\r")
            } else {insertedBeforeAnchor=false}
            let nextRange=insertedBeforeAnchor
                ? NSRange(location:anchor.location+edit.insertedLength,length:anchor.length)
                : MarkdownComments.transformedAnchorRange(anchor,through:edit)
            var comment=value.comment
            let anchorTextChanged = !comment.anchor.exact.isEmpty &&
                !insertedBeforeAnchor && MarkdownComments.editTouchesAnchor(edit,anchor:anchor)
            let oldGapStart=NSMaxRange(anchor)
            let oldGapEnd=max(oldGapStart,value.recordRange.location)
            let oldGap=NSRange(location:oldGapStart,length:oldGapEnd-oldGapStart)
            let gapChanged:Bool
            if edit.range.length==0 {
                gapChanged=edit.range.location>=oldGap.location &&
                    edit.range.location<=NSMaxRange(oldGap)
            } else {
                gapChanged=NSIntersectionRange(edit.range,oldGap).length>0 ||
                    edit.range.location==oldGap.location
            }
            let endpointContextChanged=comment.anchor.startExact != nil && gapChanged
            if anchorTextChanged || endpointContextChanged {
                let contextEnd=max(NSMaxRange(nextRange),record.location)
                let context=NSRange(location:nextRange.location,
                    length:contextEnd-nextRange.location)
                comment=MarkdownComments.updateAnchor(of:comment,to:nextRange,in:currentSource,
                    selectorContext:context)
            }
            let result=ResolvedMarkdownComment(comment:comment,recordRange:record,anchorRange:nextRange)
            if anchorTextChanged || endpointContextChanged {dirty.append(result)}
            return result
        }
        sidebar.setComments(comments)
        let active=comments.filter{$0.comment.status == .open}.compactMap(\.anchorRange)
        let selectedComment=selectedCommentID.flatMap {id in comments.first(where:{$0.comment.id==id})}
        let selected=selectedComment.map {
            $0.anchorRange ?? NSRange(location:min($0.comment.anchor.position ?? 0,markdownDocument.source.count),length:0)
        }
        let hovered=resolvedCommentRange(for:hoveredCommentID)
        source.setCommentRanges(active);source.setSelectedCommentRange(selected)
        source.setHoveredCommentRange(hovered)
        preview.comments=comments
        guard !synchronizingCommentRecord,!dirty.isEmpty else{return}
        pendingCommentAnchorSyncIDs.formUnion(dirty.map(\.comment.id))
        scheduleCommentAnchorSync()
    }
    private func scheduleCommentAnchorSync() {
        guard !commentAnchorSyncScheduled else{return}
        commentAnchorSyncScheduled=true
        // Native typing reaches this path from inside NSTextStorage's edit
        // transaction. Rewriting the adjacent record synchronously would
        // change the model without changing the still-open native storage.
        DispatchQueue.main.async { [weak self] in self?.flushCommentAnchorSync() }
    }
    private func flushCommentAnchorSync() {
        commentAnchorSyncScheduled=false
        guard !isClosed else {pendingCommentAnchorSyncIDs.removeAll();return}
        let ids=pendingCommentAnchorSyncIDs;pendingCommentAnchorSyncIDs.removeAll()
        // Keeping this derived edit outside the user's undo registration makes
        // one undo restore the prose while its record follows the inverse edit.
        let values=comments.filter{ids.contains($0.comment.id)}
            .sorted{$0.recordRange.location>$1.recordRange.location}
        for original in values {
            guard let value=comments.first(where:{$0.comment.id==original.comment.id}) else{continue}
            synchronizingCommentRecord=true
            markdownDocument.replaceMetadata(value.recordRange,
                with:MarkdownComments.serialize(value.comment,newline:markdownDocument.newline),
                selection:source.selection)
            synchronizingCommentRecord=false
        }
        source.setCommentRecordRanges(comments.map(\.recordRange))
        if !pendingCommentAnchorSyncIDs.isEmpty {scheduleCommentAnchorSync()}
    }
    private func revealComment(_ id:String,focusSource:Bool) {
        guard let comment=comments.first(where:{$0.comment.id==id}) else{return}
        let range=comment.anchorRange ?? NSRange(location:min(comment.comment.anchor.position ?? 0,markdownDocument.source.count),length:0)
        let sourceSelection=source.selection
        if sourceSelection.length>0 {
            source.textView.setSelectedRange(NSRange(location:NSMaxRange(sourceSelection),length:0))
        }
        selectedCommentID=id
        source.setSelectedCommentRange(range);preview.selectedCommentID=id
        source.reveal(range.location,alignment:.passiveReveal)
        if focusSource {window?.makeFirstResponder(source.textView)}
    }
    private func setCommentHover(_ id:String?) {
        guard id != hoveredCommentID else{return}
        hoveredCommentID=id
        source.setHoveredCommentRange(resolvedCommentRange(for:id))
        preview.previewView.setHoveredCommentID(id)
    }
    private func resolvedCommentRange(for id:String?)->NSRange? {
        id.flatMap {id in comments.first(where:{$0.comment.id==id})}.flatMap {value in
            value.anchorRange ?? NSRange(
                location:min(value.comment.anchor.position ?? 0,markdownDocument.source.count),length:0)
        }
    }
    private func clearCommentSelection() {
        finishCommentPopover(save:true)
        pendingCommentPopoverID=nil
        sidebar.deselectComment()
        selectedCommentID=nil;hoveredCommentID=nil
        preview.previewView.setHoveredCommentID(nil)
        source.setSelectedCommentRange(nil);source.setHoveredCommentRange(nil);preview.selectedCommentID=nil
    }
    private func openSidebarComment(_ id:String) {
        revealComment(id,focusSource:false)
        if let anchor=preview.selectedCommentAnchor {showCommentPopover(id:id,relativeTo:anchor)}
        else {pendingCommentPopoverID=id}
    }
    private func showCommentPopover(id:String,relativeTo anchor:NSRect) {
        guard let comment=comments.first(where:{$0.comment.id==id})?.comment else{return}
        presentCommentPopover(comment:comment,target:.existing(id:id),relativeTo:anchor,of:preview,focus:false)
    }
    private func presentCommentPopover(comment:MarkdownComment,target:CommentEditTarget,
        relativeTo anchor:NSRect,of positioningView:NSView,focus:Bool) {
        finishCommentPopover(save:true)
        let canDelete:Bool
        if case .existing = target {canDelete=true}else{canDelete=false}
        let controller=CommentPopoverViewController(comment:comment,focusOnShow:focus,canDelete:canDelete)
        controller.submit={ [weak self] in self?.finishCommentPopover(save:true) }
        controller.cancel={ [weak self] in self?.finishCommentPopover(save:false) }
        controller.delete={ [weak self] in self?.deleteCommentFromPopover() }
        let popover=NSPopover();popover.behavior = .applicationDefined;popover.animates=false;popover.delegate=self
        popover.contentViewController=controller
        commentPopover=popover;commentPopoverController=controller;commentEditTarget=target
        if case .existing(let id)=target {commentPopoverID=id}else{commentPopoverID=nil}
        hoveredCommentID=nil;preview.previewView.setHoveredCommentID(nil)
        source.setHoveredCommentRange(nil)
        pendingCommentPopoverID=nil
        popover.show(relativeTo:anchor,of:positioningView,preferredEdge:.minX)
        commentOutsideClickMonitor=NSEvent.addLocalMonitorForEvents(
            matching:[.leftMouseUp,.rightMouseUp,.otherMouseUp]) { [weak self,weak popover] event in
            guard let self,let popover,self.commentPopover === popover,popover.isShown else{return event}
            guard event.window !== popover.contentViewController?.view.window else{return event}
            // Defer until the click has reached its target. A comment-bubble
            // click replaces this popover synchronously; the identity check
            // then preserves the newly opened one. Every other outside click
            // closes the original popover after completing its normal action.
            self.scheduleCommentOutsideClick(popover)
            return event
        }
    }
    private func scheduleCommentOutsideClick(_ popover:NSPopover) {
        DispatchQueue.main.async { [weak self,weak popover] in
            guard let self,let popover,self.commentPopover === popover else{return}
            self.finishCommentPopover(save:true)
        }
    }
    private func finishCommentPopover(save:Bool,close:Bool=true) {
        guard !finishingCommentPopover,commentPopover != nil || commentEditTarget != nil else{return}
        finishingCommentPopover=true
        let popover=commentPopover,controller=commentPopoverController,target=commentEditTarget
        if let monitor=commentOutsideClickMonitor {NSEvent.removeMonitor(monitor)}
        commentOutsideClickMonitor=nil
        popover?.delegate=nil
        if close {popover?.close()}
        commentPopover=nil;commentPopoverController=nil;commentEditTarget=nil;commentPopoverID=nil
        finishingCommentPopover=false
        defer {
            hoveredCommentID=nil;preview.previewView.setHoveredCommentID(nil)
            source.setHoveredCommentRange(nil)
            if case .some(.existing(let id)) = target,id==selectedCommentID {
                selectedCommentID=nil
                source.setSelectedCommentRange(nil)
                preview.selectedCommentID=nil
            }
        }
        guard save,let target,let body=controller?.body else{return}
        switch target {
        case .new(let selection):
            guard !body.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return}
            insertComment(body:body,selection:selection)
        case .existing(let id):
            guard let resolved=comments.first(where:{$0.comment.id==id}),resolved.comment.body != body else{return}
            var comment=resolved.comment;comment.body=body
            let replacement=MarkdownComments.serialize(comment,newline:markdownDocument.newline)
            if let index=comments.firstIndex(where:{$0.comment.id==id}) {
                comments[index]=ResolvedMarkdownComment(comment:comment,recordRange:resolved.recordRange,
                    anchorRange:resolved.anchorRange)
            }
            synchronizingCommentRecord=true
            replaceCommentSource(resolved.recordRange,with:replacement,selection:source.selection,
                name:"Edit Comment")
            synchronizingCommentRecord=false
            source.setCommentRecordRanges(comments.map(\.recordRange))
        }
    }
    private func replaceCommentSource(_ range:NSRange,with replacement:String,
                                      selection:NSRange,name:String) {
        let undo=markdownDocument.undoManager
        // Comment commands are discrete UI actions. Close any implicit
        // TextKit event group left by the preceding source edit so comment
        // metadata never becomes part of that edit's "Typing" undo step.
        while let undo,undo.groupingLevel>0 {undo.endUndoGrouping()}
        undo?.beginUndoGrouping()
        markdownDocument.replace(range,with:replacement,selection:selection,
            undoSelection:selection,name:name)
        undo?.setActionName(name)
        undo?.endUndoGrouping()
    }
    private func deleteCommentFromPopover() {
        guard case .existing(let id)=commentEditTarget else{return}
        deleteComment(id,closingPopover:true)
    }
    private func deleteComment(_ id:String,closingPopover:Bool) {
        guard let resolved=comments.first(where:{$0.comment.id==id}) else{return}
        let text=markdownDocument.source.string as NSString
        let insertedRange=source.insertedSourceRange(forCommentRecord:resolved.recordRange)
        var range=insertedRange ?? resolved.recordRange
        let newline=markdownDocument.newline as NSString
        if insertedRange==nil,NSMaxRange(range)+newline.length<=text.length,
           text.substring(with:NSRange(location:NSMaxRange(range),length:newline.length))==markdownDocument.newline {
            range.length += newline.length
        }
        if closingPopover {finishCommentPopover(save:false)}
        pendingCommentPopoverID=nil;sidebar.deselectComment();selectedCommentID=nil
        hoveredCommentID=nil;preview.previewView.setHoveredCommentID(nil)
        source.setSelectedCommentRange(nil);source.setHoveredCommentRange(nil);preview.selectedCommentID=nil
        comments.removeAll{$0.comment.id==id};sidebar.setComments(comments)
        source.setCommentRanges(comments.filter{$0.comment.status == .open}.compactMap(\.anchorRange))
        preview.comments=comments
        let selection=source.selection
        replaceCommentSource(range,with:"",selection:selection,name:"Delete Comment")
        source.setCommentRecordRanges(comments.map(\.recordRange))
    }
    func popoverWillClose(_ notification:Notification) {
        guard notification.object as? NSPopover === commentPopover else{return}
        finishCommentPopover(save:true,close:false)
    }
    private func commentAnchorDidChange(_ anchor:NSRect?) {
        if let id=pendingCommentPopoverID,id==selectedCommentID,let anchor {
            showCommentPopover(id:id,relativeTo:anchor);return
        }
        moveCommentPopover(to:anchor)
    }
    private func moveCommentPopover(to anchor:NSRect?) {
        guard let popover=commentPopover,popover.isShown else{return}
        // New-comment editors are anchored to the source selection, not to a
        // preview bubble, so preview scrolling must not dismiss or move them.
        guard commentPopoverID != nil else{return}
        guard let anchor else {
            finishCommentPopover(save:true)
            return
        }
        guard commentPopoverID==selectedCommentID else{return}
        popover.show(relativeTo:anchor,of:preview,preferredEdge:.minX)
    }
    private func toggleCommentResolved(_ id:String) {
        deleteComment(id,closingPopover:false)
    }
    #if DEBUG
    func debugBeginAddComment(selection:NSRange) {
        source.textView.setSelectedRange(selection);addComment(nil)
    }
    var debugComments:[ResolvedMarkdownComment] {comments}
    var debugCommentPopoverView:NSView? {commentPopover?.contentViewController?.view}
    var debugCommentPopoverIsShown:Bool {commentPopover?.isShown == true}
    var debugCommentPopoverPositioningRect:NSRect? {commentPopover?.isShown == true ? commentPopover?.positioningRect:nil}
    var debugCommentPopoverText:String? {commentPopoverController?.body}
    var debugCommentPopoverEditorIsEditable:Bool {commentPopoverController?.editor.isEditable == true}
    var debugCommentPopoverCanDelete:Bool {commentPopoverController?.deleteButton.isHidden == false}
    var debugCommentPopoverEditorView:NSView? {commentPopoverController?.editor}
    var debugCommentPopoverTextContainerWidth:CGFloat? {
        commentPopoverController?.editor.textContainer?.containerSize.width
    }
    func debugSetCommentPopoverText(_ text:String) {
        guard let editor=commentPopoverController?.editor else{return}
        editor.setBody(text);editor.setSelectedRange(NSRange(location:text.utf16.count,length:0))
    }
    @discardableResult func debugPressCommentReturn(shift:Bool)->Bool {
        guard let editor=commentPopoverController?.editor,
              let event=NSEvent.keyEvent(with:.keyDown,location:.zero,
                modifierFlags:shift ? .shift:[],timestamp:0,windowNumber:window?.windowNumber ?? 0,
                context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)
        else{return false}
        editor.keyDown(with:event);return true
    }
    func debugClearCommentSelection() {clearCommentSelection()}
    func debugOpenCommentPopover(_ id:String) {
        revealComment(id,focusSource:false)
        let anchor=preview.selectedCommentAnchor ?? NSRect(x:8,y:16,width:20,height:20)
        showCommentPopover(id:id,relativeTo:anchor)
    }
    func debugScheduleCommentOutsideClick() {
        if let popover=commentPopover {scheduleCommentOutsideClick(popover)}
    }
    @discardableResult func debugDeleteCommentFromPopover()->Bool {
        guard debugCommentPopoverCanDelete else{return false}
        commentPopoverController?.deleteButton.performClick(nil);return true
    }
    func debugToggleCommentResolved(_ id:String) {toggleCommentResolved(id)}
    #endif
    @objc func performMarkdownCommand(_ sender:Any?) {
        guard let item=sender as? NSMenuItem,let menuCommand=MarkdownMenuCommand(rawValue:item.tag),
              canPerformMarkdownCommand else{return}
        if menuCommand == .insertImage {chooseImage();return}
        let command:MarkdownEditingCommand
        switch menuCommand {
        case .bold:command = .bold
        case .italic:command = .italic
        case .strikethrough:command = .strikethrough
        case .inlineCode:command = .inlineCode
        case .link:command = .link(destination:clipboardURL())
        case .heading1:command = .heading(1)
        case .heading2:command = .heading(2)
        case .heading3:command = .heading(3)
        case .heading4:command = .heading(4)
        case .heading5:command = .heading(5)
        case .heading6:command = .heading(6)
        case .paragraph:command = .paragraph
        case .bulletedList:command = .bulletedList
        case .numberedList:command = .numberedList
        case .blockquote:command = .blockquote
        case .insertTable:command = .table
        case .codeBlock:command = .codeBlock
        case .horizontalRule:command = .horizontalRule
        case .insertImage:return
        }
        apply(command)
    }
    private func apply(_ command:MarkdownEditingCommand) {
        guard let storage=source.textView.textStorage,
              let edit=MarkdownEditing.edit(command,in:storage.mutableString,
                selection:source.selection,newline:markdownDocument.newline) else{return}
        markdownDocument.replace(edit.range,with:edit.replacement,selection:edit.selection,name:edit.undoName)
        window?.makeFirstResponder(source.textView)
    }
    private var canPerformMarkdownCommand:Bool {
        guard !source.textView.hasMarkedText() else{return false}
        if let active=window?.firstResponder as? NSTextView,active !== source.textView {return false}
        return true
    }
    private func clipboardURL()->String? {
        let pasteboard=NSPasteboard.general
        let value=pasteboard.string(forType:.URL) ?? pasteboard.string(forType:.string)
        guard let trimmed=value?.trimmingCharacters(in:.whitespacesAndNewlines),!trimmed.isEmpty,
              !trimmed.contains(where:{$0.isWhitespace}),let components=URLComponents(string:trimmed),
              components.scheme?.isEmpty == false else{return nil}
        return trimmed
    }
    private func chooseImage() {
        let panel=NSOpenPanel()
        panel.allowedContentTypes=[.image];panel.allowsMultipleSelection=false
        panel.canChooseDirectories=false;panel.canChooseFiles=true
        panel.message="Choose an image to include in the Markdown document."
        let completion:@MainActor (NSApplication.ModalResponse)->Void = { [weak self] response in
            guard response == .OK,let self,let url=panel.url else{return}
            self.apply(.image(source:self.markdownImagePath(for:url)))
        }
        if let window {panel.beginSheetModal(for:window,completionHandler:completion)}
        else {panel.begin(completionHandler:completion)}
    }
    private func markdownImagePath(for imageURL:URL)->String {
        let image=imageURL.standardizedFileURL
        guard let documentURL=markdownDocument.fileURL?.standardizedFileURL else{return image.absoluteString}
        let base=documentURL.deletingLastPathComponent().pathComponents
        let target=image.pathComponents
        var common=0
        while common<base.count,common<target.count,base[common]==target[common] {common+=1}
        guard common>0 else{return image.absoluteString}
        return (Array(repeating:"..",count:base.count-common)+Array(target.dropFirst(common))).joined(separator:"/")
    }
    func toolbarAllowedItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier] {
        [Self.sidebarToolbarItem]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier] {
        [Self.sidebarToolbarItem]
    }
    func toolbar(_ toolbar:NSToolbar,itemForItemIdentifier identifier:NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag:Bool)->NSToolbarItem? {
        guard identifier==Self.sidebarToolbarItem else{return nil}
        let item=NSToolbarItem(itemIdentifier:identifier)
        item.isNavigational=true;item.autovalidates=false;item.isEnabled=true
        let button=NSButton(image:NSImage(systemSymbolName:"sidebar.left",accessibilityDescription:"Toggle Sidebar")!,
            target:self,action:#selector(toggleSidebar(_:)))
        button.imagePosition = .imageOnly;button.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .toolbar;button.isBordered=true
        button.showsBorderOnlyWhileMouseInside=true
        button.frame=NSRect(x:0,y:0,width:32,height:28)
        button.setAccessibilityLabel("Toggle Sidebar")
        item.view=button;item.target=self;item.action=#selector(toggleSidebar(_:))
        configureSidebarToolbarItem(item)
        return item
    }
    private func configureSidebarToolbarItem(_ item:NSToolbarItem) {
        let title=isSidebarVisible ? "Hide Sidebar":"Show Sidebar"
        item.label=title;item.paletteLabel="Sidebar";item.toolTip=title
        item.view?.toolTip=title
    }
    private func updateSidebarToolbarItem() {
        window?.toolbar?.items.first(where:{$0.itemIdentifier==Self.sidebarToolbarItem}).map(configureSidebarToolbarItem)
    }
    @objc func toggleSidebar(_ sender:Any?) {
        if !isSidebarVisible {
            sidebar.isHidden=false
            let maximum=max(180,workspaceSplit.bounds.width-480)
            workspaceSplit.setPosition(min(savedSidebarWidth,maximum),ofDividerAt:0)
            isSidebarVisible=true
        } else {
            savedSidebarWidth=max(180,sidebar.frame.width)
            workspaceSplit.setPosition(0,ofDividerAt:0)
            workspaceSplit.adjustSubviews()
            sidebar.isHidden=true
            isSidebarVisible=false
        }
        workspaceSplit.adjustSubviews();layoutContent();updateSidebarToolbarItem()
    }
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
        let hidden=source.hiddenCommentSourceRanges
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let text = rope.string as NSString
            let start = min(text.length,fromStart ? 0 : backwards ? selection.location : NSMaxRange(selection))
            let search = backwards ? NSRange(location:0,length:start) : NSRange(location:start,length:text.length-start)
            let options: NSString.CompareOptions = backwards ? [.caseInsensitive,.backwards] : [.caseInsensitive]
            func visibleMatch(in range:NSRange)->NSRange {
                var remaining=range
                while remaining.length>0 {
                    let match=text.range(of:query,options:options,range:remaining)
                    guard match.location != NSNotFound else{return match}
                    guard let folded=hidden.first(where:{NSIntersectionRange($0,match).length>0}) else{return match}
                    if backwards {
                        remaining.length=max(0,folded.location-remaining.location)
                    } else {
                        let end=NSMaxRange(remaining),start=min(end,NSMaxRange(folded))
                        remaining=NSRange(location:start,length:end-start)
                    }
                }
                return NSRange(location:NSNotFound,length:0)
            }
            var found=visibleMatch(in:search)
            if found.location == NSNotFound {found=visibleMatch(in:NSRange(location:0,length:text.length))}
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
        case #selector(toggleSidebar(_:)): menuItem.state = isSidebarVisible ? .on:.off; return true
        case #selector(togglePreview(_:)): menuItem.state = preview.isHidden ? .off : .on; return true
        case #selector(addComment(_:)): return canAddComment
        case #selector(performMarkdownCommand(_:)): return canPerformMarkdownCommand
        default:return true
        }
    }
}
