import Foundation
import Testing
@testable import MarkdownCore

private func parseHighlight(_ worker:ComrakWorker,_ rope:TextRope,_ revision:Int,
                            context:RegionalParseContext? = nil) async throws->ParseResult {
    try await withCheckedThrowingContinuation {continuation in
        worker.request(rope:rope,revision:revision,visible:NSRange(location:0,length:rope.count),
            regionalContext:context) {continuation.resume(with:$0)}
    }
}
private func highlightingFixture(_ name:String)throws->String {
    let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf:root.appendingPathComponent("Tests/fixtures/highlighting/\(name).md"),encoding:.utf8)
}
private final class CodeXML:NSObject,XMLParserDelegate {
    var text=""
    private var insideCode=false
    func parser(_ parser:XMLParser,didStartElement elementName:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
        if elementName == "code" {insideCode=true}
    }
    func parser(_ parser:XMLParser,didEndElement elementName:String,namespaceURI:String?,qualifiedName:String?) {
        if elementName == "code" {insideCode=false}
    }
    func parser(_ parser:XMLParser,foundCharacters string:String) {if insideCode {text += string}}
}
func highlightedCodeText(_ html:String)throws->String {
    let delegate=CodeXML(),parser=XMLParser(data:Data("<root>\(html)</root>".utf8))
    parser.delegate=delegate
    #expect(parser.parse(), "Highlighted HTML should be balanced and escaped")
    return delegate.text
}

@Test func allHighlightingFixturesCrossTheRecordBridge() async throws {
    for (name,count) in [("languages",12),("extended",8),("stress",100)] {
        let text=try highlightingFixture(name)
        let result=try await parseHighlight(ComrakWorker(),TextRope(text),0)
        let fences=try #require(result.blocks?.filter{$0.kind == .fencedCode})
        #expect(fences.count==count)
        for fence in fences {
            let html=try #require(fence.html?.string())
            #expect(html.contains("<span class=\"syntax-"))
            let code=try highlightedCodeText(html)
            #expect(!code.isEmpty)
            #expect(fence.from>=0 && fence.to<=text.utf16.count)
        }
    }
}

@Test func highlightedUnicodeAndHTMLPreserveLiteralTextExactly() async throws {
    for (language,code) in [
        ("python","message = \"Grüße 😀 & < >\"\n# comment\n"),
        ("html","<script>alert(\"x\")</script>\n<img src='x' onerror='alert(1)'>\n"),
        ("unknown-language","<script>literal & safe</script>\n"),
        ("swift","let message = \"Grüße 😀 & < >\"\n"),
        ("tsx","const element = <div title=\"Grüße 😀\">Hello & goodbye</div>;\n"),
        ("typst","#let message = \"Grüße 😀 & < >\"\n#message\n"),
    ] {
        let result=try await parseHighlight(ComrakWorker(),TextRope("```\(language)\n\(code)```\n"),0)
        let html=try #require(result.blocks?.first?.html?.string())
        #expect(try highlightedCodeText(html)==code)
        #expect(!html.contains("<script>") && !html.contains("<img"))
    }
}

@Test func highlightingCoexistsWithMathAndMermaid() async throws {
    let result=try await parseHighlight(ComrakWorker(),TextRope(try highlightingFixture("edge-cases")),0)
    let html=result.blocks?.compactMap{$0.html?.string()}.joined() ?? ""
    #expect(html.contains("syntax-string"))
    #expect(html.contains("mermaid-diagram"))
    #expect(html.contains("class=\"katex\""))
    #expect(html.contains("End of edge case fixture"))
}

@Test func regionalDelimiterEditMatchesFreshHighlighting() async throws {
    let worker=ComrakWorker()
    var rope=TextRope("Far before.\n\nBefore.\n\n```python\ntext = \"\"\"first\nsecond 😀\nthird\"\"\"\nprint(text)\n```\n\nAfter.\n\nFar after.\n")
    let before=try await parseHighlight(worker,rope,0)
    let retained=PreparedDocument()
    retained.adopt(try #require(before.blocks),revision:0,length:rope.count,hasReferences:before.hasReferences ?? false)
    retained.store(before,range:NSRange(location:0,length:rope.count))
    let range=(rope.string(in:NSRange(location:0,length:rope.count)) as NSString).range(of:"\"\"\"first")
    let edit=SourceEdit(range:range,insertedLength:"\"first\"".utf16.count)
    rope=rope.replacing(range,with:"\"first\"");worker.record(edit,revision:1)
    let context=try #require(retained.regionalContext(for:edit,newLength:rope.count))
    let after=try await parseHighlight(worker,rope,1,context:context)
    let change=try #require(after.blockChange)
    #expect(change.prefix>0 && change.suffix>0)
    let modified=try #require(change.blocks.first(where:{$0.kind == .fencedCode})?.html?.string())
    let fresh=try await parseHighlight(ComrakWorker(),rope,1)
    #expect(modified==fresh.blocks?.first(where:{$0.kind == .fencedCode})?.html?.string())
    #expect(modified != before.blocks?.first(where:{$0.kind == .fencedCode})?.html?.string())
}
