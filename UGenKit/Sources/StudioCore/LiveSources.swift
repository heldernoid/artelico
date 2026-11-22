import Foundation

/// How many sources Live runs at once, and the frame rate of each.
public enum LiveSources {
    /// The most sources one Live run takes (one model shared by all, taking turns on the stick or engine).
    public static let maximum = 4

    /// The limit for a device. Each extra 720p video or stream costs about 80 MB (its player and the frames
    /// copied out of it): Artelico on the Mac grew from 292 MB with one source to 539 MB with four. Devices
    /// with 4 GB or more have room for that next to a model; the 3 GB iPads and iPhones iOS 17 still runs on
    /// are kept to two, so a vision model and four players do not get the app ended for memory.
    public static func limit(physicalMemory: UInt64, isMac: Bool) -> Int {
        if isMac { return maximum }
        // Devices report a little less than their nominal memory (a 4 GB iPhone about 3.7 GiB).
        return physicalMemory >= 3_500 * 1024 * 1024 ? maximum : 2
    }
}

/// Frames per second, overall and per source, measured over windows of half a second.
public struct FrameRateMeter: Sendable {
    public private(set) var total = 0.0
    public private(set) var perSource: [Double]
    private var counts: [Int]
    private var windowStart: TimeInterval?
    private let window: TimeInterval

    public init(sources: Int, window: TimeInterval = 0.5) {
        perSource = Array(repeating: 0, count: sources)
        counts = Array(repeating: 0, count: sources)
        self.window = window
    }

    /// Counts one shown frame of `source`. Returns true when a window closed and the rates changed.
    @discardableResult
    public mutating func tick(source: Int, at now: TimeInterval) -> Bool {
        guard counts.indices.contains(source) else { return false }
        let start = windowStart ?? now
        windowStart = start
        counts[source] += 1
        let elapsed = now - start
        guard elapsed >= window else { return false }
        perSource = counts.map { Double($0) / elapsed }
        total = perSource.reduce(0, +)
        counts = Array(repeating: 0, count: counts.count)
        windowStart = now
        return true
    }
}
