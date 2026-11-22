import CoreGraphics
import Foundation

extension PostProcess {
    /// Prior boxes of an SSD-style face detector: per stride, the square anchor sizes of each cell, in
    /// input pixels. From the Model Zoo configs (cfg/base/retinaface.yaml, lightface_slim_base.yaml).
    public struct FaceAnchors: Sendable {
        public let levels: [(stride: Int, sizes: [Float])]
        /// Score and overlap limits. Hailo evaluates with 0.02 (RetinaFace) and 0.1 (LightFace) to
        /// measure mAP; for showing faces the originals' demo thresholds are used.
        public let scoreThreshold: Float
        public let iouThreshold: Float
        /// Whether the model also gives the five landmarks (eyes, nose, mouth corners).
        public let landmarks: Bool

        /// RetinaFace (biubug6/Pytorch_Retinaface): 2 anchors per cell, with five landmarks.
        public static let retinaFace = FaceAnchors(levels: [(8, [16, 32]), (16, [64, 128]), (32, [256, 512])],
                                                   scoreThreshold: 0.5, iouThreshold: 0.4, landmarks: true)
        /// LightFace (Ultra-Light-Fast-Generic-Face-Detector-1MB): 2 or 3 anchors per cell, boxes only.
        public static let lightFace = FaceAnchors(levels: [(8, [10, 16, 24]), (16, [32, 48]), (32, [64, 96]), (64, [128, 192, 256])],
                                                  scoreThreshold: 0.6, iouThreshold: 0.3, landmarks: false)
    }

    /// The anchor layout of a RetinaFace or LightFace model, recognised by its outputs:
    /// RetinaFace has 3 strides x (8 box, 4 class, 20 landmark channels); LightFace has 4 strides x
    /// (4 x anchors box, 2 x anchors class channels) with 3, 2, 2 and 3 anchors.
    public static func faceAnchors(for model: ModelInfo) -> FaceAnchors? {
        let features = model.outputs.map { $0.features ?? 0 }
        if features.count == 9, features.filter({ $0 == 20 }).count == 3, features.filter({ $0 == 4 }).count == 3,
           features.filter({ $0 == 8 }).count == 3 { return .retinaFace }
        if features.count == 8, features.sorted() == [4, 4, 6, 6, 8, 8, 12, 12] { return .lightFace }
        return nil
    }

    /// Faces from an SSD-style detector (RetinaFace, LightFace), as in the Model Zoo's
    /// FaceDetectionPostProc: per stride a box tensor (anchors x 4: dx, dy, dw, dh), a class tensor
    /// (anchors x 2 logits: background, face) and, for RetinaFace, a landmark tensor (anchors x 5 x (x, y)).
    /// Anchor centres are (column + 0.5) x stride; box centre = anchor + d / 10 x size, box size =
    /// anchor size x exp(d / 5); landmarks like the centre. Score = softmax face probability.
    public static func anchorFaces(_ tensors: [Tensor], frame: PreparedFrame, anchors: FaceAnchors) -> [Face] {
        struct Candidate { var box: CGRect; var score: Float; var landmarks: [CGPoint] }
        var candidates: [Candidate] = []
        let landmarkCount = 5
        // softmax(l)[1] > t  <=>  l1 - l0 > log(t / (1 - t))
        let logitThreshold = log(anchors.scoreThreshold / (1 - anchors.scoreThreshold))

        for (gridHeight, group) in Dictionary(grouping: tensors, by: { $0.height }) {
            // The stride whose grid has this height (LightFace's 240-pixel input rounds 3.75 up to 4).
            guard let level = anchors.levels.first(where: { (frame.height + $0.stride - 1) / $0.stride == gridHeight }),
                  let classes = group.first(where: { $0.features == 2 * level.sizes.count }),
                  let boxes = group.first(where: { $0.features == 4 * level.sizes.count }) else { continue }
            let points = group.first { $0.features == 2 * landmarkCount * level.sizes.count }
            let count = level.sizes.count, width = classes.width, stride = Float(level.stride)
            let score = classes.floats(), delta = boxes.floats(), offset = points?.floats()

            for cell in 0..<(gridHeight * width) {
                let centerX = (Float(cell % width) + 0.5) * stride, centerY = (Float(cell / width) + 0.5) * stride
                for (k, size) in level.sizes.enumerated() {
                    let anchor = cell * count + k
                    let logit = score[2 * anchor + 1] - score[2 * anchor]
                    guard logit > logitThreshold else { continue }
                    let base = 4 * anchor
                    let x = centerX + delta[base] / 10 * size, y = centerY + delta[base + 1] / 10 * size
                    let w = size * exp(delta[base + 2] / 5), h = size * exp(delta[base + 3] / 5)
                    var landmarks: [CGPoint] = []
                    if let offset {
                        for p in 0..<landmarkCount {
                            let index = (anchor * landmarkCount + p) * 2
                            landmarks.append(frame.toSource(x: CGFloat(centerX + offset[index] / 10 * size),
                                                            y: CGFloat(centerY + offset[index + 1] / 10 * size)))
                        }
                    }
                    let box = CGRect(x: CGFloat(x - w / 2), y: CGFloat(y - h / 2), width: CGFloat(w), height: CGFloat(h))
                    candidates.append(Candidate(box: box, score: 1 / (1 + exp(-logit)), landmarks: landmarks))
                }
            }
        }

        candidates.sort { $0.score > $1.score }
        var kept: [Candidate] = []
        for candidate in candidates where !kept.contains(where: { iou($0.box, candidate.box) > anchors.iouThreshold }) {
            kept.append(candidate)
        }
        return kept.map { Face(boundingBox: frame.toSource($0.box), confidence: $0.score, landmarks: $0.landmarks) }
    }

    /// Faces from any face detector UGenKit reads: SCRFD, RetinaFace or LightFace.
    public static func faces(_ tensors: [Tensor], model: ModelInfo, frame: PreparedFrame) -> [Face] {
        if let anchors = faceAnchors(for: model) { return anchorFaces(tensors, frame: frame, anchors: anchors) }
        return scrfdFaces(tensors, frame: frame)
    }
}
