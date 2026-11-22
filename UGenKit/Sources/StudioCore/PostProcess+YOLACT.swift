import CoreGraphics
import Foundation

extension PostProcess {
    /// YOLACT anchor sizes in input pixels for its 512-pixel input, per grid from the finest (64x64) to
    /// the coarsest (4x4): 24 x 2^level x (1, 2^(1/3), 2^(2/3)). From the Model Zoo's cfg/base/yolact.yaml;
    /// these give exactly the priors the source ONNX computes.
    static let yolactScales: [[Float]] = (0..<5).map { level in
        [0, 1, 2].map { step in 24 * pow(2, Float(level) + Float(step) / 3) }
    }
    static let yolactAspectRatios: [Float] = [1, 0.5, 2]

    /// YOLACT (Model Zoo's yolact_regnetx_*): per grid three tensors, each with 9 anchors per cell
    /// (3 scales x 3 aspect ratios, in that order):
    /// - 36 = 9 x 4 box offsets, decoded SSD-style around the anchor (variances 0.1 and 0.2);
    /// - 9 x 81 class logits, class 0 is background; score = softmax;
    /// - 9 x 32 mask coefficients, tanh already applied on the chip (the Model Zoo's .alls script).
    /// As in the Model Zoo, each anchor keeps its best non-background class.
    static func yolactCandidates(_ heads: [Tensor], frame: PreparedFrame, maskChannels: Int, scoreThreshold: Float) -> [SegmentCandidate] {
        let anchorsPerCell = yolactScales[0].count * yolactAspectRatios.count
        // Softmax p(best) <= e^best / (e^best + e^background), so a cell must clear this logit gap first.
        let gapThreshold = log(scoreThreshold / (1 - scoreThreshold))
        let grids = Dictionary(grouping: heads, by: { $0.height }).sorted { $0.key > $1.key }
        var candidates: [SegmentCandidate] = []

        for (level, (gridSize, group)) in grids.enumerated() where level < yolactScales.count {
            guard let boxes = group.first(where: { $0.features == anchorsPerCell * 4 }),
                  let coefficients = group.first(where: { $0.features == anchorsPerCell * maskChannels }),
                  let scores = group.first(where: { $0.features != boxes.features && $0.features != coefficients.features }),
                  scores.features % anchorsPerCell == 0 else { continue }
            let classCount = scores.features / anchorsPerCell   // background included
            let width = scores.width
            let box = ValueReader(boxes), score = ValueReader(scores), coefficient = ValueReader(coefficients)
            let inputWidth = Float(frame.width), inputHeight = Float(frame.height)

            for cell in 0..<(gridSize * width) {
                let centerX = (Float(cell % width) + 0.5) / Float(width)
                let centerY = (Float(cell / width) + 0.5) / Float(gridSize)
                for anchor in 0..<anchorsPerCell {
                    let base = (cell * anchorsPerCell + anchor) * classCount
                    let background = score[base]
                    var best: Float = -.infinity
                    var bestClass = 0
                    for c in 1..<classCount {
                        let value = score[base + c]
                        if value > best { best = value; bestClass = c }
                    }
                    guard best - background >= gapThreshold else { continue }
                    var total: Float = 0
                    for c in 0..<classCount { total += exp(score[base + c] - best) }
                    let probability = 1 / total
                    guard probability >= scoreThreshold else { continue }

                    let scale = yolactScales[level][anchor / yolactAspectRatios.count]
                    let ratio = yolactAspectRatios[anchor % yolactAspectRatios.count].squareRoot()
                    let priorWidth = scale * ratio / inputWidth, priorHeight = scale / ratio / inputHeight
                    let b = (cell * anchorsPerCell + anchor) * 4
                    let x = centerX + box[b] * 0.1 * priorWidth
                    let y = centerY + box[b + 1] * 0.1 * priorHeight
                    let w = priorWidth * exp(box[b + 2] * 0.2)
                    let h = priorHeight * exp(box[b + 3] * 0.2)
                    let rect = CGRect(x: CGFloat((x - w / 2) * inputWidth), y: CGFloat((y - h / 2) * inputHeight),
                                      width: CGFloat(w * inputWidth), height: CGFloat(h * inputHeight))
                    let m = (cell * anchorsPerCell + anchor) * maskChannels
                    candidates.append(SegmentCandidate(box: rect, score: probability, classIndex: bestClass - 1,
                                                       coefficients: (0..<maskChannels).map { coefficient[m + $0] }))
                }
            }
        }
        return candidates
    }
}
