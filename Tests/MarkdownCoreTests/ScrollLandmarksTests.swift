import XCTest
@testable import MarkdownCore

final class ScrollLandmarksTests:XCTestCase {
    func testInterpolationKeepsOneSpeedBetweenSparseLandmarks() {
        let map=ScrollLandmarks([
            ScrollLandmark(offset:0,sourceY:100,previewY:200),
            ScrollLandmark(offset:400,sourceY:500,previewY:800),
            ScrollLandmark(offset:800,sourceY:900,previewY:1000)
        ])
        XCTAssertEqual(map.previewY(for:100),200)
        XCTAssertEqual(map.previewY(for:120),230)
        XCTAssertEqual(map.previewY(for:300),500)
        XCTAssertEqual(map.previewY(for:500),800)
        XCTAssertEqual(map.previewY(for:700),900)
        XCTAssertEqual(map.previewY(for:1000),1050)
    }
    func testSourceWindowRebasePreservesFrozenMotion() {
        var map=ScrollLandmarks([
            ScrollLandmark(offset:100,sourceY:10,previewY:30),
            ScrollLandmark(offset:200,sourceY:110,previewY:230)
        ])
        let before=map.previewY(for:60)
        map.rebaseSource(by:4000)
        XCTAssertEqual(map.previewY(for:4060),before)
        XCTAssertEqual(map.previewY(for:4070)!-before!,20,accuracy:1e-9)
    }
    func testNewDOMCoordinatesDoNotReplaceFrozenInteriorLandmarks() {
        var frozen=ScrollLandmarks([
            ScrollLandmark(offset:100,sourceY:100,previewY:200),
            ScrollLandmark(offset:200,sourceY:200,previewY:400)
        ])
        let new=ScrollLandmarks([
            ScrollLandmark(offset:100,sourceY:110,previewY:50),
            ScrollLandmark(offset:150,sourceY:165,previewY:300),
            ScrollLandmark(offset:200,sourceY:220,previewY:450),
            ScrollLandmark(offset:300,sourceY:300,previewY:650)
        ])
        frozen.extend(with:new,previewShift:50)
        XCTAssertEqual(frozen.points.count,3)
        XCTAssertEqual(frozen.previewY(for:150),300)
        XCTAssertEqual(frozen.previewY(for:250),500)
        XCTAssertEqual(frozen.points.last?.previewY,600)
    }
    func testHeadingFreeWindowUsesOnlyItsEdges() {
        let map=ScrollLandmarks([
            ScrollLandmark(offset:500,sourceY:200,previewY:16,boundary:true),
            ScrollLandmark(offset:1000,sourceY:1000,previewY:1516,boundary:true)
        ])
        XCTAssertEqual(map.previewY(for:600),766)
        XCTAssertEqual(map.previewY(for:1100),1703.5)
    }
    func testRealLandmarkWinsOverRegionBoundaryAtSameSourceOffset() {
        let map=ScrollLandmarks([
            ScrollLandmark(offset:0,sourceY:0,previewY:0,boundary:true),
            ScrollLandmark(offset:0,sourceY:0,previewY:16),
            ScrollLandmark(offset:100,sourceY:100,previewY:116,boundary:true)
        ])
        XCTAssertEqual(map.points.count,2)
        XCTAssertFalse(map.points[0].boundary)
        XCTAssertEqual(map.previewY(for:0),16)
    }
    func testEmptyAndInitiallyUnpreparedGestures() {
        var map=ScrollLandmarks([])
        XCTAssertNil(map.previewY(for:0))
        map.extend(with:ScrollLandmarks([ScrollLandmark(offset:10,sourceY:20,previewY:30)]),previewShift:10)
        XCTAssertEqual(map.previewY(for:50),50)
    }
}
