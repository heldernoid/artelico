import CoreGraphics
import Foundation

/// Action recognition on video (r3d_18, Kinetics-400): the model takes a clip of 16 frames at once, as
/// one 112 x 112 input with 48 channels (frame after frame, red, green, blue in each), and names the
/// action in it. `VideoClip` keeps the latest frames of a live source; one picture alone is repeated 16
/// times, which shows the model no motion: it then guesses from the scene only (approximate).
public struct VideoClip: Sendable {
    public static let frameCount = 16
    /// Frames are taken at most this often. torchvision trained r3d_18 on 16 consecutive frames at 15
    /// per second; the Model Zoo spreads its 16 evenly over each 10-second Kinetics clip
    /// (create_kinetics400_tfrecord.py, about 1.6 per second). On Hailo's demo videos 12 per second
    /// (1.3 seconds per clip) gave the steadiest answers (grok-squats.mp4: "squat" first in all 8 answers,
    /// 0.63-1.00; at 8 per second 4 of 5, at 4 per second 1 of 2).
    public static let framesPerSecond = 12.0
    /// A new answer every this many new frames (twice in 1.3 seconds).
    public static let framesPerAnswer = 8

    private var frames: [[UInt8]] = []
    private var nextTime: Double?
    private var sinceAnswer = 0
    /// The latest answer, shown until the next one.
    public var actions: [Classification] = []

    public init() {}

    /// Adds a live frame taken at `time` (seconds). Returns the model input when a new answer is due.
    public mutating func add(_ image: CGImage, at time: Double, model: ModelInfo) -> [UInt8]? {
        let step = 1 / Self.framesPerSecond
        // Frames are taken on a steady beat (up to 10 ms early counts), so a 24 or 30 per second source
        // averages 12. After a pause the beat starts again; a clock that went back (a video starting
        // over) restarts it.
        if let due = nextTime, time >= due - 2 * step, time < due - 0.01 { return nil }
        guard let frame = Self.frame(image) else { return nil }
        let beat = (nextTime ?? time) + step
        nextTime = beat < time || beat - time > 2 * step ? time + step : beat
        frames.append(frame)
        if frames.count > Self.frameCount { frames.removeFirst(frames.count - Self.frameCount) }
        sinceAnswer += 1
        guard frames.count == Self.frameCount, actions.isEmpty || sinceAnswer >= Self.framesPerAnswer else { return nil }
        sinceAnswer = 0
        return Self.input(frames, model: model)
    }

    /// One picture repeated as a whole clip.
    public static func still(_ image: CGImage, model: ModelInfo) throws -> PreparedFrame {
        guard let frame = frame(image) else { throw StudioError.invalidInput("Could not read the picture.") }
        return PreparedFrame(rgb: input(Array(repeating: frame, count: frameCount), model: model), width: side, height: side,
                             sourceWidth: image.width, sourceHeight: image.height, contentRect: CGRect(x: 0, y: 0, width: side, height: side))
    }

    /// The five most likely actions.
    public static func actions(_ tensor: Tensor) -> [Classification] {
        PostProcess.classifications(tensor, labels: Labels.kinetics400)
    }

    // MARK: Input

    static let side = 112
    /// r3d_18_preprocessing: each frame resized (stretched) to 171 x 128, the middle 112 x 112 kept.
    static let resized = (width: 171.0, height: 128.0)
    /// Kinetics' channel means and deviations (the same function).
    static let mean: [Float] = [110.2008, 100.63983, 95.99475]
    static let std: [Float] = [58.14765, 56.46975, 55.332195]

    /// The frame as 112 x 112 RGB: resize to 171 x 128 (bilinear, no antialiasing, rounded) and crop
    /// the centre (rows 8..., columns 29...), in one step.
    static func frame(_ image: CGImage) -> [UInt8]? {
        guard let pixels = RGBAPixels(image) else { return nil }
        let sx = Double(image.width) / resized.width, sy = Double(image.height) / resized.height
        let left = Double((Int(resized.width) - side) / 2), top = Double((Int(resized.height) - side) / 2)
        return pixels.warp(width: side, height: side, x: (sx, (left + 0.5) * sx - 0.5), y: (sy, (top + 0.5) * sy - 0.5))
    }

    /// The clip in the stick's input format: normalized on the host (the model has no normalization
    /// layer) and quantized with the input's zero point and scale; channel = frame x 3 + colour.
    static func input(_ frames: [[UInt8]], model: ModelInfo) -> [UInt8] {
        let stream = model.inputs[0]
        let scale = stream.qpScale ?? 1, zero = stream.qpZp ?? 0
        let pixels = side * side, channels = 3 * frames.count
        var out = [UInt8](repeating: 0, count: pixels * channels)
        for (t, frame) in frames.enumerated() {
            for i in 0..<pixels {
                for c in 0..<3 {
                    let value = (Float(frame[i * 3 + c]) - mean[c]) / std[c]
                    out[i * channels + t * 3 + c] = UInt8(clamping: Int((value / scale + zero).rounded()))
                }
            }
        }
        return out
    }
}
