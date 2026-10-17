import Foundation
import Testing
@testable import MarkdownCore

@Test func layoutNavigationMatchesIndependentPositionsAfterSuffixEdits() {
    let index=LayoutIndex()
    var lines=(0..<4096).map {LayoutIndex.Line(length:1+$0%17,advance:Double(15+$0%7),height:Double(14+$0%7))}
    index.replaceSuffix(at:0,with:lines,origin:16)
    for step in 0..<40 {
        let kept=(step*97)%lines.count
        let offset=lines.prefix(kept).reduce(0){$0+$1.length}
        let replacement=(0..<(100+step)).map {LayoutIndex.Line(length:3+$0%9,advance:Double(18+$0%5),height:Double(17+$0%5))}
        lines=Array(lines.prefix(kept))+replacement
        index.replaceSuffix(at:offset,with:replacement)
        var start=0,y=16.0
        for line in lines {
            let p=index.position(at:start+line.length-1)
            #expect(p?.range==NSRange(location:start,length:line.length))
            #expect(p?.y==y)
            #expect(index.position(atY:y+line.height/2)?.range.location==start)
            start += line.length;y += line.advance
        }
        #expect(index.length==start)
        #expect(index.height==y)
        #expect(index.position(at:index.length)==nil)
        #expect(index.position(atY:index.height+1)==nil)
        #expect(index.treeDepth<24)
    }
}

@Test func layoutPrefixAndDocumentBoundariesStayMeasured() {
    let index=LayoutIndex()
    index.replaceSuffix(at:0,with:[.init(length:4,advance:20,height:18),.init(length:2,advance:18,height:18)],origin:12)
    let before=index.position(at:2)
    index.replaceSuffix(at:4,with:[.init(length:12,advance:40,height:40)])
    #expect(index.position(at:2)==before)
    #expect(index.position(at:10)?.y==32)
    #expect(index.position(atY:31)?.range.location==4)
    index.replaceSuffix(at:4,with:[])
    #expect(index.length==4)
    #expect(index.position(at:4)==nil)
    index.replaceSuffix(at:0,with:[],origin:0)
    #expect(index.count==0)
    #expect(index.position(atY:0)==nil)
}

@Test func estimatedRegionCanBeNavigatedAndRefinedLocally() {
    let index=LayoutIndex()
    index.replaceSuffix(at:0,with:[.init(length:1_000_000,advance:50_000,height:18,estimated:true)],origin:16)
    #expect(index.position(at:500_000)?.y==25_016)
    #expect(index.position(atY:25_016)?.range.location==500_000)
    #expect(index.hasEstimates(in:NSRange(location:400_000,length:10)))
    #expect(index.firstEstimatedRange()==NSRange(location:0,length:1_000_000))
    index.replace(NSRange(location:400_000,length:200),with:[.init(length:100,advance:18,height:18),.init(length:100,advance:18,height:18)])
    #expect(!index.hasEstimates(in:NSRange(location:400_000,length:200)))
    #expect(index.hasEstimates(in:NSRange(location:399_999,length:1)))
    #expect(index.hasEstimates(in:NSRange(location:400_200,length:1)))
    #expect(index.firstEstimatedRange(atOrAfter:400_000)==NSRange(location:400_200,length:599_800))
    #expect(index.length==1_000_000)
    #expect(index.treeDepth<8)
    index.fitEstimatedHeight(to:10_000)
    #expect(abs(index.height-10_000)<0.001)
    #expect(index.position(at:399_999)!.y<index.position(at:400_000)!.y)
}

@Test func localLayoutReplacementShiftsRetainedSuffixByItsMeasuredDelta() {
    let index=LayoutIndex()
    var lines=(0..<8192).map{LayoutIndex.Line(length:5+$0%11,advance:Double(20+$0%3),height:Double(19+$0%3))}
    index.replaceSuffix(at:0,with:lines,origin:16)
    for step in 0..<100 {
        let start=(step*79)%lines.count,end=min(lines.count,start+4)
        let offset=lines.prefix(start).reduce(0){$0+$1.length}
        let length=lines[start..<end].reduce(0){$0+$1.length}
        let replacement=[LayoutIndex.Line(length:3+step,advance:Double(16+step),height:Double(16+step))]
        lines.replaceSubrange(start..<end,with:replacement)
        index.replace(NSRange(location:offset,length:length),with:replacement)
        var position=0,y=16.0
        for line in lines {
            #expect(index.position(at:position)?.y==y)
            #expect(index.position(at:position)?.range.length==line.length)
            position += line.length;y += line.advance
        }
        #expect(index.length==position)
        #expect(index.height==y)
        #expect(index.treeDepth<24)
    }
}
