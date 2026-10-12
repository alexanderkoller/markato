import Foundation
import Testing
@testable import MarkdownCore

private func mermaidParse(_ worker:ComrakWorker,_ rope:TextRope,_ revision:Int,
                          context:RegionalParseContext? = nil) async throws->ParseResult {
    try await withCheckedThrowingContinuation {continuation in
        worker.request(rope:rope,revision:revision,visible:NSRange(location:0,length:rope.count),
            regionalContext:context) {continuation.resume(with:$0)}
    }
}
private func fixture(_ name:String)throws->String {
    let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf:root.appendingPathComponent("Tests/fixtures/mermaid/\(name).md"),encoding:.utf8)
}
private func output(_ result:ParseResult)->String {
    result.blocks?.compactMap{$0.html?.string()}.joined() ?? ""
}
private func svg(_ html:String)throws->String {
    let data=try #require(html.components(separatedBy:"data:image/svg+xml,").dropFirst().first)
    return try #require(data.components(separatedBy:"\"").first?.removingPercentEncoding)
}

@Test func mermaidFixturesCrossTheNativeRecordBoundary() async throws {
    for (name,images,errors) in [("families",14,0),("layout",8,0),("errors",1,5),("stress",100,0)] {
        let text=try fixture(name)
        let result=try await mermaidParse(ComrakWorker(),TextRope(text),0)
        let html=output(result)
        #expect(html.components(separatedBy:"class=\"mermaid-diagram\"").count-1==images)
        #expect(html.components(separatedBy:"class=\"mermaid-error\"").count-1==errors)
        #expect(result.to==text.utf16.count)
        #expect(result.blocks?.allSatisfy{$0.from>=0 && $0.to<=text.utf16.count}==true)
        for image in html.components(separatedBy:"data:image/svg+xml,").dropFirst() {
            let xml=try #require(image.components(separatedBy:"\"").first?.removingPercentEncoding)
            let parser=XMLParser(data:Data(xml.utf8))
            #expect(parser.parse(), "SVG must be well-formed XML: \(parser.parserError?.localizedDescription ?? "unknown")")
        }
    }
}

@Test func mermaidAndKaTeXRenderInTheSameDocument() async throws {
    let result=try await mermaidParse(ComrakWorker(),TextRope(try fixture("layout")),0)
    let html=output(result)
    #expect(html.contains("class=\"katex\""))
    #expect(html.contains("data:image/svg+xml,"))
    #expect(html.contains("language-swift"))
    #expect(html.contains("<table>"))
}

@Test func regionalMermaidEditMatchesFreshParseAndKeepsUntouchedBlocks() async throws {
    let worker=ComrakWorker()
    var rope=TextRope("Far before.\n\nBefore 😀.\n\n```mermaid\nflowchart LR\n A[Original] --> B[Done]\n```\n\nAfter.\n\nFar after.\n")
    let before=try await mermaidParse(worker,rope,0)
    let retained=PreparedDocument()
    retained.adopt(try #require(before.blocks),revision:0,length:rope.count,hasReferences:before.hasReferences ?? false)
    retained.store(before,range:NSRange(location:0,length:rope.count))
    let range=(rope.string(in:NSRange(location:0,length:rope.count)) as NSString).range(of:"Original")
    let edit=SourceEdit(range:range,insertedLength:"Updated 😀".utf16.count)
    rope=rope.replacing(range,with:"Updated 😀");worker.record(edit,revision:1)
    let context=try #require(retained.regionalContext(for:edit,newLength:rope.count))
    let after=try await mermaidParse(worker,rope,1,context:context)
    let change=try #require(after.blockChange)
    #expect(change.prefix>0 && change.suffix>0)
    let rendered=try #require(change.blocks.first(where:{$0.kind == .fencedCode})?.html?.string())
    #expect(try svg(rendered).contains("Updated 😀"))
    #expect(!(try svg(rendered)).contains("Original"))
    let fresh=try await mermaidParse(ComrakWorker(),rope,1)
    #expect(rendered==fresh.blocks?.first(where:{$0.kind == .fencedCode})?.html?.string())
}

@Test func invalidMermaidRecoversAfterEditWithoutResettingTheWorker() async throws {
    let worker=ComrakWorker()
    var rope=TextRope("```mermaid\nunknownDiagram\n A --> B\n```\n\nAfter.\n\nFar after.\n")
    let invalid=try await mermaidParse(worker,rope,0)
    #expect(output(invalid).contains("mermaid-error"))
    let range=NSRange(location:11,length:"unknownDiagram".utf16.count)
    let edit=SourceEdit(range:range,insertedLength:"flowchart LR".utf16.count)
    rope=rope.replacing(range,with:"flowchart LR");worker.record(edit,revision:1)
    let recovered=try await mermaidParse(worker,rope,1)
    #expect(output(recovered).contains("mermaid-diagram"))
    #expect(!output(recovered).contains("mermaid-error"))
    #expect(output(recovered).contains("<p>After.</p>"))
}
