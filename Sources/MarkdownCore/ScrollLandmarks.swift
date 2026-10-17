import Foundation

/// A passage expressed in source and preview coordinates.
public struct ScrollLandmark: Equatable, Sendable {
    public let offset:Int
    public var sourceY:Double
    public var previewY:Double
    public let boundary:Bool
    public init(offset:Int,sourceY:Double,previewY:Double,boundary:Bool=false) {
        self.offset=offset;self.sourceY=sourceY;self.previewY=previewY;self.boundary=boundary
    }
}

/// A monotone piecewise-linear position map. The preview maps
/// viewport origins, so no changing alignment term is subtracted afterward.
public struct ScrollLandmarks: Sendable {
    /// The upper golden-ratio division shared by source and preview.
    public static let readingAnchorFraction=(3-sqrt(5.0))/2
    public private(set) var points:[ScrollLandmark]
    public init(_ input:[ScrollLandmark]) {
        var result=[ScrollLandmark]()
        for var point in input.filter({$0.sourceY.isFinite && $0.previewY.isFinite}).sorted(by:{
            if $0.sourceY != $1.sourceY {return $0.sourceY<$1.sourceY}
            func priority(_ p:ScrollLandmark)->Int {p.boundary ? (p.offset==0 || p.offset==Int.max ? 2:0):1}
            return priority($0)>priority($1)
        }) {
            if let last=result.last {
                if point.sourceY==last.sourceY {continue}
                point.previewY=max(last.previewY,point.previewY)
            }
            result.append(point)
        }
        points=result
    }
    public func previewY(for sourceY:Double)->Double? {
        guard sourceY.isFinite,let first=points.first,let last=points.last else{return nil}
        if sourceY<=first.sourceY {return first.previewY+(sourceY-first.sourceY)*segmentSlope(at:0)}
        if sourceY>=last.sourceY {return last.previewY+(sourceY-last.sourceY)*segmentSlope(at:max(0,points.count-2))}
        var low=0,high=points.count-1
        while low+1<high {
            let middle=(low+high)/2
            if points[middle].sourceY<=sourceY {low=middle}else{high=middle}
        }
        let a=points[low],b=points[high],h=b.sourceY-a.sourceY,t=(sourceY-a.sourceY)/h
        return a.previewY+t*(b.previewY-a.previewY)
    }
    private func segmentSlope(at index:Int)->Double {
        guard points.count>1 else{return 0}
        let a=points[index],b=points[index+1]
        return (b.previewY-a.previewY)/(b.sourceY-a.sourceY)
    }
    /// Solve passageY = viewportY + top/reading-anchor/bottom alignment once per
    /// reference. Interpolation then operates entirely on viewport origins.
    public static func alignmentOffset(at sourceY:Double,sourceHeight:Double,viewportHeight:Double)->Double {
        let viewport=max(1,viewportHeight),end=max(0,sourceHeight-viewport)
        guard end>0 else{return 0}
        let band=min(viewport,end/2),anchor=viewport*readingAnchorFraction
        let top=min(1,max(0,sourceY/band))
        let bottom=min(1,max(0,(sourceY-end+band)/band))
        return top*anchor+bottom*(viewport-anchor)
    }
    public static func viewportOrigin(for passageY:Double,sourceHeight:Double,viewportHeight:Double)->Double {
        let viewport=max(1,viewportHeight),end=max(0,sourceHeight-viewport)
        guard end>0 else{return 0}
        let band=min(viewport,end/2),anchor=viewport*readingAnchorFraction
        let topGain=1+anchor/band,bottomGain=1+(viewport-anchor)/band
        let topEnd=band+anchor,bottomStart=end-band+anchor
        let origin:Double
        if passageY<topEnd {origin=passageY/topGain}
        else if passageY<=bottomStart {origin=passageY-anchor}
        else {origin=(passageY-anchor+(bottomGain-1)*(end-band))/bottomGain}
        return min(end,max(0,origin))
    }
    public func viewportMap(sourceHeight:Double,viewportHeight:Double,previewHeight:Double)->ScrollLandmarks {
        let end=max(0,sourceHeight-viewportHeight),previewEnd=max(0,previewHeight-viewportHeight)
        var converted=points.compactMap {point -> ScrollLandmark? in
            let x=Self.viewportOrigin(for:point.sourceY,sourceHeight:sourceHeight,viewportHeight:viewportHeight)
            if x<=0.000001 || x>=end-0.000001 {return nil}
            return ScrollLandmark(offset:point.offset,sourceY:x,
                previewY:min(previewEnd,max(0,point.previewY-(point.sourceY-x))),boundary:point.boundary)
        }
        converted.append(ScrollLandmark(offset:0,sourceY:0,previewY:0,boundary:true))
        if end>0 {converted.append(ScrollLandmark(offset:Int.max,sourceY:end,previewY:previewEnd,boundary:true))}
        if end==0 {return ScrollLandmarks([ScrollLandmark(offset:0,sourceY:0,previewY:0,boundary:true)])}
        return ScrollLandmarks(converted)
    }
}
