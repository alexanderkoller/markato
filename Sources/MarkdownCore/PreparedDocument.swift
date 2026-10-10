import Foundation

public struct RenderedEntry: Equatable, Sendable {
    public let id:String
    public let fragment:PreviewFragment
    public init(id:String,fragment:PreviewFragment) { self.id=id;self.fragment=fragment }
}
public struct RenderedPage: Sendable {
    public var range:NSRange
    public var entries:[RenderedEntry]
}

/// One revision's ordered blocks, prepared styles and measured source lines.
/// Both panes use these block identities and source coordinates. Scrolling reads
/// the indexes; it does not prepare content or invalidate measurements.
public final class PreparedDocument {
    private final class BlockNode {
        let block: PreparedBlock
        let start: Int, end: Int
        var fragment: PreviewFragment?
        var previewHeight: Double?
        var left: BlockNode?, right: BlockNode?
        weak var parent: BlockNode?
        var firstGap: Int?
        init(_ block:PreparedBlock,start:Int,end:Int) {self.block=block;self.start=start;self.end=end}
        func update() {
            firstGap=left?.firstGap ?? (fragment==nil ? start:nil) ?? right?.firstGap
        }
    }
    private final class StyleRecords {
        let spans:[SyntaxSpan]
        init(_ spans:[SyntaxSpan]) {self.spans=spans}
    }
    private struct SyntaxPage {
        let range:NSRange
        let records:StyleRecords
        var shift=0
        init(range:NSRange,records:StyleRecords,shift:Int=0) {self.range=range;self.records=records;self.shift=shift}
    }
    private var root:BlockNode?
    private var nodes=[String:BlockNode]()
    private var ordered=[BlockNode]()
    private var syntax=[SyntaxPage]()
    public let sourceLayout=LayoutIndex()
    public private(set) var revision = -1
    public private(set) var length=0
    public var count:Int {ordered.count}
    public var styleCoverage:[NSRange] {syntax.map(\.range)}
    public var byteCost:Int {ordered.reduce(0){$0+($1.fragment?.markdown.utf8.count ?? 0)+($1.fragment?.html?.utf8.count ?? 0)}}
    public init() {}

    /// The worker determines identity from complete rendering input, including
    /// resolved references. No edit-character heuristics decide cache validity.
    public func adopt(_ blocks:[PreparedBlock],revision:Int,length:Int) {
        guard revision != self.revision else{return}
        let previous=nodes
        let previousSyntax=syntax
        self.revision=revision;self.length=length;syntax.removeAll(keepingCapacity:true)
        nodes.removeAll(keepingCapacity:true);ordered.removeAll(keepingCapacity:true)
        var start=0
        for (i,block) in blocks.enumerated() {
            precondition(block.from>=start && block.to>=block.from && block.to<=length)
            let end=i==blocks.count-1 ? length:block.to
            let n=BlockNode(block,start:start,end:end)
            if let old=previous[block.id],let f=old.fragment {
                n.fragment=PreviewFragment(kind:block.kind,from:block.from,to:block.to,markdown:f.markdown,html:f.html,id:block.id)
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
            nodes[block.id]=n;ordered.append(n);start=block.to
        }
        func build(_ a:Int,_ b:Int)->BlockNode? {
            guard a<b else{return nil}
            let m=(a+b)/2,n=ordered[m]
            n.left=build(a,m);n.right=build(m+1,b)
            n.left?.parent=n;n.right?.parent=n;n.update();return n
        }
        root=build(0,ordered.count)
        setSyntax(syntax)
    }
    public func store(_ result:ParseResult,range:NSRange) {
        guard result.revision==revision else{return}
        for fragment in result.fragments {
            guard let id=fragment.id,let n=nodes[id],fragment.html != nil else{continue}
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
            result.append(contentsOf:clip(page.records.spans,to:NSIntersectionRange(page.range,range),shift:page.shift));position=NSMaxRange(page.range)
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
    public var allPages:[RenderedPage] {
        var pages=[RenderedPage]()
        for n in ordered {
            guard let fragment=n.fragment else{continue}
            let entry=RenderedEntry(id:n.block.id,fragment:fragment)
            let last=pages.count-1
            if last>=0,NSMaxRange(pages[last].range)==n.start {
                pages[last].range.length=n.end-pages[last].range.location
                pages[last].entries.append(entry)
            } else {pages.append(RenderedPage(range:NSRange(location:n.start,length:n.end-n.start),entries:[entry]))}
        }
        return pages
    }
    public func firstUnpreparedOffset(from position:Int)->Int {
        let htmlGap:Int
        if position==0 {htmlGap=root?.firstGap ?? length}
        else {
            var gap=length
            func visit(_ n:BlockNode?) {
                guard let n,let first=n.firstGap,first<gap else{return}
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
        for (id,height) in heights {nodes[id]?.previewHeight=height}
    }
    public func heights(for id:String)->(source:Double?,preview:Double?)? {
        guard let n=nodes[id] else{return nil}
        let from=sourceLayout.position(at:n.start)?.y
        let to=n.end==sourceLayout.length ? sourceLayout.height:sourceLayout.position(at:n.end)?.y
        return (from.flatMap {a in to.map{$0-a}},n.previewHeight)
    }
}
