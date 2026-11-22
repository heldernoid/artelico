import CoreGraphics
import CoreML
import Foundation
import UGenKit

/// `ugen native-map <task> <model> <image> <model.mlpackage>`
///
/// Runs a model on the stick and its Core ML conversion on this Mac with the same input frame, works
/// out how the Core ML outputs line up with the stick's (which output, which activation Hailo's script
/// adds on the chip, or which candidate layout feeds the NMS), writes `<model>.native.json` next to the
/// package, and compares the decoded results.
/// `text` is the second input of a two-input model that is not a picture (YOLO-World's prompt embeddings).
func nativeMap(task: VisionTask, model: ModelInfo, image: CGImage, package: URL, device: UGenDevice, second: CGImage? = nil,
               text: [UInt8]? = nil) async throws {
    let frame = try VisionPipeline.prepare(image, for: model, task: task)
    // Two-input models (stereo) get the second picture, or the same one again.
    var frames = [frame.rgb]
    if model.inputs.count == 2 { frames.append(try text ?? VisionPipeline.prepare(second ?? image, for: model, task: task).rgb) }
    let stickTensors = try await device.infer(inputs: frames)

    let compiled = try await CoreMLEngine.compiledModel(at: package)
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuOnly   // full float32 maths for the comparison
    let mlModel = try MLModel(contentsOf: compiled, configuration: configuration)
    if model.outputs.count == 1, model.outputs[0].isByteMaskNMS {
        try await nativeMapByteMask(task: task, model: model, frame: frame, stickTensors: stickTensors, mlModel: mlModel, package: package)
        return
    }

    // A conversion with another input size than the stick's (the Model Zoo only has some models at
    // another resolution), or a single output of another size (another vocabulary), is described by
    // its own ModelInfo and compared on decoded results.
    if let constraint = mlModel.modelDescription.inputDescriptionsByName["image"]?.imageConstraint {
        let sameInput = constraint.pixelsWide == model.inputWidth && constraint.pixelsHigh == model.inputHeight
        var singleOutputMismatch = false
        if sameInput, model.outputs.count == 1, !model.hasDeviceNMS {
            let probe = try await mlModel.prediction(from: CoreMLEngine.inputProvider(frames, model: mlModel, info: model))
            let counts = probe.featureNames.compactMap { probe.featureValue(for: $0)?.multiArrayValue?.count }
            singleOutputMismatch = counts.count == 1 && counts[0] != stickTensors[0].floats().count
        }
        if !sameInput || singleOutputMismatch {
            try await nativeMapDifferent(task: task, model: model, image: image, frame: frame, stickTensors: stickTensors,
                                         mlModel: mlModel, width: constraint.pixelsWide, height: constraint.pixelsHigh, package: package)
            return
        }
    }
    // With two or more inputs, try the default order and its reverse; keep the one closer to the stick.
    var inputOrder: [String]? = nil
    var raw = try await mlModel.prediction(from: CoreMLEngine.inputProvider(frames, model: mlModel, info: model))
    if frames.count > 1, !model.hasDeviceNMS, text == nil {
        let reversed = Array(CoreMLEngine.defaultInputOrder(mlModel).prefix(frames.count).reversed())
        let other = try await mlModel.prediction(from: CoreMLEngine.inputProvider(frames, model: mlModel, info: model, order: reversed))
        let reference = stickTensors[0].floats()
        func error(_ provider: MLFeatureProvider) -> Float {
            provider.featureNames.compactMap { provider.featureValue(for: $0)?.multiArrayValue }
                .filter { $0.count == reference.count }
                .map { meanAbsoluteDifference(CoreMLEngine.nhwc($0, stream: model.outputs[0]), reference) }
                .min() ?? .infinity
        }
        let (a, b) = (error(raw), error(other))
        print(String(format: "input order: default %.3f, reversed %.3f", a, b))
        if b < a { raw = other; inputOrder = reversed }
    }
    // A network trained on BGR pictures whose Hailo script swaps the channels on the chip needs them
    // swapped for Core ML too; taken only when clearly closer to the stick.
    var bgr: Bool? = nil
    if frames.count == 1, !model.hasDeviceNMS, mlModel.modelDescription.inputDescriptionsByName["image"]?.imageConstraint != nil {
        let swapped = try await mlModel.prediction(from: CoreMLEngine.inputProvider(frames, model: mlModel, info: model, bgr: true))
        let reference = stickTensors[0].floats()
        // Raw or with a sigmoid (which the chip may add), whichever is closer.
        func error(_ provider: MLFeatureProvider) -> Float {
            provider.featureNames.compactMap { provider.featureValue(for: $0)?.multiArrayValue }
                .filter { $0.count == reference.count }
                .map { array -> Float in
                    let values = CoreMLEngine.nhwc(array, stream: model.outputs[0])
                    return min(meanAbsoluteDifference(values, reference), meanAbsoluteDifference(apply("sigmoid", to: values), reference))
                }
                .min() ?? .infinity
        }
        let (a, b) = (error(raw), error(swapped))
        print(String(format: "channels: RGB %.4f, BGR %.4f (first output, mean |diff|)", a, b))
        if b < a * 0.7 { raw = swapped; bgr = true }
    }
    var arrays: [(name: String, array: MLMultiArray)] = []
    for name in raw.featureNames.sorted() {
        if let array = raw.featureValue(for: name)?.multiArrayValue { arrays.append((name, array)) }
    }
    print("Core ML outputs: " + arrays.map { "\($0.name) \($0.array.shape.map(\.intValue))" }.joined(separator: ", "))
    print("stick outputs:   " + model.outputs.map { "\($0.name) \($0.order) h\($0.height ?? 0) w\($0.width ?? 0) c\($0.features ?? 0)" }.joined(separator: ", "))

    var map: NativeModelMap
    var nativeTensors: [Tensor] = []
    if model.hasDeviceNMS {
        let classes = model.outputs[0].classes ?? 80
        map = try detectionMap(arrays: arrays, classes: classes, model: model, package: package)
        let byName = Dictionary(uniqueKeysWithValues: arrays.map { ($0.name, $0.array) })
        nativeTensors = [CoreMLEngine.nmsTensor(map.outputs.compactMap { byName[$0.source] }, map: map, model: model)]
        print("detection layout: \(map.detection!.rawValue) from " + map.outputs.map(\.source).joined(separator: ", "))
    } else {
        var used = Set<String>()
        var outputs: [NativeModelMap.Output] = []
        for (index, stream) in model.outputs.enumerated() {
            let reference = stickTensors[index].floats()
            let spread = max(standardDeviation(reference), 1e-6)
            var best: (name: String, activation: String?, error: Float, values: [Float])?
            for (name, array) in arrays where !used.contains(name) && array.count == reference.count {
                let values = CoreMLEngine.nhwc(array, stream: stream)
                // An activation is only taken when it fits clearly better than the raw values (Hailo's
                // scripts add one on some outputs); class maps and plain outputs stay as they are.
                let plainError = meanAbsoluteDifference(values, reference) / spread
                var choice: (activation: String?, error: Float, values: [Float]) = (nil, plainError, values)
                // softmax only for a flat vector of class scores; sigmoid only when the Core ML values leave
                // 0...1 while the stick's stay inside it (a probability the chip computes from logits); tanh
                // likewise for -1...1 (YOLACT's mask coefficients).
                let isIntegerMap = array.dataType == .int32
                let isVector = stream.order == "NC" || ((stream.height ?? 1) == 1 && (stream.width ?? 1) == 1)
                let stickIn01 = (reference.min() ?? 0) >= -0.01 && (reference.max() ?? 0) <= 1.01
                let nativeIn01 = (values.min() ?? 0) >= -0.01 && (values.max() ?? 0) <= 1.01
                var candidates: [String] = []
                let stickIn11 = (reference.min() ?? 0) >= -1.01 && (reference.max() ?? 0) <= 1.01
                let nativeIn11 = (values.min() ?? 0) >= -1.01 && (values.max() ?? 0) <= 1.01
                if stickIn01 && !nativeIn01 { candidates.append("sigmoid") }
                if stickIn11 && !nativeIn11 && !stickIn01 { candidates.append("tanh") }
                if isVector && stickIn01 { candidates.append("softmax") }
                if !isIntegerMap {
                    for activation in candidates {
                        let candidate = apply(activation, to: values)
                        let error = meanAbsoluteDifference(candidate, reference) / spread
                        if error < choice.error * 0.5 { choice = (activation, error, candidate) }
                    }
                }
                if best == nil || choice.error < best!.error { best = (name, choice.activation, choice.error, choice.values) }
            }
            guard let best else { throw UGenError.invalidInput("No Core ML output has \(reference.count) values for \(stream.name).") }
            used.insert(best.name)
            outputs.append(.init(source: best.name, activation: best.activation))
            nativeTensors.append(CoreMLEngine.tensor(best.values, like: stream))
            print(String(format: "  %@ <- %@%@: mean |diff| = %.3f x stick spread", stream.name, best.name,
                         best.activation.map { " + \($0)" } ?? "", best.error))
        }
        map = NativeModelMap(outputs: outputs, inputs: inputOrder, bgr: bgr)
    }

    let mapURL = package.deletingPathExtension().appendingPathExtension("native.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(map).write(to: mapURL)
    print("wrote \(mapURL.path)")

    let stickResult = VisionPipeline.decode(stickTensors, task: task, model: model, frame: frame)
    let nativeResult = VisionPipeline.decode(nativeTensors, task: task, model: model, frame: frame)
    print("stick:   \(stickResult.summary)")
    print("Core ML: \(nativeResult.summary)")
    if case .detections(let a) = stickResult, case .detections(let b) = nativeResult {
        compareDetections(a, b)
    }
    if case .instances(let a) = stickResult, case .instances(let b) = nativeResult { compareInstances(a, b) }
    if case .poses(let a) = stickResult, case .poses(let b) = nativeResult {
        compareDetections(a.map { Detection(label: "person", classIndex: 0, confidence: $0.confidence, boundingBox: $0.boundingBox) },
                          b.map { Detection(label: "person", classIndex: 0, confidence: $0.confidence, boundingBox: $0.boundingBox) })
    }

    // The engine with the new map must give the same result as above (checks the app's path).
    let engine = CoreMLEngine()
    try await engine.load(model, from: package, computeUnits: .all)
    let viaEngine = VisionPipeline.decode(try await engine.infer(inputs: frames), task: task, model: model, frame: frame)
    print("engine (Neural Engine allowed): \(viaEngine.summary)")
}

private func apply(_ activation: String?, to values: [Float]) -> [Float] {
    switch activation {
    case "sigmoid": return values.map { 1 / (1 + exp(-$0)) }
    case "tanh": return values.map { tanh($0) }
    case "softmax":
        let peak = values.max() ?? 0
        let exps = values.map { exp($0 - peak) }
        let total = exps.reduce(0, +)
        return exps.map { $0 / total }
    default: return values
    }
}

private func meanAbsoluteDifference(_ a: [Float], _ b: [Float]) -> Float {
    var total: Float = 0
    for i in 0..<min(a.count, b.count) { total += abs(a[i] - b[i]) }
    return total / Float(max(1, min(a.count, b.count)))
}

private func standardDeviation(_ values: [Float]) -> Float {
    let mean = values.reduce(0, +) / Float(max(1, values.count))
    let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(max(1, values.count))
    return variance.squareRoot()
}

/// For each stick detection, the best-overlapping Core ML detection of the same class.
private func compareDetections(_ stick: [Detection], _ native: [Detection]) {
    func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height
        return inter / (a.width * a.height + b.width * b.height - inter)
    }
    let top = stick.filter { $0.confidence >= 0.3 }
    var matched = 0
    var ious: [CGFloat] = []
    var scoreDiffs: [Float] = []
    for d in top {
        let candidates = native.filter { $0.classIndex == d.classIndex }
        guard let best = candidates.max(by: { iou($0.boundingBox, d.boundingBox) < iou($1.boundingBox, d.boundingBox) }) else { continue }
        let overlap = iou(best.boundingBox, d.boundingBox)
        if overlap >= 0.5 { matched += 1; ious.append(overlap); scoreDiffs.append(abs(best.confidence - d.confidence)) }
    }
    let nativeTop = native.filter { $0.confidence >= 0.3 }.count
    print(String(format: "match: %d of %d stick objects (>= 0.3) found by Core ML (it has %d), mean IoU %.3f, mean |score diff| %.3f",
                 matched, top.count, nativeTop, ious.isEmpty ? 0 : ious.reduce(0, +) / CGFloat(ious.count),
                 scoreDiffs.isEmpty ? 0 : scoreDiffs.reduce(0, +) / Float(scoreDiffs.count)))
}

/// Works out how a detector's Core ML outputs feed the engine's decoder when the stick runs NMS on the chip.
private func detectionMap(arrays: [(name: String, array: MLMultiArray)], classes: Int, model: ModelInfo, package: URL) throws -> NativeModelMap {
    // Whole decoded export: one [1, 4+C, N] or [1, N, 5+C] output.
    for (name, array) in arrays {
        let dims = array.shape.map(\.intValue)
        guard dims.count == 3 else { continue }
        if dims[1] == 4 + classes { return NativeModelMap(outputs: [.init(source: name)], detection: .boxesThenScores) }
        if dims[2] == 5 + classes { return NativeModelMap(outputs: [.init(source: name)], detection: .boxesObjectnessScores) }
    }
    // Anchor heads: [1, A, H, W, 5+C] per stride, largest grid (smallest stride) first.
    let anchorHeads = arrays.filter {
        let d = $0.array.shape.map(\.intValue)
        return (d.count == 5 && d[4] == 5 + classes) || (d.count == 4 && d[1] % (5 + classes) == 0 && d[1] / (5 + classes) <= 4)
    }.sorted { $0.array.shape[3].intValue > $1.array.shape[3].intValue }   // grid width is dimension 3 in both layouts
    if !anchorHeads.isEmpty {
        // The anchors the chip uses are in the model's NMS config (native/src/<name>/<name>_nms_config.json).
        // Without that file, fall back to the anchors in the Model Zoo config (native/zoo-configs.json).
        // yolov7x ships without one; it uses the anchors of the YOLOv7 family.
        var config = root.appendingPathComponent("native/src/\(model.name)/\(model.name)_nms_config.json")
        if !FileManager.default.fileExists(atPath: config.path), model.name.hasPrefix("yolov7") {
            config = root.appendingPathComponent("native/src/yolov7/yolov7_nms_config.json")
            print("anchors from \(config.lastPathComponent) (same family)")
        }
        var decoders: [[String: Any]] = []
        if let data = try? Data(contentsOf: config),
           let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let found = json["bbox_decoders"] as? [[String: Any]] {
            decoders = found
        } else if let data = try? Data(contentsOf: root.appendingPathComponent("native/zoo-configs.json")),
                  let all = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let entry = all.first(where: { $0["name"] as? String == model.name }),
                  let sizes = entry["anchors"] as? [[NSNumber]], let strides = entry["strides"] as? [Int] {
            print("anchors from the Model Zoo config (no \(config.lastPathComponent))")
            decoders = zip(sizes, strides).map { pairs, stride in
                ["stride": stride, "w": stride_values(pairs, 0), "h": stride_values(pairs, 1)]
            }
        } else {
            throw UGenError.invalidInput("No anchors for \(model.name).")
        }
        let sorted = decoders.sorted { ($0["stride"] as? Int ?? 0) < ($1["stride"] as? Int ?? 0) }
        let anchors: [[Float]] = sorted.map { decoder in
            let w = (decoder["w"] as? [NSNumber] ?? []).map(\.floatValue), h = (decoder["h"] as? [NSNumber] ?? []).map(\.floatValue)
            return zip(w, h).flatMap { [$0, $1] }
        }
        return NativeModelMap(outputs: anchorHeads.map { .init(source: $0.name) }, detection: .anchorHeads, anchors: anchors)
    }
    // DFL heads: per grid size a 4 x bins box output and a C-class output.
    let fourD = arrays.filter { $0.array.shape.count == 4 }
    let boxes = fourD.filter { let c = $0.array.shape[1].intValue; return c % 4 == 0 && c != classes && c >= 16 }
    let scores = fourD.filter { $0.array.shape[1].intValue == classes }
    var outputs: [NativeModelMap.Output] = []
    for box in boxes.sorted(by: { $0.array.shape[3].intValue > $1.array.shape[3].intValue }) {
        let size = (box.array.shape[2].intValue, box.array.shape[3].intValue)
        guard let score = scores.first(where: { ($0.array.shape[2].intValue, $0.array.shape[3].intValue) == size }) else { continue }
        outputs += [.init(source: box.name), .init(source: score.name)]
    }
    if !outputs.isEmpty { return NativeModelMap(outputs: outputs, detection: .dflHeads) }
    throw UGenError.invalidInput("No Core ML output layout recognised for a \(classes)-class detector: " +
                                 arrays.map { "\($0.name) \($0.array.shape.map(\.intValue))" }.joined(separator: ", "))
}

/// Every other value of a flattened (w, h, w, h, ...) anchor list.
private func stride_values(_ pairs: [NSNumber], _ offset: Int) -> [NSNumber] {
    stride(from: offset, to: pairs.count, by: 2).map { pairs[$0] }
}

/// The native model's own description: the stick's, with the conversion's input size, output grids
/// scaled to match, and a single output resized to `singleOutputCount` values.
private func nativeDescription(_ model: ModelInfo, width: Int, height: Int, singleOutputCount: Int?) throws -> ModelInfo {
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as! [String: Any]
    var inputs = json["inputs"] as! [[String: Any]]
    inputs[0]["width"] = width
    inputs[0]["height"] = height
    inputs[0]["frameSize"] = width * height * 3
    json["inputs"] = inputs
    let scaleX = Double(width) / Double(model.inputWidth), scaleY = Double(height) / Double(model.inputHeight)
    var outputs = json["outputs"] as! [[String: Any]]
    for i in outputs.indices where outputs[i]["order"] as? String != "NMS_BY_CLASS" {
        var h = outputs[i]["height"] as? Int ?? 1, w = outputs[i]["width"] as? Int ?? 1
        var f = outputs[i]["features"] as? Int ?? 1
        if h > 1 { h = Int((Double(h) * scaleY).rounded()) }
        if w > 1 { w = Int((Double(w) * scaleX).rounded()) }
        if let count = singleOutputCount, outputs.count == 1 { f = count / max(1, h * w) }
        outputs[i]["height"] = h
        outputs[i]["width"] = w
        outputs[i]["features"] = f
        // Keep the stick's element type and quantization: the engine hands quantized outputs over as
        // UINT16 over the same range, which every decoder reads.
        let bytes = (outputs[i]["type"] as? String) == "UINT16" ? 2 : ((outputs[i]["type"] as? String) == "FLOAT32" ? 4 : 1)
        outputs[i]["frameSize"] = h * w * f * bytes
    }
    json["outputs"] = outputs
    return try JSONDecoder().decode(ModelInfo.self, from: JSONSerialization.data(withJSONObject: json))
}

private func nativeMapDifferent(task: VisionTask, model: ModelInfo, image: CGImage, frame: PreparedFrame, stickTensors: [Tensor],
                                mlModel: MLModel, width: Int, height: Int, package: URL) async throws {
    var singleCount: Int?
    if width == model.inputWidth && height == model.inputHeight {
        let probe = try await mlModel.prediction(from: CoreMLEngine.inputProvider([frame.rgb], model: mlModel, info: model))
        singleCount = probe.featureNames.compactMap { probe.featureValue(for: $0)?.multiArrayValue?.count }.first
    }
    let native = try nativeDescription(model, width: width, height: height, singleOutputCount: singleCount)
    print("native model differs from the stick's: input \(width)x\(height) (stick \(model.inputWidth)x\(model.inputHeight))"
          + (singleCount.map { ", output \($0) values (stick \(stickTensors[0].floats().count))" } ?? ""))
    let nativeFrame = try VisionPipeline.prepare(image, for: native, task: task)
    let raw = try await mlModel.prediction(from: CoreMLEngine.inputProvider([nativeFrame.rgb], model: mlModel, info: native))
    let arrays: [(name: String, array: MLMultiArray)] = raw.featureNames.sorted().compactMap { name in
        raw.featureValue(for: name)?.multiArrayValue.map { (name, $0) }
    }
    var used = Set<String>()
    var outputs: [NativeModelMap.Output] = []
    var nativeTensors: [Tensor] = []
    for (index, stream) in native.outputs.enumerated() {
        let count = (stream.height ?? 1) * (stream.width ?? 1) * (stream.features ?? 1)
        guard let match = arrays.first(where: { !used.contains($0.name) && $0.array.count == count }) else {
            throw UGenError.invalidInput("No Core ML output has \(count) values for \(stream.name).")
        }
        used.insert(match.name)
        var values = CoreMLEngine.nhwc(match.array, stream: stream)
        // Same activation rule as for same-size models, judged against the stick's matching output.
        let reference = stickTensors[index].floats()
        let stickIn01 = (reference.min() ?? 0) >= -0.01 && (reference.max() ?? 0) <= 1.01
        let nativeIn01 = (values.min() ?? 0) >= -0.01 && (values.max() ?? 0) <= 1.01
        var activation: String?
        if stickIn01 && !nativeIn01 && match.array.dataType != .int32 {
            activation = "sigmoid"
            values = values.map { 1 / (1 + exp(-$0)) }
        }
        outputs.append(.init(source: match.name, activation: activation))
        nativeTensors.append(CoreMLEngine.tensor(values, like: stream))
        print(String(format: "  %@ h%d w%d c%d <- %@%@   stick %.2f..%.2f, Core ML %.2f..%.2f", stream.name, stream.height ?? 0, stream.width ?? 0,
                     stream.features ?? 0, match.name, activation.map { " + \($0)" } ?? "", reference.min() ?? 0, reference.max() ?? 0,
                     CoreMLEngine.nhwc(match.array, stream: stream).min() ?? 0, CoreMLEngine.nhwc(match.array, stream: stream).max() ?? 0))
    }
    let map = NativeModelMap(outputs: outputs, model: native)
    let mapURL = package.deletingPathExtension().appendingPathExtension("native.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(map).write(to: mapURL)
    print("wrote \(mapURL.path)")

    if model.name == "ocr" {
        print("stick:   \"\(PostProcess.recognizedText(stickTensors[0]).text)\"")
        print("Core ML: \"\(PostProcess.recognizedText(nativeTensors[0]).text)\"")
    } else {
        let stickResult = VisionPipeline.decode(stickTensors, task: task, model: model, frame: frame)
        let nativeResult = VisionPipeline.decode(nativeTensors, task: task, model: native, frame: nativeFrame)
        print("stick:   \(stickResult.summary)")
        print("Core ML: \(nativeResult.summary)")
    }
    let engine = CoreMLEngine()
    try await engine.load(model, from: package, computeUnits: .all)
    let viaEngine = try await engine.infer(inputs: [nativeFrame.rgb])
    if model.name == "ocr" {
        print("engine (Neural Engine allowed): \"\(PostProcess.recognizedText(viaEngine[0]).text)\"")
    } else {
        print("engine (Neural Engine allowed): \(VisionPipeline.decode(viaEngine, task: task, model: native, frame: nativeFrame).summary)")
    }
}
