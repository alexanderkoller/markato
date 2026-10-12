import Foundation
import Testing
@testable import MarkdownCore

private func parse(_ worker:ComrakWorker,_ rope:TextRope,_ revision:Int) async throws -> ParseResult {
    try await withCheckedThrowingContinuation { continuation in
        worker.request(rope:rope,revision:revision,visible:NSRange(location:0,length:rope.count)) { continuation.resume(with:$0) }
    }
}
private func applying(_ change:PreparedBlockChange,to blocks:[PreparedBlock])->[PreparedBlock] {
    var result=Array(blocks.prefix(change.prefix));result.append(contentsOf:change.blocks)
    result.append(contentsOf:blocks.suffix(change.suffix).map {
        PreparedBlock(id:$0.id,kind:$0.kind,from:$0.from+change.shift,to:$0.to+change.shift)
    })
    return result
}
@Test func coalescedEditsMatchFreshParse() async throws {
    let worker = ComrakWorker()
    var rope = TextRope("# Title\n\nFirst **bold** paragraph.\n\nAnother *italic* paragraph.\n")
    _ = try await parse(worker,rope,0)
    let first = SourceEdit(range:NSRange(location:9,length:0),insertedLength:4)
    rope = rope.replacing(first.range,with:"New "); worker.record(first,revision:1)
    let second = SourceEdit(range:NSRange(location:0,length:1),insertedLength:2)
    rope = rope.replacing(second.range,with:"##"); worker.record(second,revision:2)
    let incremental = try await parse(worker,rope,2)
    let fresh = try await parse(ComrakWorker(),rope,2)
    #expect(incremental.blocks?.map{[$0.kind.name,"\($0.from)","\($0.to)",$0.html?.string() ?? ""]} ==
        fresh.blocks?.map{[$0.kind.name,"\($0.from)","\($0.to)",$0.html?.string() ?? ""]})
    #expect(incremental.spans.map{$0.kind} == fresh.spans.map{$0.kind})
    #expect(incremental.spans.map{$0.from} == fresh.spans.map{$0.from})
    #expect(incremental.blocks?.map{$0.from} == fresh.blocks?.map{$0.from})
    #expect(incremental.blocks?.map{$0.to} == fresh.blocks?.map{$0.to})
}
@Test func resetDoesNotReuseDifferentSource() async throws {
    let worker = ComrakWorker()
    _ = try await parse(worker,TextRope("Old paragraph.\n"),0)
    worker.reset()
    let result = try await parse(worker,TextRope("## New heading\n"),1)
    #expect(result.blocks?.first?.kind == .atxHeading2)
}

@Test func fullContextParserUsesLibrariesForMathAndTables() async throws {
    let worker=ComrakWorker()
    let text="# Heading\n\n**bold** and $x^2$; \\(y_1\\).\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n$$\n\\begin{aligned}a&=b\\\\c&=d\\end{aligned}\n$$\n"
    let parsed:ParseResult=try await withCheckedThrowingContinuation {c in worker.request(rope:TextRope(String(repeating:"\n",count:100)+text),revision:3,visible:NSRange(location:100,length:text.utf16.count)) {c.resume(with:$0)}}
    let html=parsed.blocks?.compactMap{$0.html?.string()}.joined() ?? ""
    #expect(html.contains("<h1>Heading</h1>"))
    #expect(html.contains("<strong>bold</strong>"))
    #expect(html.contains("<table>"))
    #expect(html.components(separatedBy:"class=\"katex\"").count>=4)
    #expect(parsed.blocks?.first?.from==100)
    #expect(parsed.revision==3)
}


@Test func parserResetCannotReuseOldBlockIdentities() async throws {
    let worker=ComrakWorker()
    let before=try await parse(worker,TextRope("# Heading\n"),1)
    worker.reset()
    let after=try await parse(worker,TextRope("A paragraph.\n"),2)
    #expect(before.blocks?.first?.id != after.blocks?.first?.id)
    #expect(after.blocks?.first?.html?.string().contains("<p>A paragraph.</p>")==true)
}

@Test func manifestDeltaHandlesCoalescedEditsWithDifferentTrailingWhitespaceShift() async throws {
    let worker=ComrakWorker()
    var rope=TextRope("First paragraph.\n\nSecond **bold** paragraph.\n\nLast paragraph.\n")
    _ = try await parse(worker,rope,0)
    let first=SourceEdit(range:NSRange(location:0,length:0),insertedLength:2)
    rope=rope.replacing(first.range,with:"X ");worker.record(first,revision:1)
    let second=SourceEdit(range:NSRange(location:rope.count,length:0),insertedLength:4)
    rope=rope.replacing(second.range,with:"    ");worker.record(second,revision:2)
    let after=try await parse(worker,rope,2),fresh=try await parse(ComrakWorker(),rope,2)
    #expect(after.blocks?.map{$0.from}==fresh.blocks?.map{$0.from})
    #expect(after.blocks?.map{$0.to}==fresh.blocks?.map{$0.to})
}

@Test func swiftRetainedTreeSuppliesStatelessRegionalParseContext() async throws {
    let worker=ComrakWorker()
    var rope=TextRope((0..<1000).map{"Paragraph \($0).\n\n"}.joined())
    let before=try await parse(worker,rope,0)
    let retained=PreparedDocument()
    retained.adopt(try #require(before.blocks),revision:0,length:rope.count,
        hasReferences:before.hasReferences ?? false)
    retained.store(before,range:NSRange(location:0,length:rope.count))
    let edit=SourceEdit(range:NSRange(location:3,length:0),insertedLength:1)
    rope=rope.replacing(edit.range,with:"x")
    let context=try #require(retained.regionalContext(for:edit,newLength:rope.count))
    worker.record(edit,revision:1)
    let after:ParseResult=try await withCheckedThrowingContinuation {continuation in
        worker.request(rope:rope,revision:1,visible:NSRange(location:0,length:80),
            regionalContext:context) {continuation.resume(with:$0)}
    }
    let change=try #require(after.blockChange)
    #expect(change.prefix==0)
    #expect(change.suffix>990)
    #expect(after.from==context.range.location && after.to==NSMaxRange(context.range))
}
