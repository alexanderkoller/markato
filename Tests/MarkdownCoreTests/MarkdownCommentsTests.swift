import Foundation
import MarkdownCore
import Testing

@Test func commentRecordsRoundTripArbitraryMarkdownAndSafeHTMLComments() throws {
    let body="""
    This can be arbitrarily long Markdown.

    - It contains lists.
    - It contains a dangerous HTML-comment sequence: a--b and -->.

    ```swift
    print("still structured")
    ```
    """
    let source="Before selected words after."
    let selection=(source as NSString).range(of:"selected words")
    let comment=MarkdownComments.comment(in:source,selection:selection,body:body,author:"Reviewer",
        created:"2026-10-13T10:20:00Z")
    let encoded=MarkdownComments.serialize(comment)
    let payload=encoded.dropFirst(MarkdownComments.marker.count).dropLast(3)
    #expect(!payload.contains("--"))
    let document=source+"\n\n"+encoded+"\n"
    let record=try #require(MarkdownComments.records(in:document).first)
    #expect(record.comment==comment)
    #expect(record.anchorRange==selection)
    #expect(record.comment.body==body)
}

@Test func quoteContextDisambiguatesRepeatedSelections() throws {
    let source="first repeated words here; second repeated words there"
    let selection=(source as NSString).range(of:"repeated words",options:.backwards)
    let comment=MarkdownComments.comment(in:source,selection:selection,body:"The second one",author:"A")
    let document=source+MarkdownComments.insertion(for:comment,in:source)
    let record=try #require(MarkdownComments.records(in:document).first)
    #expect(record.anchorRange==selection)
}

@Test func pointCommentsResolveWithoutSelectingText() throws {
    let source="A short document"
    let comment=MarkdownComments.comment(in:source,selection:NSRange(location:7,length:0),body:"Point",author:"A")
    let record=try #require(MarkdownComments.records(in:source+MarkdownComments.insertion(for:comment,in:source)).first)
    #expect(record.anchorRange==NSRange(location:7,length:0))
}

@Test func commentHTMLAddsHighlightAndNavigableBubble() throws {
    let value=MarkdownComment(id:"comment-1",anchor:.init(exact:"selected words",position:7),
        author:"A",created:"now",body:"Explain this")
    let comment=ResolvedMarkdownComment(comment:value,recordRange:NSRange(location:30,length:20),
        anchorRange:NSRange(location:7,length:14))
    let fragment=PreviewFragment(kind:.paragraph,from:0,to:24,html:"<p>Before selected words.</p>",id:"block")
    let decorated=MarkdownCommentHTML.decorate([RenderedEntry(id:"block",fragment:fragment)],with:[comment])
    let html=try #require(decorated.first?.fragment.html)
    #expect(html.contains("<mark class=\"markato-comment-highlight\""))
    #expect(html.contains("href=\"markato-comment:comment-1\""))
    let bubble=try #require(html.range(of:"markato-comment-bubble"))
    let paragraph=try #require(html.range(of:"<p>"))
    #expect(bubble.lowerBound<paragraph.lowerBound)
}

@Test func previewHighlightUsesQuoteContextForRepeatedText() throws {
    let anchor=MarkdownCommentAnchor(exact:"same",prefix:"then ",suffix:" target",position:15)
    let value=MarkdownComment(id:"second",anchor:anchor,author:"A",created:"now",body:"Second occurrence")
    let comment=ResolvedMarkdownComment(comment:value,recordRange:NSRange(location:40,length:10),
        anchorRange:NSRange(location:19,length:4))
    let fragment=PreviewFragment(kind:.paragraph,from:0,to:30,html:"<p>first same, then same target</p>",id:"block")
    let html=try #require(MarkdownCommentHTML.decorate([RenderedEntry(id:"block",fragment:fragment)],with:[comment]).first?.fragment.html)
    #expect(html.contains("first same, then <mark class=\"markato-comment-highlight\""))
}

@Test func selectedCommentOutlinesMatchingHighlightAndBubble() throws {
    let value=MarkdownComment(id:"chosen",anchor:.init(exact:"words",position:7),
        author:"A",created:"now",body:"Selected")
    let comment=ResolvedMarkdownComment(comment:value,recordRange:NSRange(location:40,length:10),
        anchorRange:NSRange(location:7,length:5))
    let fragment=PreviewFragment(kind:.paragraph,from:0,to:20,html:"<p>Before words after.</p>",id:"block")
    let html=try #require(MarkdownCommentHTML.decorate(
        [RenderedEntry(id:"block",fragment:fragment)],with:[comment],selectedID:"chosen").first?.fragment.html)
    #expect(html.contains("markato-comment-highlight is-selected"))
    #expect(html.contains("markato-comment-bubble is-selected"))
    #expect(html.contains("data-comment-id=\"chosen\""))
}

@Test func commentsSharingPreviewBlockHaveSeparatedBubbles() throws {
    let values=[
        MarkdownComment(id:"one",anchor:.init(exact:"",position:4),author:"A",created:"now",body:"One"),
        MarkdownComment(id:"two",anchor:.init(exact:"",position:8),author:"B",created:"now",body:"Two")
    ]
    let comments=values.map {ResolvedMarkdownComment(comment:$0,recordRange:NSRange(location:30,length:10),
        anchorRange:NSRange(location:$0.anchor.position ?? 0,length:0))}
    let fragment=PreviewFragment(kind:.paragraph,from:0,to:20,html:"<p>One line of text.</p>",id:"block")
    let html=try #require(MarkdownCommentHTML.decorate(
        [RenderedEntry(id:"block",fragment:fragment)],with:comments).first?.fragment.html)
    #expect(html.contains("style=\"top:-2.0px\""))
    #expect(html.contains("style=\"top:24.0px\""))
}

@Test func selectionAcrossRenderedBlocksNormalizesToBlockExtent() throws {
    let source="First **bold** paragraph.\n\nSecond paragraph.\n"
    let selection=(source as NSString).range(of:"bold** paragraph.\n\nSecond")
    let first=RenderedEntry(id:"first",fragment:PreviewFragment(kind:.paragraph,from:0,to:25,
        html:"<p>First <strong>bold</strong> paragraph.</p>\n",id:"first"))
    let second=RenderedEntry(id:"second",fragment:PreviewFragment(kind:.paragraph,from:25,to:(source as NSString).length,
        html:"<p>Second paragraph.</p>\n",id:"second"))
    let comment=MarkdownComments.comment(in:source,selection:selection,body:"Crosses syntax",author:"A",
        renderedEntries:[first,second])
    #expect(comment.anchor.extent == .blocks)
    #expect(comment.anchor.exact == source)
    let resolved=ResolvedMarkdownComment(comment:comment,recordRange:NSRange(location:source.utf16.count,length:10),
        anchorRange:NSRange(location:0,length:source.utf16.count))
    let html=try #require(MarkdownCommentHTML.decorate([first,second],with:[resolved],selectedID:comment.id).first?.fragment.html)
    #expect(html.contains("<p data-markato-comment-block data-markato-comment-selected>"))
}

@Test func selectionAcrossInlineSyntaxKeepsPreciseRenderedExtent() throws {
    let source="This is passage **9** of **80**. More text.\n"
    let selection=(source as NSString).range(of:"**9** of **80**")
    let entry=RenderedEntry(id:"block",fragment:PreviewFragment(kind:.paragraph,from:0,to:(source as NSString).length,
        html:"<p>This is passage <strong>9</strong> of <strong>80</strong>. More text.</p>\n",id:"block"))
    let comment=MarkdownComments.comment(in:source,selection:selection,body:"Precise",author:"A",
        renderedEntries:[entry])
    #expect(comment.anchor.extent == nil)
    #expect(comment.anchor.exact == "**9** of **80**")
    #expect(comment.anchor.renderedExact == "9 of 80")
    let resolved=ResolvedMarkdownComment(comment:comment,recordRange:NSRange(location:source.utf16.count,length:10),
        anchorRange:selection)
    let html=try #require(MarkdownCommentHTML.decorate([entry],with:[resolved],selectedID:comment.id).first?.fragment.html)
    #expect(!html.contains("data-markato-comment-block"))
    #expect(html.contains("<strong><mark class=\"markato-comment-highlight is-selected\""))
    #expect(html.components(separatedBy:"markato-comment-highlight is-selected").count-1 == 3)
}

@Test func plainTextSelectionKeepsItsPreciseExtent() {
    let source="Before ordinary words after.\n"
    let selection=(source as NSString).range(of:"ordinary words")
    let fragment=PreviewFragment(kind:.paragraph,from:0,to:(source as NSString).length,
        html:"<p>Before ordinary words after.</p>\n",id:"block")
    let comment=MarkdownComments.comment(in:source,selection:selection,body:"Precise",author:"A",
        renderedEntries:[RenderedEntry(id:"block",fragment:fragment)])
    #expect(comment.anchor.extent == nil)
    #expect(comment.anchor.exact == "ordinary words")
}

@Test func legacySyntaxCrossingCommentFallsBackToBlockHighlight() throws {
    let value=MarkdownComment(id:"legacy",anchor:.init(exact:"bold** and `code",position:9),
        author:"A",created:"now",body:"Old record")
    let comment=ResolvedMarkdownComment(comment:value,recordRange:NSRange(location:40,length:10),
        anchorRange:NSRange(location:9,length:17))
    let fragment=PreviewFragment(kind:.paragraph,from:0,to:35,
        html:"<p>Before <strong>bold</strong> and <code>code</code> after.</p>",id:"block")
    let html=try #require(MarkdownCommentHTML.decorate(
        [RenderedEntry(id:"block",fragment:fragment)],with:[comment]).first?.fragment.html)
    #expect(html.contains("<p data-markato-comment-block>"))
}
