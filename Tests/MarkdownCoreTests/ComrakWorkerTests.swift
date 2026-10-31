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
@Test func markatoCommentRecordsDoNotCreatePreviewBlocks() async throws {
    let text="First paragraph.\n\n<!-- Explain this. | \"First paragraph.\" | markato-comment:v3 -->\n\nSecond paragraph.\n"
    let result=try await parse(ComrakWorker(),TextRope(text),1)
    let blocks=try #require(result.blocks)
    #expect(blocks.count==2)
    #expect(blocks.compactMap{$0.html?.string()}.joined().contains("markato-comment")==false)
    #expect(blocks.first?.from==0)
    #expect(blocks.last?.from==(text as NSString).range(of:"Second paragraph.").location)
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

@Test func parserPublishesPlainHeadingTitlesForNavigation() async throws {
    let worker=ComrakWorker()
    let text="# 😀 *Heading* with [`code`](https://example.com) and $x^2$\n\nSetext **title**\n---\n"
    let parsed=try await parse(worker,TextRope(text),1)
    let headings=try #require(parsed.blocks?.filter{$0.kind.isHeading})
    #expect(headings.map(\.kind.headingLevel)==[1,2])
    #expect(headings.map(\.headingTitle)==["😀 Heading with code and x^2","Setext title"])
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

@Test func rapidEditsComposeIntoOneRetainedRegionalParse() async throws {
    let worker=ComrakWorker()
    var rope=TextRope((0..<1000).map{"Paragraph \($0) has retained text.\n\n"}.joined())
    let before=try await parse(worker,rope,0)
    let retained=PreparedDocument()
    let originalBlocks=try #require(before.blocks)
    retained.adopt(originalBlocks,revision:0,length:rope.count,
        hasReferences:before.hasReferences ?? false)
    retained.store(before,range:NSRange(location:0,length:rope.count))

    let insertion=(rope.string as NSString).range(of:"retained text").location+3
    var combined:SourceEdit?
    for revision in 1...64 {
        let edit=SourceEdit(range:NSRange(location:insertion+revision-1,length:0),insertedLength:1)
        rope=rope.replacing(edit.range,with:"x")
        worker.record(edit,revision:revision)
        combined=combined.map{$0.composed(with:edit)} ?? edit
    }
    let combinedEdit=try #require(combined)
    let context=try #require(retained.regionalContext(for:combinedEdit,newLength:rope.count))
    let after:ParseResult=try await withCheckedThrowingContinuation {continuation in
        worker.request(rope:rope,revision:64,visible:NSRange(location:0,length:100),
            regionalContext:context) {continuation.resume(with:$0)}
    }
    let change=try #require(after.blockChange)
    #expect(change.prefix==0)
    #expect(change.suffix>990)
    #expect(change.blocks.count<10)
    #expect(change.blocks.first?.id==originalBlocks.first?.id)
    let updated=applying(change,to:originalBlocks)
    let fresh=try await parse(ComrakWorker(),rope,64)
    #expect(updated.map{[$0.kind.name,"\($0.from)","\($0.to)"]} ==
        fresh.blocks?.map{[$0.kind.name,"\($0.from)","\($0.to)"]})
    #expect(change.blocks.first?.html?.string().contains(String(repeating:"x",count:64))==true)
    #expect(updated.last?.id==originalBlocks.last?.id)
}

@Test func composedEditConservativelyCoversSeparatedAndOverlappingChanges() {
    let first=SourceEdit(range:NSRange(location:10,length:2),insertedLength:5)
    let overlapping=first.composed(with:SourceEdit(range:NSRange(location:12,length:2),insertedLength:1))
    #expect(overlapping.range==NSRange(location:10,length:2))
    #expect(overlapping.insertedLength==4)

    let after=overlapping.composed(with:SourceEdit(range:NSRange(location:30,length:3),insertedLength:2))
    #expect(after.range.location==10)
    #expect(NSMaxRange(after.range)==31)
    #expect(after.insertedLength==22)

    let before=after.composed(with:SourceEdit(range:NSRange(location:2,length:1),insertedLength:4))
    #expect(before.range.location==2)
    #expect(NSMaxRange(before.range)==31)
    #expect(before.insertedLength==33)
}

@Test func composedEditKeepsUnchangedPrefixAndSuffixAcrossDifficultSequence() {
    let base=String(repeating:"0123456789 abcdefghij\n",count:80)
    var current=base
    var combined:SourceEdit?
    var state:UInt64=0x5eed
    func random(_ upper:Int)->Int {
        state=state &* 6364136223846793005 &+ 1442695040888963407
        return upper==0 ? 0:Int((state>>32)%UInt64(upper))
    }
    let replacements=["x","😀","\nnew paragraph\n","**bold**","",String(repeating:"z",count:17)]
    for _ in 0..<400 {
        let length=(current as NSString).length
        let start=random(length+1),removed=min(random(12),length-start)
        let replacement=replacements[random(replacements.count)]
        let edit=SourceEdit(range:NSRange(location:start,length:removed),
            insertedLength:replacement.utf16.count)
        current=(current as NSString).replacingCharacters(in:edit.range,with:replacement)
        combined=combined.map{$0.composed(with:edit)} ?? edit
        let value=try! #require(combined)
        let baseText=base as NSString,currentText=current as NSString
        #expect(currentText.substring(to:value.range.location)==baseText.substring(to:value.range.location))
        #expect(currentText.substring(from:value.range.location+value.insertedLength) ==
            baseText.substring(from:NSMaxRange(value.range)))
        #expect(currentText.length==baseText.length-value.range.length+value.insertedLength)
    }
}
