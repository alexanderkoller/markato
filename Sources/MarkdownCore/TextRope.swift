import Foundation

/// Immutable AVL rope. Positions and edits use Cocoa/Lezer UTF-16 coordinates.
public struct TextRope: Sendable {
    indirect enum Node: Sendable {
        case leaf([UInt16], Int, Bool)
        case branch(Node, Node, Int, Int, Int, Bool)
        var count: Int { switch self { case .leaf(let a, _, _): return a.count; case .branch(_, _, let n, _, _, _): return n } }
        var breaks: Int { switch self { case .leaf(_, let n, _): return n; case .branch(_, _, _, let n, _, _): return n } }
        var containsCRLF: Bool { switch self { case .leaf(_, _, let value), .branch(_, _, _, _, _, let value): return value } }
        var first: UInt16? { switch self { case .leaf(let a, _, _): return a.first; case .branch(let a, let b, _, _, _, _): return a.first ?? b.first } }
        var last: UInt16? { switch self { case .leaf(let a, _, _): return a.last; case .branch(let a, let b, _, _, _, _): return b.last ?? a.last } }
        var height: Int { switch self { case .leaf: return 1; case .branch(_, _, _, _, let h, _): return h } }
    }
    private var root: Node
    public var count: Int { root.count }
    public var lineCount: Int { root.breaks + 1 }
    public var containsCRLF: Bool { root.containsCRLF }
    public init(_ text: String = "") {
        self.init(units:Array(text.utf16))
    }
    /// Builds the persistent tree from an immutable staging buffer. Leaves
    /// still own their final storage.
    public init(units:[UInt16]) {
        func build(_ start: Int, _ end: Int) -> Node {
            if end - start <= 2048 { return Self.leaf(Array(units[start..<end])) }
            let mid = (start + end) / 2
            return Self.branch(build(start, mid), build(mid, end))
        }
        root = build(0, units.count)
    }
    private init(root: Node) { self.root = root }
    private static func leaf(_ a: [UInt16]) -> Node {
        var breaks = 0, containsCRLF = false, previous: UInt16?
        for unit in a {
            if unit == 10 { breaks += 1; if previous == 13 { containsCRLF = true } }
            previous = unit
        }
        return .leaf(a, breaks, containsCRLF)
    }
    private static func branch(_ a: Node, _ b: Node) -> Node {
        .branch(a, b, a.count + b.count, a.breaks + b.breaks, max(a.height, b.height) + 1,
                a.containsCRLF || b.containsCRLF || (a.last == 13 && b.first == 10))
    }
    private static func balanced(_ a: Node, _ b: Node) -> Node {
        if a.height > b.height + 1, case .branch(let l, let r, _, _, _, _) = a {
            if l.height >= r.height { return branch(l, branch(r, b)) }
            if case .branch(let rl, let rr, _, _, _, _) = r { return branch(branch(l, rl), branch(rr, b)) }
        }
        if b.height > a.height + 1, case .branch(let l, let r, _, _, _, _) = b {
            if r.height >= l.height { return branch(branch(a, l), r) }
            if case .branch(let ll, let lr, _, _, _, _) = l { return branch(branch(a, ll), branch(lr, r)) }
        }
        return branch(a, b)
    }
    private static func joined(_ a: Node, _ b: Node) -> Node {
        if a.count == 0 { return b }; if b.count == 0 { return a }
        if a.height > b.height + 1, case .branch(let l, let r, _, _, _, _) = a { return balanced(l, joined(r, b)) }
        if b.height > a.height + 1, case .branch(let l, let r, _, _, _, _) = b { return balanced(joined(a, l), r) }
        if case .leaf(let x, _, _) = a, case .leaf(let y, _, _) = b, x.count + y.count <= 2048 { return leaf(x + y) }
        return branch(a, b)
    }
    private static func split(_ node: Node, _ at: Int) -> (Node, Node) {
        if at == 0 { return (leaf([]), node) }; if at == node.count { return (node, leaf([])) }
        switch node {
        case .leaf(let a, _, _): return (leaf(Array(a[..<at])), leaf(Array(a[at...])))
        case .branch(let l, let r, _, _, _, _):
            if at < l.count { let (a, b) = split(l, at); return (a, joined(b, r)) }
            let (a, b) = split(r, at - l.count); return (joined(l, a), b)
        }
    }
    public func replacing(_ range: NSRange, with text: String) -> TextRope {
        precondition(range.location >= 0 && NSMaxRange(range) <= count)
        let (a, tail) = Self.split(root, range.location)
        let (_, b) = Self.split(tail, range.length)
        return TextRope(root: Self.joined(Self.joined(a, TextRope(text).root), b))
    }
    public func units(in range: NSRange) -> [UInt16] {
        precondition(range.location >= 0 && NSMaxRange(range) <= count)
        var out = [UInt16](); out.reserveCapacity(range.length)
        func visit(_ node: Node, _ start: Int, _ end: Int) {
            if start >= end { return }
            switch node {
            case .leaf(let a, _, _): out.append(contentsOf: a[start..<end])
            case .branch(let l, let r, _, _, _, _):
                if start < l.count { visit(l, start, min(end, l.count)) }
                if end > l.count { visit(r, max(0, start - l.count), end - l.count) }
            }
        }
        visit(root, range.location, NSMaxRange(range)); return out
    }
    public func string(in range: NSRange) -> String { String(decoding: units(in: range), as: UTF16.self) }
    public var string: String { string(in: NSRange(location: 0, length: count)) }
    public func withContiguousUTF16<Result>(_ body: (UnsafeBufferPointer<UInt16>) -> Result) -> Result {
        let flattened = units(in: NSRange(location: 0, length: count))
        return flattened.withUnsafeBufferPointer(body)
    }
    public func lineStart(_ line: Int) -> Int {
        let wanted = min(max(line, 0), root.breaks)
        if wanted == 0 { return 0 }
        func find(_ node: Node, _ n: Int) -> Int {
            switch node {
            case .leaf(let a, _, _):
                var remaining = n
                for (i, u) in a.enumerated() where u == 10 { remaining -= 1; if remaining == 0 { return i + 1 } }
                return a.count
            case .branch(let l, let r, _, _, _, _):
                return n <= l.breaks ? find(l, n) : l.count + find(r, n - l.breaks)
            }
        }
        return find(root, wanted)
    }
    public func line(at offset: Int) -> Int {
        func countBreaks(_ node: Node, _ at: Int) -> Int {
            switch node {
            case .leaf(let a, _, _): return a.prefix(at).reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
            case .branch(let l, let r, _, _, _, _): return at <= l.count ? countBreaks(l, at) : l.breaks + countBreaks(r, at - l.count)
            }
        }
        return countBreaks(root, min(max(offset, 0), count))
    }
    public func lines(_ start: Int, _ end: Int) -> NSRange {
        let a = lineStart(start), b = end >= lineCount ? count : lineStart(end)
        return NSRange(location: a, length: max(0, b - a))
    }
    public var treeHeight: Int { root.height }
}
