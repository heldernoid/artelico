import CoreGraphics
import Foundation

/// The vision tasks UGenKit can post-process. Raw values match `ModelInfo.tasks`.
public enum VisionTask: String, Sendable, CaseIterable, Identifiable {
    case detection
    case pose
    case classification
    case depth
    case semanticSegmentation = "semantic_segmentation"
    case instanceSegmentation = "instance_segmentation"
    /// FastSAM: every object and region in the picture as a mask, without class names.
    case segmentEverything = "segment_everything"
    case orientedDetection = "oriented_detection"
    case superResolution = "super_resolution"
    case laneDetection = "lane_detection"
    case face
    case textDetection = "ocr"
    case tagging = "clip"
    case stereoDepth = "stereo_depth"
    /// Low light and denoising models: a picture in, a cleaner picture out.
    case enhancement = "enhance"
    /// The tasks below look at one face or person at a time, found first by a detector (`CropTasks`).
    case faceAttributes = "face_attribute"
    case faceLandmarks = "face_landmarks"
    case personAttributes = "person_attribute"
    case personReID = "person_re_id"
    /// A clip of 16 frames in, the action in it out (Kinetics-400).
    case videoClassification = "video_classification"
    /// YOLO-World: boxes for whatever the typed prompts name (`OpenVocabulary`).
    case findAnything = "zero_shot_object_detection"
    /// A detector finds people, vehicles, animals or faces; a CLIP pair matches each one against the typed
    /// prompts (`ObjectCLIP`). The chosen model is the CLIP image encoder.
    case describeObjects = "object_clip"

    public var id: String { rawValue }

    /// The catalog's task names this task covers (a model's `tasks`); usually just its own.
    public var catalogTasks: [String] {
        switch self {
        case .enhancement: return ["low_light_enhancement", "image_denoising"]
        case .segmentEverything: return ["zero_shot_instance_segmentation"]
        case .pose: return ["pose", "single_person_pose_estimation"]
        case .faceLandmarks: return ["facial_landmark_detection"]
        case .describeObjects: return [VisionTask.tagging.rawValue]
        default: return [rawValue]
        }
    }

    public var title: String {
        switch self {
        case .detection: return "Object detection"
        case .pose: return "Pose estimation"
        case .classification: return "Image classification"
        case .depth: return "Depth estimation"
        case .semanticSegmentation: return "Semantic segmentation"
        case .instanceSegmentation: return "Instance segmentation"
        case .segmentEverything: return "Segment everything"
        case .orientedDetection: return "Oriented boxes (aerial)"
        case .superResolution: return "Super-resolution"
        case .enhancement: return "Brighten or clean up"
        case .laneDetection: return "Lane detection"
        case .face: return "Face detection"
        case .textDetection: return "Read text (OCR)"
        case .tagging: return "Tagging from text (CLIP)"
        case .stereoDepth: return "Depth from two photos (stereo)"
        case .faceAttributes: return "Face attributes"
        case .faceLandmarks: return "Face landmarks"
        case .personAttributes: return "Person attributes"
        case .personReID: return "Person re-identification"
        case .videoClassification: return "Action in video"
        case .findAnything: return "Find anything (type what)"
        case .describeObjects: return "Describe each object (CLIP)"
        }
    }

    /// The part of the picture the model is given. The lane model was trained on the bottom 80% of the
    /// frame (hailo-apps resizes to 800x400 and keeps the lower 320 rows).
    public var sourceRegion: CGRect {
        self == .laneDetection ? CGRect(x: 0, y: 0.2, width: 1, height: 0.8) : CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// Other models that must be loaded next to the chosen one for this task.
    public func companionModels(for model: ModelInfo) -> [String] {
        switch self {
        case .textDetection: return [TextReader.recognizerName]
        case .face: return [FaceRecognition.embedderName]
        case .tagging: return CLIPModels.pair(forImage: model.name).map { [$0.text] } ?? []
        case .pose: return TopDownPose.isTopDown(model) ? [TopDownPose.detectorName] : []
        case .faceAttributes, .faceLandmarks, .personAttributes, .personReID: return [CropTasks.detectorName(for: self)]
        case .findAnything: return OpenVocabulary.isOpenVocabulary(model) ? [OpenVocabulary.textEncoderName] : []
        case .describeObjects: return (CLIPModels.pair(forImage: model.name).map { [$0.text] } ?? []) + [ObjectCLIP.settings.detectorName]
        default: return []
        }
    }

    public var resizeMode: ResizeMode {
        switch self {
        case .detection, .pose, .instanceSegmentation, .segmentEverything, .orientedDetection, .face, .textDetection, .findAnything: return .letterbox
        case .classification, .depth, .semanticSegmentation, .superResolution, .laneDetection, .tagging, .stereoDepth, .enhancement,
             .faceAttributes, .faceLandmarks, .personAttributes, .personReID, .videoClassification, .describeObjects: return .stretch
        }
    }
}

/// One detected object. Coordinates are normalized to the source image (0...1, origin top-left).
public struct Detection: Sendable, Equatable {
    public let label: String
    public let classIndex: Int
    public let confidence: Float
    public let boundingBox: CGRect

    public init(label: String, classIndex: Int, confidence: Float, boundingBox: CGRect) {
        self.label = label
        self.classIndex = classIndex
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// One detected person with body keypoints (COCO order, 17 points).
public struct Pose: Sendable {
    public struct Keypoint: Sendable {
        public let position: CGPoint
        public let confidence: Float

        public init(position: CGPoint, confidence: Float) {
            self.position = position
            self.confidence = confidence
        }
    }
    public let confidence: Float
    public let boundingBox: CGRect
    public let keypoints: [Keypoint]
    /// The number that follows this person from frame to frame, when tracking is on.
    public var trackID: Int?

    public init(confidence: Float, boundingBox: CGRect, keypoints: [Keypoint], trackID: Int? = nil) {
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.keypoints = keypoints
        self.trackID = trackID
    }

    /// Pairs of keypoint indices that form the skeleton.
    public static let skeleton: [(Int, Int)] = [
        (15, 13), (13, 11), (16, 14), (14, 12), (11, 12), (5, 11), (6, 12), (5, 6), (5, 7), (6, 8),
        (7, 9), (8, 10), (1, 2), (0, 1), (0, 2), (1, 3), (2, 4), (3, 5), (4, 6),
    ]
}

public struct Classification: Sendable {
    public let label: String
    public let classIndex: Int
    public let probability: Float

    public init(label: String, classIndex: Int, probability: Float) {
        self.label = label
        self.classIndex = classIndex
        self.probability = probability
    }
}

/// A dense map at the model's output resolution.
public struct DepthMap: Sendable {
    public let width: Int
    public let height: Int
    /// Estimated depth per pixel, row-major. Larger is farther.
    public let values: [Float]

    public init(width: Int, height: Int, values: [Float]) {
        self.width = width
        self.height = height
        self.values = values
    }
}

public struct SegmentationMap: Sendable {
    public let width: Int
    public let height: Int
    /// Class index per pixel, row-major.
    public let classes: [UInt8]
    public let labels: [String]
    /// RGB per class, and the class pictures leave uncoloured.
    public let colors: [[UInt8]]
    public let background: Int?

    public init(width: Int, height: Int, classes: [UInt8], set: SegmentationClasses) {
        self.width = width
        self.height = height
        self.classes = classes
        self.labels = set.labels
        self.colors = set.colors
        self.background = set.background
    }
}

/// One object with a pixel mask. Class-less segments (segment everything) have class index -1.
public struct Instance: Sendable {
    public let detection: Detection
    /// Mask covering the whole source image (not just the box), row-major, 0 = outside, 255 = inside.
    public let maskWidth: Int
    public let maskHeight: Int
    public let mask: [UInt8]

    public init(detection: Detection, maskWidth: Int, maskHeight: Int, mask: [UInt8]) {
        self.detection = detection
        self.maskWidth = maskWidth
        self.maskHeight = maskHeight
        self.mask = mask
    }
}

/// A rotated box. `corners` are its four corners in order, normalized to the source image.
public struct OrientedDetection: Sendable {
    public let label: String
    public let classIndex: Int
    public let confidence: Float
    public let corners: [CGPoint]

    public init(label: String, classIndex: Int, confidence: Float, corners: [CGPoint]) {
        self.label = label
        self.classIndex = classIndex
        self.confidence = confidence
        self.corners = corners
    }
}

/// One lane line as points from far to near, normalized to the source image.
public struct Lane: Sendable {
    public let points: [CGPoint]

    public init(points: [CGPoint]) {
        self.points = points
    }
}

/// A detected face with five landmarks (left eye, right eye, nose, left and right mouth corner).
public struct Face: Sendable {
    public let boundingBox: CGRect
    public let confidence: Float
    public let landmarks: [CGPoint]
    /// Filled in by face recognition when the face matches an enrolled person.
    public var name: String?

    public init(boundingBox: CGRect, confidence: Float, landmarks: [CGPoint], name: String? = nil) {
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.landmarks = landmarks
        self.name = name
    }
}

/// A region of text. `corners` are its four corners in order, normalized to the source image.
public struct TextRegion: Sendable {
    public let corners: [CGPoint]
    public let confidence: Float
    /// Filled in by text recognition; empty after detection alone.
    public var text: String

    public init(corners: [CGPoint], confidence: Float, text: String = "") {
        self.corners = corners
        self.confidence = confidence
        self.text = text
    }
}

/// A face, person or other object found by a detector and described by a second model: its attributes
/// (smiling, glasses, backpack...), for re-identification who it is among the people seen before, or how
/// well it matches typed prompts (`ObjectCLIP`).
public struct DescribedObject: Sendable {
    public let boundingBox: CGRect
    /// The detector's score.
    public let confidence: Float
    /// What the detector calls it ("person", "car", "face"); nil for the attribute and re-ID tasks, whose
    /// objects are all of one kind.
    public var label: String?
    /// Attributes the model sees (probability >= 0.5), most certain first. Prompt matching: every prompt with
    /// its probability, the best match first.
    public var attributes: [Classification]
    /// Re-identification: "Person N", and the cosine similarity to that person's remembered look
    /// (nil when the person is new).
    public var name: String?
    public var similarity: Float?
    /// Re-identification: the unit-length appearance vector (empty for attributes).
    public var embedding: [Float]

    public init(boundingBox: CGRect, confidence: Float, label: String? = nil, attributes: [Classification] = [], name: String? = nil,
                similarity: Float? = nil, embedding: [Float] = []) {
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.label = label
        self.attributes = attributes
        self.name = name
        self.similarity = similarity
        self.embedding = embedding
    }
}

/// Dense landmarks of one face, normalized to the picture: 68 points (3DDFA, the iBUG 300-W layout) or 468
/// (MediaPipe's face mesh).
public struct FaceLandmarks: Sendable {
    public let boundingBox: CGRect
    /// The face detector's score, or the mesh model's own face score.
    public let confidence: Float
    public let points: [CGPoint]
    /// Head turn in degrees (3DDFA only): yaw (left/right), pitch (up/down), roll (tilt).
    public let headPose: (yaw: Float, pitch: Float, roll: Float)?

    public init(boundingBox: CGRect, confidence: Float, points: [CGPoint], headPose: (yaw: Float, pitch: Float, roll: Float)? = nil) {
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.points = points
        self.headPose = headPose
    }
}

/// A picture produced by the model (super-resolution).
public struct OutputImage: @unchecked Sendable {
    public let image: CGImage

    public init(image: CGImage) {
        self.image = image
    }
}

public enum VisionResult: Sendable {
    case detections([Detection])
    case poses([Pose])
    case classifications([Classification])
    case depth(DepthMap)
    case segmentation(SegmentationMap)
    case instances([Instance])
    case orientedDetections([OrientedDetection])
    case lanes([Lane])
    case faces([Face])
    case text([TextRegion])
    case image(OutputImage)
    case described([DescribedObject])
    case faceLandmarks([FaceLandmarks])

    /// One-line summary for logs and lists.
    public var summary: String {
        switch self {
        case .detections(let found):
            return found.isEmpty ? "nothing detected" : found.map { "\($0.label) \(String(format: "%.2f", $0.confidence))" }.joined(separator: ", ")
        case .poses(let found):
            return "\(found.count) person(s)"
        case .classifications(let found):
            return found.prefix(3).map { "\($0.label) \(String(format: "%.1f%%", $0.probability * 100))" }.joined(separator: ", ")
        case .depth(let map):
            let low = map.values.min() ?? 0, high = map.values.max() ?? 0
            return String(format: "depth %dx%d, range %.2f to %.2f", map.width, map.height, low, high)
        case .segmentation(let map):
            let present = Set(map.classes).sorted().map { Int($0) < map.labels.count ? map.labels[Int($0)] : "class \($0)" }
            return "classes: " + present.joined(separator: ", ")
        case .instances(let found):
            return found.isEmpty ? "nothing detected" : found.map { "\($0.detection.label) \(String(format: "%.2f", $0.detection.confidence))" }.joined(separator: ", ")
        case .orientedDetections(let found):
            return found.isEmpty ? "nothing detected" : "\(found.count) objects: " + Dictionary(grouping: found, by: \.label).map { "\($0.value.count) \($0.key)" }.sorted().joined(separator: ", ")
        case .lanes(let found):
            return "\(found.count) lane line(s)"
        case .faces(let found):
            return found.isEmpty ? "no faces" : "\(found.count) face(s)" + (found.compactMap(\.name).isEmpty ? "" : ": " + found.compactMap(\.name).joined(separator: ", "))
        case .text(let found):
            let words = found.map(\.text).filter { !$0.isEmpty }
            return words.isEmpty ? "\(found.count) text region(s)" : words.joined(separator: " | ")
        case .image(let output):
            return "image \(output.image.width)x\(output.image.height)"
        case .described(let found):
            return found.isEmpty ? "nothing found" : found.enumerated().map { index, item in
                let traits = item.attributes.prefix(3).map { "\($0.label) \(String(format: "%.2f", $0.probability))" }
                return ([item.name ?? item.label ?? "#\(index + 1)"] + traits).joined(separator: " ")
            }.joined(separator: "; ")
        case .faceLandmarks(let found):
            return found.isEmpty ? "no faces" : "\(found.count) face(s), \(found[0].points.count) points each"
        }
    }
}

public struct VisionTiming: Sendable {
    public var prepare: Duration = .zero
    public var inference: Duration = .zero
    public var decode: Duration = .zero
    public var total: Duration { prepare + inference + decode }
}
