import Foundation

public enum MarkdownCommentStatus:String,Codable,Sendable {
    case open,resolved
}

public enum MarkdownCommentExtent:String,Codable,Sendable {
    case blocks
}

public struct MarkdownCommentAnchor:Codable,Equatable,Sendable {
    public var exact:String
    public var prefix:String
    public var suffix:String
    public var renderedExact:String?
    public var renderedPrefix:String?
    public var renderedSuffix:String?
    public var position:Int?
    public var extent:MarkdownCommentExtent?
    public init(exact:String,prefix:String="",suffix:String="",position:Int?=nil,
                extent:MarkdownCommentExtent?=nil,renderedExact:String?=nil,
                renderedPrefix:String?=nil,renderedSuffix:String?=nil) {
        self.exact=exact;self.prefix=prefix;self.suffix=suffix;self.position=position;self.extent=extent
        self.renderedExact=renderedExact;self.renderedPrefix=renderedPrefix;self.renderedSuffix=renderedSuffix
    }
}

public struct MarkdownComment:Codable,Equatable,Identifiable,Sendable {
    public var id:String
    public var status:MarkdownCommentStatus
    public var anchor:MarkdownCommentAnchor
    public var author:String
    public var created:String
    public var body:String
    public init(id:String=UUID().uuidString,status:MarkdownCommentStatus = .open,
                anchor:MarkdownCommentAnchor,author:String,created:String,body:String) {
        self.id=id;self.status=status;self.anchor=anchor
        self.author=author;self.created=created;self.body=body
    }
}

public struct ResolvedMarkdownComment:Equatable,Sendable {
    public var comment:MarkdownComment
    public let recordRange:NSRange
    public let anchorRange:NSRange?
    public init(comment:MarkdownComment,recordRange:NSRange,anchorRange:NSRange?) {
        self.comment=comment;self.recordRange=recordRange;self.anchorRange=anchorRange
    }
}

/// The single-file interchange format for Markato comments. Records are
/// ordinary HTML comments, so other CommonMark renderers keep them invisible.
/// JSON strings escape a consecutive hyphen when serialized because HTML
/// comments may not contain `--` in their body.
public enum MarkdownComments {
    public static let marker="<!-- markato-comment:v1"
    private static let closing="-->"
    private static let contextLength=48

    public static func anchor(in source:String,selection:NSRange)->MarkdownCommentAnchor {
        let text=source as NSString
        let safe=NSIntersectionRange(NSRange(location:0,length:text.length),selection)
        let before=NSRange(location:max(0,safe.location-contextLength),
            length:min(contextLength,safe.location))
        let end=NSMaxRange(safe)
        let after=NSRange(location:end,length:min(contextLength,text.length-end))
        return MarkdownCommentAnchor(exact:text.substring(with:safe),
            prefix:text.substring(with:before),suffix:text.substring(with:after),position:safe.location)
    }

    public static func comment(in source:String,selection:NSRange,body:String,author:String,
                               created:String=ISO8601DateFormatter().string(from:Date()),
                               renderedEntries:[RenderedEntry]=[])->MarkdownComment {
        var value=anchor(in:source,selection:selection)
        if selection.length>0,!renderedEntries.isEmpty {
            let selected=renderedEntries.filter {entry in
                NSIntersectionRange(entry.fragment.range,selection).length>0
            }
            var remainsInline=selected.count==1 && MarkdownCommentHTML.canHighlight(value,in:selected[0].fragment.html ?? "")
            if !remainsInline,selected.count==1,let entry=selected.first,
               let rendered=MarkdownCommentHTML.renderedAnchor(in:source,selection:selection,entry:entry) {
                value.renderedExact=rendered.exact;value.renderedPrefix=rendered.prefix;value.renderedSuffix=rendered.suffix
                remainsInline=MarkdownCommentHTML.canHighlight(value,in:entry.fragment.html ?? "")
            }
            if !remainsInline,let first=selected.first,let last=selected.last {
                let range=NSRange(location:first.fragment.from,length:last.fragment.to-first.fragment.from)
                value=anchor(in:source,selection:range);value.extent = .blocks
            }
        }
        return MarkdownComment(anchor:value,author:author,created:created,body:body)
    }

    public static func serialize(_ comment:MarkdownComment,newline:String="\n")->String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        // These model values are always JSON encodable. Keeping the failure
        // local produces a valid, inspectable record even for future fields.
        let data=(try? encoder.encode(comment)) ?? Data("{}".utf8)
        var json=String(decoding:data,as:UTF8.self)
        json=json.replacingOccurrences(of:"--",with:"-\\u002d")
        if newline != "\n" {json=json.replacingOccurrences(of:"\n",with:newline)}
        return marker+newline+json+newline+closing
    }

    public static func insertion(for comment:MarkdownComment,in source:String,newline:String="\n")->String {
        let separator: String
        if source.isEmpty {separator=""}
        else if source.hasSuffix("\r\n\r\n") || source.hasSuffix("\n\n") {separator=""}
        else if source.hasSuffix("\r\n") || source.hasSuffix("\n") {separator=newline}
        else {separator=newline+newline}
        return separator+serialize(comment,newline:newline)+newline
    }

    public static func records(in source:String)->[ResolvedMarkdownComment] {
        let text=source as NSString
        let whole=NSRange(location:0,length:text.length)
        var parsed=[(MarkdownComment,NSRange)](),cursor=0
        while cursor<text.length {
            let opening=text.range(of:marker,options:[],range:NSRange(location:cursor,length:text.length-cursor))
            guard opening.location != NSNotFound else{break}
            let bodyStart=NSMaxRange(opening)
            let close=text.range(of:closing,options:[],range:NSRange(location:bodyStart,length:text.length-bodyStart))
            guard close.location != NSNotFound else{break}
            let record=NSRange(location:opening.location,length:NSMaxRange(close)-opening.location)
            let bodyRange=NSRange(location:bodyStart,length:close.location-bodyStart)
            let body=text.substring(with:bodyRange).trimmingCharacters(in:.whitespacesAndNewlines)
            if let data=body.data(using:.utf8),let comment=try? JSONDecoder().decode(MarkdownComment.self,from:data) {
                parsed.append((comment,record))
            }
            cursor=max(NSMaxRange(record),opening.location+1)
        }
        let contentEnd=parsed.map{$0.1.location}.min() ?? whole.length
        let contentRange=NSRange(location:0,length:contentEnd)
        return parsed.map {comment,record in
            ResolvedMarkdownComment(comment:comment,recordRange:record,
                anchorRange:resolve(comment.anchor,in:text,contentRange:contentRange))
        }
    }

    private static func resolve(_ anchor:MarkdownCommentAnchor,in text:NSString,contentRange:NSRange)->NSRange? {
        if anchor.exact.isEmpty {
            return NSRange(location:min(max(0,anchor.position ?? 0),NSMaxRange(contentRange)),length:0)
        }
        var matches=[NSRange](),cursor=contentRange.location
        while cursor<NSMaxRange(contentRange) {
            let candidate=text.range(of:anchor.exact,options:.literal,
                range:NSRange(location:cursor,length:NSMaxRange(contentRange)-cursor))
            guard candidate.location != NSNotFound else{break}
            matches.append(candidate);cursor=max(NSMaxRange(candidate),candidate.location+1)
        }
        guard !matches.isEmpty else{return nil}
        func score(_ range:NSRange)->(Int,Int) {
            var context=0
            if !anchor.prefix.isEmpty,range.location>=anchor.prefix.utf16.count {
                let prefix=NSRange(location:range.location-anchor.prefix.utf16.count,length:anchor.prefix.utf16.count)
                if text.substring(with:prefix)==anchor.prefix {context += 2}
            }
            if !anchor.suffix.isEmpty,NSMaxRange(range)+anchor.suffix.utf16.count<=NSMaxRange(contentRange) {
                let suffix=NSRange(location:NSMaxRange(range),length:anchor.suffix.utf16.count)
                if text.substring(with:suffix)==anchor.suffix {context += 2}
            }
            let distance=abs(range.location-(anchor.position ?? range.location))
            return (context,-distance)
        }
        return matches.max {score($0)<score($1)}
    }
}

public enum MarkdownCommentHTML {
    private static let contextLength=48
    public static func decorate(_ entries:[RenderedEntry],with comments:[ResolvedMarkdownComment],selectedID:String?=nil)->[RenderedEntry] {
        guard !comments.isEmpty else{return entries}
        var bubbleBlock=[String:BlockID]()
        for comment in comments where comment.comment.status == .open || comment.comment.id == selectedID {
            let position=comment.anchorRange?.location ?? comment.comment.anchor.position ?? -1
            let owner=entries.first {position >= $0.fragment.from && position < $0.fragment.to}
                ?? entries.last(where:{position == $0.fragment.to})
            if let owner {bubbleBlock[comment.comment.id]=owner.blockID}
        }
        return entries.map {entry in
            var html=entry.fragment.html ?? ""
            let relevant=comments.filter {comment in
                guard comment.comment.status == .open || comment.comment.id == selectedID else{return false}
                if let range=comment.anchorRange {
                    return range.length==0
                        ? range.location>=entry.fragment.from && range.location<=entry.fragment.to
                        : NSIntersectionRange(range,entry.fragment.range).length>0
                }
                let position=comment.comment.anchor.position ?? -1
                return position>=entry.fragment.from && position<=entry.fragment.to
            }
            guard !relevant.isEmpty else{return entry}
            var highlightsBlock=false,selectsBlock=false
            for comment in relevant {
                let value=comment.comment
                let selected=value.id == selectedID
                let exact=value.anchor.exact
                if value.anchor.extent == .blocks {
                    highlightsBlock=true;selectsBlock = selectsBlock || selected
                } else if !exact.isEmpty {
                    let decorated=highlightTextOccurrence(value.anchor,in:html,id:value.id,selected:selected)
                    if decorated == html {
                        // Records created before block normalization may still
                        // cross inline syntax. Render them cleanly without
                        // requiring an eager source-file migration.
                        highlightsBlock=true;selectsBlock = selectsBlock || selected
                    } else {html=decorated}
                }
            }
            if highlightsBlock {html=decorateRoot(html,selected:selectsBlock)}
            let bubbles=relevant.filter {bubbleBlock[$0.comment.id] == entry.blockID}
            var bubbleHTML=""
            for (index,comment) in bubbles.enumerated() {
                let value=comment.comment,selected=value.id == selectedID
                let title=escapeAttribute(value.body.prefix(160).description)
                let id=escapeAttribute(value.id)
                let className="markato-comment-bubble"+(selected ? " is-selected":"")
                bubbleHTML += "<a class=\"\(className)\" data-comment-id=\"\(id)\" style=\"top:\(Double(index)*26-2)px\" href=\"markato-comment:\(id)\" title=\"\(title)\" aria-label=\"Open comment\"></a>"
            }
            html=bubbleHTML+html
            let fragment=PreviewFragment(kind:entry.fragment.kind,from:entry.fragment.from,to:entry.fragment.to,
                html:html,id:entry.fragment.id)
            return RenderedEntry(id:entry.blockID,fragment:fragment)
        }
    }

    public static func canHighlight(_ anchor:MarkdownCommentAnchor,in html:String)->Bool {
        !bestTextMatch(anchor,in:html).isEmpty
    }

    private static func highlightTextOccurrence(_ anchor:MarkdownCommentAnchor,in html:String,id:String,selected:Bool)->String {
        let matches=bestTextMatch(anchor,in:html)
        guard !matches.isEmpty else{return html}
        var result=html
        let className="markato-comment-highlight"+(selected ? " is-selected":"")
        let opening="<mark class=\"\(className)\" data-comment-id=\"\(escapeAttribute(id))\">"
        for match in matches.reversed() {
            result.insert(contentsOf:"</mark>",at:match.upperBound)
            result.insert(contentsOf:opening,at:match.lowerBound)
        }
        return result
    }

    private struct TextRun {
        let html:Range<String.Index>
        let flat:Range<Int>
    }
    private static func textRuns(in html:String)->(flat:String,runs:[TextRun])? {
        var flat="",runs=[TextRun](),index=html.startIndex
        while index<html.endIndex {
            if html[index]=="<" {
                guard let close=html[index...].firstIndex(of:">") else{return nil}
                index=html.index(after:close);continue
            }
            let end=html[index...].firstIndex(of:"<") ?? html.endIndex
            if index<end {
                let start=flat.count;flat.append(contentsOf:html[index..<end])
                runs.append(TextRun(html:index..<end,flat:start..<flat.count))
            }
            index=end
        }
        return (flat,runs)
    }
    private static func bestTextMatch(_ anchor:MarkdownCommentAnchor,in html:String)->[Range<String.Index>] {
        guard let content=textRuns(in:html) else{return []}
        let needle=escapeText(anchor.renderedExact ?? anchor.exact)
        let prefix=escapeText(anchor.renderedPrefix ?? anchor.prefix)
        let suffix=escapeText(anchor.renderedSuffix ?? anchor.suffix)
        guard !needle.isEmpty else{return []}
        var cursor=content.flat.startIndex,best:(Range<String.Index>,Int)?
        while cursor<content.flat.endIndex,let match=content.flat[cursor...].range(of:needle) {
            let before=content.flat[..<match.lowerBound],after=content.flat[match.upperBound...]
            let score=(prefix.isEmpty || before.hasSuffix(prefix) ? 2:0)
                + (suffix.isEmpty || after.hasPrefix(suffix) ? 2:0)
            if best == nil || score>best!.1 {best=(match,score)}
            cursor=match.upperBound
        }
        guard let target=best?.0 else{return []}
        let targetStart=content.flat.distance(from:content.flat.startIndex,to:target.lowerBound)
        let targetEnd=content.flat.distance(from:content.flat.startIndex,to:target.upperBound)
        let targetRange=targetStart..<targetEnd
        return content.runs.compactMap {run in
            let lowerOffset=max(run.flat.lowerBound,targetRange.lowerBound)
            let upperOffset=min(run.flat.upperBound,targetRange.upperBound)
            guard lowerOffset<upperOffset else{return nil}
            let overlap=lowerOffset..<upperOffset
            let lower=html.index(run.html.lowerBound,offsetBy:overlap.lowerBound-run.flat.lowerBound)
            let upper=html.index(run.html.lowerBound,offsetBy:overlap.upperBound-run.flat.lowerBound)
            return lower..<upper
        }
    }

    public static func renderedAnchor(in source:String,selection:NSRange,entry:RenderedEntry)
        ->(exact:String,prefix:String,suffix:String)? {
        guard let html=entry.fragment.html,let content=textRuns(in:html) else{return nil}
        let flat=decodeEntities(content.flat)
        let sourceText=source as NSString
        let blockRange=NSIntersectionRange(entry.fragment.range,NSRange(location:0,length:sourceText.length))
        let selected=NSIntersectionRange(selection,blockRange)
        guard selected.length>0 else{return nil}
        let raw=sourceText.substring(with:blockRange)
        let rawUnits=Array(raw.utf16),flatUnits=Array(flat.utf16)
        let relative=NSRange(location:selected.location-blockRange.location,length:selected.length)
        var sourceIndex=0,flatIndex=0,mapped=[Int]()
        while sourceIndex<rawUnits.count,flatIndex<flatUnits.count {
            if rawUnits[sourceIndex]==flatUnits[flatIndex] {
                if NSLocationInRange(sourceIndex,relative) {mapped.append(flatIndex)}
                sourceIndex += 1;flatIndex += 1;continue
            }
            if let next=rawUnits[(sourceIndex+1)...].firstIndex(of:flatUnits[flatIndex]) {
                sourceIndex=next;continue
            }
            flatIndex += 1
        }
        guard let first=mapped.first,let last=mapped.last,first<=last else{return nil}
        let text=flat as NSString,range=NSRange(location:first,length:last-first+1)
        let before=NSRange(location:max(0,range.location-contextLength),length:min(contextLength,range.location))
        let end=NSMaxRange(range),after=NSRange(location:end,length:min(contextLength,text.length-end))
        return (text.substring(with:range),text.substring(with:before),text.substring(with:after))
    }
    private static func decodeEntities(_ value:String)->String {
        var result=value
        for (entity,character) in [("&amp;","&"),("&lt;","<"),("&gt;",">"),("&quot;","\""),("&#39;","'")] {
            result=result.replacingOccurrences(of:entity,with:character)
        }
        return result
    }

    private static func decorateRoot(_ html:String,selected:Bool)->String {
        guard let opening=html.firstIndex(of:"<"),opening<html.endIndex,
              let close=html[opening...].firstIndex(of:">") else{return html}
        let next=html.index(after:opening)
        guard next<close,!"/!?".contains(html[next]) else{return html}
        var result=html
        let attributes=" data-markato-comment-block"+(selected ? " data-markato-comment-selected":"")
        var insertion=close,index=html.index(before:close)
        while index>opening,html[index].isWhitespace {index=html.index(before:index)}
        if html[index]=="/" {insertion=index}
        result.insert(contentsOf:attributes,at:insertion);return result
    }

    private static func escapeText(_ value:String)->String {
        value.replacingOccurrences(of:"&",with:"&amp;")
            .replacingOccurrences(of:"<",with:"&lt;")
            .replacingOccurrences(of:">",with:"&gt;")
    }
    private static func escapeAttribute(_ value:String)->String {
        escapeText(value).replacingOccurrences(of:"\"",with:"&quot;")
            .replacingOccurrences(of:"'",with:"&#39;")
            .replacingOccurrences(of:"\n",with:"&#10;")
            .replacingOccurrences(of:"\r",with:"&#13;")
    }
}
