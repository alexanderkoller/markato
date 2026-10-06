import Foundation
import Testing
@testable import MarkdownCore

private func result(_ from:Int,_ to:Int,_ text:String="text",_ revision:Int=0)->ParseResult {
    ParseResult(revision:revision,spans:[],fragments:[PreviewFragment(kind:"Paragraph",from:from,to:to,anchorFrom:from,anchorTo:to,markdown:text,html:"<p>\(text)</p>")])
}
@Test func cachedSuffixShiftsWithoutLosingContent() {
    let cache=RenderedCache()
    for i in 0..<1000 {cache.store(result(i*100,i*100+90,"\(i)"),range:NSRange(location:i*100,length:100))}
    cache.invalidate(SourceEdit(range:NSRange(location:5,length:0),insertedLength:7))
    for i in [1,2,50,500,999] {
        let entries=cache.entries(covering:NSRange(location:i*100+7,length:80))
        #expect(entries?.first?.fragment.from==i*100+7)
        #expect(entries?.first?.fragment.markdown=="\(i)")
    }
    #expect(cache.entries(covering:NSRange(location:0,length:50))==nil)
}
@Test func backgroundOverlapPreservesPreparedPages() {
    let cache=RenderedCache()
    for i in 0..<100 {cache.store(result(i*100,i*100+110,"\(i)"),range:NSRange(location:i*100,length:100))}
    #expect(cache.entries(covering:NSRange(location:0,length:10000)) != nil)
    #expect(cache.firstUnpreparedOffset(from:0)==10010)
    #expect(cache.count>=100)
    let entries=cache.store(result(9900,10010,"changed",1),range:NSRange(location:9900,length:100))
    let again=cache.store(result(9900,10010,"changed again",2),range:NSRange(location:9900,length:100))
    #expect(entries.first?.id==again.first?.id)
    #expect(cache.entries(covering:NSRange(location:100,length:80)) != nil)
}
@Test func localInvalidationRepairsOnlyTheGapAndMemoryIsBounded() {
    let cache=RenderedCache()
    for i in 0..<1000 {cache.store(result(i*100,i*100+90),range:NSRange(location:i*100,length:100))}
    #expect(cache.firstUnpreparedOffset(from:0)==100000)
    cache.invalidate(SourceEdit(range:NSRange(location:50105,length:1),insertedLength:3))
    #expect(cache.firstUnpreparedOffset(from:0)==50100)
    #expect(cache.firstUnpreparedOffset(from:50202)==100002)
    cache.store(result(50100,50202),range:NSRange(location:50100,length:102))
    #expect(cache.firstUnpreparedOffset(from:0)==100002)
    let limited=RenderedCache(byteLimit:50)
    for i in 0..<100 {limited.store(result(i*100,i*100+90),range:NSRange(location:i*100,length:100))}
    #expect(limited.byteCost<=50)
    #expect(limited.count<10)
}
@Test func localHTMLUsesLibrariesForMathAndTables() async throws {
    let worker=HTMLWorker()
    let text="# Heading\n\n**bold** and $x^2$; \\(y_1\\).\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n$$\n\\begin{aligned}a&=b\\\\c&=d\\end{aligned}\n$$\n"
    let parsed:ParseResult=try await withCheckedThrowingContinuation {c in worker.request(text:text,from:100,revision:3) {c.resume(with:$0)}}
    let html=parsed.fragments.compactMap{$0.html}.joined()
    #expect(html.contains("<h1>Heading</h1>"))
    #expect(html.contains("<strong>bold</strong>"))
    #expect(html.contains("<table>"))
    #expect(html.components(separatedBy:"class=\"katex\"").count>=4)
    #expect(parsed.fragments.first?.from==100)
    #expect(parsed.revision==3)
}
