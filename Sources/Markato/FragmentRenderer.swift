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
    private var requestedLocalOrigin:CGFloat?
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
        let paintedOrigin=windowTop+(localOrigin ?? max(0,logicalOrigin-windowTop))
        let frame=NSRect(x:0,y:paintedOrigin,width:max(1,width),height:max(1,viewportHeight))
        if web.frame != frame {web.frame=frame}
        let size=NSSize(width:max(1,width),height:max(viewportHeight,max(contentHeight,frame.maxY)))
        if canvas.frame.size != size {canvas.frame.size=size}
        clip.move(to:logicalOrigin)
    }
    func scroll(to origin:CGFloat) {
        if abs(origin-logicalOrigin)<0.01 {
            clip.move(to:logicalOrigin)
            return
        }
        logicalOrigin=origin
        let local=max(0,origin-windowTop)
        clip.move(to:origin)
        if requestedLocalOrigin.map({abs($0-local)>=0.01}) ?? true {
            requestedLocalOrigin=local;web.scroll(to:NSPoint(x:0,y:local))
        }
    }
    func applyPaintedScroll(_ localOrigin:CGFloat) {
        self.localOrigin=localOrigin
        web.setFrameOrigin(NSPoint(x:0,y:windowTop+localOrigin))
    }
    var paintedViewportOffset:CGFloat {web.frame.minY-logicalOrigin}
    func publish(at origin:CGFloat,paintedLocalOrigin:CGFloat) {
        logicalOrigin=origin
        requestedLocalOrigin=max(0,origin-windowTop)
        let paintedOrigin=windowTop+paintedLocalOrigin
        localOrigin=paintedLocalOrigin
        web.setFrameOrigin(NSPoint(x:0,y:paintedOrigin))
        clip.move(to:origin)
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
    let expectedContentVersions:[BlockID:UInt64]
    init(id:Int,content:PreviewContent,fontSize:CGFloat,baseURL:URL?,width:CGFloat) {
        self.id=id;self.content=content;self.fontSize=fontSize;self.baseURL=baseURL;self.width=width
        expectedContentVersions=Dictionary(uniqueKeysWithValues:
            content.entries.map{($0.blockID,$0.contentVersion)})
    }
    var revision:Int {content.revision}
    var entries:[RenderedEntry] {content.entries}
    var layoutID:PreviewLayoutID {
        PreviewLayoutID(width:Double(width),fontSize:Double(fontSize),
            stylesheetGeneration:HTMLPreviewResources.stylesheetGeneration)
    }
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

private enum ViewportAnchor {
    case top
    case bottom
    case absolute(origin:CGFloat)
    case block(id:String,localY:CGFloat,viewportY:CGFloat,fallbackOrigin:CGFloat)
}

private enum PreviewActivity {
    case idle
    case scrolling
    case resizing(ViewportAnchor?)
}
private struct PendingPreviewFrame {
    let frame:HTMLPreviewFrame
    let request:PreviewRequest
}

/// Prepared scrolling reads one committed presentation and moves its native clip.
@MainActor final class PreviewPane:NSView {
    var preparedDocument:PreparedDocument?
    override var isFlipped:Bool {true}
    var scrolling:PreviewScrolling = .independent {didSet {
        // Replacing the scroll source is an explicit synchronization boundary;
        // an anchor captured for the previous source cannot survive it.
        idleAnchorLock=nil
        sourceLayoutChanged()
    }}
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
    private var inspector:NSWindowController?
    private var activity:PreviewActivity = .idle
    private var renderAnchor:ViewportAnchor?
    private var pendingFrame:PendingPreviewFrame?
    private var idleAnchorLock:ViewportAnchor?
    private var resourceSettlementGeneration=0
    var isScrollMappingFrozen:Bool {
        if case .scrolling=activity {return true};return false
    }
    var presentationSettled:(()->Void)?
    private var source:ScrollSource? {
        switch scrolling {case .independent:return nil;case .synchronized(let source):return source}
    }
    private func clearResizePin() {
        resizeSession?.protectsViewport=false;resizeSession=nil
        if case .resizing=activity {activity = .idle}
    }
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
    private(set) var committedFrameID=0
    private var debugResizeAnchor:ViewportAnchor?
    var debugPresentationCommitted:(()->Void)?
    var debugCommittedHTML:String {
        committed?.request.entries.compactMap(\.fragment.html).joined(separator:"\n") ?? ""
    }
    var debugResizeAnchorViewportY:CGFloat? {
        guard let committed,let anchor=debugResizeAnchor else{return nil}
        switch anchor {
        case .top:return -surface.logicalOrigin
        case .bottom:return committed.totalHeight-surface.logicalOrigin
        case .absolute(let origin):return origin-surface.logicalOrigin
        case .block(let id,let localY,_,_):
            guard let item=committed.geometry.items.first(where:{$0.id==id}) else{return nil}
            return committed.windowTop+item.y+min(max(0,localY),item.height)-surface.logicalOrigin
        }
    }
    var debugResizeAnchorState:String {
        guard let committed else{return "missing"}
        return "anchor=\(String(describing:debugResizeAnchor)), window=\(committed.windowTop), origin=\(surface.logicalOrigin), width=\(committed.geometry.width), request=\(committed.request.width), frame=\(committedFrameID)"
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
        view.engineReady={ [weak self] in self?.preparePresentation() }
        view.resourceFrame={ [weak self] frame in self?.receiveResourceFrame(frame) }
        view.scrollApplied={ [weak self] point in self?.surface.applyPaintedScroll(point.y) }
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
        place()
        updateLoadingState()
    }
    private var hasCurrentMap:Bool {
        guard let committed else{return false}
        guard let source else{return true}
        return source.hasMeasuredLayout && source.contentRevision==committed.request.revision &&
            source.geometryRevision==committed.sourceGeometryRevision && committed.viewportHeight==bounds.height
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
        idleAnchorLock=nil
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
        idleAnchorLock=nil
        independentOrigin=max(0,visibleWebRange.lowerBound-event.scrollingDeltaY);place();return true
    }
    func navigatePreview(toEnd:Bool) {
        guard let committed else{return}
        clearResizePin()
        resumeSourceAlignment()
        idleAnchorLock=nil
        independentOrigin=toEnd ? max(0,committed.totalHeight-bounds.height):0;place()
    }
    func beginScrollGesture() {
        // A resource-settlement anchor survives passive TextKit/AppKit clip
        // corrections. Only explicit navigation intent starts a new source to
        // preview alignment; inferring intent from a changed source origin
        // made an active insertion point able to release the anchor.
        idleAnchorLock=nil
        guard !isScrollMappingFrozen else{return}
        refreshMap()
        guard hasCurrentMap else{updateLoadingState();return}
        // Source scrolling owns the destination throughout momentum. Resource
        // frames are deferred, but must eventually be positioned from the
        // final source viewport rather than from where the gesture began.
        activity = .scrolling
        web.beginViewportGesture()
    }
    func endScrollGesture() {
        guard isScrollMappingFrozen else{return}
        web.endViewportGesture()
        activity = .idle
        if let pending=pendingFrame {
            pendingFrame=nil;commitDeferredFrame(pending,anchor:nil)
        }
        moveViewport();preparePresentation()
    }
    func sourceLayoutChanged() {
        if isScrollMappingFrozen {
            // TextKit refines retained source estimates while momentum is in
            // flight. Rebuild only the bounded mounted-window map so the
            // frozen preview presentation continues to track the live source.
            refreshMap();place()
        } else {moveViewport()}
        preparePresentation()
    }
    func invalidate() {
        failedParseRevision=nil
        clearResizePin()
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
        if let desired {preparedDocument?.setPreviewLayoutID(desired.layoutID)}
        preparePresentation()
    }
    private func preparePresentation() {
        guard resizeSession?.isDragging != true,!isScrollMappingFrozen,rendering==nil,let request=desired,web.isEngineReady,
              request.width>0.5,bounds.height>0.5 else{return}
        guard request.entries.allSatisfy({$0.fragment.html != nil}),Set(request.entries.map(\.id)).count==request.entries.count else {
            NSLog("Preview request contains incomplete or duplicate fragments")
            return
        }
        rendering=request
        let preservesExistingContent=committed.map{$0.request.revision != request.revision} ?? false
        renderAnchor=currentActivityAnchor() ?? idleAnchorLock ??
            (preservesExistingContent ? captureViewportAnchor():nil)
        #if DEBUG
        patchCount += 1
        if debugFailsNextPresentation {
            debugFailsNextPresentation=false
            surface.web.debugFailNextPresentation()
        }
        #endif
        let scale=max(1,window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
        let renderRequest=HTMLPreviewRenderRequest(token:request.id,revision:request.revision,
            layoutID:request.layoutID,entries:request.entries,fontSize:request.fontSize,baseURL:request.baseURL,
            viewportSize:NSSize(width:request.width,height:bounds.height),scale:scale,scrollPoint:.zero)
        web.requestLayout(renderRequest) { [weak self] layout in self?.receiveLayout(layout,for:request) }
    }
    private func receiveLayout(_ layout:HTMLPreviewLayout?,for original:PreviewRequest) {
        guard var request=rendering,request.id==original.id else{return}
        guard isCurrent(request) else {web.discard(nil);finishPreparation(original);return}
        guard let layout else {failPreparation(original);return}
        guard layout.token==request.id,layout.revision==request.revision,layout.layoutID==request.layoutID else {
            failPreparation(original);return
        }
        guard applyMeasurements(layout.measurements,to:&request) else {
            failPreparation(original);return
        }
        guard let position=presentationPosition(request,geometry:layout.geometry,anchor:renderAnchor) else {
            failPreparation(original);return
        }
        rendering=request;desired=request
        let local=max(0,position.origin-position.windowTop)
        web.capture(token:request.id,scrollPoint:NSPoint(x:0,y:local)) { [weak self] frame in
            self?.receiveCapturedFrame(frame,request:request,position:position)
        }
    }
    private func receiveCapturedFrame(_ frame:HTMLPreviewFrame?,request original:PreviewRequest,
        position originalPosition:PresentationPosition) {
        guard var request=rendering,request.id==original.id else{return}
        guard isCurrent(request) else {web.discard(frame);finishPreparation(original);return}
        guard let frame,frame.token==request.id,frame.revision==request.revision,
              frame.layoutID==request.layoutID else {failPreparation(original);return}
        guard applyMeasurements(frame.measurements,to:&request),
              let position=presentationPosition(request,geometry:frame.geometry,anchor:renderAnchor) else {
            web.discard(frame);failPreparation(original);return
        }
        // Resource completion between layout and capture can alter the desired
        // local scroll point. Settle that deterministic race before publishing.
        let oldLocal=max(0,originalPosition.origin-originalPosition.windowTop)
        let newLocal=max(0,position.origin-position.windowTop)
        if abs(oldLocal-newLocal)>=0.5 {
            rendering=request;desired=request
            web.capture(token:request.id,scrollPoint:NSPoint(x:0,y:newLocal)) { [weak self] settled in
                self?.receiveSettledFrame(settled,request:request)
            }
            return
        }
        finishCapturedFrame(frame,request:request,position:position)
    }
    private func receiveSettledFrame(_ frame:HTMLPreviewFrame?,request original:PreviewRequest) {
        guard var request=rendering,request.id==original.id else{return}
        guard isCurrent(request) else {web.discard(frame);finishPreparation(original);return}
        guard let frame,applyMeasurements(frame.measurements,to:&request),
              let position=presentationPosition(request,geometry:frame.geometry,anchor:renderAnchor) else {
            failPreparation(original);return
        }
        finishCapturedFrame(frame,request:request,position:position)
    }
    private func finishCapturedFrame(_ frame:HTMLPreviewFrame,request:PreviewRequest,position:PresentationPosition) {
        if isScrollMappingFrozen || resizeSession?.isDragging == true {
            pendingFrame=PendingPreviewFrame(frame:frame,request:request);web.discard(frame)
            finishPreparation(request);return
        }
        let previousRevision=committed?.request.revision
        let accepted=commit(request,frame:frame,position:position)
        if accepted,previousRevision != nil,previousRevision != request.revision,
           source != nil,let anchor=captureViewportAnchor() {
            idleAnchorLock=anchor
        }
        if !accepted {web.discard(frame)}
        finishPreparation(request,keepDesired:!accepted)
    }
    private func applyMeasurements(_ measurements:[PreviewBlockMeasurement],to request:inout PreviewRequest,
        updatePresentationState:Bool=true)->Bool {
        let delta:Double
        if let preparedDocument {
            guard let value=preparedDocument.applyPreviewMeasurements(measurements,revision:request.revision,
                layoutID:request.layoutID,expectedContentVersions:request.expectedContentVersions) else{return false}
            delta=value
        } else {delta=0}
        if delta != 0,let height=request.content.previewHeight {
            request.content=PreviewContent(revision:request.content.revision,entries:request.content.entries,
                sourceLength:request.content.sourceLength,sourceRange:request.content.sourceRange,
                previewTop:request.content.previewTop,previewHeight:height+delta)
            if let base=content,base.revision==request.revision {
                content=PreviewContent(revision:base.revision,entries:base.entries,sourceLength:base.sourceLength,
                    sourceRange:base.sourceRange,previewTop:base.previewTop,
                    previewHeight:base.previewHeight.map{$0+delta})
            }
            if updatePresentationState {desired=request;rendering=request}
        }
        return true
    }
    private func failPreparation(_ request:PreviewRequest) {
        guard rendering?.id==request.id else{return}
        #if DEBUG
        presentationFailureCount += 1
        retainedPresentationAfterFailure = retainedPresentationAfterFailure &&
            (committed == nil || (committedFrameID>0 && loadingView.isHidden))
        #endif
        web.discard(nil);desired=nil;rendering=nil;renderAnchor=nil;presentationSettled?()
    }
    private func receiveResourceFrame(_ frame:HTMLPreviewFrame) {
        guard let committed,frame.cause == .resource,
              frame.token==committed.request.id,frame.revision==committed.request.revision,
              frame.layoutID==committed.request.layoutID else{return}
        var request:PreviewRequest
        if let pendingFrame,pendingFrame.frame.cause == .resource,
           pendingFrame.request.id==frame.token {request=pendingFrame.request}
        else {request=committed.request}
        rebaseResourceExtent(&request)
        guard applyMeasurements(frame.measurements,to:&request,updatePresentationState:false) else{return}
        let pending=PendingPreviewFrame(frame:frame,request:request)
        switch activity {
        case .idle:
            settleResourceFrame(pending,alignToSource:frame.createdDuringViewportGesture)
        case .scrolling,.resizing:
            pendingFrame=pending
        }
    }
    private func rebaseResourceExtent(_ request:inout PreviewRequest) {
        guard let current=content,current.revision==request.revision else{return}
        request.content=PreviewContent(revision:request.content.revision,entries:request.content.entries,
            sourceLength:request.content.sourceLength,sourceRange:request.content.sourceRange,
            previewTop:current.previewTop,previewHeight:current.previewHeight)
    }
    /// The retained tree and the browser geometry change together. If content
    /// above the viewport grew by `delta`, adding `delta` to the document-
    /// relative scroll offset keeps every visible point at the same screen Y.
    private func resourceScrollDelta(from previous:CommittedPresentation,to request:PreviewRequest,
        geometry:HTMLPreviewGeometry,origin oldOrigin:CGFloat,
        flowDisplacements:[HTMLPreviewFlowDisplacement])->CGFloat {
        if oldOrigin<=0.5 {return 0}
        let newExtent=previewExtent(request,geometry)
        let local=oldOrigin-previous.windowTop
        guard let oldIndex=previous.geometry.items.firstIndex(where:{$0.y+$0.height>local+0.01}) ??
                previous.geometry.items.indices.last else{return 0}
        let oldItem=previous.geometry.items[oldIndex]
        if !flowDisplacements.isEmpty {
            let exact=flowDisplacements.lazy.filter{$0.firstShiftedIndex<=oldIndex}.reduce(CGFloat(0)){$0+$1.delta}
            return (newExtent.top-previous.windowTop)+exact
        }
        guard
              let newItem=geometry.items.first(where:{$0.id==oldItem.id}) else{return 0}
        return (newExtent.top+newItem.y)-(previous.windowTop+oldItem.y)
    }
    private func settleResourceFrame(_ pending:PendingPreviewFrame,alignToSource:Bool=false) {
        guard let committed else{return}
        var request=pending.request
        rebaseResourceExtent(&request)
        guard preparedDocument?.revision==nil || preparedDocument?.revision==request.revision,
              applyMeasurements(pending.frame.measurements,to:&request,updatePresentationState:false) else{return}
        // Geometry compensation is expressed in the exact logical document
        // coordinate. Ultralight's quantized applied scroll is used only to
        // mount the captured bitmap; using it here would discard the native
        // fractional residual on every resource-driven relayout.
        let anchorOrigin=surface.logicalOrigin
        let delta=resourceScrollDelta(from:committed,to:request,
            geometry:pending.frame.geometry,origin:anchorOrigin,
            flowDisplacements:pending.frame.flowDisplacements)
        let baseOrigin=surface.logicalOrigin
        guard let position=presentationPosition(request,geometry:pending.frame.geometry,
            anchor:alignToSource ? nil:.absolute(origin:anchorOrigin+delta)) else{return}
        resourceSettlementGeneration += 1
        captureSettledResource(request:request,targetOrigin:position.origin,alignToSource:alignToSource,
            flowDisplacements:pending.frame.flowDisplacements,
            changedBlocks:Set(pending.frame.measurements.map(\.blockID)),baseOrigin:baseOrigin,
            requestedPosition:position,generation:resourceSettlementGeneration)
    }
    private func captureSettledResource(request original:PreviewRequest,targetOrigin:CGFloat,alignToSource:Bool,
        flowDisplacements:[HTMLPreviewFlowDisplacement],changedBlocks:Set<BlockID>,
        baseOrigin:CGFloat,requestedPosition:PresentationPosition,generation:Int) {
        let local=max(0,requestedPosition.origin-requestedPosition.windowTop)
        web.captureResource(token:original.id,scrollPoint:NSPoint(x:0,y:local)) { [weak self] frame in
            guard let self,let committed=self.committed,
                  generation==self.resourceSettlementGeneration,
                  committed.request.id==original.id,committed.request.revision==original.revision,
                  let frame,frame.token==original.id,frame.revision==original.revision,
                  frame.layoutID==original.layoutID else{return}
            var request=original
            guard self.applyMeasurements(frame.measurements,to:&request,updatePresentationState:false) else{return}
            let currentBase=self.surface.logicalOrigin
            if abs(currentBase-baseOrigin)>=0.01 {
                guard let currentPosition=self.presentationPosition(request,geometry:frame.geometry,
                    anchor:alignToSource ? nil:.absolute(origin:currentBase+self.resourceScrollDelta(
                        from:committed,to:request,geometry:frame.geometry,origin:currentBase,
                        flowDisplacements:flowDisplacements))) else{return}
                self.captureSettledResource(request:request,targetOrigin:currentPosition.origin,
                    alignToSource:alignToSource,
                    flowDisplacements:flowDisplacements,changedBlocks:changedBlocks,
                    baseOrigin:currentBase,requestedPosition:currentPosition,generation:generation)
                return
            }
            guard let position=self.presentationPosition(request,geometry:frame.geometry,
                anchor:.absolute(origin:targetOrigin)) else{return}
            let settledLocal=max(0,position.origin-position.windowTop)
            if abs(settledLocal-local)>=0.5 {
                self.captureSettledResource(request:request,targetOrigin:targetOrigin,alignToSource:alignToSource,
                    flowDisplacements:flowDisplacements,changedBlocks:changedBlocks,baseOrigin:baseOrigin,
                    requestedPosition:position,generation:generation)
                return
            }
            if self.isScrollMappingFrozen || self.resizeSession?.isDragging == true {
                self.pendingFrame=PendingPreviewFrame(frame:frame,request:request)
                return
            }
            let preservePixels=self.resourceChangesAreOutsideViewport(
                previous:committed,changedBlocks:changedBlocks)
            guard self.commit(request,frame:frame,position:position,requiresCurrent:false,
                preservePixels:preservePixels) else{return}
            if self.source != nil,!alignToSource {
                self.idleAnchorLock = .absolute(origin:position.origin)
            }
        }
    }
    private func commitDeferredFrame(_ pending:PendingPreviewFrame,anchor:ViewportAnchor?) {
        if pending.frame.cause == .resource {
            settleResourceFrame(pending,alignToSource:true)
            return
        }
        var request=pending.request
        guard preparedDocument?.revision==nil || preparedDocument?.revision==request.revision,
              applyMeasurements(pending.frame.measurements,to:&request),
              let position=presentationPosition(request,geometry:pending.frame.geometry,anchor:anchor) else{return}
        _=commit(request,frame:pending.frame,position:position,requiresCurrent:false)
    }
    private func resourceChangesAreOutsideViewport(previous:CommittedPresentation,
        changedBlocks:Set<BlockID>)->Bool {
        guard !changedBlocks.isEmpty else{return false}
        let top=surface.logicalOrigin-previous.windowTop
        let bottom=top+bounds.height
        let changed=zip(previous.request.entries,previous.geometry.items).filter {
            changedBlocks.contains($0.0.blockID)
        }
        return !changed.isEmpty && changed.allSatisfy {
            $0.1.y+$0.1.height<=top+0.01 || $0.1.y>=bottom-0.01
        }
    }
    private func isCurrent(_ request:PreviewRequest)->Bool {
        desired?.id==request.id && rendering?.id==request.id && web.isEngineReady
            && bounds.width==request.width && bounds.height>0.5
    }
    private func finishPreparation(_ request:PreviewRequest,keepDesired:Bool=false) {
        guard rendering?.id==request.id else{return}
        rendering=nil;renderAnchor=nil
        if !keepDesired,desired?.id==request.id,coversSourceViewport {desired=nil}
        presentationSettled?()
        if desired?.id != request.id {preparePresentation()}
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
    private func currentActivityAnchor()->ViewportAnchor? {
        switch activity {
        case .idle:return nil
        case .scrolling:return nil
        case .resizing(let anchor):return anchor
        }
    }
    private func captureViewportAnchor()->ViewportAnchor? {
        guard let committed else{return nil}
        let origin=surface.logicalOrigin,end=max(0,committed.totalHeight-bounds.height)
        if origin<=0.5 {return .top}
        if abs(origin-end)<=0.5 {return .bottom}
        guard origin>=committed.windowTop,
              origin<=committed.windowTop+committed.geometry.height else {
            return .absolute(origin:origin)
        }
        let local=origin-committed.windowTop
        guard let item=committed.geometry.items.first(where:{$0.y+$0.height>=local}) ?? committed.geometry.items.last else{return nil}
        let point=min(max(0,local-item.y),item.height)
        return .block(id:item.id,localY:point,viewportY:committed.windowTop+item.y+point-origin,
            fallbackOrigin:origin)
    }
    private func resolvedOrigin(_ anchor:ViewportAnchor?,geometry:HTMLPreviewGeometry,
        windowTop:CGFloat,totalHeight:CGFloat)->CGFloat? {
        guard let anchor else{return nil}
        let end=max(0,totalHeight-bounds.height)
        switch anchor {
        case .top:return 0
        case .bottom:return end
        case .absolute(let origin):return min(end,max(0,origin))
        case .block(let id,let localY,let viewportY,let fallbackOrigin):
            guard let item=geometry.items.first(where:{$0.id==id}) else{return min(end,max(0,fallbackOrigin))}
            let point=min(max(0,localY),item.height)
            return min(end,max(0,windowTop+item.y+point-viewportY))
        }
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
            return (item.y+(item.landmark ?? 0),entry)
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
    private func presentationPosition(_ request:PreviewRequest,geometry:HTMLPreviewGeometry,
        anchor:ViewportAnchor?=nil)->PresentationPosition? {
        #if DEBUG
        if debugFailsNextPosition {debugFailsNextPosition=false;return nil}
        #endif
        let extent=previewExtent(request,geometry)
        switch scrolling {
        case .independent:
            guard let origin=resolvedOrigin(anchor,geometry:geometry,windowTop:extent.top,totalHeight:extent.total) ??
                    targetOrigin(height:extent.total,map:nil) else{return nil}
            return PresentationPosition(map:nil,sourceGeometryRevision:nil,origin:origin,windowTop:extent.top,totalHeight:extent.total)
        case .synchronized(let source):
            guard covers(request.content,visible:source.visibleSourceRange) else{return nil}
            guard let map=makeMap(request,geometry:geometry,windowTop:extent.top,totalHeight:extent.total) else{return nil}
            guard let origin=resolvedOrigin(anchor,geometry:geometry,windowTop:extent.top,totalHeight:extent.total) ??
                    targetOrigin(height:extent.total,map:map) else{return nil}
            return PresentationPosition(map:map,sourceGeometryRevision:source.geometryRevision,origin:origin,windowTop:extent.top,totalHeight:extent.total)
        }
    }
    @discardableResult private func commit(_ request:PreviewRequest,frame:HTMLPreviewFrame,
        position:PresentationPosition,requiresCurrent:Bool=true,preservePixels:Bool=false)->Bool {
        if requiresCurrent {guard isCurrent(request) else{return false}}
        guard frame.token==request.id,frame.revision==request.revision,frame.layoutID==request.layoutID else{return false}
        if isScrollMappingFrozen,coversSourceViewport,!needsWindowReplenishment,
           committed?.request.revision==request.revision {return false}
        if let source {
            guard source.contentRevision==request.revision,position.sourceGeometryRevision==source.geometryRevision,
                  covers(request.content,visible:source.visibleSourceRange) else{return false}
        }
        #if DEBUG
        if let previousPresentation=committed,previousPresentation.request.revision != request.revision {
            crossRevisionCommitCount += 1
        }
        #endif
        CATransaction.begin();CATransaction.setDisableActions(true)
        let previousPaintedOffset=surface.paintedViewportOffset
        let nextPaintedOffset=position.windowTop+frame.scrollPoint.y-position.origin
        web.publish(frame,preservePixels:preservePixels,
            preservedImageOffsetY:preservePixels ? previousPaintedOffset-nextPaintedOffset:0)
        #if DEBUG
        committedFrameID += 1
        #endif
        committed=CommittedPresentation(request:request,geometry:frame.geometry,map:position.map,sourceGeometryRevision:position.sourceGeometryRevision,viewportHeight:bounds.height,windowTop:position.windowTop,totalHeight:position.totalHeight)
        desired=nil
        surface.size(contentHeight:position.totalHeight,windowTop:position.windowTop,width:request.width,viewportHeight:bounds.height)
        surface.publish(at:position.origin,paintedLocalOrigin:frame.scrollPoint.y)
        independentOrigin=position.origin
        updateLoadingState()
        assert(!surface.clip.isHidden && !web.isHidden)
        CATransaction.commit()
        updateCommentAnchor(closeIfMissing:true)
        if let session=resizeSession,session.protectsViewport {
            session.previewOrigin=position.origin
            if !session.isDragging {activity = .idle;resizeSession=nil}
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
        let anchor=captureViewportAnchor();activity = .resizing(anchor)
        #if DEBUG
        debugResizeAnchor=anchor
        #endif
    }
    func finishResizeLayout() {
        guard let session=resizeSession,session.protectsViewport else{return}
        layoutSubtreeIfNeeded()
        session.isDragging=false
        pendingFrame=nil
        if committed?.request.width != bounds.width || desired?.width != bounds.width {requestPresentation()}
        ResizeTrace.record("preview.release.render",
            "width=\(bounds.width) committed=\(committed?.request.width ?? -1) desired=\(desired?.width ?? -1)")
        preparePresentation()
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
        guard hasCurrentMap,let current=self.committed else{return}
        let anchored=idleAnchorLock.flatMap {
            resolvedOrigin($0,geometry:current.geometry,windowTop:current.windowTop,totalHeight:current.totalHeight)
        }
        guard let origin=anchored ?? targetOrigin(height:current.totalHeight,map:current.map) else{return}
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
        idleAnchorLock=nil
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
    var debugMapGeometryRevision:Int? {committed?.sourceGeometryRevision}
    var debugMaximumOrigin:CGFloat {max(0,(committed?.totalHeight ?? bounds.height)-bounds.height)}
    func debugGeometry()->String {
        let visible=source?.visibleSourceRange
        let pendingVisible=committed?.request.content.entries.contains { entry in
            guard entry.fragment.kind == .pending,let visible else{return false}
            return NSIntersectionRange(entry.fragment.range,visible).length>0
        } ?? false
        return "mounted=\(preparedFragmentCount), windowTop=\(committed?.windowTop ?? -1), total=\(committed?.totalHeight ?? -1), height=\(committed?.geometry.height ?? 0), desired=\(String(describing:desired?.id)), rendering=\(String(describing:rendering?.id)), contentRevision=\(content?.revision ?? -1), lastRevision=\(lastRevision), measuredSource=\(source?.hasMeasuredLayout == true), sourceRevision=\(source?.contentRevision ?? -1), displayedRevision=\(displayedDocumentRevision), detached=\(detachedSourceOrigin != nil), anchor=\(String(describing:idleAnchorLock)), pendingVisible=\(pendingVisible), mapCurrent=\(hasCurrentMap), uncommitted=\(web.hasUncommittedPresentation), failures=\(presentationFailureCount), frame=\(committedFrameID), clip=\(clipOrigin), patches=\(patchCount), displayed=\(String(describing:displayedSourceRange)), visible=\(String(describing:visible))"
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
