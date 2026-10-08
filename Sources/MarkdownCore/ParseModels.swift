import Foundation

public struct SyntaxSpan: Codable, Sendable {
    public let kind: String
    public let from: Int
    public let to: Int
    public var range: NSRange { NSRange(location: from, length: to - from) }
}
public struct PreviewFragment: Codable, Equatable, Sendable {
    public let kind: String
    public let from: Int
    public let to: Int
    public let markdown: String
    public let html: String?
    public var range: NSRange { NSRange(location: from, length: to - from) }
    public init(kind:String,from:Int,to:Int,markdown:String,html:String? = nil) {
        self.kind=kind; self.from=from; self.to=to; self.markdown=markdown
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
