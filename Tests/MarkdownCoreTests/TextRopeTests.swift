import Foundation
import Testing
@testable import MarkdownCore

@Test func persistentEditsAndLines() {
    var rope = TextRope("first\nsecond\n🧮 third\n")
    let before = rope
    rope = rope.replacing(NSRange(location: 6, length: 6), with: "replacement")
    #expect(rope.string == "first\nreplacement\n🧮 third\n")
    #expect(before.string == "first\nsecond\n🧮 third\n")
    #expect(rope.lineCount == 4)
    #expect(rope.lineStart(2) == 18)
    #expect(rope.line(at: 20) == 2)
}
@Test func randomizedEditsMatchUTF16Reference() {
    var rope = TextRope(String(repeating: "alpha\nbeta\n", count: 2000))
    var reference = Array(rope.string.utf16)
    var seed: UInt64 = 19
    func next(_ bound: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % UInt64(max(bound, 1))) }
    for _ in 0..<2000 {
        let start = next(reference.count + 1), length = min(next(30), reference.count-start)
        let inserted = next(2) == 0 ? "inserted\ntext" : "x"
        rope = rope.replacing(NSRange(location:start,length:length), with:inserted)
        reference.replaceSubrange(start..<start+length, with: inserted.utf16)
        #expect(rope.units(in:NSRange(location:0,length:rope.count)) == reference)
        #expect(rope.treeHeight < 30)
        let at = next(reference.count+1)
        #expect(rope.line(at:at) == reference.prefix(at).filter{$0 == 10}.count)
    }
}
@Test func parserBridgePublishesManifestThenQueriesPreparedViewport() async throws {
    let worker = ComrakWorker()
    let source = TextRope(String(repeating:"A **bold** paragraph.\n\n",count:1000))
    let result: ParseResult = try await withCheckedThrowingContinuation { continuation in
        worker.request(rope:source, revision:0, visible:NSRange(location:0,length:80)) { continuation.resume(with:$0) }
    }
    #expect(result.blocks?.count==1000)
    #expect(result.fragments.count<10)
    #expect(result.fragments.allSatisfy{$0.from<80})
    #expect(result.spans.contains{$0.kind == "StrongEmphasis"})
    let visible:ParseResult=try await withCheckedThrowingContinuation {c in
        worker.request(rope:source,revision:0,visible:NSRange(location:0,length:80),includeFragments:false) {c.resume(with:$0)}
    }
    #expect(visible.fragments.isEmpty && visible.spans.count<30)
    #expect(visible.spans.allSatisfy{$0.from>=0 && $0.to<=80})
}
