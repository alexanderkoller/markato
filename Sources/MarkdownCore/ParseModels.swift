import Foundation

public struct SyntaxSpan: Codable, Sendable {
    public let kind: String
    public let from: Int
    public let to: Int
    public var range: NSRange { NSRange(location: from, length: to - from) }
    public init(kind:String,from:Int,to:Int) {self.kind=kind;self.from=from;self.to=to}
}
public struct PreviewFragment: Codable, Equatable, Sendable {
    public let id: String?
    public let kind: String
    public let from: Int
    public let to: Int
    public let markdown: String
    public let html: String?
    public var range: NSRange { NSRange(location: from, length: to - from) }
    public init(kind:String,from:Int,to:Int,markdown:String,html:String? = nil,id:String? = nil) {
        self.id=id
        self.kind=kind; self.from=from; self.to=to; self.markdown=markdown
        self.html=html
    }
}
public struct PreparedBlock: Codable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let from: Int
    public let to: Int
    public init(id:String,kind:String,from:Int,to:Int) {self.id=id;self.kind=kind;self.from=from;self.to=to}
}
public struct PreparedBlockChange: Codable, Equatable, Sendable {
    public let prefix: Int
    public let suffix: Int
    public let shift: Int
    public let blocks: [PreparedBlock]
    public init(prefix:Int,suffix:Int,shift:Int,blocks:[PreparedBlock]) {
        self.prefix=prefix;self.suffix=suffix;self.shift=shift;self.blocks=blocks
    }
}
public struct ParseResult: Codable, Sendable {
    public let revision: Int
    public let spans: [SyntaxSpan]
    public let fragments: [PreviewFragment]
    public let blocks: [PreparedBlock]?
    public let blockChange: PreparedBlockChange?
    public let complete: Bool?
    public init(revision:Int,spans:[SyntaxSpan],fragments:[PreviewFragment],blocks:[PreparedBlock]? = nil,
                blockChange:PreparedBlockChange? = nil,complete:Bool? = nil) {
        self.revision=revision;self.spans=spans;self.fragments=fragments
        self.blocks=blocks;self.blockChange=blockChange;self.complete=complete
    }
}
public struct SourceEdit: Sendable {
    public let range: NSRange
    public let insertedLength: Int
    public init(range: NSRange, insertedLength: Int) { self.range = range; self.insertedLength = insertedLength }
}
