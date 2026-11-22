import Foundation
import SwiftUI
import StudioCore
#if canImport(UIKit)
import UIKit
#endif

import CoreML

/// App-wide state: the models stored on this device, the model currently loaded, and the Core ML
/// engine that runs them on Apple's own chips.
@MainActor
final class StudioModel: ObservableObject {
    @Published var status = "Ready"
    @Published var loadedModel: String?
    /// Where models run. Changing it reloads the model on the next run.
    @Published var computeUnits: ComputeChoice = ComputeChoice.saved {
        didSet {
            UserDefaults.standard.set(computeUnits.rawValue, forKey: "computeUnits")
            loadedModel = nil
            Task { await device.unloadAll() }
        }
    }
    @Published var downloads: [String: Double] = [:]   // model name -> fraction complete
    @Published var installed: Set<String> = []
    @Published var busy = false

    // REST API (see APIServer.swift)
    @Published var apiRunning = false
    @Published var apiRequests = 0
    @Published var apiNote = ""
    /// Set by the live view while it is using the stick, so API requests can be refused instead of colliding.
    @Published var liveRunning = false
    /// Models downloading now, with how far along each is (0...1).
    @Published var modelDownloads: [String: Double] = [:]
    /// Download sizes from the model repository's manifest, once it has been fetched.
    @Published var remoteSizes: [String: Int64] = [:]
    /// "Download all": which of how many models it is on, while it runs (see ModelDownloads.swift).
    @Published var downloadAllProgress: (done: Int, of: Int)?
    var downloadAllTask: Task<Void, Never>?
    /// The last API request queued (see `inTurn` in APIServer.swift).
    var apiTurn: Task<Void, Never>?
    var apiServer: HTTPServer?

    /// Runs the vision models (named `device` so the screens shared with Hailo Studio read the same).
    let device = CoreMLEngine()

    // Speech to text (see SpeechEngine.swift; WhisperKit is only imported there, because its own
    // `ModelInfo` type would clash with StudioCore's here).
    let speech = LoadedWhisper()
    @Published var whisperModel: String?
    /// Whisper models downloading now, with how far along each is (0...1).
    @Published var whisperDownloads: [String: Double] = [:]
    /// Download size of each Whisper model, once fetched (`fetchWhisperSizes`).
    @Published var whisperSizes: [String: Int] = [:]

    // Language models (see LanguageModels.swift, LlamaEngine.swift). One at a time.
    var llm: LlamaEngine?
    @Published var llmName: String?
    @Published var llmDownloads: [String: Double] = [:]
    @Published var llmDownloadInfo: [String: String] = [:]
    @Published var speechProgress: Double?

    init() {
        FaceRecognition.embedderName = faceEmbedder
        ObjectCLIP.settings = objectSettings
        refreshInstalled()
    }

    /// "Mac", "iPad" or "iPhone", for the texts on screen and in API answers.
    #if targetEnvironment(macCatalyst)
    nonisolated static let deviceKind = "Mac"
    #else
    nonisolated static let deviceKind = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    #endif

    // MARK: Model files

    /// Where model files are read from and downloaded to: a folder the user chose (see `useModelsFolder`),
    /// or the app's own "models" folder.
    static var modelsDirectory: URL {
        if let chosenModelsFolder { return chosenModelsFolder }
        return defaultModelsDirectory
    }

    /// The app's own models folder: on a Mac ~/.artelico/models (outside the sandbox container, so tools and
    /// scripts find the models too; allowed by the Mac entitlements), on an iPhone or iPad Documents/models.
    /// How the default folder is named on screen: its path from the home folder on a Mac.
    static var defaultModelsFolderName: String {
        let path = defaultModelsDirectory.path
        if let dot = path.range(of: "/.", options: .backwards) { return "~" + path[dot.lowerBound...] }
        return "This app's own folder"
    }

    static let defaultModelsDirectory: URL = {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("models", isDirectory: true)
        #if targetEnvironment(macCatalyst)
        // In the sandbox the home folder is the container; the real one comes from the user database.
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        let url = URL(fileURLWithPath: home).appendingPathComponent(".artelico/models", isDirectory: true)
        if (try? fm.createDirectory(at: url, withIntermediateDirectories: true)) != nil {
            // Models downloaded before into the container's folder move over once (same disk: a rename).
            for name in (try? fm.contentsOfDirectory(atPath: documents.path)) ?? [] where !fm.fileExists(atPath: url.appendingPathComponent(name).path) {
                try? fm.moveItem(at: documents.appendingPathComponent(name), to: url.appendingPathComponent(name))
            }
            return url
        }
        #endif
        try? fm.createDirectory(at: documents, withIntermediateDirectories: true)
        return documents
    }()

    // MARK: Chosen models folder
    //
    // The app is sandboxed, so a folder elsewhere (on the Mac for example the project's `models/`
    // folder) can only be used after the user picks it once. The permission is kept as a bookmark and
    // renewed at every launch.

    private static let modelsFolderKey = "modelsFolderBookmark"
    private(set) static var chosenModelsFolder: URL? = resolveChosenModelsFolder()

    #if targetEnvironment(macCatalyst)
    private static let bookmarkCreation: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let bookmarkResolution: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let bookmarkCreation: URL.BookmarkCreationOptions = []
    private static let bookmarkResolution: URL.BookmarkResolutionOptions = []
    #endif

    private static func resolveChosenModelsFolder() -> URL? {
        #if DEBUG && targetEnvironment(macCatalyst)
        // Testing from the Mac: `-modelsfolder <path>` uses that folder without the folder picker. Only Debug
        // builds may, through the temporary sandbox exception in Artelico-Mac-Debug.entitlements.
        if let index = CommandLine.arguments.firstIndex(of: "-modelsfolder"), index + 1 < CommandLine.arguments.count {
            return URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        }
        #endif
        guard let data = UserDefaults.standard.data(forKey: modelsFolderKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: bookmarkResolution, relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()   // kept open for the life of the app
        guard (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil else {
            url.stopAccessingSecurityScopedResource()
            return nil   // moved, deleted or on a disk that is not attached; fall back to the app's folder
        }
        if stale, let renewed = try? url.bookmarkData(options: bookmarkCreation, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(renewed, forKey: modelsFolderKey)
        }
        return url
    }

    /// Reads models from `folder` (picked by the user) from now on; new downloads go there too.
    func useModelsFolder(_ folder: URL) throws {
        let accessing = folder.startAccessingSecurityScopedResource()
        do {
            let bookmark = try folder.bookmarkData(options: Self.bookmarkCreation, includingResourceValuesForKeys: nil, relativeTo: nil)
            _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            UserDefaults.standard.set(bookmark, forKey: Self.modelsFolderKey)
        } catch {
            if accessing { folder.stopAccessingSecurityScopedResource() }
            throw StudioError.invalidInput("Cannot use that folder: \(error.localizedDescription)")
        }
        Self.chosenModelsFolder?.stopAccessingSecurityScopedResource()
        Self.chosenModelsFolder = folder
        refreshInstalled()
    }

    /// Goes back to the app's own "models" folder. Files in the chosen folder are left alone.
    func useDefaultModelsFolder() {
        UserDefaults.standard.removeObject(forKey: Self.modelsFolderKey)
        Self.chosenModelsFolder?.stopAccessingSecurityScopedResource()
        Self.chosenModelsFolder = nil
        refreshInstalled()
    }

    /// A model is a Core ML package converted from Hailo's Model Zoo (see native/tools), with an optional
    /// `<name>.native.json` next to it that lines its outputs up with the decoders.
    static func fileURL(for model: ModelInfo) -> URL {
        modelsDirectory.appendingPathComponent("\(model.name).mlpackage")
    }

    func refreshInstalled() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.modelsDirectory.path)) ?? []
        installed = Set(names.filter { $0.hasSuffix(".mlpackage") }.map { String($0.dropLast(".mlpackage".count)) })
    }

    var installedBytes: Int {
        ModelCatalog.all.filter { installed.contains($0.name) }.reduce(0) { $0 + ($1.fileSize ?? 0) }
    }

    // Downloading models: ModelDownloads.swift.

    func delete(_ model: ModelInfo) {
        try? FileManager.default.removeItem(at: Self.fileURL(for: model))
        try? FileManager.default.removeItem(at: Self.modelsDirectory.appendingPathComponent("\(model.name).mlmodelc"))
        try? FileManager.default.removeItem(at: Self.modelsDirectory.appendingPathComponent("\(model.name).native.json"))
        for file in CLIPModels.pair(forText: model.name)?.textFiles ?? [] {
            try? FileManager.default.removeItem(at: Self.modelsDirectory.appendingPathComponent(file))
        }
        refreshInstalled()
    }

    // MARK: Engine

    /// Kept for the screens shared with Hailo Studio: there is nothing to connect to.
    func connect() async throws { status = "Ready" }
    func release() async {}

    /// Makes sure `model` is on this device and loaded, together with any companion models the task
    /// needs (for example the face embedder next to the face detector).
    func prepare(_ model: ModelInfo, task: VisionTask? = nil) async throws {
        let companions = (task?.companionModels(for: model) ?? []).compactMap { ModelCatalog.model(named: $0) }
        let wanted = Set([model.name] + companions.map(\.name))
        if await device.loadedModel?.name == model.name, wanted.isSubset(of: Set(await device.loadedModelNames)) { return }
        refreshInstalled()
        for item in [model] + companions where !installed.contains(item.name) {
            try await download(item)
        }
        status = "Loading \(model.name)…"
        await device.unloadAll()
        try await device.load(model, from: Self.fileURL(for: model), computeUnits: computeUnits.units)
        for companion in companions {
            try await device.load(companion, from: Self.fileURL(for: companion), computeUnits: computeUnits.units, primary: false)
        }
        loadedModel = model.name
        status = "Ready"
    }

    // MARK: Tasks that need more than one inference per picture

    /// True when the task cannot use the simple "one frame in, one result out" path.
    func needsPipeline(_ task: VisionTask, tiles: Int) -> Bool {
        switch task {
        case .textDetection, .face, .tagging, .superResolution, .enhancement, .stereoDepth: return true
        // Prompts embedded by a text encoder first; describing also runs a detector and one crop per object.
        case .findAnything, .describeObjects: return true
        // A detector, then one run per face or person; video keeps a clip of each live source.
        case .faceAttributes, .faceLandmarks, .personAttributes, .personReID, .videoClassification: return true
        case .detection: return tiles > 1
        // A single-person pose model runs once per person found by its detector.
        case .pose: return loadedModel.flatMap(ModelCatalog.model(named:)).map(TopDownPose.isTopDown) ?? false
        default: return false
        }
    }

    /// Runs one picture through a multi-step task. `prepare(_:task:)` must have been called first.
    /// `liveSource` is the live source the picture comes from (video clips are kept per source).
    func runPipeline(_ task: VisionTask, on image: CGImage, tiles: Int, prompts: [String], numberUnknownFaces: Bool = false,
                     second: CGImage? = nil, liveSource: Int? = nil) async throws -> VisionResult {
        switch task {
        case .stereoDepth:
            guard let second else { throw StudioError.invalidInput("Choose the right-hand photo as well.") }
            return .depth(try await StereoDepth.run(left: image, right: second, device: device))
        case .textDetection:
            return .text(try await TextReader.read(image, device: device))
        case .face:
            guard numberUnknownFaces else {
                return .faces(try await FaceRecognition.recognize(image, device: device, gallery: gallery))
            }
            // Re-identification: a face nobody has named is remembered for this run as "Person N", so the
            // same person gets the same label later and on the other camera.
            var faces: [Face] = []
            for (face, embedding) in try await FaceRecognition.describe(image, device: device) {
                // Faces without an embedding (LightFace has no landmarks) are shown without a name.
                guard !embedding.isEmpty else { faces.append(face); continue }
                var named = face
                if let known = gallery.match(embedding) ?? sessionFaces.match(embedding) {
                    named.name = known.name
                } else {
                    let name = "Person \(sessionFaces.people.count + 1)"
                    sessionFaces.enroll(name, embedding: embedding)
                    named.name = name
                }
                faces.append(named)
            }
            return .faces(faces)
        case .personReID:
            // Everyone keeps their number across pictures, frames and sources until Live starts again.
            guard case .described(var people) = try await VisionPipeline.run(task, on: image, device: device).result,
                  let model = await device.loadedModel else { return .described([]) }
            if sessionPeople.embedder != model.name { sessionPeople = ReIdentification.gallery(for: model) }
            ReIdentification.name(&people, gallery: &sessionPeople)
            return .described(people)
        case .videoClassification:
            // Live: the source's latest frames as a clip. One picture alone is repeated (approximate).
            guard let liveSource, let model = await device.loadedModel else {
                return try await VisionPipeline.run(task, on: image, device: device).result
            }
            var clip = videoClips[liveSource] ?? VideoClip()
            if let input = clip.add(image, at: Date().timeIntervalSinceReferenceDate, model: model) {
                clip.actions = VideoClip.actions(try await device.infer(inputs: [input])[0])
            }
            videoClips[liveSource] = clip
            return .classifications(clip.actions)
        case .tagging, .findAnything, .describeObjects:
            let tagger = try await prepareTagger(for: task, prompts: prompts)
            // Live keeps the models it started with; a detector chosen since then is loaded now.
            if task == .describeObjects, !(await device.loadedModelNames).contains(ObjectCLIP.settings.detectorName),
               let model = await device.loadedModel {
                try await prepare(model, task: task)
            }
            return try await VisionPipeline.run(task, on: image, device: device, prompts: tagger).result
        case .superResolution, .enhancement:
            return .image(OutputImage(image: try await PictureModels.run(image, device: device)))
        case .detection:
            return .detections(try await Tiling.detect(image, device: device, columns: tiles, rows: tiles))
        default:
            return try await VisionPipeline.run(task, on: image, device: device).result
        }
    }

    // MARK: Faces

    /// Unnamed people seen during the current live run (re-identification). Not saved.
    private var sessionFaces = FaceGallery()

    /// People seen by person re-identification (Photos, Live and the REST API), numbered in order. Not saved.
    private var sessionPeople = FaceGallery()
    /// Live clips for action recognition, one per source.
    private var videoClips: [Int: VideoClip] = [:]

    /// Starts over: unnamed faces and people are numbered from 1 again, video clips are emptied.
    func forgetSessionFaces() {
        sessionFaces = FaceGallery()
        sessionPeople = FaceGallery()
        videoClips = [:]
    }

    private static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// The face embedder recognition uses (FaceRecognition.embedderNames). Each has its own list of
    /// people, because vectors of different embedders cannot be compared.
    @Published var faceEmbedder = StudioModel.savedFaceEmbedder {
        didSet {
            guard faceEmbedder != oldValue else { return }
            UserDefaults.standard.set(faceEmbedder, forKey: "faceEmbedder")
            FaceRecognition.embedderName = faceEmbedder
            gallery = FaceGallery.load(from: Self.documents, embedder: faceEmbedder)
            sessionFaces = FaceGallery(embedder: faceEmbedder)
        }
    }

    /// What "Describe each object" describes and which detector finds it (Photos, Live and the REST API).
    @Published var objectSettings = StudioModel.savedObjectSettings {
        didSet {
            guard objectSettings != oldValue else { return }
            ObjectCLIP.settings = objectSettings
            let defaults = UserDefaults.standard
            defaults.set(objectSettings.objects.rawValue, forKey: "describe.objects")
            defaults.set(objectSettings.detector, forKey: "describe.detector")
            defaults.set(objectSettings.faceDetector, forKey: "describe.faceDetector")
        }
    }

    private static var savedObjectSettings: ObjectCLIP.Settings {
        let defaults = UserDefaults.standard
        var settings = ObjectCLIP.Settings()
        settings.objects = defaults.string(forKey: "describe.objects").flatMap(ObjectCLIP.Objects.init(rawValue:)) ?? settings.objects
        settings.detector = defaults.string(forKey: "describe.detector").flatMap { ModelCatalog.model(named: $0)?.name } ?? settings.detector
        settings.faceDetector = defaults.string(forKey: "describe.faceDetector").flatMap { ModelCatalog.model(named: $0)?.name } ?? settings.faceDetector
        return settings
    }

    private static var savedFaceEmbedder: String {
        let saved = UserDefaults.standard.string(forKey: "faceEmbedder") ?? ""
        return FaceRecognition.embedderNames.contains(saved) ? saved : FaceRecognition.defaultEmbedderName
    }

    @Published var gallery = FaceGallery.load(from: StudioModel.documents, embedder: StudioModel.savedFaceEmbedder)

    /// Remembers the most prominent face in `image` under `name`. Returns how many faces were found.
    func enroll(_ name: String, from image: CGImage) async throws -> Int {
        let found = try await FaceRecognition.describe(image, device: device)
        let described = found.filter { !$0.embedding.isEmpty }
        if !found.isEmpty, described.isEmpty {
            throw StudioError.invalidInput("This face model finds faces but not their eyes, nose and mouth, which recognition needs. Choose SCRFD or RetinaFace.")
        }
        guard let best = described.max(by: { $0.face.boundingBox.width * $0.face.boundingBox.height < $1.face.boundingBox.width * $1.face.boundingBox.height }) else { return 0 }
        gallery.enroll(name, embedding: best.embedding)
        saveGallery()
        return found.count
    }

    /// Stores one averaged identity vector for `name`, replacing earlier samples of that name (check-in enrolment).
    func enroll(_ name: String, embedding: [Float]) {
        gallery.remove(name)
        gallery.enroll(name, embedding: embedding)
        saveGallery()
    }

    func forget(_ name: String) {
        gallery.remove(name)
        saveGallery()
    }

    private func saveGallery() {
        gallery.save(to: Self.documents)
    }

    // MARK: CLIP

    private var tagger: CLIPTagger?
    private var taggerPrompts: [String] = []
    private var taggerPrefix = ""

    /// The prompts embedded for `task`: by the loaded image encoder's own text encoder, or for YOLO-World by
    /// clip_vit_b_32's. Its tables are loaded once (fetching any an older download of the text encoder lacks);
    /// the prompts are embedded again when they change.
    private func prepareTagger(for task: VisionTask, prompts: [String]) async throws -> CLIPTagger {
        let loaded = await device.loadedModel?.name
        guard let pair = task == .findAnything ? CLIPModels.pair(forText: OpenVocabulary.textEncoderName) : loaded.flatMap(CLIPModels.pair(forImage:)) else {
            throw StudioError.invalidInput("\(task.title) needs one of the CLIP or SigLIP image encoders.")
        }
        // YOLO-World's class embeddings are the bare names; tagging and describing say "A photo of a ..." as the reference app.
        let prefix = task == .findAnything ? "" : CLIP.promptPrefix
        if tagger?.pair != pair {
            tagger = nil
            adoptOldCLIPTables()
            try await downloadExtraFiles(CLIPModels.missingFiles(for: pair, in: Self.modelsDirectory), of: pair.text,
                                         fallback: CLIPModels.fallbackAddress(for:))
            status = "Reading \(pair.text)'s word tables…"
            tagger = CLIPTagger(encoder: try CLIPTextEncoder(pair: pair, folder: Self.modelsDirectory))
            taggerPrompts = []
        }
        if taggerPrompts != prompts || taggerPrefix != prefix {
            status = "Reading the prompts…"
            // Work on a copy: the tagger is a value type and embedding the prompts takes a while.
            if var updated = tagger {
                try await updated.setPrompts(prompts, device: device, prefix: prefix)
                tagger = updated
            }
            taggerPrompts = prompts
            taggerPrefix = prefix
            status = "Ready"
        }
        guard let tagger else { throw StudioError.invalidInput("\(pair.text)'s word tables could not be read.") }
        return tagger
    }

    /// Earlier versions downloaded clip_vit_b_32's tables from Hailo into Documents/clip; they move to the
    /// models folder under the names the text encoder's files have now (the old tokenizer is bundled now).
    private func adoptOldCLIPTables() {
        let fm = FileManager.default
        let old = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("clip", isDirectory: true)
        guard fm.fileExists(atPath: old.path) else { return }
        for (name, file) in [("token_embedding_lut.npy", "tokens.npy"), ("text_projection.npy", "projection.npy")] {
            let target = Self.modelsDirectory.appendingPathComponent("clip_vit_b_32_text_encoder.\(file)")
            if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: old.appendingPathComponent(name), to: target) }
        }
        try? fm.removeItem(at: old)
    }

    func fail(_ error: Error) {
        status = "\(error)"
        Task { loadedModel = await device.loadedModel?.name }
    }
}

/// Reports download progress as a fraction from 0 to 1.
final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: (Double) -> Void

    init(report: @escaping (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

func formatBytes(_ count: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
}

func formatMilliseconds(_ duration: Duration) -> String {
    let value = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    return String(format: "%.1f ms", value)
}

/// Which of Apple's chips run the models.
enum ComputeChoice: String, CaseIterable, Identifiable {
    case all, neuralEngine, gpu, cpu
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Automatic"
        case .neuralEngine: return "Neural Engine"
        case .gpu: return "GPU"
        case .cpu: return "CPU"
        }
    }
    var units: MLComputeUnits {
        switch self {
        case .all: return .all
        case .neuralEngine: return .cpuAndNeuralEngine
        case .gpu: return .cpuAndGPU
        case .cpu: return .cpuOnly
        }
    }
    static var saved: ComputeChoice { ComputeChoice(rawValue: UserDefaults.standard.string(forKey: "computeUnits") ?? "") ?? .all }
}
