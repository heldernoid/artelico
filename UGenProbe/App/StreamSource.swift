import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UGenKit

/// A network stream or a video file.
///
/// Three kinds are handled, chosen from the server's answer:
/// - Video files: read frame by frame and shown in even steps (PacedVideoReader), so motion stays smooth.
/// - HLS (`.m3u8`) and ordinary video addresses: played with AVPlayer.
/// - MJPEG (`multipart/x-mixed-replace`): JPEG frames cut out of the byte stream.
/// - A still image that the camera replaces every few seconds: fetched again and again.
///
/// - RTSP (`rtsp://`): UGenKit's own client, because iPadOS has no built-in RTSP player. It supports
///   H.264 over TCP with Basic or Digest login; cameras that only offer UDP or H.265 are refused with
///   a message that says so.
final class StreamSource: NSObject, FrameSource, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let box = FrameBox()
    private let queue = DispatchQueue(label: "ugen.stream")

    // AVPlayer path
    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var timer: DispatchSourceTimer?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    // Videos store their frames in the sensor's orientation plus a rotation to apply when showing them.
    // The player's frame output ignores that rotation, so it is applied here.
    private var orientation: CGImagePropertyOrientation = .up
    private let imageContext = CIContext()

    // MJPEG / still-image path
    private var session: URLSession?
    private var buffer = Data()
    private var pollTask: Task<Void, Never>?
    private var kindContinuation: CheckedContinuation<Kind, Error>?

    // RTSP path
    private var rtsp: RTSPClient?
    // Video files: read frame by frame and shown in even steps, so motion stays smooth at the model's pace.
    private var paced: PacedVideoReader?

    private enum Kind { case player, mjpeg, still }
    // Road cameras replace their picture every minute or so; asking more often only loads their servers.
    private static let stillInterval: Duration = .seconds(3)
    private static let maxBufferedBytes = 8 * 1024 * 1024

    init(url: URL) {
        self.url = url
    }

    var failure: String? { paced?.failure ?? rtsp?.failure ?? box.failure }

    func takeLatest() -> CGImage? {
        if let paced { return paced.takeLatest() }
        return rtsp?.takeLatest() ?? box.take()
    }

    func start() async throws {
        if url.scheme?.lowercased().hasPrefix("rtsp") == true {
            let client = RTSPClient(url: url)
            rtsp = client
            try await client.start()
            return
        }
        if url.isFileURL {
            let reader = PacedVideoReader(url: url)
            paced = reader
            try await reader.start()
            return
        }
        switch try await detectKind() {
        case .player: try await startPlayer()
        case .mjpeg: break  // the detection request keeps running and delivers frames
        case .still: startPolling()
        }
    }

    func stop() {
        paced?.stop()
        paced = nil
        rtsp?.stop()
        rtsp = nil
        timer?.cancel()
        timer = nil
        player?.pause()
        player = nil
        videoOutput = nil
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        pollTask?.cancel()
        pollTask = nil
        session?.invalidateAndCancel()
        session = nil
        box.clear()
    }

    // MARK: Kind detection (also the MJPEG reader)

    private func detectKind() async throws -> Kind {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        return try await withCheckedThrowingContinuation { continuation in
            queue.sync { self.kindContinuation = continuation }
            session.dataTask(with: url).resume()
        }
    }

    private func resolveKind(_ result: Result<Kind, Error>) {
        queue.sync {
            guard let continuation = kindContinuation else { return }
            kindContinuation = nil
            continuation.resume(with: result)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            resolveKind(.failure(SourceError(description: "The server answered HTTP \(http.statusCode) for this address.")))
            completionHandler(.cancel)
            return
        }
        let type = (response.mimeType ?? "").lowercased()
        if type.contains("multipart/x-mixed-replace") {
            resolveKind(.success(.mjpeg))
            completionHandler(.allow)
        } else if type.hasPrefix("image/") {
            resolveKind(.success(.still))
            completionHandler(.cancel)
        } else {
            resolveKind(.success(.player))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Cut complete JPEGs (FF D8 ... FF D9) out of the multipart stream.
        buffer.append(data)
        let startMarker = Data([0xFF, 0xD8]), endMarker = Data([0xFF, 0xD9])
        while let start = buffer.range(of: startMarker),
              let end = buffer.range(of: endMarker, in: start.upperBound..<buffer.endIndex) {
            let jpeg = buffer.subdata(in: start.lowerBound..<end.upperBound)
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            if let image = Self.decode(jpeg) { box.put(image) }
        }
        if buffer.count > Self.maxBufferedBytes { buffer.removeAll() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled {
            resolveKind(.failure(SourceError(description: "Could not open the stream: \(error.localizedDescription)")))
            box.fail("The stream stopped: \(error.localizedDescription)")
        } else if error == nil {
            resolveKind(.failure(SourceError(description: "The server closed the connection without sending a stream.")))
            box.fail("The stream ended.")
        }
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: Still image, fetched repeatedly

    private func startPolling() {
        let url = self.url
        let box = self.box
        pollTask = Task {
            var failures = 0
            while !Task.isCancelled {
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                if let (data, _) = try? await URLSession.shared.data(for: request), let image = Self.decode(data) {
                    box.put(image)
                    failures = 0
                } else {
                    failures += 1
                    if failures == 5 { box.fail("The camera image could not be fetched five times in a row.") }
                }
                try? await Task.sleep(for: Self.stillInterval)
            }
        }
    }

    // MARK: AVPlayer (HLS, video addresses, video files)

    private func startPlayer() async throws {
        let item = AVPlayerItem(url: url)
        if let track = try? await item.asset.loadTracks(withMediaType: .video).first,
           let transform = try? await track.load(.preferredTransform) {
            let degrees = Int((atan2(transform.b, transform.a) * 180 / .pi).rounded())
            switch (degrees + 360) % 360 {
            case 90: orientation = .right
            case 180: orientation = .down
            case 270: orientation = .left
            default: orientation = .up
            }
        }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        self.player = player
        self.videoOutput = output

        // Wait until the item is ready, or report why it is not.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            self.statusObservation = item.observe(\.status, options: [.initial, .new]) { item, _ in
                guard !resumed else { return }
                switch item.status {
                case .readyToPlay:
                    resumed = true
                    continuation.resume()
                case .failed:
                    resumed = true
                    continuation.resume(throwing: SourceError(description: "This address could not be played: \(item.error?.localizedDescription ?? "unknown error")"))
                default:
                    break
                }
            }
        }

        let box = self.box
        // A video file on the device (the user's or a demo video) plays again from the start; a stream that
        // ends has stopped.
        let loops = url.isFileURL
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: nil) { [weak player] _ in
            if loops, let player {
                player.seek(to: .zero)
                player.play()
            } else {
                box.fail("The video ended.")
            }
        }
        player.play()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))
        timer.setEventHandler { [weak self] in
            guard let self, let output = self.videoOutput, let player = self.player else { return }
            let time = player.currentTime()
            guard output.hasNewPixelBuffer(forItemTime: time),
                  let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
            let image: CGImage?
            if self.orientation == .up {
                image = makeImage(from: pixelBuffer)
            } else {
                let upright = CIImage(cvPixelBuffer: pixelBuffer).oriented(self.orientation)
                image = self.imageContext.createCGImage(upright, from: upright.extent)
            }
            guard let image else { return }
            self.box.put(image)
        }
        timer.resume()
        self.timer = timer
    }
}
