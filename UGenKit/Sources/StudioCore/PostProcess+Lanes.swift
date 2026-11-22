import CoreGraphics
import Foundation

extension PostProcess {
    /// Lane lines (ufld_v2_tu), ported from hailo-apps `lane_detection_utils.py` (UFLDProcessing).
    ///
    /// Four vectors, told apart by their length:
    /// - 100 x 56 x 4: for each of 56 row anchors and 4 lanes, logits over 100 horizontal grid cells.
    /// - 100 x 41 x 4: for each of 41 column anchors and 4 lanes, logits over 100 vertical grid cells.
    /// - 2 x 56 x 4 and 2 x 41 x 4: absent/present logits per anchor and lane.
    /// Each is laid out as (cell, anchor, lane). Lanes 1 and 2 (the edges of our own lane) are read from the
    /// row anchors, lanes 0 and 3 (far left and far right) from the column anchors. The position at an anchor
    /// is the softmax expectation over the best cell and its two neighbours, plus 0.5, divided by 99.
    ///
    /// Row anchors sit at 160/720 ... 710/720 of the frame height and column anchors at 0 ... 1 of its width,
    /// exactly as the reference draws them. The reference feeds the model the lower 80 % of the frame and
    /// still draws at anchor x full height; here the whole frame is stretched into the input, and on the
    /// test capture the same direct mapping is the one that lands on the lane markings.
    public static func lanes(_ tensors: [Tensor], frame: PreparedFrame) -> [Lane] {
        let cells = 100, rowCount = 56, columnCount = 41, laneCount = 4
        guard let rowTensor = tensors.first(where: { $0.features == cells * rowCount * laneCount }),
              let columnTensor = tensors.first(where: { $0.features == cells * columnCount * laneCount }),
              let rowExistTensor = tensors.first(where: { $0.features == 2 * rowCount * laneCount }),
              let columnExistTensor = tensors.first(where: { $0.features == 2 * columnCount * laneCount }) else { return [] }
        let rows = rowTensor.floats(), columns = columnTensor.floats()
        let rowExists = rowExistTensor.floats(), columnExists = columnExistTensor.floats()
        guard rows.count == cells * rowCount * laneCount, columns.count == cells * columnCount * laneCount,
              rowExists.count == 2 * rowCount * laneCount, columnExists.count == 2 * columnCount * laneCount else { return [] }

        /// Anchors of one lane where it is present, with the sub-cell position (0...1) at each.
        func positions(_ values: [Float], _ exists: [Float], anchors: Int, lane: Int, minimum: Float) -> [(anchor: Int, position: Float)] {
            func value(_ cell: Int, _ anchor: Int) -> Float { values[(cell * anchors + anchor) * laneCount + lane] }
            let present = (0..<anchors).filter { exists[(anchors + $0) * laneCount + lane] > exists[$0 * laneCount + lane] }
            guard Float(present.count) > minimum else { return [] }
            return present.map { anchor in
                var best = 0
                for cell in 1..<cells where value(cell, anchor) > value(best, anchor) { best = cell }
                let low = max(0, best - 1), high = min(cells - 1, best + 1)
                let peak = value(best, anchor)
                var total: Float = 0, expectation: Float = 0
                for cell in low...high {
                    let weight = exp(value(cell, anchor) - peak)
                    total += weight
                    expectation += weight * Float(cell)
                }
                return (anchor, (expectation / total + 0.5) / Float(cells - 1))
            }
        }

        var found: [Lane] = []
        for lane in 0..<laneCount {
            var points: [CGPoint]
            if lane == 1 || lane == 2 {
                // Row anchors: fixed heights, predicted x. More than half of the anchors must be present.
                points = positions(rows, rowExists, anchors: rowCount, lane: lane, minimum: Float(rowCount) / 2).map { anchor, position in
                    let fraction = (160 + Float(anchor) * (710 - 160) / Float(rowCount - 1)) / 720
                    // Both values are fractions of the whole frame, as in the reference, whatever part was fed to the model.
                    return CGPoint(x: CGFloat(position), y: CGFloat(fraction))
                }
            } else {
                // Column anchors: fixed x, predicted height. More than a quarter of the anchors must be present.
                points = positions(columns, columnExists, anchors: columnCount, lane: lane, minimum: Float(columnCount) / 4).map { anchor, position in
                    let fraction = Float(anchor) / Float(columnCount - 1)
                    return CGPoint(x: CGFloat(fraction), y: CGFloat(position))
                }
            }
            guard points.count >= 2 else { continue }
            // Far (higher in the picture) to near.
            if let first = points.first, let last = points.last, first.y > last.y { points.reverse() }
            found.append(Lane(points: points))
        }
        return found
    }
}
