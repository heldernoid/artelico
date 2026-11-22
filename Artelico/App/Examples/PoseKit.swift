import AVFoundation
import PhotosUI
import SwiftUI
import StudioCore

// Shared parts of the pose examples (ported from the UGen300 demos): a camera or video runs through a
// pose model on this device, every frame's people go to the example's rules (StudioCore/PoseGames.swift).

// MARK: - Sound

/// Short synthesized notes, chimes and an alarm (no sound files). Sine through a soft clipper, like the
/// air-instrument demo, with a short fade in and out so there are no clicks.
@MainActor
final class ToneSynth {
    static let shared = ToneSynth()

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var started = false

    /// Do re mi sol la do' re' mi' (pentatonic-ish, pleasant in any order).
    static let scale: [Double] = [261.63, 293.66, 329.63, 392.00, 440.00, 523.25, 587.33, 659.25]

    private func start() {
        guard !started else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        for _ in 0..<8 {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            players.append(player)
        }
        do { try engine.start(); started = true } catch { started = false }
    }

    private func buffer(_ frequency: Double, seconds: Double, bright: Bool, volume: Float) -> AVAudioPCMBuffer {
        let rate = format.sampleRate
        let count = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        let data = buffer.floatChannelData![0]
        let attack = Int(rate * 0.005), release = Int(rate * 0.04)
        for i in 0..<Int(count) {
            let t = Double(i) / rate
            let sine = sin(2 * .pi * frequency * t)
            var value = bright ? tanh(4 * sine) / tanh(4) : sine
            if !bright { value += 0.3 * sin(4 * .pi * frequency * t) }   // a soft overtone
            var envelope = 1.0
            if i < attack { envelope = Double(i) / Double(attack) }
            if i > Int(count) - release { envelope = Double(Int(count) - i) / Double(release) }
            if !bright { envelope *= exp(-3 * t / seconds) }
            data[i] = Float(value * envelope) * volume
        }
        return buffer
    }

    func play(_ frequency: Double, seconds: Double = 0.25, bright: Bool = false, volume: Float = 0.5, delay: Double = 0) {
        start()
        guard started else { return }
        let player = players[next]
        next = (next + 1) % players.count
        let b = buffer(frequency, seconds: seconds, bright: bright, volume: volume)
        if delay > 0 {
            let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: delay))
            player.scheduleBuffer(b, at: when, options: [], completionHandler: nil)
        } else {
            player.scheduleBuffer(b, completionHandler: nil)
        }
        if !player.isPlaying { player.play() }
    }

    private var cache: [String: AVAudioPCMBuffer] = [:]

    /// Plays synthesized samples (made once per `key`, then cached).
    func play(key: String, volume: Float = 0.6, seconds: Double, make: (Double, Int) -> [Float]) {
        start()
        guard started else { return }
        let buffer: AVAudioPCMBuffer
        if let cached = cache[key] {
            buffer = cached
        } else {
            let rate = format.sampleRate
            let count = Int(rate * seconds)
            var samples = make(rate, count)
            let peak = samples.map(abs).max() ?? 1
            if peak > 0 { samples = samples.map { $0 / peak * volume } }
            buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { buffer.floatChannelData![0][i] = samples[i] }
            cache[key] = buffer
        }
        let player = players[next]
        next = (next + 1) % players.count
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    /// Air band instruments, as in the demo: piano (4 harmonics), plucked string (Karplus-Strong), drums.
    func piano(_ f: Double) {
        play(key: "piano\(f)", volume: 0.5, seconds: 1.2) { rate, n in
            (0..<n).map { i in
                let t = Double(i) / rate
                let tone = (0..<4).reduce(0.0) { $0 + pow(0.6, Double($1)) * sin(2 * .pi * f * Double($1 + 1) * t) }
                return Float(tone * min(1, t / 0.004) * exp(-t / 0.45))
            }
        }
    }

    func pluck(_ f: Double) {
        play(key: "pluck\(f)", volume: 0.35, seconds: 1.0) { rate, n in
            let period = max(2, Int(rate / f))
            var ring = (0..<period).map { _ in Float.random(in: -1...1) }
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let j = i % period
                out[i] = ring[j]
                ring[j] = 0.5 * (ring[j] + ring[(j + 1) % period]) * 0.996
            }
            return out
        }
    }

    func drum(_ kind: String) {
        play(key: "drum" + kind, volume: 0.7, seconds: 0.4) { rate, n in
            (0..<n).map { i in
                let t = Double(i) / rate
                switch kind {
                case "kick": return Float(sin(2 * .pi * (60 + 80 * exp(-t * 30)) * t) * exp(-t * 9))
                case "snare": return Float((Double.random(in: -1...1) * 0.6 + sin(2 * .pi * 180 * t) * 0.4) * exp(-t * 14))
                default: return Float(Double.random(in: -1...1) * exp(-t * 40) * 0.6)
                }
            }
        }
    }

    /// A rising arpeggio for a success.
    func chime() {
        for (i, f) in [523.25, 659.25, 783.99, 1046.5].enumerated() { play(f, seconds: 0.35, volume: 0.45, delay: Double(i) * 0.09) }
    }

    /// A short "tick" for a counted repetition.
    func tick() { play(880, seconds: 0.12, bright: true, volume: 0.35) }

    /// One beat of the alarm: two bright beeps.
    func alarmBeat() {
        play(988, seconds: 0.18, bright: true, volume: 0.7)
        play(988, seconds: 0.18, bright: true, volume: 0.7, delay: 0.25)
    }
}

// MARK: - Runner

enum PoseSourceKind: String, CaseIterable, Identifiable {
    case front = "Front camera"
    case back = "Back camera"
    case video = "Video file"
    case stream = "Stream address"
    case picture = "Photo"
    var id: String { rawValue }
}

/// A still picture repeated as a stream (testing from the Mac: `-posesample bus.jpg`).
final class StillSource: FrameSource, @unchecked Sendable {
    let image: CGImage
    private var last = Date.distantPast
    init(image: CGImage) { self.image = image }
    func start() async throws {}
    func stop() {}
    func takeLatest() -> CGImage? {
        guard Date().timeIntervalSince(last) > 1.0 / 15 else { return nil }
        last = Date()
        return image
    }
    var failure: String? { nil }
}

/// One analysed frame, in display coordinates (mirrored for the front camera).
struct PoseFrame {
    let image: CGImage
    /// People, positions as fractions of the picture as shown.
    let poses: [Pose]
    /// Objects from the optional second model (Classroom's phones), same coordinates.
    let detections: [Detection]
    /// Faces with their identity vectors (face task), same coordinates.
    var faces: [(face: Face, embedding: [Float])] = []
    /// Hands (21 points each), same coordinates, when the runner was started with `hands: true`.
    var hands: [HandPoints] = []
    let time: TimeInterval
    /// How long the main model took on this frame (milliseconds), for EdgeVsCloud.
    var inferenceMilliseconds: Double = 0
    var aspect: Double { Double(image.width) / Double(max(image.height, 1)) }

    /// People in demo pixels (`width` wide), ready for the rules.
    func bodies(width: Double = 640) -> [BodyPose] { poses.map { BodyPose($0, aspect: aspect, width: width) } }

    /// The person taking up the most room (the one the single-person examples follow).
    var mainPose: Pose? { poses.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height } }
}

@MainActor
final class PoseRunner: ObservableObject {
    @Published var image: CGImage?
    @Published var poses: [Pose] = []
    @Published var detections: [Detection] = []
    @Published var faces: [Face] = []
    @Published var hands: [HandPoints] = []
    @Published var framesPerSecond = 0.0
    @Published var message = ""
    @Published var running = false
    @Published var mirrored = false
    /// Keeps the last picture and results on screen and skips new frames.
    @Published var paused = false
    @Published var source: PoseSourceKind = .front
    @Published var videoURL: URL?
    @Published var picture: CGImage?
    /// The bundled sample picture or demo video in use (for its credit tag); nil for the camera or own files.
    @Published var sampleFile: String?
    /// The sample shown now, if the source is that sample.
    var shownSample: String? {
        guard let sampleFile else { return nil }
        return SampleMedia.isVideo(sampleFile) ? (source == .video ? sampleFile : nil) : (source == .picture ? sampleFile : nil)
    }
    @Published var streamAddress: String = UserDefaults.standard.string(forKey: "examples.stream") ?? "" {
        didSet { UserDefaults.standard.set(streamAddress, forKey: "examples.stream") }
    }
    /// The main model: a pose model, or a detector for the detection examples.
    let task: VisionTask
    @Published var modelName: String {
        didSet { UserDefaults.standard.set(modelName, forKey: "examples.model.\(task.rawValue)") }
    }

    private var loop: Task<Void, Never>?
    /// Keeps the hands' crop squares and points steady from frame to frame.
    private let handSmoother = HandSmoother()

    init(task: VisionTask = .pose, source: PoseSourceKind = .front) {
        self.task = task
        self.source = source
        modelName = UserDefaults.standard.string(forKey: "examples.model.\(task.rawValue)")
            ?? (task == .pose ? "yolov8s_pose" : task == .face ? "scrfd_10g" : task == .instanceSegmentation ? "yolov8s_seg" : "yolov8s")
    }

    /// Models for the task that run here, the ones on this device first. Face screens recognise people,
    /// so they offer only face detectors that find landmarks (not LightFace).
    func models(installed: Set<String>) -> [ModelInfo] {
        let all = ModelCatalog.models(for: task.rawValue).filter {
            VisionPipeline.supports(task, model: $0) && (task != .face || FaceRecognition.findsLandmarks($0))
        }
        return all.filter { installed.contains($0.name) } + all.filter { !installed.contains($0.name) }
    }

    func stop() { loop?.cancel() }

    /// Starts the camera (or video) and calls `handle` with every analysed frame. `detector` adds a second
    /// model whose detections come with each frame. `extra` models are loaded when they are here; `required`
    /// ones are downloaded if needed. `filter` changes each frame before it is shown or handed on (Privacy
    /// camera), from the frame and the main model's instance masks.
    func start(studio: StudioModel, detector: ModelInfo? = nil, extra: [ModelInfo] = [], required: [ModelInfo] = [], hands: Bool = false,
               filter: (@MainActor (CGImage, [Instance]) async throws -> CGImage)? = nil,
               handle: @escaping @MainActor (PoseFrame) -> Void) {
        guard loop == nil else { return }
        if !studio.canUse(modelName), let first = models(installed: studio.installed).first(where: { studio.canUse($0.name) }) {
            modelName = first.name
        }
        guard let model = ModelCatalog.model(named: modelName) else { message = "Choose a model."; return }
        message = ""
        running = true
        loop = Task {
            var frameSource: FrameSource?
            do {
                let source = try makeSource()
                frameSource = source
                mirrored = self.source == .front && !CommandLine.arguments.contains("-posesample")
                studio.liveRunning = true
                try await studio.prepare(model, task: task)
                if let detector, studio.canUse(detector.name) {
                    try await studio.loadExtra(detector)
                }
                let handModel = hands ? ModelCatalog.model(named: HandReader.modelName) : nil
                if hands, handModel == nil || !studio.canUse(HandReader.modelName) {
                    throw SourceError(description: "The hand model \(HandReader.modelName) is not on this \(StudioModel.deviceKind).")
                }
                for item in extra + [handModel].compactMap({ $0 }) where studio.canUse(item.name) {
                    try await studio.loadExtra(item)
                }
                for item in required { try await studio.loadExtra(item) }
                try await source.start()
                try await run(model: model, detector: detector.flatMap { studio.canUse($0.name) ? $0 : nil },
                              hands: hands, device: studio.exampleEngine, source: source, filter: filter, handle: handle)
            } catch is CancellationError {
            } catch {
                message = "Stopped: \(error)"
            }
            frameSource?.stop()
            studio.liveRunning = false
            running = false
            image = nil
            poses = []
            detections = []
            faces = []
            self.hands = []
            loop = nil
        }
    }

    private func makeSource() throws -> FrameSource {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "-posesample"), index + 1 < arguments.count {
            let name = arguments[index + 1]
            guard let url = Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: (name as NSString).pathExtension),
                  let data = try? Data(contentsOf: url), let provider = CGDataProvider(data: data as CFData),
                  let picture = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                    ?? CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
                throw SourceError(description: "Sample \(name) not found.")
            }
            return StillSource(image: picture)
        }
        switch source {
        case .front: return CameraSource(position: .front)
        case .back: return CameraSource(position: .back)
        case .video:
            guard let videoURL else { throw SourceError(description: "Choose a video first.") }
            return StreamSource(url: videoURL)
        case .stream:
            let trimmed = streamAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
                throw SourceError(description: "Enter a full address starting with https://, http:// or rtsp://.")
            }
            return StreamSource(url: url)
        case .picture:
            guard let picture else { throw SourceError(description: "Choose a photo first.") }
            return StillSource(image: picture)
        }
    }

    private func run(model: ModelInfo, detector: ModelInfo?, hands handsWanted: Bool = false, device: any InferenceEngine, source: FrameSource,
                     filter: (@MainActor (CGImage, [Instance]) async throws -> CGImage)?,
                     handle: @escaping @MainActor (PoseFrame) -> Void) async throws {
        var tracker = ObjectTracker()
        let clock = ContinuousClock()
        let started = clock.now
        var windowStart = clock.now
        var windowFrames = 0
        while !Task.isCancelled {
            if paused {
                _ = source.takeLatest()
                try await Task.sleep(for: .milliseconds(30))
                continue
            }
            guard let frame = source.takeLatest() else {
                if let problem = source.failure { throw SourceError(description: problem) }
                try await Task.sleep(for: .milliseconds(3))
                continue
            }
            var found: [Pose] = []
            var objects: [Detection] = []
            var people: [(face: Face, embedding: [Float])] = []
            var instances: [Instance] = []
            var inferenceMilliseconds = 0.0
            if task == .face {
                people = try await FaceRecognition.describe(frame, device: device)
            } else if task == .pose, TopDownPose.isTopDown(model) {
                // A single-person model: the person detector, then one run per person (all counted).
                let inferStart = clock.now
                let list = try await TopDownPose.run(frame, model: model, device: device)
                let inferTime = clock.now - inferStart
                inferenceMilliseconds = Double(inferTime.components.seconds) * 1000 + Double(inferTime.components.attoseconds) / 1e15
                if case .poses(let tracked) = tracker.track(.poses(list)) { found = tracked }
            } else {
                let prepared = try VisionPipeline.prepare(frame, for: model, task: task)
                let inferStart = clock.now
                let tensors = try await device.infer(inputs: [prepared.rgb], model: model.name)
                let inferTime = clock.now - inferStart
                inferenceMilliseconds = Double(inferTime.components.seconds) * 1000 + Double(inferTime.components.attoseconds) / 1e15
                switch VisionPipeline.decode(tensors, task: task, model: model, frame: prepared) {
                case .poses(let list):
                    if case .poses(let tracked) = tracker.track(.poses(list)) { found = tracked }
                case .detections(let list):
                    objects = list   // untracked: the examples follow objects themselves
                case .instances(let list):
                    instances = list
                    objects = list.map(\.detection)
                default:
                    break
                }
            }
            if let detector {
                let preparedObjects = try VisionPipeline.prepare(frame, for: detector, task: .detection)
                let raw = try await device.infer(inputs: [preparedObjects.rgb], model: detector.name)
                if case .detections(let list) = VisionPipeline.decode(raw, task: .detection, model: detector, frame: preparedObjects) { objects = list }
            }
            var handList: [HandPoints] = []
            if handsWanted {
                let now = clock.now - started
                handList = try await HandReader.read(frame, poses: found, device: device, smoother: handSmoother,
                                                     time: Double(now.components.seconds) + Double(now.components.attoseconds) / 1e18)
            }
            if mirrored {
                found = found.map(Self.mirror)
                objects = objects.map(Self.mirror)
                people = people.map { (Self.mirror($0.face), $0.embedding) }
                handList = handList.map { $0.mirrored() }
            }
            // Filtered in the camera's own orientation, before anything is shown.
            let shown = try await filter?(frame, instances) ?? frame
            let elapsed = clock.now - started
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            image = shown
            poses = found
            detections = objects
            faces = people.map(\.face)
            hands = handList
            handle(PoseFrame(image: shown, poses: found, detections: objects, faces: people, hands: handList, time: seconds,
                             inferenceMilliseconds: inferenceMilliseconds))

            windowFrames += 1
            let window = clock.now - windowStart
            if window >= .milliseconds(500) {
                framesPerSecond = Double(windowFrames) / (Double(window.components.seconds) + Double(window.components.attoseconds) / 1e18)
                windowStart = clock.now
                windowFrames = 0
            }
        }
    }

    static func mirror(_ pose: Pose) -> Pose {
        var copy = Pose(confidence: pose.confidence,
                        boundingBox: CGRect(x: 1 - pose.boundingBox.maxX, y: pose.boundingBox.minY, width: pose.boundingBox.width, height: pose.boundingBox.height),
                        keypoints: pose.keypoints.map { Pose.Keypoint(position: CGPoint(x: 1 - $0.position.x, y: $0.position.y), confidence: $0.confidence) })
        copy.trackID = pose.trackID
        return copy
    }

    static func mirror(_ f: Face) -> Face {
        Face(boundingBox: CGRect(x: 1 - f.boundingBox.maxX, y: f.boundingBox.minY, width: f.boundingBox.width, height: f.boundingBox.height),
             confidence: f.confidence, landmarks: f.landmarks.map { CGPoint(x: 1 - $0.x, y: $0.y) }, name: f.name)
    }

    static func mirror(_ d: Detection) -> Detection {
        Detection(label: d.label, classIndex: d.classIndex, confidence: d.confidence,
                  boundingBox: CGRect(x: 1 - d.boundingBox.maxX, y: d.boundingBox.minY, width: d.boundingBox.width, height: d.boundingBox.height))
    }
}

// MARK: - Views

/// Source and model choice, Start/Stop and the frame rate, above every pose example.
struct PoseControls: View {
    @ObservedObject var runner: PoseRunner
    @EnvironmentObject private var studio: StudioModel
    @State private var pickedVideo: PhotosPickerItem?
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showCameras = false
    @StateObject private var catalog = StreamCatalog()
    /// Sources this example offers.
    var sources: [PoseSourceKind] = [.front, .back, .video]
    /// Bundled sample photos offered next to "Choose a photo" (file names in Samples).
    var samples: [(title: String, file: String)] = []
    let start: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Picker("Source", selection: $runner.source) {
                    ForEach(sources) { Text($0.rawValue).tag($0) }
                }
                if runner.source == .video {
                    PhotosPicker(runner.videoURL == nil ? "Choose a video" : "Other video", selection: $pickedVideo, matching: .videos)
                    VideoSoundButton(file: runner.videoURL)
                }
                if runner.source == .picture {
                    PhotosPicker(runner.picture == nil ? "Choose a photo" : "Other photo", selection: $pickedPhoto, matching: .images)
                }
                // Sample pictures (when the example takes photos) and Hailo's demo videos.
                let offered = samples.filter { SampleMedia.isVideo($0.file) ? sources.contains(.video) : sources.contains(.picture) }
                if !offered.isEmpty {
                    Menu("Samples") {
                        ForEach(offered, id: \.file) { sample in
                            Button(sample.title) { useSample(sample.file) }
                        }
                    }
                }
                if runner.source == .stream {
                    TextField("https://… or rtsp://…", text: $runner.streamAddress)
                        .textFieldStyle(.roundedBorder).frame(width: 260)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { showCameras = true } label: { Label("Road cameras", systemImage: "road.lanes") }
                    VideoSoundButton(stream: true)
                }
                Picker("Model", selection: $runner.modelName) {
                    ForEach(runner.models(installed: studio.installed)) { model in
                        Text(studio.modelLabel(model.name)).tag(model.name)
                    }
                }
                if runner.running {
                    Text(String(format: "%.0f FPS", runner.framesPerSecond)).font(.callout.monospacedDigit().bold())
                }
                Button(runner.running ? "Stop" : "Start") { runner.running ? runner.stop() : start() }
                    .buttonStyle(.borderedProminent)
                    .tint(runner.running ? .red : .accentColor)
            }
            .pickerStyle(.menu)
            .padding(.horizontal)
        }
        .onChange(of: pickedVideo) { _, item in
            Task { if let movie = try? await item?.loadTransferable(type: PickedMovie.self) { runner.videoURL = movie.url; runner.sampleFile = nil } }
        }
        .onChange(of: pickedPhoto) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    runner.picture = image.uprightCGImage
                    runner.sampleFile = nil
                }
            }
        }
        .sheet(isPresented: $showCameras) {
            CameraListView(catalog: catalog) { camera in runner.streamAddress = camera.url }
        }
        #if DEBUG
        // Testing: `-samplevideo grok-squats.mp4` plays that demo video when the example opens.
        .task {
            if let index = CommandLine.arguments.firstIndex(of: "-samplevideo"), index + 1 < CommandLine.arguments.count, !runner.running {
                useSample(CommandLine.arguments[index + 1])
            }
        }
        #endif
    }

    /// Shows a bundled sample photo, or a demo video (downloaded the first time), as a preview. A running example
    /// switches to it; a stopped one waits for Start, so choosing a sample never loads or downloads a model.
    /// (Web counterpart: the Samples menu in web/js/ui/examples/kit.js.)
    private func useSample(_ file: String) {
        Task {
            let wasRunning = runner.running
            if SampleMedia.isVideo(file) {
                if wasRunning { runner.stop() }
                while runner.running { try? await Task.sleep(for: .milliseconds(20)) }
                runner.message = "Downloading the sample video…"
                do {
                    let url = try await SampleMedia.localVideo(file)
                    runner.message = ""
                    runner.source = .video
                    runner.videoURL = url
                    runner.sampleFile = file
                    if wasRunning { start() } else { await preview(Self.firstFrame(url)) }
                } catch {
                    runner.message = "\(error)"
                }
                return
            }
            let parts = file.split(separator: ".")
            guard parts.count == 2, let url = Bundle.main.url(forResource: String(parts[0]), withExtension: String(parts[1])),
                  let image = UIImage(contentsOfFile: url.path)?.uprightCGImage else { return }
            runner.source = .picture
            runner.picture = image
            runner.sampleFile = file
            guard wasRunning else { await preview(image); return }
            // A running example keeps the old picture: let it finish, then start again on the sample.
            runner.stop()
            while runner.running { try? await Task.sleep(for: .milliseconds(20)) }
            start()
        }
    }

    /// The first picture of a video, upright, for its preview.
    private static func firstFrame(_ url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        return try? await generator.image(at: .zero).image
    }

    /// The sample shown before Start, with what Start will do.
    private func preview(_ image: CGImage?) async {
        runner.mirrored = false
        runner.poses = []; runner.detections = []; runner.faces = []; runner.hands = []
        runner.image = image
        runner.message = studio.installed.contains(runner.modelName)
            ? "Press Start to run \(runner.modelName) on it."
            : "Press Start to download \(runner.modelName) and run it."
    }
}

/// The camera picture with the skeletons, plus the example's own drawing on top (in display coordinates:
/// `overlay` gets the size of the picture as shown).
struct PoseStage<Overlay: View>: View {
    @ObservedObject var runner: PoseRunner
    var tint: (Int, Pose) -> Color = { index, _ in Color(cgColor: VisionRenderer.color(index)) }
    var placeholder = "Tap Start and step in front of the camera."
    @ViewBuilder var overlay: (CGSize) -> Overlay

    var body: some View {
        ZStack {
            if let image = runner.image {
                let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
                Image(decorative: image, scale: 1).resizable()
                    .scaleEffect(x: runner.mirrored ? -1 : 1, y: 1)
                    .aspectRatio(aspect, contentMode: .fit)
                    .overlay {
                        GeometryReader { geometry in
                            ZStack {
                                SkeletonLayer(poses: runner.poses, tint: tint)
                                overlay(geometry.size)
                            }
                        }
                    }
            } else if runner.running {
                ProgressView("Starting the camera…")
            } else if runner.message.hasPrefix("Downloading") {
                ProgressView(runner.message)
            } else {
                ContentUnavailableView("Camera off", systemImage: "figure.wave",
                                       description: Text(runner.message.isEmpty ? placeholder : runner.message))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
            if runner.image != nil, let sample = runner.shownSample { CreditTag(file: sample) }
        }
        .overlay(alignment: .top) {
            // A sample's preview: what Start will do.
            if !runner.running, runner.image != nil, !runner.message.isEmpty {
                Text(runner.message).font(.callout).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule()).padding(10)
            }
        }
    }
}

struct SkeletonLayer: View {
    let poses: [Pose]
    let tint: (Int, Pose) -> Color

    var body: some View {
        Canvas { context, size in
            func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
            for (index, pose) in poses.enumerated() {
                let color = tint(index, pose)
                var bones = Path()
                for (a, b) in Pose.skeleton where pose.keypoints[a].confidence > 0.5 && pose.keypoints[b].confidence > 0.5 {
                    bones.move(to: point(pose.keypoints[a].position))
                    bones.addLine(to: point(pose.keypoints[b].position))
                }
                context.stroke(bones, with: .color(color), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                for keypoint in pose.keypoints where keypoint.confidence > 0.5 {
                    let p = point(keypoint.position)
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.white))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A rounded panel for the numbers next to the picture.
struct ExamplePanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Picture and panel side by side when there is room for both (the picture keeps at least about 1.6
/// times the panel's width), otherwise the panel goes under the picture (iPad in portrait with the
/// sidebar open, iPhone).
struct ExampleLayout<Stage: View, Panel: View>: View {
    var panelWidth: CGFloat = 320
    @ViewBuilder var stage: Stage
    @ViewBuilder var panel: Panel

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < panelWidth * 2.6 {
                VStack(spacing: 10) {
                    stage.frame(maxHeight: .infinity)
                    ScrollView { panel }.frame(maxHeight: min(360, geometry.size.height * 0.45))
                }
                .padding(.horizontal, 10)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    stage
                    ScrollView { panel }.frame(width: panelWidth)
                }
                .padding(.horizontal, 14)
            }
        }
    }
}

/// Applies the `-autostart` test argument once.
struct AutoStart: ViewModifier {
    let start: () -> Void
    @State private var done = false
    func body(content: Content) -> some View {
        content.onAppear {
            guard !done, CommandLine.arguments.contains("-autostart") else { return }
            done = true
            start()
        }
    }
}

extension UIImage {
    /// The picture as a CGImage with its orientation applied (photos from the library are often rotated).
    var uprightCGImage: CGImage? {
        if imageOrientation == .up, let cgImage { return cgImage }
        let renderer = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }.cgImage
    }
}
