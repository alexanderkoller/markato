import Foundation

/// Coordinates in a source/preview reference frame. `offset` identifies the
/// same passage across replacement of either pane's working window.
public struct ScrollLandmark: Equatable, Sendable {
    public let offset:Int
    public var sourceY:Double
    public var previewY:Double
    public let boundary:Bool
    public init(offset:Int,sourceY:Double,previewY:Double,boundary:Bool=false) {
        self.offset=offset;self.sourceY=sourceY;self.previewY=previewY;self.boundary=boundary
    }
}

public struct ScrollLandmarks: Sendable {
    public private(set) var points:[ScrollLandmark]
    public init(_ points:[ScrollLandmark]) {
        var seen=Set<Int>()
        self.points=points.sorted {
            $0.offset == $1.offset ? !$0.boundary && $1.boundary : $0.offset<$1.offset
        }.filter {
            $0.sourceY.isFinite && $0.previewY.isFinite && seen.insert($0.offset).inserted
        }
    }
    /// Interpolate between reference points; continue the outermost slope when
    /// a gesture briefly advances beyond the currently prepared region.
    public func previewY(for sourceY:Double)->Double? {
        guard let first=points.first else{return nil}
        guard points.count>1 else{return first.previewY+sourceY-first.sourceY}
        var low=0,high=points.count-1
        while low+1<high {
            let middle=(low+high)/2
            if points[middle].sourceY<=sourceY {low=middle}else{high=middle}
        }
        let a=points[low],b=points[high]
        let fraction=(sourceY-a.sourceY)/max(1,b.sourceY-a.sourceY)
        return a.previewY+(b.previewY-a.previewY)*fraction
    }
    /// Moving the native source working window changes its coordinate origin,
    /// not the frozen distances between landmarks.
    public mutating func rebaseSource(by delta:Double) {
        for index in points.indices {points[index].sourceY += delta}
    }
    /// Keep every captured coordinate. Only extend beyond the frozen region;
    /// interior layout reports must not change its slopes during a gesture.
    public mutating func extend(with next:ScrollLandmarks,previewShift:Double) {
        guard let first=points.first,let last=points.last else {
            points=next.points.map {var p=$0;p.previewY -= previewShift;return p};return
        }
        let extra=next.points.filter{!$0.boundary}
            .map {var p=$0;p.previewY -= previewShift;return p}
        points.insert(contentsOf:extra.filter{$0.offset<first.offset},at:0)
        points.append(contentsOf:extra.filter{$0.offset>last.offset})
    }
}
