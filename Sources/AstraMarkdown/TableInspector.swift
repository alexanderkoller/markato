import AppKit
import MarkdownCore

/// An independent row window rendered by the same Markdown/HTML libraries.
@MainActor final class TableInspector:NSWindowController {
    private let scroll=NSScrollView(),canvas=FlippedView()
    private let pane=PreviewPane(frame:.zero)
    private let renderer=HTMLWorker()
    private let source:TextRope
    private let firstLine:Int,finalLine:Int
    private var firstRow = -1,generation=0
    private var observer:NSObjectProtocol?
    init(fragment:PreviewFragment,source:TextRope,baseURL:URL?,fontSize:CGFloat) {
        self.source=source
        firstLine=source.line(at:fragment.containerFrom ?? fragment.from)
        finalLine=source.line(at:fragment.containerTo ?? fragment.to)
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:760,height:600),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        super.init(window:panel);panel.title="Inspect Table";panel.center()
        scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.documentView=canvas
        canvas.addSubview(pane);pane.baseURL=baseURL;pane.fontSize=fontSize
        pane.wheel={ [weak self] event in self?.scroll.scrollWheel(with:event) }
        panel.contentView=scroll;scroll.contentView.postsBoundsChangedNotifications=true
        observer=NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:scroll.contentView,queue:.main) { [weak self] _ in MainActor.assumeIsolated {self?.renderRows()} }
        renderRows()
    }
    required init?(coder:NSCoder) {fatalError()}
    deinit {if let observer {NotificationCenter.default.removeObserver(observer)}}
    private func renderRows() {
        let rowCount=max(0,finalLine-firstLine-1),rowHeight:CGFloat=34
        let first=min(max(0,Int(scroll.contentView.bounds.minY/rowHeight)-12),max(0,rowCount-1))
        let end=min(rowCount,first+max(40,Int(scroll.contentSize.height/rowHeight)+24))
        let width=max(1,scroll.contentSize.width)
        let changed=first != firstRow || abs(pane.frame.width-width)>0.5
        canvas.frame.size=NSSize(width:width,height:max(scroll.contentSize.height,CGFloat(rowCount+1)*rowHeight+32))
        pane.frame=NSRect(x:0,y:CGFloat(first)*rowHeight,width:width,height:CGFloat(max(1,end-first))*rowHeight+64)
        guard changed else{return};firstRow=first;generation += 1;let version=generation
        let header=source.string(in:source.lines(firstLine,firstLine+2))
        let rows=source.lines(firstLine+2+first,firstLine+2+end)
        renderer.request(text:header+source.string(in:rows),from:rows.location,revision:version) { [weak self] result in
            guard let self,self.generation==version,case .success(let parsed)=result else{return}
            self.pane.show(parsed);self.pane.setAnchor(rows.location)
        }
    }
}
