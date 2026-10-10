import AppKit
import WebKit
import MarkdownCore

private final class PreviewWebView:WKWebView {
    var wheel:((NSEvent)->Void)?
    var itemMenu:((NSEvent)->NSMenu?)?
    private var horizontalGesture:Bool?
    private var axisReset:DispatchWorkItem?
    override func menu(for event:NSEvent)->NSMenu? {itemMenu?(event) ?? super.menu(for:event)}
    override func scrollWheel(with event:NSEvent) {
        axisReset?.cancel();axisReset=nil
        if event.phase.contains(.began) {horizontalGesture=nil}
        let phased = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        if phased,horizontalGesture==nil,event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            horizontalGesture=abs(event.scrollingDeltaX)>abs(event.scrollingDeltaY)
        }
        if horizontalGesture ?? (abs(event.scrollingDeltaX)>abs(event.scrollingDeltaY)) {super.scrollWheel(with:event)}
        else {wheel?(event)}
        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) || event.phase.contains(.cancelled) || !phased {
            horizontalGesture=nil
        } else if event.phase.contains(.ended) {
            let reset=DispatchWorkItem { [weak self] in self?.horizontalGesture=nil }
            axisReset=reset;DispatchQueue.main.asyncAfter(deadline:.now()+0.15,execute:reset)
        }
    }
}

/// One presentation surface owns all of its native and WebKit coordinates.
/// The inactive surface stays hidden until its complete presentation is ready.
private final class PreviewSurface {
    let clip=NSClipView()
    let canvas=FlippedView()
    let web:PreviewWebView
    let assets:PreviewAssets
    var ready=false
    var navigation:WKNavigation?
    var request:PreviewRequest?
    var observed:PreviewGeometry?
    var preparedContent:PreviewContent?
    var preparedAssetBase:String?
    init(web:PreviewWebView,assets:PreviewAssets) {
        self.web=web;self.assets=assets
        clip.drawsBackground=true;clip.backgroundColor = .textBackgroundColor
        clip.documentView=canvas;canvas.addSubview(web)
        setVisible(false)
    }
    func setVisible(_ visible:Bool) {
        clip.isHidden = !visible;web.isHidden = !visible
        web.setAccessibilityHidden(!visible)
    }
    func size(contentHeight:CGFloat,width:CGFloat,viewportHeight:CGFloat) {
        let margin=max(1,viewportHeight)
        let frame=NSRect(x:0,y:margin,width:max(1,width),height:max(margin*3,contentHeight+margin))
        if web.frame != frame {web.frame=frame}
        let size=NSSize(width:max(1,width),height:web.frame.maxY+margin)
        if canvas.frame.size != size {canvas.frame.size=size}
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
    let metrics:[String:(CGFloat,CGFloat)]
    init(request:PreviewRequest,geometry:PreviewGeometry,surface:PreviewSurface,map:ScrollLandmarks?,sourceGeometryRevision:Int?,viewportHeight:CGFloat) {
        self.request=request;self.geometry=geometry;self.surface=surface
        self.map=map;self.sourceGeometryRevision=sourceGeometryRevision;self.viewportHeight=viewportHeight
        metrics=Dictionary(uniqueKeysWithValues:geometry.items.map{($0.id,($0.y,$0.height))})
    }
}

/// Prepared scrolling reads one committed presentation and moves its native clip.
@MainActor final class PreviewPane:NSView,WKNavigationDelegate {
    var preparedDocument:PreparedDocument?
    override var isFlipped:Bool {true}
    var scrolling:PreviewScrolling = .independent {didSet {sourceLayoutChanged()}}
    var openAnchor:((String)->Void)?
    var fontSize:CGFloat=14 {didSet {if fontSize != oldValue {endScrollGesture();requestPresentation()}}}
    var baseURL:URL? {didSet {if baseURL != oldValue {endScrollGesture();requestPresentation()}}}
    private let surfaces:[PreviewSurface]
    private var displayed:PreviewSurface {committed?.surface ?? surfaces[0]}
    private var web:PreviewWebView {displayed.web}
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
    private var bootstrapHTML=""
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
    var isPreparingPresentation:Bool {desired != nil}
    var displayedSourceRange:NSRange? {
        guard let content=committed?.request.content,let first=content.entries.first else{return nil}
        return NSRange(location:first.fragment.from,length:max(0,content.sourceLength-first.fragment.from))
    }
    private func covers(_ content:PreviewContent,visible:NSRange)->Bool {
        // A complete first semantic block may follow leading blank source
        // lines. Those lines are already prepared and add no preview element.
        let start=content.entries.first.map{$0.fragment.kind=="Pending" ? $0.fragment.from:0} ?? 0
        guard start<=visible.location,content.sourceLength>=NSMaxRange(visible) else{return false}
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
    var isShowingLoadingState:Bool {!loadingView.isHidden}
    var clipOrigin:CGFloat {clip.bounds.minY}
    var webView:WKWebView {web}
    var visibleWebRange:ClosedRange<CGFloat> {
        let top=clip.bounds.minY-web.frame.minY
        return top...(top+bounds.height)
    }
    #if DEBUG
    private(set) var patchCount=0
    var scrollLandmarkCount:Int {committed?.map?.points.count ?? 0}
    var semanticLandmarkOffsets:[Int] {committed?.map?.points.filter{!$0.boundary}.map(\.offset) ?? []}
    var debugScrollLandmarks:[ScrollLandmark] {committed?.map?.points ?? []}
    #endif
    override init(frame:NSRect) {
        func makeSurface()->PreviewSurface {
            let assets=PreviewAssets()
            let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
            config.setURLSchemeHandler(assets,forURLScheme:"astra-asset")
            return PreviewSurface(web:PreviewWebView(frame:.zero,configuration:config),assets:assets)
        }
        surfaces=[makeSurface(),makeSurface()]
        super.init(frame:frame)
        wantsLayer=true;layer?.masksToBounds=true
        for surface in surfaces {addSubview(surface.clip)}
        loadingView.wantsLayer=true;loadingView.layer?.backgroundColor=NSColor.textBackgroundColor.cgColor
        loadingLabel.textColor = .secondaryLabelColor;loadingLabel.alignment = .center
        loadingView.addSubview(loadingLabel);addSubview(loadingView);loadingView.isHidden=true
        let itemMenu:(NSEvent)->NSMenu? = { [weak self] event in
            let menu=self?.menu(for:event) ?? NSMenu()
            let copy=NSMenuItem(title:"Copy",action:#selector(NSText.copy(_:)),keyEquivalent:"");copy.target=self?.web
            menu.insertItem(copy,at:0);return menu
        }
        func resource(_ name:String,_ ext:String)->String {
            guard let url=Bundle.main.url(forResource:name,withExtension:ext),let text=try? String(contentsOf:url,encoding:.utf8) else{preconditionFailure("Missing bundled preview resource: \(name).\(ext)")}
            return text
        }
        let html="<!doctype html><html><head><meta charset='utf-8'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; img-src astra-asset: data:; font-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'\"><style>\(resource("KaTeX","css"))\(resource("Preview","css"))</style></head><body><main id='preview'></main><script>\(resource("Preview","js"))</script></body></html>"
        bootstrapHTML=html
        for surface in surfaces {
            let view=surface.web
            view.navigationDelegate=self;view.itemMenu=itemMenu
            view.wheel={ [weak self] event in self?.handleVerticalScroll(event) }
            view.configuration.userContentController.add(GeometryProxy(self,view:view),name:"geometry")
            view.setAccessibilityLabel("Markdown preview")
        }
        // The first viewport needs one browser document. Bootstrap the spare
        // only after publication, so its fonts/CSS do not compete at startup.
        surfaces[0].navigation=surfaces[0].web.loadHTMLString(bootstrapHTML,baseURL:nil)
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
              let committed,committed.geometry.height>bounds.height,
              abs(event.scrollingDeltaY)>=abs(event.scrollingDeltaX) else{return false}
        independentOrigin=max(0,visibleWebRange.lowerBound-event.scrollingDeltaY);place();return true
    }
    func navigatePreview(toEnd:Bool) {
        guard let committed else{return}
        independentOrigin=toEnd ? max(0,committed.geometry.height-bounds.height):0;place()
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
    func show(_ result:ParseResult) {
        let existing=Dictionary((content?.entries ?? []).map{($0.fragment.from,$0.id)},uniquingKeysWith:{first,_ in first})
        show(result.fragments.map{RenderedEntry(id:$0.id ?? existing[$0.from] ?? UUID().uuidString,fragment:$0)},revision:result.revision)
    }
    func show(_ entries:[RenderedEntry],revision:Int) {
        let extent=source?.sourceLength ?? entries.last?.fragment.to ?? 0
        let next=PreviewContent(revision:revision,entries:entries,sourceLength:extent)
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
        if canExtendDisplayedDocument(request) || displayedPatch != nil {surface=displayed}
        else {
            guard let ready=surfaces.first(where:{$0.ready && $0 !== committed?.surface}) else{return}
            surface=ready
        }
        rendering=request
        if surface !== committed?.surface {surface.setVisible(false)}
        surface.request=request;surface.observed=nil;surface.assets.baseURL=request.baseURL
        surface.size(contentHeight:max(1,committed?.geometry.height ?? 0),width:request.width,viewportHeight:bounds.height)
        #if DEBUG
        let encode=TimingDiagnostics.shared.begin("web.patch.encode")
        #endif
        let baseKey=request.baseURL?.absoluteString ?? ""
        let previous=surface.preparedAssetBase==baseKey ? Dictionary((surface.preparedContent?.entries ?? []).map{($0.id,$0.fragment.html!)},uniquingKeysWith:{first,_ in first}):[:]
        let indexed=surface === committed?.surface && surface.preparedAssetBase==baseKey
            ? displayedPatch ?? indexedPatch(from:surface.preparedContent,to:request):nil
        let items:[[String:Any]]=indexed?.items ?? request.entries.map {entry in
            let fragment=entry.fragment
            var item:[String:Any]=["id":entry.id,"from":fragment.from,"to":fragment.to]
            if previous[entry.id] != fragment.html {item["html"]=fragment.html!}
            return item
        }
        guard let data=try? JSONSerialization.data(withJSONObject:items),let json=String(data:data,encoding:.utf8) else {
            finishPreparation(request);return
        }
        #if DEBUG
        TimingDiagnostics.shared.end(encode,values:["mounted":Double(request.entries.count),"htmlEntries":Double(items.filter{$0["html"] != nil}.count),"payloadBytes":Double(data.count)])
        patchCount += 1
        let roundtrip=TimingDiagnostics.shared.begin("web.patch.roundtrip")
        #endif
        let patch:(Any?)->Void = { [weak self] state in
            guard let self,self.isCurrent(request,surface:surface) else {self?.finishPreparation(request);return}
            if surface === self.committed?.surface,self.isScrollMappingFrozen,self.coversSourceViewport {
                self.finishPreparation(request);return
            }
            let baseKeyData=try? JSONSerialization.data(withJSONObject:[request.baseURL?.absoluteString ?? ""])
            let baseJSON=baseKeyData.flatMap{String(data:$0,encoding:.utf8)} ?? "[\"\"]"
            // Appending below the viewport retains the actual selection and
            // horizontal state. Restoring an earlier snapshot would overwrite
            // interaction that happened while the new resources were settling.
            let restoreState=surface === self.committed?.surface ? "":"astraRestoreViewState(\(state as? String ?? "null"));"
            let update:String
            if let indexed {
                update="astraPatch(\(json),\(request.id),\(request.fontSize),\(baseJSON)[0],\(indexed.suffixIndex),\(indexed.shift)"
            } else {update="astraUpdate(\(json),\(request.id),\(request.fontSize),\(baseJSON)[0]"}
            #if DEBUG
            let script="const patched=\(update),\(roundtrip == nil ? "false":"true"));await astraReady(\(request.width));\(restoreState)const started=performance.now(),measured=geometry();if(patched?.timing){measured.timing={...patched.timing,layoutMs:performance.now()-started,totalMs:patched.timing.patchMs+performance.now()-started};}return JSON.stringify(measured);"
            #else
            let script="\(update));await astraReady(\(request.width));\(restoreState)return JSON.stringify(geometry());"
            #endif
            surface.web.callAsyncJavaScript(script,arguments:[:],in:nil,in:.page) { [weak self] outcome in
                guard let self else{return}
                // A superseded success still describes this surface's DOM.
                // Navigation or a newer request makes that observation stale.
                if surface.request?.id==request.id {
                    switch outcome {
                    case .success:surface.preparedContent=request.content;surface.preparedAssetBase=baseKey
                    case .failure:surface.preparedContent=nil;surface.preparedAssetBase=nil
                    }
                }
                let value:Any?
                switch outcome {
                case .success(let result):
                    value=(result as? String).flatMap{$0.data(using:.utf8)}.flatMap{try? JSONSerialization.jsonObject(with:$0)}
                case .failure(let error):
                    let detail=(error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                    NSLog("Preview presentation %ld failed (%@ %ld): %@",request.id,(error as NSError).domain,(error as NSError).code,detail)
                    #if DEBUG
                    TimingDiagnostics.shared.end(roundtrip,values:["failed":1])
                    #endif
                    self.finishPreparation(request);return
                }
                #if DEBUG
                TimingDiagnostics.shared.end(roundtrip,values:["version":Double(request.id),"revision":Double(request.revision),"failed":0])
                #endif
                guard self.isCurrent(request,surface:surface),let geometry=PreviewGeometry(value,request:request) else {
                    self.finishPreparation(request);return
                }
                #if DEBUG
                self.recordGeometry(value)
                #endif
                if let observed=surface.observed,observed.measurement>geometry.measurement,!observed.sameLayout(as:geometry) {
                    self.finishPreparation(request,retry:true);return
                }
                surface.observed=geometry
                surface.size(contentHeight:geometry.height,width:request.width,viewportHeight:self.bounds.height)
                guard let position=self.presentationPosition(request,geometry:geometry) else{self.finishPreparation(request);return}
                // Local edit patches can commit as soon as their new geometry
                // is known. Same-revision viewport extension keeps the paint
                // fence used by the calibrated scrolling path.
                if indexed != nil,surface === self.committed?.surface {
                    self.commit(request,geometry:geometry,surface:surface,position:position)
                    self.finishPreparation(request);return
                }
                let snapshot=WKSnapshotConfiguration()
                let top=position.origin
                // Fence the destination plus one viewport on either side, not
                // an unbounded document texture. The whole DOM stays mounted.
                let paintTop=max(0,top-self.bounds.height)
                snapshot.rect=NSRect(x:0,y:paintTop,width:request.width,
                    height:min(surface.web.bounds.height-paintTop,self.bounds.height*3))
                snapshot.snapshotWidth=1;snapshot.afterScreenUpdates=true
                #if DEBUG
                let paintWait=TimingDiagnostics.shared.begin("web.paint.wait")
                #endif
                surface.web.takeSnapshot(with:snapshot) { [weak self] image,error in
                    #if DEBUG
                    TimingDiagnostics.shared.end(paintWait)
                    #endif
                    guard let self else{return}
                    if let error {NSLog("Preview paint fence failed: %@",error.localizedDescription)}
                    guard self.isCurrent(request,surface:surface),image != nil,error==nil,
                          surface.observed?.sameLayout(as:geometry)==true else {
                        self.finishPreparation(request,retry:error==nil);return
                    }
                    guard let position=self.presentationPosition(request,geometry:geometry) else{self.finishPreparation(request);return}
                    let currentTop=position.origin
                    guard currentTop>=snapshot.rect.minY-0.001,
                          currentTop+self.bounds.height<=snapshot.rect.maxY+0.001 else {
                        self.finishPreparation(request,retry:true);return
                    }
                    self.commit(request,geometry:geometry,surface:surface,position:position)
                    self.finishPreparation(request)
                }
            }
        }
        if let committed, surface !== committed.surface {
            committed.surface.web.evaluateJavaScript("JSON.stringify(astraViewState())") {state,_ in patch(state)}
        } else {
            // The initial document has no selection or horizontal state to
            // transfer. Publish it without an empty state-capture round trip.
            patch(nil)
        }
    }
    private func isCurrent(_ request:PreviewRequest,surface:PreviewSurface)->Bool {
        desired?.id==request.id && rendering?.id==request.id && surfaces.contains(where:{$0 === surface}) && surface.ready
            && surface.request?.id==request.id && bounds.width==request.width && bounds.height>0.5
    }
    private func finishPreparation(_ request:PreviewRequest,retry:Bool=false) {
        guard rendering?.id==request.id else{return}
        rendering=nil
        presentationSettled?()
        if desired?.id != request.id || retry {preparePresentation()}
    }
    #if DEBUG
    private func recordGeometry(_ value:Any?) {
        guard let object=value as? [String:Any],let timing=object["timing"] as? [String:Double] else{return}
        let values=["mounted":timing["mounted"] ?? 0,"changedHTML":timing["changedHTML"] ?? 0]
        for (name,key) in [("web.dom.patch","patchMs"),("web.dom.layout","layoutMs"),("web.dom.total","totalMs")] {
            TimingDiagnostics.shared.reported(name,milliseconds:timing[key] ?? 0,values:values)
        }
    }
    #endif
    private struct PresentationPosition {
        let map:ScrollLandmarks?
        let sourceGeometryRevision:Int?
        let origin:CGFloat
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
    private func makeMap(_ request:PreviewRequest,geometry:PreviewGeometry)->ScrollLandmarks? {
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
            points.append(ScrollLandmark(offset:entry.fragment.from,sourceY:Double(y),previewY:Double(previewY)))
        }
        guard revision==source.geometryRevision else{return nil}
        return ScrollLandmarks(points).viewportMap(sourceHeight:Double(source.contentHeight),viewportHeight:Double(bounds.height),previewHeight:Double(geometry.height))
    }
    private func presentationPosition(_ request:PreviewRequest,geometry:PreviewGeometry)->PresentationPosition? {
        switch scrolling {
        case .independent:
            guard let origin=targetOrigin(height:geometry.height,map:nil) else{return nil}
            return PresentationPosition(map:nil,sourceGeometryRevision:nil,origin:origin)
        case .synchronized(let source):
            guard covers(request.content,visible:source.visibleSourceRange) else{return nil}
            guard let map=makeMap(request,geometry:geometry) else{return nil}
            guard let origin=targetOrigin(height:geometry.height,map:map) else{return nil}
            return PresentationPosition(map:map,sourceGeometryRevision:source.geometryRevision,origin:origin)
        }
    }
    fileprivate func observe(_ value:Any?,from view:WKWebView) {
        guard let surface=surfaces.first(where:{$0.web === view}),surface.ready,let request=surface.request,
              let geometry=PreviewGeometry(value,request:request),geometry.measurement>(surface.observed?.measurement ?? -1) else{return}
        let changed=surface.observed.map{!$0.sameLayout(as:geometry)} == true
        #if DEBUG
        if let old=surface.observed,changed {
            let pairs=zip(old.items,geometry.items)
            TimingDiagnostics.shared.reported("web.geometry.change",milliseconds:0,values:[
                "oldHeight":Double(old.height),"height":Double(geometry.height),
                "oldWidth":Double(old.width),"width":Double(geometry.width),
                "maximumYDelta":pairs.map{abs(Double($0.0.y-$0.1.y))}.max() ?? 0,
                "maximumHeightDelta":pairs.map{abs(Double($0.0.height-$0.1.height))}.max() ?? 0,
                "committed":surface === committed?.surface ? 1:0,
                "request":Double(request.id)])
        }
        #endif
        surface.observed=geometry
        if surface === committed?.surface,changed,rendering==nil,desired==nil,committed?.request.id==request.id {requestPresentation()}
    }
    private func commit(_ request:PreviewRequest,geometry:PreviewGeometry,surface:PreviewSurface,position:PresentationPosition) {
        guard isCurrent(request,surface:surface) else{return}
        if isScrollMappingFrozen,coversSourceViewport,committed?.request.revision==request.revision {return}
        if let source {
            guard source.contentRevision==request.revision,position.sourceGeometryRevision==source.geometryRevision,
                  covers(request.content,visible:source.visibleSourceRange) else{return}
        }
        let previous=committed?.surface
        let hadFocus=previous.map{(window?.firstResponder as? NSView)?.isDescendant(of:$0.web)==true} == true
        CATransaction.begin();CATransaction.setDisableActions(true)
        committed=CommittedPresentation(request:request,geometry:geometry,surface:surface,map:position.map,sourceGeometryRevision:position.sourceGeometryRevision,viewportHeight:bounds.height)
        preparedDocument?.recordPreviewHeights(Dictionary(uniqueKeysWithValues:geometry.items.map{($0.id,Double($0.height))}),revision:request.revision)
        desired=nil
        surface.size(contentHeight:geometry.height,width:request.width,viewportHeight:bounds.height)
        moveClip(to:position.origin)
        if surface !== previous {previous?.setVisible(false);surface.setVisible(true)}
        updateLoadingState()
        for spare in surfaces where spare.navigation==nil && !spare.ready {
            spare.navigation=spare.web.loadHTMLString(bootstrapHTML,baseURL:nil)
        }
        if hadFocus {window?.makeFirstResponder(surface.web)}
        assert(surfaces.filter{!$0.clip.isHidden}.count==1 && !surface.web.isHidden)
        CATransaction.commit()
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
        guard let surface=surfaces.first(where:{$0.web === webView}),surface.navigation === navigation else{return}
        surface.preparedContent=nil;surface.preparedAssetBase=nil
        surface.ready=true;preparePresentation()
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
        if let committed {committed.surface.size(contentHeight:committed.geometry.height,width:committed.request.width,viewportHeight:bounds.height)}
        place();preparePresentation()
    }
    private func refreshMap() {
        guard let committed,let source,(committed.sourceGeometryRevision != source.geometryRevision || committed.viewportHeight != bounds.height) else{return}
        guard let map=makeMap(committed.request,geometry:committed.geometry) else{return}
        self.committed=CommittedPresentation(request:committed.request,geometry:committed.geometry,surface:committed.surface,map:map,sourceGeometryRevision:source.geometryRevision,viewportHeight:bounds.height)
    }
    private func place() {
        guard let committed else{return}
        if let source,source.contentRevision != committed.request.revision {return}
        if !isScrollMappingFrozen {refreshMap()}
        guard hasCurrentMap,let current=self.committed,let origin=targetOrigin(height:current.geometry.height,map:current.map) else{return}
        moveClip(to:origin)
    }
    private func moveClip(to origin:CGFloat) {
        guard let committed else{return}
        CATransaction.begin();CATransaction.setDisableActions(true)
        committed.surface.clip.scroll(to:NSPoint(x:0,y:committed.surface.web.frame.minY+origin))
        independentOrigin=origin
        CATransaction.commit()
    }
    func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
        guard navigationAction.navigationType == .linkActivated,let url=navigationAction.request.url else{decisionHandler(.allow);return}
        decisionHandler(.cancel)
        if let fragment=url.fragment {openAnchor?(fragment)}
        else if ["http","https","mailto"].contains(url.scheme?.lowercased() ?? "") {NSWorkspace.shared.open(url)}
    }
    func webViewWebContentProcessDidTerminate(_ webView:WKWebView) {
        guard let surface=surfaces.first(where:{$0.web === webView}) else{return}
        surface.preparedContent=nil;surface.preparedAssetBase=nil
        surface.ready=false;surface.observed=nil;surface.setVisible(false)
        if rendering?.id==surface.request?.id {rendering=nil}
        if surface === committed?.surface {committed=nil}
        surface.request=nil
        surface.navigation=webView.loadHTMLString(bootstrapHTML,baseURL:nil)
        updateLoadingState();requestPresentation()
    }
    #if DEBUG
    var debugAlignmentDrift:Double {
        guard let committed,let source,let target=committed.map?.previewY(for:Double(source.viewportOrigin)) else{return 0}
        return Double(visibleWebRange.lowerBound)-target
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

private final class GeometryProxy:NSObject,WKScriptMessageHandler {
    weak var pane:PreviewPane?
    weak var view:WKWebView?
    init(_ pane:PreviewPane,view:WKWebView) {self.pane=pane;self.view=view}
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {
        guard let pane,let view else{return}
        pane.observe(message.body,from:view)
    }
}
