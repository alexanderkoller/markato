import Foundation

public struct RenderedEntry: Equatable, Sendable {
    public let id:String
    public let fragment:PreviewFragment
    public init(id:String,fragment:PreviewFragment) { self.id=id;self.fragment=fragment }
}
public struct RenderedWindow: Sendable {
    public let range:NSRange
    public let entries:[RenderedEntry]
    public let previewTop:Double
    public let previewHeight:Double
}

/// One revision's ordered blocks, prepared styles and measured source lines.
/// Both panes use these block identities and source coordinates. Scrolling reads
/// the indexes; it does not prepare content or invalidate measurements.
public final class PreparedDocument {
    private final class BlockNode {
        var block: PreparedBlock
        var start: Int, end: Int
        var fragment: PreviewFragment?
        var previewHeight: Double?
        var left: BlockNode?, right: BlockNode?
        weak var parent: BlockNode?
        var firstGap: Int?
        var depth=1,count=1,preparedCount=0,lazyShift=0
        var previewSum:Double=0
        init(_ block:PreparedBlock,start:Int,end:Int) {self.block=block;self.start=start;self.end=end}
        var effectivePreviewHeight:Double {
            previewHeight ?? max(24,ceil(Double(max(1,end-start))/80)*24+12)
        }
        func shift(_ delta:Int) {
            guard delta != 0 else{return}
            block=PreparedBlock(id:block.id,kind:block.kind,from:block.from+delta,to:block.to+delta)
            start += delta;end += delta;firstGap=firstGap.map{$0+delta};lazyShift += delta
            if let f=fragment {fragment=PreviewFragment(kind:f.kind,from:f.from+delta,to:f.to+delta,html:f.html,id:f.id)}
        }
        func push() {
            guard lazyShift != 0 else{return}
            left?.shift(lazyShift);right?.shift(lazyShift);lazyShift=0
        }
        func update() {
            left?.parent=self;right?.parent=self
            depth=1+max(left?.depth ?? 0,right?.depth ?? 0)
            count=1+(left?.count ?? 0)+(right?.count ?? 0)
            preparedCount=(left?.preparedCount ?? 0)+(fragment == nil ? 0:1)+(right?.preparedCount ?? 0)
            firstGap=left?.firstGap ?? (fragment==nil ? start:nil) ?? right?.firstGap
            previewSum=(left?.previewSum ?? 0)+effectivePreviewHeight+(right?.previewSum ?? 0)
        }
    }
    private final class StyleRecords {
        let spans:[SyntaxSpan]
        private struct Node {
            let index:Int
            var left:Int?,right:Int?,maximumEnd:Int
        }
        private var nodes=[Node]()
        private var root:Int?
        init(_ spans:[SyntaxSpan]) {
            self.spans=spans
            let ordered=spans.indices.sorted {spans[$0].from==spans[$1].from ? $0<$1:spans[$0].from<spans[$1].from}
            nodes.reserveCapacity(spans.count)
            func build(_ a:Int,_ b:Int)->Int? {
                guard a<b else{return nil}
                let middle=(a+b)/2,index=ordered[middle],slot=nodes.count
                nodes.append(Node(index:index,left:nil,right:nil,maximumEnd:spans[index].to))
                let left=build(a,middle),right=build(middle+1,b)
                nodes[slot].left=left;nodes[slot].right=right
                nodes[slot].maximumEnd=max(spans[index].to,max(left.map{nodes[$0].maximumEnd} ?? 0,right.map{nodes[$0].maximumEnd} ?? 0))
                return slot
            }
            root=build(0,ordered.count)
        }
        func clipped(to range:NSRange,shift:Int)->[SyntaxSpan] {
            let from=range.location-shift,to=NSMaxRange(range)-shift
            var selected=[Int]()
            func visit(_ slot:Int?) {
                guard let slot,nodes[slot].maximumEnd>from else{return}
                let node=nodes[slot],span=spans[node.index]
                visit(node.left)
                if span.from<to && span.to>from {selected.append(node.index)}
                if span.from<to {visit(node.right)}
            }
            visit(root)
            // Source font traits follow AST order, including nested emphasis.
            return selected.sorted().map {index in
                let span=spans[index]
                return SyntaxSpan(kind:span.kind,from:max(range.location,span.from+shift),to:min(NSMaxRange(range),span.to+shift))
            }
        }
    }
    private struct SyntaxPage {
        let range:NSRange
        let records:StyleRecords
        var shift=0
        init(range:NSRange,records:StyleRecords,shift:Int=0) {self.range=range;self.records=records;self.shift=shift}
    }
    private var root:BlockNode?
    private var nodes=[String:BlockNode]()
    private var syntax=[SyntaxPage]()
    public let sourceLayout=LayoutIndex()
    public private(set) var revision = -1
    public private(set) var length=0
    public var count:Int {root?.count ?? 0}
    public var hasCompleteFragments:Bool {(root?.preparedCount ?? 0)==count}
    public var styleCoverage:[NSRange] {syntax.map(\.range)}
    public var byteCost:Int {nodes.values.reduce(0){$0+($1.fragment?.html?.utf8.count ?? 0)}}
    public init() {}

    private func build(_ items:[BlockNode],_ from:Int,_ to:Int)->BlockNode? {
        guard from<to else{return nil}
        let middle=(from+to)/2,node=items[middle]
        node.left=build(items,from,middle);node.right=build(items,middle+1,to);node.parent=nil;node.lazyShift=0;node.update()
        return node
    }
    private func balance(_ node:BlockNode)->BlockNode {
        node.push()
        if (node.left?.depth ?? 0)>(node.right?.depth ?? 0)+1 {
            let left=node.left!;left.push()
            if (left.left?.depth ?? 0)<(left.right?.depth ?? 0) {
                let middle=left.right!;middle.push()
                left.right=middle.left;left.update();middle.left=left;middle.update();node.left=middle
            }
            let top=node.left!;top.push();node.left=top.right;node.update();top.right=node;top.parent=nil;top.update();return top
        }
        if (node.right?.depth ?? 0)>(node.left?.depth ?? 0)+1 {
            let right=node.right!;right.push()
            if (right.right?.depth ?? 0)<(right.left?.depth ?? 0) {
                let middle=right.left!;middle.push()
                right.left=middle.right;right.update();middle.right=right;middle.update();node.right=middle
            }
            let top=node.right!;top.push();node.right=top.left;node.update();top.left=node;top.parent=nil;top.update();return top
        }
        node.update();return node
    }
    private func split(_ node:BlockNode?,_ count:Int)->(BlockNode?,BlockNode?) {
        guard let node else{return(nil,nil)};node.push()
        let before=node.left?.count ?? 0
        if count<=before {
            let (a,b)=split(node.left,count);node.left=b;let right=balance(node);a?.parent=nil;right.parent=nil;return(a,right)
        }
        let (a,b)=split(node.right,count-before-1);node.right=a;let left=balance(node);left.parent=nil;b?.parent=nil;return(left,b)
    }
    private func join(_ left:BlockNode?,_ pivot:BlockNode,_ right:BlockNode?)->BlockNode {
        if (left?.depth ?? 0)>(right?.depth ?? 0)+1 {
            let left=left!;left.push();left.right=join(left.right,pivot,right);let result=balance(left);result.parent=nil;return result
        }
        if (right?.depth ?? 0)>(left?.depth ?? 0)+1 {
            let right=right!;right.push();right.left=join(left,pivot,right.left);let result=balance(right);result.parent=nil;return result
        }
        pivot.left=left;pivot.right=right;pivot.parent=nil;pivot.lazyShift=0;pivot.update();return pivot
    }
    private func popLast(_ node:BlockNode)->(BlockNode?,BlockNode) {
        node.push()
        guard let right=node.right else {
            let rest=node.left;rest?.parent=nil;node.left=nil;node.right=nil;node.update();return(rest,node)
        }
        let (newRight,last)=popLast(right);node.right=newRight;let rest=balance(node);rest.parent=nil;return(rest,last)
    }
    private func append(_ left:BlockNode?,_ right:BlockNode?)->BlockNode? {
        guard let left else{return right};guard let right else{return left}
        let (rest,pivot)=popLast(left);return join(rest,pivot,right)
    }
    private func materialize(_ node:BlockNode) {
        var path=[BlockNode](),current:BlockNode?=node
        while let item=current {path.append(item);current=item.parent}
        for item in path.reversed() {item.push()}
    }
    private func collect(_ node:BlockNode?,_ result:inout [BlockNode]) {
        guard let node else{return};node.push();collect(node.left,&result);result.append(node);collect(node.right,&result)
    }

    /// The worker determines identity from complete rendering input, including
    /// resolved references. No edit-character heuristics decide cache validity.
    public func adopt(_ blocks:[PreparedBlock],revision:Int,length:Int) {
        #if DEBUG
        let work=TimingDiagnostics.shared.begin("prepared.adopt")
        defer {TimingDiagnostics.shared.end(work)}
        #endif
        guard revision != self.revision else{return}
        let previous=nodes
        let previousSyntax=syntax
        self.revision=revision;self.length=length;syntax.removeAll(keepingCapacity:true)
        nodes.removeAll(keepingCapacity:true)
        var items=[BlockNode]();items.reserveCapacity(blocks.count)
        var start=0
        for (i,block) in blocks.enumerated() {
            precondition(block.from>=start && block.to>=block.from && block.to<=length)
            let end=i==blocks.count-1 ? length:block.to
            let n=BlockNode(block,start:start,end:end)
            if let old=previous[block.id],let f=old.fragment {
                n.fragment=PreviewFragment(kind:block.kind,from:block.from,to:block.to,html:f.html,id:block.id)
                n.previewHeight=old.previewHeight
            }
            if let old=previous[block.id] {
                var low=0,high=previousSyntax.count
                while low<high {let mid=(low+high)/2;if NSMaxRange(previousSyntax[mid].range)<=old.start {low=mid+1}else{high=mid}}
                let delta=block.from-old.block.from
                for page in previousSyntax.dropFirst(low) {
                    if page.range.location>=old.end {break}
                    let overlap=NSIntersectionRange(page.range,NSRange(location:old.start,length:old.end-old.start))
                    let from=max(n.start,overlap.location+delta),to=min(n.end,NSMaxRange(overlap)+delta)
                    if to>from {syntax.append(SyntaxPage(range:NSRange(location:from,length:to-from),records:page.records,shift:page.shift+delta))}
                }
            }
            nodes[block.id]=n;items.append(n);start=block.to
        }
        root=build(items,0,items.count)
        setSyntax(syntax)
    }

    /// Replace only the manifest interval reported by the parser. The retained
    /// prefix and suffix remain the same tree nodes; a suffix coordinate change
    /// is recorded once at its subtree root.
    public func apply(_ change:PreparedBlockChange,revision:Int,length:Int) {
        #if DEBUG
        let work=TimingDiagnostics.shared.begin("prepared.splice")
        defer {TimingDiagnostics.shared.end(work,values:["changedBlocks":Double(change.blocks.count)])}
        #endif
        guard revision != self.revision,change.prefix>=0,change.suffix>=0,
              change.prefix+change.suffix<=count else{return}
        let oldCount=count,removedCount=oldCount-change.prefix-change.suffix
        let (prefix,tail)=split(root,change.prefix)
        let (removed,suffix)=split(tail,removedCount)
        var removedItems=[BlockNode]();collect(removed,&removedItems)
        let removedByID=Dictionary(removedItems.map{($0.block.id,$0)},uniquingKeysWith:{first,_ in first})
        let oldStart=removedItems.first?.start ?? suffix.map{materialize($0);return $0.start} ?? self.length
        let oldEnd=removedItems.last?.end ?? oldStart
        suffix?.shift(change.shift)
        var previousTo:Int
        if let prefix {materialize(prefix);var n=prefix;while let right=n.right {n.push();n=right};previousTo=n.block.to}
        else {previousTo=0}
        var inserted=[BlockNode]()
        for (index,block) in change.blocks.enumerated() {
            let isLast=change.suffix==0 && index==change.blocks.count-1
            let node=BlockNode(block,start:previousTo,end:isLast ? length:block.to)
            if let old=removedByID[block.id] {
                materialize(old)
                if let f=old.fragment {node.fragment=PreviewFragment(kind:block.kind,from:block.from,to:block.to,html:f.html,id:block.id)}
                node.previewHeight=old.previewHeight
            }
            node.update();inserted.append(node);previousTo=block.to
        }
        for item in removedItems {nodes.removeValue(forKey:item.block.id)}
        for item in inserted {nodes[item.block.id]=item}
        let middle=build(inserted,0,inserted.count)
        root=append(append(prefix,middle),suffix);root?.parent=nil
        self.revision=revision;self.length=length
        var retained=[SyntaxPage]()
        for page in syntax {
            if NSMaxRange(page.range)<=oldStart {retained.append(page)}
            else if page.range.location>=oldEnd {
                retained.append(SyntaxPage(range:NSRange(location:page.range.location+change.shift,length:page.range.length),records:page.records,shift:page.shift+change.shift))
            } else {
                if page.range.location<oldStart {
                    retained.append(SyntaxPage(range:NSRange(location:page.range.location,length:oldStart-page.range.location),records:page.records,shift:page.shift))
                }
                if NSMaxRange(page.range)>oldEnd {
                    retained.append(SyntaxPage(range:NSRange(location:oldEnd+change.shift,length:NSMaxRange(page.range)-oldEnd),records:page.records,shift:page.shift+change.shift))
                }
            }
        }
        setSyntax(retained)
    }
    public func store(_ result:ParseResult,range:NSRange) {
        #if DEBUG
        let work=TimingDiagnostics.shared.begin("prepared.store")
        defer {TimingDiagnostics.shared.end(work)}
        #endif
        guard result.revision==revision else{return}
        for fragment in result.fragments {
            guard let id=fragment.id,let n=nodes[id],fragment.html != nil else{continue}
            materialize(n)
            n.fragment=fragment
            var ancestor:BlockNode?=n
            while let current=ancestor {current.update();ancestor=current.parent}
        }
        let bounded=NSIntersectionRange(NSRange(location:0,length:length),range)
        guard bounded.length>0 else{return}
        var pages=[SyntaxPage]()
        for page in syntax {
            if NSMaxRange(page.range)<=bounded.location || page.range.location>=NSMaxRange(bounded) {pages.append(page);continue}
            if page.range.location<bounded.location {
                let prefix=NSRange(location:page.range.location,length:bounded.location-page.range.location)
                pages.append(SyntaxPage(range:prefix,records:page.records,shift:page.shift))
            }
            if NSMaxRange(page.range)>NSMaxRange(bounded) {
                let suffix=NSRange(location:NSMaxRange(bounded),length:NSMaxRange(page.range)-NSMaxRange(bounded))
                pages.append(SyntaxPage(range:suffix,records:page.records,shift:page.shift))
            }
        }
        pages.append(SyntaxPage(range:bounded,records:StyleRecords(clip(result.spans,to:bounded))))
        setSyntax(pages)
    }
    private func setSyntax(_ pages:[SyntaxPage]) {
        var merged=[SyntaxPage]()
        for page in pages.sorted(by:{$0.range.location<$1.range.location}) {
            if let last=merged.last,NSMaxRange(last.range)==page.range.location,last.records === page.records,last.shift==page.shift {
                merged[merged.count-1]=SyntaxPage(range:NSRange(location:last.range.location,length:NSMaxRange(page.range)-last.range.location),records:last.records,shift:last.shift)
            } else {merged.append(page)}
        }
        syntax=merged
    }
    private func clip(_ spans:[SyntaxSpan],to range:NSRange,shift:Int=0)->[SyntaxSpan] {
        spans.compactMap {
            let from=max(range.location,$0.from+shift),to=min(NSMaxRange(range),$0.to+shift)
            return to>from ? SyntaxSpan(kind:$0.kind,from:from,to:to):nil
        }
    }
    private func syntaxStart(_ position:Int)->Int {
        var low=0,high=syntax.count
        while low<high {let mid=(low+high)/2;if NSMaxRange(syntax[mid].range)<=position {low=mid+1}else{high=mid}}
        return low
    }
    public func styles(in range:NSRange)->[SyntaxSpan]? {
        guard range.length>0 else{return []}
        var result=[SyntaxSpan](),position=range.location
        for page in syntax.dropFirst(syntaxStart(position)) {
            if page.range.location>position {return nil}
            result.append(contentsOf:page.records.clipped(to:NSIntersectionRange(page.range,range),shift:page.shift));position=NSMaxRange(page.range)
            if position>=NSMaxRange(range) {return result}
        }
        return nil
    }
    public func firstSyntaxGap(from position:Int)->Int {
        var position=position
        for page in syntax.dropFirst(syntaxStart(position)) {
            if page.range.location>position {break};position=NSMaxRange(page.range)
        }
        return position
    }
    private func selected(_ range:NSRange)->[BlockNode] {
        var result=[BlockNode]()
        func visit(_ n:BlockNode?) {
            guard let n else{return}
            n.push()
            if range.location<n.start {visit(n.left)}
            if n.end>range.location && n.start<NSMaxRange(range) {result.append(n)}
            if NSMaxRange(range)>n.end {visit(n.right)}
        }
        visit(root);return result
    }
    public func entries(covering range:NSRange)->[RenderedEntry]? {
        let blocks=selected(range)
        guard !blocks.isEmpty || length==0 else{return nil}
        guard blocks.allSatisfy({$0.fragment != nil}) else{return nil}
        return blocks.map{RenderedEntry(id:$0.block.id,fragment:$0.fragment!)}
    }
    /// Returns cached blocks around a source viewport. The tree supplies the
    /// global preview extent; no document-sized placeholder enters the HTML engine.
    public func window(covering range:NSRange,before:Double,after:Double)->RenderedWindow? {
        var blocks=selected(range)
        guard let visibleFirst=blocks.first,let visibleLast=blocks.last,
              blocks.allSatisfy({$0.fragment != nil}) else{return nil}
        func predecessor(_ node:BlockNode)->BlockNode? {
            materialize(node)
            if var n=node.left {while true {n.push();if let right=n.right {n=right}else{return n}}}
            var child=node,current=node.parent
            while let parent=current {if parent.right === child {return parent};child=parent;current=parent.parent}
            return nil
        }
        func successor(_ node:BlockNode)->BlockNode? {
            materialize(node)
            if var n=node.right {while true {n.push();if let left=n.left {n=left}else{return n}}}
            var child=node,current=node.parent
            while let parent=current {if parent.left === child {return parent};child=parent;current=parent.parent}
            return nil
        }
        var remaining=before,cursor=visibleFirst
        while remaining>0,let previous=predecessor(cursor),previous.fragment != nil {
            blocks.insert(previous,at:0);remaining -= previous.effectivePreviewHeight;cursor=previous
        }
        remaining=after;cursor=visibleLast
        while remaining>0,let next=successor(cursor),next.fragment != nil {
            blocks.append(next);remaining -= next.effectivePreviewHeight;cursor=next
        }
        let first=blocks[0],last=blocks[blocks.count-1]
        materialize(first)
        var top=first.left?.previewSum ?? 0,child=first,current=first.parent
        while let parent=current {
            if parent.right === child {top += (parent.left?.previewSum ?? 0)+parent.effectivePreviewHeight}
            child=parent;current=parent.parent
        }
        return RenderedWindow(range:NSRange(location:first.start,length:last.end-first.start),
            entries:blocks.map{RenderedEntry(id:$0.block.id,fragment:$0.fragment!)},
            previewTop:16+top,previewHeight:32+(root?.previewSum ?? 0))
    }
    public func firstUnpreparedOffset(from position:Int)->Int {
        let htmlGap:Int
        if position==0 {htmlGap=root?.firstGap ?? length}
        else {
            var gap=length
            func visit(_ n:BlockNode?) {
                guard let n,let first=n.firstGap,first<gap else{return}
                n.push()
                if n.end>position {visit(n.left)}
                if n.end>position,n.fragment==nil {gap=min(gap,max(position,n.start))}
                if n.end<gap {visit(n.right)}
            }
            visit(root);htmlGap=gap
        }
        return min(htmlGap,firstSyntaxGap(from:position))
    }
    public func recordPreviewHeights(_ heights:[String:Double],revision:Int) {
        guard revision==self.revision else{return}
        for (id,height) in heights where height.isFinite && height>0 {
            if let node=nodes[id] {
                materialize(node);node.previewHeight=height
                var ancestor:BlockNode?=node
                while let current=ancestor {current.update();ancestor=current.parent}
            }
        }
    }
    public func heights(for id:String)->(source:Double?,preview:Double?)? {
        guard let n=nodes[id] else{return nil}
        materialize(n)
        let from=sourceLayout.position(at:n.start)?.y
        let to=n.end==sourceLayout.length ? sourceLayout.height:sourceLayout.position(at:n.end)?.y
        return (from.flatMap {a in to.map{$0-a}},n.previewHeight)
    }
}
