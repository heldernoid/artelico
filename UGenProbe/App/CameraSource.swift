import AVFoundation
import CoreGraphics
import VideoToolbox

/// Anything that produces pictures for the live view. Only the newest frame is kept, so a slow model
/// always works on a current picture.
protocol FrameSource: AnyObject, Sendable {
    /// Starts producing frames. Throws a readable error if the source cannot be opened.
    func start() async throws
    func stop()
    /// Returns the newest frame once; nil until another one arrives.
    func takeLatest() -> CGImage?
    /// A problem that happened after starting (for example, the stream ended).
    var failure: String? { get }
}

struct SourceError: Error, CustomStringConvertible {
    let description: String
}

/// Holds the newest frame behind a lock.
final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CGImage?
    private var problem: String?

    func put(_ newImage: CGImage) {
        lock.lock(); image = newImage; lock.unlock()
    }

    func take() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        let current = image
        image = nil
        return current
    }

    func clear() {
        lock.lock(); image = nil; problem = nil; lock.unlock()
    }

    func fail(_ message: String) {
        lock.lock(); problem = message; lock.unlock()
    }

    var failure: String? {
        lock.lock(); defer { lock.unlock() }
        return problem
    }
}

func makeImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
    var image: CGImage?
    VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
    return image
}

/// The iPad's front or back camera.
final class CameraSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let position: AVCaptureDevice.Position
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "ugen.camera")
    private let box = FrameBox()
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var configured = false

    init(position: AVCaptureDevice.Position) {
        self.position = position
    }

    var failure: String? { box.failure }

    func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            throw SourceError(description: "Camera access is off. Allow it in Settings > Apps > Hailo Studio.")
        }
        let ready: Bool = await withCheckedContinuation { continuation in
            queue.async {
                if !self.configured { self.configured = self.configure() }
                if self.configured, !self.session.isRunning { self.session.startRunning() }
                continuation.resume(returning: self.configured)
            }
        }
        guard ready else { throw SourceError(description: "The \(position == .front ? "front" : "back") camera could not be started.") }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
        box.clear()
    }

    func takeLatest() -> CGImage? { box.take() }

    private func configure() -> Bool {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: camera) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.commitConfiguration()
        rotation = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
        return true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Keep the picture upright as the iPad is turned.
        if let angle = rotation?.videoRotationAngleForHorizonLevelCapture,
           connection.isVideoRotationAngleSupported(angle), connection.videoRotationAngle != angle {
            connection.videoRotationAngle = angle
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer), let image = makeImage(from: pixelBuffer) else { return }
        box.put(image)
    }
}
