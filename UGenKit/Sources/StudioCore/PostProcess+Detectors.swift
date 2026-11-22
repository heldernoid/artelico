import CoreGraphics
import Foundation

/// Detection decoders for the Model Zoo detectors that return raw heads (no NMS on the device): anchor YOLOs
/// (v3, v4, tiny), DAMO-YOLO, CenterNet, DETR, and the "bbox decoding only" models. Each follows the Model
/// Zoo's own post-processing (hailo_model_zoo/core/postprocessing/detection).
extension PostProcess {
    /// Which raw-head decoder a detection model needs, from its name and outputs; nil when none fits.
    public enum DetectorHead: Sendable, Equatable {
        /// YOLOv3 / tiny YOLOv3 / tiny YOLOv4: one tensor per stride, 3 anchors x (x, y, w, h, objectness, 80 classes), logits.
        case anchorYOLO(anchors: [[Float]], strides: [Int], scaleXY: Float)
        /// YOLOv4 split by the compiler: per stride centres (6), sizes (6), objectness (3), classes (240).
        case anchorYOLOSplit(anchors: [[Float]], strides: [Int], scaleXY: Float)
        /// DAMO-YOLO: per stride 4 x 17 distance bins and 80 (+1) class scores already through a sigmoid.
        case damo
        /// CenterNet: box sizes, centre offsets and the class heat map's local maxima (stride 4).
        case centerNet
        /// DETR: 100 queries x 92 class logits (91 COCO ids + "no object") and 100 boxes (cx, cy, w, h).
        case detr
        /// Boxes decoded on the host side of the compiled model: N x (x1, y1, x2, y2, [objectness,] classes).
        case decodedBoxes(objectness: Bool)
    }

    static let yolov3Anchors: [[Float]] = [[10, 13, 16, 30, 33, 23], [30, 61, 62, 45, 59, 119], [116, 90, 156, 198, 373, 326]]
    static let tinyYOLOAnchors: [[Float]] = [[23, 27, 37, 58, 81, 82], [81, 82, 135, 169, 344, 319]]
    static let yolov4Anchors: [[Float]] = [[12, 16, 19, 36, 40, 28], [36, 75, 76, 55, 72, 146], [142, 110, 192, 243, 459, 401]]

    public static func detectorHead(for model: ModelInfo) -> DetectorHead? {
        let outputs = model.outputs, name = model.name
        if name.hasSuffix("_bbox_decoding_only"), outputs.count == 1, let f = outputs[0].features, f == 84 || f == 85 {
            return .decodedBoxes(objectness: f == 85)
        }
        if name.hasPrefix("detr"), outputs.count == 2, outputs.contains(where: { $0.features == 92 }), outputs.contains(where: { $0.features == 4 }) {
            return .detr
        }
        if name.hasPrefix("centernet"), outputs.count == 3, outputs.filter({ $0.features == 2 }).count == 2, outputs.contains(where: { $0.features == 80 }) {
            return .centerNet
        }
        if name.hasPrefix("damoyolo"), outputs.count == 6, outputs.filter({ $0.features == 68 }).count == 3 {
            return .damo
        }
        if outputs.allSatisfy({ $0.features == 255 && $0.order == "NHWC" }) {
            if outputs.count == 3 { return .anchorYOLO(anchors: yolov3Anchors, strides: [8, 16, 32], scaleXY: 1) }
            if outputs.count == 2 { return .anchorYOLO(anchors: tinyYOLOAnchors, strides: [16, 32], scaleXY: 1) }
        }
        if name.hasPrefix("yolov4"), outputs.count == 12, outputs.filter({ $0.features == 240 }).count == 3 {
            return .anchorYOLOSplit(anchors: yolov4Anchors, strides: [8, 16, 32], scaleXY: 1.05)
        }
        return nil
    }

    /// Decodes a raw-head detector (see `DetectorHead`).
    public static func rawDetections(_ tensors: [Tensor], head: DetectorHead, frame: PreparedFrame,
                                     scoreThreshold: Float = 0.3, iouThreshold: Float = 0.45) -> [Detection] {
        var found: [DetectorCandidate]
        var labels = Labels.coco
        switch head {
        case let .anchorYOLO(anchors, strides, scaleXY):
            found = anchorYOLO(tensors, anchors: anchors, strides: strides, scaleXY: scaleXY, frame: frame, threshold: scoreThreshold)
        case let .anchorYOLOSplit(anchors, strides, scaleXY):
            found = anchorYOLOSplit(tensors, anchors: anchors, strides: strides, scaleXY: scaleXY, frame: frame, threshold: scoreThreshold)
        case .damo:
            found = damo(tensors, frame: frame, threshold: scoreThreshold)
        case .centerNet:
            return finish(centerNet(tensors, frame: frame, threshold: scoreThreshold), labels: labels, frame: frame, iou: 1)
        case .detr:
            labels = Labels.coco91
            return finish(detr(tensors, frame: frame, threshold: scoreThreshold), labels: labels, frame: frame, iou: 1)
        case let .decodedBoxes(objectness):
            found = decodedBoxes(tensors[0], objectness: objectness, frame: frame, threshold: scoreThreshold)
        }
        return finish(found, labels: labels, frame: frame, iou: iouThreshold)
    }

    // MARK: Shared

    struct DetectorCandidate { var box: CGRect; var score: Float; var classIndex: Int }

    /// Per-class NMS (skipped when `iou` >= 1: the model gives one box per object), then labels.
    static func finish(_ candidates: [DetectorCandidate], labels: [String], frame: PreparedFrame, iou: Float, maxDetections: Int = 100) -> [Detection] {
        var kept: [DetectorCandidate] = []
        for c in candidates.sorted(by: { $0.score > $1.score }) {
            if kept.count >= maxDetections { break }
            if iou < 1, kept.contains(where: { $0.classIndex == c.classIndex && PostProcess.iou($0.box, c.box) > iou }) { continue }
            kept.append(c)
        }
        return kept.map {
            Detection(label: labels.indices.contains($0.classIndex) ? labels[$0.classIndex] : "class \($0.classIndex)",
                      classIndex: $0.classIndex, confidence: $0.score, boundingBox: frame.toSource($0.box))
        }
    }

    @inline(__always) static func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }

    // MARK: Anchor YOLO (v3, tiny v3/v4)

    static func anchorYOLO(_ tensors: [Tensor], anchors: [[Float]], strides: [Int], scaleXY: Float, frame: PreparedFrame, threshold: Float) -> [DetectorCandidate] {
        var out: [DetectorCandidate] = []
        for t in tensors {
            let stride = frame.height / t.height
            guard let level = strides.firstIndex(of: stride) else { continue }
            let v = t.floats(), per = t.features / 3, classes = per - 5
            for cell in 0..<(t.height * t.width) {
                for a in 0..<3 {
                    let base = cell * t.features + a * per
                    let objectness = sigmoid(v[base + 4])
                    guard objectness >= threshold else { continue }
                    var best = 0, bestLogit = -Float.infinity
                    for c in 0..<classes where v[base + 5 + c] > bestLogit { bestLogit = v[base + 5 + c]; best = c }
                    let score = objectness * sigmoid(bestLogit)
                    guard score >= threshold else { continue }
                    let column = Float(cell % t.width), row = Float(cell / t.width)
                    let cx = (sigmoid(v[base]) * scaleXY - 0.5 * (scaleXY - 1) + column) * Float(stride)
                    let cy = (sigmoid(v[base + 1]) * scaleXY - 0.5 * (scaleXY - 1) + row) * Float(stride)
                    let w = exp(min(v[base + 2], 10)) * anchors[level][2 * a], h = exp(min(v[base + 3], 10)) * anchors[level][2 * a + 1]
                    out.append(DetectorCandidate(box: CGRect(x: CGFloat(cx - w / 2), y: CGFloat(cy - h / 2), width: CGFloat(w), height: CGFloat(h)),
                                                 score: score, classIndex: best))
                }
            }
        }
        return out
    }

    /// YOLOv4 split into centres, sizes, objectness and classes per stride; same decoding as `anchorYOLO`.
    static func anchorYOLOSplit(_ tensors: [Tensor], anchors: [[Float]], strides: [Int], scaleXY: Float, frame: PreparedFrame, threshold: Float) -> [DetectorCandidate] {
        var out: [DetectorCandidate] = []
        for (grid, group) in Dictionary(grouping: tensors, by: { $0.height }) {
            let pairs = group.filter { $0.features == 6 }
            guard pairs.count == 2, let objT = group.first(where: { $0.features == 3 }), let clsT = group.first(where: { $0.features == 240 }) else { continue }
            let stride = frame.height / grid
            guard let level = strides.firstIndex(of: stride) else { continue }
            let centres = pairs[0].floats(), sizes = pairs[1].floats(), obj = objT.floats(), cls = clsT.floats()
            let width = objT.width
            for cell in 0..<(grid * width) {
                for a in 0..<3 {
                    let objectness = sigmoid(obj[cell * 3 + a])
                    guard objectness >= threshold else { continue }
                    var best = 0, bestLogit = -Float.infinity
                    for c in 0..<80 where cls[cell * 240 + a * 80 + c] > bestLogit { bestLogit = cls[cell * 240 + a * 80 + c]; best = c }
                    let score = objectness * sigmoid(bestLogit)
                    guard score >= threshold else { continue }
                    let column = Float(cell % width), row = Float(cell / width)
                    let cx = (sigmoid(centres[cell * 6 + 2 * a]) * scaleXY - 0.5 * (scaleXY - 1) + column) * Float(stride)
                    let cy = (sigmoid(centres[cell * 6 + 2 * a + 1]) * scaleXY - 0.5 * (scaleXY - 1) + row) * Float(stride)
                    let w = exp(min(sizes[cell * 6 + 2 * a], 10)) * anchors[level][2 * a], h = exp(min(sizes[cell * 6 + 2 * a + 1], 10)) * anchors[level][2 * a + 1]
                    out.append(DetectorCandidate(box: CGRect(x: CGFloat(cx - w / 2), y: CGFloat(cy - h / 2), width: CGFloat(w), height: CGFloat(h)),
                                                 score: score, classIndex: best))
                }
            }
        }
        return out
    }

    // MARK: DAMO-YOLO

    /// Box distances as 4 x 17 bins (softmax expectation x stride) from the cell's corner (no half-cell offset).
    static func damo(_ tensors: [Tensor], frame: PreparedFrame, threshold: Float) -> [DetectorCandidate] {
        var out: [DetectorCandidate] = []
        let bins = 17
        for (grid, group) in Dictionary(grouping: tensors, by: { $0.height }) {
            guard let boxT = group.first(where: { $0.features == 4 * bins }), let scoreT = group.first(where: { $0.features != 4 * bins }) else { continue }
            let stride = Float(frame.height) / Float(grid)
            let scores = scoreT.floats(), boxes = boxT.floats(), classes = min(80, scoreT.features), width = scoreT.width
            for cell in 0..<(grid * width) {
                var best = 0, bestScore: Float = 0
                for c in 0..<classes where scores[cell * scoreT.features + c] > bestScore { bestScore = scores[cell * scoreT.features + c]; best = c }
                guard bestScore >= threshold else { continue }
                var d = [Float](repeating: 0, count: 4)
                for side in 0..<4 {
                    let base = cell * 4 * bins + side * bins
                    var peak = -Float.infinity
                    for b in 0..<bins { peak = max(peak, boxes[base + b]) }
                    var total: Float = 0, expectation: Float = 0
                    for b in 0..<bins { let e = exp(boxes[base + b] - peak); total += e; expectation += e * Float(b) }
                    d[side] = expectation / total * stride
                }
                let cx = Float(cell % width) * stride, cy = Float(cell / width) * stride
                out.append(DetectorCandidate(box: CGRect(x: CGFloat(cx - d[0]), y: CGFloat(cy - d[1]), width: CGFloat(d[0] + d[2]), height: CGFloat(d[1] + d[3])),
                                             score: bestScore, classIndex: best))
            }
        }
        return out
    }

    // MARK: CenterNet

    /// The heat map holds class scores only at local maxima (the device's max finder zeroes the rest), so
    /// every value above the threshold is one object: centre = (cell + offset) x 4, size = sizes x 4.
    static func centerNet(_ tensors: [Tensor], frame: PreparedFrame, threshold: Float) -> [DetectorCandidate] {
        guard let heat = tensors.first(where: { $0.features == 80 }) else { return [] }
        let twos = tensors.filter { $0.features == 2 }
        guard twos.count == 2 else { return [] }
        let a = twos[0].floats(), b = twos[1].floats()
        // Offsets are fractions of a cell; sizes are tens of cells. Tell them apart by their typical size.
        let meanA = a.reduce(0) { $0 + abs($1) } / Float(max(a.count, 1)), meanB = b.reduce(0) { $0 + abs($1) } / Float(max(b.count, 1))
        let (sizes, offsets) = meanA > meanB ? (a, b) : (b, a)
        let scores = heat.floats(), width = heat.width, scale = Float(frame.height) / Float(heat.height)
        var out: [DetectorCandidate] = []
        for i in scores.indices where scores[i] >= threshold {
            let cell = i / 80, c = i % 80
            let x = (Float(cell % width) + offsets[cell * 2]) * scale, y = (Float(cell / width) + offsets[cell * 2 + 1]) * scale
            let w = sizes[cell * 2] * scale, h = sizes[cell * 2 + 1] * scale
            out.append(DetectorCandidate(box: CGRect(x: CGFloat(x - w / 2), y: CGFloat(y - h / 2), width: CGFloat(w), height: CGFloat(h)), score: scores[i], classIndex: c))
        }
        return out
    }

    // MARK: DETR

    /// Softmax over the 92 logits of each query; the best real class (not the last, "no object") is the label.
    /// Boxes are (cx, cy, w, h) in 0...1 of the input, after a sigmoid (applied here when the values are logits).
    static func detr(_ tensors: [Tensor], frame: PreparedFrame, threshold: Float) -> [DetectorCandidate] {
        guard let logitsT = tensors.first(where: { $0.features == 92 }), let boxT = tensors.first(where: { $0.features == 4 }) else { return [] }
        let logits = logitsT.floats(), boxes = boxT.floats()
        let queries = logits.count / 92
        let needsSigmoid = boxes.contains { $0 < 0 || $0 > 1 }
        var out: [DetectorCandidate] = []
        for q in 0..<queries {
            let row = logits[(q * 92)..<(q * 92 + 92)]
            let peak = row.max() ?? 0
            var total: Float = 0, best = 0, bestValue = -Float.infinity
            for (k, v) in row.enumerated() {
                total += exp(v - peak)
                if k < 91, v > bestValue { bestValue = v; best = k }
            }
            let score = exp(bestValue - peak) / total
            guard score >= threshold, q * 4 + 3 < boxes.count else { continue }
            var b = Array(boxes[(q * 4)..<(q * 4 + 4)])
            if needsSigmoid { b = b.map(sigmoid) }
            let W = Float(frame.width), H = Float(frame.height)
            out.append(DetectorCandidate(box: CGRect(x: CGFloat((b[0] - b[2] / 2) * W), y: CGFloat((b[1] - b[3] / 2) * H),
                                                     width: CGFloat(b[2] * W), height: CGFloat(b[3] * H)), score: score, classIndex: best))
        }
        return out
    }

    // MARK: Decoded boxes

    /// N rows of (x1, y1, x2, y2[, objectness], class scores). Coordinates in input pixels, or in 0...1 when all are.
    static func decodedBoxes(_ t: Tensor, objectness: Bool, frame: PreparedFrame, threshold: Float) -> [DetectorCandidate] {
        let v = t.floats(), per = t.features, first = objectness ? 5 : 4
        let rows = v.count / per
        var normalized = true
        for r in 0..<min(rows, 2000) where v[r * per + 2] > 1.5 { normalized = false; break }
        let sx = normalized ? Float(frame.width) : 1, sy = normalized ? Float(frame.height) : 1
        var out: [DetectorCandidate] = []
        for r in 0..<rows {
            let base = r * per
            let obj = objectness ? v[base + 4] : 1
            guard obj >= threshold else { continue }
            var best = 0, bestScore: Float = 0
            for c in 0..<(per - first) where v[base + first + c] > bestScore { bestScore = v[base + first + c]; best = c }
            let score = obj * bestScore
            guard score >= threshold else { continue }
            let x1 = v[base] * sx, y1 = v[base + 1] * sy, x2 = v[base + 2] * sx, y2 = v[base + 3] * sy
            guard x2 > x1, y2 > y1 else { continue }
            out.append(DetectorCandidate(box: CGRect(x: CGFloat(x1), y: CGFloat(y1), width: CGFloat(x2 - x1), height: CGFloat(y2 - y1)), score: score, classIndex: best))
        }
        return out
    }
}
