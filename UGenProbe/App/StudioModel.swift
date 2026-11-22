import Foundation
import SwiftUI
import UGenKit

/// App-wide state: the stick, the models stored on the iPad, and the model currently loaded.
@MainActor
final class StudioModel: ObservableObject {
    @Published var mode: UGenDevice.Mode = .unknown
    @Published var status = "Not connected"
    @Published var identity: UGenDevice.Identity?
    @Published var loadedModel: String?
    @Published var downloads: [String: Double] = [:]   // model name -> fraction complete
    @Published var installed: Set<String> = []
    @Published var busy = false

    // REST API (see APIServer.swift)
    @Published var apiRunning = false
    @Published var apiRequests = 0
    @Published var apiNote = ""
    /// Set by the live view while it is using the stick, so API requests can be refused instead of colliding.
    @Published var liveRunning = false
    /// The last API request queued (see `inTurn` in APIServer.swift).
    var apiTurn: Task<Void, Never>?
    var apiServer: HTTPServer?

    // Language models (see LanguageModels.swift). At most one is on the stick.
    var chatModel: ChatModel?
    var chatModelName: String?
    var visionChatModel: VisionChatModel?
    var speechModel: SpeechToText?

    let device = UGenDevice()

    init() {
        FaceRecognition.embedderName = faceEmbedder
        ObjectCLIP.settings = objectSettings
        refreshInstalled()
    }

    /// "Mac" or "iPad", for the texts on screen and in API answers.
    #if targetEnvironment(macCatalyst)
    nonisolated static let deviceKind = "Mac"
    #else
    nonisolated static let deviceKind = "iPad"
    #endif

    // MARK: Model files

    /// Where model files are read from and downloaded to: a folder the user chose (see `useModelsFolder`),
    /// or the app's own "models" folder.
    static var modelsDirectory: URL {
        if let chosenModelsFolder { return chosenModelsFolder }
        return defaultModelsDirectory
    }

    /// The app's own models folder: on a Mac ~/.hailo/models (outside the sandbox container, so tools and
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
        let url = URL(fileURLWithPath: home).appendingPathComponent(".hailo/models", isDirectory: true)
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
            throw UGenError.invalidInput("Cannot use that folder: \(error.localizedDescription)")
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

    static func fileURL(for model: ModelInfo) -> URL {
        modelsDirectory.appendingPathComponent("\(model.name).hef")
    }

    func refreshInstalled() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.modelsDirectory.path)) ?? []
        installed = Set(names.filter { $0.hasSuffix(".hef") }.map { String($0.dropLast(4)) })
    }

    var installedBytes: Int {
        ModelCatalog.all.filter { installed.contains($0.name) }.reduce(0) { $0 + ($1.fileSize ?? 0) }
    }

    /// Downloads a model from Hailo's servers if it is not on the iPad yet.
    func download(_ model: ModelInfo) async throws {
        guard !installed.contains(model.name) else { return }
        guard let address = model.url, let url = URL(string: address) else {
            throw UGenError.invalidInput("No download address for \(model.name).")
        }
        downloads[model.name] = 0
        defer { downloads[model.name] = nil }

        // Large files over Wi-Fi drop now and then, so try a few times before giving up.
        var lastError: Error = UGenError.invalidInput("Download of \(model.name) failed.")
        for attempt in 1...3 {
            do {
                let progress = DownloadProgress { [weak self] fraction in
                    Task { @MainActor in self?.downloads[model.name] = fraction }
                }
                let (temporary, response) = try await URLSession.shared.download(from: url, delegate: progress)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw UGenError.invalidInput("Download of \(model.name) failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int) ?? 0
                if let expected = model.fileSize, size != expected {
                    throw UGenError.invalidInput("\(model.name) downloaded \(size) bytes, expected \(expected).")
                }
                let destination = Self.fileURL(for: model)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                refreshInstalled()
                return
            } catch {
                lastError = error
                if attempt < 3 { try? await Task.sleep(for: .seconds(1)) }
            }
        }
        throw lastError
    }

    func delete(_ model: ModelInfo) {
        try? FileManager.default.removeItem(at: Self.fileURL(for: model))
        refreshInstalled()
    }

    // MARK: Device

    private var connecting: Task<Void, Error>?

    /// Connects, boots the runtime if the stick is in loader mode, and reads its identity.
    /// Callers that arrive while a connection is in progress wait for that one instead of starting another.
    func connect() async throws {
        if let connecting {
            try await connecting.value
            return
        }
        let attempt = Task { try await self.performConnect() }
        connecting = attempt
        defer { connecting = nil }
        try await attempt.value
    }

    private func performConnect() async throws {
        status = "Connecting…"
        loadedModel = nil
        dropLanguageModels()
        for attempt in 0..<2 {
            var current = try await device.connect()
            if current == .loader {
                status = "Starting the stick (about 6 seconds)…"
                guard let image = Bundle.main.url(forResource: "core-image-hailo-hailo10-usb-dongle", withExtension: "ext4") else {
                    throw UGenError.invalidInput("The runtime image is missing from the app.")
                }
                try await device.bootRuntime(image: image)
                current = await device.mode
            }
            mode = current
            do {
                identity = try await device.identify()
                status = "Ready"
                return
            } catch UGenError.restarting where attempt == 0 {
                // The stick is rebooting to clear a session left by an earlier run. Wait for it to
                // come back in loader mode, then go round again and boot it.
                status = "Restarting the stick to clear an earlier session…"
                mode = .unknown
                try await waitForLoader()
            }
        }
    }

    private func waitForLoader() async throws {
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(500))
            if (try? await device.connect()) == .loader { return }
            await device.disconnect()
        }
        throw UGenError.replugNeeded
    }

    /// Closes the session properly so the stick does not keep it. Called when the app leaves the screen.
    func release() async {
        dropLanguageModels()
        await device.disconnect()
        mode = .unknown
        loadedModel = nil
        status = "Not connected"
    }

    /// Makes sure the stick is running and `model` is downloaded and loaded, together with any
    /// companion models the task needs (for example the text recogniser next to the text detector).
    func prepare(_ model: ModelInfo, task: VisionTask? = nil) async throws {
        if await device.mode != .runtime {
            try await connect()
        }
        // A vision model takes the place of any chat or speech model on the stick.
        dropLanguageModels()
        // YOLO-World's text encoder runs on this device instead (`promptEncoder`).
        let companions = (task?.companionModels(for: model) ?? []).compactMap { ModelCatalog.model(named: $0) }
            .filter { task != .findAnything || $0.name != OpenVocabulary.textEncoderName }
        // A text encoder that does not fit next to its image encoder is loaded only to read the prompts.
        let alone = CLIPModels.pair(forImage: model.name).flatMap { $0.stickLoadsBoth ? nil : $0.text }
        let loaded = companions.filter { $0.name != alone }
        let wanted = Set([model.name] + loaded.map(\.name))
        if await device.loadedModel?.name == model.name, wanted.isSubset(of: Set(await device.loadedModelNames)) { return }

        for item in [model] + companions where !installed.contains(item.name) {
            status = "Downloading \(item.name)…"
            try await download(item)
        }
        status = "Loading \(model.name)…"
        do {
            try await load(model, companions: loaded)
        } catch {
            // The stick may have been replugged: reconnect once and try again.
            try await connect()
            try await load(model, companions: loaded)
        }
        loadedModel = model.name
        status = "Ready"
    }

    private func load(_ model: ModelInfo, companions: [ModelInfo]) async throws {
        try await device.loadModel(hef: Self.fileURL(for: model), info: model)
        for companion in companions {
            try await device.addModel(hef: Self.fileURL(for: companion), info: companion)
        }
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
            guard let second else { throw UGenError.invalidInput("Choose the right-hand photo as well.") }
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

    /// Where the text encoders' tables are kept. They come from the Artelico model repository on Hugging Face
    /// (CLIPModels.fallbackAddress: clip_vit_b_32's from Hailo's own server when the repository lacks them).
    private static var clipFolder: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("clip", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    /// A fixed commit of helmo/artelico-models, so later uploads cannot change what this build downloads.
    private static let clipFilesRevision = "922f2602f2a1b313e357e83e004a2d47feddc7f1"

    /// The prompts embedded for `task`: by the loaded image encoder's own text encoder, or for YOLO-World by
    /// clip_vit_b_32's. The text tables are downloaded on first use (25 to 400 MB) and loaded once per pair; the
    /// prompts are embedded again when they change.
    private func prepareTagger(for task: VisionTask, prompts: [String]) async throws -> CLIPTagger {
        guard let loaded = await device.loadedModel,
              let pair = task == .findAnything ? CLIPModels.pair(forText: OpenVocabulary.textEncoderName) : CLIPModels.pair(forImage: loaded.name) else {
            throw UGenError.invalidInput("\(task.title) needs one of the CLIP or SigLIP image encoders.")
        }
        // YOLO-World's class embeddings are the bare names; tagging and describing say "A photo of a ..." as the reference app.
        let prefix = task == .findAnything ? "" : CLIP.promptPrefix
        if tagger?.pair != pair {
            tagger = nil
            for file in CLIPModels.missingFiles(for: pair, in: Self.clipFolder) {
                status = "Downloading \(file)…"
                try await downloadCLIPFile(file)
            }
            tagger = CLIPTagger(encoder: try CLIPTextEncoder(pair: pair, folder: Self.clipFolder))
            taggerPrompts = []
        }
        if taggerPrompts != prompts || taggerPrefix != prefix {
            status = "Reading the prompts…"
            // Work on a copy: the tagger is a value type and embedding the prompts takes a while.
            if var updated = tagger, let text = ModelCatalog.model(named: pair.text) {
                if task == .findAnything {
                    try await updated.setPrompts(prompts, device: try await promptEncoder(), prefix: prefix)
                } else if pair.stickLoadsBoth {
                    try await updated.setPrompts(prompts, device: device, prefix: prefix)
                } else {
                    // The text encoder alone, then the image encoder again with the rest of the task's models.
                    try await device.loadModel(hef: Self.fileURL(for: text), info: text)
                    try await updated.setPrompts(prompts, device: device, prefix: prefix)
                    let others = task.companionModels(for: loaded).filter { $0 != pair.text }.compactMap { ModelCatalog.model(named: $0) }
                    try await load(loaded, companions: others)
                }
                tagger = updated
            }
            taggerPrompts = prompts
            taggerPrefix = prefix
            status = "Ready"
        }
        guard let tagger else { throw UGenError.invalidInput("\(pair.text)'s word tables could not be read.") }
        return tagger
    }

    /// YOLO-World's prompts are embedded on this device with Core ML (clip_vit_b_32_text_encoder, 76 MB, downloaded
    /// once from the model repository). The stick's copy of that text encoder ends in 8 bits: its embeddings are
    /// 0.99 alike to the float model's, close enough for tagging, but YOLO-World was calibrated with float
    /// embeddings and loses most of its scores with them (bus.jpg: people 0.32 instead of 0.90).
    private var promptEngine: CoreMLEngine?

    private func promptEncoder() async throws -> CoreMLEngine {
        if let promptEngine { return promptEngine }
        guard let text = ModelCatalog.model(named: OpenVocabulary.textEncoderName) else {
            throw UGenError.invalidInput("\(OpenVocabulary.textEncoderName) is missing from the model table.")
        }
        let package = "\(text.name).mlpackage"
        // The manifest last, so a package with one is complete.
        for part in ["Data/com.apple.CoreML/weights/weight.bin", "Data/com.apple.CoreML/model.mlmodel", "Manifest.json"] {
            let file = "\(package)/\(part)"
            guard !FileManager.default.fileExists(atPath: Self.clipFolder.appendingPathComponent(file).path) else { continue }
            status = "Downloading \(text.name) for Core ML…"
            try await downloadCLIPFile(file)
        }
        let engine = CoreMLEngine()
        try await engine.load(text, from: Self.clipFolder.appendingPathComponent(package))
        promptEngine = engine
        return engine
    }

    private func downloadCLIPFile(_ file: String) async throws {
        let destination = Self.clipFolder.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Earlier versions kept clip_vit_b_32's tables under Hailo's names.
        if let old = Self.legacyCLIPNames[file], (try? FileManager.default.moveItem(at: Self.clipFolder.appendingPathComponent(old), to: destination)) != nil {
            return
        }
        let repository = URL(string: "https://huggingface.co/helmo/artelico-models/resolve/\(Self.clipFilesRevision)/coreml/\(file)")!
        for address in [repository] + [CLIPModels.fallbackAddress(for: file)].compactMap({ $0 }) {
            let (temporary, response) = try await URLSession.shared.download(from: address)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { try? FileManager.default.removeItem(at: temporary); continue }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return
        }
        throw UGenError.invalidInput("Download of \(file) failed.")
    }

    private static let legacyCLIPNames = ["clip_vit_b_32_text_encoder.tokens.npy": "token_embedding_lut.npy",
                                          "clip_vit_b_32_text_encoder.projection.npy": "text_projection.npy"]

    func fail(_ error: Error) {
        status = "\(error)"
        Task {
            mode = await device.mode
            loadedModel = await device.loadedModel?.name
        }
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
