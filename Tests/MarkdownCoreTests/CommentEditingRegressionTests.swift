import Foundation
import MarkdownCore
import Testing

@Test func commentAnchorInsertionAffinityIsStableAtEveryBoundary() {
    let anchor=NSRange(location:10,length:5)
    let cases:[(SourceEdit,NSRange,Bool)]=[
        (.init(range:NSRange(location:9,length:0),insertedLength:2),NSRange(location:12,length:5),false),
        (.init(range:NSRange(location:10,length:0),insertedLength:2),NSRange(location:10,length:7),true),
        (.init(range:NSRange(location:12,length:0),insertedLength:2),NSRange(location:10,length:7),true),
        (.init(range:NSRange(location:14,length:0),insertedLength:2),NSRange(location:10,length:7),true),
        (.init(range:NSRange(location:15,length:0),insertedLength:2),anchor,false),
        (.init(range:NSRange(location:16,length:0),insertedLength:2),anchor,false),
    ]
    for (edit,expected,touches) in cases {
        #expect(MarkdownComments.transformedAnchorRange(anchor,through:edit)==expected)
        #expect(MarkdownComments.editTouchesAnchor(edit,anchor:anchor)==touches)
    }
}

@Test func commentAnchorReplacementHandlesEveryOverlapShape() {
    let anchor=NSRange(location:10,length:10)
    let cases:[(SourceEdit,NSRange,Bool)]=[
        (.init(range:NSRange(location:5,length:3),insertedLength:1),NSRange(location:8,length:10),false),
        (.init(range:NSRange(location:7,length:3),insertedLength:1),NSRange(location:8,length:10),false),
        (.init(range:NSRange(location:10,length:2),insertedLength:0),NSRange(location:10,length:8),true),
        (.init(range:NSRange(location:8,length:4),insertedLength:1),NSRange(location:8,length:9),true),
        (.init(range:NSRange(location:18,length:4),insertedLength:2),NSRange(location:10,length:10),true),
        (.init(range:NSRange(location:8,length:14),insertedLength:3),NSRange(location:8,length:3),true),
        (.init(range:NSRange(location:10,length:10),insertedLength:0),NSRange(location:10,length:0),true),
        (.init(range:NSRange(location:20,length:3),insertedLength:1),anchor,false),
    ]
    for (edit,expected,touches) in cases {
        #expect(MarkdownComments.transformedAnchorRange(anchor,through:edit)==expected)
        #expect(MarkdownComments.editTouchesAnchor(edit,anchor:anchor)==touches)
    }
}

@Test func commentAnchorTransformStaysBoundedAcrossExhaustiveSmallEdits() {
    for anchorStart in 0...8 {
        for anchorLength in 1...4 where anchorStart+anchorLength<=12 {
            let anchor=NSRange(location:anchorStart,length:anchorLength)
            for editStart in 0...12 {
                for replaced in 0...(12-editStart) {
                    for inserted in 0...3 {
                        let edit=SourceEdit(range:NSRange(location:editStart,length:replaced),
                            insertedLength:inserted)
                        let result=MarkdownComments.transformedAnchorRange(anchor,through:edit)
                        #expect(result.location>=0)
                        #expect(result.length>=0)
                        #expect(NSMaxRange(result)<=12-replaced+inserted)
                        if editStart==NSMaxRange(anchor),replaced==0 {
                            #expect(result==anchor)
                            #expect(!MarkdownComments.editTouchesAnchor(edit,anchor:anchor))
                        }
                    }
                }
            }
        }
    }
}

@Test func endInsertionDoesNotEnterTheSerializedSelector() {
    let original="Before selected words after."
    let anchor=(original as NSString).range(of:"selected words")
    let edit=SourceEdit(range:NSRange(location:NSMaxRange(anchor),length:0),insertedLength:1)
    let edited=(original as NSString).replacingCharacters(in:edit.range,with:" ")
    let transformed=MarkdownComments.transformedAnchorRange(anchor,through:edit)
    let comment=MarkdownComment(anchor:MarkdownComments.anchor(in:original,selection:anchor),
        author:"",created:"",body:"Boundary")
    let updated=MarkdownComments.editTouchesAnchor(edit,anchor:anchor)
        ? MarkdownComments.updateAnchor(of:comment,to:transformed,in:edited):comment
    let serialized=MarkdownComments.serialize(updated)
    #expect(transformed==anchor)
    #expect(updated.anchor.exact=="selected words")
    #expect(serialized=="<!-- Boundary | \"selected words\" | markato-comment:v3 -->")
}

@Test func startInsertionEntersSelectorIncludingUnicodeUTF16() {
    let original="Before selected 😀 words after."
    let anchor=(original as NSString).range(of:"selected 😀 words")
    let insertion="🟡 "
    let edit=SourceEdit(range:NSRange(location:anchor.location,length:0),
        insertedLength:insertion.utf16.count)
    let edited=(original as NSString).replacingCharacters(in:edit.range,with:insertion)
    let transformed=MarkdownComments.transformedAnchorRange(anchor,through:edit)
    let comment=MarkdownComment(anchor:MarkdownComments.anchor(in:original,selection:anchor),
        author:"",created:"",body:"Unicode")
    let updated=MarkdownComments.updateAnchor(of:comment,to:transformed,in:edited)
    #expect(updated.anchor.exact=="🟡 selected 😀 words")
    #expect(transformed.length==anchor.length+insertion.utf16.count)
}

@Test func renderedSelectorSurvivesNestedMarkupLinksEntitiesAndUnicode() throws {
    let source="Review **bold & [linked 😀](https://example.test?q=1)** text."
    let range=(source as NSString).range(of:"**bold & [linked 😀](https://example.test?q=1)**")
    let raw=(source as NSString).substring(with:range)
    let comment=MarkdownComment(anchor:.init(exact:raw,position:range.location),
        author:"",created:"",body:"Nested")
    let entry=RenderedEntry(id:"block",fragment:PreviewFragment(kind:.paragraph,from:0,
        to:source.utf16.count,
        html:"<p>Review <strong>bold &amp; <a href=\"https://example.test?q=1\">linked 😀</a></strong> text.</p>",
        id:"block"))
    let updated=MarkdownComments.updateRenderedAnchor(of:comment,to:range,in:source,entry:entry)
    #expect(updated.anchor.renderedExact=="bold & linked 😀")
    let resolved=ResolvedMarkdownComment(comment:updated,
        recordRange:NSRange(location:source.utf16.count,length:0),anchorRange:range)
    let html=try #require(MarkdownCommentHTML.decorate([entry],with:[resolved]).first?.fragment.html)
    #expect(!html.contains("data-markato-comment-block"))
    #expect(html.components(separatedBy:"markato-comment-highlight").count-1>=2)
}

@Test func renderedSelectorIsRemovedAgainWhenMarkupBecomesPlainText() {
    let source="Before plain text after."
    let range=(source as NSString).range(of:"plain text")
    let comment=MarkdownComment(anchor:.init(exact:"plain text",position:range.location,
        renderedExact:"stale rendered text"),author:"",created:"",body:"Plain")
    let entry=RenderedEntry(id:"block",fragment:PreviewFragment(kind:.paragraph,from:0,
        to:source.utf16.count,html:"<p>Before plain text after.</p>",id:"block"))
    let updated=MarkdownComments.updateRenderedAnchor(of:comment,to:range,in:source,entry:entry)
    #expect(updated.anchor.renderedExact==nil)
    #expect(!MarkdownComments.serialize(updated).contains(" => "))
}

@Test func renderedSelectorDoesNotCrossAPreparedBlockBoundary() {
    let source="First paragraph.\n\nSecond paragraph."
    let range=NSRange(location:6,length:20)
    let comment=MarkdownComment(anchor:.init(exact:(source as NSString).substring(with:range)),
        author:"",created:"",body:"Crossing")
    let first=RenderedEntry(id:"first",fragment:PreviewFragment(kind:.paragraph,from:0,to:18,
        html:"<p>First paragraph.</p>",id:"first"))
    #expect(MarkdownComments.updateRenderedAnchor(of:comment,to:range,in:source,entry:first)==comment)
}
