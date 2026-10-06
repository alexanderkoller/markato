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
}
@Test func resetDoesNotReuseDifferentSource() async throws {
    let worker = LezerWorker()
    _ = try await parse(worker,TextRope("Old paragraph.\n"),0)
    worker.reset()
    let result = try await parse(worker,TextRope("## New heading\n"),1)
    #expect(result.fragments.first?.kind == "ATXHeading2")
}
