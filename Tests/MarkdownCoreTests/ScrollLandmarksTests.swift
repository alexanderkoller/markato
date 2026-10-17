import XCTest
@testable import MarkdownCore

final class ScrollLandmarksTests:XCTestCase {
    private func point(_ x:Double,_ y:Double)->ScrollLandmark {
        ScrollLandmark(offset:Int(x),sourceY:x,previewY:y)
    }
    func testImageTopIsAnExactReferenceAndTravelIsLinear() {
        let map=ScrollLandmarks([point(0,0),point(100,120),point(500,920)])
        XCTAssertEqual(map.previewY(for:100)!,120,accuracy:1e-8)
        for x in stride(from:100.0,through:499,by:0.5) {
            XCTAssertEqual(map.previewY(for:x+0.5)!-map.previewY(for:x)!,1,accuracy:1e-8)
        }
    }
    func testCompressedPassagesAndEdgesNeverReverse() {
        for height in [500.0,850,1600,8000] {
            for viewport in [380.0,760,1190] {
                for ratio in [0.01,0.2,0.4,1,4,20] {
                    let raw=ScrollLandmarks((0...20).map{point(Double($0)*height/20,Double($0)*height/20*ratio)})
                    let map=raw.viewportMap(sourceHeight:height,viewportHeight:viewport,
                        previewHeight:height*ratio)
                    let end=max(0,height-viewport),expected=max(0,height*ratio-viewport)
                    XCTAssertEqual(map.previewY(for:0)!,0,accuracy:1e-8)
                    // A source shorter than its viewport has no scroll domain.
                    XCTAssertEqual(map.previewY(for:end)!,end==0 ? 0:expected,accuracy:1e-8)
                    var previous=map.previewY(for:0)!
                    for step in 1...1000 {
                        let value=map.previewY(for:Double(step)*end/1000)!
                        XCTAssertGreaterThanOrEqual(value+1e-8,previous)
                        XCTAssertGreaterThanOrEqual(value,-1e-8)
                        XCTAssertLessThanOrEqual(value,expected+1e-8)
                        previous=value
                    }
                }
            }
        }
    }
    func testLinearIntervalsHaveConstantGainAndMeetAtReferences() {
        let map=ScrollLandmarks([point(0,0),point(100,50),point(300,650)])
        XCTAssertEqual(map.previewY(for:50)!,25,accuracy:1e-8)
        XCTAssertEqual(map.previewY(for:200)!,350,accuracy:1e-8)
        XCTAssertEqual(map.previewY(for:100)!,50,accuracy:1e-8)
        XCTAssertEqual(map.previewY(for:99.999)!,49.9995,accuracy:1e-8)
        XCTAssertEqual(map.previewY(for:100.001)!,50.003,accuracy:1e-8)
    }
    func testInvalidGeometryCannotBreakOrderingOrProduceNonfiniteResults() {
        let map=ScrollLandmarks([point(100,100),point(0,0),point(50,80),point(75,20),
            ScrollLandmark(offset:1,sourceY:.nan,previewY:10),point(50,90)])
        XCTAssertEqual(map.points.count,4)
        for (a,b) in zip(map.points,map.points.dropFirst()) {
            XCTAssertGreaterThan(b.sourceY,a.sourceY)
            XCTAssertGreaterThanOrEqual(b.previewY,a.previewY)
        }
        XCTAssertNil(map.previewY(for:.infinity))
        XCTAssertNil(ScrollLandmarks([]).previewY(for:0))
    }
    func testReadingAnchorReferenceAndInverseForShortAndLongDocuments() {
        for height in [600.0,1000,2000,8000] {
            let viewport=760.0,end=max(0,height-viewport)
            for step in 0...100 {
                let x=end*Double(step)/100
                let a=ScrollLandmarks.alignmentOffset(at:x,sourceHeight:height,viewportHeight:viewport)
                XCTAssertEqual(ScrollLandmarks.viewportOrigin(for:x+a,sourceHeight:height,viewportHeight:viewport),x,accuracy:1e-8)
            }
            XCTAssertEqual(ScrollLandmarks.alignmentOffset(at:0,sourceHeight:height,viewportHeight:viewport),0,accuracy:1e-8)
            if end>0 {
                XCTAssertEqual(ScrollLandmarks.alignmentOffset(at:end/2,sourceHeight:height,viewportHeight:viewport),
                    viewport*ScrollLandmarks.readingAnchorFraction,accuracy:1e-8)
                XCTAssertEqual(ScrollLandmarks.alignmentOffset(at:end,sourceHeight:height,viewportHeight:viewport),viewport,accuracy:1e-8)
            }
        }
    }
    func testDirectBoundaryInverseAgainstIndependentNumericalSolution() {
        for viewport in [1.0,380,760,1190] {
            for height in [0.0,viewport,viewport+0.01,viewport*1.5,viewport*3,80000] {
                let end=max(0,height-viewport)
                for step in -5...105 {
                    let passage=height*Double(step)/100
                    var low=0.0,high=end
                    for _ in 0..<60 {
                        let middle=(low+high)/2
                        let readingPosition=middle+ScrollLandmarks.alignmentOffset(at:middle,sourceHeight:height,viewportHeight:viewport)
                        if readingPosition<passage {low=middle}else{high=middle}
                    }
                    XCTAssertEqual(ScrollLandmarks.viewportOrigin(for:passage,sourceHeight:height,viewportHeight:viewport),(low+high)/2,accuracy:1e-8)
                }
            }
        }
    }

}
