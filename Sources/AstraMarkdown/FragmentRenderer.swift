import AppKit
import HTMLPreview
import MarkdownCore

/// One presentation surface owns all of its native and HTML-engine coordinates.
/// The inactive surface stays hidden until its complete presentation is ready.
@MainActor private final class PreviewSurface {
    let clip=NSClipView()
    let canvas=FlippedView()
    let web:HTMLPreviewView
    var ready=false
    var request:PreviewRequest?
    var observed:PreviewGeometry?
    var preparedContent:PreviewContent?
    var preparedAssetBase:String?
    var ignoresGeometry=false
    private(set) var logicalOrigin:CGFloat=0
    private(set) var windowTop:CGFloat=0
    private var margin:CGFloat=1
    init(web:HTMLPreviewView) {
        self.web=web;ready=web.isEngineReady
        clip.drawsBackground=true;clip.backgroundColor = .textBackgroundColor
        clip.documentView=canvas;canvas.addSubview(web)
        setVisible(false)
    }
    func setVisible(_ visible:Bool) {
        clip.isHidden = !visible;web.isHidden = !visible
        web.setAccessibilityHidden(!visible)
    }
    func size(contentHeight:CGFloat,windowTop:CGFloat=0,windowHeight:CGFloat?=nil,width:CGFloat,viewportHeight:CGFloat) {
        self.windowTop=windowTop
        margin=max(1,viewportHeight)
        let frame=NSRect(x:0,y:margin+logicalOrigin,width:max(1,width),height:max(1,viewportHeight))
        if web.frame != frame {web.frame=frame}
        let size=NSSize(width:max(1,width),height:max(contentHeight+margin*2,frame.maxY+margin))
        if canvas.frame.size != size {canvas.frame.size=size}
    }
    func scroll(to origin:CGFloat) {
        logicalOrigin=origin
        let local=max(0,origin-windowTop)
        web.setFrameOrigin(NSPoint(x:0,y:margin+origin))
        clip.scroll(to:NSPoint(x:0,y:margin+origin))
        web.scroll(to:NSPoint(x:0,y:local))
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
    func scrollWheel(with event:NSEvent)
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
    let content:PreviewContent
    let fontSize:CGFloat
    let baseURL:URL?
    let width:CGFloat
    var revision:Int {content.revision}
    var entries:[RenderedEntry] {content.entries}
}
private struct PreviewGeometry:Equatable {
    struct Item:Equatable {
        let id:String
        let y:CGFloat
        let height:CGFloat
        let landmark:CGFloat?
    }
    let requestID:Int
    let measurement:Int
    let width:CGFloat
    let height:CGFloat
    let items:[Item]
    init?(_ value:Any?,request:PreviewRequest) {
        guard let object=value as? [String:Any],let id=object["revision"] as? Int,id==request.id,
              let measurement=object["measurement"] as? Int,measurement>=0,
              let width=object["width"] as? Double,width.isFinite,abs(width-Double(request.width))<=1,
              let height=object["height"] as? Double,height.isFinite,height>=0,
              let raw=object["items"] as? [[String:Any]],raw.count==request.entries.count else{return nil}
        var items=[Item]()
        for (object,entry) in zip(raw,request.entries) {
            guard let id=object["id"] as? String,id==entry.id,
                  let y=object["y"] as? Double,y.isFinite,
                  let h=object["height"] as? Double,h.isFinite,h>=0 else{return nil}
            let reference=object["landmarkY"] as? Double
            guard reference?.isFinite != false else{return nil}
            items.append(Item(id:id,y:CGFloat(y),height:CGFloat(h),landmark:reference.map{CGFloat($0)}))
        }
        requestID=id;self.measurement=measurement;self.width=CGFloat(width);self.height=CGFloat(height);self.items=items
    }
    init(_ value:HTMLPreviewGeometry,request:PreviewRequest) {
        requestID=request.id;measurement=value.measurement;width=value.width;height=value.height
        items=value.items.map{Item(id:$0.id,y:$0.y,height:$0.height,landmark:$0.landmark)}
    }
    func sameLayout(as other:PreviewGeometry)->Bool {
        requestID==other.requestID && width==other.width && height==other.height && items==other.items
    }
}

private final class PreviewLoadingView:NSView {
    override func hitTest(_ point:NSPoint)->NSView? {nil}
}

private struct CommittedPresentation {
    let request:PreviewRequest
    let geometry:PreviewGeometry
    let surface:PreviewSurface
    let map:ScrollLandmarks?
    let sourceGeometryRevision:Int?
    let viewportHeight:CGFloat
    let windowTop:CGFloat
    let totalHeight:CGFloat
    let metrics:[String:(CGFloat,CGFloat)]
    init(request:PreviewRequest,geometry:PreviewGeometry,surface:PreviewSurface,map:ScrollLandmarks?,sourceGeometryRevision:Int?,viewportHeight:CGFloat,windowTop:CGFloat,totalHeight:CGFloat) {
        self.request=request;self.geometry=geometry;self.surface=surface
        self.map=map;self.sourceGeometryRevision=sourceGeometryRevision;self.viewportHeight=viewportHeight
        self.windowTop=windowTop;self.totalHeight=totalHeight
        metrics=Dictionary(uniqueKeysWithValues:geometry.items.map{($0.id,($0.y,$0.height))})
    }
}

/// Prepared scrolling reads one committed presentation and moves its native clip.
@MainActor final class PreviewPane:NSView {
    var preparedDocument:PreparedDocument?
    override var isFlipped:Bool {true}
    var scrolling:PreviewScrolling = .independent {didSet {sourceLayoutChanged()}}
    var openAnchor:((String)->Void)?
    var fontSize:CGFloat=14 {didSet {if fontSize != oldValue {endScrollGesture();requestPresentation()}}}
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
    private var version=0,measuredWidth:CGFloat=0
    private var inspector:NSWindowController?
    private(set) var isScrollMappingFrozen=false
    var presentationSettled:(()->Void)?
    private var source:ScrollSource? {
        switch scrolling {case .independent:return nil;case .synchronized(let source):return source}
    }
    var lastRevision:Int {
        guard let committed,committed.surface.ready,desired==nil,content?.revision==committed.request.revision else{return -1}
        return committed.request.revision
    }
    var preparedFragmentCount:Int {committed?.request.entries.count ?? 0}
    var hasPendingContent:Bool {committed?.request.entries.contains{$0.fragment.kind=="Pending"} == true}
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
            entry.fragment.kind=="Pending" && (NSIntersectionRange(entry.fragment.range,visible).length>0 ||
                (visible.length==0 && entry.fragment.from<=visible.location && entry.fragment.to>visible.location))
        }
    }
    var coversSourceViewport:Bool {
        guard let committed else{return false}
        guard let source else{return true}
        guard source.hasMeasuredLayout else{return false}
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
    var webView:HTMLPreviewView {web}
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
    var scrollLandmarkCount:Int {committed?.map?.points.count ?? 0}
    var semanticLandmarkOffsets:[Int] {committed?.map?.points.filter{!$0.boundary}.map(\.offset) ?? []}
    var debugScrollLandmarks:[ScrollLandmark] {committed?.map?.points ?? []}
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
            view.verticalWheel={ [weak self] event in self?.handleVerticalScroll(event) }
            view.openURL={ [weak self] url in
                if let fragment=url.fragment {self?.openAnchor?(fragment)}
                else if ["http","https","mailto"].contains(url.scheme?.lowercased() ?? "") {NSWorkspace.shared.open(url)}
            }
        }
    }
    required init?(coder:NSCoder) {fatalError()}
    override func draw(_ dirtyRect:NSRect) {NSColor.textBackgroundColor.setFill();dirtyRect.fill()}
    func moveViewport() {place();updateLoadingState()}
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
        if let source,!source.hasMeasuredLayout {hidden=committed?.surface.ready==true}
        else {
        let replacingContent=source.map{$0.contentRevision != committed?.request.revision} == true
        hidden=committed?.surface.ready==true && coversSourceViewport && (replacingContent || hasCurrentMap)
        }
        #if DEBUG
        if !hidden,loadingWait==nil {loadingWait=TimingDiagnostics.shared.begin("preview.loading")}
        if hidden {TimingDiagnostics.shared.end(loadingWait);loadingWait=nil}
        #endif
        loadingView.isHidden=hidden
    }
    private func handleVerticalScroll(_ event:NSEvent) {
        switch scrolling {
        case .synchronized(let source):source.scrollWheel(with:event)
        case .independent:independentOrigin=max(0,independentOrigin-event.scrollingDeltaY);place()
        }
    }
    func scrollOverflow(_ event:NSEvent)->Bool {
        guard let source,source.contentHeight<=bounds.height+0.001,
              let committed,committed.totalHeight>bounds.height,
              abs(event.scrollingDeltaY)>=abs(event.scrollingDeltaX) else{return false}
        independentOrigin=max(0,visibleWebRange.lowerBound-event.scrollingDeltaY);place();return true
    }
    func navigatePreview(toEnd:Bool) {
        guard let committed else{return}
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
    func invalidate() {endScrollGesture();version += 1;content=nil;desired=nil;updateLoadingState()}
    /// Apply an equal-cardinality manifest splice immediately to the complete
    /// displayed DOM. Its old geometry/map remain the last committed snapshot;
    /// the caller follows with a normal full measurement and commit.
    func patchCompleteDocument(_ change:PreparedBlockChange,entries:[(index:Int,entry:RenderedEntry)],completion:@escaping(Bool)->Void) {
        guard let committed,displaysCompleteDocument,rendering==nil,
              change.prefix+change.suffix<=committed.request.entries.count,
              committed.request.entries.count-change.prefix-change.suffix==change.blocks.count else {
            completion(false);return
        }
        let surface=committed.surface
        surface.ignoresGeometry=true
        let geometry=surface.web.patch(entries)
        surface.observed=geometry.map{PreviewGeometry($0,request:committed.request)}
        completion(geometry != nil)
    }
    func show(_ result:ParseResult) {
        let existing=Dictionary((content?.entries ?? []).map{($0.fragment.from,$0.id)},uniquingKeysWith:{first,_ in first})
        show(result.fragments.map{RenderedEntry(id:$0.id ?? existing[$0.from] ?? UUID().uuidString,fragment:$0)},revision:result.revision)
    }
    func show(_ entries:[RenderedEntry],revision:Int,sourceRange:NSRange?=nil,previewTop:Double?=nil,previewHeight:Double?=nil) {
        let extent=source?.sourceLength ?? entries.last?.fragment.to ?? 0
        let covered=sourceRange ?? NSRange(location:entries.first?.fragment.from ?? 0,
            length:max(0,(entries.last?.fragment.to ?? extent)-(entries.first?.fragment.from ?? 0)))
        let next=PreviewContent(revision:revision,entries:entries,sourceLength:extent,sourceRange:covered,
            previewTop:previewTop,previewHeight:previewHeight)
        guard content != next || committed?.request.content != next else{updateLoadingState();return}
        if let committed,committed.request.revision != revision {endScrollGesture()}
        content=next;requestPresentation();updateLoadingState()
    }
    private func requestPresentation() {
        guard let content else{return}
        version += 1
        desired=PreviewRequest(id:version,content:content,fontSize:fontSize,baseURL:baseURL,width:bounds.width)
        preparePresentation()
    }
    private func canExtendDisplayedDocument(_ request:PreviewRequest)->Bool {
        guard let committed,committed.surface.ready,committed.request.revision==request.revision else{return false}
        let previous=committed.request
        let covered=coversSourceViewport
        guard previous.width==request.width,previous.fontSize==request.fontSize,
              previous.baseURL?.absoluteString==request.baseURL?.absoluteString,
              previous.content.sourceLength==request.content.sourceLength,
              !isScrollMappingFrozen || !covered else{return false}
        let next=Dictionary(request.entries.map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
        var fillsPendingContent=false
        for entry in committed.request.entries {
            if entry.fragment.kind=="Pending",next[entry.id] != entry {
                // A covered viewport is immutable. An uncovered viewport is
                // already masked; fill its pending content on the retained DOM.
                if covered {guard let (y,_)=committed.metrics[entry.id],y>=visibleWebRange.upperBound else{return false}}
                fillsPendingContent=true
            } else if next[entry.id] != entry {return false}
        }
        return fillsPendingContent
    }
    private func displayedPatch(_ request:PreviewRequest)->IndexedPatch? {
        guard let committed,committed.surface.ready,
              committed.request.width==request.width,committed.request.fontSize==request.fontSize,
              committed.request.baseURL?.absoluteString==request.baseURL?.absoluteString,
              committed.request.revision != request.revision else{return nil}
        return indexedPatch(from:committed.request.content,to:request)
    }
    private struct IndexedPatch {
        let items:[[String:Any]]
        let suffixIndex:Int
        let shift:Int
    }
    private func indexedPatch(from previous:PreviewContent?,to request:PreviewRequest)->IndexedPatch? {
        guard let old=previous?.entries,old.count==request.entries.count,!old.isEmpty else{return nil}
        let next=request.entries
        var prefix=0
        while prefix<old.count,old[prefix].id==next[prefix].id,
              old[prefix].fragment.html==next[prefix].fragment.html {prefix += 1}
        guard prefix<old.count else{return nil}
        var suffix=old.count
        while suffix>prefix,old[suffix-1].id==next[suffix-1].id,
              old[suffix-1].fragment.html==next[suffix-1].fragment.html {suffix -= 1}
        guard suffix-prefix<=8 else{return nil}
        let shift=suffix<old.count ? next[suffix].fragment.from-old[suffix].fragment.from:0
        if suffix<old.count {
            for index in suffix..<old.count where
                next[index].fragment.from-old[index].fragment.from != shift ||
                next[index].fragment.to-old[index].fragment.to != shift {return nil}
        }
        let items:[[String:Any]]=(prefix..<suffix).map {index in
            let entry=next[index],fragment=entry.fragment
            return ["index":index,"id":entry.id,"from":fragment.from,"to":fragment.to,"html":fragment.html!]
        }
        return IndexedPatch(items:items,suffixIndex:suffix,shift:shift)
    }
    private func preparePresentation() {
        guard rendering==nil,let request=desired,
              request.width>0.5,bounds.height>0.5 else{return}
        guard request.entries.allSatisfy({$0.fragment.html != nil}),Set(request.entries.map(\.id)).count==request.entries.count else {
            NSLog("Preview request contains incomplete or duplicate fragments")
            return
        }
        let displayedPatch=displayedPatch(request)
        let surface:PreviewSurface
        if canExtendDisplayedDocument(request) ||
            (displayedPatch != nil && committed?.surface.ignoresGeometry != true) {surface=displayed}
        else if let ready=surfaces.first(where:{$0.ready && $0 !== committed?.surface}) {surface=ready}
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
        surface.request=request;surface.observed=nil;surface.ignoresGeometry=false
        surface.size(contentHeight:max(1,committed?.totalHeight ?? 0),windowTop:committed?.windowTop ?? 0,
            windowHeight:committed?.geometry.height,width:request.width,viewportHeight:bounds.height)
        #if DEBUG
        let roundtrip=TimingDiagnostics.shared.begin("html.presentation")
        patchCount += 1
        #endif
        guard isCurrent(request,surface:surface),let measured=surface.web.present(request.entries,fontSize:request.fontSize,baseURL:request.baseURL) else {
            finishPreparation(request);return
        }
        surface.preparedContent=request.content;surface.preparedAssetBase=request.baseURL?.absoluteString ?? ""
        let geometry=PreviewGeometry(measured,request:request);surface.observed=geometry
        guard let position=presentationPosition(request,geometry:geometry) else {finishPreparation(request);return}
        surface.size(contentHeight:position.totalHeight,windowTop:position.windowTop,
            windowHeight:geometry.height,width:request.width,viewportHeight:bounds.height)
        surface.scroll(to:position.origin)
        #if DEBUG
        TimingDiagnostics.shared.end(roundtrip,values:["mounted":Double(request.entries.count),"height":Double(geometry.height)])
        #endif
        commit(request,geometry:geometry,surface:surface,position:position)
        finishPreparation(request)
    }
    private func isCurrent(_ request:PreviewRequest,surface:PreviewSurface)->Bool {
        desired?.id==request.id && rendering?.id==request.id && surfaces.contains(where:{$0 === surface}) && surface.ready
            && surface.request?.id==request.id && bounds.width==request.width && bounds.height>0.5
    }
    private func finishPreparation(_ request:PreviewRequest,retry:Bool=false) {
        guard rendering?.id==request.id else{return}
        rendering=nil
        if !retry,desired?.id==request.id,coversSourceViewport {desired=nil}
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
    private func previewExtent(_ request:PreviewRequest,_ geometry:PreviewGeometry)->(top:CGFloat,total:CGFloat) {
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
            if source.contentHeight<=bounds.height+0.001 {target=independentOrigin}
            else {
                guard let map,let y=map.previewY(for:Double(source.viewportOrigin)) else{return nil}
                target=CGFloat(y)
            }
        }
        return min(max(0,height-bounds.height),max(0,target))
    }
    private func makeMap(_ request:PreviewRequest,geometry:PreviewGeometry,windowTop:CGFloat,totalHeight:CGFloat)->ScrollLandmarks? {
        #if DEBUG
        let work=TimingDiagnostics.shared.begin("preview.map")
        defer {TimingDiagnostics.shared.end(work)}
        #endif
        guard let source,source.hasMeasuredLayout,source.contentRevision==request.revision,source.sourceLength==request.content.sourceLength else{return nil}
        let revision=source.geometryRevision
        var points=[ScrollLandmark]()
        for (item,entry) in zip(geometry.items,request.entries) {
            guard let previewY=item.landmark,entry.fragment.from != 0 else{continue}
            guard let y=source.verticalPosition(for:entry.fragment.from),y.isFinite else{return nil}
            points.append(ScrollLandmark(offset:entry.fragment.from,sourceY:Double(y),previewY:Double(windowTop+previewY)))
        }
        guard revision==source.geometryRevision else{return nil}
        return ScrollLandmarks(points).viewportMap(sourceHeight:Double(source.contentHeight),viewportHeight:Double(bounds.height),previewHeight:Double(totalHeight))
    }
    private func presentationPosition(_ request:PreviewRequest,geometry:PreviewGeometry)->PresentationPosition? {
        let extent=previewExtent(request,geometry)
        switch scrolling {
        case .independent:
            guard let origin=targetOrigin(height:extent.total,map:nil) else{return nil}
            return PresentationPosition(map:nil,sourceGeometryRevision:nil,origin:origin,windowTop:extent.top,totalHeight:extent.total)
        case .synchronized(let source):
            guard covers(request.content,visible:source.visibleSourceRange) else{return nil}
            guard let map=makeMap(request,geometry:geometry,windowTop:extent.top,totalHeight:extent.total) else{return nil}
            guard let origin=targetOrigin(height:extent.total,map:map) else{return nil}
            return PresentationPosition(map:map,sourceGeometryRevision:source.geometryRevision,origin:origin,windowTop:extent.top,totalHeight:extent.total)
        }
    }
    private func commit(_ request:PreviewRequest,geometry:PreviewGeometry,surface:PreviewSurface,position:PresentationPosition) {
        guard isCurrent(request,surface:surface) else{return}
        if isScrollMappingFrozen,coversSourceViewport,!needsWindowReplenishment,
           committed?.request.revision==request.revision {return}
        if let source {
            guard source.contentRevision==request.revision,position.sourceGeometryRevision==source.geometryRevision,
                  covers(request.content,visible:source.visibleSourceRange) else{return}
        }
        let previous=committed?.surface
        let hadFocus=previous.map{(window?.firstResponder as? NSView)?.isDescendant(of:$0.web)==true} == true
        CATransaction.begin();CATransaction.setDisableActions(true)
        committed=CommittedPresentation(request:request,geometry:geometry,surface:surface,map:position.map,sourceGeometryRevision:position.sourceGeometryRevision,viewportHeight:bounds.height,windowTop:position.windowTop,totalHeight:position.totalHeight)
        var heights=[String:Double]()
        for index in geometry.items.indices {
            let item=geometry.items[index]
            let stride=index+1<geometry.items.count ? geometry.items[index+1].y-item.y:item.height+12
            heights[item.id]=Double(max(item.height,stride))
        }
        preparedDocument?.recordPreviewHeights(heights,revision:request.revision)
        desired=nil
        surface.size(contentHeight:position.totalHeight,windowTop:position.windowTop,windowHeight:geometry.height,width:request.width,viewportHeight:bounds.height)
        moveClip(to:position.origin)
        if surface !== previous {previous?.setVisible(false);surface.setVisible(true)}
        updateLoadingState()
        if hadFocus {window?.makeFirstResponder(surface.web)}
        assert(surfaces.filter{!$0.clip.isHidden}.count==1 && !surface.web.isHidden)
        CATransaction.commit()
    }
    override func setFrameSize(_ size:NSSize) {
        if size != frame.size {endScrollGesture()}
        super.setFrameSize(size);needsLayout=true
    }
    override func layout() {
        super.layout()
        for surface in surfaces {surface.clip.frame=bounds}
        loadingView.frame=bounds
        loadingLabel.frame=NSRect(x:16,y:max(0,(bounds.height-24)/2),width:max(0,bounds.width-32),height:24)
        loadingView.layer?.backgroundColor=NSColor.textBackgroundColor.cgColor
        let changed=measuredWidth != bounds.width;measuredWidth=bounds.width
        if changed {endScrollGesture();requestPresentation()}
        if let committed {committed.surface.size(contentHeight:committed.totalHeight,windowTop:committed.windowTop,windowHeight:committed.geometry.height,width:committed.request.width,viewportHeight:bounds.height)}
        place();preparePresentation()
    }
    private func refreshMap() {
        guard let committed,let source,(committed.sourceGeometryRevision != source.geometryRevision || committed.viewportHeight != bounds.height) else{return}
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
    func webViewWebContentProcessDidTerminate(_ view:HTMLPreviewView) {
        // Ultralight is in-process and has no WebContent process. Keep this
        // hook until the old process-crash integration case is retired.
        requestPresentation()
    }
    #endif
    #if DEBUG
    var debugAlignmentDrift:Double {
        guard let committed,let source,let target=committed.map?.previewY(for:Double(source.viewportOrigin)) else{return 0}
        return Double(visiblePreviewRange.lowerBound)-target
    }
    func debugGeometry()->String {"mounted=\(preparedFragmentCount), height=\(committed?.geometry.height ?? 0), desired=\(String(describing:desired?.id)), rendering=\(String(describing:rendering?.id)), measuredSource=\(source?.hasMeasuredLayout == true), mapCurrent=\(hasCurrentMap), clip=\(clipOrigin), patches=\(patchCount), displayed=\(String(describing:displayedSourceRange)), visible=\(String(describing:source?.visibleSourceRange))"}
    #endif
    override func menu(for event:NSEvent)->NSMenu? {
        let menu=NSMenu();menu.addItem(withTitle:"Inspect Item",action:#selector(inspect(_:)),keyEquivalent:"").target=self;return menu
    }
    @objc private func inspect(_ sender:Any?) {
        guard let source,let f=committed?.request.entries.first(where:{$0.fragment.from<=source.alignmentAnchor && $0.fragment.to>=source.alignmentAnchor})?.fragment,f.kind != "Pending" else{return}
        _ = showInspector(for:f)
    }
    func showInspector(for fragment:PreviewFragment)->NSWindowController {
        precondition(fragment.html != nil && fragment.kind != "Pending")
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:760,height:600),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        panel.title=fragment.kind=="Table" ? "Inspect Table":"Inspect Item"
        let pane=PreviewPane(frame:panel.contentRect(forFrameRect:panel.frame));pane.baseURL=baseURL;pane.fontSize=fontSize
        pane.show(ParseResult(revision:0,spans:[],fragments:[fragment]))
        panel.contentView=pane;panel.center()
        let controller=NSWindowController(window:panel);inspector=controller;controller.showWindow(nil)
        return controller
    }
}
