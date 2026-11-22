import CoreGraphics
import Foundation

extension PostProcess {
    /// Oriented boxes (yolo11s_obb, DOTA classes), ported from hailo-apps
    /// `oriented_object_detection_post_process.py`.
    ///
    /// Nine outputs, three per stride (8, 16, 32): box distances as 4 x 16 distribution bins (64 channels,
    /// order left, top, right, bottom), one logit per class, and one angle logit.
    /// angle = (sigmoid(logit) - 0.25) * pi, so it lies in [-pi/4, 3pi/4). The centre is the cell centre plus
    /// the offset ((right - left) / 2, (bottom - top) / 2) rotated by the angle; the size is
    /// (left + right, top + bottom). The best class must score above `scoreThreshold`; overlapping boxes are
    /// removed regardless of class when their rotated-rectangle IoU exceeds `iouThreshold`.
    public static func orientedDetections(_ tensors: [Tensor], frame: PreparedFrame) -> [OrientedDetection] {
        let scoreThreshold: Float = 0.35
        let iouThreshold: Float = 0.25
        let bins = 16

        struct Candidate {
            var centerX: Float, centerY: Float, width: Float, height: Float, angle: Float
            var score: Float
            var classIndex: Int
            var corners: [CGPoint]
            var radius: Float
        }
        var candidates: [Candidate] = []

        func raw(_ tensor: Tensor, _ index: Int, wide: Bool) -> Float {
            wide ? Float(UInt16(tensor.bytes[2 * index]) | UInt16(tensor.bytes[2 * index + 1]) << 8) : Float(tensor.bytes[index])
        }

        let grids = Dictionary(grouping: tensors) { $0.height }
        for (gridSize, group) in grids {
            guard let boxes = group.first(where: { $0.features == 4 * bins }),
                  let angles = group.first(where: { $0.features == 1 }),
                  let classes = group.first(where: { $0.features != 4 * bins && $0.features != 1 }) else { continue }
            let stride = Float(frame.height) / Float(gridSize)
            let width = boxes.width
            let classCount = classes.features
            let boxZero = boxes.stream.qpZp ?? 0, boxScale = boxes.stream.qpScale ?? 1
            let classZero = classes.stream.qpZp ?? 0, classScale = classes.stream.qpScale ?? 1
            let angleZero = angles.stream.qpZp ?? 0, angleScale = angles.stream.qpScale ?? 1
            let boxWide = boxes.stream.type == "UINT16"
            let classWide = classes.stream.type == "UINT16"
            let angleWide = angles.stream.type == "UINT16"
            let cellCount = boxes.height * width
            guard boxes.bytes.count >= cellCount * 4 * bins * (boxWide ? 2 : 1),
                  classes.bytes.count >= cellCount * classCount * (classWide ? 2 : 1),
                  angles.bytes.count >= cellCount * (angleWide ? 2 : 1) else { continue }

            for cell in 0..<cellCount {
                // Best class first; only cells that pass the threshold are decoded further.
                var bestRaw: Float = -.infinity
                var bestClass = 0
                for c in 0..<classCount {
                    let value = raw(classes, cell * classCount + c, wide: classWide)
                    if value > bestRaw { bestRaw = value; bestClass = c }
                }
                let score = 1 / (1 + exp(-(bestRaw - classZero) * classScale))
                guard score > scoreThreshold else { continue }

                var distances = [Float](repeating: 0, count: 4)
                for side in 0..<4 {
                    var logits = [Float](repeating: 0, count: bins)
                    for bin in 0..<bins {
                        logits[bin] = (raw(boxes, (cell * 4 + side) * bins + bin, wide: boxWide) - boxZero) * boxScale
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
                let angleLogit = (raw(angles, cell, wide: angleWide) - angleZero) * angleScale
                let angle = (1 / (1 + exp(-angleLogit)) - 0.25) * Float.pi
                let sine = sin(angle), cosine = cos(angle)
                let offsetX = (distances[2] - distances[0]) / 2
                let offsetY = (distances[3] - distances[1]) / 2
                let column = Float(cell % width) + 0.5, row = Float(cell / width) + 0.5
                let centerX = (offsetX * cosine - offsetY * sine + column) * stride
                let centerY = (offsetX * sine + offsetY * cosine + row) * stride
                // The reference keeps sizes at one pixel or more.
                let boxWidth = max((distances[0] + distances[2]) * stride, 1)
                let boxHeight = max((distances[1] + distances[3]) * stride, 1)

                let halfW = boxWidth / 2, halfH = boxHeight / 2
                let corners = [(-halfW, -halfH), (halfW, -halfH), (halfW, halfH), (-halfW, halfH)].map { dx, dy in
                    CGPoint(x: CGFloat(centerX + dx * cosine - dy * sine), y: CGFloat(centerY + dx * sine + dy * cosine))
                }
                candidates.append(Candidate(centerX: centerX, centerY: centerY, width: boxWidth, height: boxHeight, angle: angle,
                                            score: score, classIndex: bestClass, corners: corners,
                                            radius: (halfW * halfW + halfH * halfH).squareRoot()))
            }
        }

        // Rotated non-maximum suppression, across classes as in the reference.
        candidates.sort { $0.score > $1.score }
        var kept: [Candidate] = []
        for candidate in candidates {
            let suppressed = kept.contains { other in
                let dx = other.centerX - candidate.centerX, dy = other.centerY - candidate.centerY
                let reach = other.radius + candidate.radius
                guard dx * dx + dy * dy < reach * reach else { return false }
                return rotatedIoU(other.corners, other.width * other.height, candidate.corners, candidate.width * candidate.height) > iouThreshold
            }
            if !suppressed { kept.append(candidate) }
        }

        let labels = Labels.dota
        return kept.map { candidate in
            let label = labels.indices.contains(candidate.classIndex) ? labels[candidate.classIndex] : "class \(candidate.classIndex)"
            return OrientedDetection(label: label, classIndex: candidate.classIndex, confidence: candidate.score,
                                     corners: candidate.corners.map { frame.toSource(x: $0.x, y: $0.y) })
        }
    }

    /// Intersection over union of two rectangles given as four corners in order (convex polygons).
    static func rotatedIoU(_ a: [CGPoint], _ areaA: Float, _ b: [CGPoint], _ areaB: Float) -> Float {
        let overlap = Float(polygonArea(clip(a, by: b)))
        let union = areaA + areaB - overlap
        return union > 0 ? overlap / (union + 1e-9) : 0
    }

    static func polygonArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 3 else { return 0 }
        var twice: CGFloat = 0
        for i in points.indices {
            let p = points[i], q = points[(i + 1) % points.count]
            twice += p.x * q.y - q.x * p.y
        }
        return abs(twice) / 2
    }

    /// Sutherland-Hodgman: the part of convex polygon `subject` inside convex polygon `clipper`.
    static func clip(_ subject: [CGPoint], by clipper: [CGPoint]) -> [CGPoint] {
        var signed: CGFloat = 0
        for i in clipper.indices {
            let p = clipper[i], q = clipper[(i + 1) % clipper.count]
            signed += p.x * q.y - q.x * p.y
        }
        let orientation: CGFloat = signed >= 0 ? 1 : -1
        var output = subject
        for i in clipper.indices {
            guard !output.isEmpty else { break }
            let a = clipper[i], b = clipper[(i + 1) % clipper.count]
            func side(_ p: CGPoint) -> CGFloat { orientation * ((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)) }
            let input = output
            output = []
            for j in input.indices {
                let current = input[j], previous = input[(j + input.count - 1) % input.count]
                let sideCurrent = side(current), sidePrevious = side(previous)
                if (sideCurrent >= 0) != (sidePrevious >= 0) {
                    let t = sidePrevious / (sidePrevious - sideCurrent)
                    output.append(CGPoint(x: previous.x + t * (current.x - previous.x), y: previous.y + t * (current.y - previous.y)))
                }
                if sideCurrent >= 0 { output.append(current) }
            }
        }
        return output
    }
}
