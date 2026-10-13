import AppKit
import MarkdownCore

/// The sidebar presents navigation providers without depending on preview DOM
/// details. Outline and comments share the same reveal/focus behavior.
@MainActor final class SidebarPane:NSView,NSOutlineViewDataSource,NSOutlineViewDelegate,
                                    NSTableViewDataSource,NSTableViewDelegate {
    enum Mode:Int {case outline,comments}
    private enum CommentFilter:Int {case open,resolved,all}
    private final class Cell:NSTableCellView {}
    private final class CommentCell:NSTableCellView {
        let card=NSView(),label=NSTextField(wrappingLabelWithString:"")
        override init(frame:NSRect) {
            super.init(frame:frame);card.wantsLayer=true;card.layer?.cornerRadius=6
            label.maximumNumberOfLines=3;label.lineBreakMode = .byWordWrapping
            label.font=NSFont.systemFont(ofSize:12);label.textColor = .labelColor
            label.isSelectable=false;label.isEditable=false;label.allowsEditingTextAttributes=false
            card.addSubview(label);addSubview(card);textField=label
        }
        required init?(coder:NSCoder) {fatalError()}
        override func layout() {
            super.layout();card.frame=bounds.insetBy(dx:6,dy:4);label.frame=card.bounds.insetBy(dx:9,dy:6)
        }
        func configure(text:String,selected:Bool) {
            label.stringValue=text
            card.layer?.backgroundColor=NSColor(calibratedRed:0.98,green:0.91,blue:0.68,alpha:1).cgColor
            card.layer?.borderWidth=selected ? 1:0
            card.layer?.borderColor=NSColor.controlAccentColor.cgColor
        }
    }
    private final class Node:NSObject {
        let heading:DocumentHeading
        weak var parent:Node?
        var children=[Node]()
        init(_ heading:DocumentHeading) {self.heading=heading}
    }

    override var isFlipped:Bool {true}
    var activateHeading:((BlockID,Bool)->Void)?
    var activateComment:((String,Bool)->Void)?
    var openComment:((String)->Void)?
    var clearCommentSelection:(()->Void)?
    var toggleCommentResolved:((String)->Void)?

    private let modeControl=NSSegmentedControl(labels:["Outline","Comments"],trackingMode:.selectOne,target:nil,action:nil)
    private let outlineScroll=NSScrollView()
    private let outline=NSOutlineView()
    private let outlineColumn=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("Outline"))
    private let outlineEmpty=NSTextField(labelWithString:"No headings")
    private let commentScroll=NSScrollView()
    private let commentTable=NSTableView()
    private let commentColumn=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("Comments"))
    private let commentEmpty=NSTextField(labelWithString:"No comments")
    private let commentFilter=NSSegmentedControl(labels:["Open","Resolved","All"],trackingMode:.selectOne,target:nil,action:nil)
    private let resolveButton=NSButton(title:"Resolve",target:nil,action:nil)

    private var roots=[Node](),ordered=[Node](),nodes=[BlockID:Node]()
    private var allComments=[ResolvedMarkdownComment](),comments=[ResolvedMarkdownComment]()
    private var hasSnapshot=false,changingSelection=false
    private(set) var mode:Mode = .outline

    override init(frame:NSRect) {
        super.init(frame:frame)
        wantsLayer=true;layer?.backgroundColor=NSColor.controlBackgroundColor.cgColor
        modeControl.selectedSegment=0;modeControl.target=self;modeControl.action=#selector(changeMode(_:))
        modeControl.setAccessibilityLabel("Sidebar content");addSubview(modeControl)

        outline.addTableColumn(outlineColumn);outline.outlineTableColumn=outlineColumn
        outline.headerView=nil;outline.style = .sourceList;outline.rowSizeStyle = .default
        outline.dataSource=self;outline.delegate=self;outline.target=self
        outline.doubleAction=#selector(openSelectedHeading(_:));outline.setAccessibilityLabel("Document outline")
        outlineScroll.documentView=outline;configure(scroll:outlineScroll);addSubview(outlineScroll)

        commentTable.addTableColumn(commentColumn);commentTable.headerView=nil
        commentTable.style = .sourceList;commentTable.rowHeight=64;commentTable.selectionHighlightStyle = .none
        commentTable.dataSource=self;commentTable.delegate=self;commentTable.target=self
        commentTable.action=#selector(clickSelectedComment(_:))
        commentTable.doubleAction=#selector(openSelectedComment(_:));commentTable.setAccessibilityLabel("Document comments")
        commentScroll.documentView=commentTable;configure(scroll:commentScroll);addSubview(commentScroll)
        commentFilter.selectedSegment=CommentFilter.open.rawValue
        commentFilter.target=self;commentFilter.action=#selector(changeCommentFilter(_:))
        commentFilter.setAccessibilityLabel("Comment status filter");addSubview(commentFilter)

        resolveButton.target=self;resolveButton.action=#selector(toggleResolved(_:));resolveButton.bezelStyle = .rounded
        addSubview(resolveButton)
        for label in [outlineEmpty,commentEmpty] {
            label.alignment = .center;label.textColor = .secondaryLabelColor
            label.font=NSFont.systemFont(ofSize:12);label.isHidden=true;addSubview(label)
        }
        showMode(.outline)
    }
    required init?(coder:NSCoder) {fatalError()}

    private func configure(scroll:NSScrollView) {
        scroll.hasVerticalScroller=true;scroll.drawsBackground=false;scroll.autohidesScrollers=true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance();layer?.backgroundColor=NSColor.controlBackgroundColor.cgColor
    }
    override func layout() {
        super.layout()
        let inset:CGFloat=8,top:CGFloat=36
        modeControl.frame=NSRect(x:inset,y:6,width:max(1,bounds.width-inset*2),height:24)
        outlineScroll.frame=NSRect(x:0,y:top,width:bounds.width,height:max(0,bounds.height-top))
        outlineEmpty.frame=NSRect(x:16,y:top+22,width:max(0,bounds.width-32),height:20)
        outlineColumn.width=max(1,bounds.width)
        let commentTop:CGFloat=68,controls:CGFloat=36
        commentFilter.frame=NSRect(x:inset,y:38,width:max(1,bounds.width-inset*2),height:24)
        commentScroll.frame=NSRect(x:0,y:commentTop,width:bounds.width,height:max(0,bounds.height-commentTop-controls));commentColumn.width=max(1,bounds.width)
        commentEmpty.frame=NSRect(x:16,y:commentTop+18,width:max(0,bounds.width-32),height:20)
        resolveButton.frame=NSRect(x:max(8,bounds.width-82),y:bounds.height-32,width:74,height:26)
    }

    @objc private func changeMode(_ sender:Any?) {showMode(Mode(rawValue:modeControl.selectedSegment) ?? .outline)}
    func showMode(_ next:Mode) {
        mode=next;modeControl.selectedSegment=next.rawValue
        let outlineVisible=next == .outline
        outlineScroll.isHidden = !outlineVisible;outlineEmpty.isHidden = !outlineVisible || !ordered.isEmpty
        for view in [commentFilter,commentScroll,commentEmpty,resolveButton] {view.isHidden=outlineVisible}
        if !outlineVisible {commentEmpty.isHidden = !comments.isEmpty;updateSelectionActions()}
    }

    func setHeadings(_ headings:[DocumentHeading],activeID:BlockID?) {
        let expanded=Set(nodes.values.filter{outline.isItemExpanded($0)}.map{$0.heading.id})
        let selected=(outline.item(atRow:outline.selectedRow) as? Node)?.heading.id
        roots.removeAll(keepingCapacity:true);ordered.removeAll(keepingCapacity:true);nodes.removeAll(keepingCapacity:true)
        var stack=[Node]()
        for heading in headings {
            let node=Node(heading);ordered.append(node);nodes[heading.id]=node
            while let last=stack.last,last.heading.level>=heading.level {stack.removeLast()}
            if let parent=stack.last {node.parent=parent;parent.children.append(node)} else {roots.append(node)}
            stack.append(node)
        }
        let firstSnapshot = !hasSnapshot;hasSnapshot=true;outline.reloadData()
        if firstSnapshot {for root in roots {outline.expandItem(root,expandChildren:true)}}
        else {for id in expanded {if let node=nodes[id] {expandAncestors(of:node);outline.expandItem(node)}}}
        if let selected,let node=nodes[selected] {select(node,scroll:false)}
        selectHeading(id:activeID);outlineEmpty.isHidden = mode != .outline || !headings.isEmpty
    }
    func setComments(_ next:[ResolvedMarkdownComment]) {
        let selected=selectedComment?.comment.id
        allComments=next.sorted {
            ($0.anchorRange?.location ?? $0.comment.anchor.position ?? Int.max) <
            ($1.anchorRange?.location ?? $1.comment.anchor.position ?? Int.max)
        }
        applyCommentFilter(preserving:selected)
        if selected != nil && selectedComment == nil {clearCommentSelection?()}
    }
    func selectHeading(id:BlockID?) {guard let id,let node=nodes[id] else{return};select(node,scroll:true)}
    func selectComment(id:String,activate:Bool=true) {
        guard let value=allComments.first(where:{$0.comment.id==id}) else{return}
        if !comments.contains(where:{$0.comment.id==id}) {
            commentFilter.selectedSegment=(value.comment.status == .open ? CommentFilter.open:CommentFilter.resolved).rawValue
            applyCommentFilter(preserving:id)
        }
        guard let row=comments.firstIndex(where:{$0.comment.id==id}) else{return}
        showMode(.comments);changingSelection=true
        commentTable.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);commentTable.scrollRowToVisible(row)
        changingSelection=false;refreshCommentCards();updateSelectionActions();if activate {activateComment?(id,false)}
    }
    func deselectComment() {
        guard commentTable.selectedRow>=0 else{return}
        changingSelection=true;commentTable.deselectAll(nil);changingSelection=false
        refreshCommentCards();updateSelectionActions()
    }

    private var selectedComment:ResolvedMarkdownComment? {
        guard commentTable.selectedRow>=0,commentTable.selectedRow<comments.count else{return nil}
        return comments[commentTable.selectedRow]
    }
    private func snippet(for comment:ResolvedMarkdownComment)->String {
        let flat=comment.comment.body.split(whereSeparator:{$0.isWhitespace}).joined(separator:" ")
        return flat.count>60 ? String(flat.prefix(57))+"...":flat
    }
    @objc private func changeCommentFilter(_ sender:Any?) {
        applyCommentFilter(preserving:selectedComment?.comment.id)
        if let id=selectedComment?.comment.id {activateComment?(id,false)} else {clearCommentSelection?()}
    }
    private func applyCommentFilter(preserving id:String?) {
        let filter=CommentFilter(rawValue:commentFilter.selectedSegment) ?? .open
        comments=allComments.filter {value in
            switch filter {
            case .open:return value.comment.status == .open
            case .resolved:return value.comment.status == .resolved
            case .all:return true
            }
        }
        changingSelection=true;commentTable.reloadData()
        if let id,let row=comments.firstIndex(where:{$0.comment.id==id}) {
            commentTable.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        } else {commentTable.deselectAll(nil)}
        changingSelection=false
        let label:String
        switch filter {case .open:label="No open comments";case .resolved:label="No resolved comments";case .all:label="No comments"}
        commentEmpty.stringValue=label;commentEmpty.isHidden = mode != .comments || !comments.isEmpty
        refreshCommentCards();updateSelectionActions()
    }
    private func updateSelectionActions() {
        guard let value=selectedComment?.comment else {resolveButton.isEnabled=false;return}
        resolveButton.title=value.status == .open ? "Resolve":"Reopen"
        resolveButton.isEnabled=true
    }
    private func expandAncestors(of node:Node) {var parent=node.parent;while let item=parent {outline.expandItem(item);parent=item.parent}}
    private func select(_ node:Node,scroll:Bool) {
        expandAncestors(of:node);let row=outline.row(forItem:node)
        guard row>=0,outline.selectedRow != row else{return}
        changingSelection=true;outline.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        if scroll {outline.scrollRowToVisible(row)};changingSelection=false
    }

    @objc private func openSelectedHeading(_ sender:Any?) {
        guard let node=outline.item(atRow:outline.selectedRow) as? Node else{return};activateHeading?(node.heading.id,true)
    }
    @objc private func openSelectedComment(_ sender:Any?) {
        guard let comment=selectedComment else{return};openComment?(comment.comment.id)
    }
    @objc private func clickSelectedComment(_ sender:Any?) {
        guard let comment=selectedComment else{return};activateComment?(comment.comment.id,false)
    }
    @objc private func toggleResolved(_ sender:Any?) {
        guard let id=selectedComment?.comment.id else{return};toggleCommentResolved?(id)
    }

    func outlineView(_ outlineView:NSOutlineView,numberOfChildrenOfItem item:Any?)->Int {(item as? Node)?.children.count ?? roots.count}
    func outlineView(_ outlineView:NSOutlineView,child index:Int,ofItem item:Any?)->Any {(item as? Node)?.children[index] ?? roots[index]}
    func outlineView(_ outlineView:NSOutlineView,isItemExpandable item:Any)->Bool {!(item as! Node).children.isEmpty}
    func outlineView(_ outlineView:NSOutlineView,viewFor tableColumn:NSTableColumn?,item:Any)->NSView? {
        let identifier=NSUserInterfaceItemIdentifier("OutlineCell")
        let cell=(outlineView.makeView(withIdentifier:identifier,owner:self) as? Cell) ?? {
            let cell=Cell(frame:NSRect(x:0,y:0,width:max(1,outlineColumn.width),height:outline.rowHeight));cell.identifier=identifier
            let label=NSTextField(labelWithString:"");label.lineBreakMode = .byTruncatingTail;label.maximumNumberOfLines=1
            label.frame=NSRect(x:6,y:0,width:max(1,outlineColumn.width-12),height:outline.rowHeight)
            label.autoresizingMask=[.width,.height]
            cell.textField=label;cell.addSubview(label);return cell
        }()
        cell.textField?.stringValue=(item as! Node).heading.title;cell.textField?.textColor = .secondaryLabelColor;return cell
    }
    func outlineViewSelectionDidChange(_ notification:Notification) {
        guard !changingSelection,let node=outline.item(atRow:outline.selectedRow) as? Node else{return};activateHeading?(node.heading.id,false)
    }

    func numberOfRows(in tableView:NSTableView)->Int {comments.count}
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        let identifier=NSUserInterfaceItemIdentifier("CommentCell")
        let cell=(tableView.makeView(withIdentifier:identifier,owner:self) as? CommentCell) ?? {
            let cell=CommentCell(frame:NSRect(x:0,y:0,width:max(1,commentColumn.width),height:64));cell.identifier=identifier
            return cell
        }()
        let comment=comments[row]
        let state=comment.anchorRange == nil ? "⚠︎ ":""
        cell.configure(text:"\(state)\(snippet(for:comment))",selected:commentTable.selectedRow==row);return cell
    }
    func tableView(_ tableView:NSTableView,heightOfRow row:Int)->CGFloat {64}
    func tableViewSelectionDidChange(_ notification:Notification) {
        refreshCommentCards()
        updateSelectionActions();guard !changingSelection else{return}
        if selectedComment == nil {clearCommentSelection?()}
    }
    private func refreshCommentCards() {
        for row in 0..<comments.count {
            guard let cell=commentTable.view(atColumn:0,row:row,makeIfNecessary:false) as? CommentCell else{continue}
            cell.configure(text:(comments[row].anchorRange == nil ? "⚠︎ ":"")+snippet(for:comments[row]),
                selected:commentTable.selectedRow==row)
        }
    }

    #if DEBUG
    var debugHeadingCount:Int {ordered.count}
    var debugHeadingTitles:[String] {ordered.map{$0.heading.title}}
    var debugCommentCount:Int {allComments.count}
    var debugVisibleCommentCount:Int {comments.count}
    var debugCommentSnippets:[String] {comments.map(snippet)}
    var debugCommentTextIsSelectable:Bool {
        (0..<comments.count).contains {row in
            (commentTable.view(atColumn:0,row:row,makeIfNecessary:true) as? CommentCell)?.label.isSelectable == true
        }
    }
    func debugSetCommentFilter(_ status:MarkdownCommentStatus?) {
        switch status {case .some(.open):commentFilter.selectedSegment=CommentFilter.open.rawValue
        case .some(.resolved):commentFilter.selectedSegment=CommentFilter.resolved.rawValue
        case nil:commentFilter.selectedSegment=CommentFilter.all.rawValue}
        applyCommentFilter(preserving:selectedComment?.comment.id)
    }
    func debugSelectComment(id:String) {selectComment(id:id)}
    func debugOpenSelectedComment() {openSelectedComment(nil)}
    func debugHeading(containing text:String)->DocumentHeading? {ordered.first(where:{$0.heading.title.contains(text)})?.heading}
    @discardableResult func debugActivateHeading(containing text:String)->Bool {
        guard let node=ordered.first(where:{$0.heading.title.contains(text)}) else{return false}
        select(node,scroll:true);activateHeading?(node.heading.id,false);return true
    }
    #endif
}
