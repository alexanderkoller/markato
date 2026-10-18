import Foundation

public enum MarkdownCommentStatus:String,Codable,Sendable {
    case open,resolved
}

public struct MarkdownCommentAnchor:Codable,Equatable,Sendable {
    public var exact:String
    public var prefix:String
    public var suffix:String
    public var renderedExact:String?
    public var renderedPrefix:String?
    public var renderedSuffix:String?
    public var startExact:String?
    public var endExact:String?
    public var position:Int?
    public init(exact:String,prefix:String="",suffix:String="",position:Int?=nil,
                renderedExact:String?=nil,
                renderedPrefix:String?=nil,renderedSuffix:String?=nil,
                startExact:String?=nil,endExact:String?=nil) {
        self.exact=exact;self.prefix=prefix;self.suffix=suffix;self.position=position
        self.renderedExact=renderedExact;self.renderedPrefix=renderedPrefix;self.renderedSuffix=renderedSuffix
        self.startExact=startExact;self.endExact=endExact
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
/// Quoted selectors use JSON string escaping; the readable body doubles
/// backslashes and escapes consecutive hyphens because HTML comments may not
/// contain `--` in their body.
public enum MarkdownComments {
    public static let marker="markato-comment:v3"
    private static let opening="<!--"
    private static let closing="-->"
    private static let fieldDelimiter=" | "
    private static let terminalTag=fieldDelimiter+marker
    private static let contextLength=48

    private static func endpointPairs(start:String,end:String,in text:NSString,
                                      range:NSRange)->[NSRange] {
        var result=[NSRange](),cursor=range.location
        while cursor<NSMaxRange(range) {
            let opening=text.range(of:start,options:.literal,
                range:NSRange(location:cursor,length:NSMaxRange(range)-cursor))
            guard opening.location != NSNotFound else{break}
            let after=NSMaxRange(opening)
            let closing=text.range(of:end,options:.literal,
                range:NSRange(location:after,length:NSMaxRange(range)-after))
            if closing.location != NSNotFound {
                result.append(NSRange(location:opening.location,
                    length:NSMaxRange(closing)-opening.location))
            }
            cursor=max(NSMaxRange(opening),opening.location+1)
        }
        return result
    }

    private static func compactSelector(for exact:String,in source:String?=nil,
                                        selection:NSRange?=nil,context:NSRange?=nil)
        ->(start:String,end:String)? {
        let characters=exact.count
        guard exact.contains(where:{$0.isNewline}) || characters>72,characters>32 else{return nil}
        let maximum=min(64,max(16,(characters-1)/2))
        func isWord(_ character:Character)->Bool {
            character.isLetter || character.isNumber || character=="_"
        }
        func startMarker(_ target:Int)->String? {
            var boundary=exact.index(exact.startIndex,offsetBy:min(target,characters))
            if boundary>exact.startIndex,boundary<exact.endIndex,
               isWord(exact[exact.index(before:boundary)]),isWord(exact[boundary]) {
                while boundary<exact.endIndex,isWord(exact[boundary]) {
                    boundary=exact.index(after:boundary)
                }
            }
            var value=exact[..<boundary]
            while let last=value.last,last.isWhitespace {value=value.dropLast()}
            return value.isEmpty ? nil:String(value)
        }
        func endMarker(_ target:Int)->String? {
            var boundary=exact.index(exact.endIndex,offsetBy:-min(target,characters))
            if boundary>exact.startIndex,boundary<exact.endIndex,
               isWord(exact[exact.index(before:boundary)]),isWord(exact[boundary]) {
                while boundary>exact.startIndex,isWord(exact[exact.index(before:boundary)]) {
                    boundary=exact.index(before:boundary)
                }
            }
            var value=exact[boundary...]
            while let first=value.first,first.isWhitespace {value=value.dropFirst()}
            return value.isEmpty ? nil:String(value)
        }
        var tried=Set<String>()
        for length in stride(from:16,through:maximum,by:8) {
            guard let start=startMarker(length),let end=endMarker(length),
                  start.count<=96,end.count<=96,start.count+end.count<characters else{continue}
            let signature=start+"\u{0}"+end
            guard tried.insert(signature).inserted else{continue}
            let interior=exact.dropFirst(start.count).dropLast(end.count)
            guard !interior.contains(start),!interior.contains(end) else{continue}
            if let source,let selection {
                let text=source as NSString
                let scope=NSIntersectionRange(NSRange(location:0,length:text.length),context ?? selection)
                let pairs=endpointPairs(start:start,end:end,in:text,
                    range:scope)
                guard pairs.count==1,pairs[0]==selection else{continue}
            }
            return (start,end)
        }
        return nil
    }

    public static func anchor(in source:String,selection:NSRange,
                              selectorContext:NSRange?=nil)->MarkdownCommentAnchor {
        let text=source as NSString
        let safe=NSIntersectionRange(NSRange(location:0,length:text.length),selection)
        let before=NSRange(location:max(0,safe.location-contextLength),
            length:min(contextLength,safe.location))
        let end=NSMaxRange(safe)
        let after=NSRange(location:end,length:min(contextLength,text.length-end))
        let exact=text.substring(with:safe)
        let compact=compactSelector(for:exact,in:source,selection:safe,context:selectorContext)
        return MarkdownCommentAnchor(exact:exact,
            prefix:text.substring(with:before),suffix:text.substring(with:after),position:safe.location,
            startExact:compact?.start,endExact:compact?.end)
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
                value=anchor(in:source,selection:range)
            }
        }
        return MarkdownComment(anchor:value,author:author,created:created,body:body)
    }

    public static func serialize(_ comment:MarkdownComment,newline:String="\n")->String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.withoutEscapingSlashes]
        func quoted(_ value:String)->String {
            let data=(try? encoder.encode(value)) ?? Data("\"\"".utf8)
            return String(decoding:data,as:UTF8.self)
        }
        var header=""
        let compact: (start:String,end:String)?
        if let start=comment.anchor.startExact,let end=comment.anchor.endExact {compact=(start,end)}
        else {compact=nil}
        if let compact {
            let (start,end)=compact
            header += "\(quoted(start)) ... \(quoted(end))"
        } else {header += quoted(comment.anchor.exact)}
        // Compact raw endpoints are sufficient to recover the source range.
        // The rendered selector is derived again from that range, so repeating
        // another potentially long quote here would bury the comment body.
        if compact == nil,let rendered=comment.anchor.renderedExact {
            header += " => \(quoted(rendered))"
        }
        func escaped(_ value:String)->String {
            value.replacingOccurrences(of:"\\",with:"\\\\")
                .replacingOccurrences(of:"--",with:"-\\-")
        }
        let body=escaped(comment.body)
            .replacingOccurrences(of:fieldDelimiter,with:" \\| ")
        let selector=escaped(header)
        let payload=body+fieldDelimiter+selector+terminalTag
        var value=opening+" "+payload+" "+closing
        if newline != "\n" {value=value.replacingOccurrences(of:"\n",with:newline)}
        return value
    }

    public static func insertion(for comment:MarkdownComment,in source:String,at location:Int?=nil,
                                 newline:String="\n")->String {
        let text=source as NSString
        let position=min(max(0,location ?? text.length),text.length)
        let prefix=text.substring(to:position)
        let separator: String
        if prefix.isEmpty {separator=""}
        else if prefix.hasSuffix("\r\n\r\n") || prefix.hasSuffix("\n\n") {separator=""}
        else if prefix.hasSuffix("\r\n") || prefix.hasSuffix("\n") {separator=newline}
        else {separator=newline+newline}
        let suffix=position<text.length ? text.substring(from:position):""
        let trailing=(suffix.hasPrefix("\r\n") || suffix.hasPrefix("\n")) ? "":newline
        return separator+serialize(comment,newline:newline)+newline+trailing
    }

    public static func records(in source:String)->[ResolvedMarkdownComment] {
        let text=source as NSString
        var parsed=[(MarkdownComment,NSRange)](),cursor=0
        while cursor<text.length {
            let search=NSRange(location:cursor,length:text.length-cursor)
            let commentStart=text.range(of:opening,options:[],range:search)
            guard commentStart.location != NSNotFound else{break}
            let bodyStart=NSMaxRange(commentStart)
            let close=text.range(of:closing,options:[],range:NSRange(location:bodyStart,length:text.length-bodyStart))
            guard close.location != NSNotFound else{break}
            let record=NSRange(location:commentStart.location,length:NSMaxRange(close)-commentStart.location)
            let bodyRange=NSRange(location:bodyStart,length:close.location-bodyStart)
            let payload=text.substring(with:bodyRange).trimmingCharacters(in:.whitespacesAndNewlines)
            if let comment=parseCurrent(payload) {
                parsed.append((comment,record))
            }
            cursor=max(NSMaxRange(record),commentStart.location+1)
        }
        let recordRanges=parsed.map{$0.1}
        return parsed.map {comment,record in
            let range=NSRange(location:0,length:record.location)
            let anchorRange=resolve(comment.anchor,in:text,contentRange:range,excluding:recordRanges)
            var hydrated=comment
            if comment.anchor.startExact != nil,let anchorRange {
                hydrated.anchor.exact=text.substring(with:anchorRange)
                hydrated.anchor.position=anchorRange.location
            } else if let anchorRange,!comment.anchor.exact.isEmpty {
                let canonical=anchor(in:source,selection:anchorRange)
                hydrated.anchor.startExact=canonical.startExact
                hydrated.anchor.endExact=canonical.endExact
            }
            return ResolvedMarkdownComment(comment:hydrated,recordRange:record,anchorRange:anchorRange)
        }
    }

    private static func parseCurrent(_ payload:String)->MarkdownComment? {
        guard payload.hasSuffix(terminalTag) else{return nil}
        let fields=payload.dropLast(terminalTag.count)
        guard let delimiter=fields.range(of:fieldDelimiter) else{return nil}
        let body=String(fields[..<delimiter.lowerBound])
        let selector=String(fields[delimiter.upperBound...])
        return parseInline(selector+" | "+body)
    }

    private static func parseInline(_ payload:String)->MarkdownComment? {
        var input=Substring(unescape(payload)).drop(while:{$0.isWhitespace})
        func takeQuoted(_ input:inout Substring)->String? {
            guard input.first == "\"" else{return nil}
            var index=input.index(after:input.startIndex),escaped=false
            while index<input.endIndex {
                let character=input[index]
                if character == "\"" && !escaped {
                    let end=input.index(after:index),encoded=String(input[..<end])
                    input=input[end...]
                    return try? JSONDecoder().decode(String.self,from:Data(encoded.utf8))
                }
                if character == "\\" {escaped.toggle()} else {escaped=false}
                index=input.index(after:index)
            }
            return nil
        }
        guard let exact=takeQuoted(&input) else{return nil}
        var compactEnd:String?
        if input.hasPrefix(" ... ") {input=input.dropFirst(5);compactEnd=takeQuoted(&input)}
        var rendered:String?
        if input.hasPrefix(" => ") {input=input.dropFirst(4);rendered=takeQuoted(&input)}
        guard input.hasPrefix(" | ") else{return nil}
        let body=String(input.dropFirst(3)).trimmingCharacters(in:.whitespacesAndNewlines)
        let anchor=MarkdownCommentAnchor(exact:compactEnd == nil ? exact:"",position:nil,
            renderedExact:rendered,startExact:compactEnd == nil ? nil:exact,endExact:compactEnd)
        return MarkdownComment(status:.open,anchor:anchor,author:"",created:"",body:body)
    }

    private static func unescape(_ payload:String)->String {
        let escaped=payload.replacingOccurrences(of:"\r\n",with:"\n")
        var normalized="",index=escaped.startIndex
        while index<escaped.endIndex {
            let next=escaped.index(after:index)
            if escaped[index]=="\\",next<escaped.endIndex,escaped[next]=="\\" {
                normalized.append("\\");index=escaped.index(after:next)
            } else if escaped[index]=="\\",next<escaped.endIndex,escaped[next]=="|" {
                normalized.append("|");index=escaped.index(after:next)
            } else if escaped[index]=="-",next<escaped.endIndex,escaped[next]=="\\" {
                let last=escaped.index(after:next)
                if last<escaped.endIndex,escaped[last]=="-" {
                    normalized.append("--");index=escaped.index(after:last)
                } else {normalized.append(escaped[index]);index=next}
            } else {normalized.append(escaped[index]);index=next}
        }
        return normalized
    }

    public static func updateAnchor(of comment:MarkdownComment,to range:NSRange,in source:String,
                                    selectorContext:NSRange?=nil)->MarkdownComment {
        // An empty quote is a block comment: its live range is the adjacent
        // paragraph, not text that should become a selector after the first
        // edit inside that paragraph.
        guard !comment.anchor.exact.isEmpty || comment.anchor.startExact != nil else{return comment}
        var result=comment,newAnchor=anchor(in:source,selection:range,
            selectorContext:selectorContext)
        // Rendered quote selectors describe the old spelling and cannot be
        // retained after the selected source itself changes.
        if newAnchor.exact == comment.anchor.exact {
            newAnchor.renderedExact=comment.anchor.renderedExact
            newAnchor.renderedPrefix=comment.anchor.renderedPrefix
            newAnchor.renderedSuffix=comment.anchor.renderedSuffix
        }
        result.anchor=newAnchor;return result
    }

    public static func editTouchesAnchor(_ edit:SourceEdit,anchor:NSRange)->Bool {
        edit.range.length==0 ? NSLocationInRange(edit.range.location,anchor)
            : NSIntersectionRange(edit.range,anchor).length>0
    }

    /// Transforms an anchor through a source edit. Insertions use leading
    /// affinity: text inserted at the anchor start joins it, while text
    /// inserted at its end remains outside it.
    public static func transformedAnchorRange(_ anchor:NSRange,through edit:SourceEdit)->NSRange {
        let delta=edit.insertedLength-edit.range.length
        if anchor.length==0 {
            return edit.range.location<=anchor.location
                ? NSRange(location:max(0,anchor.location+delta),length:0):anchor
        }
        if edit.range.length==0 {
            if edit.range.location<anchor.location {
                return NSRange(location:anchor.location+delta,length:anchor.length)
            }
            if edit.range.location<NSMaxRange(anchor) {
                return NSRange(location:anchor.location,length:anchor.length+delta)
            }
            return anchor
        }
        let editEnd=NSMaxRange(edit.range),anchorEnd=NSMaxRange(anchor)
        if editEnd<=anchor.location {
            return NSRange(location:anchor.location+delta,length:anchor.length)
        }
        if edit.range.location>=anchorEnd {return anchor}
        let start=anchor.location<edit.range.location ? anchor.location:edit.range.location
        let end=anchorEnd>editEnd ? anchorEnd+delta:edit.range.location+edit.insertedLength
        return NSRange(location:max(0,start),length:max(0,end-start))
    }

    public static func updateRenderedAnchor(of comment:MarkdownComment,to range:NSRange,
                                            in source:String,entry:RenderedEntry)->MarkdownComment {
        guard !comment.anchor.exact.isEmpty,range.length>0,
              NSIntersectionRange(range,entry.fragment.range).length == range.length,
              let html=entry.fragment.html else{return comment}
        var result=comment
        result.anchor.renderedExact=nil
        result.anchor.renderedPrefix=nil
        result.anchor.renderedSuffix=nil
        if MarkdownCommentHTML.canHighlight(result.anchor,in:html) {return result}
        guard let rendered=MarkdownCommentHTML.renderedAnchor(in:source,selection:range,entry:entry)
            else{return comment}
        result.anchor.renderedExact=rendered.exact
        result.anchor.renderedPrefix=rendered.prefix
        result.anchor.renderedSuffix=rendered.suffix
        return result
    }

    private static func resolve(_ anchor:MarkdownCommentAnchor,in text:NSString,contentRange:NSRange,
                                excluding records:[NSRange])->NSRange? {
        if let start=anchor.startExact,let end=anchor.endExact {
            let matches=endpointPairs(start:start,end:end,in:text,range:contentRange)
                .filter {candidate in
                    !records.contains(where:{NSIntersectionRange($0,candidate).length>0})
                }
            if let match=matches.last {return match}
            return adjacentParagraph(before:NSMaxRange(contentRange),in:text,excluding:records)
        }
        if anchor.exact.isEmpty {
            return adjacentParagraph(before:NSMaxRange(contentRange),in:text,excluding:records)
        }
        var matches=[NSRange](),cursor=contentRange.location
        while cursor<NSMaxRange(contentRange) {
            let candidate=text.range(of:anchor.exact,options:.literal,
                range:NSRange(location:cursor,length:NSMaxRange(contentRange)-cursor))
            guard candidate.location != NSNotFound else{break}
            if !records.contains(where:{NSIntersectionRange($0,candidate).length>0}) {matches.append(candidate)}
            cursor=max(NSMaxRange(candidate),candidate.location+1)
        }
        return matches.last ?? adjacentParagraph(before:NSMaxRange(contentRange),in:text,excluding:records)
    }

    private static func adjacentParagraph(before location:Int,in text:NSString,
                                          excluding records:[NSRange])->NSRange? {
        var cursor=min(location,text.length)
        while cursor>0 {
            let index=cursor-1
            if let record=records.first(where:{NSLocationInRange(index,$0)}) {
                cursor=record.location;continue
            }
            let scalar=text.character(at:index)
            if let value=UnicodeScalar(scalar),CharacterSet.whitespacesAndNewlines.contains(value) {
                cursor -= 1;continue
            }
            let paragraph=text.paragraphRange(for:NSRange(location:index,length:1))
            var end=NSMaxRange(paragraph)
            while end>paragraph.location {
                let value=text.character(at:end-1)
                guard let scalar=UnicodeScalar(value),CharacterSet.newlines.contains(scalar) else{break}
                end -= 1
            }
            return NSRange(location:paragraph.location,length:max(0,end-paragraph.location))
        }
        return nil
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
                if !exact.isEmpty {
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
