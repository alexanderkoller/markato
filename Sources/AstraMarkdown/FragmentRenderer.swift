import AppKit
import WebKit
import MarkdownCore

private final class PreviewWebView:WKWebView {
    var wheel:((NSEvent)->Void)?
    var itemMenu:((NSEvent)->NSMenu?)?
    override func menu(for event:NSEvent)->NSMenu? {itemMenu?(event) ?? super.menu(for:event)}
    override func scrollWheel(with event:NSEvent) {
        if abs(event.scrollingDeltaX)>abs(event.scrollingDeltaY) {super.scrollWheel(with:event)}
        else {wheel?(event)}
    }
}

/// Only the source viewport and overscan enter the DOM. Cached scrolling moves
/// AppKit geometry synchronously, without JavaScript calls or Markdown rendering.
@MainActor final class PreviewPane:NSView,WKNavigationDelegate {
    override var isFlipped:Bool {true}
    var wheel:((NSEvent)->Void)? {didSet{web.wheel=wheel}}
    var openAnchor:((String)->Void)?
    var sourceFraction:((NSRange,Int)->CGFloat?)?
    var sourcePosition:((Int)->CGFloat)?
    var sourceViewportY:(()->CGFloat)?
    var sourceAlignmentOffset:(()->CGFloat)?
    var sourceBottomDistance:(()->CGFloat)?
    var sourceGeometryRevision:(()->Int)?
    var sourceContentHeight:(()->CGFloat)?
    var inspectItem:((PreviewFragment)->Void)?
    var fontSize:CGFloat=14 {didSet{flush()}}
    var baseURL:URL? {didSet{assets.baseURL=baseURL}}
    private let clip=NSClipView()
    private let canvas=FlippedView()
    private let web:PreviewWebView
    private let assets=PreviewAssets()
    private var entries=[RenderedEntry]()
    private var sentHTML=[String:String]()
    private var metrics=[String:(CGFloat,CGFloat)]()
    private var landmarkYs=[String:CGFloat]()
    private var positionedEntries=[RenderedEntry]()
    private var landmarks=ScrollLandmarks([])
    private var frozenLandmarks:ScrollLandmarks?
    private var frozenSourceHeight:CGFloat?
    private var previewCoordinateShift:Double=0
    private var positionedVersion = -1
    private(set) var isScrollMappingFrozen=false
    var scrollLandmarkCount:Int {(frozenLandmarks ?? landmarks).points.filter{!$0.boundary}.count}
    private var cachedGeometryRevision = -1
    private var anchor=0,version=0
    private var anchorFraction:CGFloat=0
    private var loaded=false,inFlight=false,dirty=false
    private var contentHeight:CGFloat=0,measuredWidth:CGFloat=0
    private var inspector:NSWindowController?
    private var pendingRevision = -1
    private(set) var lastRevision = -1
    private(set) var patchCount=0
    var preparedFragmentCount:Int {entries.count}
    var mountedIDs:[String] {entries.map{$0.id}}
    var clipOrigin:CGFloat {clip.bounds.minY}
    var webView:WKWebView {web}
    var visibleWebRange:ClosedRange<CGFloat> {
        (clip.bounds.minY-web.frame.minY)...(clip.bounds.maxY-web.frame.minY)
    }
    override init(frame:NSRect) {
        let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(assets,forURLScheme:"astra-asset")
        web=PreviewWebView(frame:.zero,configuration:config)
        super.init(frame:frame)
        wantsLayer=true;layer?.masksToBounds=true
        clip.drawsBackground=true;clip.backgroundColor = .textBackgroundColor
        clip.documentView=canvas;canvas.addSubview(web);addSubview(clip)
        web.navigationDelegate=self
        web.itemMenu={ [weak self] event in
            let menu=self?.menu(for:event) ?? NSMenu()
            let copy=NSMenuItem(title:"Copy",action:#selector(NSText.copy(_:)),keyEquivalent:"");copy.target=self?.web
            menu.insertItem(copy,at:0);return menu
        }
        config.userContentController.add(GeometryProxy(self),name:"geometry")
        web.setAccessibilityLabel("Markdown preview")
        func resource(_ name:String,_ ext:String)->String {
            guard let url=Bundle.main.url(forResource:name,withExtension:ext) else{return ""}
            return (try? String(contentsOf:url,encoding:.utf8)) ?? ""
        }
        web.loadHTMLString("<!doctype html><html><head><meta charset='utf-8'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; img-src astra-asset: data:; font-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'\"><style>\(resource("KaTeX","css"))\(resource("Preview","css"))</style></head><body><main id='preview'></main><script>\(resource("Preview","js"))</script></body></html>",baseURL:nil)
    }
    required init?(coder:NSCoder) {fatalError()}
    override func draw(_ dirtyRect:NSRect) {NSColor.textBackgroundColor.setFill();dirtyRect.fill()}
    func overlaps(_ range:NSRange)->Bool {entries.contains{NSIntersectionRange($0.fragment.range,range).length>0}}
    func setAnchor(_ position:Int,fraction:CGFloat=0) {anchor=position;anchorFraction=fraction;place()}
    func beginScrollGesture() {
        guard !isScrollMappingFrozen else{return}
        refreshLandmarks()
        frozenLandmarks=landmarks;frozenSourceHeight=sourceContentHeight?()
        previewCoordinateShift=0;isScrollMappingFrozen=true
    }
    func endScrollGesture() {
        isScrollMappingFrozen=false;frozenLandmarks=nil;frozenSourceHeight=nil
        previewCoordinateShift=0;cachedGeometryRevision = -1
        // Reconcile on the next navigation/layout event, not as a corrective
        // jump at the end of otherwise unchanged scrolling.
    }
    func rebaseSource(by delta:CGFloat) {
        frozenLandmarks?.rebaseSource(by:Double(delta))
        if let height=frozenSourceHeight {frozenSourceHeight=height+delta}
        cachedGeometryRevision = -1
    }
    func invalidate(_ edit:SourceEdit,source:TextRope,revision:Int,structural:Bool) {
        endScrollGesture()
        cachedGeometryRevision = -1
        let delta=edit.insertedLength-edit.range.length
        entries=entries.map { entry in
            let f=entry.fragment
            let after=f.from>=NSMaxRange(edit.range) && f.from != edit.range.location
            let touched=f.to>=edit.range.location && f.from<=NSMaxRange(edit.range)
            let from=after ? f.from+delta:f.from,to=after||touched ? f.to+delta:f.to
            return RenderedEntry(id:entry.id,fragment:PreviewFragment(kind:f.kind,from:max(0,from),to:max(from,to),anchorFrom:after ? f.anchorFrom+delta:f.anchorFrom,anchorTo:after||touched ? f.anchorTo+delta:f.anchorTo,markdown:f.markdown,html:f.html,containerFrom:f.containerFrom.map{after ? $0+delta:$0},containerTo:f.containerTo.map{after||touched ? $0+delta:$0}))
        }
        lastRevision = -1
    }
    func show(_ result:ParseResult) {
        show(result.fragments.map{f in RenderedEntry(id:entries.first{$0.fragment.from==f.from}?.id ?? UUID().uuidString,fragment:f)},revision:result.revision)
    }
    func show(_ next:[RenderedEntry],revision:Int) {
        let next=next.map{entry in RenderedEntry(id:entries.first{$0.fragment.from==entry.fragment.from}?.id ?? entry.id,fragment:entry.fragment)}
        let changed=entries.count != next.count || zip(entries,next).contains{$0.id != $1.id || $0.fragment.html != $1.fragment.html}
        entries=next
        cachedGeometryRevision = -1
        if changed || pendingRevision != revision {version += 1;lastRevision = -1;pendingRevision=revision;flush()}
        else {place()}
    }
    private func flush() {
        dirty=true
        guard loaded,!inFlight else{return}
        dirty=false;inFlight=true
        let encode=TimingDiagnostics.shared.begin("web.patch.encode")
        let sentVersion=version,sentRevision=pendingRevision
        let actual=Dictionary(uniqueKeysWithValues:entries.map{($0.id,$0.fragment.html ?? "")})
        let items=entries.map { entry -> [String:String] in
            var item=["id":entry.id,"kind":entry.fragment.kind,"container":String(entry.fragment.containerFrom ?? entry.fragment.from),"from":String(entry.fragment.from),"to":String(entry.fragment.to)]
            if sentHTML[entry.id] != actual[entry.id] {item["html"]=actual[entry.id]}
            return item
        }
        guard let data=try? JSONSerialization.data(withJSONObject:items),let json=String(data:data,encoding:.utf8) else {inFlight=false;return}
        TimingDiagnostics.shared.end(encode,values:["mounted":Double(entries.count),"payloadBytes":Double(data.count),"changedHTML":Double(items.filter{$0["html"] != nil}.count)])
        patchCount += 1
        let roundtrip=TimingDiagnostics.shared.begin("web.patch.roundtrip")
        web.evaluateJavaScript("astraUpdate(\(json),\(sentVersion),\(fontSize),\(roundtrip == nil ? "false":"true"))") { [weak self] result,error in
            TimingDiagnostics.shared.end(roundtrip,values:["version":Double(sentVersion),"revision":Double(sentRevision),"failed":error==nil ? 0:1])
            guard let self else{return};self.inFlight=false
            if let error {NSLog("Preview update failed: %@",error.localizedDescription)}
            else {
                self.sentHTML=actual
                if sentVersion==self.version {self.receive(result);self.lastRevision=sentRevision}
            }
            if self.dirty {self.flush()}
        }
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {loaded=true;flush()}
    fileprivate func receive(_ value:Any?) {
        guard let object=value as? [String:Any],let v=object["revision"] as? Int,v==version,let items=object["items"] as? [[String:Any]] else{return}
        let work=TimingDiagnostics.shared.begin("web.geometry.apply")
        defer {TimingDiagnostics.shared.end(work,values:["mounted":Double(items.count),"version":Double(v)])}
        if let timing=object["timing"] as? [String:Double] {
            let values=["mounted":timing["mounted"] ?? 0,"changedHTML":timing["changedHTML"] ?? 0]
            TimingDiagnostics.shared.reported("web.dom.patch",milliseconds:timing["patchMs"] ?? 0,values:values)
            TimingDiagnostics.shared.reported("web.dom.layout",milliseconds:timing["layoutMs"] ?? 0,values:values)
            TimingDiagnostics.shared.reported("web.dom.total",milliseconds:timing["totalMs"] ?? 0,values:values)
        }
        var nextMetrics=[String:(CGFloat,CGFloat)](),nextLandmarks=[String:CGFloat]()
        for item in items {
            if let id=item["id"] as? String,let y=item["y"] as? Double,let height=item["height"] as? Double {
                nextMetrics[id]=(y,height)
                if let landmark=item["landmarkY"] as? Double {nextLandmarks[id]=landmark}
            }
        }
        // A remount changes the local DOM origin. Translate that origin using a
        // retained passage, while keeping the frozen landmark distances intact.
        // Font/image geometry reports for the same DOM version do not rebase it.
        let remounted=v != positionedVersion
        var rebased=false
        if isScrollMappingFrozen,remounted {
            let shared=entries.filter{nextMetrics[$0.id] != nil && metrics[$0.id] != nil}
            let reference=shared.min{abs($0.fragment.from-anchor)<abs($1.fragment.from-anchor)}
            if let reference,let old=metrics[reference.id],let next=nextMetrics[reference.id] {
                previewCoordinateShift += Double(next.0-old.0);rebased=true
            }
        }
        let hadFrozenPoints=frozenLandmarks?.points.isEmpty == false
        let sourceReference=sourceViewportY.map{Double($0()+alignmentOffset)}
        let oldReference=sourceReference.flatMap{frozenLandmarks?.previewY(for:$0)}
        positionedEntries=entries;positionedVersion=v
        metrics=nextMetrics;landmarkYs=nextLandmarks
        cachedGeometryRevision = -1
        refreshLandmarks()
        if isScrollMappingFrozen {
            if !hadFrozenPoints {
                frozenLandmarks=landmarks;previewCoordinateShift=0
            } else {
                if remounted,!rebased,let y=sourceReference {
                    // A cold jump can outrun all overlap. Give the new local
                    // window the old mapping's coordinate at this passage.
                    if let old=oldReference,let next=landmarks.previewY(for:y) {previewCoordinateShift=next-old}
                }
                frozenLandmarks?.extend(with:landmarks,previewShift:previewCoordinateShift)
            }
        }
        contentHeight=CGFloat(object["height"] as? Double ?? 0);sizeCanvas();place()
    }
    override func layout() {
        let work=TimingDiagnostics.shared.begin("preview.layout")
        defer {TimingDiagnostics.shared.end(work,values:["width":Double(bounds.width),"height":Double(bounds.height)])}
        super.layout();clip.frame=bounds
        let changed=abs(measuredWidth-bounds.width)>0.5;measuredWidth=bounds.width
        if changed {endScrollGesture()}
        sizeCanvas();place()
        // WebKit reflows only the mounted region; ResizeObserver reports geometry.
        if changed {needsDisplay=true}
    }
    private func sizeCanvas() {
        let margin=max(1,bounds.height)
        web.frame=NSRect(x:0,y:margin,width:max(1,bounds.width),height:max(margin*3,contentHeight+margin))
        canvas.frame.size=NSSize(width:max(1,bounds.width),height:web.frame.maxY+margin)
    }
    private var alignmentOffset:CGFloat {
        guard let height=frozenSourceHeight,let y=sourceViewportY?() else{return sourceAlignmentOffset?() ?? 0}
        let viewport=max(1,bounds.height)
        return min(1,max(0,y/viewport))*min(1,max(0,(height-viewport-y)/viewport))*viewport/2
    }
    private func refreshLandmarks() {
        guard let sourcePosition else{return}
        let revision=sourceGeometryRevision?() ?? -1
        guard revision != cachedGeometryRevision || sourceGeometryRevision==nil else{return}
        var points=positionedEntries.compactMap {entry -> ScrollLandmark? in
            guard let y=landmarkYs[entry.id] else{return nil}
            return ScrollLandmark(offset:entry.fragment.anchorFrom,sourceY:Double(sourcePosition(entry.fragment.anchorFrom)),previewY:Double(y))
        }
        // Bounded previews may contain no heading or image (e.g. the middle of
        // an 800-row table). Use the region edges, never every block, as fallback.
        if let first=positionedEntries.first,let metric=metrics[first.id] {
            points.append(ScrollLandmark(offset:first.fragment.anchorFrom,sourceY:Double(sourcePosition(first.fragment.anchorFrom)),previewY:Double(metric.0),boundary:true))
        }
        if let last=positionedEntries.last,let metric=metrics[last.id] {
            points.append(ScrollLandmark(offset:last.fragment.anchorTo,sourceY:Double(sourcePosition(last.fragment.anchorTo)),previewY:Double(metric.0+metric.1),boundary:true))
        }
        landmarks=ScrollLandmarks(points);cachedGeometryRevision=revision
    }
    private func place() {
        let work=TimingDiagnostics.shared.begin("preview.position")
        defer {TimingDiagnostics.shared.end(work,values:["clipY":Double(clip.bounds.minY),"mounted":Double(entries.count),"sourceY":Double(sourceViewportY?() ?? 0)])}
        let entries=positionedEntries
        guard !entries.isEmpty else{return}
        if sourcePosition != nil,let sourceViewportY {
            let adjustment=alignmentOffset
            let viewportY=sourceViewportY()+adjustment
            if !isScrollMappingFrozen {refreshLandmarks()}
            let map=frozenLandmarks ?? landmarks
            guard let y=map.previewY(for:Double(viewportY)) else{return}
            var target=web.frame.minY+CGFloat(y+(isScrollMappingFrozen ? previewCoordinateShift:0))-adjustment
            let bottom=frozenSourceHeight.map{max(0,$0-sourceViewportY()-bounds.height)} ?? sourceBottomDistance?()
            if let bottom,bottom<bounds.height {
                let weight=max(0,1-bottom/max(1,bounds.height))
                let endTarget=web.frame.minY+contentHeight-bounds.height+16
                target=target*(1-weight)+endTarget*weight
            }
            moveClip(to:target)
            return
        }
        let entry=entries.first{anchor >= $0.fragment.from && anchor < $0.fragment.to}
            ?? entries.first{$0.fragment.from>=anchor} ?? entries.last!
        guard let (y,height)=metrics[entry.id] else{return}
        let f=entry.fragment
        let fraction=sourceFraction?(NSRange(location:f.anchorFrom,length:max(0,f.anchorTo-f.anchorFrom)),anchor)
            ?? max(0,min(1,CGFloat(anchor-f.anchorFrom)/CGFloat(max(1,f.anchorTo-f.anchorFrom))))
        let target=web.frame.minY+y+height*fraction-anchorFraction
        moveClip(to:target)
    }
    private func moveClip(to target:CGFloat) {
        let work=TimingDiagnostics.shared.begin("preview.clip.move")
        let before=clip.bounds.minY
        defer {TimingDiagnostics.shared.end(work,values:["targetY":Double(target),"clipY":Double(clip.bounds.minY),"deltaY":Double(clip.bounds.minY-before)])}
        CATransaction.begin();CATransaction.setDisableActions(true)
        clip.scroll(to:NSPoint(x:0,y:max(0,target)))
        CATransaction.commit()
    }
    func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
        guard navigationAction.navigationType == .linkActivated,let url=navigationAction.request.url else{decisionHandler(.allow);return}
        decisionHandler(.cancel)
        if let fragment=url.fragment {openAnchor?(fragment)}
        else if ["http","https","mailto"].contains(url.scheme?.lowercased() ?? "") {NSWorkspace.shared.open(url)}
    }
    func webViewWebContentProcessDidTerminate(_ webView:WKWebView) {loaded=false;sentHTML.removeAll();metrics.removeAll();web.reload()}
    func debugGeometry()->String {"mounted=\(entries.count), height=\(contentHeight), clip=\(clip.bounds.minY), patches=\(patchCount)"}
    override func menu(for event:NSEvent)->NSMenu? {
        let menu=NSMenu();menu.addItem(withTitle:"Inspect Item",action:#selector(inspect(_:)),keyEquivalent:"").target=self;return menu
    }
    @objc private func inspect(_ sender:Any?) {
        guard let f=entries.first(where:{$0.fragment.from<=anchor && $0.fragment.to>=anchor})?.fragment else{return}
        if f.kind=="Table",let inspectItem {inspectItem(f);return}
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:760,height:600),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        panel.title="Inspect Item"
        let pane=PreviewPane(frame:panel.contentRect(forFrameRect:panel.frame));pane.baseURL=baseURL;pane.fontSize=fontSize
        pane.show(ParseResult(revision:0,spans:[],fragments:[f]));pane.setAnchor(f.from)
        pane.wheel={ [weak pane] event in guard let pane else{return};pane.clip.scroll(to:NSPoint(x:0,y:max(0,pane.clip.bounds.minY-event.scrollingDeltaY))) }
        panel.contentView=pane;panel.center();inspector=NSWindowController(window:panel);inspector?.showWindow(nil)
    }
}

private final class GeometryProxy:NSObject,WKScriptMessageHandler {
    weak var pane:PreviewPane?
    init(_ pane:PreviewPane) {self.pane=pane}
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {pane?.receive(message.body)}
}
