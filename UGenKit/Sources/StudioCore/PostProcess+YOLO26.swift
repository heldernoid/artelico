import CoreGraphics
import Foundation

extension PostProcess {
    /// YOLO26 detection (no NMS on the device).
    ///
    /// Six outputs, two per stride (8, 16, 32), taken from the model's one-to-one head:
    /// - 4 channels: distances (left, top, right, bottom) from the cell centre to the box edges, in grid cells.
    ///   YOLO26 has no distribution bins, the values are used directly:
    ///   `x1 = (column + 0.5 - left) * stride`, `x2 = (column + 0.5 + right) * stride`, same for y.
    /// - 80 channels: class logits; confidence = sigmoid(logit).
    ///
    /// The model is trained to give one box per object, so every (cell, class) above the threshold is a
    /// detection. A light per-class NMS removes the rare duplicate.
    public static func yolo26Detections(_ tensors: [Tensor], frame: PreparedFrame, scoreThreshold: Float = 0.25,
                                        iouThreshold: Float = 0.7, maxDetections: Int = 300) -> [Detection] {
        struct Candidate { var box: CGRect; var score: Float; var classIndex: Int }
        var candidates: [Candidate] = []

        for (gridSize, group) in Dictionary(grouping: tensors, by: { $0.height }) {
            guard let boxes = group.first(where: { $0.features == 4 }),
                  let scores = group.first(where: { $0.features != 4 && $0.features > 1 }),
                  boxes.width == scores.width else { continue }
            let classCount = scores.features
            let width = scores.width
            let strideX = Float(frame.width) / Float(width), strideY = Float(frame.height) / Float(gridSize)
            let scoreValue = ValueReader(scores)
            let boxValue = ValueReader(boxes)

            for index in y26Hits(scores, threshold: scoreThreshold) {
                let cell = index / classCount
                guard cell * 4 + 3 < boxValue.count else { continue }
                let logit = scoreValue[index]
                let column = Float(cell % width) + 0.5, row = Float(cell / width) + 0.5
                let left = boxValue[cell * 4], top = boxValue[cell * 4 + 1]
                let right = boxValue[cell * 4 + 2], bottom = boxValue[cell * 4 + 3]
                let box = CGRect(x: CGFloat((column - left) * strideX), y: CGFloat((row - top) * strideY),
                                 width: CGFloat((left + right) * strideX), height: CGFloat((top + bottom) * strideY))
                guard box.width > 0, box.height > 0 else { continue }
                candidates.append(Candidate(box: box, score: 1 / (1 + exp(-logit)), classIndex: index % classCount))
            }
        }

        candidates.sort { $0.score > $1.score }
        var kept: [Candidate] = []
        for candidate in candidates {
            if kept.count >= maxDetections { break }
            if kept.contains(where: { $0.classIndex == candidate.classIndex && iou($0.box, candidate.box) > iouThreshold }) { continue }
            kept.append(candidate)
        }
        let classCount = tensors.map(\.features).max() ?? 0
        let labels = classCount == Labels.coco.count ? Labels.coco : (0..<classCount).map { "class \($0)" }
        return kept.map {
            Detection(label: labels.indices.contains($0.classIndex) ? labels[$0.classIndex] : "class \($0.classIndex)",
                      classIndex: $0.classIndex, confidence: $0.score, boundingBox: frame.toSource($0.box))
        }
    }

    /// YOLO26 pose.
    ///
    /// Nine outputs, three per stride (8, 16, 32), taken from the model's one-to-one head:
    /// - 4 channels: box distances, decoded as in `yolo26Detections`.
    /// - 1 channel: person logit; confidence = sigmoid(logit).
    /// - 51 channels: 17 keypoints x (x, y, confidence logit). x and y are offsets from the cell centre in
    ///   grid cells: `x = (column + 0.5 + dx) * stride`, `y = (row + 0.5 + dy) * stride`
    ///   (unlike YOLOv8-pose, which uses `(2 * dx + column) * stride`).
    public static func yolo26Poses(_ tensors: [Tensor], frame: PreparedFrame, scoreThreshold: Float = 0.25,
                                   iouThreshold: Float = 0.7, maxDetections: Int = 300) -> [Pose] {
        struct Candidate { var box: CGRect; var score: Float; var keypoints: [Pose.Keypoint] }
        var candidates: [Candidate] = []
        let keypointCount = 17

        for (gridSize, group) in Dictionary(grouping: tensors, by: { $0.height }) {
            guard let boxes = group.first(where: { $0.features == 4 }),
                  let scores = group.first(where: { $0.features == 1 }),
                  let points = group.first(where: { $0.features == keypointCount * 3 }),
                  boxes.width == scores.width, points.width == scores.width else { continue }
            let width = scores.width
            let strideX = Float(frame.width) / Float(width), strideY = Float(frame.height) / Float(gridSize)
            let scoreValue = ValueReader(scores)
            let boxValue = ValueReader(boxes), pointValue = ValueReader(points)

            for cell in y26Hits(scores, threshold: scoreThreshold) {
                guard cell * 4 + 3 < boxValue.count, (cell + 1) * keypointCount * 3 <= pointValue.count else { continue }
                let logit = scoreValue[cell]
                let column = Float(cell % width) + 0.5, row = Float(cell / width) + 0.5
                let left = boxValue[cell * 4], top = boxValue[cell * 4 + 1]
                let right = boxValue[cell * 4 + 2], bottom = boxValue[cell * 4 + 3]
                let box = CGRect(x: CGFloat((column - left) * strideX), y: CGFloat((row - top) * strideY),
                                 width: CGFloat((left + right) * strideX), height: CGFloat((top + bottom) * strideY))
                guard box.width > 0, box.height > 0 else { continue }

                var keypoints: [Pose.Keypoint] = []
                keypoints.reserveCapacity(keypointCount)
                for k in 0..<keypointCount {
                    let base = (cell * keypointCount + k) * 3
                    let x = (column + pointValue[base]) * strideX
                    let y = (row + pointValue[base + 1]) * strideY
                    let confidence = 1 / (1 + exp(-pointValue[base + 2]))
                    keypoints.append(Pose.Keypoint(position: frame.toSource(x: CGFloat(x), y: CGFloat(y)), confidence: confidence))
                }
                candidates.append(Candidate(box: box, score: 1 / (1 + exp(-logit)), keypoints: keypoints))
            }
        }

        candidates.sort { $0.score > $1.score }
        var kept: [Candidate] = []
        for candidate in candidates {
            if kept.count >= maxDetections { break }
            if kept.contains(where: { iou($0.box, candidate.box) > iouThreshold }) { continue }
            kept.append(candidate)
        }
        return kept.map { Pose(confidence: $0.score, boundingBox: frame.toSource($0.box), keypoints: $0.keypoints) }
    }

    /// YOLO26-seg: per stride the YOLO26 detection tensors (4 box distances, class logits, see
    /// `yolo26Detections`) plus 32 mask coefficients for the shared prototypes.
    static func yolo26SegCandidates(_ heads: [Tensor], frame: PreparedFrame, maskChannels: Int, scoreThreshold: Float) -> [SegmentCandidate] {
        var candidates: [SegmentCandidate] = []
        for (gridSize, group) in Dictionary(grouping: heads, by: { $0.height }) {
            guard let boxes = group.first(where: { $0.features == 4 }),
                  let coefficients = group.first(where: { $0.features == maskChannels }),
                  let scores = group.first(where: { $0.features != 4 && $0.features != maskChannels }),
                  boxes.width == scores.width, coefficients.width == scores.width else { continue }
            let classCount = scores.features, width = scores.width
            let strideX = Float(frame.width) / Float(width), strideY = Float(frame.height) / Float(gridSize)
            let score = ValueReader(scores), box = ValueReader(boxes), coefficient = ValueReader(coefficients)
            for index in y26Hits(scores, threshold: scoreThreshold) {
                let cell = index / classCount
                let column = Float(cell % width) + 0.5, row = Float(cell / width) + 0.5
                let left = box[cell * 4], top = box[cell * 4 + 1], right = box[cell * 4 + 2], bottom = box[cell * 4 + 3]
                let rect = CGRect(x: CGFloat((column - left) * strideX), y: CGFloat((row - top) * strideY),
                                  width: CGFloat((left + right) * strideX), height: CGFloat((top + bottom) * strideY))
                guard rect.width > 0, rect.height > 0 else { continue }
                candidates.append(SegmentCandidate(box: rect, score: 1 / (1 + exp(-score[index])), classIndex: index % classCount,
                                                   coefficients: (0..<maskChannels).map { coefficient[cell * maskChannels + $0] }))
            }
        }
        return candidates
    }

    /// Indices of the elements of a logit tensor whose sigmoid is at least `threshold`.
    /// Compares raw values against the threshold moved into the tensor's own number format, so nothing is converted.
    private static func y26Hits(_ tensor: Tensor, threshold: Float) -> [Int] {
        let clamped = min(max(threshold, 1e-6), 1 - 1e-6)
        let logit = log(clamped / (1 - clamped))
        var hits: [Int] = []
        tensor.bytes.withUnsafeBytes { raw in
            switch tensor.stream.type {
            case "FLOAT32":
                let values = raw.bindMemory(to: Float.self)
                for i in 0..<values.count where values[i] >= logit { hits.append(i) }
            case "UINT16":
                let scale = tensor.stream.qpScale ?? 1, zero = tensor.stream.qpZp ?? 0
                guard scale > 0 else { return }
                let limit = (logit / scale + zero).rounded(.up)
                guard limit <= 65535 else { return }
                let minimum = UInt16(max(0, limit))
                let values = raw.bindMemory(to: UInt16.self)
                for i in 0..<values.count where UInt16(littleEndian: values[i]) >= minimum { hits.append(i) }
            default:
                let scale = tensor.stream.qpScale ?? 1, zero = tensor.stream.qpZp ?? 0
                guard scale > 0 else { return }
                let limit = (logit / scale + zero).rounded(.up)
                guard limit <= 255 else { return }
                let minimum = UInt8(max(0, limit))
                for i in 0..<raw.count where raw[i] >= minimum { hits.append(i) }
            }
        }
        return hits
    }
}
