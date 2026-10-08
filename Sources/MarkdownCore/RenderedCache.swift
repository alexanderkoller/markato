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

/// Nonoverlapping source intervals in an AVL tree. Suffix offsets are shifted lazily,
/// so insertion near the beginning does not visit every later cached page.
public final class RenderedCache {
    private final class Node {
        var page:RenderedPage
        var left:Node?,right:Node?
        var height=1,shift=0
        var first:Int,last:Int,continuous=true
        init(_ page:RenderedPage) {
            self.page=page;first=page.range.location;last=NSMaxRange(page.range)
        }
    }
    private var root:Node?
    public private(set) var count=0
    #if DEBUG
    public var byteCost:Int {allPages.flatMap(\.entries).reduce(0){$0+$1.fragment.markdown.utf8.count+($1.fragment.html?.utf8.count ?? 0)}}
    #endif
    public var allPages:[RenderedPage] {
        pages(in:NSRange(location:0,length:Int.max))
    }
    public init() {}
    public func clear() {
        let old=root;root=nil;count=0
        DispatchQueue.global(qos:.utility).async { _ = old?.height }
    }
    private func height(_ n:Node?)->Int { n?.height ?? 0 }
    private func shift(_ n:Node?,_ delta:Int) { guard let n else{return};n.page.range.location += delta;n.first += delta;n.last += delta;n.shift += delta }
    private func shifted(_ f:PreviewFragment,_ delta:Int)->PreviewFragment {
        PreviewFragment(kind:f.kind,from:f.from+delta,to:f.to+delta,markdown:f.markdown,html:f.html)
    }
    private func push(_ n:Node) {
        if n.shift != 0 {
            shift(n.left,n.shift);shift(n.right,n.shift)
            n.page.entries=n.page.entries.map{RenderedEntry(id:$0.id,fragment:shifted($0.fragment,n.shift))}
            n.shift=0
        }
    }
    private func update(_ n:Node) {
        n.height=1+max(height(n.left),height(n.right))
        n.first=n.left?.first ?? n.page.range.location;n.last=n.right?.last ?? NSMaxRange(n.page.range)
        n.continuous=(n.left?.continuous ?? true) && (n.right?.continuous ?? true)
            && (n.left?.last ?? n.page.range.location)>=n.page.range.location
            && (n.right?.first ?? NSMaxRange(n.page.range))<=NSMaxRange(n.page.range)
    }
    private func balance(_ n:Node)->Node {
        update(n)
        if height(n.left)-height(n.right)>1 {
            let l=n.left!;push(l)
            if height(l.left)<height(l.right) { n.left=rotateLeft(l) }
            return rotateRight(n)
        }
        if height(n.right)-height(n.left)>1 {
            let r=n.right!;push(r)
            if height(r.right)<height(r.left) { n.right=rotateRight(r) }
            return rotateLeft(n)
        }
        return n
    }
    private func rotateLeft(_ n:Node)->Node { push(n);let r=n.right!;push(r);n.right=r.left;r.left=n;update(n);update(r);return r }
    private func rotateRight(_ n:Node)->Node { push(n);let l=n.left!;push(l);n.left=l.right;l.right=n;update(n);update(l);return l }
    private func join(_ a:Node?,_ pivot:Node,_ b:Node?)->Node {
        if height(a)>height(b)+1 { let a=a!;push(a);a.right=join(a.right,pivot,b);return balance(a) }
        if height(b)>height(a)+1 { let b=b!;push(b);b.left=join(a,pivot,b.left);return balance(b) }
        pivot.left=a;pivot.right=b;return balance(pivot)
    }
    private func split(_ n:Node?,at key:Int)->(Node?,Node?) {
        guard let n else{return(nil,nil)};push(n)
        if n.page.range.location<key { let (a,b)=split(n.right,at:key);return(join(n.left,n,a),b) }
        let (a,b)=split(n.left,at:key);return(a,join(b,n,n.right))
    }
    private func concatenate(_ a:Node?,_ b:Node?)->Node? {
        guard let a else{return b};guard let b else{return a};push(b)
        if b.left == nil { return join(a,b,b.right) }
        let page=minimum(b).page;let (_,rest)=split(b,at:page.range.location+1)
        return join(a,Node(page),rest)
    }
    private func minimum(_ n:Node)->Node { push(n);return n.left.map{minimum($0)} ?? n }
    private func predecessor(_ key:Int)->Node? {
        var n=root,best:Node?
        while let current=n { push(current);if current.page.range.location<=key {best=current;n=current.right}else{n=current.left} }
        return best
    }
    public func pages(in range:NSRange)->[RenderedPage] {
        var result=[RenderedPage]()
        func visit(_ n:Node?) {
            guard let n else{return};push(n)
            if n.page.range.location>=range.location { visit(n.left) }
            if n.page.range.location>=range.location && n.page.range.location<=NSMaxRange(range) {result.append(n.page)}
            if n.page.range.location<NSMaxRange(range) {visit(n.right)}
        }
        // Include the predecessor page even when its start is outside the query.
        if let p=predecessor(range.location),p.page.range.location<range.location,NSMaxRange(p.page.range)>=range.location {result.append(p.page)}
        visit(root)
        return result
    }
    public func entries(covering range:NSRange)->[RenderedEntry]? {
        let selected=pages(in:range);var end=range.location
        for p in selected {if p.range.location>end{return nil};end=max(end,NSMaxRange(p.range))}
        guard end>=NSMaxRange(range),!selected.isEmpty else{return nil}
        return selected.flatMap{$0.entries}
    }
    @discardableResult public func store(_ result:ParseResult,range:NSRange)->[RenderedEntry] {
        #if DEBUG
        let work=TimingDiagnostics.shared.begin("cache.store")
        defer {TimingDiagnostics.shared.end(work,values:["pages":Double(count),"bytes":Double(byteCost),"fragments":Double(result.fragments.count)])}
        #endif
        let start=min(range.location,result.fragments.first?.from ?? range.location)
        let end=max(NSMaxRange(range),result.fragments.last?.to ?? NSMaxRange(range))
        let pages=pages(in:NSRange(location:start,length:end-start)),old=pages.flatMap{$0.entries}
        let entries=result.fragments.map { f in
            RenderedEntry(id:old.first{$0.fragment.from==f.from && $0.fragment.kind==f.kind}?.id ?? UUID().uuidString,fragment:f)
        }
        remove(NSRange(location:start,length:end-start),delta:0)
        // A background batch can overlap the end of an earlier page. Preserve
        // its prepared prefix/suffix instead of discarding the rest of that page.
        for page in pages {
            if page.range.location<start {
                // A semantic block that crosses the batch edge cannot be
                // preserved as a partly prepared block.
                let prefixEnd=page.entries.filter{$0.fragment.from<start && $0.fragment.to>start}
                    .map{$0.fragment.from}.min() ?? start
                if prefixEnd>page.range.location {
                    insert(RenderedPage(range:NSRange(location:page.range.location,length:prefixEnd-page.range.location),entries:page.entries.filter{$0.fragment.to<=prefixEnd}))
                }
            }
            if NSMaxRange(page.range)>end {
                let suffixStart=page.entries.filter{$0.fragment.from<end && $0.fragment.to>end}
                    .map{$0.fragment.to}.max() ?? end
                if suffixStart<NSMaxRange(page.range) {
                    insert(RenderedPage(range:NSRange(location:suffixStart,length:NSMaxRange(page.range)-suffixStart),entries:page.entries.filter{$0.fragment.from>=suffixStart}))
                }
            }
        }
        insert(RenderedPage(range:NSRange(location:start,length:end-start),entries:entries))

        return entries
    }
    private func insert(_ page:RenderedPage) {
        let (a,b)=split(root,at:page.range.location);root=join(a,Node(page),b);count += 1
    }
    public func invalidate(_ edit:SourceEdit) {
        #if DEBUG
        let work=TimingDiagnostics.shared.begin("cache.invalidate")
        defer {TimingDiagnostics.shared.end(work,values:["pages":Double(count),"bytes":Double(byteCost)])}
        #endif
        remove(edit.range,delta:edit.insertedLength-edit.range.length)
    }
    /// Cached contiguous subtrees are skipped as a unit. An ordinary edit repairs
    /// holes in the cache instead of rerendering every unaffected page.
    public func firstUnpreparedOffset(from position:Int)->Int {
        func end(_ n:Node?,_ position:Int)->Int {
            guard let n,position>=n.first,position<n.last else{return position}
            if n.continuous {return n.last}
            push(n);var covered=position
            if let left=n.left,left.last>covered {
                covered=end(left,covered);if covered<left.last{return covered}
            }
            if n.page.range.location>covered{return covered}
            covered=max(covered,NSMaxRange(n.page.range))
            if let right=n.right,right.last>covered {covered=end(right,covered)}
            return covered
        }
        return end(root,position)
    }
    private func remove(_ range:NSRange,delta:Int) {
        let start=predecessor(range.location).flatMap{NSMaxRange($0.page.range)>=range.location ? $0.page.range.location:nil} ?? range.location
        let (a,tail)=split(root,at:start)
        let (removed,b)=split(tail,at:NSMaxRange(range)+1)
        func nodes(_ n:Node?)->Int {guard let n else{return 0};return 1+nodes(n.left)+nodes(n.right)}
        count -= nodes(removed);shift(b,delta);root=concatenate(a,b)
    }
}
