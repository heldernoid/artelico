import CoreML
import CoreVideo
import Foundation

/// How a Core ML conversion of a model lines up with the stick's version of it. Written by
/// `ugen native-map` (which runs both and compares) next to the model as `<name>.native.json`.
public struct NativeModelMap: Codable, Sendable {
    public struct Output: Codable, Sendable {
        /// Core ML output that becomes this stick output (same index in `ModelInfo.outputs`).
        public var source: String
        /// Applied after reading: "sigmoid", "tanh", "softmax" or nil. Hailo's model scripts sometimes add an
        /// activation on the chip that the original graph does not have.
        public var activation: String?

        public init(source: String, activation: String? = nil) {
            self.source = source
            self.activation = activation
        }
    }

    public enum DetectionLayout: String, Codable, Sendable {
        /// One output [1, 4 + classes, candidates]: center x, center y, width, height (input pixels),
        /// class scores (full YOLOv8/v11 export).
        case boxesThenScores
        /// One output [1, candidates, 5 + classes]: center x, center y, width, height, objectness, class
        /// scores (full YOLOv5/v7 export).
        case boxesObjectnessScores
        /// Per stride a box output [1, 4 x 16, H, W] (distance distributions, DFL) and a class output
        /// [1, classes, H, W] (logits); `outputs` lists them box, class, box, class... (YOLOv8/v10/v11 cut
        /// where Hailo's decoding starts).
        case dflHeads
        /// Per stride one output [1, anchors, H, W, 5 + classes] of logits; `anchors` gives each stride's
        /// anchor sizes in input pixels (YOLOv5/v7 cut where Hailo's decoding starts).
        case anchorHeads
    }

    public var outputs: [Output]
    /// Set when the stick runs NMS on the chip and the Core ML model returns raw candidates instead;
    /// the engine then decodes them, runs NMS and writes the stick's NMS layout.
    public var detection: DetectionLayout?
    /// `anchorHeads` only: per output, anchor (width, height) pairs in input pixels, flattened.
    public var anchors: [[Float]]?
    /// Core ML input names in the order of the stick's inputs, when that differs from the default
    /// ("image", "image_2", ...); for example stereonet, whose compiled model lists the right picture first.
    public var inputs: [String]?
    /// The native model's own description when it differs from the stick's (another input size, or a
    /// different output shape such as PaddleOCR v5's multilingual recogniser). Same name as the stick's.
    public var model: ModelInfo?
    /// True when the Core ML model wants its pictures blue-first: the original network was trained on BGR
    /// and Hailo's script swaps the channels on the chip, so the stick takes RGB (centerpose's
    /// input_conversion(bgr_to_rgb)).
    public var bgr: Bool?

    public init(outputs: [Output], detection: DetectionLayout? = nil, anchors: [[Float]]? = nil, inputs: [String]? = nil, model: ModelInfo? = nil,
                bgr: Bool? = nil) {
        self.outputs = outputs
        self.detection = detection
        self.anchors = anchors
        self.inputs = inputs
        self.model = model
        self.bgr = bgr
    }
}

/// Runs models with Core ML on Apple's own chips (Neural Engine, GPU or CPU). Takes the same input
/// frames as the stick and returns outputs in the stick's layout, so everything built on `Tensor`
/// works unchanged.
public actor CoreMLEngine: InferenceEngine {
    private struct Loaded {
        let info: ModelInfo
        let model: MLModel
        let map: NativeModelMap?
    }

    private var loaded: [String: Loaded] = [:]
    private var primary: String?
    private var pending: [Task<[Tensor], Error>] = []

    public init() {}

    public var loadedModel: ModelInfo? { primary.flatMap { loaded[$0]?.info } }
    public var loadedModelNames: [String] { loaded.keys.sorted() }
    public var queueSize: Int { 2 }
    /// Frames submitted and not yet collected.
    public var framesInFlight: Int { pending.count }

    /// Compiles a `.mlpackage` once and keeps the compiled `.mlmodelc` next to it for later launches.
    public static func compiledModel(at url: URL) async throws -> URL {
        if url.pathExtension == "mlmodelc" { return url }
        let compiled = url.deletingPathExtension().appendingPathExtension("mlmodelc")
        let fm = FileManager.default
        let packageDate = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        if let compiledDate = try? fm.attributesOfItem(atPath: compiled.path)[.modificationDate] as? Date, compiledDate >= packageDate {
            return compiled
        }
        let temporary = try await MLModel.compileModel(at: url)
        try? fm.removeItem(at: compiled)
        do { try fm.moveItem(at: temporary, to: compiled) } catch { return temporary }
        return compiled
    }

    /// Loads a model. `url` is a `.mlpackage` or `.mlmodelc`; a `<name>.native.json` map next to it is
    /// used when present. With `primary` false the model is added next to the main one.
    public func load(_ info: ModelInfo, from url: URL, computeUnits: MLComputeUnits = .all, primary makePrimary: Bool = true) async throws {
        let compiled = try await Self.compiledModel(at: url)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let model = try await MLModel.load(contentsOf: compiled, configuration: configuration)
        let mapURL = url.deletingPathExtension().appendingPathExtension("native.json")
        let map = (try? Data(contentsOf: mapURL)).flatMap { try? JSONDecoder().decode(NativeModelMap.self, from: $0) }
        // A native model can differ from the stick's (input size, output shape); its own description wins.
        loaded[info.name] = Loaded(info: map?.model ?? info, model: model, map: map)
        if makePrimary || primary == nil { primary = info.name }
    }

    public func unload(_ name: String) {
        loaded[name] = nil
        if primary == name { primary = loaded.keys.first }
    }

    public func unloadAll() {
        loaded = [:]
        primary = nil
    }

    // MARK: Running

    public func infer(inputs: [[UInt8]], model name: String? = nil) async throws -> [Tensor] {
        guard let key = name ?? primary, let entry = loaded[key] else { throw StudioError.noModelLoaded }
        let provider = try Self.inputProvider(inputs, for: entry)
        let result = try await entry.model.prediction(from: provider)
        return try Self.outputs(result, for: entry)
    }

    public func submit(inputs: [[UInt8]], model name: String? = nil) async throws {
        guard let key = name ?? primary, let entry = loaded[key] else { throw StudioError.noModelLoaded }
        let provider = try Self.inputProvider(inputs, for: entry)
        pending.append(Task {
            let result = try await entry.model.prediction(from: provider)
            return try Self.outputs(result, for: entry)
        })
    }

    public func collect() async throws -> [Tensor] {
        guard !pending.isEmpty else { throw StudioError.invalidInput("Nothing submitted.") }
        return try await pending.removeFirst().value
    }

    // MARK: Inputs

    private static func inputProvider(_ frames: [[UInt8]], for entry: Loaded) throws -> MLFeatureProvider {
        try inputProvider(frames, model: entry.model, info: entry.info, order: entry.map?.inputs, bgr: entry.map?.bgr ?? false)
    }

    /// The Core ML inputs for frames in the stick's input format. `order` names the Core ML input for
    /// each frame; by default "image", "image_2", ... then other inputs by name. `bgr` swaps red and blue
    /// in image inputs (`NativeModelMap.bgr`).
    public static func inputProvider(_ frames: [[UInt8]], model: MLModel, info: ModelInfo, order: [String]? = nil,
                                     bgr: Bool = false) throws -> MLFeatureProvider {
        let descriptions = model.modelDescription.inputDescriptionsByName
        let ordered = order ?? defaultInputOrder(model)
        var features: [String: MLFeatureValue] = [:]
        for (index, frame) in frames.enumerated() where index < ordered.count {
            let name = ordered[index]
            guard let description = descriptions[name] else { continue }
            let stream = index < info.inputs.count ? info.inputs[index] : nil
            if let constraint = description.imageConstraint {
                features[name] = MLFeatureValue(pixelBuffer: try pixelBuffer(rgb: frame, width: constraint.pixelsWide, height: constraint.pixelsHigh, bgr: bgr))
            } else if let constraint = description.multiArrayConstraint, let stream {
                features[name] = MLFeatureValue(multiArray: try tensorInput(frame, stream: stream, shape: constraint.shape.map(\.intValue)))
            }
        }
        return try MLDictionaryFeatureProvider(dictionary: features)
    }

    /// Converted models name image inputs "image", "image_2", ...; other inputs keep their graph names.
    public static func defaultInputOrder(_ model: MLModel) -> [String] {
        Array(model.modelDescription.inputDescriptionsByName.keys).sorted { a, b in
            func rank(_ n: String) -> (Int, String) { n == "image" ? (0, "") : (n.hasPrefix("image_") ? (1, n) : (2, n)) }
            return rank(a) < rank(b)
        }
    }

    /// RGB bytes (as sent to the stick) into a BGRA pixel buffer for an image input (with `bgr`, the
    /// channels go in the other way round, so the model sees blue where it reads red).
    private static func pixelBuffer(rgb: [UInt8], width: Int, height: Int, bgr: Bool = false) throws -> CVPixelBuffer {
        guard rgb.count >= width * height * 3 else { throw StudioError.invalidInput("Frame is \(rgb.count) bytes, expected \(width * height * 3).") }
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess, let buffer else {
            throw StudioError.invalidInput("Could not create a \(width)x\(height) pixel buffer.")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let (blue, red) = bgr ? (0, 2) : (2, 0)
        rgb.withUnsafeBufferPointer { source in
            for y in 0..<height {
                let row = base + y * rowBytes
                for x in 0..<width {
                    let s = (y * width + x) * 3
                    row[x * 4] = source[s + blue]
                    row[x * 4 + 1] = source[s + 1]
                    row[x * 4 + 2] = source[s + red]
                    row[x * 4 + 3] = 255
                }
            }
        }
        return buffer
    }

    /// A frame in the stick's input format (quantized, NHWC) as a float array in the model's shape (NCHW).
    private static func tensorInput(_ frame: [UInt8], stream: StreamInfo, shape: [Int]) throws -> MLMultiArray {
        let values = Tensor(stream: stream, bytes: frame).floats()   // NHWC, dequantized
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        let count = min(values.count, array.count)
        let h = stream.height ?? 1, w = stream.width ?? 1, c = stream.features ?? 1
        if shape.count == 4, shape[1] == c, shape[2] == h, shape[3] == w, c > 1 {
            for y in 0..<h { for x in 0..<w { for ch in 0..<c {
                pointer[(ch * h + y) * w + x] = values[(y * w + x) * c + ch]
            } } }
        } else if shape.count == 5, shape[1] * shape[2] == c, shape[3] == h, shape[4] == w {
            // A clip [1, colours, frames, H, W] (r3d_18); the stick's channels are frame x colours + colour.
            let colours = shape[1], frames = shape[2]
            for y in 0..<h { for x in 0..<w { for t in 0..<frames { for ch in 0..<colours {
                pointer[((ch * frames + t) * h + y) * w + x] = values[(y * w + x) * c + t * colours + ch]
            } } } }
        } else {
            for i in 0..<count { pointer[i] = values[i] }
        }
        return array
    }

    // MARK: Outputs

    private static func outputs(_ result: MLFeatureProvider, for entry: Loaded) throws -> [Tensor] {
        let info = entry.info
        if let map = entry.map, map.detection != nil, info.hasDeviceNMS {
            var arrays: [MLMultiArray] = []
            for output in map.outputs {
                guard let array = result.featureValue(for: output.source)?.multiArrayValue else {
                    throw StudioError.invalidInput("Missing output \(output.source).")
                }
                arrays.append(array)
            }
            return [nmsTensor(arrays, map: map, model: info)]
        }
        let mapping: [NativeModelMap.Output] = entry.map?.outputs
            ?? result.featureNames.sorted().map { NativeModelMap.Output(source: $0, activation: nil) }
        var tensors: [Tensor] = []
        for (index, stream) in info.outputs.enumerated() where index < mapping.count {
            guard let array = result.featureValue(for: mapping[index].source)?.multiArrayValue else {
                throw StudioError.invalidInput("Missing output \(mapping[index].source).")
            }
            var values = nhwc(array, stream: stream)
            switch mapping[index].activation {
            case "sigmoid": for i in values.indices { values[i] = 1 / (1 + exp(-values[i])) }
            case "tanh": for i in values.indices { values[i] = tanh(values[i]) }
            case "softmax":
                let peak = values.max() ?? 0
                var total: Float = 0
                for i in values.indices { values[i] = exp(values[i] - peak); total += values[i] }
                for i in values.indices { values[i] /= total }
            default: break
            }
            tensors.append(tensor(values, like: stream))
        }
        return tensors
    }

    /// Wraps values in a format the decoders read for `stream`:
    /// - class maps (argmax outputs) stay one byte per pixel;
    /// - outputs the stick quantizes (UINT8/UINT16) become UINT16 over the same value range, which keeps
    ///   practically full precision and works with the decoders' fast integer paths;
    /// - float outputs, and outputs quantized per channel, are float32.
    public static func tensor(_ values: [Float], like stream: StreamInfo) -> Tensor {
        if stream.type == "UINT8", stream.order == "NHW", (stream.qpScale ?? 1) == 1, (stream.qpZp ?? 0) == 0 {
            return Tensor(stream: stream, bytes: values.map { UInt8(clamping: Int($0.rounded())) })
        }
        // Per-channel quantized outputs have no single value range (the stick's come as float32 too).
        if stream.qpScales == nil, stream.type == "UINT8" || stream.type == "UINT16" {
            let scale = stream.qpScale ?? 1, zero = stream.qpZp ?? 0
            let levels: Float = stream.type == "UINT8" ? 255 : 65535
            let low = (0 - zero) * scale, high = (levels - zero) * scale
            let wideScale = (high - low) / 65535
            let wideZero = -low / wideScale
            var bytes = [UInt8](repeating: 0, count: values.count * 2)
            bytes.withUnsafeMutableBytes { raw in
                for (i, value) in values.enumerated() {
                    // Clamped before Int(), which traps on infinity and NaN (a float16 overflow in a conversion;
                    // NaN becomes the value 0).
                    let level = (value / wideScale + wideZero).rounded()
                    let q = UInt16(level.isNaN ? wideZero.rounded() : min(max(level, 0), 65535))
                    raw.storeBytes(of: q.littleEndian, toByteOffset: 2 * i, as: UInt16.self)
                }
            }
            return Tensor(stream: stream.with(type: "UINT16", zeroPoint: wideZero, scale: wideScale), bytes: bytes)
        }
        return Tensor(stream: stream.asFloat32, bytes: values.withUnsafeBytes { Array($0) })
    }

    /// All elements of an output in row-major order of its shape, as Float, honoring strides (Neural
    /// Engine outputs can have padded rows).
    public static func contiguous(_ array: MLMultiArray) -> [Float] {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        let count = shape.reduce(1, *)
        var out = [Float](repeating: 0, count: count)
        let isHalf = array.dataType == .float16
        let isDouble = array.dataType == .double
        let isInt = array.dataType == .int32   // class maps (argmax) come back as integers
        let base = array.dataPointer
        var index = [Int](repeating: 0, count: shape.count)
        for i in 0..<count {
            var offset = 0
            for d in 0..<shape.count { offset += index[d] * strides[d] }
            if isInt {
                out[i] = Float(base.assumingMemoryBound(to: Int32.self)[offset])
            } else if isHalf {
                out[i] = Float(base.assumingMemoryBound(to: Float16.self)[offset])
            } else if isDouble {
                out[i] = Float(base.assumingMemoryBound(to: Double.self)[offset])
            } else {
                out[i] = base.assumingMemoryBound(to: Float.self)[offset]
            }
            var d = shape.count - 1
            while d >= 0 {
                index[d] += 1
                if index[d] < shape[d] { break }
                index[d] = 0
                d -= 1
            }
        }
        return out
    }

    /// Reorders an NCHW (or [1, C]) output into the stick's NHWC layout for `stream`.
    public static func nhwc(_ array: MLMultiArray, stream: StreamInfo) -> [Float] {
        let values = contiguous(array)
        let h = stream.height ?? 1, w = stream.width ?? 1, c = stream.features ?? 1
        let dims = array.shape.map(\.intValue)
        // [1, C, H, W] -> [H, W, C]
        if dims.count == 4, dims[1] == c, dims[2] == h, dims[3] == w, c > 1 || h > 1 {
            var out = [Float](repeating: 0, count: h * w * c)
            for ch in 0..<c { for y in 0..<h { for x in 0..<w {
                out[(y * w + x) * c + ch] = values[(ch * h + y) * w + x]
            } } }
            return out
        }
        // [1, C, N] where the stick has H = 1, W = N, C channels.
        if dims.count == 3, dims[1] == c, dims[2] == w * h, c > 1 {
            let n = w * h
            var out = [Float](repeating: 0, count: n * c)
            for ch in 0..<c { for i in 0..<n { out[i * c + ch] = values[ch * n + i] } }
            return out
        }
        return values
    }

    // MARK: Detection decoding and NMS

    /// One candidate box: (y_min, x_min, y_max, x_max) normalized to the input, and its score.
    public typealias Candidate = (box: (Float, Float, Float, Float), score: Float)

    /// Decodes raw YOLO outputs (see `NativeModelMap.DetectionLayout`), runs class-wise NMS and writes
    /// Hailo's NMS_BY_CLASS layout.
    public static func nmsTensor(_ arrays: [MLMultiArray], map: NativeModelMap, model: ModelInfo) -> Tensor {
        let classes = model.outputs[0].classes ?? 80
        let threshold = model.nmsScore ?? 0.2
        let inputW = Float(model.inputWidth), inputH = Float(model.inputHeight)
        var perClass = [[Candidate]](repeating: [], count: classes)
        func add(_ c: Int, cx: Float, cy: Float, w: Float, h: Float, score: Float) {
            let box = ((cy - h / 2) / inputH, (cx - w / 2) / inputW, (cy + h / 2) / inputH, (cx + w / 2) / inputW)
            perClass[c].append((box: box, score: score))
        }
        func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }

        switch map.detection {
        case .boxesThenScores:
            guard let array = arrays.first else { break }
            let values = contiguous(array)
            let n = array.shape.last?.intValue ?? 0
            for i in 0..<n {
                for c in 0..<classes {
                    let s = values[(4 + c) * n + i]
                    guard s >= threshold else { continue }
                    add(c, cx: values[i], cy: values[n + i], w: values[2 * n + i], h: values[3 * n + i], score: s)
                }
            }
        case .boxesObjectnessScores:
            guard let array = arrays.first else { break }
            let values = contiguous(array)
            let stride = array.shape.last?.intValue ?? (5 + classes)
            for i in 0..<(values.count / stride) {
                let row = i * stride
                let objectness = values[row + 4]
                guard objectness >= threshold else { continue }
                for c in 0..<classes {
                    let s = objectness * values[row + 5 + c]
                    guard s >= threshold else { continue }
                    add(c, cx: values[row], cy: values[row + 1], w: values[row + 2], h: values[row + 3], score: s)
                }
            }
        case .dflHeads:
            // Pairs of (box distributions, class logits), one pair per stride.
            let logit = log(threshold / (1 - threshold))
            var index = 0
            while index + 1 < arrays.count {
                let boxArray = arrays[index], classArray = arrays[index + 1]
                index += 2
                let h = boxArray.shape[2].intValue, w = boxArray.shape[3].intValue
                let bins = boxArray.shape[1].intValue / 4
                let stride = inputW / Float(w)
                let box = contiguous(boxArray), cls = contiguous(classArray)
                let plane = h * w
                for y in 0..<h {
                    for x in 0..<w {
                        let cell = y * w + x
                        var best: Float = -.infinity
                        for c in 0..<classes { best = max(best, cls[c * plane + cell]) }
                        guard best >= logit else { continue }
                        // Expected distance per side: softmax over the bins.
                        var distance = [Float](repeating: 0, count: 4)
                        for side in 0..<4 {
                            var peak: Float = -.infinity
                            for b in 0..<bins { peak = max(peak, box[(side * bins + b) * plane + cell]) }
                            var total: Float = 0, weighted: Float = 0
                            for b in 0..<bins {
                                let e = exp(box[(side * bins + b) * plane + cell] - peak)
                                total += e
                                weighted += e * Float(b)
                            }
                            distance[side] = weighted / total * stride
                        }
                        let px = (Float(x) + 0.5) * stride, py = (Float(y) + 0.5) * stride
                        let x0 = px - distance[0], y0 = py - distance[1], x1 = px + distance[2], y1 = py + distance[3]
                        for c in 0..<classes {
                            let raw = cls[c * plane + cell]
                            guard raw >= logit else { continue }
                            add(c, cx: (x0 + x1) / 2, cy: (y0 + y1) / 2, w: x1 - x0, h: y1 - y0, score: sigmoid(raw))
                        }
                    }
                }
            }
        case .anchorHeads:
            let logit = log(threshold / (1 - threshold))
            for (level, array) in arrays.enumerated() {
                // [1, anchors, H, W, 5 + classes], or the head conv itself: [1, anchors x (5 + classes), H, W].
                let dims = array.shape.map(\.intValue)
                guard let anchorSizes = map.anchors?[level] else { continue }
                let anchorCount = anchorSizes.count / 2
                let depth = 5 + classes
                let channelsFirst = dims.count == 4
                guard channelsFirst ? dims[1] == anchorCount * depth : dims.count == 5 else { continue }
                let h = channelsFirst ? dims[2] : dims[2], w = channelsFirst ? dims[3] : dims[3]
                let stride = inputW / Float(w)
                let values = contiguous(array)
                for a in 0..<anchorCount {
                    let anchorW = anchorSizes[2 * a], anchorH = anchorSizes[2 * a + 1]
                    for y in 0..<h {
                        for x in 0..<w {
                            func v(_ k: Int) -> Float {
                                channelsFirst ? values[((a * depth + k) * h + y) * w + x] : values[((a * h + y) * w + x) * depth + k]
                            }
                            guard v(4) >= logit else { continue }
                            let objectness = sigmoid(v(4))
                            let cx = (sigmoid(v(0)) * 2 - 0.5 + Float(x)) * stride
                            let cy = (sigmoid(v(1)) * 2 - 0.5 + Float(y)) * stride
                            let bw = pow(sigmoid(v(2)) * 2, 2) * anchorW
                            let bh = pow(sigmoid(v(3)) * 2, 2) * anchorH
                            for c in 0..<classes {
                                let s = objectness * sigmoid(v(5 + c))
                                guard s >= threshold else { continue }
                                add(c, cx: cx, cy: cy, w: bw, h: bh, score: s)
                            }
                        }
                    }
                }
            }
        case nil:
            break
        }
        return nmsBytes(perClass, model: model)
    }

    /// Class-wise NMS, written as Hailo's NMS_BY_CLASS layout: for each class a count followed by
    /// (y_min, x_min, y_max, x_max, score) per box.
    static func nmsBytes(_ perClass: [[Candidate]], model: ModelInfo) -> Tensor {
        let stream = model.outputs[0]
        let maxBoxes = stream.maxBoxes ?? 100
        let iouThreshold = model.nmsIoU ?? 0.7
        func iou(_ a: (Float, Float, Float, Float), _ b: (Float, Float, Float, Float)) -> Float {
            let y0 = max(a.0, b.0), x0 = max(a.1, b.1), y1 = min(a.2, b.2), x1 = min(a.3, b.3)
            let inter = max(0, y1 - y0) * max(0, x1 - x0)
            let union = (a.2 - a.0) * (a.3 - a.1) + (b.2 - b.0) * (b.3 - b.1) - inter
            return union > 0 ? inter / union : 0
        }
        var out: [Float] = []
        for candidates in perClass {
            var kept: [Candidate] = []
            for candidate in candidates.sorted(by: { $0.score > $1.score }) where kept.count < maxBoxes {
                if kept.allSatisfy({ iou($0.box, candidate.box) <= iouThreshold }) { kept.append(candidate) }
            }
            out.append(Float(kept.count))
            for k in kept {
                out += [max(0, k.box.0), max(0, k.box.1), min(1, k.box.2), min(1, k.box.3), k.score]
            }
        }
        return Tensor(stream: stream, bytes: out.withUnsafeBytes { Array($0) })
    }
}

extension StreamInfo {
    /// The same stream holding plain float32 values (no quantization), as `CoreMLEngine` returns them.
    /// The same stream with another element type and quantization.
    public func with(type newType: String, zeroPoint: Float, scale: Float) -> StreamInfo {
        let size = newType == "UINT16" ? 2 : (newType == "FLOAT32" ? 4 : 1)
        return StreamInfo(name: name, type: newType, order: order, frameSize: (frameSize / max(1, bytesPerElement)) * size,
                          height: height, width: width, features: features, qpZp: zeroPoint, qpScale: scale, classes: classes, maxBoxes: maxBoxes)
    }

    public var asFloat32: StreamInfo {
        StreamInfo(name: name, type: "FLOAT32", order: order, frameSize: (frameSize / max(1, bytesPerElement)) * 4,
                   height: height, width: width, features: features, qpZp: 0, qpScale: 1, classes: classes, maxBoxes: maxBoxes)
    }
}
