import Foundation
import Testing
@testable import MarkdownCore

private func parse(_ worker:LezerWorker,_ rope:TextRope,_ revision:Int) async throws -> ParseResult {
    try await withCheckedThrowingContinuation { continuation in
        worker.request(rope:rope,revision:revision,visible:NSRange(location:0,length:rope.count)) { continuation.resume(with:$0) }
    }
}
@Test func coalescedEditsMatchFreshParse() async throws {
    let worker = LezerWorker()
    var rope = TextRope("# Title\n\nFirst **bold** paragraph.\n\nAnother *italic* paragraph.\n")
    _ = try await parse(worker,rope,0)
    let first = SourceEdit(range:NSRange(location:9,length:0),insertedLength:4)
    rope = rope.replacing(first.range,with:"New "); worker.record(first,revision:1)
    let second = SourceEdit(range:NSRange(location:0,length:1),insertedLength:2)
    rope = rope.replacing(second.range,with:"##"); worker.record(second,revision:2)
    let incremental = try await parse(worker,rope,2)
    let fresh = try await parse(LezerWorker(),rope,2)
    #expect(incremental.fragments.map{$0.markdown} == fresh.fragments.map{$0.markdown})
    #expect(incremental.spans.map{$0.kind} == fresh.spans.map{$0.kind})
    #expect(incremental.spans.map{$0.from} == fresh.spans.map{$0.from})
    #expect(incremental.blocks?.map{$0.from} == fresh.blocks?.map{$0.from})
    #expect(incremental.blocks?.map{$0.to} == fresh.blocks?.map{$0.to})
}
@Test func resetDoesNotReuseDifferentSource() async throws {
    let worker = LezerWorker()
    _ = try await parse(worker,TextRope("Old paragraph.\n"),0)
    worker.reset()
    let result = try await parse(worker,TextRope("## New heading\n"),1)
    #expect(result.fragments.first?.kind == "ATXHeading2")
}

@Test func fullContextParserUsesLibrariesForMathAndTables() async throws {
    let worker=LezerWorker()
    let text="# Heading\n\n**bold** and $x^2$; \\(y_1\\).\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n$$\n\\begin{aligned}a&=b\\\\c&=d\\end{aligned}\n$$\n"
    let parsed:ParseResult=try await withCheckedThrowingContinuation {c in worker.request(rope:TextRope(String(repeating:"\n",count:100)+text),revision:3,visible:NSRange(location:100,length:text.utf16.count)) {c.resume(with:$0)}}
    let html=parsed.fragments.compactMap{$0.html}.joined()
    #expect(html.contains("<h1>Heading</h1>"))
    #expect(html.contains("<strong>bold</strong>"))
    #expect(html.contains("<table>"))
    #expect(html.components(separatedBy:"class=\"katex\"").count>=4)
    #expect(parsed.fragments.first?.from==100)
    #expect(parsed.revision==3)
}


@Test func parserResetCannotReuseOldBlockIdentities() async throws {
    let worker=LezerWorker()
    let before=try await parse(worker,TextRope("# Heading\n"),1)
    worker.reset()
    let after=try await parse(worker,TextRope("A paragraph.\n"),2)
    #expect(before.blocks?.first?.id != after.blocks?.first?.id)
    #expect(after.fragments.first?.html?.contains("<p>A paragraph.</p>")==true)
}

@Test func manifestDeltaHandlesCoalescedEditsWithDifferentTrailingWhitespaceShift() async throws {
    let worker=LezerWorker()
    var rope=TextRope("First paragraph.\n\nSecond **bold** paragraph.\n\nLast paragraph.\n")
    let before=try await parse(worker,rope,0)
    let first=SourceEdit(range:NSRange(location:0,length:0),insertedLength:2)
    rope=rope.replacing(first.range,with:"X ");worker.record(first,revision:1)
    let second=SourceEdit(range:NSRange(location:rope.count,length:0),insertedLength:4)
    rope=rope.replacing(second.range,with:"    ");worker.record(second,revision:2)
    let after=try await parse(worker,rope,2),fresh=try await parse(LezerWorker(),rope,2)
    #expect(after.blocks?.map{$0.from}==fresh.blocks?.map{$0.from})
    #expect(after.blocks?.map{$0.to}==fresh.blocks?.map{$0.to})
    #expect(after.blocks?.last?.id==before.blocks?.last?.id)
    #expect(after.blocks?.last?.from==(before.blocks?.last?.from ?? 0)+2)
}
