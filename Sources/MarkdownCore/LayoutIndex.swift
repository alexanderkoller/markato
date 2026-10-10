import Foundation

/// A measured sequence. Positions are relative; subtree sums locate either a
/// source offset or a vertical position without shifting the unchanged suffix.
public final class LayoutIndex {
    public struct Line: Equatable {
        public let length: Int
        public let advance: Double
        public let height: Double
        public init(length: Int, advance: Double, height: Double) {
            precondition(length > 0 && advance >= 0 && height >= 0)
            self.length=length;self.advance=advance;self.height=height
        }
    }
    public struct Position: Equatable {
        public let range: NSRange
        public let y: Double
        public let height: Double
    }
    private final class Node {
        let line: Line
        let left: Node?, right: Node?
        let length: Int, count: Int, depth: Int
        let advance: Double
        init(_ line:Line,_ left:Node?=nil,_ right:Node?=nil) {
            self.line=line;self.left=left;self.right=right
            length=(left?.length ?? 0)+line.length+(right?.length ?? 0)
            advance=(left?.advance ?? 0)+line.advance+(right?.advance ?? 0)
            count=(left?.count ?? 0)+1+(right?.count ?? 0)
            depth=1+max(left?.depth ?? 0,right?.depth ?? 0)
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
        precondition(length>=before+n.line.length,"Layout replacement must start at a measured-line boundary")
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
                return Position(range:NSRange(location:start+before,length:n.line.length),y:y+above,height:n.line.height)
            } else {start += before+n.line.length;y += above+n.line.advance;node=n.right}
        }
        return nil
    }
    public func position(atY target:Double)->Position? {
        var node=root,start=0,y=origin,candidate:Position?
        while let n=node {
            let before=n.left?.length ?? 0,above=n.left?.advance ?? 0
            let lineY=y+above
            if target<lineY+n.line.height {
                candidate=Position(range:NSRange(location:start+before,length:n.line.length),y:lineY,height:n.line.height)
                node=n.left
            } else {start += before+n.line.length;y=lineY+n.line.advance;node=n.right}
        }
        return candidate
    }
}
