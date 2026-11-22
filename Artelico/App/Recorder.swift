import AVFoundation
import CoreGraphics
import Foundation

/// Writes frames to an H.264 .mp4 in the app's Documents/recordings folder.
final class Recorder {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int
    private let height: Int
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant
    private var lastTime = CMTime.invalid
    private(set) var frameCount = 0
    let url: URL

    static var directory: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func recordings() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "mp4" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Starts a recording sized for `firstFrame`. Dimensions are rounded down to even numbers for H.264.
    init(firstFrame: CGImage, name: String) throws {
        width = firstFrame.width & ~1
        height = firstFrame.height & ~1
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        url = Self.directory.appendingPathComponent("\(formatter.string(from: Date()))_\(name).mp4")
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw SourceError(description: "The video writer could not be set up.") }
        writer.add(input)
        guard writer.startWriting() else { throw SourceError(description: "Recording could not start: \(writer.error?.localizedDescription ?? "unknown error")") }
        writer.startSession(atSourceTime: .zero)
        start = clock.now
    }

    /// Adds one frame, stamped with the time since the recording started. Frames are skipped while the
    /// encoder is busy.
    func append(_ image: CGImage) {
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        var time = CMTime(seconds: seconds, preferredTimescale: 600)
        if lastTime.isValid, time <= lastTime { time = CMTimeAdd(lastTime, CMTime(value: 1, timescale: 600)) }
        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            lastTime = time
            frameCount += 1
        }
    }

    /// Finishes the file. Returns nil if nothing was written.
    func finish() async -> URL? {
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed, frameCount > 0 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }
}
