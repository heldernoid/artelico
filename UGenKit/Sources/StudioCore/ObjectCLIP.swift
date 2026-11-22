import CoreGraphics
import Foundation

/// "Describe each object": a detector finds people, vehicles, animals or faces, and each one is matched against
/// the typed prompts with a CLIP pair ("wearing a hat, wearing a backpack, on a phone"), like hailo-apps' clip app
/// with `--detector person|vehicle|face`. Its cropper hands each detection box, as it is, to the image encoder,
/// which stretches it to its input (hailocropper); the prompts are embedded once (`CLIPTagger`).
///
/// The chosen model is the image encoder; its text encoder and the detector are companions
/// (`VisionTask.companionModels(for:)`). The stick cannot hold clip_vit_l_14_laion2B's two encoders at once
/// (`CLIPPair.stickLoadsBoth`): Hailo Studio then embeds the prompts first and keeps the image encoder and detector.
public enum ObjectCLIP {
    /// What to describe: which of the detector's classes are kept, or faces from a face detector.
    public enum Objects: String, CaseIterable, Sendable, Identifiable {
        case people, vehicles, animals, faces, everything

        public var id: String { rawValue }

        public var title: String { rawValue.capitalized }

        /// The detector labels kept (COCO names); nil keeps every class. Faces come from a face detector.
        var labels: Set<String>? {
            switch self {
            case .people: return ["person"]
            case .vehicles: return ["bicycle", "car", "motorcycle", "bus", "truck", "train", "boat"]
            case .animals: return ["bird", "cat", "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe"]
            case .faces, .everything: return nil
            }
        }
    }

    /// The objects to describe and the detector for them. Any detector `VisionPipeline` decodes works, a face
    /// detector for faces.
    public struct Settings: Sendable, Equatable {
        public var objects: Objects
        public var detector: String
        public var faceDetector: String

        public init(objects: Objects = .people, detector: String = TopDownPose.detectorName, faceDetector: String = FaceRecognition.detectorName) {
            self.objects = objects
            self.detector = detector
            self.faceDetector = faceDetector
        }

        /// The detector this choice runs.
        public var detectorName: String { objects == .faces ? faceDetector : detector }
    }

    /// The apps' current choice (Photos, Live and the REST API share it), as `FaceRecognition.embedderName`.
    nonisolated(unsafe) public static var settings = Settings()

    /// Detections below this score are not described (as the crop tasks' people).
    static let detectorThreshold: Float = 0.4

    /// Each object found, best detector score first (at most `CropTasks.maxObjects`), with every prompt's
    /// probability for its crop, the best first. `prompts` were embedded with the loaded image encoder's own text
    /// encoder; the image encoder and the detector must be loaded.
    public static func run(_ image: CGImage, prompts: CLIPTagger, settings: Settings = settings,
                           device: any InferenceEngine) async throws -> [DescribedObject] {
        guard !prompts.prompts.isEmpty else { throw StudioError.invalidInput("Type what to look for, for example: wearing a hat, wearing a backpack.") }
        guard let encoder = ModelCatalog.model(named: prompts.pair.image) else { throw StudioError.invalidInput("\(prompts.pair.image) is missing from the model table.") }
        let found = try await find(in: image, settings: settings, device: device)
        let frames = try found.map { item in
            try ImagePrep.prepare(image, width: encoder.inputWidth, height: encoder.inputHeight, mode: .stretch, region: item.box).rgb
        }
        let outputs = try await device.inferEach(frames, model: encoder.name)
        return zip(found, outputs).map { item, tensors in
            let scores = CLIP.scores(image: CLIP.imageEmbedding(from: tensors[0]), prompts: prompts.prompts, scale: prompts.pair.logitScale)
            let ranked = prompts.classifications(scores.sorted { $0.probability > $1.probability })
            return DescribedObject(boundingBox: item.box, confidence: item.confidence, label: item.label, attributes: ranked)
        }
    }

    struct Found {
        let box: CGRect
        let confidence: Float
        let label: String
    }

    /// The objects the settings ask for, normalized to the picture, clipped to it (crops need pixels).
    static func find(in image: CGImage, settings: Settings, device: any InferenceEngine) async throws -> [Found] {
        let name = settings.detectorName
        guard let detector = ModelCatalog.model(named: name) else { throw StudioError.invalidInput("\(name) is missing from the model table.") }
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        var found: [Found] = []
        if settings.objects == .faces {
            guard VisionPipeline.supports(.face, model: detector) else { throw StudioError.invalidInput("\(name) is not a face detector.") }
            let frame = try VisionPipeline.prepare(image, for: detector, task: .face)
            found = PostProcess.faces(try await device.infer(inputs: [frame.rgb], model: name), model: detector, frame: frame)
                .map { Found(box: $0.boundingBox, confidence: $0.confidence, label: "face") }
        } else {
            guard VisionPipeline.supports(.detection, model: detector) else { throw StudioError.invalidInput("\(name) is not an object detector.") }
            let frame = try VisionPipeline.prepare(image, for: detector, task: .detection)
            guard case .detections(let detections) = VisionPipeline.decode(try await device.infer(inputs: [frame.rgb], model: name),
                                                                          task: .detection, model: detector, frame: frame) else { return [] }
            found = detections.filter { settings.objects.labels?.contains($0.label) ?? true }
                .map { Found(box: $0.boundingBox, confidence: $0.confidence, label: $0.label) }
        }
        return found.filter { $0.confidence >= detectorThreshold }
            .map { Found(box: $0.box.intersection(whole), confidence: $0.confidence, label: $0.label) }
            .filter { !$0.box.isNull && $0.box.width * CGFloat(image.width) >= 4 && $0.box.height * CGFloat(image.height) >= 4 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(CropTasks.maxObjects).map { $0 }
    }
}
