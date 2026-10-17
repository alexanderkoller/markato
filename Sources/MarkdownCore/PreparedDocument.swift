import Foundation

public struct RenderedEntry: Equatable, Sendable {
    public let blockID:BlockID
    public var id:String {blockID.description}
    public let fragment:PreviewFragment
    /// Identity of the exact HTML submitted to the preview renderer. This is
    /// deliberately independent of parser block identity: comments and other
    /// presentation decoration may change HTML without changing the source
    /// block.
    public let contentVersion:UInt64
    public init(id:BlockID,fragment:PreviewFragment,contentVersion:UInt64?=nil) {
        blockID=id;self.fragment=fragment
        self.contentVersion=contentVersion ?? Self.version(of:fragment.html ?? "",documentFirst:fragment.from==0)
    }
    private static func version(of value:String,documentFirst:Bool)->UInt64 {
        var hash:UInt64=1469598103934665603
        for byte in value.utf8 {hash=(hash ^ UInt64(byte)) &* 1099511628211}
        hash=(hash ^ UInt64(documentFirst ? 1:0)) &* 1099511628211
        return hash
    }
}

/// Complete identity of CSS geometry. Equality means a measured block stride
/// can be reused without qualification.
public struct PreviewLayoutID:Equatable,Hashable,Sendable {
    public let width:Double
    public let fontSize:Double
    public let stylesheetGeneration:UInt64
    public init(width:Double,fontSize:Double,stylesheetGeneration:UInt64=1) {
        self.width=width;self.fontSize=fontSize;self.stylesheetGeneration=stylesheetGeneration
    }
}

public struct PreviewBlockMeasurement:Equatable,Sendable {
    public let blockID:BlockID
    public let contentVersion:UInt64
    public let stride:Double
    public init(blockID:BlockID,contentVersion:UInt64,stride:Double) {
        self.blockID=blockID;self.contentVersion=contentVersion;self.stride=stride
    }
}

public enum PreviewStrideState:Equatable,Sendable {
    case estimated
    case measured(layoutID:PreviewLayoutID,contentVersion:UInt64)
}

public struct PreviewBlockLayout:Equatable,Sendable {
    public let stride:Double
    public let state:PreviewStrideState
    public init(stride:Double,state:PreviewStrideState) {self.stride=stride;self.state=state}
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
        var syntaxShift=0
        var fragment: PreviewFragment?
        var previewLayout:PreviewBlockLayout
        var left: BlockNode?, right: BlockNode?
        weak var parent: BlockNode?
        var firstGap:Int?,firstStyleGap:Int?
        var depth=1,count=1,preparedCount=0,headingCount=0,lazyShift=0
        var previewSum:Double=0
        init(_ block:PreparedBlock,start:Int,end:Int) {
            self.block=block;self.start=start;self.end=end
            previewLayout=PreviewBlockLayout(stride:Self.estimate(start:start,end:end),state:.estimated)
        }
        private static func estimate(start:Int,end:Int)->Double {
            max(24,ceil(Double(max(1,end-start))/80)*24+12)
        }
        var hasContent:Bool {block.html != nil || fragment != nil}
        var effectivePreviewHeight:Double {previewLayout.stride}
        func shift(_ delta:Int) {
            guard delta != 0 else{return}
            block=PreparedBlock(id:block.id,kind:block.kind,from:block.from+delta,to:block.to+delta,
                html:block.html,syntax:block.syntax,headingTitle:block.headingTitle)
            start += delta;end += delta;firstGap=firstGap.map{$0+delta};firstStyleGap=firstStyleGap.map{$0+delta}
            syntaxShift += delta;lazyShift += delta
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
            preparedCount=(left?.preparedCount ?? 0)+(hasContent ? 1:0)+(right?.preparedCount ?? 0)
            headingCount=(left?.headingCount ?? 0)+(block.kind.isHeading ? 1:0)+(right?.headingCount ?? 0)
            firstGap=left?.firstGap ?? (hasContent ? nil:start) ?? right?.firstGap
            firstStyleGap=left?.firstStyleGap ?? (block.syntax == nil ? start:nil) ?? right?.firstStyleGap
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
    private var nodes=[BlockID:BlockNode]()
    private var syntax=[SyntaxPage]()
    public let sourceLayout=LayoutIndex()
    public private(set) var revision = -1
    public private(set) var length=0
    public private(set) var hasReferences=false
    public private(set) var previewLayoutID:PreviewLayoutID?
    /// Changes only when the outline's identities, titles, levels, or order
    /// change. Coordinate-only edits are resolved lazily from the block tree.
    public private(set) var outlineGeneration=0
    public var headings:[DocumentHeading] {
        var result=[DocumentHeading]()
        result.reserveCapacity(root?.headingCount ?? 0)
        func collect(_ node:BlockNode?) {
            guard let node,node.headingCount>0 else{return}
            node.push();collect(node.left)
            if let heading=documentHeading(node.block) {result.append(heading)}
            collect(node.right)
        }
        collect(root);return result
    }
    public var count:Int {root?.count ?? 0}
    public var hasCompleteFragments:Bool {(root?.preparedCount ?? 0)==count}
    public var styleCoverage:[NSRange] {syntax.map(\.range)}
    public var byteCost:Int {nodes.values.reduce(0){$0+($1.block.html?.byteCount ?? $1.fragment?.html?.utf8.count ?? 0)}}
    public init() {}

    private func documentHeading(_ block:PreparedBlock)->DocumentHeading? {
        guard let level=block.kind.headingLevel else{return nil}
        let title=block.headingTitle?.isEmpty == false ? block.headingTitle! : "Untitled heading"
        return DocumentHeading(id:block.id,title:title,level:level,
            range:NSRange(location:block.from,length:max(0,block.to-block.from)))
    }

    /// Resolves the current coordinate only when a row is activated. This
    /// avoids rewriting every later outline row after an edit near the top.
    public func heading(id:BlockID)->DocumentHeading? {
        guard let node=nodes[id] else{return nil}
        materialize(node);return documentHeading(node.block)
    }

    /// Finds the last heading at or before an offset through the retained
    /// order-statistics tree rather than scanning the outline.
    public func heading(at offset:Int)->DocumentHeading? {
        func lastHeading(in node:BlockNode?)->BlockNode? {
            guard let node,node.headingCount>0 else{return nil}
            node.push()
            if let result=lastHeading(in:node.right) {return result}
            if node.block.kind.isHeading {return node}
            return lastHeading(in:node.left)
        }
        var current=root,candidate:BlockNode?
        while let node=current {
            node.push()
            if node.block.from<=offset {
                if let left=lastHeading(in:node.left) {candidate=left}
                if node.block.kind.isHeading {candidate=node}
                current=node.right
            } else {current=node.left}
        }
        guard let candidate else{return nil}
        materialize(candidate);return documentHeading(candidate.block)
    }

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
    private func preparedFragment(_ node:BlockNode)->PreviewFragment? {
        if let fragment=node.fragment {return fragment}
        guard let html=node.block.html else{return nil}
        let fragment=PreviewFragment(kind:node.block.kind,from:node.block.from,to:node.block.to,
            html:html.string(),id:node.block.id)
        node.fragment=fragment
        return fragment
    }
    private func collect(_ node:BlockNode?,_ result:inout [BlockNode]) {
        guard let node else{return};node.push();collect(node.left,&result);result.append(node);collect(node.right,&result)
    }

    private func node(at index:Int)->BlockNode? {
        guard index>=0,index<count else{return nil}
        var index=index,current=root
        while let node=current {
            node.push();let before=node.left?.count ?? 0
            if index<before {current=node.left}
            else if index==before {return node}
            else {index -= before+1;current=node.right}
        }
        return nil
    }
    private func firstBlockIndex(where predicate:(PreparedBlock)->Bool)->Int {
        var base=0,current=root,result=count
        while let node=current {
            node.push();let before=node.left?.count ?? 0
            if predicate(node.block) {result=base+before;current=node.left}
            else {base += before+1;current=node.right}
        }
        return result
    }

    /// The Swift tree owns edit-region selection and stable block identities.
    /// Rust receives only this source interval and returns an owned parse.
    public func regionalContext(for edit:SourceEdit,newLength:Int)->RegionalParseContext? {
        guard revision>=0,!hasReferences,count>0 else{return nil}
        let firstOwner=min(count-1,firstBlockIndex{$0.to>edit.range.location})
        let lastOwner=min(count-1,max(firstOwner,firstBlockIndex{$0.to>=NSMaxRange(edit.range)}))
        let first=max(0,firstOwner-1),last=min(count-1,lastOwner+1)
        guard let lastNode=node(at:last) else{return nil}
        let oldFrom=first==0 ? 0 : node(at:first-1)!.block.to
        let oldTo=last+1==count ? length:lastNode.block.to
        let delta=edit.insertedLength-edit.range.length
        func shiftedStart(_ offset:Int)->Int {
            if offset<=edit.range.location {return offset}
            if offset>=NSMaxRange(edit.range) {return offset+delta}
            return edit.range.location
        }
        func shiftedEnd(_ offset:Int)->Int {
            if offset<edit.range.location {return offset}
            if offset>=NSMaxRange(edit.range) {return offset+delta}
            return edit.range.location+edit.insertedLength
        }
        let newFrom=shiftedStart(oldFrom),newTo=shiftedEnd(oldTo)
        guard newFrom>=0,newTo>=newFrom,newTo<=newLength else{return nil}
        var blocks=[RegionalBlock]();blocks.reserveCapacity(last-first+1)
        for index in first...last {
            guard let node=node(at:index),let fragment=preparedFragment(node),let html=fragment.html else{return nil}
            materialize(node)
            blocks.append(RegionalBlock(id:node.block.id,kind:node.block.kind,
                from:node.block.from,to:node.block.to,html:html))
        }
        return RegionalParseContext(range:NSRange(location:newFrom,length:newTo-newFrom),
            prefix:first,suffix:count-last-1,shift:delta,
            firstGuardID:first<firstOwner ? blocks.first?.id:nil,
            lastGuardID:last>lastOwner ? blocks.last?.id:nil,blocks:blocks)
    }

    /// The worker determines identity from complete rendering input, including
    /// resolved references. No edit-character heuristics decide cache validity.
    public func adopt(_ blocks:[PreparedBlock],revision:Int,length:Int,hasReferences:Bool=false) {
        #if DEBUG
        let work=TimingDiagnostics.shared.begin("prepared.adopt")
        defer {TimingDiagnostics.shared.end(work)}
        #endif
        guard revision != self.revision else{return}
        let previous=nodes
        let previousSyntax=syntax
        self.revision=revision;self.length=length;self.hasReferences=hasReferences;syntax.removeAll(keepingCapacity:true)
        nodes.removeAll(keepingCapacity:true)
        var items=[BlockNode]();items.reserveCapacity(blocks.count)
        var start=0
        for (i,block) in blocks.enumerated() {
            precondition(block.from>=start && block.to>=block.from && block.to<=length)
            let end=i==blocks.count-1 ? length:block.to
            let n=BlockNode(block,start:start,end:end)
            if let old=previous[block.id] {
                if block.html == nil || block.syntax == nil {
                    n.block=PreparedBlock(id:block.id,kind:block.kind,from:block.from,to:block.to,
                        html:block.html ?? old.block.html,syntax:block.syntax ?? old.block.syntax,
                        headingTitle:block.headingTitle ?? old.block.headingTitle)
                }
                if block.html == nil,let f=old.fragment {
                    n.fragment=PreviewFragment(kind:block.kind,from:block.from,to:block.to,html:f.html,id:block.id)
                }
                if block.syntax == nil {n.syntaxShift=old.syntaxShift+block.from-old.block.from}
                if block.html == nil || block.html?.string()==old.block.html?.string() {
                    n.previewLayout=old.previewLayout
                }
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
        outlineGeneration &+= 1
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
                if block.html == nil || block.syntax == nil {
                    node.block=PreparedBlock(id:block.id,kind:block.kind,from:block.from,to:block.to,
                        html:block.html ?? old.block.html,syntax:block.syntax ?? old.block.syntax,
                        headingTitle:block.headingTitle ?? old.block.headingTitle)
                }
                if block.html == nil,let f=old.fragment {node.fragment=PreviewFragment(kind:block.kind,from:block.from,to:block.to,html:f.html,id:block.id)}
                if block.syntax == nil {node.syntaxShift=old.syntaxShift+block.from-old.block.from}
                if block.html == nil || block.html?.string()==old.block.html?.string() {
                    node.previewLayout=old.previewLayout
                }
            }
            node.update();inserted.append(node);previousTo=block.to
        }
        for item in removedItems {nodes.removeValue(forKey:item.block.id)}
        for item in inserted {nodes[item.block.id]=item}
        let middle=build(inserted,0,inserted.count)
        root=append(append(prefix,middle),suffix);root?.parent=nil
        self.revision=revision;self.length=length
        let oldOutline=removedItems.compactMap{documentHeading($0.block)}
        let newOutline=inserted.compactMap{documentHeading($0.block)}
        let outlineChanged=oldOutline.count != newOutline.count || zip(oldOutline,newOutline).contains {
            $0.id != $1.id || $0.title != $1.title || $0.level != $1.level
        }
        if outlineChanged {outlineGeneration &+= 1}
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
            n.block=PreparedBlock(id:n.block.id,kind:n.block.kind,from:n.block.from,to:n.block.to,
                html:fragment.html.map(HTMLPayload.init),syntax:n.block.syntax,headingTitle:n.block.headingTitle)
            n.fragment=fragment
            var ancestor:BlockNode?=n
            while let current=ancestor {current.update();ancestor=current.parent}
        }
        if result.blocks != nil || result.blockChange != nil {return}
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
        let blocks=selected(range)
        if !blocks.isEmpty,blocks.allSatisfy({$0.block.syntax != nil}) {
            return blocks.flatMap{$0.block.syntax!.clipped(to:range,shift:$0.syntaxShift)}
        }
        var result=[SyntaxSpan](),position=range.location
        for page in syntax.dropFirst(syntaxStart(position)) {
            if page.range.location>position {return nil}
            result.append(contentsOf:page.records.clipped(to:NSIntersectionRange(page.range,range),shift:page.shift));position=NSMaxRange(page.range)
            if position>=NSMaxRange(range) {return result}
        }
        return nil
    }
    public func firstSyntaxGap(from position:Int)->Int {
        var pageEnd=position
        for page in syntax.dropFirst(syntaxStart(pageEnd)) {
            if page.range.location>pageEnd {break};pageEnd=NSMaxRange(page.range)
        }
        var nativeGap=length
        func visit(_ node:BlockNode?) {
            guard let node,let first=node.firstStyleGap,first<nativeGap else{return}
            node.push()
            if node.end>position {visit(node.left)}
            if node.end>position,node.block.syntax == nil {nativeGap=min(nativeGap,max(position,node.start))}
            if node.end<nativeGap {visit(node.right)}
        }
        visit(root)
        return max(pageEnd,nativeGap)
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
        let fragments=blocks.map(preparedFragment)
        guard fragments.allSatisfy({$0 != nil}) else{return nil}
        return zip(blocks,fragments).map{RenderedEntry(id:$0.block.id,fragment:$1!)}
    }

    /// Returns the next bounded run whose preview strides have not yet been
    /// measured for `layoutID`. Background layout uses this cursor-based API
    /// so completing document geometry never constructs a document-sized DOM
    /// or repeatedly scans the retained prefix.
    public func measurementWindow(from position:Int,layoutID:PreviewLayoutID,
        maximumBlocks:Int)->RenderedWindow? {
        guard hasCompleteFragments,maximumBlocks>0 else{return nil}
        func successor(_ node:BlockNode)->BlockNode? {
            materialize(node)
            if var n=node.right {
                while true {n.push();if let left=n.left {n=left}else{return n}}
            }
            var child=node,current=node.parent
            while let parent=current {
                if parent.left === child {return parent}
                child=parent;current=parent.parent
            }
            return nil
        }
        func firstNode(atOrAfter offset:Int)->BlockNode? {
            var current=root,candidate:BlockNode?
            while let node=current {
                node.push()
                if node.end>offset {candidate=node;current=node.left}
                else {current=node.right}
            }
            return candidate
        }
        func entry(_ node:BlockNode)->RenderedEntry? {
            preparedFragment(node).map{RenderedEntry(id:node.block.id,fragment:$0)}
        }
        func isMeasured(_ node:BlockNode)->Bool {
            guard let value=entry(node) else{return false}
            if case .measured(let measuredLayout,let version)=node.previewLayout.state {
                return measuredLayout==layoutID && version==value.contentVersion
            }
            return false
        }
        var cursor=firstNode(atOrAfter:max(0,position))
        while let node=cursor,isMeasured(node) {cursor=successor(node)}
        guard let first=cursor else{return nil}
        var blocks=[BlockNode](),node:BlockNode?=first
        while let current=node,blocks.count<maximumBlocks,!isMeasured(current) {
            blocks.append(current);node=successor(current)
        }
        let entries=blocks.compactMap(entry)
        guard entries.count==blocks.count,let last=blocks.last else{return nil}
        materialize(first)
        var top=first.left?.previewSum ?? 0,child=first,current=first.parent
        while let parent=current {
            if parent.right === child {top += (parent.left?.previewSum ?? 0)+parent.effectivePreviewHeight}
            child=parent;current=parent.parent
        }
        return RenderedWindow(range:NSRange(location:first.start,length:last.end-first.start),
            entries:entries,previewTop:32+top,previewHeight:64+(root?.previewSum ?? 0))
    }
    /// Returns cached blocks around a source viewport. The tree supplies the
    /// global preview extent; no document-sized placeholder enters the HTML engine.
    public func window(covering range:NSRange,before:Double,after:Double)->RenderedWindow? {
        var blocks=selected(range)
        if blocks.isEmpty,length==0 {
            return RenderedWindow(range:NSRange(location:0,length:0),entries:[],
                previewTop:0,previewHeight:0)
        }
        guard let visibleFirst=blocks.first,let visibleLast=blocks.last,
              blocks.allSatisfy({$0.hasContent}) else{return nil}
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
        while remaining>0,let previous=predecessor(cursor),previous.hasContent {
            blocks.insert(previous,at:0);remaining -= previous.effectivePreviewHeight;cursor=previous
        }
        remaining=after;cursor=visibleLast
        while remaining>0,let next=successor(cursor),next.hasContent {
            blocks.append(next);remaining -= next.effectivePreviewHeight;cursor=next
        }
        let first=blocks[0],last=blocks[blocks.count-1]
        materialize(first)
        var top=first.left?.previewSum ?? 0,child=first,current=first.parent
        while let parent=current {
            if parent.right === child {top += (parent.left?.previewSum ?? 0)+parent.effectivePreviewHeight}
            child=parent;current=parent.parent
        }
        let entries=blocks.compactMap {node in preparedFragment(node).map{RenderedEntry(id:node.block.id,fragment:$0)}}
        guard entries.count==blocks.count else{return nil}
        return RenderedWindow(range:NSRange(location:first.start,length:last.end-first.start),entries:entries,
            previewTop:32+top,previewHeight:64+(root?.previewSum ?? 0))
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
                if n.end>position,!n.hasContent {gap=min(gap,max(position,n.start))}
                if n.end<gap {visit(n.right)}
            }
            visit(root);htmlGap=gap
        }
        return min(htmlGap,firstSyntaxGap(from:position))
    }
    /// Changes the geometry identity without walking the retained tree. Old
    /// numeric strides remain useful estimates; their measured state simply no
    /// longer matches this identity.
    public func setPreviewLayoutID(_ layoutID:PreviewLayoutID) {
        previewLayoutID=layoutID
    }

    /// Atomically validates and records measurements for mounted blocks. The
    /// returned delta lets a frame use the corrected global extent before its
    /// pixels become visible.
    @discardableResult public func applyPreviewMeasurements(_ measurements:[PreviewBlockMeasurement],
        revision:Int,layoutID:PreviewLayoutID,expectedContentVersions:[BlockID:UInt64])->Double? {
        guard revision==self.revision,layoutID==previewLayoutID else{return nil}
        for measurement in measurements {
            guard measurement.stride.isFinite,measurement.stride>0,
                  nodes[measurement.blockID] != nil,
                  expectedContentVersions[measurement.blockID]==measurement.contentVersion else{return nil}
        }
        var extentChange=0.0
        for measurement in measurements {
            let node=nodes[measurement.blockID]!
            materialize(node)
            let previous=node.effectivePreviewHeight
            node.previewLayout=PreviewBlockLayout(stride:measurement.stride,
                state:.measured(layoutID:layoutID,contentVersion:measurement.contentVersion))
            extentChange += measurement.stride-previous
            var ancestor:BlockNode?=node
            while let current=ancestor {current.update();ancestor=current.parent}
        }
        return extentChange
    }
    public func heights(for id:BlockID)->(source:Double?,preview:Double?)? {
        guard let n=nodes[id] else{return nil}
        materialize(n)
        let from=sourceLayout.position(at:n.start)?.y
        let to=n.end==sourceLayout.length ? sourceLayout.height:sourceLayout.position(at:n.end)?.y
        return (from.flatMap {a in to.map{$0-a}},n.previewLayout.stride)
    }
    public func previewLayout(for id:BlockID)->PreviewBlockLayout? {
        guard let node=nodes[id] else{return nil}
        materialize(node);return node.previewLayout
    }
}
