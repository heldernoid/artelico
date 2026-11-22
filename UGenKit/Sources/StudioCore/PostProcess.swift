import CoreGraphics
import Foundation

/// Decoders that turn raw model outputs into results. Each one documents the layout it expects.
public enum PostProcess {
    // MARK: Detection (NMS done on the device)

    /// HAILO_NMS_BY_CLASS float32: for each class, a box count followed by that many
    /// (y_min, x_min, y_max, x_max, score) tuples in coordinates normalized to the model input.
    public static func detections(_ tensor: Tensor, frame: PreparedFrame, labels: [String], minimumConfidence: Float = 0) -> [Detection] {
        let classCount = tensor.stream.classes ?? 0
        let maxBoxes = tensor.stream.maxBoxes ?? 0
        var found: [Detection] = []
        tensor.bytes.withUnsafeBytes { raw in
            var offset = 0
            func next() -> Float? {
                guard offset + 4 <= raw.count else { return nil }
                defer { offset += 4 }
                return raw.loadUnaligned(fromByteOffset: offset, as: Float.self)
            }
            for classIndex in 0..<classCount {
                guard let count = next(), count >= 0, count <= Float(maxBoxes) else { return }
                for _ in 0..<Int(count) {
                    guard let yMin = next(), let xMin = next(), let yMax = next(), let xMax = next(), let score = next() else { return }
                    guard score >= minimumConfidence else { continue }
                    let box = CGRect(x: CGFloat(xMin) * CGFloat(frame.width), y: CGFloat(yMin) * CGFloat(frame.height),
                                     width: CGFloat(xMax - xMin) * CGFloat(frame.width), height: CGFloat(yMax - yMin) * CGFloat(frame.height))
                    found.append(Detection(label: classIndex < labels.count ? labels[classIndex] : "class \(classIndex)", classIndex: classIndex, confidence: score, boundingBox: frame.toSource(box)))
                }
            }
        }
        return found.sorted { $0.confidence > $1.confidence }
    }

    // MARK: Classification

    /// One vector of class scores. Applied softmax unless the values are already probabilities: all in
    /// 0...1 and summing to roughly 1. (Models that end in a softmax come back quantized from the stick,
    /// so their sum can be off by more than a few percent; a second softmax would flatten them.)
    public static func classifications(_ tensor: Tensor, top: Int = 5, labels: [String] = Labels.imagenet) -> [Classification] {
        var scores = tensor.floats()
        let sum = scores.reduce(0, +)
        let probabilities = scores.allSatisfy { $0 >= 0 && $0 <= 1.0001 } && sum > 0.7 && sum < 1.3
        if !probabilities {
            let peak = scores.max() ?? 0
            var total: Float = 0
            for i in scores.indices { scores[i] = exp(scores[i] - peak); total += scores[i] }
            for i in scores.indices { scores[i] /= total }
        } else if abs(sum - 1) > 0.001 {
            for i in scores.indices { scores[i] /= sum }
        }
        // Some ImageNet models have 1001 outputs with a leading background class.
        let labelOffset = scores.count == labels.count + 1 ? 1 : 0
        return scores.enumerated().sorted { $0.element > $1.element }.prefix(top).map { index, probability in
            let labelIndex = index - labelOffset
            let label = labels.indices.contains(labelIndex) ? labels[labelIndex] : "class \(index)"
            return Classification(label: label, classIndex: index, probability: probability)
        }
    }

    // MARK: Depth

    /// scdepthv3: one channel of logits; depth = 1 / (sigmoid(x) * 10 + 0.009), as in hailo-apps.
    public static func depth(_ tensor: Tensor) -> DepthMap {
        var values = tensor.floats()
        for i in values.indices {
            let sigmoid = 1 / (1 + exp(-values[i]))
            values[i] = 1 / (sigmoid * 10 + 0.009)
        }
        return DepthMap(width: tensor.width, height: tensor.height, values: values)
    }

    // MARK: Semantic segmentation

    /// One class index per pixel: the device already took the argmax (one channel), or the output holds
    /// one score per class (deeplab_v3_mobilenet_v2: 21 Pascal VOC classes; unet_mobilenet_v2: 3 pet
    /// trimap classes) and the best class is taken here. One scale and zero point per tensor keep the
    /// order of raw values, so the argmax runs on them.
    public static func segmentation(_ tensor: Tensor, model: ModelInfo) -> SegmentationMap {
        let set = Labels.segmentation(for: model)
        let pixels = tensor.width * tensor.height, classCount = tensor.features
        guard classCount > 1 else { return SegmentationMap(width: tensor.width, height: tensor.height, classes: tensor.bytes, set: set) }
        var classes = [UInt8](repeating: 0, count: pixels)
        func argmax<T: Comparable>(_ values: UnsafeBufferPointer<T>) {
            for pixel in 0..<pixels {
                let base = pixel * classCount
                var best = 0
                for c in 1..<classCount where values[base + c] > values[base + best] { best = c }
                classes[pixel] = UInt8(best)
            }
        }
        tensor.bytes.withUnsafeBytes { raw in
            switch tensor.stream.type {
            case "FLOAT32": argmax(raw.bindMemory(to: Float.self))
            case "UINT16": argmax(raw.bindMemory(to: UInt16.self))
            default: argmax(raw.bindMemory(to: UInt8.self))
            }
        }
        return SegmentationMap(width: tensor.width, height: tensor.height, classes: classes, set: set)
    }

    // MARK: Pose (YOLOv8-pose)

    /// Nine outputs, three per stride (8, 16, 32): box distances as 4 x 16 distribution bins (64 channels),
    /// one person score already passed through a sigmoid, and 17 keypoints x (x, y, confidence logits).
    public static func yolov8Poses(_ tensors: [Tensor], frame: PreparedFrame, scoreThreshold: Float = 0.3, iouThreshold: Float = 0.7) -> [Pose] {
        struct Candidate { var box: CGRect; var score: Float; var keypoints: [Pose.Keypoint] }
        var candidates: [Candidate] = []
        let keypointCount = 17
        let bins = 16

        // Group the three tensors of each grid size.
        let grids = Dictionary(grouping: tensors) { $0.height }
        for (gridSize, group) in grids {
            guard let boxes = group.first(where: { $0.features == 4 * bins }),
                  let scores = group.first(where: { $0.features == 1 }),
                  let points = group.first(where: { $0.features == keypointCount * 3 }) else { continue }
            let stride = Float(frame.height) / Float(gridSize)
            let scoreValues = scores.floats()
            let width = scores.width
            // Convert only the cells that pass the threshold; the other tensors are large.
            let boxZero = boxes.stream.qpZp ?? 0, boxScale = boxes.stream.qpScale ?? 1
            let pointZero = points.stream.qpZp ?? 0, pointScale = points.stream.qpScale ?? 1
            let pointWide = points.stream.type == "UINT16"
            let boxWide = boxes.stream.type == "UINT16"

            for cell in scoreValues.indices where scoreValues[cell] >= scoreThreshold {
                let column = Float(cell % width), row = Float(cell / width)
                var distances = [Float](repeating: 0, count: 4)
                for side in 0..<4 {
                    var logits = [Float](repeating: 0, count: bins)
                    for bin in 0..<bins {
                        let index = (cell * 4 + side) * bins + bin
                        let raw: Float = boxWide
                            ? Float(UInt16(boxes.bytes[2 * index]) | UInt16(boxes.bytes[2 * index + 1]) << 8)
                            : Float(boxes.bytes[index])
                        logits[bin] = (raw - boxZero) * boxScale
                    }
                    let peak = logits.max() ?? 0
                    var total: Float = 0, expectation: Float = 0
                    for bin in 0..<bins {
                        let weight = exp(logits[bin] - peak)
                        total += weight
                        expectation += weight * Float(bin)
                    }
                    distances[side] = expectation / total
                }
                let centerX = column + 0.5, centerY = row + 0.5
                let box = CGRect(x: CGFloat((centerX - distances[0]) * stride), y: CGFloat((centerY - distances[1]) * stride),
                                 width: CGFloat((distances[0] + distances[2]) * stride), height: CGFloat((distances[1] + distances[3]) * stride))

                var keypoints: [Pose.Keypoint] = []
                keypoints.reserveCapacity(keypointCount)
                for k in 0..<keypointCount {
                    func value(_ component: Int) -> Float {
                        let index = cell * keypointCount * 3 + k * 3 + component
                        let raw: Float = pointWide
                            ? Float(UInt16(points.bytes[2 * index]) | UInt16(points.bytes[2 * index + 1]) << 8)
                            : Float(points.bytes[index])
                        return (raw - pointZero) * pointScale
                    }
                    let x = (value(0) * 2 + column) * stride
                    let y = (value(1) * 2 + row) * stride
                    let confidence = 1 / (1 + exp(-value(2)))
                    keypoints.append(Pose.Keypoint(position: frame.toSource(x: CGFloat(x), y: CGFloat(y)), confidence: confidence))
                }
                candidates.append(Candidate(box: box, score: scoreValues[cell], keypoints: keypoints))
            }
        }

        // Non-maximum suppression on the boxes.
        candidates.sort { $0.score > $1.score }
        var kept: [Candidate] = []
        for candidate in candidates where !kept.contains(where: { iou($0.box, candidate.box) > iouThreshold }) {
            kept.append(candidate)
        }
        return kept.map { Pose(confidence: $0.score, boundingBox: frame.toSource($0.box), keypoints: $0.keypoints) }
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let overlap = intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - overlap
        return union > 0 ? Float(overlap / union) : 0
    }
}

/// Reads single real values out of a tensor without converting the whole tensor.
struct ValueReader {
    let tensor: Tensor
    let zero: Float
    let scale: Float
    let kind: Int
    let count: Int

    init(_ tensor: Tensor) {
        self.tensor = tensor
        zero = tensor.stream.qpZp ?? 0
        scale = tensor.stream.qpScale ?? 1
        kind = tensor.stream.type == "UINT16" ? 2 : (tensor.stream.type == "FLOAT32" ? 4 : 1)
        count = tensor.bytes.count / kind
    }

    subscript(index: Int) -> Float {
        switch kind {
        case 2:
            let raw = UInt16(tensor.bytes[2 * index]) | UInt16(tensor.bytes[2 * index + 1]) << 8
            return (Float(raw) - zero) * scale
        case 4:
            return tensor.bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4 * index, as: Float.self) }
        default:
            return (Float(tensor.bytes[index]) - zero) * scale
        }
    }
}
