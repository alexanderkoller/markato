import Foundation

public enum MarkdownEditingCommand:Equatable,Sendable {
    case bold,italic,strikethrough,inlineCode
    case link(destination:String?)
    case heading(Int),paragraph
    case bulletedList,numberedList,blockquote
    case image(source:String)
    case table,codeBlock,horizontalRule
}

public struct MarkdownTextEdit:Equatable,Sendable {
    public let range:NSRange
    public let replacement:String
    public let selection:NSRange
    public let undoName:String

    public init(range:NSRange,replacement:String,selection:NSRange,undoName:String) {
        self.range=range;self.replacement=replacement;self.selection=selection;self.undoName=undoName
    }
}

/// Pure Markdown source transformations. AppKit supplies the selection and
/// applies the returned edit as one document/undo transaction.
public enum MarkdownEditing {
    public static func edit(_ command:MarkdownEditingCommand,in source:NSString,
                            selection:NSRange,newline:String="\n")->MarkdownTextEdit? {
        guard selection.location != NSNotFound,selection.location>=0,
              NSMaxRange(selection)<=source.length else{return nil}
        switch command {
        case .bold:return wrap("**",selection:selection,in:source,name:"Bold")
        case .italic:return wrap("*",selection:selection,in:source,name:"Italic")
        case .strikethrough:return wrap("~~",selection:selection,in:source,name:"Strikethrough")
        case .inlineCode:
            let selected=source.substring(with:selection)
            let fence=String(repeating:"`",count:max(1,longestRun(of:"`",in:selected)+1))
            return wrap(fence,selection:selection,in:source,name:"Inline Code")
        case .link(let destination):
            return link(destination:destination,selection:selection,in:source)
        case .heading(let level):
            guard (1...6).contains(level) else{return nil}
            return transformLines(selection:selection,in:source,name:"Heading \(level)") {line in
                let plain=removingHeading(from:line)
                return String(repeating:"#",count:level)+" "+plain
            }
        case .paragraph:
            return transformLines(selection:selection,in:source,name:"Paragraph",transform:removingHeading)
        case .bulletedList:
            return toggleLines(selection:selection,in:source,name:"Bulleted List",
                pattern:#"^[-+*][\t ]+"#,prefix:"- ")
        case .numberedList:
            return toggleLines(selection:selection,in:source,name:"Numbered List",
                pattern:#"^[0-9]+[.)][\t ]+"#,prefix:"1. ")
        case .blockquote:
            return toggleLines(selection:selection,in:source,name:"Blockquote",
                pattern:#"^>[\t ]?"#,prefix:"> ")
        case .image(let imageSource):
            let alt=source.substring(with:selection)
            let destination=markdownDestination(imageSource)
            let replacement="![\(alt)](\(destination))"
            return MarkdownTextEdit(range:selection,replacement:replacement,
                selection:NSRange(location:selection.location+2,length:(alt as NSString).length),undoName:"Insert Image")
        case .table:
            let body="| Column 1 | Column 2 | Column 3 |\(newline)| --- | --- | --- |\(newline)|  |  |  |\(newline)|  |  |  |"
            return standalone(body,selection:selection,in:source,newline:newline,
                selectedOffset:2,selectedLength:8,name:"Insert Table")
        case .codeBlock:
            let selected=source.substring(with:selection)
            let fence=String(repeating:"`",count:max(3,longestRun(of:"`",in:selected)+1))
            let body="\(fence)\(newline)\(selected)\(selected.isEmpty ? "" : newline)\(fence)"
            return standalone(body,selection:selection,in:source,newline:newline,
                selectedOffset:(fence as NSString).length+(newline as NSString).length,
                selectedLength:(selected as NSString).length,name:"Code Block")
        case .horizontalRule:
            return standalone("---",selection:selection,in:source,newline:newline,
                selectedOffset:3,selectedLength:0,name:"Insert Horizontal Rule")
        }
    }

    private static func wrap(_ mark:String,selection:NSRange,in source:NSString,name:String)->MarkdownTextEdit {
        let width=(mark as NSString).length
        let selected=source.substring(with:selection)
        if selection.length>=width*2,selected.hasPrefix(mark),selected.hasSuffix(mark) {
            let inner=(selected as NSString).substring(with:NSRange(location:width,length:selection.length-width*2))
            return MarkdownTextEdit(range:selection,replacement:inner,
                selection:NSRange(location:selection.location,length:(inner as NSString).length),undoName:name)
        }
        if selection.location>=width,NSMaxRange(selection)+width<=source.length,
           source.substring(with:NSRange(location:selection.location-width,length:width))==mark,
           source.substring(with:NSRange(location:NSMaxRange(selection),length:width))==mark {
            return MarkdownTextEdit(range:NSRange(location:selection.location-width,length:selection.length+width*2),
                replacement:selected,selection:NSRange(location:selection.location-width,length:selection.length),undoName:name)
        }
        return MarkdownTextEdit(range:selection,replacement:mark+selected+mark,
            selection:NSRange(location:selection.location+width,length:selection.length),undoName:name)
    }

    private static func link(destination:String?,selection:NSRange,in source:NSString)->MarkdownTextEdit {
        let label=source.substring(with:selection)
        let target=destination.map(markdownDestination) ?? ""
        let replacement="[\(label)](\(target))"
        let labelLength=(label as NSString).length,targetLength=(target as NSString).length
        let nextSelection:NSRange
        if selection.length>0 {
            nextSelection=NSRange(location:selection.location+labelLength+3,length:targetLength)
        } else {
            nextSelection=NSRange(location:selection.location+1,length:0)
        }
        return MarkdownTextEdit(range:selection,replacement:replacement,selection:nextSelection,undoName:"Insert Link")
    }

    private static func markdownDestination(_ value:String)->String {
        value.contains(where:{$0.isWhitespace || "()<>".contains($0)}) ? "<\(value)>" : value
    }

    private static func standalone(_ body:String,selection:NSRange,in source:NSString,newline:String,
                                   selectedOffset:Int,selectedLength:Int,name:String)->MarkdownTextEdit {
        let before:String
        if selection.location==0 {before=""}
        else {
            let amount=min(selection.location,(newline as NSString).length*2)
            let prefix=source.substring(with:NSRange(location:selection.location-amount,length:amount))
            if prefix.hasSuffix(newline+newline) {before=""}
            else if prefix.hasSuffix(newline) {before=newline}
            else {before=newline+newline}
        }
        let after:String
        if NSMaxRange(selection)==source.length {after=""}
        else {
            let amount=min(source.length-NSMaxRange(selection),(newline as NSString).length*2)
            let suffix=source.substring(with:NSRange(location:NSMaxRange(selection),length:amount))
            if suffix.hasPrefix(newline+newline) {after=""}
            else if suffix.hasPrefix(newline) {after=newline}
            else {after=newline+newline}
        }
        return MarkdownTextEdit(range:selection,replacement:before+body+after,
            selection:NSRange(location:selection.location+(before as NSString).length+selectedOffset,
                              length:selectedLength),undoName:name)
    }

    private struct Line {let content:String,ending:String}
    private static func lines(in text:String)->[Line] {
        let value=text as NSString
        guard value.length>0 else{return [Line(content:"",ending:"")]}
        var result=[Line](),position=0
        while position<value.length {
            var start=0,end=0,contentsEnd=0
            value.getLineStart(&start,end:&end,contentsEnd:&contentsEnd,
                for:NSRange(location:position,length:0))
            result.append(Line(content:value.substring(with:NSRange(location:start,length:contentsEnd-start)),
                               ending:value.substring(with:NSRange(location:contentsEnd,length:end-contentsEnd))))
            position=max(end,position+1)
        }
        return result
    }

    private static func selectedLineRange(_ selection:NSRange,in source:NSString)->NSRange {
        var range=selection
        if range.length>0,NSMaxRange(range)>0 {
            let last=source.character(at:NSMaxRange(range)-1)
            if last==10 || last==13 {range.length-=1}
        }
        return source.lineRange(for:range)
    }

    private static func transformLines(selection:NSRange,in source:NSString,name:String,
                                       transform:(String)->String)->MarkdownTextEdit {
        let range=selectedLineRange(selection,in:source)
        let original=source.substring(with:range),parts=lines(in:original)
        let replacement=parts.map{transform($0.content)+$0.ending}.joined()
        return lineEdit(range:range,replacement:replacement,originalSelection:selection,name:name)
    }

    private static func toggleLines(selection:NSRange,in source:NSString,name:String,
                                    pattern:String,prefix:String)->MarkdownTextEdit {
        let range=selectedLineRange(selection,in:source)
        let original=source.substring(with:range),parts=lines(in:original)
        let expression=try! NSRegularExpression(pattern:pattern)
        let nonempty=parts.filter{!$0.content.isEmpty}
        let removing = !nonempty.isEmpty && nonempty.allSatisfy {line in
            expression.firstMatch(in:line.content,range:NSRange(location:0,length:(line.content as NSString).length)) != nil
        }
        let replacement=parts.map {line in
            guard !line.content.isEmpty else{return line.ending}
            if removing,let match=expression.firstMatch(in:line.content,
                range:NSRange(location:0,length:(line.content as NSString).length)) {
                let value=line.content as NSString
                return value.replacingCharacters(in:match.range,with:"")+line.ending
            }
            return prefix+line.content+line.ending
        }.joined()
        return lineEdit(range:range,replacement:replacement,originalSelection:selection,name:name)
    }

    private static func lineEdit(range:NSRange,replacement:String,originalSelection:NSRange,name:String)->MarkdownTextEdit {
        let replacementLength=(replacement as NSString).length
        let selection:NSRange
        if originalSelection.length==0 {
            let relative=originalSelection.location-range.location
            let delta=replacementLength-range.length
            selection=NSRange(location:range.location+max(0,min(replacementLength,relative+delta)),length:0)
        } else {
            var length=replacementLength
            if replacement.hasSuffix("\r\n") {length-=2}
            else if replacement.hasSuffix("\n") || replacement.hasSuffix("\r") {length-=1}
            selection=NSRange(location:range.location,length:max(0,length))
        }
        return MarkdownTextEdit(range:range,replacement:replacement,selection:selection,undoName:name)
    }

    private static func removingHeading(from line:String)->String {
        line.replacingOccurrences(of:#"^#{1,6}[\t ]+"#,with:"",options:.regularExpression)
    }

    private static func longestRun(of character:Character,in text:String)->Int {
        var longest=0,current=0
        for value in text {
            if value==character {current+=1;longest=max(longest,current)} else {current=0}
        }
        return longest
    }
}
