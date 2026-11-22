import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

/// Decides how far a video file moves on each frame shown.
///
/// Showing "whatever frame is newest when the model is ready" jumps 2, then 4, then 3 frames, as the model's
/// time varies: motion looks jerky. Instead the video always moves on by the same `step`, chosen so it keeps
/// up with real time on average. The step only changes when the video has drifted more than `tolerance`
/// seconds from the clock, so it stays the same for seconds at a time.
public struct FramePacer: Sendable {
    public let frameRate: Double
    public let tolerance: Double
    public private(set) var step = 1
    /// Video time of the frame last shown, from the first one.
    public private(set) var shown = 0.0
    private var start: Double?

    public init(frameRate: Double, tolerance: Double = 0.4) {
        self.frameRate = max(frameRate, 1)
        self.tolerance = tolerance
    }

    /// How many frames to move on when a frame is asked for at `now` (seconds): 0 means "not yet" (the
    /// model is faster than the video, which then plays at its own speed).
    public mutating func advance(now: Double) -> Int {
        guard let start else {
            self.start = now
            return 1
        }
        let elapsed = now - start
        let next = shown + Double(step) / frameRate
        if step == 1, next > elapsed { return 0 }
        if elapsed - next > tolerance {
            step += 1          // falling behind the clock
        } else if next - elapsed > tolerance, step > 1 {
            step -= 1          // running ahead of it
        }
        shown += Double(step) / frameRate
        return step
    }
}

/// A video file read frame by frame (not played), shown in even steps (FramePacer), looping at the end.
/// Frames are decoded a few ahead on a background queue; only the frames shown become pictures.
/// With `sound`, the file's sound plays along, following the frames shown (VideoSound).
public final class PacedVideoReader: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ugen.paced-video")
    private let context = CIContext()
    private var pacer = FramePacer(frameRate: 30)
    private var orientation: CGImagePropertyOrientation = .up
    private var decoded: [(buffer: CVPixelBuffer, seconds: Double)] = []
    private let wantsSound: Bool
    private var sound: VideoSound?
    private var running = false
    private var problem: String?
    /// Frames decoded ahead at most (a few, so memory stays small).
    private static let ahead = 8

    public init(url: URL, sound: Bool = false) {
        self.url = url
        self.wantsSound = sound
    }

    /// Whether the file's sound is playing along (it has a sound track and `sound` was asked for).
    public var playsSound: Bool { lock.withLock { sound != nil } }

    public var failure: String? { lock.withLock { problem } }

    public func start() async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw StudioError.invalidInput("This file has no video.")
        }
        let (rate, transform) = try await track.load(.nominalFrameRate, .preferredTransform)
        let degrees = Int((atan2(transform.b, transform.a) * 180 / .pi).rounded())
        lock.withLock {
            pacer = FramePacer(frameRate: Double(rate > 0 ? rate : 30))
            orientation = [90: .right, 180: .down, 270: .left][(degrees + 360) % 360] ?? .up
            running = true
        }
        if wantsSound, let sound = await VideoSound(url: url) { lock.withLock { self.sound = sound } }
        queue.async { [weak self] in self?.decodeLoop(asset: asset, track: track) }
    }

    public func stop() {
        let sound = lock.withLock { running = false; decoded = []; let s = self.sound; self.sound = nil; return s }
        sound?.stop()
    }

    /// The next frame to show, or nil when none is due yet.
    public func takeLatest() -> CGImage? {
        let chosen: (buffer: CVPixelBuffer, seconds: Double)? = lock.withLock {
            guard !decoded.isEmpty else { return nil }
            let steps = pacer.advance(now: ProcessInfo.processInfo.systemUptime)
            guard steps > 0 else { return nil }
            // Move on `steps` frames; if fewer are decoded yet, show the furthest one (decoding catches up).
            let index = min(steps, decoded.count) - 1
            let chosen = decoded[index]
            decoded.removeFirst(index + 1)
            return chosen
        }
        guard let (buffer, seconds) = chosen else { return nil }
        lock.withLock { sound }?.follow(seconds)
        let image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        return context.createCGImage(image, from: image.extent)
    }

    private func decodeLoop(asset: AVAsset, track: AVAssetTrack) {
        while lock.withLock({ running }) {
            guard let reader = try? AVAssetReader(asset: asset) else { fail("The video could not be read."); return }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            guard reader.startReading() else { fail("The video could not be read: \(reader.error?.localizedDescription ?? "unknown error")."); return }
            var frames = 0
            while lock.withLock({ running }) {
                // Wait while enough frames are ready: the pacer, not the decoder, sets the speed.
                if lock.withLock({ decoded.count >= Self.ahead + pacer.step }) {
                    Thread.sleep(forTimeInterval: 0.003)
                    continue
                }
                guard let sample = output.copyNextSampleBuffer() else { break }   // the end: start again
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                lock.withLock { decoded.append((buffer, seconds.isFinite ? seconds : 0)) }
                frames += 1
            }
            reader.cancelReading()
            if frames == 0 { fail("The video has no frames that can be decoded."); return }
        }
    }

    private func fail(_ message: String) {
        lock.withLock { problem = message; running = false }
    }
}
