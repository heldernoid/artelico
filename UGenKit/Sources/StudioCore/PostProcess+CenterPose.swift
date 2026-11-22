import CoreGraphics
import Foundation

extension PostProcess {
    /// CenterPose (centerpose_regnetx_800mf): six 128 x 128 maps, in the stick's order: person centres
    /// (1, sigmoid on the chip), box size (2), each keypoint's offset from the centre (34), centre offset
    /// (2), keypoint heatmaps (17, sigmoid on the chip) and keypoint offset (2).
    public static func isCenterPose(_ model: ModelInfo) -> Bool {
        model.outputs.map { $0.features ?? 0 } == [1, 2, 34, 2, 17, 2]
    }

    /// People from CenterPose, as in the Model Zoo's centerpose_postprocessing.py: peaks of the centre map
    /// (3 x 3 local maxima) give the people; each keypoint is first the centre plus its regressed offset,
    /// then moved to the nearest keypoint-heatmap peak (score >= 0.1, within the person's box and 0.3 of
    /// its longer side). The Zoo keeps the best 100 for mAP; people below `scoreThreshold` are left out, and
    /// so is a person whose box overlaps a better one by more than `iouThreshold`: two neighbouring cells
    /// with the same score both pass the max-pool (bus.jpg's half-visible person came out twice).
    public static func centerPoses(_ tensors: [Tensor], frame: PreparedFrame, scoreThreshold: Float = 0.3, iouThreshold: Float = 0.7,
                                   maxPeople: Int = 20) -> [Pose] {
        guard tensors.count == 6 else { return [] }
        let w = tensors[0].width, h = tensors[0].height
        let joints = 17, candidates = 100, jointThreshold: Float = 0.1
        let centers = tensors[0].floats(), size = tensors[1].floats(), fromCenter = tensors[2].floats()
        let centerOffset = tensors[3].floats(), jointMaps = tensors[4].floats(), jointOffset = tensors[5].floats()
        // Output cells to input pixels (512 / 128).
        let stride = CGFloat(frame.width) / CGFloat(w)

        /// Cells that are the highest of their 3 x 3 neighbourhood (the Zoo's max-pool "NMS"), best first.
        func peaks(_ values: [Float], channels: Int, channel: Int, minimum: Float, limit: Int) -> [(cell: Int, score: Float)] {
            var found: [(cell: Int, score: Float)] = []
            for y in 0..<h {
                for x in 0..<w {
                    let v = values[(y * w + x) * channels + channel]
                    guard v >= minimum else { continue }
                    var isPeak = true
                    for dy in -1...1 where isPeak {
                        for dx in -1...1 where (dx != 0 || dy != 0) {
                            let nx = x + dx, ny = y + dy
                            if nx >= 0, ny >= 0, nx < w, ny < h, values[(ny * w + nx) * channels + channel] > v { isPeak = false; break }
                        }
                    }
                    if isPeak { found.append((y * w + x, v)) }
                }
            }
            return Array(found.sorted { $0.score > $1.score }.prefix(limit))
        }

        // Keypoint-heatmap peaks per joint, at their sub-cell position.
        let jointPeaks: [[(x: Float, y: Float, score: Float)]] = (0..<joints).map { j in
            peaks(jointMaps, channels: joints, channel: j, minimum: jointThreshold, limit: candidates).map { peak in
                (Float(peak.cell % w) + jointOffset[peak.cell * 2], Float(peak.cell / w) + jointOffset[peak.cell * 2 + 1], peak.score)
            }
        }

        var poses: [Pose] = []
        for center in peaks(centers, channels: 1, channel: 0, minimum: scoreThreshold, limit: maxPeople) {
            let cell = center.cell
            let cx = Float(cell % w), cy = Float(cell / w)
            let bx = cx + centerOffset[cell * 2], by = cy + centerOffset[cell * 2 + 1]
            let bw = size[cell * 2], bh = size[cell * 2 + 1]
            let left = bx - bw / 2, right = bx + bw / 2, top = by - bh / 2, bottom = by + bh / 2
            let reach = max(bottom - top, right - left) * 0.3
            var keypoints: [Pose.Keypoint] = []
            for j in 0..<joints {
                // The regressed point starts from the centre cell itself (not the offset centre), as in the Zoo.
                var x = cx + fromCenter[cell * 34 + 2 * j], y = cy + fromCenter[cell * 34 + 2 * j + 1]
                var score: Float = 0
                if let nearest = jointPeaks[j].min(by: { hypot($0.x - x, $0.y - y) < hypot($1.x - x, $1.y - y) }) {
                    score = nearest.score
                    let inside = nearest.x >= left && nearest.x <= right && nearest.y >= top && nearest.y <= bottom
                    if inside, hypot(nearest.x - x, nearest.y - y) <= reach { x = nearest.x; y = nearest.y }
                }
                keypoints.append(Pose.Keypoint(position: frame.toSource(x: CGFloat(x) * stride, y: CGFloat(y) * stride), confidence: score))
            }
            let box = CGRect(x: CGFloat(left) * stride, y: CGFloat(top) * stride, width: CGFloat(bw) * stride, height: CGFloat(bh) * stride)
            if poses.contains(where: { iou($0.boundingBox, frame.toSource(box)) > iouThreshold }) { continue }
            poses.append(Pose(confidence: center.score, boundingBox: frame.toSource(box), keypoints: keypoints))
        }
        return poses
    }
}
