import CoreGraphics
import Foundation

/// Tasks whose model looks at one face or one person at a time: a detector finds them (scrfd_10g for
/// faces, yolov8s for people), each is cut out the way the model was trained, and the crops go through
/// the model one after another. Both models must be loaded on the device
/// (`VisionTask.companionModels(for:)` names the detector). Without a detector (`VisionPipeline.prepare`
/// / `decode`, native-map, capture) the whole picture is one crop.
public enum CropTasks {
    public static let tasks: Set<VisionTask> = [.faceAttributes, .faceLandmarks, .personAttributes, .personReID]
    /// Each face or person costs one more run; more than this many (the best scores first) are left out.
    public static let maxObjects = 10
    /// People below this detector score are skipped (as for top-down pose).
    static let personThreshold: Float = 0.4

    public static func detectorName(for task: VisionTask) -> String {
        task == .faceAttributes || task == .faceLandmarks ? FaceRecognition.detectorName : TopDownPose.detectorName
    }

    /// A face or person found by the detector, normalized to the picture.
    struct Found {
        let box: CGRect
        let confidence: Float
        /// Faces: eyes, nose and mouth corners (SCRFD); empty for people and whole pictures.
        let landmarks: [CGPoint]
    }

    /// One model input and how its pixels map back to the picture: by the frame, or by a turned square
    /// (face mesh crops are turned so the eyes are level).
    struct Crop {
        let frame: PreparedFrame
        let square: RotatedSquare?
    }

    /// The faces or people in `image`, each described by the loaded model.
    public static func run(_ task: VisionTask, on image: CGImage, model: ModelInfo, device: any InferenceEngine) async throws -> VisionResult {
        let found = try await find(task, in: image, device: device)
        guard !found.isEmpty, let pixels = RGBAPixels(image) else { return decode([], task: task, model: model, found: [], crops: []) }
        let crops = found.map { crop(task, model: model, image: image, pixels: pixels, found: $0) }
        let outputs = try await device.inferEach(crops.map(\.frame.rgb), model: model.name)
        return decode(outputs, task: task, model: model, found: found, crops: crops)
    }

    /// The whole picture stretched to the input, as the model's one crop (the Model Zoo's evaluation
    /// pictures are crops already).
    static func wholePicture(_ image: CGImage, model: ModelInfo) throws -> PreparedFrame {
        guard let pixels = RGBAPixels(image) else { throw StudioError.invalidInput("Could not read the picture.") }
        return stretched(pixels, region: CGRect(x: 0, y: 0, width: image.width, height: image.height), model: model)
    }

    /// Decodes the whole-picture crop of `wholePicture`.
    static func decodeWhole(_ tensors: [Tensor], task: VisionTask, model: ModelInfo, frame: PreparedFrame) -> VisionResult {
        let whole = Found(box: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 1, landmarks: [])
        return decode([tensors], task: task, model: model, found: [whole], crops: [Crop(frame: frame, square: nil)])
    }

    // MARK: Finding

    static func find(_ task: VisionTask, in image: CGImage, device: any InferenceEngine) async throws -> [Found] {
        let name = detectorName(for: task)
        guard let detector = ModelCatalog.model(named: name) else { throw StudioError.invalidInput("\(name) is missing from the model table.") }
        if name == FaceRecognition.detectorName {
            let frame = try VisionPipeline.prepare(image, for: detector, task: .face)
            let faces = PostProcess.faces(try await device.infer(inputs: [frame.rgb], model: name), model: detector, frame: frame)
            return faces.sorted { $0.confidence > $1.confidence }.prefix(maxObjects)
                .map { Found(box: $0.boundingBox, confidence: $0.confidence, landmarks: $0.landmarks) }
        }
        let frame = try VisionPipeline.prepare(image, for: detector, task: .detection)
        let tensors = try await device.infer(inputs: [frame.rgb], model: name)
        guard case .detections(let found) = VisionPipeline.decode(tensors, task: .detection, model: detector, frame: frame) else { return [] }
        return found.filter { $0.classIndex == 0 && $0.confidence >= personThreshold }.sorted { $0.confidence > $1.confidence }
            .prefix(maxObjects).map { Found(box: $0.boundingBox, confidence: $0.confidence, landmarks: []) }
    }

    // MARK: Cutting out

    /// Where the five SCRFD landmarks sit in CelebA's aligned 178 x 218 pictures (the means of
    /// list_landmarks_align_celeba.txt), which face_attr_resnet_v1_18 was trained on.
    static let celebaTemplate: [CGPoint] = [
        CGPoint(x: 69, y: 111), CGPoint(x: 108, y: 111), CGPoint(x: 88, y: 135), CGPoint(x: 72, y: 152), CGPoint(x: 105, y: 152),
    ]

    static func crop(_ task: VisionTask, model: ModelInfo, image: CGImage, pixels: RGBAPixels, found: Found) -> Crop {
        let inW = model.inputWidth, inH = model.inputHeight
        let pw = Double(pixels.width), ph = Double(pixels.height)
        let box = CGRect(x: Double(found.box.minX) * pw, y: Double(found.box.minY) * ph, width: Double(found.box.width) * pw, height: Double(found.box.height) * ph)
        /// A square crop, turned by `angle`, resized to the square input.
        func square(_ square: RotatedSquare) -> Crop {
            let region = CGRect(x: square.cx - square.size / 2, y: square.cy - square.size / 2, width: square.size, height: square.size)
            return Crop(frame: frame(pixels.crop(square, side: inW), pixels: pixels, region: region, model: model), square: square.angle == 0 ? nil : square)
        }

        switch task {
        case .faceAttributes:
            // Aligned like CelebA's pictures by eyes, nose and mouth; stretched if that cannot be done.
            let template = celebaTemplate.map { CGPoint(x: $0.x * CGFloat(inW) / 178, y: $0.y * CGFloat(inH) / 218) }
            if let aligned = FaceRecognition.align(image, landmarks: found.landmarks, template: template, size: CGSize(width: inW, height: inH)),
               let rgb = try? ImagePrep.prepare(aligned, width: inW, height: inH, mode: .stretch).rgb {
                return Crop(frame: frame(rgb, pixels: pixels, region: box, model: model), square: nil)
            }
            return Crop(frame: stretched(pixels, region: box, model: model), square: nil)
        case .faceLandmarks where model.outputs.count == 1:
            // 3DDFA_V2's parse_roi_box_from_bbox: a square 1.58 x the box's mean side, moved down by 0.14.
            let side = (box.width + box.height) / 2
            let roi = RotatedSquare(cx: box.midX, cy: box.midY + side * 0.14, size: (side * 1.58).rounded(.towardZero), angle: 0)
            return square(roi)
        case .faceLandmarks:
            // MediaPipe's face mesh: a square 1.5 x the box's longer side, turned so the eyes are level.
            var angle = 0.0
            if found.landmarks.count >= 2 {
                let left = found.landmarks[0], right = found.landmarks[1]
                angle = -atan2(Double(right.y - left.y) * ph, Double(right.x - left.x) * pw)
            }
            return square(RotatedSquare(cx: box.midX, cy: box.midY, size: 1.5 * max(box.width, box.height), angle: angle))
        default:
            // People: the detector's box stretched to the input, as PETA's and Market-1501's crops are.
            return Crop(frame: stretched(pixels, region: box, model: model), square: nil)
        }
    }

    /// `region` (picture pixels) stretched to the model's input (bilinear, pixel centres as tf.image.resize).
    static func stretched(_ pixels: RGBAPixels, region: CGRect, model: ModelInfo) -> PreparedFrame {
        let inW = model.inputWidth, inH = model.inputHeight
        let sx = Double(region.width) / Double(inW), sy = Double(region.height) / Double(inH)
        let rgb = pixels.warp(width: inW, height: inH, x: (sx, Double(region.minX) + 0.5 * sx - 0.5), y: (sy, Double(region.minY) + 0.5 * sy - 0.5))
        return frame(rgb, pixels: pixels, region: region, model: model)
    }

    /// A crop of `region` (picture pixels) as a frame that maps input pixels back to the picture.
    static func frame(_ rgb: [UInt8], pixels: RGBAPixels, region: CGRect, model: ModelInfo) -> PreparedFrame {
        let pw = Double(pixels.width), ph = Double(pixels.height)
        return PreparedFrame(rgb: rgb, width: model.inputWidth, height: model.inputHeight, sourceWidth: pixels.width, sourceHeight: pixels.height,
                             contentRect: CGRect(x: 0, y: 0, width: model.inputWidth, height: model.inputHeight),
                             sourceRegion: CGRect(x: region.minX / pw, y: region.minY / ph, width: region.width / pw, height: region.height / ph))
    }

    // MARK: Decoding

    static func decode(_ outputs: [[Tensor]], task: VisionTask, model: ModelInfo, found: [Found], crops: [Crop]) -> VisionResult {
        let runs = Array(zip(found, zip(crops, outputs)))
        switch task {
        case .faceLandmarks:
            return .faceLandmarks(runs.compactMap { item, run in
                let (crop, tensors) = run
                func picture(_ p: CGPoint) -> CGPoint {
                    guard let square = crop.square else { return crop.frame.toSource(x: p.x, y: p.y) }
                    let q = square.toPicture(u: Double(p.x), v: Double(p.y), side: Double(crop.frame.width))
                    return CGPoint(x: q.x / CGFloat(crop.frame.sourceWidth), y: q.y / CGFloat(crop.frame.sourceHeight))
                }
                if let mesh = PostProcess.faceMesh(tensors) {
                    return FaceLandmarks(boundingBox: item.box, confidence: mesh.score, points: mesh.points.map(picture))
                }
                guard let dense = PostProcess.tddfaLandmarks(tensors[0]) else { return nil }
                return FaceLandmarks(boundingBox: item.box, confidence: item.confidence, points: dense.points.map(picture), headPose: dense.pose)
            })
        case .personReID:
            var people = runs.map { item, run in
                DescribedObject(boundingBox: item.box, confidence: item.confidence, embedding: PostProcess.unitEmbedding(run.1[0]))
            }
            // Numbered within this picture; apps keep a gallery across pictures and frames instead.
            var gallery = ReIdentification.gallery(for: model)
            ReIdentification.name(&people, gallery: &gallery)
            return .described(people)
        default:
            return .described(runs.map { item, run in
                let tensor = run.1[0]
                let attributes = task == .faceAttributes ? PostProcess.faceAttributes(tensor) : PostProcess.personAttributes(tensor)
                return DescribedObject(boundingBox: item.box, confidence: item.confidence, attributes: attributes)
            })
        }
    }
}

/// Re-identification: people are told apart by the cosine similarity of their appearance vectors. A
/// person not like anyone seen before becomes "Person N"; the gallery keeps a few looks per person.
public enum ReIdentification {
    /// Looks kept per person (the latest ones), so a turn or a step into shade still matches.
    static let looksPerPerson = 8

    /// An empty gallery for `model`, with the similarity it needs to call two crops the same person.
    /// OSNet's vectors come out of a ReLU (no negative numbers), so even strangers score 0.6-0.85 on
    /// bus.jpg; the same person in other frames of walk_in_room.mp4 scored 0.72-0.98. RepVGG spreads
    /// them wider: strangers 0.2-0.6, the same person 0.6-0.99.
    public static func gallery(for model: ModelInfo) -> FaceGallery {
        var gallery = FaceGallery(embedder: model.name)
        gallery.threshold = model.name == "osnet_x1_0" ? 0.75 : 0.6
        return gallery
    }

    /// Names everyone in `people` from `gallery`, adding new people to it. Within one picture each name
    /// is given once, the most similar pairs first.
    public static func name(_ people: inout [DescribedObject], gallery: inout FaceGallery) {
        var pairs: [(person: Int, name: String, similarity: Float)] = []
        for index in people.indices {
            people[index].name = nil
            people[index].similarity = nil
        }
        for (index, person) in people.enumerated() where !person.embedding.isEmpty {
            for (name, looks) in gallery.people {
                let best = looks.map { look in zip(look, person.embedding).reduce(0) { $0 + $1.0 * $1.1 } }.max() ?? -1
                if best >= gallery.threshold { pairs.append((index, name, best)) }
            }
        }
        var takenNames = Set<String>(), named = Set<Int>()
        for pair in pairs.sorted(by: { $0.similarity > $1.similarity }) where !takenNames.contains(pair.name) && !named.contains(pair.person) {
            takenNames.insert(pair.name)
            named.insert(pair.person)
            people[pair.person].name = pair.name
            people[pair.person].similarity = pair.similarity
            gallery.people[pair.name] = Array((gallery.people[pair.name] ?? []).suffix(looksPerPerson - 1)) + [people[pair.person].embedding]
        }
        for index in people.indices where !named.contains(index) && !people[index].embedding.isEmpty {
            let name = "Person \(gallery.people.count + 1)"
            gallery.enroll(name, embedding: people[index].embedding)
            people[index].name = name
        }
    }
}
