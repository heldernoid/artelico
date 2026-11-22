import CoreGraphics
import Foundation

/// Reads text in a picture with two models: `ocr_det` finds the regions and `ocr` reads each one.
/// Both must be loaded on the device (`loadModel` for one, `addModel` for the other).
public enum TextReader {
    public static let detectorName = "ocr_det"
    public static let recognizerName = "ocr"
    /// Grey used to pad a text crop to the recogniser's 320x48 input, as in hailo-apps (128).
    static let pad: CGFloat = 128.0 / 255.0

    public static func read(_ image: CGImage, device: any InferenceEngine) async throws -> [TextRegion] {
        guard let detector = ModelCatalog.model(named: detectorName), let recognizer = ModelCatalog.model(named: recognizerName) else {
            throw StudioError.invalidInput("The text models are missing from the model table.")
        }
        let frame = try VisionPipeline.prepare(image, for: detector, task: .textDetection)
        let tensors = try await device.infer(inputs: [frame.rgb], model: detectorName)
        var regions = PostProcess.textRegions(tensors[0], frame: frame)

        for index in regions.indices {
            guard let crop = ImagePrep.crop(image, quad: regions[index].corners), crop.width >= crop.height else { continue }
            let input = try ImagePrep.prepare(crop, width: recognizer.inputWidth, height: recognizer.inputHeight, mode: .letterbox, pad: pad)
            let output = try await device.infer(inputs: [input.rgb], model: recognizerName)
            let (text, confidence) = PostProcess.recognizedText(output[0])
            if confidence >= 0.5 { regions[index].text = text }
        }
        return regions
    }
}

/// People the app has been shown, each with one or more face embeddings.
public struct FaceGallery: Codable, Sendable {
    public var people: [String: [[Float]]] = [:]
    /// Cosine similarity needed to call two faces the same person.
    public var threshold: Float = 0.4
    /// The model that made the embeddings. Another embedder's vectors have the same length but mean
    /// something else, so they are never compared (see `FaceRecognition.recognize`).
    public var embedder: String = FaceRecognition.defaultEmbedderName

    public init(embedder: String = FaceRecognition.defaultEmbedderName) {
        self.embedder = embedder
    }

    /// Lists saved before the embedder could be chosen have no "embedder": they are arcface_mobilefacenet's.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        people = try container.decode([String: [[Float]]].self, forKey: .people)
        threshold = try container.decodeIfPresent(Float.self, forKey: .threshold) ?? 0.4
        embedder = try container.decodeIfPresent(String.self, forKey: .embedder) ?? FaceRecognition.defaultEmbedderName
    }

    public mutating func enroll(_ name: String, embedding: [Float]) {
        people[name, default: []].append(embedding)
    }

    public mutating func remove(_ name: String) {
        people[name] = nil
    }

    /// The best-matching person, if the similarity reaches the threshold.
    public func match(_ embedding: [Float]) -> (name: String, similarity: Float)? {
        var best: (name: String, similarity: Float)?
        for (name, embeddings) in people {
            for known in embeddings where known.count == embedding.count {
                var dot: Float = 0
                for i in known.indices { dot += known[i] * embedding[i] }
                if dot > (best?.similarity ?? -1) { best = (name, dot) }
            }
        }
        guard let best, best.similarity >= threshold else { return nil }
        return best
    }

    /// The file an app keeps the list of `embedder` in: one per embedder. The default keeps the name
    /// "faces.json" that lists had before there was a choice.
    public static func fileName(for embedder: String) -> String {
        embedder == FaceRecognition.defaultEmbedderName ? "faces.json" : "faces-\(embedder).json"
    }

    /// The saved list of `embedder` in `folder`, or an empty one.
    public static func load(from folder: URL, embedder: String) -> FaceGallery {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName(for: embedder))),
              let saved = try? JSONDecoder().decode(FaceGallery.self, from: data), saved.embedder == embedder else {
            return FaceGallery(embedder: embedder)
        }
        return saved
    }

    public func save(to folder: URL) {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: folder.appendingPathComponent(Self.fileName(for: embedder)), options: .atomic)
        }
    }
}

/// Finds faces with the loaded face detector (SCRFD, RetinaFace or LightFace; `scrfd_10g` if none is
/// loaded) and describes each with an ArcFace embedder, so they can be compared with enrolled people.
/// Both models must be loaded on the device.
public enum FaceRecognition {
    public static let detectorName = "scrfd_10g"
    public static let defaultEmbedderName = "arcface_mobilefacenet"
    /// The embedders to choose from (both 512 numbers per face): MobileFaceNet (2.6 MB, fast) and
    /// ResNet-50 (25 MB, slower, more accurate).
    public static let embedderNames = [defaultEmbedderName, "arcface_r50"]
    /// The embedder in use. An app sets it from its settings before loading models; each embedder has
    /// its own list of people (`FaceGallery.embedder`).
    nonisolated(unsafe) public static var embedderName = defaultEmbedderName
    /// Where the five landmarks sit in ArcFace's 112x112 input (from hailo-apps' face_align.cpp).
    static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// Whether `detector` gives the five landmarks recognition aligns faces with. LightFace gives boxes
    /// only: its faces are found but cannot be recognised.
    public static func findsLandmarks(_ detector: ModelInfo) -> Bool {
        PostProcess.faceAnchors(for: detector)?.landmarks ?? true
    }

    /// Detects faces and returns each with its unit-length embedding. The embedding is empty for faces
    /// without landmarks (LightFace): ArcFace only works on faces aligned by their eyes, nose and mouth.
    public static func describe(_ image: CGImage, device: any InferenceEngine) async throws -> [(face: Face, embedding: [Float])] {
        // The loaded face detector when there is one, otherwise scrfd_10g.
        let loaded = await device.loadedModel
        let chosen = loaded.flatMap { VisionPipeline.supports(.face, model: $0) ? $0 : nil } ?? ModelCatalog.model(named: detectorName)
        guard let detector = chosen, let embedder = ModelCatalog.model(named: embedderName) else {
            throw StudioError.invalidInput("The face models are missing from the model table.")
        }
        let frame = try VisionPipeline.prepare(image, for: detector, task: .face)
        let faces = PostProcess.faces(try await device.infer(inputs: [frame.rgb], model: detector.name), model: detector, frame: frame)

        var result: [(Face, [Float])] = []
        for face in faces {
            let scale = CGFloat(embedder.inputWidth) / 112
            guard let aligned = align(image, landmarks: face.landmarks, template: template.map { CGPoint(x: $0.x * scale, y: $0.y * scale) },
                                      size: CGSize(width: embedder.inputWidth, height: embedder.inputWidth)) else {
                result.append((face, []))
                continue
            }
            let input = try ImagePrep.prepare(aligned, width: embedder.inputWidth, height: embedder.inputHeight, mode: .stretch)
            let output = try await device.infer(inputs: [input.rgb], model: embedder.name)
            var embedding = output[0].floats()
            let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
            if norm > 0 { for i in embedding.indices { embedding[i] /= norm } }
            result.append((face, embedding))
        }
        return result
    }

    /// Detects faces and names the ones that match someone in `gallery` (a list made with the embedder in use).
    public static func recognize(_ image: CGImage, device: any InferenceEngine, gallery: FaceGallery) async throws -> [Face] {
        let comparable = gallery.embedder == embedderName
        return try await describe(image, device: device).map { face, embedding in
            var named = face
            named.name = comparable ? gallery.match(embedding)?.name : nil
            return named
        }
    }

    /// Rotates, scales and shifts the face so its five landmarks (normalized to `image`) land on
    /// `template` (pixels of the `size` output): ArcFace's positions, or CelebA's for face attributes.
    static func align(_ image: CGImage, landmarks: [CGPoint], template target: [CGPoint], size: CGSize) -> CGImage? {
        guard landmarks.count == target.count else { return nil }
        let source = landmarks.map { CGPoint(x: $0.x * CGFloat(image.width), y: $0.y * CGFloat(image.height)) }
        // Least-squares similarity transform (rotation, uniform scale, translation) from source to target.
        let count = CGFloat(source.count)
        let sourceMean = CGPoint(x: source.reduce(0) { $0 + $1.x } / count, y: source.reduce(0) { $0 + $1.y } / count)
        let targetMean = CGPoint(x: target.reduce(0) { $0 + $1.x } / count, y: target.reduce(0) { $0 + $1.y } / count)
        var a: CGFloat = 0, b: CGFloat = 0, spread: CGFloat = 0
        for (s, t) in zip(source, target) {
            let sx = s.x - sourceMean.x, sy = s.y - sourceMean.y
            let tx = t.x - targetMean.x, ty = t.y - targetMean.y
            a += sx * tx + sy * ty
            b += sx * ty - sy * tx
            spread += sx * sx + sy * sy
        }
        guard spread > 0 else { return nil }
        let cosine = a / spread, sine = b / spread
        let transform = CGAffineTransform(a: cosine, b: sine, c: -sine, d: cosine,
                                          tx: targetMean.x - (cosine * sourceMean.x - sine * sourceMean.y),
                                          ty: targetMean.y - (sine * sourceMean.x + cosine * sourceMean.y))
        return ImagePrep.draw(image, into: size, transform: transform)
    }
}

/// Depth from two pictures taken side by side (left and right camera) with `stereonet`.
public enum StereoDepth {
    public static let modelName = "stereonet"

    /// Returns a depth map at the model's resolution (1232x368). Values are the largest disparity minus
    /// each pixel's disparity, so larger is farther; they are relative, not metres.
    public static func run(left: CGImage, right: CGImage, device: any InferenceEngine) async throws -> DepthMap {
        guard let model = ModelCatalog.model(named: modelName), model.inputs.count == 2 else {
            throw StudioError.invalidInput("The stereo model is missing from the model table.")
        }
        // The model's inputs are listed right picture first ("input_layer2"), then left ("input_layer1").
        var frames: [[UInt8]] = []
        for stream in model.inputs {
            let picture = stream.name.hasSuffix("input_layer1") ? left : right
            frames.append(try ImagePrep.prepare(picture, width: stream.width ?? 0, height: stream.height ?? 0, mode: .stretch).rgb)
        }
        let output = try await device.infer(inputs: frames, model: modelName)[0]
        let disparity = output.floats()
        let largest = disparity.max() ?? 0
        return DepthMap(width: output.width, height: output.height, values: disparity.map { largest - $0 })
    }
}
