import Foundation

/// A measured sequence. Positions are relative; subtree sums locate either a
/// source offset or a vertical position without shifting the unchanged suffix.
public final class LayoutIndex {
    public struct Line: Equatable {
        public let length: Int
        public let advance: Double
        public let height: Double
        public let estimated: Bool
        public init(length: Int, advance: Double, height: Double, estimated:Bool=false) {
            precondition(length > 0 && advance >= 0 && height >= 0)
            self.length=length;self.advance=advance;self.height=height;self.estimated=estimated
        }
    }
    public struct Position: Equatable {
        public let range: NSRange
        public let y: Double
        public let height: Double
        public let estimated: Bool
    }
    private final class Node {
        let line: Line
        let left: Node?, right: Node?
        let length: Int, count: Int, depth: Int
        let advance: Double
        let hasEstimates: Bool
        init(_ line:Line,_ left:Node?=nil,_ right:Node?=nil) {
            self.line=line;self.left=left;self.right=right
            length=(left?.length ?? 0)+line.length+(right?.length ?? 0)
            advance=(left?.advance ?? 0)+line.advance+(right?.advance ?? 0)
            count=(left?.count ?? 0)+1+(right?.count ?? 0)
            depth=1+max(left?.depth ?? 0,right?.depth ?? 0)
            hasEstimates=line.estimated || (left?.hasEstimates ?? false) || (right?.hasEstimates ?? false)
        }
    }
    private var root: Node?
    public private(set) var origin=0.0
    public var length: Int {root?.length ?? 0}
    public var count: Int {root?.count ?? 0}
    public var height: Double {origin+(root?.advance ?? 0)}
    public var treeDepth: Int {root?.depth ?? 0}
    public init() {}

    private func join(_ left:Node?,_ line:Line,_ right:Node?)->Node {
        if (left?.depth ?? 0) > (right?.depth ?? 0)+1 {
            let l=left!
            let r=join(l.right,line,right)
            return balance(l.line,l.left,r)
        }
        if (right?.depth ?? 0) > (left?.depth ?? 0)+1 {
            let r=right!
            let l=join(left,line,r.left)
            return balance(r.line,l,r.right)
        }
        return Node(line,left,right)
    }
    private func balance(_ line:Line,_ left:Node?,_ right:Node?)->Node {
        if (left?.depth ?? 0) > (right?.depth ?? 0)+1 {
            let l=left!
            if (l.left?.depth ?? 0) >= (l.right?.depth ?? 0) {
                return Node(l.line,l.left,Node(line,l.right,right))
            }
            let m=l.right!
            return Node(m.line,Node(l.line,l.left,m.left),Node(line,m.right,right))
        }
        if (right?.depth ?? 0) > (left?.depth ?? 0)+1 {
            let r=right!
            if (r.right?.depth ?? 0) >= (r.left?.depth ?? 0) {
                return Node(r.line,Node(line,left,r.left),r.right)
            }
            let m=r.left!
            return Node(m.line,Node(line,left,m.left),Node(r.line,m.right,r.right))
        }
        return Node(line,left,right)
    }
    private func split(_ n:Node?,_ length:Int)->(Node?,Node?) {
        guard let n else{return(nil,nil)}
        if length==0 {return(nil,n)}
        if length==n.length {return(n,nil)}
        let before=n.left?.length ?? 0
        if length<=before {
            let (a,b)=split(n.left,length)
            return(a,join(b,n.line,n.right))
        }
        if length<before+n.line.length {
            precondition(n.line.estimated,"Layout replacement must start at a measured-line boundary")
            let prefixLength=length-before,suffixLength=n.line.length-prefixLength
            let fraction=Double(prefixLength)/Double(n.line.length)
            let prefix=Line(length:prefixLength,advance:n.line.advance*fraction,height:n.line.height,estimated:true)
            let suffix=Line(length:suffixLength,advance:n.line.advance*(1-fraction),height:n.line.height,estimated:true)
            return(join(n.left,prefix,nil),join(nil,suffix,n.right))
        }
        let (a,b)=split(n.right,length-before-n.line.length)
        return(join(n.left,n.line,a),b)
    }
    private func append(_ a:Node?,_ b:Node?)->Node? {
        guard let b else{return a}
        return join(append(a,b.left),b.line,b.right)
    }
    public func replaceSuffix(at offset:Int,with lines:[Line],origin:Double?=nil) {
        replace(NSRange(location:offset,length:length-offset),with:lines,origin:origin)
    }
    /// Retains both sides by reference. Source offsets and vertical positions
    /// in the suffix shift through subtree sums, without visiting its lines.
    public func replace(_ range:NSRange,with lines:[Line],origin:Double?=nil) {
        precondition(range.location>=0 && NSMaxRange(range)<=length)
        if range.location==0 {self.origin=origin ?? self.origin}
        func build(_ from:Int,_ to:Int)->Node? {
            guard from<to else{return nil}
            let mid=(from+to)/2
            return Node(lines[mid],build(from,mid),build(mid+1,to))
        }
        let (before,tail)=split(root,range.location)
        let (_,after)=split(tail,range.length)
        root=append(append(before,build(0,lines.count)),after)
    }
    public func position(at offset:Int)->Position? {
        guard offset>=0,offset<length else{return nil}
        var node=root,start=0,y=origin
        while let n=node {
            let before=n.left?.length ?? 0,above=n.left?.advance ?? 0
            if offset<start+before {node=n.left}
            else if offset<start+before+n.line.length {
                let lineStart=start+before,lineY=y+above
                if n.line.estimated {
                    let fraction=Double(offset-lineStart)/Double(max(1,n.line.length))
                    return Position(range:NSRange(location:offset,length:1),y:lineY+n.line.advance*fraction,height:n.line.height,estimated:true)
                }
                return Position(range:NSRange(location:lineStart,length:n.line.length),y:lineY,height:n.line.height,estimated:false)
            } else {start += before+n.line.length;y += above+n.line.advance;node=n.right}
        }
        return nil
    }
    public func position(atY target:Double)->Position? {
        var node=root,start=0,y=origin,candidate:Position?
        while let n=node {
            let before=n.left?.length ?? 0,above=n.left?.advance ?? 0
            let lineY=y+above
            let lineStart=start+before
            if n.line.estimated,target<lineY+n.line.advance {
                let fraction=max(0,min(1,(target-lineY)/max(n.line.advance,0.001)))
                let offset=min(lineStart+n.line.length-1,lineStart+Int(Double(n.line.length)*fraction))
                return Position(range:NSRange(location:offset,length:1),y:lineY+n.line.advance*fraction,height:n.line.height,estimated:true)
            }
            if target<lineY+n.line.height {
                candidate=Position(range:NSRange(location:lineStart,length:n.line.length),y:lineY,height:n.line.height,estimated:false)
                node=n.left
            } else {start += before+n.line.length;y=lineY+n.line.advance;node=n.right}
        }
        return candidate
    }
    public func hasEstimates(in range:NSRange)->Bool {
        guard range.length>0 else{return false}
        func visit(_ node:Node?,_ start:Int)->Bool {
            guard let node else{return false}
            let before=node.left?.length ?? 0,lineStart=start+before,lineEnd=lineStart+node.line.length
            if range.location<lineStart,visit(node.left,start) {return true}
            if range.location<lineEnd,NSMaxRange(range)>lineStart,node.line.estimated {return true}
            return NSMaxRange(range)>lineEnd && visit(node.right,lineEnd)
        }
        return visit(root,0)
    }
    public func firstEstimatedRange(atOrAfter offset:Int=0)->NSRange? {
        let requested=max(0,min(offset,length))
        func find(_ node:Node?,_ start:Int)->NSRange? {
            guard let node,node.hasEstimates,start+node.length>requested else{return nil}
            let before=node.left?.length ?? 0,lineStart=start+before
            if let found=find(node.left,start) {return found}
            if node.line.estimated,lineStart+node.line.length>requested {
                return NSRange(location:lineStart,length:node.line.length)
            }
            return find(node.right,lineStart+node.line.length)
        }
        return find(root,0)
    }
    /// Once TextKit has measured the document end, keep exact lines fixed and
    /// distribute the remaining height across the still-estimated regions.
    public func fitEstimatedHeight(to totalHeight:Double) {
        func sums(_ node:Node?)->(exact:Double,estimated:Double) {
            guard let node else{return(0,0)}
            let a=sums(node.left),b=sums(node.right)
            return (a.exact+b.exact+(node.line.estimated ? 0:node.line.advance),
                a.estimated+b.estimated+(node.line.estimated ? node.line.advance:0))
        }
        let values=sums(root),available=max(0,totalHeight-origin-values.exact)
        guard values.estimated>0 else{return}
        let scale=available/values.estimated
        func adjusted(_ node:Node?)->Node? {
            guard let node else{return nil}
            let line=node.line.estimated ? Line(length:node.line.length,advance:node.line.advance*scale,height:node.line.height,estimated:true):node.line
            return Node(line,adjusted(node.left),adjusted(node.right))
        }
        root=adjusted(root)
    }
}
