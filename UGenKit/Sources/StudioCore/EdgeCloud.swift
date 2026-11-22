import Foundation

/// The numbers of the EdgeVsCloud demo (vendor/ref-ugen300-demos/EdgeVsCloud): the same camera picture
/// detected here, measured, next to what sending every frame to a cloud vision API would take.
/// Measured: time per frame here, frames per second, frames so far, the network round trip.
/// Reference values (shown as estimates): the cloud server's time, its price and the power figures.
public struct EdgeCloudComparison: Sendable, Equatable {
    /// Typical server-side time of a cloud vision API, without the network (the demo's value).
    public static let cloudServerMilliseconds = 250.0
    /// Typical price of a cloud image-recognition API: about US$1-1.5 per 1000 pictures.
    public static let cloudDollarsPerThousand = 1.5
    /// Typical power of one cloud inference GPU.
    public static let cloudWatts = 300.0
    /// The UGen300 (Hailo-10H) typical power, from its specification.
    public static let stickWatts = 2.5
    /// The demo's month: 8 hours a day, 22 days.
    public static let secondsPerWorkMonth = 3600.0 * 8 * 22

    /// Time per frame here (milliseconds, model run only).
    public var edgeMilliseconds: Double
    /// Frames per second here.
    public var framesPerSecond: Double
    /// Frames analysed so far.
    public var frames: Int
    /// Time to open a connection to a cloud address (about one network round trip); nil when offline.
    public var connectMilliseconds: Double?

    public init(edgeMilliseconds: Double, framesPerSecond: Double, frames: Int, connectMilliseconds: Double?) {
        self.edgeMilliseconds = edgeMilliseconds
        self.framesPerSecond = framesPerSecond
        self.frames = frames
        self.connectMilliseconds = connectMilliseconds
    }

    /// Network time of one cloud request: two round trips (connection, then the upload and answer), as the demo.
    public var cloudNetworkMilliseconds: Double? { connectMilliseconds.map { $0 * 2 } }
    /// Estimated time per frame in the cloud; nil when offline (the cloud cannot be used).
    public var cloudMilliseconds: Double? { cloudNetworkMilliseconds.map { $0 + Self.cloudServerMilliseconds } }
    /// Frames per second the cloud would manage one after another.
    public var cloudFramesPerSecond: Double? { cloudMilliseconds.map { 1000 / $0 } }
    /// What the frames so far would have cost in the cloud (US$).
    public var cloudDollarsSoFar: Double { Double(frames) * Self.cloudDollarsPerThousand / 1000 }
    /// A month at this speed in the cloud (US$).
    public var cloudDollarsPerMonth: Double { framesPerSecond * Self.secondsPerWorkMonth * Self.cloudDollarsPerThousand / 1000 }
    /// How many times faster per frame it is here (nil when offline or not measured).
    public var speedup: Double? {
        guard let cloud = cloudMilliseconds, edgeMilliseconds > 0 else { return nil }
        return cloud / edgeMilliseconds
    }
}
