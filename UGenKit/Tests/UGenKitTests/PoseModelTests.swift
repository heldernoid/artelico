import CoreGraphics
import XCTest
@testable import StudioCore

/// The single-person pose models (ViTPose, MSPN) and CenterPose, on hand-made tensors with known answers.
final class PoseModelTests: XCTestCase {
    private func model(_ name: String) throws -> ModelInfo { try XCTUnwrap(ModelCatalog.everything.first { $0.name == name }) }

    /// A frame whose input covers the whole source picture, so input pixels map linearly.
    private func frame(_ model: ModelInfo) -> PreparedFrame {
        PreparedFrame(rgb: [], width: model.inputWidth, height: model.inputHeight, sourceWidth: model.inputWidth,
                      sourceHeight: model.inputHeight, contentRect: CGRect(x: 0, y: 0, width: model.inputWidth, height: model.inputHeight))
    }

    func testLayoutsAndCompanions() throws {
        for name in ["vit_pose_small", "vit_pose_small_bn", "mspn_regnetx_800mf", "centerpose_regnetx_800mf", "yolov8s_pose"] {
            XCTAssertTrue(VisionPipeline.supports(.pose, model: try model(name)), name)
        }
        XCTAssertEqual(PostProcess.heatmapStyle(for: try model("vit_pose_small")), .unbiased)
        XCTAssertEqual(PostProcess.heatmapStyle(for: try model("mspn_regnetx_800mf")), .classic)
        XCTAssertNil(PostProcess.heatmapStyle(for: try model("yolov8s_pose")))
        XCTAssertTrue(PostProcess.isCenterPose(try model("centerpose_regnetx_800mf")))
        XCTAssertEqual(VisionTask.pose.companionModels(for: try model("vit_pose_small_bn")), [TopDownPose.detectorName])
        XCTAssertEqual(VisionTask.pose.companionModels(for: try model("centerpose_regnetx_800mf")), [])
        XCTAssertTrue(ModelCatalog.models(for: "pose").contains { $0.name == "mspn_regnetx_800mf" })
    }

    /// 17 heatmaps (64 x 48) with one Gaussian (sigma 2) per keypoint at `peak`.
    private func heatmaps(_ model: ModelInfo, peak: (x: Double, y: Double), height: Float) -> Tensor {
        let stream = model.outputs[0]
        var values = [Float](repeating: 0, count: 64 * 48 * 17)
        for y in 0..<64 {
            for x in 0..<48 {
                let v = height * Float(exp(-(pow(Double(x) - peak.x, 2) + pow(Double(y) - peak.y, 2)) / 8))
                for k in 0..<17 { values[(y * 48 + x) * 17 + k] = v }
            }
        }
        return CoreMLEngine.tensor(values, like: stream)
    }

    /// DARK finds a Gaussian's centre between cells; unbiased crops put cell 47 on the crop's right edge.
    func testViTPoseSubCellPeak() throws {
        let vit = try model("vit_pose_small")
        let pose = PostProcess.heatmapPose(heatmaps(vit, peak: (20.3, 30.6), height: 0.9), style: .unbiased, frame: frame(vit))
        let point = try XCTUnwrap(pose.keypoints.first)
        XCTAssertEqual(pose.keypoints.count, 17)
        XCTAssertEqual(point.position.x, 20.3 / 47, accuracy: 0.002)
        XCTAssertEqual(point.position.y, 30.6 / 63, accuracy: 0.002)
        XCTAssertEqual(point.confidence, 0.9 * Float(exp(-(0.09 + 0.16) / 8.0)), accuracy: 0.01)   // the peak cell's value
    }

    /// MSPN: a quarter cell towards the higher neighbour, plus half a cell.
    func testMSPNQuarterStep() throws {
        let mspn = try model("mspn_regnetx_800mf")
        let pose = PostProcess.heatmapPose(heatmaps(mspn, peak: (20.2, 30.3), height: 150), style: .classic, frame: frame(mspn))
        let point = try XCTUnwrap(pose.keypoints.first)
        XCTAssertEqual(point.position.x, (20 + 0.25 + 0.5) / 48, accuracy: 0.001)
        XCTAssertEqual(point.position.y, (30 + 0.25 + 0.5) / 64, accuracy: 0.001)
        XCTAssertEqual(point.confidence, 150 * Float(exp(-0.13 / 8.0)) / PostProcess.mspnPeakForCertain, accuracy: 0.02)
    }

    /// The Model Zoo's person crop: the box widened to 3:4, then 25% added; crop centre = box centre.
    func testPersonCrop() throws {
        let vit = try model("vit_pose_small")
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let pixels = try XCTUnwrap(RGBAPixels(try XCTUnwrap(context.makeImage())))
        let box = CGRect(x: 100.0 / 400, y: 50.0 / 300, width: 100.0 / 400, height: 100.0 / 300)
        let crop = TopDownPose.crop(pixels, box: box, model: vit, style: .unbiased)
        // 100 x 100 -> 100 x 133.3 (3:4) -> 125 x 166.7 around the centre (150, 100).
        XCTAssertEqual(crop.sourceRegion.minX * 400, 87.5, accuracy: 0.01)
        XCTAssertEqual(crop.sourceRegion.width * 400, 125, accuracy: 0.01)
        XCTAssertEqual(crop.sourceRegion.minY * 300, 100 - 166.667 / 2, accuracy: 0.01)
        XCTAssertEqual(crop.sourceRegion.height * 300, 166.667, accuracy: 0.01)
        XCTAssertEqual(crop.rgb.count, 192 * 256 * 3)
        // This crop lies inside the (white) picture; one at the picture's left edge reaches past it: black there.
        XCTAssertEqual(crop.rgb[(128 * 192 + 96) * 3], 255)
        XCTAssertEqual(crop.rgb[(2 * 192 + 96) * 3], 255)
        let wide = TopDownPose.crop(pixels, box: CGRect(x: 0, y: 0, width: 0.1, height: 0.5), model: vit, style: .classic)
        XCTAssertEqual(wide.rgb[(128 * 192 + 2) * 3], 0)   // left of the picture
    }

    /// CenterPose: one person centre; keypoint 0 moves to the nearby heatmap peak, keypoint 1 has none and
    /// keeps its regressed place (score 0). A neighbouring cell with the same score is the same person.
    func testCenterPose() throws {
        let center = try model("centerpose_regnetx_800mf")
        let (cx, cy) = (40, 50)
        let cell = cy * 128 + cx
        let outputs: [Tensor] = center.outputs.map { stream in
            var values = [Float](repeating: 0, count: 128 * 128 * (stream.features ?? 1))
            switch stream.name.split(separator: "/").last {
            case "conv60": values[cell] = 0.9; values[cell + 1] = 0.9
            case "conv61": for c in [cell, cell + 1] { values[c * 2] = 20; values[c * 2 + 1] = 40 }
            case "conv63": values[cell * 2] = 0.5; values[cell * 2 + 1] = 0.5
            case "conv62": for c in [cell, cell + 1] { for j in 0..<17 { values[c * 34 + 2 * j] = -4; values[c * 34 + 2 * j + 1] = -10 } }
            case "conv64": values[((cy - 9) * 128 + cx - 5) * 17] = 0.8   // keypoint 0, one cell from its regressed (36, 40)
            case "conv65": values[((cy - 9) * 128 + cx - 5) * 2] = 0.25
            default: break
            }
            return CoreMLEngine.tensor(values, like: stream)
        }
        let poses = PostProcess.centerPoses(outputs, frame: frame(center))
        XCTAssertEqual(poses.count, 1)
        let pose = try XCTUnwrap(poses.first)
        XCTAssertEqual(pose.confidence, 0.9, accuracy: 0.01)
        XCTAssertEqual(pose.boundingBox.midX * 128, 40.5, accuracy: 0.05)
        XCTAssertEqual(pose.boundingBox.height * 128, 40, accuracy: 0.05)
        XCTAssertEqual(pose.keypoints[0].position.x * 128, 35.25, accuracy: 0.05)
        XCTAssertEqual(pose.keypoints[0].position.y * 128, 41, accuracy: 0.05)
        XCTAssertEqual(pose.keypoints[0].confidence, 0.8, accuracy: 0.01)
        XCTAssertEqual(pose.keypoints[1].position.x * 128, 36, accuracy: 0.05)
        XCTAssertEqual(pose.keypoints[1].confidence, 0)
    }
}
