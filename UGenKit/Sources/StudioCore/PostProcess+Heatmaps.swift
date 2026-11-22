import CoreGraphics
import Foundation

// Single-person pose models (ViTPose, MSPN): one person crop in, one heatmap per COCO keypoint out
// (64 x 48 x 17 for a 256 x 192 crop). The two need different refinements of the heatmap peak, as in the
// Model Zoo's vit_pose_postprocessing.py and mspn_postprocessing.py; `TopDownPose` makes the crops.

extension PostProcess {
    /// How a heatmap model's crop is laid out and its peaks refined.
    public enum HeatmapStyle: Sendable {
        /// ViTPose: "unbiased" crops (pixel 0 and the last pixel sit on the crop's edges) and DARK
        /// refinement (one Newton step on the log heatmap).
        case unbiased
        /// MSPN: classic crops (the crop's centre at width / 2) and a quarter-pixel step towards the
        /// higher neighbour after a 5 x 5 Gaussian blur.
        case classic
    }

    /// The heatmap style of a single-person pose model. Both have the same output layout, so the Zoo's
    /// meta architecture (in the name) decides.
    public static func heatmapStyle(for model: ModelInfo) -> HeatmapStyle? {
        guard model.outputs.count == 1, let o = model.outputs.first, o.features == 17, (o.height ?? 0) > 1, (o.width ?? 0) > 1,
              model.tasks.contains("single_person_pose_estimation") else { return nil }
        return model.name.hasPrefix("mspn") ? .classic : .unbiased
    }

    /// One person from the 17 heatmaps of a crop. `frame` maps crop pixels to the picture (see
    /// `TopDownPose.crop`). The box is the crop's part of the picture and the confidence the mean keypoint
    /// score; `TopDownPose` replaces both with the person detector's.
    public static func heatmapPose(_ tensor: Tensor, style: HeatmapStyle, frame: PreparedFrame) -> Pose {
        let w = tensor.width, h = tensor.height, k = tensor.features
        let values = tensor.floats()
        // One map per keypoint, row-major (the tensor is NHWC).
        var maps = [[Float]](repeating: [Float](repeating: 0, count: w * h), count: k)
        for i in 0..<(w * h) {
            for j in 0..<k { maps[j][i] = values[i * k + j] }
        }
        var keypoints: [Pose.Keypoint] = []
        for map in maps {
            let (x, y, score) = style == .unbiased ? darkPeak(map, width: w, height: h) : classicPeak(map, width: w, height: h)
            // Heatmap cells to crop pixels: unbiased crops put the first and last cell on the crop's edges.
            let sx = style == .unbiased ? Double(frame.width) / Double(w - 1) : Double(frame.width) / Double(w)
            let sy = style == .unbiased ? Double(frame.height) / Double(h - 1) : Double(frame.height) / Double(h)
            keypoints.append(Pose.Keypoint(position: frame.toSource(x: CGFloat(x * sx), y: CGFloat(y * sy)), confidence: score))
        }
        let mean = keypoints.map(\.confidence).reduce(0, +) / Float(max(keypoints.count, 1))
        return Pose(confidence: mean, boundingBox: frame.toSource(frame.contentRect), keypoints: keypoints)
    }

    /// The highest cell (first one on ties, like numpy's argmax) and its value.
    private static func argmax(_ map: [Float]) -> (index: Int, value: Float) {
        var best = 0
        for i in map.indices where map[i] > map[best] { best = i }
        return (best, map[best])
    }

    /// ViTPose (post_dark_udp): log of the heatmap clipped to 0.001...50, edge-padded, then one Newton
    /// step from the peak. The Zoo's Gaussian blur before it has no effect there (cv2.GaussianBlur's
    /// result is thrown away), so it is left out here too. The score is the raw peak value.
    static func darkPeak(_ map: [Float], width w: Int, height h: Int) -> (x: Double, y: Double, score: Float) {
        let (index, peak) = argmax(map)
        let px = index % w, py = index / w
        guard peak > 0 else { return (-1, -1, peak) }
        func at(_ x: Int, _ y: Int) -> Double {
            let value = map[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)]
            return log(Double(min(max(value, 0.001), 50)))
        }
        let i = at(px, py)
        let dx = 0.5 * (at(px + 1, py) - at(px - 1, py))
        let dy = 0.5 * (at(px, py + 1) - at(px, py - 1))
        let dxx = at(px + 1, py) - 2 * i + at(px - 1, py)
        let dyy = at(px, py + 1) - 2 * i + at(px, py - 1)
        let dxy = 0.5 * (at(px + 1, py + 1) - at(px + 1, py) - at(px, py + 1) + 2 * i - at(px - 1, py) - at(px, py - 1) + at(px - 1, py - 1))
        // Inverse of the Hessian (+ 1e-6 on the diagonal, as in the Zoo) times the gradient.
        let a = dxx + 1e-6, d = dyy + 1e-6, determinant = a * d - dxy * dxy
        guard determinant != 0 else { return (Double(px), Double(py), peak) }
        let stepX = (d * dx - dxy * dy) / determinant
        let stepY = (a * dy - dxy * dx) / determinant
        return (Double(px) - stepX, Double(py) - stepY, peak)
    }

    /// MSPN: blur with a 5 x 5 Gaussian (sigma 1.1, zeros outside), take the peak, move a quarter cell
    /// towards the higher neighbour and add half a cell (the cell's centre). Its heatmap peaks are not
    /// probabilities (up to about 220 where it is sure; the Zoo scores peak / 255 + 0.5, a rescoring for
    /// COCO's mAP that makes every keypoint look certain). Score here: peak / `mspnPeakForCertain`, which
    /// follows ViTPose's scores on the same crop (thumbs_up.jpg: ViTPose 0.5 is near an MSPN peak of 85).
    static let mspnPeakForCertain: Float = 170

    static func classicPeak(_ map: [Float], width w: Int, height h: Int) -> (x: Double, y: Double, score: Float) {
        let blurred = gaussianBlur5(map, width: w, height: h)
        let (index, _) = argmax(blurred)
        let peak = map.max() ?? 0   // the Zoo rescales the blurred map to the original maximum
        var x = Double(index % w), y = Double(index / w)
        let px = index % w, py = index / w
        if px > 1, px < w - 1, py > 1, py < h - 1 {
            let diffX = blurred[py * w + px + 1] - blurred[py * w + px - 1]
            let diffY = blurred[(py + 1) * w + px] - blurred[(py - 1) * w + px]
            x += diffX > 0 ? 0.25 : (diffX < 0 ? -0.25 : 0)
            y += diffY > 0 ? 0.25 : (diffY < 0 ? -0.25 : 0)
            x += 0.5
            y += 0.5
        }
        return (x, y, min(max(peak / mspnPeakForCertain, 0), 1))
    }

    /// cv2.GaussianBlur with a 5 x 5 kernel and sigma 0 (so 1.1) on a map padded with zeros.
    static func gaussianBlur5(_ map: [Float], width w: Int, height h: Int) -> [Float] {
        let sigma = 0.3 * ((5.0 - 1) * 0.5 - 1) + 0.8
        var kernel = (-2...2).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var rows = [Float](repeating: 0, count: w * h), out = rows
        for y in 0..<h {
            for x in 0..<w {
                var sum: Float = 0
                for t in -2...2 where x + t >= 0 && x + t < w { sum += kernel[t + 2] * map[y * w + x + t] }
                rows[y * w + x] = sum
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var sum: Float = 0
                for t in -2...2 where y + t >= 0 && y + t < h { sum += kernel[t + 2] * rows[(y + t) * w + x] }
                out[y * w + x] = sum
            }
        }
        return out
    }
}
