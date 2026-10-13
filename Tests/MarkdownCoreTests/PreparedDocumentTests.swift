import Foundation
import Testing
@testable import MarkdownCore

private func prepared(_ id:String,_ from:Int,_ to:Int,_ text:String)->PreviewFragment {
    PreviewFragment(kind:"Paragraph",from:from,to:to,html:"<p>\(text)</p>",id:id)
}
@Test func emptyDocumentProducesAnEmptyRenderableWindow() throws {
    let doc=PreparedDocument()
    doc.adopt([],revision:1,length:0)
    let window=try #require(doc.window(covering:NSRange(location:0,length:0),before:100,after:100))
    #expect(window.range==NSRange(location:0,length:0))
    #expect(window.entries.isEmpty)
    #expect(window.previewTop==0)
    #expect(window.previewHeight==0)
}
@Test func sharedBlocksRetainHTMLAndMeasuredHeightsAcrossOffsetChanges() {
    let doc=PreparedDocument()
    doc.adopt([.init(id:"a",kind:"Paragraph",from:0,to:5),.init(id:"b",kind:"Paragraph",from:7,to:12)],revision:1,length:13)
    doc.store(ParseResult(revision:1,spans:[],fragments:[prepared("a",0,5,"first"),prepared("b",7,12,"last")]),range:NSRange(location:0,length:13))
    doc.recordPreviewHeights(["b":30],revision:1)
    doc.sourceLayout.replaceSuffix(at:0,with:[.init(length:7,advance:20,height:20),.init(length:6,advance:20,height:20)])
    #expect(doc.firstUnpreparedOffset(from:0)==13)
    #expect(doc.heights(for:"b")?.preview==30)
    doc.adopt([.init(id:"new",kind:"Paragraph",from:0,to:10),.init(id:"b",kind:"Paragraph",from:12,to:17)],revision:2,length:18)
    #expect(doc.entries(covering:NSRange(location:12,length:5))?.first?.fragment.html=="<p>last</p>")
    #expect(doc.entries(covering:NSRange(location:12,length:5))?.first?.fragment.from==12)
    #expect(doc.entries(covering:NSRange(location:0,length:10))==nil)
    #expect(doc.styles(in:NSRange(location:12,length:5))?.isEmpty==true)
    #expect(doc.heights(for:"b")?.preview==30)
    #expect(doc.window(covering:NSRange(location:12,length:5),before:0,after:0)?.range==NSRange(location:10,length:8))
}
@Test func manifestSpliceRetainsUnaffectedNodesCachesAndShiftedCoordinates() {
    let doc=PreparedDocument()
    doc.adopt([.init(id:"a",kind:"Paragraph",from:0,to:5),
               .init(id:"b",kind:"Paragraph",from:7,to:12),
               .init(id:"c",kind:"Paragraph",from:14,to:19)],revision:1,length:20)
    doc.store(ParseResult(revision:1,spans:[.init(kind:"Emphasis",from:14,to:19)],
        fragments:[prepared("a",0,5,"a"),prepared("b",7,12,"b"),prepared("c",14,19,"c")]),
        range:NSRange(location:0,length:20))
    doc.recordPreviewHeights(["c":31],revision:1)
    doc.apply(.init(prefix:1,suffix:1,shift:3,
        blocks:[.init(id:"new",kind:"Paragraph",from:7,to:15)]),revision:2,length:23)
    #expect(doc.entries(covering:NSRange(location:0,length:5))?.first?.fragment.html=="<p>a</p>")
    #expect(doc.entries(covering:NSRange(location:17,length:5))?.first?.fragment.html=="<p>c</p>")
    #expect(doc.entries(covering:NSRange(location:17,length:5))?.first?.fragment.from==17)
    #expect(doc.entries(covering:NSRange(location:7,length:8))==nil)
    #expect(doc.heights(for:"c")?.preview==31)
    #expect(doc.styles(in:NSRange(location:17,length:5))?.first?.range==NSRange(location:17,length:5))
}

@Test func outlineProjectionSplicesHeadingsAndShiftsUnaffectedRanges() {
    let doc=PreparedDocument()
    doc.adopt([
        .init(id:"title",kind:"ATXHeading1",from:0,to:7,headingTitle:"Title"),
        .init(id:"body",kind:"Paragraph",from:9,to:20),
        .init(id:"later",kind:"ATXHeading2",from:22,to:30,headingTitle:"Later")
    ],revision:1,length:31)
    #expect(doc.headings.map(\.title)==["Title","Later"])
    doc.apply(.init(prefix:1,suffix:1,shift:5,blocks:[
        .init(id:"inserted",kind:"ATXHeading3",from:9,to:25,headingTitle:"Inserted")
    ]),revision:2,length:36)
    #expect(doc.headings.map(\.title)==["Title","Inserted","Later"])
    #expect(doc.headings.map(\.level)==[1,3,2])
    #expect(doc.headings.map(\.range.location)==[0,9,27])
}
@Test func bodyEditDoesNotRebuildOutlineAndResolvesShiftedHeadingLazily() throws {
    let doc=PreparedDocument()
    doc.adopt([
        .init(id:"title",kind:"ATXHeading1",from:0,to:7,headingTitle:"Title"),
        .init(id:"body",kind:"Paragraph",from:9,to:20),
        .init(id:"later",kind:"ATXHeading2",from:22,to:30,headingTitle:"Later")
    ],revision:1,length:31)
    let generation=doc.outlineGeneration
    doc.apply(.init(prefix:1,suffix:1,shift:100,blocks:[
        .init(id:"replacement",kind:"Paragraph",from:9,to:120)
    ]),revision:2,length:131)
    #expect(doc.outlineGeneration==generation)
    #expect(try #require(doc.heading(id:BlockID("later"))).range.location==122)
    #expect(doc.heading(at:125)?.id==BlockID("later"))
}
@Test func retainedStyleRecordsUseRelativeOffsetsAfterMultipleEdits() {
    let doc=PreparedDocument()
    doc.adopt([.init(id:"a",kind:"Paragraph",from:0,to:20),.init(id:"b",kind:"Paragraph",from:22,to:42)],revision:1,length:44)
    doc.store(ParseResult(revision:1,spans:[SyntaxSpan(kind:"Emphasis",from:2,to:5),SyntaxSpan(kind:"Emphasis",from:24,to:30)],fragments:[]),range:NSRange(location:0,length:44))
    doc.adopt([.init(id:"new",kind:"Paragraph",from:0,to:25),.init(id:"b",kind:"Paragraph",from:27,to:47)],revision:2,length:49)
    #expect(doc.styles(in:NSRange(location:27,length:20))?.first?.range==NSRange(location:29,length:6))
    #expect(doc.styles(in:NSRange(location:0,length:25))==nil)
    doc.adopt([.init(id:"newer",kind:"Paragraph",from:0,to:15),.init(id:"b",kind:"Paragraph",from:17,to:37)],revision:3,length:39)
    #expect(doc.styles(in:NSRange(location:17,length:20))?.first?.range==NSRange(location:19,length:6))
    doc.adopt([.init(id:"b",kind:"Paragraph",from:0,to:20)],revision:4,length:22)
    #expect(doc.styles(in:NSRange(location:0,length:20))?.map{$0.range}==[NSRange(location:2,length:6)])
}
@Test func giantBlockHTMLAndBoundedStyleCoverageAreIndependent() {
    let doc=PreparedDocument()
    doc.adopt([.init(id:"table",kind:"Table",from:0,to:10000)],revision:1,length:10000)
    doc.store(ParseResult(revision:1,spans:[SyntaxSpan(kind:"StrongEmphasis",from:40,to:60)],fragments:[prepared("table",0,10000,"rows")]),range:NSRange(location:0,length:100))
    #expect(doc.entries(covering:NSRange(location:5000,length:100)) != nil)
    #expect(doc.styles(in:NSRange(location:5000,length:100))==nil)
    #expect(doc.firstUnpreparedOffset(from:0)==100)
    #expect(doc.styles(in:NSRange(location:50,length:20))?.first?.range==NSRange(location:50,length:10))
    doc.store(ParseResult(revision:1,spans:[],fragments:[]),range:NSRange(location:100,length:9900))
    #expect(doc.firstUnpreparedOffset(from:0)==10000)
    #expect(doc.entries(covering:NSRange(location:9000,length:500))?.first?.blockID==BlockID("table"))
}
@Test func overlappingStylePagesPreserveCoverageAndRejectStaleResults() {
    let doc=PreparedDocument()
    doc.adopt([.init(id:"a",kind:"Paragraph",from:0,to:200)],revision:3,length:200)
    doc.store(ParseResult(revision:3,spans:[SyntaxSpan(kind:"Emphasis",from:0,to:100)],fragments:[]),range:NSRange(location:0,length:100))
    doc.store(ParseResult(revision:3,spans:[SyntaxSpan(kind:"Link",from:50,to:150)],fragments:[]),range:NSRange(location:50,length:100))
    let styles=doc.styles(in:NSRange(location:0,length:150))
    #expect(styles?.map{ $0.range }==[NSRange(location:0,length:50),NSRange(location:50,length:100)])
    #expect(doc.firstSyntaxGap(from:0)==150)
    doc.store(ParseResult(revision:2,spans:[],fragments:[prepared("a",0,200,"stale")]),range:NSRange(location:150,length:50))
    #expect(doc.firstSyntaxGap(from:0)==150)
    #expect(doc.entries(covering:NSRange(location:0,length:200))==nil)
}
@Test func sharedDocumentFindsHolesWithoutDiscardingDistantPreparation() {
    let doc=PreparedDocument()
    let blocks=(0..<1000).map{PreparedBlock(id:"\($0)",kind:"Paragraph",from:$0*10,to:($0+1)*10)}
    doc.adopt(blocks,revision:1,length:10000)
    doc.store(ParseResult(revision:1,spans:[],fragments:[prepared("900",9000,9010,"destination")]),range:NSRange(location:9000,length:10))
    #expect(doc.firstUnpreparedOffset(from:0)==0)
    #expect(doc.entries(covering:NSRange(location:9000,length:10))?.first?.blockID==BlockID("900"))
    let fragments=(0..<1000).filter{$0 != 555}.map{prepared("\($0)",$0*10,($0+1)*10,"\($0)")}
    doc.store(ParseResult(revision:1,spans:[],fragments:fragments),range:NSRange(location:0,length:10000))
    #expect(doc.firstUnpreparedOffset(from:0)==5550)
    #expect(doc.firstUnpreparedOffset(from:5560)==10000)
    doc.store(ParseResult(revision:1,spans:[],fragments:[prepared("555",5550,5560,"filled")]),range:NSRange(location:5550,length:10))
    #expect(doc.firstUnpreparedOffset(from:0)==10000)
    #expect(doc.hasCompleteFragments)
}

@Test func renderedWindowsUseCachedHeightPrefixesAndStopAtCacheHoles() {
    let doc=PreparedDocument()
    let blocks=(0..<6).map{PreparedBlock(id:"\($0)",kind:"Paragraph",from:$0*10,to:($0+1)*10)}
    doc.adopt(blocks,revision:1,length:60)
    let fragments=(0..<5).map{prepared("\($0)",$0*10,($0+1)*10,"\($0)")}
    doc.store(ParseResult(revision:1,spans:[],fragments:fragments),range:NSRange(location:0,length:50))
    doc.recordPreviewHeights(["0":10,"1":20,"2":30,"3":40,"4":50],revision:1)

    let single=doc.window(covering:NSRange(location:20,length:10),before:0,after:0)
    #expect(single?.entries.map(\.blockID)==[BlockID("2")])
    #expect(single?.previewTop==46)
    // The unrendered final node still contributes an estimated scrollbar
    // extent, but can never enter the rendered window.
    #expect(single?.previewHeight==218)

    let expanded=doc.window(covering:NSRange(location:20,length:10),before:25,after:500)
    #expect(expanded?.entries.map(\.blockID)==["0","1","2","3","4"].map{BlockID($0)})
    #expect(expanded?.range==NSRange(location:0,length:50))
    #expect(expanded?.previewTop==16)
}

@Test func measuredHeightCorrectionMatchesTheNextRenderedExtent() throws {
    let doc=PreparedDocument()
    doc.adopt([.init(id:"before",kind:"Paragraph",from:0,to:10),
               .init(id:"inserted",kind:"Paragraph",from:12,to:22),
               .init(id:"after",kind:"Paragraph",from:24,to:34)],revision:1,length:35)
    doc.store(ParseResult(revision:1,spans:[],fragments:[
        prepared("before",0,10,"before"),prepared("inserted",12,22,"inserted"),prepared("after",24,34,"after")
    ]),range:NSRange(location:0,length:35))
    let estimated=try #require(doc.window(covering:NSRange(location:12,length:10),before:100,after:100))
    let correction=doc.recordPreviewHeights(["before":33,"inserted":33,"after":33],revision:1)
    let measured=try #require(doc.window(covering:NSRange(location:12,length:10),before:100,after:100))
    #expect(estimated.previewHeight+correction==measured.previewHeight)
    #expect(doc.recordPreviewHeights(["before":33,"inserted":33,"after":33],revision:1)==0)
}
