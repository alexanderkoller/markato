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

/// One presentation surface owns all of its native and HTML-engine coordinates.
/// The inactive surface stays hidden until its complete presentation is ready.
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
        setVisible(false)
    }
    func setVisible(_ visible:Bool) {
        if visible {
            // Prepare the child while its parent is still hidden, then expose
            // the complete surface in one parent visibility change.
            web.isHidden=false
            web.setAccessibilityHidden(false)
            clip.isHidden=false
        } else {
            // Remove the whole surface before changing its child state so a
            // background-only clip can never become a composited frame.
            clip.isHidden=true
            web.isHidden=true
            web.setAccessibilityHidden(true)
        }
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
    var editAnchor:Int {get}
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
    let surface:PreviewSurface
    let map:ScrollLandmarks?
    let sourceGeometryRevision:Int?
    let viewportHeight:CGFloat
    let windowTop:CGFloat
    let totalHeight:CGFloat
    init(request:PreviewRequest,geometry:HTMLPreviewGeometry,surface:PreviewSurface,map:ScrollLandmarks?,sourceGeometryRevision:Int?,viewportHeight:CGFloat,windowTop:CGFloat,totalHeight:CGFloat) {
        self.request=request;self.geometry=geometry;self.surface=surface
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
    var fontSize:CGFloat=15 {didSet {if fontSize != oldValue {endScrollGesture();requestPresentation()}}}
    var baseURL:URL? {didSet {if baseURL != oldValue {endScrollGesture();requestPresentation()}}}
    private let surfaces:[PreviewSurface]
    private var displayed:PreviewSurface {committed?.surface ?? surfaces[0]}
    private var web:HTMLPreviewView {displayed.web}
    private var clip:NSClipView {displayed.clip}
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
        guard let committed,committed.surface.web.isEngineReady,desired==nil,content?.revision==committed.request.revision else{return -1}
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
        let top=(committed?.surface.logicalOrigin ?? 0)-(committed?.windowTop ?? 0)
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
    private(set) var inPlaceCrossRevisionCommitCount=0
    private(set) var pixelReuseCommitCount=0
    var debugPresentationCommitted:(()->Void)?
    var debugCommittedSurfaceIndex:Int? {
        guard let surface=committed?.surface else{return nil}
        return surfaces.firstIndex{$0 === surface}
    }
    var debugResizeAnchorViewportY:CGFloat? {
        guard let committed,let id=resizeSession?.previewEntryID,
              let item=committed.geometry.items.first(where:{$0.id==id}) else{return nil}
        return committed.windowTop+item.y-committed.surface.logicalOrigin
    }
    var debugResizePinnedOrigin:CGFloat? {resizeSession?.protectsViewport == true ? resizeSession?.previewOrigin:nil}
    var debugResizeAnchorState:String {
        guard let committed,let id=resizeSession?.previewEntryID,
              let item=committed.geometry.items.first(where:{$0.id==id}) else{return "missing"}
        return "surface=\(surfaces.firstIndex{$0 === committed.surface} ?? -1), item=\(item.y), window=\(committed.windowTop), origin=\(committed.surface.logicalOrigin), width=\(committed.geometry.width), request=\(committed.request.width)"
    }
    private var debugFailsNextPresentation=false
    private var debugFailsNextPosition=false
    func debugFailNextPresentation() {debugFailsNextPresentation=true}
    func debugFailNextPosition() {debugFailsNextPosition=true}
    #endif
    override init(frame:NSRect) {
        func makeSurface()->PreviewSurface {PreviewSurface(web:HTMLPreviewView(frame:.zero))}
        surfaces=[makeSurface(),makeSurface()]
        super.init(frame:frame)
        wantsLayer=true;layer?.masksToBounds=true
        for surface in surfaces {addSubview(surface.clip)}
        loadingView.wantsLayer=true;loadingView.layer?.backgroundColor=NSColor.textBackgroundColor.cgColor
        loadingLabel.textColor = .secondaryLabelColor;loadingLabel.alignment = .center
        loadingView.addSubview(loadingLabel);addSubview(loadingView);loadingView.isHidden=true
        for surface in surfaces {
            let view=surface.web
            view.viewportResized={ [weak self,weak surface] in
                guard let self,let surface else{return}
                self.viewportDidResize(surface)
            }
            view.verticalWheel={ [weak self] event in self?.handleVerticalScroll(event) }
            view.openURL={ [weak self] url in
                if let fragment=url.fragment {self?.openAnchor?(fragment)}
                else if ["http","https","mailto"].contains(url.scheme?.lowercased() ?? "") {NSWorkspace.shared.open(url)}
            }
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
        if resizeSession?.protectsViewport == true {hidden=committed?.surface.web.isEngineReady==true}
        else if let source,failedParseRevision==source.contentRevision {hidden=committed?.surface.web.isEngineReady==true}
        else if let source,!source.hasMeasuredLayout {hidden=committed?.surface.web.isEngineReady==true}
        else {
            let replacingContent=source.map{$0.contentRevision != committed?.request.revision} == true
            // A revision change deliberately leaves the last complete bitmap
            // visible until its replacement commits. Coverage and map checks
            // only apply when positioning content from the current revision;
            // requiring them for stale content briefly exposed the loading
            // view on every edit.
            hidden=committed?.surface.web.isEngineReady==true &&
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
        resumeSourceAlignment()
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
        desired=PreviewRequest(id:version,content:content,fontSize:fontSize,baseURL:baseURL,width:bounds.width)
        preparePresentation()
    }
    private func canExtendDisplayedDocument(_ request:PreviewRequest)->Bool {
        guard let committed,committed.surface.web.isEngineReady,committed.request.revision==request.revision,
              committed.request.entries.count==committed.geometry.items.count else{return false}
        let previous=committed.request
        let covered=coversSourceViewport
        guard previous.width==request.width,previous.fontSize==request.fontSize,
              previous.baseURL?.absoluteString==request.baseURL?.absoluteString,
              previous.content.sourceLength==request.content.sourceLength,
              !isScrollMappingFrozen || !covered else{return false}
        let next=Dictionary(request.entries.map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
        var fillsPendingContent=false
        for (entry,item) in zip(committed.request.entries,committed.geometry.items) {
            guard entry.id==item.id else{return false}
            if entry.fragment.kind == .pending,next[entry.id] != entry {
                // A covered viewport is immutable. An uncovered viewport is
                // already masked; fill its pending content on the retained DOM.
                if covered, item.y<visibleWebRange.upperBound {return false}
                fillsPendingContent=true
            } else if next[entry.id] != entry {return false}
        }
        return fillsPendingContent
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
            let origin=min(max(0,previous.totalHeight-bounds.height),max(0,previous.surface.logicalOrigin))
            return PresentationPosition(map:nil,sourceGeometryRevision:nil,origin:origin,
                windowTop:previous.windowTop,totalHeight:previous.totalHeight)
        case .synchronized(let source):
            guard covers(request.content,visible:source.visibleSourceRange),
                  let map=makeMap(request,geometry:previous.geometry,windowTop:previous.windowTop,
                    totalHeight:previous.totalHeight),
                  let origin=centerAlignedOrigin(height:previous.totalHeight,map:map,source:source) else{return nil}
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
        // or swap a surface while the committed bitmap and map are frozen.
        guard resizeSession?.isDragging != true,rendering==nil,var request=desired,
              request.width>0.5,bounds.height>0.5 else{return}
        guard request.entries.allSatisfy({$0.fragment.html != nil}),Set(request.entries.map(\.id)).count==request.entries.count else {
            NSLog("Preview request contains incomplete or duplicate fragments")
            return
        }
        if let previous=committed,previous.surface.web.isEngineReady,
           previous.request.revision != request.revision,rendersSamePixels(request,as:previous.request),
           let position=reusedPixelPosition(request,from:previous) {
            // Source ranges and the scroll map changed, but the mounted IDs and
            // HTML did not. Publishing the new metadata over the existing
            // bitmap avoids an unnecessary engine update and surface swap.
            rendering=request
            // The parser may replace the adjacent block ID when its trailing
            // whitespace changes. Carry the already measured stride onto that
            // new identity so later window calculations do not regress to an
            // estimate and introduce a delayed correction.
            preparedDocument?.recordPreviewHeights(measuredHeights(previous.geometry,for:request.entries),
                revision:request.revision)
            metadataPinnedOrigin=position.origin
            metadataPinnedSourceOrigin=source?.viewportOrigin
            commit(request,geometry:previous.geometry,surface:previous.surface,position:position,reusesPixels:true)
            finishPreparation(request)
            return
        }
        if committed?.request.revision != request.revision {
            metadataPinnedOrigin=nil;metadataPinnedSourceOrigin=nil
        }
        let surface:PreviewSurface
        // Only same-revision cache completion may touch the displayed DOM, and
        // then only outside the covered viewport. A document edit must always
        // render on the inactive surface: mutating the displayed Ultralight
        // DOM exposes its intermediate layout/paint frames as typing flicker.
        if canExtendDisplayedDocument(request) {surface=displayed}
        else if let ready=surfaces.first(where:{$0.web.isEngineReady && $0 !== committed?.surface}) {surface=ready}
        else {
            // Background cache growth is optional while the committed window
            // covers the viewport. An uncovered destination is already masked,
            // so it can safely replace the displayed DOM in place.
            if committed?.request.revision==request.revision {
                let complete=request.content.sourceRange.location==0 &&
                    NSMaxRange(request.content.sourceRange)>=request.content.sourceLength
                // The complete steady-state document is a one-time transition,
                // not disposable cache growth. Keep it queued until the hidden
                // surface has finished bootstrapping.
                if complete {return}
                if coversSourceViewport {desired=nil;return}
                surface=displayed
            } else {
                return
            }
        }
        rendering=request
        if surface !== committed?.surface {surface.setVisible(false)}
        surface.size(contentHeight:max(1,committed?.totalHeight ?? 0),windowTop:committed?.windowTop ?? 0,
            width:request.width,viewportHeight:bounds.height)
        #if DEBUG
        let roundtrip=TimingDiagnostics.shared.begin("html.presentation")
        patchCount += 1
        #endif
        guard isCurrent(request,surface:surface) else {
            finishPreparation(request);return
        }
        #if DEBUG
        if debugFailsNextPresentation {
            debugFailsNextPresentation=false
            surface.web.debugFailNextPresentation()
        }
        #endif
        guard let measured=surface.web.present(request.entries,fontSize:request.fontSize,baseURL:request.baseURL) else {
            #if DEBUG
            presentationFailureCount += 1
            retainedPresentationAfterFailure = retainedPresentationAfterFailure &&
                (committed == nil || (committed?.surface.clip.isHidden==false && loadingView.isHidden))
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
            // The hidden surface has already measured every mounted block.
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
        surface.scroll(to:position.origin,flush:true)
        #if DEBUG
        TimingDiagnostics.shared.end(roundtrip,values:["mounted":Double(request.entries.count),"height":Double(geometry.height)])
        #endif
        let committed=commit(request,geometry:geometry,surface:surface,position:position)
        finishPreparation(request,keepDesired:!committed)
    }
    private func isCurrent(_ request:PreviewRequest,surface:PreviewSurface)->Bool {
        desired?.id==request.id && rendering?.id==request.id && surfaces.contains(where:{$0 === surface}) && surface.web.isEngineReady
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
    private func editedBlockOrigin(_ request:PreviewRequest,geometry:HTMLPreviewGeometry,
        windowTop:CGFloat,totalHeight:CGFloat,source:ScrollSource)->CGFloat? {
        guard committed?.request.revision != request.revision else{return nil}
        let offset=source.editAnchor
        guard let (entry,item)=Array(zip(request.entries,geometry.items))
            .last(where:{$0.0.fragment.from<=offset && $0.0.fragment.to>=offset}),
              let sourceY=source.alignmentVerticalPosition(for:entry.fragment.from) else{return nil}
        let viewportY=sourceY-source.viewportOrigin
        guard viewportY>=0,viewportY<bounds.height else{return nil}
        return min(max(0,totalHeight-bounds.height),max(0,windowTop+item.y-viewportY))
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
        guard !landmarks.isEmpty else{return nil}
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
                    editedBlockOrigin(request,geometry:geometry,windowTop:extent.top,totalHeight:extent.total,source:source) ??
                    targetOrigin(height:extent.total,map:map) else{return nil}
            return PresentationPosition(map:map,sourceGeometryRevision:source.geometryRevision,origin:origin,windowTop:extent.top,totalHeight:extent.total)
        }
    }
    @discardableResult private func commit(_ request:PreviewRequest,geometry:HTMLPreviewGeometry,surface:PreviewSurface,
        position:PresentationPosition,reusesPixels:Bool=false)->Bool {
        guard isCurrent(request,surface:surface) else{return false}
        if isScrollMappingFrozen,coversSourceViewport,!needsWindowReplenishment,
           committed?.request.revision==request.revision {return false}
        if let source {
            guard source.contentRevision==request.revision,position.sourceGeometryRevision==source.geometryRevision,
                  covers(request.content,visible:source.visibleSourceRange) else{return false}
        }
        let previousPresentation=committed
        let previous=previousPresentation?.surface
        #if DEBUG
        if let previousPresentation,previousPresentation.request.revision != request.revision {
            crossRevisionCommitCount += 1
            if reusesPixels {pixelReuseCommitCount += 1}
            else if surface === previousPresentation.surface {inPlaceCrossRevisionCommitCount += 1}
        }
        #endif
        if !reusesPixels {metadataPinnedOrigin=nil;metadataPinnedSourceOrigin=nil}
        let hadFocus=previous.map{(window?.firstResponder as? NSView)?.isDescendant(of:$0.web)==true} == true
        CATransaction.begin();CATransaction.setDisableActions(true)
        committed=CommittedPresentation(request:request,geometry:geometry,surface:surface,map:position.map,sourceGeometryRevision:position.sourceGeometryRevision,viewportHeight:bounds.height,windowTop:position.windowTop,totalHeight:position.totalHeight)
        desired=nil
        surface.size(contentHeight:position.totalHeight,windowTop:position.windowTop,width:request.width,viewportHeight:bounds.height)
        moveClip(to:position.origin)
        if surface !== previous {
            // Keep the old bitmap composited until the replacement is ready.
            // Showing first also prevents a transient empty view hierarchy if
            // AppKit services display invalidations inside this transaction.
            surface.setVisible(true);previous?.setVisible(false)
        }
        updateLoadingState()
        if hadFocus {window?.makeFirstResponder(surface.web)}
        assert(surfaces.filter{!$0.clip.isHidden}.count==1 && !surface.web.isHidden)
        CATransaction.commit()
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
        for surface in surfaces {surface.clip.frame=bounds}
        loadingView.frame=bounds
        loadingLabel.frame=NSRect(x:16,y:max(0,(bounds.height-24)/2),width:max(0,bounds.width-32),height:24)
        loadingView.layer?.backgroundColor=NSColor.textBackgroundColor.cgColor
        let previousSize=measuredSize
        let widthChanged=previousSize.width != bounds.width
        measuredSize=bounds.size
        if widthChanged {endScrollGesture();requestPresentation()}
        if let committed {
            committed.surface.size(contentHeight:committed.totalHeight,windowTop:committed.windowTop,
                width:bounds.width,viewportHeight:bounds.height)
        }
        if resizeSession?.protectsViewport != true {place()}
        preparePresentation()
    }
    func captureResizeAnchor()->(entryID:String?,displacement:CGFloat,origin:CGFloat) {
        web.flush()
        let origin=committed?.surface.logicalOrigin ?? 0
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
              previous.surface.web.isEngineReady,
              request.content==previous.request.content,
              request.fontSize==previous.request.fontSize,
              request.baseURL==previous.request.baseURL,
              request.width==bounds.width,
              previous.surface.web.bounds.width==bounds.width else{return false}
        previous.surface.web.flush()
        guard let geometry=previous.surface.web.geometry(),
              abs(geometry.width-request.width)<1,
              geometry.items.map(\.id)==request.entries.map(\.id),
              let position=presentationPosition(request,geometry:geometry) else{return false}
        rendering=request
        let reused=commit(request,geometry:geometry,surface:previous.surface,
            position:position,reusesPixels:true)
        finishPreparation(request,keepDesired:!reused)
        return reused
    }
    private func viewportDidResize(_ surface:PreviewSurface) {
        guard let session=resizeSession,session.protectsViewport,
              let committed,surface === committed.surface,
              let geometry=surface.web.geometry() else{return}
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
            surface:surface,map:committed.map,sourceGeometryRevision:committed.sourceGeometryRevision,
            viewportHeight:bounds.height,windowTop:extent.top,totalHeight:extent.total)
    }
    private func refreshMap() {
        guard let committed,let source,(committed.map == nil || committed.sourceGeometryRevision != source.geometryRevision || committed.viewportHeight != bounds.height) else{return}
        guard let map=makeMap(committed.request,geometry:committed.geometry,windowTop:committed.windowTop,totalHeight:committed.totalHeight) else{return}
        self.committed=CommittedPresentation(request:committed.request,geometry:committed.geometry,surface:committed.surface,map:map,sourceGeometryRevision:source.geometryRevision,viewportHeight:bounds.height,windowTop:committed.windowTop,totalHeight:committed.totalHeight)
    }
    private func place() {
        guard let committed else{return}
        if let source,source.contentRevision != committed.request.revision {return}
        if !isScrollMappingFrozen {refreshMap()}
        guard hasCurrentMap,let current=self.committed,let origin=targetOrigin(height:current.totalHeight,map:current.map) else{return}
        moveClip(to:origin)
    }
    private func moveClip(to origin:CGFloat) {
        guard let committed else{return}
        CATransaction.begin();CATransaction.setDisableActions(true)
        committed.surface.scroll(to:origin)
        independentOrigin=origin
        CATransaction.commit()
    }
    #if DEBUG
    var debugIsIndependentlyScrolled:Bool {detachedSourceOrigin != nil}
    func debugScrollViewport(by delta:CGFloat) {
        metadataPinnedOrigin=nil;metadataPinnedSourceOrigin=nil
        scrollPreview(to:independentOrigin+delta,detachFromSource:source != nil)
    }
    var debugFirstHeadingViewportY:CGFloat? {
        guard let committed,let rect=committed.surface.web.debugRect("h1",containing:"Markato") else{return nil}
        return committed.surface.web.frame.minY-committed.surface.clip.bounds.minY+rect.minY
    }
    func debugParagraphViewportY(containing text:String)->CGFloat? {
        guard let committed,let rect=committed.surface.web.debugRect("p",containing:text) else{return nil}
        return committed.surface.web.frame.minY-committed.surface.clip.bounds.minY+rect.minY
    }
    func debugHeadingViewportY(containing text:String)->CGFloat? {
        guard let committed,
              let rect=committed.surface.web.debugRect("h1, h2, h3, h4, h5, h6",containing:text) else{return nil}
        return committed.surface.web.frame.minY-committed.surface.clip.bounds.minY+rect.minY
    }
    var debugScrollMapError:CGFloat? {
        guard let committed,let source,let map=committed.map,
              let expected=map.previewY(for:Double(source.viewportOrigin)) else{return nil}
        return CGFloat(expected)-committed.surface.logicalOrigin
    }
    func debugGeometry()->String {
        let visible=source?.visibleSourceRange
        let pendingVisible=committed?.request.content.entries.contains { entry in
            guard entry.fragment.kind == .pending,let visible else{return false}
            return NSIntersectionRange(entry.fragment.range,visible).length>0
        } ?? false
        return "mounted=\(preparedFragmentCount), height=\(committed?.geometry.height ?? 0), desired=\(String(describing:desired?.id)), rendering=\(String(describing:rendering?.id)), measuredSource=\(source?.hasMeasuredLayout == true), sourceRevision=\(source?.contentRevision ?? -1), displayedRevision=\(displayedDocumentRevision), pendingVisible=\(pendingVisible), mapCurrent=\(hasCurrentMap), clip=\(clipOrigin), patches=\(patchCount), displayed=\(String(describing:displayedSourceRange)), visible=\(String(describing:visible))"
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
