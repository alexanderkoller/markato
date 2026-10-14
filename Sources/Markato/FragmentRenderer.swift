import AppKit
import HTMLPreview
import MarkdownCore

private final class PreviewClipView:NSClipView {
    var rendererOrigin:CGFloat=0
    override func constrainBoundsRect(_ proposedBounds:NSRect)->NSRect {
        var bounds=super.constrainBoundsRect(proposedBounds)
        bounds.origin.y=rendererOrigin
        return bounds
    }
    func move(to origin:CGFloat) {
        rendererOrigin=origin
        scroll(to:NSPoint(x:bounds.minX,y:origin))
    }
}

/// The presentation surface owns the native and HTML-engine coordinates. Its
/// renderer may prepare ahead, while its native view retains the last committed
/// bitmap until the replacement is validated.
@MainActor private final class PreviewSurface {
    let clip=PreviewClipView()
    let canvas=FlippedView()
    let web:HTMLPreviewView
    private(set) var logicalOrigin:CGFloat=0
    private var localOrigin:CGFloat?
    private(set) var windowTop:CGFloat=0
    init(web:HTMLPreviewView) {
        self.web=web
        clip.drawsBackground=true;clip.backgroundColor = .textBackgroundColor
        clip.documentView=canvas;canvas.addSubview(web)
        web.isHidden=false
        web.setAccessibilityHidden(false)
        clip.isHidden=false
    }
    func size(contentHeight:CGFloat,windowTop:CGFloat=0,width:CGFloat,viewportHeight:CGFloat) {
        self.windowTop=windowTop
        // Keep the viewport-sized renderer's outer coordinate system fixed;
        // moving both the view and clip by `viewportHeight` caused AppKit to
        // visibly present that relocation during every live-resize frame.
        let frame=NSRect(x:0,y:logicalOrigin,width:max(1,width),height:max(1,viewportHeight))
        if web.frame != frame {web.frame=frame}
        let size=NSSize(width:max(1,width),height:max(viewportHeight,max(contentHeight,frame.maxY)))
        if canvas.frame.size != size {canvas.frame.size=size}
        clip.move(to:logicalOrigin)
    }
    func scroll(to origin:CGFloat,flush:Bool=false) {
        logicalOrigin=origin
        let local=max(0,origin-windowTop)
        web.setFrameOrigin(NSPoint(x:0,y:origin))
        clip.move(to:origin)
        if localOrigin.map({abs($0-local)>=0.01}) ?? true {
            localOrigin=local;web.scroll(to:NSPoint(x:0,y:local))
        }
        if flush {web.flush()}
    }
    func stageScroll(to origin:CGFloat) {
        logicalOrigin=origin
        let local=max(0,origin-windowTop)
        web.setFrameOrigin(NSPoint(x:0,y:origin))
        clip.move(to:origin)
        localOrigin=local
        web.stageScroll(to:NSPoint(x:0,y:local))
    }
}

@MainActor protocol ScrollSource:AnyObject {
    var contentRevision:Int {get}
    var hasMeasuredLayout:Bool {get}
    var geometryRevision:Int {get}
    var viewportOrigin:CGFloat {get}
    var contentHeight:CGFloat {get}
    var sourceLength:Int {get}
    var visibleSourceRange:NSRange {get}
    var alignmentAnchor:Int {get}
    func verticalPosition(for offset:Int)->CGFloat?
    func alignmentVerticalPosition(for offset:Int)->CGFloat?
}
@MainActor enum PreviewScrolling {
    case independent
    case synchronized(ScrollSource)
}
private struct PreviewContent:Equatable {
    let revision:Int
    let entries:[RenderedEntry]
    let sourceLength:Int
    let sourceRange:NSRange
    let previewTop:Double?
    let previewHeight:Double?
}
private struct PreviewRequest {
    let id:Int
    var content:PreviewContent
    let fontSize:CGFloat
    let baseURL:URL?
    let width:CGFloat
    var hasRetried=false
    var revision:Int {content.revision}
    var entries:[RenderedEntry] {content.entries}
}
private final class PreviewLoadingView:NSView {
    override func hitTest(_ point:NSPoint)->NSView? {nil}
}

private struct CommittedPresentation {
    let request:PreviewRequest
    let geometry:HTMLPreviewGeometry
    let map:ScrollLandmarks?
    let sourceGeometryRevision:Int?
    let viewportHeight:CGFloat
    let windowTop:CGFloat
    let totalHeight:CGFloat
    init(request:PreviewRequest,geometry:HTMLPreviewGeometry,map:ScrollLandmarks?,sourceGeometryRevision:Int?,viewportHeight:CGFloat,windowTop:CGFloat,totalHeight:CGFloat) {
        self.request=request;self.geometry=geometry
        self.map=map;self.sourceGeometryRevision=sourceGeometryRevision;self.viewportHeight=viewportHeight
        self.windowTop=windowTop;self.totalHeight=totalHeight
    }
}

/// Prepared scrolling reads one committed presentation and moves its native clip.
@MainActor final class PreviewPane:NSView {
    var preparedDocument:PreparedDocument?
    override var isFlipped:Bool {true}
    var scrolling:PreviewScrolling = .independent {didSet {sourceLayoutChanged()}}
    var openAnchor:((String)->Void)?
    var openComment:((String,NSView,NSRect)->Void)?
    var commentAnchorChanged:((NSRect?)->Void)?
    var fontSize:CGFloat=15 {didSet {if fontSize != oldValue {endScrollGesture();requestPresentation()}}}
    var baseURL:URL? {didSet {if baseURL != oldValue {endScrollGesture();requestPresentation()}}}
    var comments=[ResolvedMarkdownComment]() {
        // Comment resolution follows source edits. Moving the viewport here
        // would align the still-visible old preview bitmap against the new
        // source geometry, producing a large transient jump on every key.
        // If the parser has not published this source revision yet, wait: its
        // presentation will read the new comments. Repainting the previous
        // revision with shifted comment ranges creates exactly the stale-map
        // jump this guard avoids.
        didSet {
            if comments != oldValue,
               source == nil || content?.revision==source?.contentRevision {requestPresentation()}
        }
    }
    var selectedCommentID:String? {
        didSet {
            if selectedCommentID != oldValue {
                if selectedCommentID == nil {commentAnchorChanged?(nil)}
                endScrollGesture();requestPresentation()
            }
        }
    }
    private let surface:PreviewSurface
    private var web:HTMLPreviewView {surface.web}
    private var clip:NSClipView {surface.clip}
    private let loadingView=PreviewLoadingView()
    private let loadingLabel=NSTextField(labelWithString:"Loading preview…")
    #if DEBUG
    private var loadingWait:TimingDiagnostics.Interval?
    #endif
    private var committed:CommittedPresentation?
    private var content:PreviewContent?
    private var desired:PreviewRequest?
    private var rendering:PreviewRequest?
    private var independentOrigin:CGFloat=0
    // A preview-originated vertical gesture temporarily opts out of the
    // source-driven position without changing the configured relationship
    // between the panes. The source revision/origin at that moment tells us
    // when source movement or editing should restore synchronization.
    private var detachedSourceOrigin:CGFloat?
    private var detachedSourceRevision:Int?
    private var version=0,measuredSize:NSSize = .zero
    var resizeSession:ViewportResizeSession?
    private var failedParseRevision:Int?
    // A committed edit position remains stable until source movement begins.
    // Scroll entry points clear this value before applying the shared center
    // alignment function, preserving the established scrolling behavior.
    private var metadataPinnedOrigin:CGFloat?
    private var metadataPinnedSourceOrigin:CGFloat?
    private var inspector:NSWindowController?
    private(set) var isScrollMappingFrozen=false
    var presentationSettled:(()->Void)?
    private var source:ScrollSource? {
        switch scrolling {case .independent:return nil;case .synchronized(let source):return source}
    }
    private func clearResizePin() {resizeSession?.protectsViewport=false;resizeSession=nil}
    var lastRevision:Int {
        guard let committed,web.isEngineReady,desired==nil,content?.revision==committed.request.revision else{return -1}
        return committed.request.revision
    }
    var preparedFragmentCount:Int {committed?.request.entries.count ?? 0}
    var displayedDocumentRevision:Int {committed?.request.revision ?? -1}
    var displaysCompleteDocument:Bool {
        guard let content=committed?.request.content else{return false}
        return content.sourceRange.location==0 && NSMaxRange(content.sourceRange)>=content.sourceLength
    }
    var isPreparingPresentation:Bool {desired != nil}
    var isRenderingPresentation:Bool {rendering != nil}
    var displayedSourceRange:NSRange? {
        committed?.request.content.sourceRange
    }
    private func covers(_ content:PreviewContent,visible:NSRange)->Bool {
        // A complete first semantic block may follow leading blank source
        // lines. Those lines are already prepared and add no preview element.
        guard content.sourceRange.location<=visible.location,NSMaxRange(content.sourceRange)>=NSMaxRange(visible) else{return false}
        return !content.entries.contains {entry in
            entry.fragment.kind == .pending && (NSIntersectionRange(entry.fragment.range,visible).length>0 ||
                (visible.length==0 && entry.fragment.from<=visible.location && entry.fragment.to>visible.location))
        }
    }
    var coversSourceViewport:Bool {
        guard let committed else{return false}
        guard let source else{return true}
        guard source.hasMeasuredLayout,source.contentRevision==committed.request.revision else{return false}
        return covers(committed.request.content,visible:source.visibleSourceRange)
    }
    var needsWindowReplenishment:Bool {
        guard let committed,let source,source.hasMeasuredLayout else{return false}
        let sourceRange=committed.request.content.sourceRange
        let visibleSource=source.visibleSourceRange
        let visiblePreview=visibleWebRange
        // Begin replacing the bounded browser window while a substantial
        // rendered runway remains. At the sustained fast-scroll test rate this
        // covers the renderer's long-tail patch and paint latency without making the
        // mounted DOM depend on document length.
        let reserve=max(1,bounds.height)*12
        let needsBefore=sourceRange.location>0 && visibleSource.location>sourceRange.location
            && visiblePreview.lowerBound<reserve
        let needsAfter=NSMaxRange(sourceRange)<committed.request.content.sourceLength
            && NSMaxRange(visibleSource)<NSMaxRange(sourceRange)
            && visiblePreview.upperBound>committed.geometry.height-reserve
        return needsBefore || needsAfter
    }
    var needsWindowTrimming:Bool {
        guard let committed,committed.request.entries.count>1,bounds.height>1 else{return false}
        return committed.geometry.height>bounds.height*30
    }
    var isShowingLoadingState:Bool {!loadingView.isHidden}
    var clipOrigin:CGFloat {clip.bounds.minY}
    var previewView:HTMLPreviewView {web}
    var visibleWebRange:ClosedRange<CGFloat> {
        let top=surface.logicalOrigin-(committed?.windowTop ?? 0)
        return top...(top+bounds.height)
    }
    private var visiblePreviewRange:ClosedRange<CGFloat> {
        let top=(committed?.windowTop ?? 0)+visibleWebRange.lowerBound
        return top...(top+bounds.height)
    }
    #if DEBUG
    private(set) var patchCount=0
    private(set) var presentationFailureCount=0
    private(set) var retainedPresentationAfterFailure=true
    private(set) var crossRevisionCommitCount=0
    private(set) var pixelReuseCommitCount=0
    private(set) var committedFrameID=0
    var debugPresentationCommitted:(()->Void)?
    var debugResizeAnchorViewportY:CGFloat? {
        guard let committed,let id=resizeSession?.previewEntryID,
              let item=committed.geometry.items.first(where:{$0.id==id}) else{return nil}
        return committed.windowTop+item.y-surface.logicalOrigin
    }
    var debugResizePinnedOrigin:CGFloat? {resizeSession?.protectsViewport == true ? resizeSession?.previewOrigin:nil}
    var debugResizeAnchorState:String {
        guard let committed,let id=resizeSession?.previewEntryID,
              let item=committed.geometry.items.first(where:{$0.id==id}) else{return "missing"}
        return "item=\(item.y), window=\(committed.windowTop), origin=\(surface.logicalOrigin), width=\(committed.geometry.width), request=\(committed.request.width), frame=\(committedFrameID)"
    }
    private var debugFailsNextPresentation=false
    private var debugFailsNextPosition=false
    func debugFailNextPresentation() {debugFailsNextPresentation=true}
    func debugFailNextPosition() {debugFailsNextPosition=true}
    #endif
    override init(frame:NSRect) {
        surface=PreviewSurface(web:HTMLPreviewView(frame:.zero))
        super.init(frame:frame)
        wantsLayer=true;layer?.masksToBounds=true
        addSubview(surface.clip)
        loadingView.wantsLayer=true;loadingView.layer?.backgroundColor=NSColor.textBackgroundColor.cgColor
        loadingLabel.textColor = .secondaryLabelColor;loadingLabel.alignment = .center
        loadingView.addSubview(loadingLabel);addSubview(loadingView);loadingView.isHidden=true
        let view=surface.web
        view.viewportResized={ [weak self] in self?.viewportDidResize() }
        view.verticalWheel={ [weak self] event in self?.handleVerticalScroll(event) }
        view.openURL={ [weak self,weak view] url,anchor in
            if url.scheme?.lowercased()=="markato-comment" {
                let prefix="markato-comment:"
                let value=url.absoluteString.hasPrefix(prefix) ? String(url.absoluteString.dropFirst(prefix.count)):url.absoluteString
                guard let view else{return}
                self?.openComment?(value.removingPercentEncoding ?? value,view,anchor)
            } else if let fragment=url.fragment {self?.openAnchor?(fragment)}
            else if ["http","https","mailto"].contains(url.scheme?.lowercased() ?? "") {NSWorkspace.shared.open(url)}
        }
    }
    required init?(coder:NSCoder) {fatalError()}
    override func draw(_ dirtyRect:NSRect) {NSColor.textBackgroundColor.setFill();dirtyRect.fill()}
    func moveViewport() {
        if resizeSession?.protectsViewport == true {updateLoadingState();return}
        resumeSourceAlignmentIfNeeded()
        if let pinned=metadataPinnedSourceOrigin,let source,
           abs(source.viewportOrigin-pinned)>=0.01 {
            metadataPinnedOrigin=nil;metadataPinnedSourceOrigin=nil
        }
        place()
        updateLoadingState()
    }
    private var hasCurrentMap:Bool {
        guard let committed else{return false}
        guard let source else{return true}
        return source.hasMeasuredLayout && source.contentRevision==committed.request.revision &&
            (isScrollMappingFrozen || (source.geometryRevision==committed.sourceGeometryRevision && committed.viewportHeight==bounds.height))
    }
    private func updateLoadingState() {
        // Edits retain the previous complete presentation while its replacement
        // prepares. Movement still requires a map for the current revision.
        let hidden:Bool
        if resizeSession?.protectsViewport == true {hidden=committed != nil && web.isEngineReady}
        else if let source,failedParseRevision==source.contentRevision {hidden=committed != nil && web.isEngineReady}
        else if let source,!source.hasMeasuredLayout {hidden=committed != nil && web.isEngineReady}
        else {
            let replacingContent=source.map{$0.contentRevision != committed?.request.revision} == true
            // A revision change deliberately leaves the last complete bitmap
            // visible until its replacement commits. Coverage and map checks
            // only apply when positioning content from the current revision;
            // requiring them for stale content briefly exposed the loading
            // view on every edit.
            hidden=committed != nil && web.isEngineReady &&
                (replacingContent || (coversSourceViewport && hasCurrentMap))
        }
        #if DEBUG
        if !hidden,loadingWait==nil {loadingWait=TimingDiagnostics.shared.begin("preview.loading")}
        if hidden {TimingDiagnostics.shared.end(loadingWait);loadingWait=nil}
        #endif
        loadingView.isHidden=hidden
    }
    private func handleVerticalScroll(_ event:NSEvent) {
        metadataPinnedOrigin=nil;metadataPinnedSourceOrigin=nil
        switch scrolling {
        case .synchronized:
            scrollPreview(to:independentOrigin-event.scrollingDeltaY,detachFromSource:true)
        case .independent:
            scrollPreview(to:independentOrigin-event.scrollingDeltaY,detachFromSource:false)
        }
    }
    private func scrollPreview(to proposedOrigin:CGFloat,detachFromSource:Bool) {
        guard let committed else{return}
        clearResizePin()
        let origin=min(max(0,committed.totalHeight-bounds.height),max(0,proposedOrigin))
        guard abs(origin-independentOrigin)>=0.01 else{return}
        if detachFromSource,let source {
            detachedSourceOrigin=source.viewportOrigin
            detachedSourceRevision=source.contentRevision
        }
        independentOrigin=origin;place()
    }
    private func resumeSourceAlignmentIfNeeded() {
        guard let origin=detachedSourceOrigin,let revision=detachedSourceRevision,let source,
              source.contentRevision != revision || abs(source.viewportOrigin-origin)>=0.01 else{return}
        detachedSourceOrigin=nil;detachedSourceRevision=nil
    }
    private func resumeSourceAlignment() {
        detachedSourceOrigin=nil;detachedSourceRevision=nil
    }
    func scrollOverflow(_ event:NSEvent)->Bool {
        guard let source,source.contentHeight<=bounds.height+0.001,
              let committed,committed.totalHeight>bounds.height,
              abs(event.scrollingDeltaY)>=abs(event.scrollingDeltaX) else{return false}
        clearResizePin()
        metadataPinnedOrigin=nil;metadataPinnedSourceOrigin=nil
        independentOrigin=max(0,visibleWebRange.lowerBound-event.scrollingDeltaY);place();return true
    }
    func navigatePreview(toEnd:Bool) {
        guard let committed else{return}
        clearResizePin()
        resumeSourceAlignment()
        metadataPinnedOrigin=nil;metadataPinnedSourceOrigin=nil
        independentOrigin=toEnd ? max(0,committed.totalHeight-bounds.height):0;place()
    }
    func beginScrollGesture() {
        guard !isScrollMappingFrozen else{return}
        refreshMap()
        guard hasCurrentMap else{updateLoadingState();return}
        isScrollMappingFrozen=true
    }
    func endScrollGesture() {
        isScrollMappingFrozen=false;moveViewport();preparePresentation()
    }
    func sourceLayoutChanged() {
        if !isScrollMappingFrozen {moveViewport()}
        preparePresentation()
    }
    func invalidate() {
        failedParseRevision=nil
        clearResizePin()
        metadataPinnedOrigin=nil;metadataPinnedSourceOrigin=nil
        endScrollGesture();version += 1;content=nil;desired=nil;updateLoadingState()
    }
    func show(_ result:ParseResult) {
        let existing=Dictionary((content?.entries ?? []).map{($0.fragment.from,$0.blockID)},uniquingKeysWith:{first,_ in first})
        show(result.fragments.map{RenderedEntry(id:$0.id ?? existing[$0.from] ?? BlockID(UInt64.random(in:1...UInt64.max)),fragment:$0)},revision:result.revision)
    }
    func show(_ entries:[RenderedEntry],revision:Int,sourceRange:NSRange?=nil,previewTop:Double?=nil,previewHeight:Double?=nil) {
        failedParseRevision=nil
        let extent=source?.sourceLength ?? entries.last?.fragment.to ?? 0
        let covered=sourceRange ?? NSRange(location:entries.first?.fragment.from ?? 0,
            length:max(0,(entries.last?.fragment.to ?? extent)-(entries.first?.fragment.from ?? 0)))
        let next=PreviewContent(revision:revision,entries:entries,sourceLength:extent,sourceRange:covered,
            previewTop:previewTop,previewHeight:previewHeight)
        guard content != next || committed?.request.content != next else{updateLoadingState();return}
        if let committed,committed.request.revision != revision {
            // Every edit abandons resize anchoring and publishes a fresh
            // center-aligned map, even when the HTML pixels are unchanged.
            clearResizePin();endScrollGesture()
        }
        content=next;requestPresentation();updateLoadingState()
    }
    func showParseFailure(revision:Int) {failedParseRevision=revision;updateLoadingState()}
    func clearParseFailure() {failedParseRevision=nil;updateLoadingState()}
    private func requestPresentation() {
        guard let content else{return}
        version += 1
        let presented=PreviewContent(revision:content.revision,
            entries:MarkdownCommentHTML.decorate(content.entries,with:comments,selectedID:selectedCommentID),
            sourceLength:content.sourceLength,sourceRange:content.sourceRange,
            previewTop:content.previewTop,previewHeight:content.previewHeight)
        desired=PreviewRequest(id:version,content:presented,fontSize:fontSize,baseURL:baseURL,width:bounds.width)
        preparePresentation()
    }
    private func rendersSamePixels(_ request:PreviewRequest,as previous:PreviewRequest)->Bool {
        guard request.width==previous.width,request.fontSize==previous.fontSize,
              request.baseURL?.absoluteString==previous.baseURL?.absoluteString,
              request.entries.count==previous.entries.count else{return false}
        // IDs are parser/cache identity, not paint input. A trailing blank-line
        // edit can legitimately replace the adjacent block ID while producing
        // the same ordered HTML. The engine receives only this HTML (plus the
        // already-compared presentation settings), so the bitmap is unchanged.
        return zip(request.entries,previous.entries).allSatisfy {
            $0.fragment.html==$1.fragment.html
        }
    }
    private func reusedPixelPosition(_ request:PreviewRequest,from previous:CommittedPresentation)->PresentationPosition? {
        switch scrolling {
        case .independent:
            let origin=min(max(0,previous.totalHeight-bounds.height),max(0,surface.logicalOrigin))
            return PresentationPosition(map:nil,sourceGeometryRevision:nil,origin:origin,
                windowTop:previous.windowTop,totalHeight:previous.totalHeight)
        case .synchronized(let source):
            guard covers(request.content,visible:source.visibleSourceRange),
                  let map=makeMap(request,geometry:previous.geometry,windowTop:previous.windowTop,
                    totalHeight:previous.totalHeight) else{return nil}
            // An edit that leaves the rendered pixels unchanged is still an
            // edit. Keep the user's preview position instead of snapping it
            // back to the newly calculated source alignment.
            let origin=min(max(0,previous.totalHeight-bounds.height),
                max(0,surface.logicalOrigin))
            return PresentationPosition(map:map,sourceGeometryRevision:source.geometryRevision,origin:origin,
                windowTop:previous.windowTop,totalHeight:previous.totalHeight)
        }
    }
    private func measuredHeights(_ geometry:HTMLPreviewGeometry,for entries:[RenderedEntry])->[BlockID:Double] {
        guard geometry.items.count==entries.count else{return [:]}
        var heights=[BlockID:Double]();heights.reserveCapacity(entries.count)
        for index in geometry.items.indices {
            let item=geometry.items[index]
            let stride=index+1<geometry.items.count ? geometry.items[index+1].y-item.y:item.height+12
            heights[entries[index].blockID]=Double(max(item.height,stride))
        }
        return heights
    }
    private func preparePresentation() {
        // Source layout/viewport callbacks continue during a window drag and
        // may enqueue newer prepared windows. Coalesce them, but never render
        // a replacement while the committed bitmap and map are frozen.
        guard resizeSession?.isDragging != true,rendering==nil,var request=desired,
              request.width>0.5,bounds.height>0.5 else{return}
        guard request.entries.allSatisfy({$0.fragment.html != nil}),Set(request.entries.map(\.id)).count==request.entries.count else {
            NSLog("Preview request contains incomplete or duplicate fragments")
            return
        }
        if let previous=committed,web.isEngineReady,
           previous.request.revision != request.revision,rendersSamePixels(request,as:previous.request),
           let position=reusedPixelPosition(request,from:previous) {
            // Source ranges and the scroll map changed, but the mounted IDs and
            // HTML did not. Publishing the new metadata over the existing
            // bitmap avoids an unnecessary engine update and pixel copy.
            rendering=request
            // The parser may replace the adjacent block ID when its trailing
            // whitespace changes. Carry the already measured stride onto that
            // new identity so later window calculations do not regress to an
            // estimate and introduce a delayed correction.
            preparedDocument?.recordPreviewHeights(measuredHeights(previous.geometry,for:request.entries),
                revision:request.revision)
            metadataPinnedOrigin=position.origin
            metadataPinnedSourceOrigin=source?.viewportOrigin
            commit(request,geometry:previous.geometry,position:position,reusesPixels:true)
            finishPreparation(request)
            return
        }
        if committed?.request.revision != request.revision {
            metadataPinnedOrigin=nil;metadataPinnedSourceOrigin=nil
        }
        rendering=request
        surface.size(contentHeight:max(1,committed?.totalHeight ?? 0),windowTop:committed?.windowTop ?? 0,
            width:request.width,viewportHeight:bounds.height)
        #if DEBUG
        let roundtrip=TimingDiagnostics.shared.begin("html.presentation")
        patchCount += 1
        #endif
        guard isCurrent(request) else {
            finishPreparation(request);return
        }
        #if DEBUG
        if debugFailsNextPresentation {
            debugFailsNextPresentation=false
            surface.web.debugFailNextPresentation()
        }
        #endif
        guard let measured=web.prepare(request.entries,fontSize:request.fontSize,baseURL:request.baseURL) else {
            #if DEBUG
            presentationFailureCount += 1
            retainedPresentationAfterFailure = retainedPresentationAfterFailure &&
                (committed == nil || (committedFrameID>0 && loadingView.isHidden))
            #endif
            if !request.hasRetried,desired?.id==request.id {
                desired?.hasRetried=true
                finishPreparation(request,retry:true)
            } else {
                needsLayout=true
                finishPreparation(request)
            }
            return
        }
        let geometry=measured
        let heights=measuredHeights(geometry,for:request.entries)
        let extentChange=preparedDocument?.recordPreviewHeights(heights,revision:request.revision) ?? 0
        if extentChange != 0,let previewHeight=request.content.previewHeight {
            // The renderer has already measured every mounted block without
            // publishing its pending pixels.
            // Publish its corrected global extent in this first frame so an
            // inserted paragraph cannot trigger an estimate/measurement bounce.
            request.content=PreviewContent(revision:request.content.revision,
                entries:request.content.entries,sourceLength:request.content.sourceLength,
                sourceRange:request.content.sourceRange,previewTop:request.content.previewTop,
                previewHeight:previewHeight+extentChange)
            content=request.content
            desired=request
            rendering=request
        }
        guard let position=presentationPosition(request,geometry:geometry) else {
            // Source geometry or prepared coverage can legitimately lag the
            // final window frame by one callback. Keep the coherent old bitmap
            // and this desired request; source/viewport publication will retry.
            finishPreparation(request,keepDesired:true)
            return
        }
        surface.size(contentHeight:position.totalHeight,windowTop:position.windowTop,
            width:request.width,viewportHeight:bounds.height)
        surface.stageScroll(to:position.origin)
        guard web.capturePendingFrame(baseURL:request.baseURL,
            containsImages:request.entries.contains{$0.fragment.html?.contains("<img") == true}) else {
            #if DEBUG
            presentationFailureCount += 1
            retainedPresentationAfterFailure = retainedPresentationAfterFailure &&
                (committed == nil || (committedFrameID>0 && loadingView.isHidden))
            #endif
            finishPreparation(request,keepDesired:true)
            return
        }
        #if DEBUG
        TimingDiagnostics.shared.end(roundtrip,values:["mounted":Double(request.entries.count),"height":Double(geometry.height)])
        #endif
        let committed=commit(request,geometry:geometry,position:position)
        if !committed {web.discardPendingFrame()}
        finishPreparation(request,keepDesired:!committed)
    }
    private func isCurrent(_ request:PreviewRequest)->Bool {
        desired?.id==request.id && rendering?.id==request.id && web.isEngineReady
            && bounds.width==request.width && bounds.height>0.5
    }
    private func finishPreparation(_ request:PreviewRequest,retry:Bool=false,keepDesired:Bool=false) {
        guard rendering?.id==request.id else{return}
        rendering=nil
        if !retry,!keepDesired,desired?.id==request.id,coversSourceViewport {desired=nil}
        presentationSettled?()
        if desired?.id != request.id || retry {preparePresentation()}
    }
    private struct PresentationPosition {
        let map:ScrollLandmarks?
        let sourceGeometryRevision:Int?
        let origin:CGFloat
        let windowTop:CGFloat
        let totalHeight:CGFloat
    }
    private func previewExtent(_ request:PreviewRequest,_ geometry:HTMLPreviewGeometry)->(top:CGFloat,total:CGFloat) {
        guard let top=request.content.previewTop,let total=request.content.previewHeight else{return(0,geometry.height)}
        let height=max(geometry.height,CGFloat(total))
        if request.content.sourceRange.location==0 {return(0,height)}
        if NSMaxRange(request.content.sourceRange)>=request.content.sourceLength {
            return(max(0,height-geometry.height),height)
        }
        return (CGFloat(top)-(geometry.items.first?.y ?? 0),height)
    }
    private func targetOrigin(height:CGFloat,map:ScrollLandmarks?)->CGFloat? {
        if let session=resizeSession,session.protectsViewport {
            return min(max(0,height-bounds.height),max(0,session.previewOrigin))
        }
        if let metadataPinnedOrigin {
            return min(max(0,height-bounds.height),max(0,metadataPinnedOrigin))
        }
        let target:CGFloat
        switch scrolling {
        case .independent:target=independentOrigin
        case .synchronized(let source):
            if detachedSourceOrigin != nil || source.contentHeight<=bounds.height+0.001 {target=independentOrigin}
            else {
                guard let map,let origin=centerAlignedOrigin(height:height,map:map,source:source) else{return nil}
                return origin
            }
        }
        return min(max(0,height-bounds.height),max(0,target))
    }
    /// The single source of truth for center alignment. Ordinary scrolling and
    /// edit commits both map the source viewport through this exact function.
    private func centerAlignedOrigin(height:CGFloat,map:ScrollLandmarks,source:ScrollSource)->CGFloat? {
        guard let y=map.previewY(for:Double(source.viewportOrigin)) else{return nil}
        return min(max(0,height-bounds.height),max(0,CGFloat(y)))
    }
    private func resizeOrigin(geometry:HTMLPreviewGeometry,windowTop:CGFloat,totalHeight:CGFloat)->CGFloat? {
        guard let session=resizeSession,session.protectsViewport,
              let id=session.previewEntryID,
              let item=geometry.items.first(where:{$0.id==id}) else{return nil}
        return min(max(0,totalHeight-bounds.height),
            max(0,windowTop+item.y+session.previewDisplacement))
    }
    private func retainedEditOrigin(_ request:PreviewRequest,totalHeight:CGFloat)->CGFloat? {
        guard let previous=committed,previous.request.revision != request.revision else{return nil}
        return min(max(0,totalHeight-bounds.height),max(0,surface.logicalOrigin))
    }
    private func makeMap(_ request:PreviewRequest,geometry:HTMLPreviewGeometry,windowTop:CGFloat,totalHeight:CGFloat)->ScrollLandmarks? {
        #if DEBUG
        let work=TimingDiagnostics.shared.begin("preview.map")
        defer {TimingDiagnostics.shared.end(work)}
        #endif
        guard let source,source.hasMeasuredLayout,source.contentRevision==request.revision,source.sourceLength==request.content.sourceLength else{return nil}
        let revision=source.geometryRevision
        let landmarks=zip(geometry.items,request.entries).compactMap {item,entry -> (previewY:CGFloat,entry:RenderedEntry)? in
            guard entry.fragment.from != 0,entry.fragment.kind != .pending else{return nil}
            return (item.landmark ?? item.y,entry)
        }
        // A map must use one coordinate system throughout. Mixing locally exact
        // TextKit positions with retained estimates lets the monotonic map
        // reorder/clamp points after reflow, producing large visual offsets.
        // The browser window is bounded, so measure every mounted landmark.
        var points=[ScrollLandmark]()
        for landmark in landmarks {
            let offset=landmark.entry.fragment.from
            let y=source.alignmentVerticalPosition(for:offset)
            guard let y,y.isFinite else{return nil}
            points.append(ScrollLandmark(offset:offset,sourceY:Double(y),previewY:Double(windowTop+landmark.previewY)))
        }
        guard revision==source.geometryRevision else{return nil}
        // The first block starts at source offset zero and is represented by
        // the boundary that viewportMap adds. A one-block or empty document
        // therefore legitimately has no interior landmarks.
        return ScrollLandmarks(points).viewportMap(sourceHeight:Double(source.contentHeight),viewportHeight:Double(bounds.height),previewHeight:Double(totalHeight))
    }
    private func presentationPosition(_ request:PreviewRequest,geometry:HTMLPreviewGeometry)->PresentationPosition? {
        #if DEBUG
        if debugFailsNextPosition {debugFailsNextPosition=false;return nil}
        #endif
        let extent=previewExtent(request,geometry)
        switch scrolling {
        case .independent:
            guard let origin=resizeOrigin(geometry:geometry,windowTop:extent.top,totalHeight:extent.total) ??
                    targetOrigin(height:extent.total,map:nil) else{return nil}
            return PresentationPosition(map:nil,sourceGeometryRevision:nil,origin:origin,windowTop:extent.top,totalHeight:extent.total)
        case .synchronized(let source):
            guard covers(request.content,visible:source.visibleSourceRange) else{return nil}
            if resizeSession?.protectsViewport == true {
                guard let origin=resizeOrigin(geometry:geometry,windowTop:extent.top,totalHeight:extent.total) ??
                        targetOrigin(height:extent.total,map:nil) else{return nil}
                return PresentationPosition(map:nil,sourceGeometryRevision:source.geometryRevision,
                    origin:origin,windowTop:extent.top,totalHeight:extent.total)
            }
            guard let map=makeMap(request,geometry:geometry,windowTop:extent.top,totalHeight:extent.total) else{return nil}
            guard let origin=resizeOrigin(geometry:geometry,windowTop:extent.top,totalHeight:extent.total) ??
                    retainedEditOrigin(request,totalHeight:extent.total) ??
                    targetOrigin(height:extent.total,map:map) else{return nil}
            return PresentationPosition(map:map,sourceGeometryRevision:source.geometryRevision,origin:origin,windowTop:extent.top,totalHeight:extent.total)
        }
    }
    @discardableResult private func commit(_ request:PreviewRequest,geometry:HTMLPreviewGeometry,
        position:PresentationPosition,reusesPixels:Bool=false)->Bool {
        guard isCurrent(request) else{return false}
        if isScrollMappingFrozen,coversSourceViewport,!needsWindowReplenishment,
           committed?.request.revision==request.revision {return false}
        if let source {
            guard source.contentRevision==request.revision,position.sourceGeometryRevision==source.geometryRevision,
                  covers(request.content,visible:source.visibleSourceRange) else{return false}
        }
        let previousPresentation=committed
        #if DEBUG
        if let previousPresentation,previousPresentation.request.revision != request.revision {
            crossRevisionCommitCount += 1
            if reusesPixels {pixelReuseCommitCount += 1}
        }
        #endif
        let preservesEditOrigin=previousPresentation.map{$0.request.revision != request.revision} ?? false
        if preservesEditOrigin {
            metadataPinnedOrigin=position.origin
            metadataPinnedSourceOrigin=source?.viewportOrigin
        } else if !reusesPixels {metadataPinnedOrigin=nil;metadataPinnedSourceOrigin=nil}
        CATransaction.begin();CATransaction.setDisableActions(true)
        if !reusesPixels {
            guard web.publishPendingFrame() else {CATransaction.commit();return false}
            #if DEBUG
            committedFrameID += 1
            #endif
        }
        committed=CommittedPresentation(request:request,geometry:geometry,map:position.map,sourceGeometryRevision:position.sourceGeometryRevision,viewportHeight:bounds.height,windowTop:position.windowTop,totalHeight:position.totalHeight)
        desired=nil
        surface.size(contentHeight:position.totalHeight,windowTop:position.windowTop,width:request.width,viewportHeight:bounds.height)
        moveClip(to:position.origin)
        updateLoadingState()
        assert(!surface.clip.isHidden && !web.isHidden)
        CATransaction.commit()
        updateCommentAnchor(closeIfMissing:true)
        if let session=resizeSession,session.protectsViewport {
            session.previewOrigin=position.origin
        }
        #if DEBUG
        debugPresentationCommitted?()
        #endif
        return true
    }
    override func setFrameSize(_ size:NSSize) {
        if size != frame.size {endScrollGesture()}
        super.setFrameSize(size);needsLayout=true
    }
    override func layout() {
        #if DEBUG
        let resizeWork=TimingDiagnostics.shared.begin("preview.layout")
        defer {TimingDiagnostics.shared.end(resizeWork,values:["width":Double(bounds.width),"height":Double(bounds.height)])}
        #endif
        super.layout()
        surface.clip.frame=bounds
        loadingView.frame=bounds
        loadingLabel.frame=NSRect(x:16,y:max(0,(bounds.height-24)/2),width:max(0,bounds.width-32),height:24)
        loadingView.layer?.backgroundColor=NSColor.textBackgroundColor.cgColor
        let previousSize=measuredSize
        let widthChanged=previousSize.width != bounds.width
        measuredSize=bounds.size
        if widthChanged {endScrollGesture();requestPresentation()}
        if let committed {
            surface.size(contentHeight:committed.totalHeight,windowTop:committed.windowTop,
                width:bounds.width,viewportHeight:bounds.height)
        }
        if resizeSession?.protectsViewport != true {place()}
        updateCommentAnchor(closeIfMissing:false)
        preparePresentation()
    }
    func captureResizeAnchor()->(entryID:String?,displacement:CGFloat,origin:CGFloat) {
        web.flush()
        let origin=surface.logicalOrigin
        guard let committed else{return(nil,0,origin)}
        let local=origin-committed.windowTop
        let item=Array(zip(committed.request.entries,committed.geometry.items))
            .last(where:{$0.1.y<=local}) ??
            Array(zip(committed.request.entries,committed.geometry.items)).first
        return (item?.0.id,item.map{local-$0.1.y} ?? 0,origin)
    }
    func beginResize(_ session:ViewportResizeSession) {
        resizeSession=session
        metadataPinnedOrigin=nil;metadataPinnedSourceOrigin=nil
    }
    func finishResizeLayout() {
        guard let session=resizeSession,session.protectsViewport else{return}
        layoutSubtreeIfNeeded()
        if committed?.request.width != bounds.width {requestPresentation()}
        // The displayed engine has already reflowed to the final viewport
        // during the drag. If its semantic content is unchanged, publish its
        // new geometry and bitmap without remounting a second surface.
        let reused=reuseResizedPresentation()
        ResizeTrace.record(reused ? "preview.release.reused" : "preview.release.render",
            "width=\(bounds.width) committed=\(committed?.request.width ?? -1) desired=\(desired?.width ?? -1)")
        session.isDragging=false
        preparePresentation()
    }
    private func reuseResizedPresentation()->Bool {
        guard rendering==nil,let request=desired,let previous=committed,
              web.isEngineReady,
              request.content==previous.request.content,
              request.fontSize==previous.request.fontSize,
              request.baseURL==previous.request.baseURL,
              request.width==bounds.width,
              web.bounds.width==bounds.width else{return false}
        web.flush()
        guard let geometry=web.geometry(),
              abs(geometry.width-request.width)<1,
              geometry.items.map(\.id)==request.entries.map(\.id),
              let position=presentationPosition(request,geometry:geometry) else{return false}
        rendering=request
        let reused=commit(request,geometry:geometry,position:position,reusesPixels:true)
        finishPreparation(request,keepDesired:!reused)
        return reused
    }
    private func viewportDidResize() {
        guard let session=resizeSession,session.protectsViewport,
              let committed,let geometry=web.geometry() else{return}
        let extent=previewExtent(committed.request,geometry)
        if let id=session.previewEntryID,
           let item=geometry.items.first(where:{$0.id==id}) {
            session.previewOrigin=min(max(0,extent.total-bounds.height),
                max(0,extent.top+item.y+session.previewDisplacement))
        }
        let origin=session.previewOrigin
        surface.size(contentHeight:extent.total,windowTop:extent.top,
            width:bounds.width,viewportHeight:bounds.height)
        surface.scroll(to:origin)
        self.committed=CommittedPresentation(request:committed.request,geometry:geometry,
            map:committed.map,sourceGeometryRevision:committed.sourceGeometryRevision,
            viewportHeight:bounds.height,windowTop:extent.top,totalHeight:extent.total)
        updateCommentAnchor(closeIfMissing:false)
    }
    private func refreshMap() {
        guard let committed,let source,(committed.map == nil || committed.sourceGeometryRevision != source.geometryRevision || committed.viewportHeight != bounds.height) else{return}
        guard let map=makeMap(committed.request,geometry:committed.geometry,windowTop:committed.windowTop,totalHeight:committed.totalHeight) else{return}
        self.committed=CommittedPresentation(request:committed.request,geometry:committed.geometry,map:map,sourceGeometryRevision:source.geometryRevision,viewportHeight:bounds.height,windowTop:committed.windowTop,totalHeight:committed.totalHeight)
    }
    private func place() {
        guard let committed else{return}
        if let source,source.contentRevision != committed.request.revision {return}
        if !isScrollMappingFrozen {refreshMap()}
        guard hasCurrentMap,let current=self.committed,let origin=targetOrigin(height:current.totalHeight,map:current.map) else{return}
        moveClip(to:origin)
    }
    private func moveClip(to origin:CGFloat) {
        guard committed != nil else{return}
        CATransaction.begin();CATransaction.setDisableActions(true)
        surface.scroll(to:origin)
        independentOrigin=origin
        CATransaction.commit()
        updateCommentAnchor(closeIfMissing:false)
    }
    private func updateCommentAnchor(closeIfMissing:Bool) {
        guard selectedCommentID != nil,committed != nil else{return}
        guard let viewport=selectedCommentAnchor else {
            if closeIfMissing {commentAnchorChanged?(nil)}
            return
        }
        commentAnchorChanged?(bounds.intersects(viewport) ? viewport:nil)
    }
    var selectedCommentAnchor:NSRect? {
        guard committed != nil,let rect=web.elementRect(".markato-comment-bubble.is-selected") else{return nil}
        let viewport=NSRect(
            x:web.frame.minX-surface.clip.bounds.minX+rect.minX,
            y:web.frame.minY-surface.clip.bounds.minY+rect.minY,
            width:rect.width,height:rect.height)
        return viewport
    }
    #if DEBUG
    var debugIsIndependentlyScrolled:Bool {detachedSourceOrigin != nil}
    var debugSelectedCommentAnchor:NSRect? {selectedCommentAnchor}
    func debugScrollViewport(by delta:CGFloat) {
        metadataPinnedOrigin=nil;metadataPinnedSourceOrigin=nil
        scrollPreview(to:independentOrigin+delta,detachFromSource:source != nil)
    }
    var debugFirstHeadingViewportY:CGFloat? {
        guard committed != nil,let rect=web.debugRect("h1",containing:"Markato") else{return nil}
        return web.frame.minY-surface.clip.bounds.minY+rect.minY
    }
    func debugParagraphViewportY(containing text:String)->CGFloat? {
        guard committed != nil,let rect=web.debugRect("p",containing:text) else{return nil}
        return web.frame.minY-surface.clip.bounds.minY+rect.minY
    }
    func debugHeadingViewportY(containing text:String)->CGFloat? {
        guard committed != nil,
              let rect=web.debugRect("h1, h2, h3, h4, h5, h6",containing:text) else{return nil}
        return web.frame.minY-surface.clip.bounds.minY+rect.minY
    }
    var debugScrollMapError:CGFloat? {
        guard let committed,let source,let map=committed.map,
              let expected=map.previewY(for:Double(source.viewportOrigin)) else{return nil}
        return CGFloat(expected)-surface.logicalOrigin
    }
    func debugGeometry()->String {
        let visible=source?.visibleSourceRange
        let pendingVisible=committed?.request.content.entries.contains { entry in
            guard entry.fragment.kind == .pending,let visible else{return false}
            return NSIntersectionRange(entry.fragment.range,visible).length>0
        } ?? false
        return "mounted=\(preparedFragmentCount), height=\(committed?.geometry.height ?? 0), desired=\(String(describing:desired?.id)), rendering=\(String(describing:rendering?.id)), measuredSource=\(source?.hasMeasuredLayout == true), sourceRevision=\(source?.contentRevision ?? -1), displayedRevision=\(displayedDocumentRevision), pendingVisible=\(pendingVisible), mapCurrent=\(hasCurrentMap), uncommitted=\(web.hasUncommittedPresentation), failures=\(presentationFailureCount), frame=\(committedFrameID), clip=\(clipOrigin), patches=\(patchCount), displayed=\(String(describing:displayedSourceRange)), visible=\(String(describing:visible))"
    }
    #endif
    override func menu(for event:NSEvent)->NSMenu? {
        let menu=NSMenu();menu.addItem(withTitle:"Inspect Item",action:#selector(inspect(_:)),keyEquivalent:"").target=self;return menu
    }
    @objc private func inspect(_ sender:Any?) {
        guard let source,let f=committed?.request.entries.first(where:{$0.fragment.from<=source.alignmentAnchor && $0.fragment.to>=source.alignmentAnchor})?.fragment,f.kind != .pending else{return}
        _ = showInspector(for:f)
    }
    func showInspector(for fragment:PreviewFragment)->NSWindowController {
        precondition(fragment.html != nil && fragment.kind != .pending)
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:760,height:600),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        panel.title=fragment.kind == .table ? "Inspect Table":"Inspect Item"
        let pane=PreviewPane(frame:panel.contentRect(forFrameRect:panel.frame));pane.baseURL=baseURL;pane.fontSize=fontSize
        pane.show(ParseResult(revision:0,spans:[],fragments:[fragment]))
        panel.contentView=pane;panel.center()
        let controller=NSWindowController(window:panel);inspector=controller;controller.showWindow(nil)
        return controller
    }
}
