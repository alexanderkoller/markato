import AppKit
import Foundation
import HTMLPreview
import MarkdownCore
import Network

private enum CheckError:Error,CustomStringConvertible {
    case failed(String)
    var description:String {switch self {case .failed(let message):return message}}
}

private final class DelayedImageServer {
    private let listener:NWListener
    private let queue=DispatchQueue(label:"Astra delayed image check")
    private let image:Data
    init(image:Data) throws {
        self.image=image;listener=try NWListener(using:.tcp,on:.any)
        listener.newConnectionHandler={ [weak self] connection in self?.accept(connection) }
    }
    func start() async throws->UInt16 {
        try await withCheckedThrowingContinuation {continuation in
            listener.stateUpdateHandler={ [weak self] state in
                switch state {
                case .ready:
                    self?.listener.stateUpdateHandler=nil
                    guard let port=self?.listener.port?.rawValue else {
                        continuation.resume(throwing:CheckError.failed("image server has no port"));return
                    }
                    continuation.resume(returning:port)
                case .failed:
                    self?.listener.stateUpdateHandler=nil
                    continuation.resume(throwing:CheckError.failed("image server failed"))
                default:break
                }
            }
            listener.start(queue:queue)
        }
    }
    private func accept(_ connection:NWConnection) {
        connection.start(queue:queue)
        connection.receive(minimumIncompleteLength:1,maximumLength:8192) { [weak self] _,_,_,_ in
            guard let self else{return}
            queue.asyncAfter(deadline:.now()+0.35) {
                var response=Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(self.image.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(self.image)
                connection.send(content:response,contentContext:.defaultMessage,isComplete:true,
                    completion:.contentProcessed{_ in connection.cancel()})
            }
        }
    }
    deinit {listener.cancel()}
}

@MainActor private func waitUntilReady(_ view:HTMLPreviewView) async throws {
    for _ in 0..<500 {
        if view.isEngineReady {return}
        try await Task.sleep(for:.milliseconds(10))
    }
    throw CheckError.failed("renderer did not become ready")
}

@MainActor private func render(_ entries:[RenderedEntry],in view:HTMLPreviewView,token:Int) async throws
    ->(HTMLPreviewLayout,HTMLPreviewFrame) {
    let layoutID=PreviewLayoutID(width:Double(view.bounds.width),fontSize:15,
        stylesheetGeneration:HTMLPreviewResources.stylesheetGeneration)
    let request=HTMLPreviewRenderRequest(token:token,revision:token,layoutID:layoutID,entries:entries,
        fontSize:15,baseURL:nil,viewportSize:view.bounds.size,scale:1)
    guard let layout=await withCheckedContinuation({continuation in
        view.requestLayout(request){continuation.resume(returning:$0)}
    }) else {throw CheckError.failed("layout failed")}
    guard let frame=await withCheckedContinuation({continuation in
        view.capture(token:token,scrollPoint:.zero){continuation.resume(returning:$0)}
    }) else {throw CheckError.failed("capture failed")}
    view.publish(frame);return(layout,frame)
}

@MainActor private func renderDuringEventTracking(_ entries:[RenderedEntry],in view:HTMLPreviewView,token:Int) throws
    ->(HTMLPreviewLayout,HTMLPreviewFrame) {
    let layoutID=PreviewLayoutID(width:Double(view.bounds.width),fontSize:15,
        stylesheetGeneration:HTMLPreviewResources.stylesheetGeneration)
    let request=HTMLPreviewRenderRequest(token:token,revision:token,layoutID:layoutID,entries:entries,
        fontSize:15,baseURL:nil,viewportSize:view.bounds.size,scale:1)
    var layout:HTMLPreviewLayout?,layoutFinished=false
    view.requestLayout(request) {layout=$0;layoutFinished=true}
    let layoutDeadline=Date(timeIntervalSinceNow:2)
    while !layoutFinished && Date()<layoutDeadline {
        _=RunLoop.current.run(mode:.eventTracking,before:Date(timeIntervalSinceNow:0.01))
    }
    guard let layout else{throw CheckError.failed("layout completion starved in event-tracking mode")}
    var frame:HTMLPreviewFrame?,captureFinished=false
    view.capture(token:token,scrollPoint:.zero) {frame=$0;captureFinished=true}
    let captureDeadline=Date(timeIntervalSinceNow:2)
    while !captureFinished && Date()<captureDeadline {
        _=RunLoop.current.run(mode:.eventTracking,before:Date(timeIntervalSinceNow:0.01))
    }
    guard let frame else{throw CheckError.failed("capture completion starved in event-tracking mode")}
    view.publish(frame);return(layout,frame)
}

@MainActor private func checkRenderer() async throws {
    let view=HTMLPreviewView(frame:NSRect(x:0,y:0,width:600,height:320))
    try await waitUntilReady(view)

    let styled=[
        RenderedEntry(id:"a",fragment:.init(kind:"RawHTML",from:0,to:1,
            html:"<style>.astra-preview-block { height: 999px }</style><h1>Alpha</h1>",id:"a")),
        RenderedEntry(id:"b",fragment:.init(kind:"Paragraph",from:2,to:3,html:"<p>Beta</p>",id:"b"))
    ]
    let (layout,_)=try await render(styled,in:view,token:1)
    guard layout.geometry.items.count==2,
          layout.geometry.items.allSatisfy({$0.height<999}),
          abs(layout.geometry.height-(64+layout.geometry.items.reduce(0){$0+$1.height}))<1,
          let firstHeading=view.elementRect("h1"),abs(firstHeading.minY-32)<1 else {
        throw CheckError.failed("wrapper stride invariant failed")
    }

    let wrapping=RenderedEntry(id:"wrapping",fragment:.init(kind:"Paragraph",from:0,to:1,
        html:"<p>This deliberately long preview paragraph must occupy substantially more lines when the preview pane becomes narrow, proving that a width-only resize performs browser layout rather than stretching the previous bitmap.</p>",id:"wrapping"))
    let (wide,_)=try await render([wrapping],in:view,token:2)
    view.setFrameSize(NSSize(width:280,height:320))
    let (narrow,_)=try renderDuringEventTracking([wrapping],in:view,token:3)
    guard narrow.geometry.width<wide.geometry.width-250,
          let wideHeight=wide.geometry.items.first?.height,
          let narrowHeight=narrow.geometry.items.first?.height,
          narrowHeight>wideHeight+20 else {
        throw CheckError.failed("preview did not rewrap after width change: wide=\(wide.geometry), narrow=\(narrow.geometry)")
    }
    view.setFrameSize(NSSize(width:600,height:320))

    guard let png=Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=") else {
        throw CheckError.failed("invalid fixture")
    }
    let server=try DelayedImageServer(image:png),port=try await server.start()
    let image=RenderedEntry(id:"image",fragment:.init(kind:"RawHTML",from:0,to:1,
        html:"<img style=\"display:block;width:400px\" src=\"http://127.0.0.1:\(port)/image.png\">",id:"image"))
    let following=RenderedEntry(id:"following",fragment:.init(kind:"Paragraph",from:2,to:3,
        html:"<p>Following</p>",id:"following"))
    var resource:HTMLPreviewFrame?
    view.resourceFrame={resource=$0}
    let (initial,_)=try await render([image,following],in:view,token:4)
    for _ in 0..<500 where resource == nil {try await Task.sleep(for:.milliseconds(10))}
    guard let updated=resource,
          updated.cause == .resource,
          updated.measurements.map(\.blockID)==[BlockID("image")],
          let before=initial.geometry.items.first(where:{$0.id==image.id}),
          let after=updated.geometry.items.first(where:{$0.id==image.id}),
          after.height>before.height+300,
          updated.geometry.items.first(where:{$0.id==following.id})?.height ==
            initial.geometry.items.first(where:{$0.id==following.id})?.height else {
        throw CheckError.failed("incremental image remeasurement failed")
    }

    let localURL=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        .appendingPathComponent("App/Resources/ExampleImage.png").absoluteURL
    let local=RenderedEntry(id:"local",fragment:.init(kind:"RawHTML",from:0,to:1,
        html:"<img src=\"\(localURL.absoluteString)\" alt=\"local image\">",id:"local"))
    resource=nil
    _=try await render([local],in:view,token:5)
    for _ in 0..<500 where resource == nil {try await Task.sleep(for:.milliseconds(10))}
    guard let localRect=view.elementRect("img"),localRect.height>100 else {
        throw CheckError.failed("absolute local image URL did not load: \(localURL.absoluteString), rect=\(String(describing:view.elementRect("img")))")
    }

    let details=RenderedEntry(id:"details",fragment:.init(kind:"RawHTML",from:0,to:1,
        html:"<details><summary>Expand</summary><div style=\"height:300px\">Body</div></details>",id:"details"))
    resource=nil
    let (closed,_)=try await render([details,following],in:view,token:6)
    let window=NSWindow(contentRect:view.bounds,styleMask:[.borderless],backing:.buffered,defer:false)
    window.contentView=view
    guard let summary=view.elementRect("summary") else {throw CheckError.failed("missing details summary")}
    let point=view.convert(NSPoint(x:summary.midX,y:summary.midY),to:nil)
    for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
        guard let event=NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,
            windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1) else {
            throw CheckError.failed("could not create details click")
        }
        if type == .leftMouseDown {view.mouseDown(with:event)} else {view.mouseUp(with:event)}
    }
    for _ in 0..<500 where resource == nil {try await Task.sleep(for:.milliseconds(10))}
    guard let toggled=resource,toggled.measurements.map(\.blockID)==[BlockID("details")],
          let closedItem=closed.geometry.items.first,
          let openItem=toggled.geometry.items.first,openItem.height>closedItem.height+250 else {
        throw CheckError.failed("details did not use dirty-block remeasurement: ids=\(resource?.measurements.map(\.blockID) ?? []), closed=\(closed.geometry.items.first?.height ?? -1), openHeight=\(resource?.geometry.items.first?.height ?? -1)")
    }
}

_ = NSApplication.shared
Task { @MainActor in
    do {
        try await checkRenderer();fputs("HTML PREVIEW HARNESS PASSED\n",stdout);fflush(stdout);_exit(0)
    } catch {
        fputs("HTML PREVIEW HARNESS FAILED: \(error)\n",stderr);fflush(stderr);_exit(1)
    }
}
RunLoop.main.run()
