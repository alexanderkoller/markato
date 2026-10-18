import Foundation
import MarkdownCore
import Testing

@Test func commentRecordsRoundTripArbitraryMarkdownAndSafeHTMLComments() throws {
    let body="""
    This can be arbitrarily long Markdown.

    - It contains lists.
    - It contains a dangerous HTML-comment sequence: a--b and -->.
    - It preserves literal backslashes such as -\\- and -\\u002d.
    - It can mention a separator: x | markato-comment:v3 y.

    ```swift
    print("still structured")
    ```
    """
    let source="Before selected words after."
    let selection=(source as NSString).range(of:"selected words")
    let comment=MarkdownComments.comment(in:source,selection:selection,body:body,author:"Reviewer",
        created:"2026-10-13T10:20:00Z")
    let encoded=MarkdownComments.serialize(comment)
    let payload=encoded.dropFirst(4).dropLast(3)
    #expect(!payload.contains("--"))
    #expect(encoded.contains(" | \"selected words\" | markato-comment:v3"))
    #expect(!encoded.contains("2026-10-13"))
    #expect(!encoded.contains(comment.id))
    #expect(!encoded.contains("Reviewer"))
    let document=source+"\n\n"+encoded+"\n"
    let record=try #require(MarkdownComments.records(in:document).first)
    #expect(record.comment.anchor.exact==comment.anchor.exact)
    #expect(record.comment.author.isEmpty)
    #expect(record.comment.created.isEmpty)
    #expect(record.comment.status == .open)
    #expect(record.anchorRange==selection)
    #expect(record.comment.body==body)
}

@Test func bodyLastV3SyntaxIsNotAccepted() {
    let old="<!-- markato-comment:v3 \"selected words\" | Old arrangement -->"
    #expect(MarkdownComments.records(in:"selected words\n\n"+old).isEmpty)
}

@Test func singleLineCommentUsesOnePhysicalLine() throws {
    let source="A concise sentence."
    let selection=(source as NSString).range(of:"concise")
    let comment=MarkdownComments.comment(in:source,selection:selection,
        body:"Prefer a stronger word.",author:"Reviewer")
    let encoded=MarkdownComments.serialize(comment)
    #expect(!encoded.contains("\n"))
    #expect(encoded=="<!-- Prefer a stronger word. | \"concise\" | markato-comment:v3 -->")
    let parsed=try #require(MarkdownComments.records(in:source+"\n\n"+encoded).first)
    #expect(parsed.comment.body=="Prefer a stronger word.")
    #expect(parsed.comment.author.isEmpty)
}

@Test func longMultiblockAnchorUsesCompactEndpointsAndKeepsCommentProminent() throws {
    let selected="""
    This is passage 2 of 80. A little emphasis makes the source styling easy to recognize.

    The path continues through a second paragraph with enough text to make repeating the whole selection noisy.

    The final sentence gives the live preview something small to update.
    """
    let source="Before.\n\n\(selected)\n\nAfter."
    let selection=(source as NSString).range(of:selected)
    let comment=MarkdownComments.comment(in:source,selection:selection,
        body:"Focus on this comment.",author:"")
    let encoded=MarkdownComments.serialize(comment)
    #expect(encoded.contains(" ... \""))
    #expect(!encoded.contains(" => "))
    #expect(!encoded.contains("second paragraph with enough text"))
    #expect(encoded.hasPrefix("<!-- Focus on this comment. | \""))
    #expect(encoded.hasSuffix(" | markato-comment:v3 -->"))
    #expect(encoded.utf16.count<150)

    let insertion=MarkdownComments.insertion(for:comment,in:source,at:NSMaxRange(selection))
    let document=(source as NSString).replacingCharacters(
        in:NSRange(location:NSMaxRange(selection),length:0),with:insertion)
    let parsed=try #require(MarkdownComments.records(in:document).first)
    #expect(parsed.anchorRange==selection)
    #expect(parsed.comment.anchor.exact==selected)
    #expect(parsed.comment.anchor.startExact==comment.anchor.startExact)
    #expect(parsed.comment.anchor.endExact==comment.anchor.endExact)
    #expect(parsed.comment.body=="Focus on this comment.")
}

@Test func compactEndpointsFollowEditsAtBothEnds() throws {
    let original="Opening words identify a long selection. "+String(repeating:"middle filler ",count:12)
        + "Closing words identify its end."
    let oldRange=NSRange(location:0,length:original.utf16.count)
    let comment=MarkdownComment(anchor:MarkdownComments.anchor(in:original,selection:oldRange),
        author:"",created:"",body:"Review")
    let edited="New opening identifies the changed selection. "+String(repeating:"middle filler ",count:12)
        + "A new closing identifies its end."
    let newRange=NSRange(location:0,length:edited.utf16.count)
    let updated=MarkdownComments.updateAnchor(of:comment,to:newRange,in:edited)
    let encoded=MarkdownComments.serialize(updated)
    #expect(updated.anchor.startExact?.hasPrefix("New opening")==true)
    #expect(updated.anchor.endExact?.hasSuffix("its end.")==true)
    #expect(encoded.contains("middle filler")==false)
    let document=edited+MarkdownComments.insertion(for:updated,in:edited)
    #expect(try #require(MarkdownComments.records(in:document).first).anchorRange==newRange)
}

@Test func ambiguousRepeatedEndpointsKeepTheExactSelector() {
    let exact=String(repeating:"same repeated endpoint ",count:10)
    let comment=MarkdownComment(anchor:.init(exact:exact),author:"",created:"",body:"Review")
    let encoded=MarkdownComments.serialize(comment)
    #expect(!encoded.contains(" ... "))
    #expect(encoded.contains(exact))
}

@Test func quoteContextDisambiguatesRepeatedSelections() throws {
    let source="first repeated words here; second repeated words there"
    let selection=(source as NSString).range(of:"repeated words",options:.backwards)
    let comment=MarkdownComments.comment(in:source,selection:selection,body:"The second one",author:"A")
    let document=source+MarkdownComments.insertion(for:comment,in:source)
    let record=try #require(MarkdownComments.records(in:document).first)
    #expect(record.anchorRange==selection)
}

@Test func pointCommentsBecomeAdjacentBlockComments() throws {
    let source="A short document"
    let comment=MarkdownComments.comment(in:source,selection:NSRange(location:7,length:0),body:"Point",author:"A")
    let record=try #require(MarkdownComments.records(in:source+MarkdownComments.insertion(for:comment,in:source)).first)
    #expect(record.anchorRange==NSRange(location:0,length:source.utf16.count))
}

@Test func editingInsideBlockCommentDoesNotCreateAParagraphSelector() {
    let source="A short edited document"
    let comment=MarkdownComment(anchor:.init(exact:"",position:7),author:"",created:"",body:"Point")
    let updated=MarkdownComments.updateAnchor(of:comment,
        to:NSRange(location:0,length:source.utf16.count),in:source)
    #expect(updated.anchor.exact.isEmpty)
    #expect(MarkdownComments.serialize(updated)=="<!-- Point | \"\" | markato-comment:v3 -->")
}

@Test func inlineRecordLivesBesideItsBlockAndUsesTheNearestRepeatedQuote() throws {
    let source="First repeated words.\n\nSecond repeated words.\n\nFollowing paragraph.\n"
    let selection=(source as NSString).range(of:"repeated words",options:.backwards)
    let blockEnd=(source as NSString).range(of:"Second repeated words.\n").upperBound
    let comment=MarkdownComments.comment(in:source,selection:selection,body:"The nearby one",author:"A")
    let insertion=MarkdownComments.insertion(for:comment,in:source,at:blockEnd)
    let document=(source as NSString).replacingCharacters(in:NSRange(location:blockEnd,length:0),with:insertion)
    let record=try #require(MarkdownComments.records(in:document).first)
    #expect(record.recordRange.location>selection.location)
    #expect(record.recordRange.location<(document as NSString).range(of:"Following paragraph.").location)
    #expect(record.anchorRange==selection)
}

@Test func editedAnchorSerializesItsCurrentText() {
    let source="Before keeps unaffected blocks after."
    let original=MarkdownComment(anchor:.init(exact:"retains unchanged blocks",position:7),
        author:"A",created:"old",body:"Explain this")
    let range=(source as NSString).range(of:"keeps unaffected blocks")
    let updated=MarkdownComments.updateAnchor(of:original,to:range,in:source)
    let encoded=MarkdownComments.serialize(updated)
    #expect(updated.anchor.exact=="keeps unaffected blocks")
    #expect(encoded.contains("\"keeps unaffected blocks\" |"))
}

@Test func editedMarkdownAnchorRefreshesItsRenderedSelector() throws {
    let source="The path follows a **stream** through open woodland."
    let range=(source as NSString).range(of:"follows a **stream** through open woodland")
    let comment=MarkdownComment(anchor:.init(exact:(source as NSString).substring(with:range),
        position:range.location),author:"",created:"",body:"Keep this precise")
    let fragment=PreviewFragment(kind:.paragraph,from:0,to:source.utf16.count,
        html:"<p>The path follows a <strong>stream</strong> through open woodland.</p>",id:"block")
    let entry=RenderedEntry(id:"block",fragment:fragment)
    let updated=MarkdownComments.updateRenderedAnchor(of:comment,to:range,in:source,entry:entry)
    #expect(updated.anchor.renderedExact=="follows a stream through open woodland")
    #expect(MarkdownComments.serialize(updated).contains(
        "\"follows a **stream** through open woodland\" => \"follows a stream through open woodland\""))
    let resolved=ResolvedMarkdownComment(comment:updated,
        recordRange:NSRange(location:source.utf16.count,length:0),anchorRange:range)
    let html=try #require(MarkdownCommentHTML.decorate([entry],with:[resolved]).first?.fragment.html)
    #expect(html.contains("data-markato-comment-block")==false)
    #expect(html.contains("markato-comment-highlight"))
}

@Test func externallyStaleQuoteFallsBackToAdjacentParagraph() throws {
    let source="Keeps unaffected blocks now.\n\nFollowing paragraph.\n"
    let stale=MarkdownComment(anchor:.init(exact:"retains unchanged blocks"),author:"A",created:"",body:"Explain")
    let end=(source as NSString).range(of:"Keeps unaffected blocks now.\n").upperBound
    let insertion=MarkdownComments.insertion(for:stale,in:source,at:end)
    let document=(source as NSString).replacingCharacters(in:NSRange(location:end,length:0),with:insertion)
    let record=try #require(MarkdownComments.records(in:document).first)
    #expect(record.anchorRange==(document as NSString).range(of:"Keeps unaffected blocks now."))
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

@Test func selectionAcrossRenderedBlocksNormalizesWithoutPersistedRenderingMode() throws {
    let source="First **bold** paragraph.\n\nSecond paragraph.\n"
    let selection=(source as NSString).range(of:"bold** paragraph.\n\nSecond")
    let first=RenderedEntry(id:"first",fragment:PreviewFragment(kind:.paragraph,from:0,to:25,
        html:"<p>First <strong>bold</strong> paragraph.</p>\n",id:"first"))
    let second=RenderedEntry(id:"second",fragment:PreviewFragment(kind:.paragraph,from:25,to:(source as NSString).length,
        html:"<p>Second paragraph.</p>\n",id:"second"))
    let comment=MarkdownComments.comment(in:source,selection:selection,body:"Crosses syntax",author:"A",
        renderedEntries:[first,second])
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
