import Foundation

public enum MarkdownKind:UInt8,Sendable,CaseIterable {
    case pending=0,paragraph=1
    case atxHeading1=2,atxHeading2,atxHeading3,atxHeading4,atxHeading5,atxHeading6
    case setextHeading1=8,setextHeading2,setextHeading3,setextHeading4,setextHeading5,setextHeading6
    case mathBlock=14,orderedList,bulletList,blockquote,table,fencedCode,codeBlock,horizontalRule
    case htmlBlock=22,linkReference,empty,headerMark,strongEmphasis,emphasis,emphasisMark,link
    case linkMark=30,url,codeMark,mathInline,listMark,quoteMark

    public var name:String {
        switch self {
        case .pending:"Pending";case .paragraph:"Paragraph"
        case .atxHeading1:"ATXHeading1";case .atxHeading2:"ATXHeading2"
        case .atxHeading3:"ATXHeading3";case .atxHeading4:"ATXHeading4"
        case .atxHeading5:"ATXHeading5";case .atxHeading6:"ATXHeading6"
        case .setextHeading1:"SetextHeading1";case .setextHeading2:"SetextHeading2"
        case .setextHeading3:"SetextHeading3";case .setextHeading4:"SetextHeading4"
        case .setextHeading5:"SetextHeading5";case .setextHeading6:"SetextHeading6"
        case .mathBlock:"MathBlock";case .orderedList:"OrderedList";case .bulletList:"BulletList"
        case .blockquote:"Blockquote";case .table:"Table";case .fencedCode:"FencedCode"
        case .codeBlock:"CodeBlock";case .horizontalRule:"HorizontalRule";case .htmlBlock:"HTMLBlock"
        case .linkReference:"LinkReference";case .empty:"Empty";case .headerMark:"HeaderMark"
        case .strongEmphasis:"StrongEmphasis";case .emphasis:"Emphasis";case .emphasisMark:"EmphasisMark"
        case .link:"Link";case .linkMark:"LinkMark";case .url:"URL";case .codeMark:"CodeMark"
        case .mathInline:"MathInline";case .listMark:"ListMark";case .quoteMark:"QuoteMark"
        }
    }
    public init(name:String) {self=Self.allCases.first{$0.name==name} ?? .paragraph}
    public var isHeading:Bool {rawValue>=Self.atxHeading1.rawValue && rawValue<=Self.setextHeading6.rawValue}
    public var headingLevel:Int? {
        switch self {
        case .atxHeading1,.setextHeading1:1
        case .atxHeading2,.setextHeading2:2
        case .atxHeading3,.setextHeading3:3
        case .atxHeading4,.setextHeading4:4
        case .atxHeading5,.setextHeading5:5
        case .atxHeading6,.setextHeading6:6
        default:nil
        }
    }
    public var isMark:Bool {
        switch self {case .headerMark,.emphasisMark,.linkMark,.codeMark,.listMark,.quoteMark:true;default:false}
    }
}
public func ==(lhs:MarkdownKind,rhs:String)->Bool {lhs.name==rhs}
public func ==(lhs:String,rhs:MarkdownKind)->Bool {lhs==rhs.name}

public struct BlockID:Hashable,Sendable,ExpressibleByStringLiteral,CustomStringConvertible {
    public let rawValue:UInt64
    public init(_ rawValue:UInt64) {self.rawValue=rawValue}
    public init(stringLiteral value:String) {self.init(value)}
    public init(_ value:String) {
        var hash:UInt64=1469598103934665603
        for byte in value.utf8 {hash=(hash ^ UInt64(byte)) &* 1099511628211}
        rawValue=hash
    }
    public var description:String {String(rawValue)}
    public static func ==(lhs:BlockID,rhs:BlockID)->Bool {lhs.rawValue==rhs.rawValue}
    public func hash(into hasher:inout Hasher) {hasher.combine(rawValue)}
}
public func ==(lhs:BlockID,rhs:String)->Bool {lhs.description==rhs}
public func ==(lhs:String,rhs:BlockID)->Bool {lhs==rhs.description}

public final class HTMLArena:@unchecked Sendable {
    public struct View:@unchecked Sendable {
        let bytes:UnsafePointer<UInt8>?
        let count:Int
        public init(bytes:UnsafePointer<UInt8>?,count:Int) {self.bytes=bytes;self.count=count}
    }
    private let owner:AnyObject
    private let views:[View]
    public init(owner:AnyObject,views:[View]) {self.owner=owner;self.views=views}
    fileprivate func byteCount(at index:Int)->Int {views[index].count}
    fileprivate func string(at index:Int)->String {
        let view=views[index]
        guard view.count>0,let bytes=view.bytes else{return ""}
        return String(decoding:UnsafeBufferPointer(start:bytes,count:view.count),as:UTF8.self)
    }
}
public struct HTMLPayload:@unchecked Sendable {
    private let arena:HTMLArena?
    private let index:Int
    private let eager:String?
    public init(_ string:String) {arena=nil;index=0;eager=string}
    public init(arena:HTMLArena,index:Int) {self.arena=arena;self.index=index;eager=nil}
    public var byteCount:Int {eager?.utf8.count ?? arena?.byteCount(at:index) ?? 0}
    public func string()->String {
        if let eager{return eager}
        return arena?.string(at:index) ?? ""
    }
}

public struct SyntaxSpan:Sendable {
    public let kind:MarkdownKind
    public let from:Int,to:Int
    public var range:NSRange {NSRange(location:from,length:to-from)}
    public init(kind:MarkdownKind,from:Int,to:Int) {self.kind=kind;self.from=from;self.to=to}
    public init(kind:String,from:Int,to:Int) {self.init(kind:MarkdownKind(name:kind),from:from,to:to)}
}
public final class SyntaxArena:@unchecked Sendable {
    public let spans:[SyntaxSpan]
    public init(_ spans:[SyntaxSpan]) {self.spans=spans}
}
public struct SyntaxPayload:@unchecked Sendable {
    private let arena:SyntaxArena
    private let indexRange:Range<Int>
    public init(arena:SyntaxArena,range:Range<Int>) {self.arena=arena;indexRange=range}
    public func clipped(to range:NSRange,shift:Int=0)->[SyntaxSpan] {
        arena.spans[indexRange].compactMap {span in
            let from=max(range.location,span.from+shift),to=min(NSMaxRange(range),span.to+shift)
            return from<to ? SyntaxSpan(kind:span.kind,from:from,to:to):nil
        }
    }
}
public struct PreviewFragment:Equatable,Sendable {
    public let id:BlockID?
    public let kind:MarkdownKind
    public let from:Int,to:Int
    public let html:String?
    public var range:NSRange {NSRange(location:from,length:to-from)}
    public init(kind:MarkdownKind,from:Int,to:Int,html:String?=nil,id:BlockID?=nil) {
        self.id=id;self.kind=kind;self.from=from;self.to=to;self.html=html
    }
    public init(kind:String,from:Int,to:Int,html:String?=nil,id:String?=nil) {
        self.init(kind:MarkdownKind(name:kind),from:from,to:to,html:html,id:id.map{BlockID($0)})
    }
}
/// The single block representation crossing the parser boundary and entering
/// the retained tree. HTML may remain in a shared UTF-8 arena until rendered.
public struct PreparedBlock:Sendable {
    public let id:BlockID
    public let kind:MarkdownKind
    public let from:Int,to:Int
    public let html:HTMLPayload?
    public let syntax:SyntaxPayload?
    public let headingTitle:String?
    public init(id:BlockID,kind:MarkdownKind,from:Int,to:Int,html:HTMLPayload?=nil,
                syntax:SyntaxPayload?=nil,headingTitle:String?=nil) {
        self.id=id;self.kind=kind;self.from=from;self.to=to;self.html=html;self.syntax=syntax
        self.headingTitle=headingTitle
    }
    public init(id:String,kind:String,from:Int,to:Int,html:String?=nil,headingTitle:String?=nil) {
        self.init(id:BlockID(id),kind:MarkdownKind(name:kind),from:from,to:to,
            html:html.map(HTMLPayload.init),headingTitle:headingTitle)
    }
}

public struct DocumentHeading:Equatable,Sendable {
    public let id:BlockID
    public let title:String
    public let level:Int
    public let range:NSRange
    public init(id:BlockID,title:String,level:Int,range:NSRange) {
        self.id=id;self.title=title;self.level=level;self.range=range
    }
}
public struct PreparedBlockChange:Sendable {
    public let prefix:Int,suffix:Int,shift:Int
    public let blocks:[PreparedBlock]
    public init(prefix:Int,suffix:Int,shift:Int,blocks:[PreparedBlock]) {
        self.prefix=prefix;self.suffix=suffix;self.shift=shift;self.blocks=blocks
    }
}
public struct ParseResult:Sendable {
    public let revision:Int
    public let from:Int?,to:Int?
    public let hasReferences:Bool?
    public let spans:[SyntaxSpan]
    public let fragments:[PreviewFragment]
    public let blocks:[PreparedBlock]?
    public let blockChange:PreparedBlockChange?
    public init(revision:Int,spans:[SyntaxSpan],fragments:[PreviewFragment]=[],blocks:[PreparedBlock]?=nil,
                blockChange:PreparedBlockChange?=nil,from:Int?=nil,to:Int?=nil,hasReferences:Bool?=nil) {
        self.revision=revision;self.spans=spans;self.fragments=fragments;self.blocks=blocks
        self.blockChange=blockChange;self.from=from;self.to=to;self.hasReferences=hasReferences
    }
}
public struct SourceEdit:Sendable {
    public let range:NSRange
    public let insertedLength:Int
    public init(range:NSRange,insertedLength:Int) {self.range=range;self.insertedLength=insertedLength}
}
public struct RegionalBlock:Sendable {
    public let id:BlockID
    public let kind:MarkdownKind
    public let from:Int,to:Int
    public let html:String
    public init(id:BlockID,kind:MarkdownKind,from:Int,to:Int,html:String) {
        self.id=id;self.kind=kind;self.from=from;self.to=to;self.html=html
    }
}
public struct RegionalParseContext:Sendable {
    public let range:NSRange
    public let prefix:Int,suffix:Int,shift:Int
    public let firstGuardID:BlockID?,lastGuardID:BlockID?
    public let blocks:[RegionalBlock]
    public init(range:NSRange,prefix:Int,suffix:Int,shift:Int,firstGuardID:BlockID?,lastGuardID:BlockID?,blocks:[RegionalBlock]) {
        self.range=range;self.prefix=prefix;self.suffix=suffix;self.shift=shift
        self.firstGuardID=firstGuardID;self.lastGuardID=lastGuardID;self.blocks=blocks
    }
}
