import AppKit
import MarkdownCore

/// A renderer-independent navigation shell. Outline rows are the first
/// provider; search results and comments can later publish the same tree shape
/// and document navigation targets without depending on the preview DOM.
@MainActor final class SidebarPane:NSView,NSOutlineViewDataSource,NSOutlineViewDelegate {
    private final class Cell:NSTableCellView {}
    private final class Node:NSObject {
        let heading:DocumentHeading
        weak var parent:Node?
        var children=[Node]()
        init(_ heading:DocumentHeading) {self.heading=heading}
    }

    override var isFlipped:Bool {true}
    var activateHeading:((BlockID,Bool)->Void)?
    var closeRequested:(()->Void)?

    private let header=NSView()
    private let title=NSTextField(labelWithString:"Outline")
    private let closeButton=NSButton()
    private let scroll=NSScrollView()
    private let outline=NSOutlineView()
    private let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("Outline"))
    private let emptyLabel=NSTextField(labelWithString:"No headings")
    private var roots=[Node]()
    private var ordered=[Node]()
    private var nodes=[BlockID:Node]()
    private var hasSnapshot=false
    private var changingSelection=false

    override init(frame:NSRect) {
        super.init(frame:frame)
        wantsLayer=true
        layer?.backgroundColor=NSColor.controlBackgroundColor.cgColor

        title.font=NSFont.systemFont(ofSize:NSFont.systemFontSize,weight:.regular)
        title.textColor = .secondaryLabelColor
        header.addSubview(title)

        closeButton.image=NSImage(systemSymbolName:"sidebar.left",accessibilityDescription:"Hide Sidebar")
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered=false
        closeButton.target=self
        closeButton.action=#selector(closeSidebar(_:))
        closeButton.toolTip="Hide Sidebar"
        header.addSubview(closeButton)

        outline.addTableColumn(column)
        outline.outlineTableColumn=column
        outline.headerView=nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.dataSource=self
        outline.delegate=self
        outline.target=self
        outline.doubleAction=#selector(openSelectedHeading(_:))
        outline.setAccessibilityLabel("Document outline")

        scroll.documentView=outline
        scroll.hasVerticalScroller=true
        scroll.drawsBackground=false
        scroll.autohidesScrollers=true
        addSubview(header);addSubview(scroll)

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font=NSFont.systemFont(ofSize:12)
        emptyLabel.isHidden=true
        addSubview(emptyLabel)
    }
    required init?(coder:NSCoder) {fatalError()}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor=NSColor.controlBackgroundColor.cgColor
    }

    override func layout() {
        super.layout()
        let headerHeight:CGFloat=39
        header.frame=NSRect(x:0,y:0,width:bounds.width,height:headerHeight)
        title.frame=NSRect(x:12,y:11,width:max(0,bounds.width-52),height:18)
        closeButton.frame=NSRect(x:max(0,bounds.width-34),y:7,width:27,height:26)
        scroll.frame=NSRect(x:0,y:headerHeight,width:bounds.width,height:max(0,bounds.height-headerHeight))
        emptyLabel.frame=NSRect(x:16,y:headerHeight+28,width:max(0,bounds.width-32),height:20)
        column.width=max(1,bounds.width)
    }

    func setHeadings(_ headings:[DocumentHeading],activeID:BlockID?) {
        let expanded=Set(nodes.values.filter{outline.isItemExpanded($0)}.map{$0.heading.id})
        let selected=(outline.item(atRow:outline.selectedRow) as? Node)?.heading.id
        roots.removeAll(keepingCapacity:true);ordered.removeAll(keepingCapacity:true);nodes.removeAll(keepingCapacity:true)
        var stack=[Node]()
        for heading in headings {
            let node=Node(heading);ordered.append(node);nodes[heading.id]=node
            while let last=stack.last,last.heading.level>=heading.level {stack.removeLast()}
            if let parent=stack.last {node.parent=parent;parent.children.append(node)}
            else {roots.append(node)}
            stack.append(node)
        }
        let firstSnapshot = !hasSnapshot
        hasSnapshot=true
        outline.reloadData()
        if firstSnapshot {
            for root in roots {outline.expandItem(root,expandChildren:true)}
        } else {
            for id in expanded {if let node=nodes[id] {expandAncestors(of:node);outline.expandItem(node)}}
        }
        if let selected,let node=nodes[selected] {select(node,scroll:false)}
        selectHeading(id:activeID)
        emptyLabel.isHidden = !headings.isEmpty
    }

    func selectHeading(id:BlockID?) {
        guard let id,let node=nodes[id] else{return}
        select(node,scroll:true)
    }

    private func expandAncestors(of node:Node) {
        var parent=node.parent
        while let item=parent {outline.expandItem(item);parent=item.parent}
    }
    private func select(_ node:Node,scroll:Bool) {
        expandAncestors(of:node)
        let row=outline.row(forItem:node)
        guard row>=0,outline.selectedRow != row else{return}
        changingSelection=true
        outline.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        if scroll {outline.scrollRowToVisible(row)}
        changingSelection=false
    }

    @objc private func closeSidebar(_ sender:Any?) {closeRequested?()}
    @objc private func openSelectedHeading(_ sender:Any?) {
        guard let node=outline.item(atRow:outline.selectedRow) as? Node else{return}
        activateHeading?(node.heading.id,true)
    }

    func outlineView(_ outlineView:NSOutlineView,numberOfChildrenOfItem item:Any?)->Int {
        (item as? Node)?.children.count ?? roots.count
    }
    func outlineView(_ outlineView:NSOutlineView,child index:Int,ofItem item:Any?)->Any {
        (item as? Node)?.children[index] ?? roots[index]
    }
    func outlineView(_ outlineView:NSOutlineView,isItemExpandable item:Any)->Bool {
        !(item as! Node).children.isEmpty
    }
    func outlineView(_ outlineView:NSOutlineView,viewFor tableColumn:NSTableColumn?,item:Any)->NSView? {
        let identifier=NSUserInterfaceItemIdentifier("OutlineCell")
        let cell=(outlineView.makeView(withIdentifier:identifier,owner:self) as? Cell) ?? {
            let cell=Cell(frame:NSRect(x:0,y:0,width:max(1,column.width),height:outline.rowHeight))
            cell.identifier=identifier
            let label=NSTextField(labelWithString:"")
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines=1
            cell.textField=label;cell.addSubview(label)
            return cell
        }()
        let node=item as! Node
        cell.textField?.stringValue=node.heading.title
        cell.textField?.textColor = .secondaryLabelColor
        return cell
    }
    func outlineViewSelectionDidChange(_ notification:Notification) {
        guard !changingSelection,let node=outline.item(atRow:outline.selectedRow) as? Node else{return}
        activateHeading?(node.heading.id,false)
    }

    #if DEBUG
    var debugHeadingCount:Int {ordered.count}
    var debugHeadingTitles:[String] {ordered.map{$0.heading.title}}
    func debugHeading(containing text:String)->DocumentHeading? {
        ordered.first(where:{$0.heading.title.contains(text)})?.heading
    }
    @discardableResult func debugActivateHeading(containing text:String)->Bool {
        guard let node=ordered.first(where:{$0.heading.title.contains(text)}) else{return false}
        select(node,scroll:true);activateHeading?(node.heading.id,false);return true
    }
    #endif
}
