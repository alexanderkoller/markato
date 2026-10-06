import Foundation

public struct SyntaxSpan: Codable, Sendable {
    public let kind: String
    public let from: Int
    public let to: Int
    public var range: NSRange { NSRange(location: from, length: to - from) }
}
public struct PreviewFragment: Codable, Sendable {
    public let kind: String
    public let from: Int
    public let to: Int
    public let anchorFrom: Int
    public let anchorTo: Int
    public let markdown: String
    public let html: String?
    public let containerFrom: Int?
    public let containerTo: Int?
    public var range: NSRange { NSRange(location: from, length: to - from) }
    public init(kind:String,from:Int,to:Int,anchorFrom:Int,anchorTo:Int,markdown:String,html:String? = nil,containerFrom:Int? = nil,containerTo:Int? = nil) {
        self.kind=kind; self.from=from; self.to=to; self.anchorFrom=anchorFrom; self.anchorTo=anchorTo; self.markdown=markdown
        self.containerFrom=containerFrom; self.containerTo=containerTo
        self.html=html
    }
}
public struct ParseResult: Codable, Sendable {
    public let revision: Int
    public let spans: [SyntaxSpan]
    public let fragments: [PreviewFragment]
    public init(revision:Int,spans:[SyntaxSpan],fragments:[PreviewFragment]) { self.revision=revision; self.spans=spans; self.fragments=fragments }
}
public struct SourceEdit: Sendable {
    public let range: NSRange
    public let insertedLength: Int
    public init(range: NSRange, insertedLength: Int) { self.range = range; self.insertedLength = insertedLength }
}
