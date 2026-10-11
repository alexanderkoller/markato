import Foundation
import Testing
@testable import MarkdownCore

private func prepare(_ text:String,_ worker:ComrakWorker = ComrakWorker(),revision:Int = 1,range:NSRange? = nil) async throws->ParseResult {
    let rope=TextRope(text)
    return try await withCheckedThrowingContinuation {c in
        worker.request(rope:rope,revision:revision,visible:range ?? NSRange(location:0,length:rope.count)) {c.resume(with:$0)}
    }
}
@Test func firstPublicationReturnsCompleteManifestAndVisibleRecords() async throws {
    let text="# First\n\n"+(0..<200).map{"Paragraph \($0) **bold**.\n\n"}.joined()+"# Last\n"
    let result=try await prepare(text,range:NSRange(location:0,length:8))
    #expect(result.fragments.first?.html?.contains("<h1>First</h1>")==true)
    #expect(result.blocks?.count==202)
    #expect(result.fragments.count < (result.blocks?.count ?? 0))
    #expect(result.spans.allSatisfy{$0.from<8 && $0.to<=8})
}
@Test func unicodeCRLFAndNestedSourceStylesMatchLiteralText() async throws {
    let text="# 😀 Heading\r\n\r\n> 1. Nested ***bold italic*** and [link](https://example.com).\r\n"
    let result=try await prepare(text)
    let source=text as NSString
    for span in result.spans {#expect(span.from>=0 && span.to<=source.length && span.to>span.from)}
    #expect(result.spans.contains{$0.kind=="StrongEmphasis" && source.substring(with:$0.range).contains("bold italic")})
    #expect(result.spans.contains{$0.kind=="Emphasis" && source.substring(with:$0.range).contains("bold italic")})
    #expect(result.fragments.last?.html?.contains("<ol>")==true)
    #expect(result.fragments.last?.kind=="Blockquote")
}
@Test func tablesCodeRawHTMLAndAssetsKeepTheirContext() async throws {
    let text="| A | B |\n|---|---|\n"+(0..<1000).map{"| \($0) | **cell** |\n"}.joined()+"\n```swift\nlet x = \"$literal$\"\n```\n\n<div>literal **HTML**</div>\n\n![relative](images/test.png)\n\n![file](file:///tmp/test.png)\n\n[bad](javascript:alert(1))\n"
    let result=try await prepare(text)
    let table=try #require(result.fragments.first(where:{$0.kind=="Table"}))
    #expect(table.html?.components(separatedBy:"<tr>").count==1002)
    #expect(table.html?.contains(">999</td>")==true)
    let html=result.fragments.compactMap{$0.html}.joined()
    #expect(html.contains("language-swift"))
    #expect(html.contains("$literal$"))
    #expect(!html.contains("class=\"katex\""))
    #expect(html.contains("<pre>&lt;div&gt;literal **HTML**&lt;/div&gt;</pre>"))
    #expect(html.contains("source=images%2Ftest.png"))
    #expect(html.contains("source=file%3A%2F%2F%2Ftmp%2Ftest.png"))
    #expect(!html.contains("href=\"javascript:"))
}
@Test func everyMathDialectUsesTheSameNativeParseAndKaTeX() async throws {
    let result=try await prepare("$x^2$ and \\(y_1\\).\n\n$$\na=b\n$$\n\n\\[\nc=d\n\\]\n\n```math\nx=y\n```\n")
    let html=result.fragments.compactMap{$0.html}.joined()
    #expect(html.components(separatedBy:"class=\"katex\"").count==6)
    #expect(html.components(separatedBy:"katex-display").count==4)
    #expect(result.fragments.filter{$0.kind=="MathBlock"}.count==3)
    #expect(result.spans.contains{$0.kind=="MathInline"})
}
@Test func invalidMathStaysLocalToItsExpression() async throws {
    let invalid=try await prepare("Before $\\frac{$ after.\n")
    let invalidHTML=invalid.fragments.compactMap{$0.html}.joined()
    #expect(invalidHTML.contains("katex-error"))
    #expect(invalidHTML.contains("Before"))
    #expect(invalidHTML.contains("after"))
}
#if DEBUG
@Test func unavailableMathStaysLocalToItsExpression() async throws {
    let worker=ComrakWorker()
    worker.debugFailNextMathRender()
    let unavailable=try await prepare("Before $x & <y$ after.\n",worker)
    let unavailableHTML=unavailable.fragments.compactMap{$0.html}.joined()
    #expect(unavailableHTML.contains("class=\"math-error\""))
    #expect(unavailableHTML.contains("x &amp; &lt;y"))
    #expect(unavailableHTML.contains("Before"))
    #expect(unavailableHTML.contains("after"))
}
#endif
@Test func blankDocumentAndDistantReferencesHaveCompleteCoverage() async throws {
    let blank=try await prepare(String(repeating:"\n",count:300))
    #expect(blank.fragments.first?.kind=="Empty")
    let result=try await prepare("A [reference][r].\n\n"+String(repeating:"\n",count:300)+"[r]: https://example.com\n")
    #expect(result.fragments.first?.html?.contains("href=\"https://example.com\"")==true)
    #expect(result.blocks?.last?.kind=="LinkReference")
}
@Test func indexedWholeDocumentStylesEqualClippingAcrossGiantBlocks() {
    let doc=PreparedDocument()
    let count=20_000
    let spans=(0..<count).map{SyntaxSpan(kind:"StrongEmphasis",from:$0*10,to:$0*10+8)}
        + [SyntaxSpan(kind:"Emphasis",from:0,to:count*10)]
    doc.adopt([.init(id:"table",kind:"Table",from:0,to:count*10)],revision:1,length:count*10)
    doc.store(ParseResult(revision:1,spans:spans,fragments:[]),range:NSRange(location:0,length:count*10))
    let range=NSRange(location:123_451,length:50)
    let expected=spans.compactMap {s->SyntaxSpan? in
        let from=max(range.location,s.from),to=min(NSMaxRange(range),s.to)
        return from<to ? SyntaxSpan(kind:s.kind,from:from,to:to):nil
    }
    #expect(doc.styles(in:range)?.map{$0.range}==expected.map{$0.range})
    #expect(doc.styles(in:range)?.map{$0.kind}==expected.map{$0.kind})
}
