import CoreGraphics
import Foundation

extension PostProcess {
    /// Face boxes and five landmarks (scrfd_10g), ported from hailo-apps' postprocess/cpp/scrfd.cpp.
    ///
    /// Nine outputs, three per stride (8, 16, 32), each with two anchors per cell:
    /// scores (2 channels, already passed through a sigmoid), box distances (2 x 4: left, top, right,
    /// bottom, in units of the stride) and landmarks (2 x 5 x (x, y) offsets in units of the stride).
    /// The anchor centre is the cell's top-left corner (column * stride, row * stride), as in the reference.
    public static func scrfdFaces(_ tensors: [Tensor], frame: PreparedFrame, scoreThreshold: Float = 0.4, iouThreshold: Float = 0.4) -> [Face] {
        struct Candidate { var box: CGRect; var score: Float; var landmarks: [CGPoint] }
        var candidates: [Candidate] = []
        let landmarkCount = 5

        func reader(_ tensor: Tensor) -> (Int) -> Float {
            let zero = tensor.stream.qpZp ?? 0, scale = tensor.stream.qpScale ?? 1
            let bytes = tensor.bytes
            switch tensor.stream.type {
            case "UINT16":
                return { (Float(UInt16(bytes[2 * $0]) | UInt16(bytes[2 * $0 + 1]) << 8) - zero) * scale }
            case "FLOAT32":
                return { index in bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4 * index, as: Float.self) } }
            default:
                return { (Float(bytes[$0]) - zero) * scale }
            }
        }

        // Group the three tensors of each grid size.
        let grids = Dictionary(grouping: tensors) { $0.height }
        for (gridSize, group) in grids {
            guard gridSize > 0, let scores = group.min(by: { $0.features < $1.features }) else { continue }
            let anchors = scores.features
            guard anchors > 0,
                  let boxes = group.first(where: { $0.features == anchors * 4 }),
                  let points = group.first(where: { $0.features == anchors * landmarkCount * 2 }) else { continue }
            let stride = Float(frame.height) / Float(gridSize)
            let width = scores.width
            let score = reader(scores), distance = reader(boxes), offset = reader(points)

            // Convert only the anchors that pass the threshold.
            for index in 0..<(scores.height * width * anchors) {
                let confidence = score(index)
                guard confidence > scoreThreshold else { continue }
                let cell = index / anchors
                let centerX = Float(cell % width) * stride, centerY = Float(cell / width) * stride
                let left = centerX - distance(index * 4) * stride
                let top = centerY - distance(index * 4 + 1) * stride
                let right = centerX + distance(index * 4 + 2) * stride
                let bottom = centerY + distance(index * 4 + 3) * stride
                guard right > left, bottom > top else { continue }
                var landmarks: [CGPoint] = []
                landmarks.reserveCapacity(landmarkCount)
                for k in 0..<landmarkCount {
                    let base = index * landmarkCount * 2 + k * 2
                    let x = centerX + offset(base) * stride
                    let y = centerY + offset(base + 1) * stride
                    landmarks.append(frame.toSource(x: CGFloat(x), y: CGFloat(y)))
                }
                let box = CGRect(x: CGFloat(left), y: CGFloat(top), width: CGFloat(right - left), height: CGFloat(bottom - top))
                candidates.append(Candidate(box: box, score: confidence, landmarks: landmarks))
            }
        }

        // Non-maximum suppression on the boxes.
        candidates.sort { $0.score > $1.score }
        var kept: [Candidate] = []
        for candidate in candidates where !kept.contains(where: { iou($0.box, candidate.box) > iouThreshold }) {
            kept.append(candidate)
        }
        return kept.map { Face(boundingBox: frame.toSource($0.box), confidence: $0.score, landmarks: $0.landmarks) }
    }
}
