import Foundation
import Testing
@testable import MarkdownCore

private func result(_ from:Int,_ to:Int,_ text:String="text",_ revision:Int=0)->ParseResult {
    ParseResult(revision:revision,spans:[],fragments:[PreviewFragment(kind:"Paragraph",from:from,to:to,markdown:text,html:"<p>\(text)</p>")])
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
    for i in 0..<100 {cache.store(result(i*100,i*100+90,"\(i)"),range:NSRange(location:i*100,length:110))}
    #expect(cache.entries(covering:NSRange(location:0,length:10000)) != nil)
    #expect(cache.firstUnpreparedOffset(from:0)==10010)
    #expect(cache.count>=100)
    let entries=cache.store(result(9900,10010,"changed",1),range:NSRange(location:9900,length:100))
    let again=cache.store(result(9900,10010,"changed again",2),range:NSRange(location:9900,length:100))
    #expect(entries.first?.id==again.first?.id)
    #expect(cache.entries(covering:NSRange(location:100,length:80)) != nil)
}
@Test func overlappingBlocksCannotClaimMissingContentIsPrepared() {
    let cache=RenderedCache()
    func table(_ from:Int,_ to:Int)->PreviewFragment {
        PreviewFragment(kind:"Table",from:from,to:to,markdown:"rows \(from)...\(to)",html:"<table></table>")
    }
    let initial=ParseResult(revision:0,spans:[],fragments:[result(0,90).fragments[0],table(100,300),result(310,390).fragments[0]])
    cache.store(initial,range:NSRange(location:0,length:400))
    cache.store(ParseResult(revision:0,spans:[],fragments:[table(160,220)]),range:NSRange(location:160,length:60))
    #expect(cache.entries(covering:NSRange(location:0,length:90)) != nil)
    #expect(cache.entries(covering:NSRange(location:310,length:80)) != nil)
    #expect(cache.entries(covering:NSRange(location:160,length:60))?.first?.fragment.from==160)
    #expect(cache.entries(covering:NSRange(location:120,length:20))==nil)
    #expect(cache.entries(covering:NSRange(location:260,length:20))==nil)
    #expect(cache.firstUnpreparedOffset(from:0)==100)
    cache.store(ParseResult(revision:0,spans:[],fragments:[table(100,300)]),range:NSRange(location:100,length:200))
    #expect(cache.entries(covering:NSRange(location:0,length:400)) != nil)
    #expect(cache.firstUnpreparedOffset(from:0)==400)
}
@Test func localInvalidationRepairsOnlyTheGap() {
    let cache=RenderedCache()
    for i in 0..<1000 {cache.store(result(i*100,i*100+90),range:NSRange(location:i*100,length:100))}
    #expect(cache.firstUnpreparedOffset(from:0)==100000)
    cache.invalidate(SourceEdit(range:NSRange(location:50105,length:1),insertedLength:3))
    #expect(cache.firstUnpreparedOffset(from:0)==50100)
    #expect(cache.firstUnpreparedOffset(from:50202)==100002)
    cache.store(result(50100,50202),range:NSRange(location:50100,length:102))
    #expect(cache.firstUnpreparedOffset(from:0)==100002)
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

@Test func preparedDocumentRetainsDistantIntervalsWhileProgressHasAGap() {
    let cache=RenderedCache()
    cache.store(result(900,1000,"destination"),range:NSRange(location:900,length:100))
    cache.store(result(0,100,"beginning"),range:NSRange(location:0,length:100))
    #expect(cache.allPages.map{ $0.range.location }==[0,900])
    #expect(cache.firstUnpreparedOffset(from:0)==100)
    #expect(cache.entries(covering:NSRange(location:900,length:100))?.first?.fragment.markdown=="destination")
    for offset in stride(from:100,to:900,by:100) {
        cache.store(result(offset,offset+100),range:NSRange(location:offset,length:100))
    }
    #expect(cache.firstUnpreparedOffset(from:0)==1000)
    #expect(cache.allPages.flatMap{$0.entries}.count==10)
    #expect(cache.allPages.last?.entries.first?.fragment.markdown=="destination")
}
