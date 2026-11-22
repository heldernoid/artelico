import CoreGraphics
import Foundation

// Reading hands steadily: a turned square crop (the hand upright, as hand_landmark_lite was trained) and
// smoothing from frame to frame, as MediaPipe's own hand pipeline does. Without it the square follows the
// pose model's wrist, which moves a few pixels every frame, and all 21 points shake with it.

/// A square in the picture (pixels, centre and side) turned by `angle` radians: turning the picture by
/// `angle` makes the square upright.
public struct RotatedSquare: Sendable, Equatable {
    public var cx: Double, cy: Double, size: Double, angle: Double

    public init(cx: Double, cy: Double, size: Double, angle: Double) {
        self.cx = cx; self.cy = cy; self.size = size; self.angle = angle
    }

    /// A point of the upright `side` x `side` crop (u to the right, v down) in picture pixels.
    public func toPicture(u: Double, v: Double, side: Double) -> CGPoint {
        let scale = size / side
        let x = (u - side / 2) * scale, y = (v - side / 2) * scale
        let c = cos(-angle), s = sin(-angle)
        return CGPoint(x: cx + x * c - y * s, y: cy + x * s + y * c)
    }
}

/// A picture as RGBA bytes (top row first), to cut turned squares out of.
public struct RGBAPixels {
    public let width: Int, height: Int
    let bytes: [UInt8]

    public init?(_ image: CGImage) {
        width = image.width; height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let w = width, h = height
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))   // row 0 of the buffer is the top row
            return true
        }
        guard ok else { return nil }
        bytes = buffer
    }

    /// The square as upright `side` x `side` RGB bytes (bilinear); outside the picture is black.
    public func crop(_ square: RotatedSquare, side: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: side * side * 3)
        let scale = square.size / Double(side), c = cos(-square.angle), s = sin(-square.angle)
        let half = Double(side) / 2
        bytes.withUnsafeBufferPointer { src in
            for v in 0..<side {
                for u in 0..<side {
                    let x = (Double(u) + 0.5 - half) * scale, y = (Double(v) + 0.5 - half) * scale
                    let px = square.cx + x * c - y * s - 0.5, py = square.cy + x * s + y * c - 0.5
                    let x0 = Int(floor(px)), y0 = Int(floor(py))
                    guard x0 >= 0, y0 >= 0, x0 + 1 < width, y0 + 1 < height else { continue }
                    let fx = px - Double(x0), fy = py - Double(y0)
                    let o = (v * side + u) * 3
                    let i00 = (y0 * width + x0) * 4, i10 = i00 + 4, i01 = i00 + width * 4, i11 = i01 + 4
                    for ch in 0..<3 {
                        let top = Double(src[i00 + ch]) * (1 - fx) + Double(src[i10 + ch]) * fx
                        let bottom = Double(src[i01 + ch]) * (1 - fx) + Double(src[i11 + ch]) * fx
                        out[o + ch] = UInt8(clamping: Int((top * (1 - fy) + bottom * fy).rounded()))
                    }
                }
            }
        }
        return out
    }
}

/// The One-Euro filter (Casiez et al. 2012, used by MediaPipe for landmarks): little smoothing when a
/// value moves fast (no lag), a lot when it stands still (no shaking).
public struct OneEuroFilter: Sendable {
    public var minCutoff: Double, beta: Double, derivativeCutoff: Double
    private var value: Double?, speed = 0.0, time: Double?

    public init(minCutoff: Double = 1.0, beta: Double = 0.02, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff; self.beta = beta; self.derivativeCutoff = derivativeCutoff
    }

    private static func alpha(_ dt: Double, _ cutoff: Double) -> Double { 1 / (1 + 1 / (2 * .pi * cutoff * dt)) }

    public mutating func callAsFunction(_ x: Double, time t: Double) -> Double {
        guard let previous = value, let last = time, t > last else { value = x; time = t; return x }
        let dt = t - last
        let a = Self.alpha(dt, derivativeCutoff)
        speed = a * (x - previous) / dt + (1 - a) * speed
        let smoothed = previous + Self.alpha(dt, minCutoff + beta * abs(speed)) * (x - previous)
        value = smoothed; time = t
        return smoothed
    }
}

/// Keeps each hand (person and side) steady from frame to frame: the crop square follows the wrist with a
/// little damping (it jumps when the hand moves far), and the 21 points go through One-Euro filters in
/// picture pixels.
public final class HandSmoother: @unchecked Sendable {
    private struct State {
        var box: RotatedSquare
        var filters: [OneEuroFilter]
        var seen: TimeInterval
    }

    private var states: [String: State] = [:]
    private let lock = NSLock()
    /// How much of the new square is taken each frame (the rest is the previous one).
    public var boxFollow = 0.35

    public init() {}

    func steady(_ box: RotatedSquare, key: String, time: TimeInterval) -> RotatedSquare {
        lock.lock(); defer { lock.unlock() }
        guard var state = states[key] else {
            states[key] = State(box: box, filters: Array(repeating: OneEuroFilter(), count: 42), seen: time)
            return box
        }
        let old = state.box
        var next = box
        // A big jump (fast movement, or a new person) is followed at once.
        if hypot(box.cx - old.cx, box.cy - old.cy) < old.size * 0.5 {
            let k = boxFollow
            next.cx = old.cx + (box.cx - old.cx) * k
            next.cy = old.cy + (box.cy - old.cy) * k
            next.size = old.size + (box.size - old.size) * k
            // Angles through their direction vectors, so -179 and 179 degrees average to 180, not 0.
            let x = cos(old.angle) * (1 - k) + cos(box.angle) * k, y = sin(old.angle) * (1 - k) + sin(box.angle) * k
            next.angle = atan2(y, x)
        }
        state.box = next
        state.seen = time
        states[key] = state
        return next
    }

    func filter(_ points: [CGPoint], key: String, time: TimeInterval, scale: CGSize) -> [CGPoint] {
        lock.lock(); defer { lock.unlock() }
        guard var state = states[key], state.filters.count == points.count * 2 else { return points }
        let w = Double(scale.width), h = Double(scale.height)
        let smoothed = points.enumerated().map { i, p in
            CGPoint(x: state.filters[i * 2](Double(p.x) * w, time: time) / w,
                    y: state.filters[i * 2 + 1](Double(p.y) * h, time: time) / h)
        }
        states[key] = state
        return smoothed
    }

    func forget(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        states[key] = nil
    }

    func dropUnseen(before time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        states = states.filter { $0.value.seen >= time }
    }
}
