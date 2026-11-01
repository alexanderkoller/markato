import AppKit
import MarkdownCore

/// The sidebar presents navigation providers without depending on preview DOM
/// details. Outline and comments share the same reveal/focus behavior.
@MainActor final class SidebarPane:NSView,NSOutlineViewDataSource,NSOutlineViewDelegate,
                                    NSTableViewDataSource,NSTableViewDelegate {
    enum Mode:Int {case outline,comments}
    private final class Cell:NSTableCellView {}
    private final class CommentCell:NSTableCellView {
        static let font=NSFont.systemFont(ofSize:12)
        let card=NSView(),label=NSTextField(wrappingLabelWithString:"")
        override init(frame:NSRect) {
            super.init(frame:frame);card.wantsLayer=true;card.layer?.cornerRadius=6
            label.maximumNumberOfLines=4;label.lineBreakMode = .byWordWrapping
            label.font=Self.font;label.textColor = .labelColor
            label.isSelectable=false;label.isEditable=false;label.allowsEditingTextAttributes=false
            card.addSubview(label);addSubview(card);textField=label
        }
        required init?(coder:NSCoder) {fatalError()}
        override func layout() {
            super.layout()
            let inset:CGFloat=6
            // Full-width table rows retain a platform leading offset even
            // though their cell can extend beneath the trailing clip edge.
            // Lay the card out against the visible row and mirror that leading
            // offset, so its rounded right edge always has the same breathing
            // room as its left edge.
            let rowWidth=enclosingScrollView?.contentView.bounds.width ?? superview?.bounds.width ?? bounds.width
            let cardWidth=max(1,rowWidth-frame.minX*2-inset*2)
            card.frame=NSRect(x:inset,y:4,width:cardWidth,height:max(1,bounds.height-8))
            label.frame=card.bounds.insetBy(dx:9,dy:6)
        }
        func configure(text:String,selected:Bool) {
            label.stringValue=text
            card.layer?.backgroundColor=NSColor(calibratedRed:0.98,green:0.91,blue:0.68,alpha:1).cgColor
            card.layer?.borderWidth=selected ? 1:0
            card.layer?.borderColor=NSColor.controlAccentColor.cgColor
        }
        static func rowHeight(for text:String,width:CGFloat)->CGFloat {
            let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byWordWrapping
            let measured=(text as NSString).boundingRect(
                with:NSSize(width:max(1,width-50),height:CGFloat.greatestFiniteMagnitude),
                options:[.usesLineFragmentOrigin,.usesFontLeading],
                attributes:[.font:font,.paragraphStyle:paragraph])
            return max(52,min(92,ceil(measured.height)+20))
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
    private let resolveButton=NSButton(title:"Resolve",target:nil,action:nil)

    private var roots=[Node](),ordered=[Node](),nodes=[BlockID:Node]()
    private var allComments=[ResolvedMarkdownComment](),comments=[ResolvedMarkdownComment]()
    private var hasSnapshot=false,changingSelection=false
    private var commentLayoutWidth:CGFloat = -1
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
        commentTable.style = .fullWidth;commentTable.rowHeight=64;commentTable.selectionHighlightStyle = .none
        commentTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        commentColumn.resizingMask = .autoresizingMask
        commentTable.dataSource=self;commentTable.delegate=self;commentTable.target=self
        commentTable.action=#selector(clickSelectedComment(_:))
        commentTable.doubleAction=#selector(openSelectedComment(_:));commentTable.setAccessibilityLabel("Document comments")
        commentScroll.documentView=commentTable;configure(scroll:commentScroll);addSubview(commentScroll)
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
        outlineColumn.width=max(1,outlineScroll.contentSize.width)
        let commentTop:CGFloat=36,controls:CGFloat=36
        commentScroll.frame=NSRect(x:0,y:commentTop,width:bounds.width,height:max(0,bounds.height-commentTop-controls))
        let commentWidth=max(1,commentScroll.contentSize.width)
        commentColumn.width=commentWidth
        if abs(commentWidth-commentLayoutWidth)>0.5 {
            commentLayoutWidth=commentWidth
            if !comments.isEmpty {
                commentTable.noteHeightOfRows(withIndexesChanged:IndexSet(integersIn:0..<comments.count))
            }
        }
        commentEmpty.frame=NSRect(x:16,y:commentTop+18,width:max(0,bounds.width-32),height:20)
        resolveButton.frame=NSRect(x:max(8,bounds.width-82),y:bounds.height-32,width:74,height:26)
    }

    @objc private func changeMode(_ sender:Any?) {showMode(Mode(rawValue:modeControl.selectedSegment) ?? .outline)}
    func showMode(_ next:Mode) {
        mode=next;modeControl.selectedSegment=next.rawValue
        let outlineVisible=next == .outline
        outlineScroll.isHidden = !outlineVisible;outlineEmpty.isHidden = !outlineVisible || !ordered.isEmpty
        for view in [commentScroll,commentEmpty,resolveButton] {view.isHidden=outlineVisible}
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
        comments=allComments;changingSelection=true;commentTable.reloadData()
        if let selected,let row=comments.firstIndex(where:{$0.comment.id==selected}) {
            commentTable.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        } else {commentTable.deselectAll(nil)}
        changingSelection=false;commentEmpty.isHidden = mode != .comments || !comments.isEmpty
        refreshCommentCards();updateSelectionActions()
        if selected != nil && selectedComment == nil {clearCommentSelection?()}
    }
    func selectHeading(id:BlockID?) {guard let id,let node=nodes[id] else{return};select(node,scroll:true)}
    func selectComment(id:String,activate:Bool=true) {
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
        return flat.count>120 ? String(flat.prefix(117))+"...":flat
    }
    private func updateSelectionActions() {
        resolveButton.title="Resolve";resolveButton.isEnabled=selectedComment != nil
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
    func tableView(_ tableView:NSTableView,heightOfRow row:Int)->CGFloat {
        guard comments.indices.contains(row) else{return 52}
        let text=(comments[row].anchorRange == nil ? "⚠︎ ":"")+snippet(for:comments[row])
        return CommentCell.rowHeight(for:text,width:max(1,commentLayoutWidth))
    }
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
    var debugSelectedHeadingID:BlockID? {(outline.item(atRow:outline.selectedRow) as? Node)?.heading.id}
    var debugCommentCount:Int {allComments.count}
    var debugVisibleCommentCount:Int {comments.count}
    var debugCommentSnippets:[String] {comments.map(snippet)}
    var debugCommentTextIsSelectable:Bool {
        (0..<comments.count).contains {row in
            (commentTable.view(atColumn:0,row:row,makeIfNecessary:true) as? CommentCell)?.label.isSelectable == true
        }
    }
    var debugCommentCardsFit:Bool {
        comments.indices.allSatisfy {row in
            guard let cell=commentTable.view(atColumn:0,row:row,makeIfNecessary:true) as? CommentCell else{return false}
            cell.layoutSubtreeIfNeeded()
            let rowWidth=cell.enclosingScrollView?.contentView.bounds.width ??
                cell.superview?.bounds.width ?? cell.bounds.width
            let visibleLeft=cell.frame.minX+cell.card.frame.minX
            let visibleRight=rowWidth-(cell.frame.minX+cell.card.frame.maxX)
            return visibleLeft>=5.5 && visibleRight>=5.5 && abs(visibleLeft-visibleRight)<=0.5 &&
                cell.card.frame.minX >= -0.5 && cell.card.frame.maxX <= cell.bounds.maxX+0.5 &&
                cell.label.frame.minX >= -0.5 && cell.label.frame.maxX <= cell.card.bounds.maxX+0.5 &&
                cell.label.frame.minY >= -0.5 && cell.label.frame.maxY <= cell.card.bounds.maxY+0.5
        }
    }
    func debugSetCommentFilter(_ status:MarkdownCommentStatus?) {
        _ = status
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
