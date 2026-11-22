import CoreGraphics
import Foundation

/// Steadies tracked boxes and body points from frame to frame. Each frame is detected from scratch, so a
/// box or a knee moves a few pixels even when nothing in the picture moves; drawn over video that reads as
/// shaking. One-Euro filters (as for hands, HandSteadying.swift) smooth a lot while something stands
/// still and hardly at all while it moves fast, so nothing lags behind a real movement.
public struct TrackSmoother: Sendable {
    /// Positions are filtered as if the picture were this many pixels wide and high: the filter's speed
    /// setting is in pixels per second.
    static let scale = 1000.0

    private struct Filters: Sendable {
        var box: [OneEuroFilter]
        var points: [OneEuroFilter]
        var seen: Double
    }

    private var tracks: [Int: Filters] = [:]

    public init() {}

    /// `box` of track `id` at `time` (seconds), steadied.
    public mutating func box(_ box: CGRect, id: Int, time: Double) -> CGRect {
        var filters = tracks[id] ?? Filters(box: Self.boxFilters(), points: [], seen: time)
        let s = Self.scale
        let cx = filters.box[0](Double(box.midX) * s, time: time) / s
        let cy = filters.box[1](Double(box.midY) * s, time: time) / s
        let w = filters.box[2](Double(box.width) * s, time: time) / s
        let h = filters.box[3](Double(box.height) * s, time: time) / s
        filters.seen = time
        tracks[id] = filters
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// `points` of track `id` at `time`, steadied (x and y each filtered).
    public mutating func points(_ points: [CGPoint], id: Int, time: Double) -> [CGPoint] {
        var filters = tracks[id] ?? Filters(box: Self.boxFilters(), points: [], seen: time)
        if filters.points.count != points.count * 2 {
            filters.points = Array(repeating: OneEuroFilter(minCutoff: 1.0, beta: 0.02), count: points.count * 2)
        }
        let s = Self.scale
        let steadied = points.enumerated().map { i, p in
            CGPoint(x: filters.points[2 * i](Double(p.x) * s, time: time) / s,
                    y: filters.points[2 * i + 1](Double(p.y) * s, time: time) / s)
        }
        filters.seen = time
        tracks[id] = filters
        return steadied
    }

    /// Forgets tracks not seen for `seconds`, so a number given again later starts fresh.
    public mutating func forget(notSeenSince time: Double) {
        tracks = tracks.filter { $0.value.seen >= time }
    }

    public mutating func reset() { tracks = [:] }

    /// Boxes move as a whole: the centre follows a little faster than the size, which flickers most.
    private static func boxFilters() -> [OneEuroFilter] {
        [OneEuroFilter(minCutoff: 1.0, beta: 0.02), OneEuroFilter(minCutoff: 1.0, beta: 0.02),
         OneEuroFilter(minCutoff: 0.6, beta: 0.01), OneEuroFilter(minCutoff: 0.6, beta: 0.01)]
    }
}
