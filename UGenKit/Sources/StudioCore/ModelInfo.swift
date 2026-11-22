import Foundation

/// One input or output of a compiled model, as reported by Hailo's library (see tools/hefinfo.c).
public struct StreamInfo: Codable, Sendable, Hashable {
    public let name: String
    /// "UINT8", "UINT16" or "FLOAT32".
    public let type: String
    /// "NHWC", "NC", "NHW", "FCR", "NMS_BY_CLASS" or "NMS_BYTE_MASK".
    public let order: String
    /// Size of one frame of this stream in bytes, in the model's own data type.
    public let frameSize: Int
    public let height: Int?
    public let width: Int?
    public let features: Int?
    /// Quantization: real value = (raw - qpZp) * qpScale.
    public let qpZp: Float?
    public let qpScale: Float?
    /// NMS outputs only.
    public let classes: Int?
    public let maxBoxes: Int?
    /// Per-channel quantization (one zero point and scale per feature), for outputs whose HEF quantizes
    /// each channel on its own; `qpScale` is then 0. From tools/hef_feature_quant.py.
    public var qpZps: [Float]? = nil
    public var qpScales: [Float]? = nil

    public var isNMS: Bool { order == "NMS_BY_CLASS" }
    /// Instance segmentation finished on the device: boxes after NMS, each with its own mask.
    public var isByteMaskNMS: Bool { order == "NMS_BYTE_MASK" }
    public var bytesPerElement: Int { type == "UINT16" ? 2 : (type == "FLOAT32" ? 4 : 1) }
}

/// A compiled model the stick can run, with where to download it.
public struct ModelInfo: Codable, Sendable, Identifiable, Hashable {
    public let name: String
    /// Studio tasks this model serves, e.g. "detection", "pose", "classification".
    public let tasks: [String]
    /// The Hailo Model Zoo task page the model is listed on (docs/public_models/HAILO10H), e.g.
    /// "classification", "face_attribute"; nil for models only hailo-apps uses.
    public let taskPage: String?
    public let url: String?
    public let fileSize: Int?
    public let defaultFor: [String]
    public let inputs: [StreamInfo]
    public let outputs: [StreamInfo]
    public let nmsScore: Float?
    public let nmsIoU: Float?
    public let op: String?

    public var id: String { name }
    public var inputWidth: Int { inputs.first?.width ?? 0 }
    public var inputHeight: Int { inputs.first?.height ?? 0 }
    /// True when the device runs box decoding and NMS itself and returns finished detections.
    public var hasDeviceNMS: Bool { outputs.count == 1 && outputs[0].isNMS }
}

/// The models UGenKit knows about: every Hailo-10H vision model used by Hailo Studio.
public enum ModelCatalog {
    /// Every model in the table (all of Hailo's, for the stick).
    public static let everything: [ModelInfo] = {
        guard let url = Bundle.module.url(forResource: "models", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let models = try? JSONDecoder().decode([ModelInfo].self, from: data) else { return [] }
        return models
    }()

    /// An app that offers only some of the models (Artelico: those in its model repository) sets this
    /// once at launch, before any screen reads the catalog. nil = every model (Hailo Studio).
    nonisolated(unsafe) public static var only: Set<String>? {
        didSet { all = only.map { names in everything.filter { names.contains($0.name) } } ?? everything }
    }

    /// The models this app offers.
    nonisolated(unsafe) public private(set) static var all: [ModelInfo] = everything

    public static func model(named name: String) -> ModelInfo? { all.first { $0.name == name } }

    /// Models for a task, default model first, then by name.
    public static func models(for task: String) -> [ModelInfo] {
        let names = VisionTask(rawValue: task)?.catalogTasks ?? [task]
        return all.filter { $0.tasks.contains(where: names.contains) }.sorted {
            let a = $0.defaultFor.contains(task), b = $1.defaultFor.contains(task)
            return a != b ? a : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// Label sets shipped with UGenKit.
public enum Labels {
    private struct File: Decodable {
        struct Cityscape: Decodable { let name: String; let color: [Int] }
        let imagenet: [String]
        let cityscapes: [Cityscape]
        let dota: [String]
        let kinetics400: [String]
    }

    private static let file: File? = {
        guard let url = Bundle.module.url(forResource: "labels", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }()

    public static let imagenet: [String] = file?.imagenet ?? []
    public static let cityscapes: [String] = file?.cityscapes.map(\.name) ?? []
    /// RGB colour per Cityscapes class.
    public static let cityscapesColors: [[UInt8]] = file?.cityscapes.map { $0.color.map { UInt8(clamping: $0) } } ?? []
    public static let dota: [String] = file?.dota ?? []
    /// The 400 actions of DeepMind's Kinetics-400 video set (the Model Zoo's kinetics400_names.json).
    public static let kinetics400: [String] = file?.kinetics400 ?? []

    public static let coco: [String] = [
        "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat", "traffic light",
        "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep", "cow",
        "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella", "handbag", "tie", "suitcase", "frisbee",
        "skis", "snowboard", "sports ball", "kite", "baseball bat", "baseball glove", "skateboard", "surfboard",
        "tennis racket", "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
        "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair", "couch",
        "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse", "remote", "keyboard",
        "cell phone", "microwave", "oven", "toaster", "sink", "refrigerator", "book", "clock", "vase",
        "scissors", "teddy bear", "hair drier", "toothbrush",
    ]

    /// COCO as numbered in the original paper: 90 ids, some unused. Used by the SSD detectors, whose
    /// class 0 is id 1.
    public static let cocoPaper: [String] = [
        "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat", "traffic light",
        "fire hydrant", "N/A", "stop sign", "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep",
        "cow", "elephant", "bear", "zebra", "giraffe", "N/A", "backpack", "umbrella", "N/A", "N/A",
        "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball", "kite", "baseball bat",
        "baseball glove", "skateboard", "surfboard", "tennis racket", "bottle", "N/A", "wine glass", "cup", "fork",
        "knife", "spoon", "bowl", "banana", "apple", "sandwich", "orange", "broccoli", "carrot", "hot dog",
        "pizza", "donut", "cake", "chair", "couch", "potted plant", "bed", "N/A", "dining table", "N/A",
        "N/A", "toilet", "N/A", "tv", "laptop", "mouse", "remote", "keyboard", "cell phone", "microwave",
        "oven", "toaster", "sink", "refrigerator", "N/A", "book", "clock", "vase", "scissors", "teddy bear",
        "hair drier", "toothbrush",
    ]

    /// DETR's 91 class ids: 0 is unused ("N/A"), then the paper's numbering.
    public static let coco91: [String] = ["N/A"] + cocoPaper

    /// From hailo-apps' hailo_4_classes.json and visdrone.json, without their leading "unlabeled" entry.
    public static let hailoFourClasses = ["person", "vehicle", "face", "license plate"]
    public static let visdrone = ["person", "person", "bicycle", "car", "van", "truck", "tricycle", "awning-tricycle", "bus", "motor", "others"]

    /// Labels for a detection model. Unknown sets fall back to "class N".
    public static func detection(for model: ModelInfo) -> [String] {
        let count = model.outputs.first?.classes ?? 0
        if model.name.contains("visdrone") { return padded(visdrone, to: count) }
        if model.name.contains("4_classes") { return padded(hailoFourClasses, to: count) }
        if count == coco.count { return coco }
        if count == cocoPaper.count { return cocoPaper }
        return padded([], to: count)
    }

    private static func padded(_ labels: [String], to count: Int) -> [String] {
        labels.count >= count ? labels : labels + (labels.count..<count).map { "class \($0)" }
    }
}

/// One output frame from the device, in the model's own data type.
public struct Tensor: Sendable {
    public let stream: StreamInfo
    public let bytes: [UInt8]

    public init(stream: StreamInfo, bytes: [UInt8]) {
        self.stream = stream
        self.bytes = bytes
    }

    public var height: Int { stream.height ?? 1 }
    public var width: Int { stream.width ?? 1 }
    public var features: Int { stream.features ?? 1 }

    /// Real values in NHWC order: (raw - zero point) * scale.
    public func floats() -> [Float] {
        if let scales = stream.qpScales, let zeros = stream.qpZps, scales.count == features, zeros.count == features, stream.type != "FLOAT32" {
            let wide = stream.type == "UINT16"
            let count = bytes.count / (wide ? 2 : 1)
            return bytes.withUnsafeBytes { raw in
                (0..<count).map { i in
                    let value = wide ? Float(raw.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self)) : Float(raw[i])
                    return (value - zeros[i % features]) * scales[i % features]
                }
            }
        }
        let zeroPoint = stream.qpZp ?? 0
        let scale = stream.qpScale ?? 1
        switch stream.type {
        case "UINT16":
            let count = bytes.count / 2
            return [Float](unsafeUninitializedCapacity: count) { out, initialized in
                bytes.withUnsafeBytes { raw in
                    for i in 0..<count {
                        let value = UInt16(raw[2 * i]) | UInt16(raw[2 * i + 1]) << 8
                        out[i] = (Float(value) - zeroPoint) * scale
                    }
                }
                initialized = count
            }
        case "FLOAT32":
            let count = bytes.count / 4
            return bytes.withUnsafeBytes { raw in
                (0..<count).map { raw.loadUnaligned(fromByteOffset: 4 * $0, as: Float.self) }
            }
        default:
            let count = bytes.count
            return [Float](unsafeUninitializedCapacity: count) { out, initialized in
                bytes.withUnsafeBytes { raw in
                    for i in 0..<count { out[i] = (Float(raw[i]) - zeroPoint) * scale }
                }
                initialized = count
            }
        }
    }

    /// The same values as float32 when the stream is quantized per channel, so decoders that read one
    /// scale and zero point (or float32) handle it; other tensors are returned unchanged.
    public var withPerChannelDequantized: Tensor {
        guard stream.qpScales != nil, stream.type != "FLOAT32" else { return self }
        return Tensor(stream: stream.asFloat32, bytes: floats().withUnsafeBytes { Array($0) })
    }
}
