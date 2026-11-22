import CoreGraphics
import Foundation

/// Pose with a single-person model (ViTPose, MSPN), "top-down": a detector finds the people, each one is
/// cut out as the Model Zoo does (the box widened to the crop's 3:4 shape, 25% added around it, outside
/// the picture black) and goes through the pose model on its own. Both models must be loaded on the
/// device (`VisionTask.companionModels(for:)` names the detector).
public enum TopDownPose {
    /// Finds the people. yolov8s is the examples' default detector, small and fast on both engines.
    public static let detectorName = "yolov8s"
    /// People below this detector score are skipped.
    public static let personThreshold: Float = 0.4
    /// Each person costs one more pose run; more than this many (the largest scores first) are left out.
    public static let maxPeople = 6
    /// Room added around the person's box (the Zoo's `padding`).
    static let padding = 1.25

    public static func isTopDown(_ model: ModelInfo) -> Bool { PostProcess.heatmapStyle(for: model) != nil }

    /// People and their keypoints in `image`.
    public static func run(_ image: CGImage, model: ModelInfo, device: any InferenceEngine, maxPeople: Int = maxPeople) async throws -> [Pose] {
        guard let style = PostProcess.heatmapStyle(for: model), let detector = ModelCatalog.model(named: detectorName) else {
            throw StudioError.invalidInput("\(model.name) is not a single-person pose model.")
        }
        let frame = try VisionPipeline.prepare(image, for: detector, task: .detection)
        let tensors = try await device.infer(inputs: [frame.rgb], model: detectorName)
        guard case .detections(let found) = VisionPipeline.decode(tensors, task: .detection, model: detector, frame: frame) else { return [] }
        let people = found.filter { $0.classIndex == 0 && $0.confidence >= personThreshold }.prefix(maxPeople)
        guard !people.isEmpty, let pixels = RGBAPixels(image) else { return [] }

        let crops = people.map { crop(pixels, box: $0.boundingBox, model: model, style: style) }
        let outputs = try await device.inferEach(crops.map(\.rgb), model: model.name)
        return zip(people, zip(crops, outputs)).map { person, run in
            let pose = PostProcess.heatmapPose(run.1[0], style: style, frame: run.0)
            return Pose(confidence: person.confidence, boundingBox: person.boundingBox, keypoints: pose.keypoints)
        }
    }

    /// The model's input for the person in `box` (normalized to the picture). The returned frame maps
    /// crop pixels back: its source region is the crop's rectangle in the picture, which may reach past
    /// the picture's edges.
    public static func crop(_ pixels: RGBAPixels, box: CGRect, model: ModelInfo, style: PostProcess.HeatmapStyle) -> PreparedFrame {
        let inW = model.inputWidth, inH = model.inputHeight
        let aspect = Double(inW) / Double(inH)
        let pw = Double(pixels.width), ph = Double(pixels.height)
        // _bbox_xywh2cs: centre of the box, the short side grown to the crop's aspect ratio, then padding.
        var w = Double(box.width) * pw, h = Double(box.height) * ph
        let cx = Double(box.midX) * pw, cy = Double(box.midY) * ph
        if w > aspect * h { h = w / aspect } else if w < aspect * h { w = h * aspect }
        w *= padding
        h *= padding
        // Crop pixel u samples the picture at cx - w / 2 + u * step, in pixels with centres at whole numbers
        // (cv2.warpAffine's, hence the - 0.5). Unbiased crops (get_warp_matrix) put pixels 0 and inW - 1 on
        // the crop's edges; classic ones (get_affine_transform) put the crop's centre at inW / 2.
        let stepX = style == .unbiased ? w / Double(inW - 1) : w / Double(inW)
        let stepY = style == .unbiased ? h / Double(inH - 1) : h / Double(inH)
        let rgb = pixels.warp(width: inW, height: inH, x: (stepX, cx - w / 2 - 0.5), y: (stepY, cy - h / 2 - 0.5))
        let region = CGRect(x: (cx - w / 2) / pw, y: (cy - h / 2) / ph, width: w / pw, height: h / ph)
        return PreparedFrame(rgb: rgb, width: inW, height: inH, sourceWidth: pixels.width, sourceHeight: pixels.height,
                             contentRect: CGRect(x: 0, y: 0, width: inW, height: inH), sourceRegion: region)
    }
}

extension RGBAPixels {
    /// RGB bytes of a `width` x `height` picture whose pixel (u, v) is this picture's point
    /// (x.scale * u + x.offset, y.scale * v + y.offset), in pixels with centres at whole numbers. Bilinear,
    /// with black outside (cv2.warpAffine with INTER_LINEAR and a constant border).
    func warp(width: Int, height: Int, x: (scale: Double, offset: Double), y: (scale: Double, offset: Double)) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 3)
        let sw = self.width, sh = self.height
        bytes.withUnsafeBufferPointer { src in
            func sample(_ xi: Int, _ yi: Int, _ channel: Int) -> Double {
                guard xi >= 0, yi >= 0, xi < sw, yi < sh else { return 0 }
                return Double(src[(yi * sw + xi) * 4 + channel])
            }
            for v in 0..<height {
                let py = y.scale * Double(v) + y.offset
                let y0 = Int(floor(py)), fy = py - floor(py)
                guard y0 >= -1, y0 < sh else { continue }
                for u in 0..<width {
                    let px = x.scale * Double(u) + x.offset
                    let x0 = Int(floor(px)), fx = px - floor(px)
                    guard x0 >= -1, x0 < sw else { continue }
                    let o = (v * width + u) * 3
                    for channel in 0..<3 {
                        let top = sample(x0, y0, channel) * (1 - fx) + sample(x0 + 1, y0, channel) * fx
                        let bottom = sample(x0, y0 + 1, channel) * (1 - fx) + sample(x0 + 1, y0 + 1, channel) * fx
                        out[o + channel] = UInt8(clamping: Int((top * (1 - fy) + bottom * fy).rounded()))
                    }
                }
            }
        }
        return out
    }
}
