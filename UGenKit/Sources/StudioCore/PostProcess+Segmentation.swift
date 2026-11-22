import CoreGraphics
import Foundation

extension PostProcess {
    /// Anchor boxes (width, height in input pixels) of YOLOv5-seg per stride, from Hailo's
    /// instance-segmentation config (hailo-apps, instance_segmentation/config.json, "v5").
    static let yolov5SegAnchors: [Int: [(Float, Float)]] = [
        8: [(10, 13), (16, 30), (33, 23)],
        16: [(30, 61), (62, 45), (59, 119)],
        32: [(116, 90), (156, 198), (373, 326)],
    ]

    /// A box before non-maximum suppression, in model-input pixels, with its mask coefficients.
    struct SegmentCandidate {
        var box: CGRect
        var score: Float
        var classIndex: Int
        var coefficients: [Float]
    }

    /// Instance segmentation. Recognised by the outputs' layout:
    /// - one NMS_BYTE_MASK output: the device already ran NMS and drew the masks (YOLOv5-seg "hpp");
    /// - YOLOv5-seg: prototypes and 3 anchor heads;
    /// - YOLACT: prototypes and 5 grids of box, coefficient and class tensors;
    /// - YOLO26-seg: per stride 4 box distances, class logits and coefficients;
    /// - YOLOv8-seg: per stride 64 DFL box bins, class scores and coefficients. FastSAM has the same
    ///   layout with a single "object" score; its instances are numbered instead of named.
    public static func instances(_ tensors: [Tensor], model: ModelInfo, frame: PreparedFrame) -> [Instance] {
        if tensors.count == 1, tensors[0].stream.isByteMaskNMS { return byteMaskInstances(tensors[0], frame: frame) }
        // The prototype tensor is the one with the largest grid.
        guard let prototypes = tensors.max(by: { $0.height * $0.width < $1.height * $1.width }) else { return [] }
        let heads = tensors.filter { $0.stream.name != prototypes.stream.name }
        let maskChannels = prototypes.features
        let scoreThreshold: Float = 0.3

        var candidates: [SegmentCandidate]
        let iouThreshold: Float
        if heads.count == 3, heads.allSatisfy({ $0.features % 3 == 0 && $0.features / 3 > 5 + maskChannels }) {
            candidates = yolov5SegCandidates(heads, frame: frame, maskChannels: maskChannels, scoreThreshold: scoreThreshold)
            iouThreshold = 0.6
        } else if Set(heads.map(\.height)).count == 5 {
            candidates = yolactCandidates(heads, frame: frame, maskChannels: maskChannels, scoreThreshold: scoreThreshold)
            iouThreshold = 0.5
        } else if heads.contains(where: { $0.features == 4 }) {
            candidates = yolo26SegCandidates(heads, frame: frame, maskChannels: maskChannels, scoreThreshold: scoreThreshold)
            iouThreshold = 0.7
        } else {
            candidates = yolov8SegCandidates(heads, frame: frame, maskChannels: maskChannels, scoreThreshold: scoreThreshold)
            iouThreshold = 0.7
        }
        // FastSAM ("segment everything") scores one class, "object": its instances are "object 1, 2..." with class -1.
        let numbered = heads.contains { $0.features == 1 }

        // Class-aware non-maximum suppression.
        candidates.sort { $0.score > $1.score }
        var kept: [SegmentCandidate] = []
        for candidate in candidates where !kept.contains(where: { $0.classIndex == candidate.classIndex && iou($0.box, candidate.box) > iouThreshold }) {
            kept.append(candidate)
            if kept.count >= 100 { break }
        }

        // The part of the prototype grid covered by the image (the rest is letterbox padding).
        let protoWidth = prototypes.width, protoHeight = prototypes.height
        let scaleX = Float(protoWidth) / Float(frame.width), scaleY = Float(protoHeight) / Float(frame.height)
        let cropX = min(max(Int((Float(frame.contentRect.minX) * scaleX).rounded()), 0), protoWidth - 1)
        let cropY = min(max(Int((Float(frame.contentRect.minY) * scaleY).rounded()), 0), protoHeight - 1)
        let maskWidth = min(max(Int((Float(frame.contentRect.width) * scaleX).rounded()), 1), protoWidth - cropX)
        let maskHeight = min(max(Int((Float(frame.contentRect.height) * scaleY).rounded()), 1), protoHeight - cropY)

        let labels = Labels.coco
        let protoZero = prototypes.stream.qpZp ?? 0
        let protoWide = prototypes.stream.type == "UINT16"
        let protoFloat = prototypes.stream.type == "FLOAT32"

        return prototypes.bytes.withUnsafeBytes { proto -> [Instance] in
            kept.enumerated().map { rank, candidate in
                var mask = [UInt8](repeating: 0, count: maskWidth * maskHeight)
                // Box in prototype cells, clipped to the image area.
                let x0 = max(Int((Float(candidate.box.minX) * scaleX).rounded(.up)), cropX)
                let x1 = min(Int((Float(candidate.box.maxX) * scaleX).rounded(.up)), cropX + maskWidth)
                let y0 = max(Int((Float(candidate.box.minY) * scaleY).rounded(.up)), cropY)
                let y1 = min(Int((Float(candidate.box.maxY) * scaleY).rounded(.up)), cropY + maskHeight)
                // sigmoid(sum c * (raw - zp) * scale) > 0.5  <=>  sum c * raw > zp * sum c  (scale > 0).
                let coefficients = candidate.coefficients
                let bias = protoZero * coefficients.reduce(0, +)
                if x0 < x1, y0 < y1 {
                    coefficients.withUnsafeBufferPointer { c in
                        for y in y0..<y1 {
                            for x in x0..<x1 {
                                let base = (y * protoWidth + x) * maskChannels
                                var sum: Float = 0
                                if protoFloat {
                                    for k in 0..<maskChannels { sum += c[k] * proto.loadUnaligned(fromByteOffset: 4 * (base + k), as: Float.self) }
                                } else if protoWide {
                                    for k in 0..<maskChannels { sum += c[k] * Float(proto.loadUnaligned(fromByteOffset: 2 * (base + k), as: UInt16.self)) }
                                } else {
                                    for k in 0..<maskChannels { sum += c[k] * Float(proto[base + k]) }
                                }
                                if sum > bias { mask[(y - cropY) * maskWidth + (x - cropX)] = 255 }
                            }
                        }
                    }
                }
                let label = numbered ? "object \(rank + 1)"
                    : (candidate.classIndex < labels.count ? labels[candidate.classIndex] : "class \(candidate.classIndex)")
                let detection = Detection(label: label, classIndex: numbered ? -1 : candidate.classIndex, confidence: candidate.score,
                                          boundingBox: frame.toSource(candidate.box))
                return Instance(detection: detection, maskWidth: maskWidth, maskHeight: maskHeight, mask: mask)
            }
        }
    }

    /// Reads element `index` of a tensor's raw buffer as a real value.
    @inline(__always)
    private static func real(_ raw: UnsafeRawBufferPointer, _ index: Int, wide: Bool, zero: Float, scale: Float) -> Float {
        let value: Float = wide ? Float(raw.loadUnaligned(fromByteOffset: 2 * index, as: UInt16.self)) : Float(raw[index])
        return (value - zero) * scale
    }

    /// YOLOv8-seg: per stride a DFL box tensor (4 x 16 bins), a class tensor (already sigmoid) and mask coefficients.
    private static func yolov8SegCandidates(_ heads: [Tensor], frame: PreparedFrame, maskChannels: Int, scoreThreshold: Float) -> [SegmentCandidate] {
        var candidates: [SegmentCandidate] = []
        let bins = 16
        for (gridSize, group) in Dictionary(grouping: heads, by: { $0.height }) {
            guard let boxes = group.first(where: { $0.features == 4 * bins }),
                  let masks = group.first(where: { $0.features == maskChannels && $0.stream.name != boxes.stream.name }),
                  let scores = group.first(where: { $0.stream.name != boxes.stream.name && $0.stream.name != masks.stream.name }),
                  boxes.stream.type != "FLOAT32", masks.stream.type != "FLOAT32", scores.stream.type != "FLOAT32" else { continue }
            let stride = Float(frame.height) / Float(gridSize)
            let width = scores.width, classCount = scores.features
            let scoreZero = scores.stream.qpZp ?? 0, scoreScale = scores.stream.qpScale ?? 1, scoreWide = scores.stream.type == "UINT16"
            let boxZero = boxes.stream.qpZp ?? 0, boxScale = boxes.stream.qpScale ?? 1, boxWide = boxes.stream.type == "UINT16"
            let maskZero = masks.stream.qpZp ?? 0, maskScale = masks.stream.qpScale ?? 1, maskWide = masks.stream.type == "UINT16"
            // Compare raw values against the threshold so only passing cells are converted.
            let rawThreshold = scoreThreshold / scoreScale + scoreZero

            scores.bytes.withUnsafeBytes { scoreRaw in
                boxes.bytes.withUnsafeBytes { boxRaw in
                    masks.bytes.withUnsafeBytes { maskRaw in
                        let cellCount = scores.height * width
                        for cell in 0..<cellCount {
                            var best: Float = -.infinity
                            var bestClass = 0
                            let base = cell * classCount
                            if scoreWide {
                                for c in 0..<classCount {
                                    let value = Float(scoreRaw.loadUnaligned(fromByteOffset: 2 * (base + c), as: UInt16.self))
                                    if value > best { best = value; bestClass = c }
                                }
                            } else {
                                var top: UInt8 = 0
                                for c in 0..<classCount where scoreRaw[base + c] > top { top = scoreRaw[base + c]; bestClass = c }
                                best = Float(top)
                            }
                            guard best >= rawThreshold else { continue }
                            let score = (best - scoreZero) * scoreScale

                            var distances: (Float, Float, Float, Float) = (0, 0, 0, 0)
                            withUnsafeMutableBytes(of: &distances) { out in
                                let sides = out.bindMemory(to: Float.self)
                                for side in 0..<4 {
                                    var peak: Float = -.infinity
                                    var logits = (Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0),
                                                  Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0))
                                    withUnsafeMutableBytes(of: &logits) { buffer in
                                        let values = buffer.bindMemory(to: Float.self)
                                        for bin in 0..<bins {
                                            let v = real(boxRaw, (cell * 4 + side) * bins + bin, wide: boxWide, zero: boxZero, scale: boxScale)
                                            values[bin] = v
                                            peak = max(peak, v)
                                        }
                                        var total: Float = 0, expectation: Float = 0
                                        for bin in 0..<bins {
                                            let weight = exp(values[bin] - peak)
                                            total += weight
                                            expectation += weight * Float(bin)
                                        }
                                        sides[side] = expectation / total
                                    }
                                }
                            }
                            let centerX = Float(cell % width) + 0.5, centerY = Float(cell / width) + 0.5
                            let box = CGRect(x: CGFloat((centerX - distances.0) * stride), y: CGFloat((centerY - distances.1) * stride),
                                             width: CGFloat((distances.0 + distances.2) * stride), height: CGFloat((distances.1 + distances.3) * stride))
                            let coefficients = (0..<maskChannels).map { real(maskRaw, cell * maskChannels + $0, wide: maskWide, zero: maskZero, scale: maskScale) }
                            candidates.append(SegmentCandidate(box: box, score: score, classIndex: bestClass, coefficients: coefficients))
                        }
                    }
                }
            }
        }
        return candidates
    }

    /// YOLOv5-seg: per stride one tensor with 3 anchors x (x, y, w, h, objectness, classes, mask coefficients), raw logits.
    private static func yolov5SegCandidates(_ heads: [Tensor], frame: PreparedFrame, maskChannels: Int, scoreThreshold: Float) -> [SegmentCandidate] {
        var candidates: [SegmentCandidate] = []
        let anchorCount = 3
        for head in heads where head.stream.type != "FLOAT32" {
            let stride = Float(frame.height) / Float(head.height)
            guard let anchors = yolov5SegAnchors[Int(stride.rounded())] else { continue }
            let fields = head.features / anchorCount
            let classCount = fields - 5 - maskChannels
            let width = head.width
            let zero = head.stream.qpZp ?? 0, scale = head.stream.qpScale ?? 1, wide = head.stream.type == "UINT16"
            // score = objectness * class <= objectness, so objectness below the threshold can be skipped on raw values.
            let logitThreshold = log(scoreThreshold / (1 - scoreThreshold))
            let rawThreshold = logitThreshold / scale + zero

            head.bytes.withUnsafeBytes { raw in
                for cell in 0..<(head.height * width) {
                    for anchor in 0..<anchorCount {
                        let base = cell * head.features + anchor * fields
                        let rawObjectness: Float = wide ? Float(raw.loadUnaligned(fromByteOffset: 2 * (base + 4), as: UInt16.self)) : Float(raw[base + 4])
                        guard rawObjectness >= rawThreshold else { continue }
                        let objectness = sigmoid((rawObjectness - zero) * scale)
                        var best: Float = -.infinity
                        var bestClass = 0
                        for c in 0..<classCount {
                            let index = base + 5 + c
                            let value: Float = wide ? Float(raw.loadUnaligned(fromByteOffset: 2 * index, as: UInt16.self)) : Float(raw[index])
                            if value > best { best = value; bestClass = c }
                        }
                        let score = objectness * sigmoid((best - zero) * scale)
                        guard score >= scoreThreshold else { continue }

                        func value(_ field: Int) -> Float { sigmoid(real(raw, base + field, wide: wide, zero: zero, scale: scale)) }
                        let centerX = (value(0) * 2 + Float(cell % width) - 0.5) * stride
                        let centerY = (value(1) * 2 + Float(cell / width) - 0.5) * stride
                        let w = (value(2) * 2) * (value(2) * 2) * anchors[anchor].0
                        let h = (value(3) * 2) * (value(3) * 2) * anchors[anchor].1
                        let box = CGRect(x: CGFloat(centerX - w / 2), y: CGFloat(centerY - h / 2), width: CGFloat(w), height: CGFloat(h))
                        let coefficients = (0..<maskChannels).map { real(raw, base + 5 + classCount + $0, wide: wide, zero: zero, scale: scale) }
                        candidates.append(SegmentCandidate(box: box, score: score, classIndex: bestClass, coefficients: coefficients))
                    }
                }
            }
        }
        return candidates
    }
}
