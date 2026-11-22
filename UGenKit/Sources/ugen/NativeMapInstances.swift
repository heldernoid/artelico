import CoreGraphics
import CoreML
import Foundation
import UGenKit

/// For each stick instance (>= 0.3), the Core ML instance of the same class with the best box overlap,
/// and how well their masks agree (IoU over the source picture, sampled on a 256 x 256 grid).
func compareInstances(_ stick: [Instance], _ native: [Instance]) {
    func boxIoU(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        return i.width * i.height / (a.width * a.height + b.width * b.height - i.width * i.height)
    }
    let top = stick.filter { $0.detection.confidence >= 0.3 }
    var boxIoUs: [CGFloat] = [], maskIoUs: [Double] = []
    for item in top {
        let same = native.filter { $0.detection.classIndex == item.detection.classIndex }
        guard let best = same.max(by: { boxIoU($0.detection.boundingBox, item.detection.boundingBox) < boxIoU($1.detection.boundingBox, item.detection.boundingBox) }),
              boxIoU(best.detection.boundingBox, item.detection.boundingBox) >= 0.5 else { continue }
        boxIoUs.append(boxIoU(best.detection.boundingBox, item.detection.boundingBox))
        maskIoUs.append(maskIoU(item, best))
    }
    print(String(format: "match: %d of %d stick instances (>= 0.3) found by Core ML (it has %d), mean box IoU %.3f, mean mask IoU %.3f",
                 boxIoUs.count, top.count, native.filter { $0.detection.confidence >= 0.3 }.count,
                 boxIoUs.isEmpty ? 0 : boxIoUs.reduce(0, +) / CGFloat(boxIoUs.count),
                 maskIoUs.isEmpty ? 0 : maskIoUs.reduce(0, +) / Double(maskIoUs.count)))
}

/// Masks cover the whole source picture at their own resolution; both are sampled on one grid.
func maskIoU(_ a: Instance, _ b: Instance, grid: Int = 256) -> Double {
    func inside(_ item: Instance, _ x: Int, _ y: Int) -> Bool {
        let mx = x * item.maskWidth / grid, my = y * item.maskHeight / grid
        return item.mask[my * item.maskWidth + mx] != 0
    }
    var both = 0, either = 0
    for y in 0..<grid {
        for x in 0..<grid {
            let p = inside(a, x, y), q = inside(b, x, y)
            if p && q { both += 1 }
            if p || q { either += 1 }
        }
    }
    return either == 0 ? 0 : Double(both) / Double(either)
}

/// Writes each instance's mask resampled to `width` x `height` (one byte per pixel, 0 or 1, one after
/// the other), for comparisons with a Python reference.
func writeMasks(_ instances: [Instance], width: Int, height: Int, to path: String) throws {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(instances.count * width * height)
    for item in instances {
        for y in 0..<height {
            for x in 0..<width {
                bytes.append(item.mask[(y * item.maskHeight / height) * item.maskWidth + x * item.maskWidth / width] != 0 ? 1 : 0)
            }
        }
    }
    try Data(bytes).write(to: URL(fileURLWithPath: path))
}

/// `native-map` for a model whose device output is NMS_BYTE_MASK (YOLOv5-seg "hpp"): the Core ML
/// conversion is the same network without Hailo's post-processing, so it is described by the plain
/// model's outputs (yolov5n_seg_hpp -> yolov5n_seg) under the hpp model's name, and decoded like it.
func nativeMapByteMask(task: VisionTask, model: ModelInfo, frame: PreparedFrame, stickTensors: [Tensor], mlModel: MLModel,
                       package: URL) async throws {
    let plainName = model.name.replacingOccurrences(of: "_hpp", with: "")
    guard let plain = ModelCatalog.everything.first(where: { $0.name == plainName }) else {
        throw UGenError.invalidInput("No plain model \(plainName) to describe the Core ML outputs of \(model.name).")
    }
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as! [String: Any]
    json["name"] = model.name
    json["tasks"] = model.tasks
    json["url"] = model.url
    json["fileSize"] = model.fileSize
    let native = try JSONDecoder().decode(ModelInfo.self, from: JSONSerialization.data(withJSONObject: json))

    let raw = try await mlModel.prediction(from: CoreMLEngine.inputProvider([frame.rgb], model: mlModel, info: native))
    let arrays: [(name: String, array: MLMultiArray)] = raw.featureNames.sorted().compactMap { name in
        raw.featureValue(for: name)?.multiArrayValue.map { (name, $0) }
    }
    var outputs: [NativeModelMap.Output] = []
    var nativeTensors: [Tensor] = []
    for stream in native.outputs {
        let count = (stream.height ?? 1) * (stream.width ?? 1) * (stream.features ?? 1)
        guard let match = arrays.first(where: { $0.array.count == count }) else {
            throw UGenError.invalidInput("No Core ML output has \(count) values for \(stream.name).")
        }
        outputs.append(.init(source: match.name))
        nativeTensors.append(CoreMLEngine.tensor(CoreMLEngine.nhwc(match.array, stream: stream), like: stream))
        print("  \(stream.name) h\(stream.height ?? 0) w\(stream.width ?? 0) c\(stream.features ?? 0) <- \(match.name)")
    }
    let mapURL = package.deletingPathExtension().appendingPathExtension("native.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(NativeModelMap(outputs: outputs, model: native)).write(to: mapURL)
    print("wrote \(mapURL.path) (outputs described as \(plainName)'s)")

    let stickResult = VisionPipeline.decode(stickTensors, task: task, model: model, frame: frame)
    let nativeResult = VisionPipeline.decode(nativeTensors, task: task, model: native, frame: frame)
    print("stick:   \(stickResult.summary)")
    print("Core ML: \(nativeResult.summary)")
    if case .instances(let a) = stickResult, case .instances(let b) = nativeResult { compareInstances(a, b) }

    let engine = CoreMLEngine()
    try await engine.load(model, from: package, computeUnits: .all)
    guard let loaded = await engine.loadedModel else { return }
    let viaEngine = VisionPipeline.decode(try await engine.infer(inputs: [frame.rgb]), task: task, model: loaded, frame: frame)
    print("engine (Neural Engine allowed): \(viaEngine.summary)")
}
