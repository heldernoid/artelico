import CoreGraphics
import XCTest
@testable import StudioCore

/// The face and person crop models (attributes, re-identification, dense landmarks) and the video
/// clip of r3d_18, on hand-made tensors with known answers.
final class CropModelTests: XCTestCase {
    private func model(_ name: String) throws -> ModelInfo { try XCTUnwrap(ModelCatalog.everything.first { $0.name == name }) }

    /// tddfa_bfm68.bin (Basel Face Model licence) is left out of the public repository; 3DDFA is then not offered.
    private var haveBFM: Bool { PostProcess.FaceModel3D.landmarks != nil }

    func testLayoutsAndCompanions() throws {
        let pairs: [(VisionTask, String)] = [
            (.faceAttributes, "face_attr_resnet_v1_18"), (.personAttributes, "person_attr_resnet_v1_18"),
            (.personReID, "osnet_x1_0"), (.personReID, "repvgg_a0_person_reid_512"), (.faceLandmarks, "tddfa_mobilenet_v1"),
            (.faceLandmarks, "face_landmarks_lite"), (.videoClassification, "r3d_18"),
        ].filter { haveBFM || $0.1 != "tddfa_mobilenet_v1" }
        if !haveBFM { XCTAssertFalse(VisionPipeline.supports(.faceLandmarks, model: try model("tddfa_mobilenet_v1"))) }
        for (task, name) in pairs {
            XCTAssertTrue(VisionPipeline.supports(task, model: try model(name)), name)
            XCTAssertEqual(VisionTask.allCases.filter { VisionPipeline.supports($0, model: try! model(name)) }, [task], name)
        }
        XCTAssertEqual(VisionTask.faceAttributes.companionModels(for: try model("face_attr_resnet_v1_18")), [FaceRecognition.detectorName])
        XCTAssertEqual(VisionTask.personReID.companionModels(for: try model("osnet_x1_0")), [TopDownPose.detectorName])
        XCTAssertEqual(VisionTask.videoClassification.companionModels(for: try model("r3d_18")), [])
        XCTAssertEqual(Labels.kinetics400.count, 400)
        XCTAssertEqual(ModelCatalog.models(for: "face_landmarks").map(\.name).sorted(), ["face_landmarks_lite", "tddfa_mobilenet_v1"])
    }

    /// CelebA: one (absent, present) pair per attribute, softmaxed; "attractive" is never shown.
    func testFaceAttributes() throws {
        let stream = try model("face_attr_resnet_v1_18").outputs[0]
        var values = [Float](repeating: 0, count: 80)
        for i in 0..<40 { values[2 * i] = 2 }                     // everything absent...
        values[2 * 31] = 0; values[2 * 31 + 1] = 3                // ...but smiling (index 31): 1 / (1 + e^-3)
        values[2 * 15] = 0; values[2 * 15 + 1] = 1                // and glasses: 1 / (1 + e^-1)
        values[2 * 2] = 0; values[2 * 2 + 1] = 5                  // "attractive": hidden
        let found = PostProcess.faceAttributes(CoreMLEngine.tensor(values, like: stream))
        XCTAssertEqual(found.map(\.label), ["smiling", "glasses"])
        XCTAssertEqual(found[0].probability, 1 / (1 + exp(-3)), accuracy: 0.01)
        XCTAssertEqual(found[1].probability, 1 / (1 + exp(-1)), accuracy: 0.01)
    }

    /// PETA: one logit per attribute, present from 0 on.
    func testPersonAttributes() throws {
        let stream = try model("person_attr_resnet_v1_18").outputs[0]
        var values = [Float](repeating: -4, count: 35)
        values[4] = 2      // backpack
        values[16] = 0.5   // male
        let found = PostProcess.personAttributes(CoreMLEngine.tensor(values, like: stream))
        XCTAssertEqual(found.map(\.label), ["backpack", "male"])
        XCTAssertEqual(found[1].probability, 1 / (1 + exp(-0.5)), accuracy: 0.02)
    }

    /// 3DDFA: all-zero outputs mean the average face; points and pose as 3DDFA_V2's code gives them
    /// (worked out in numpy from bfm_noneck_v3.pkl and TDDFA_RESCALE_PARAMS).
    func testTDDFAAverageFace() throws {
        try XCTSkipUnless(haveBFM, "tddfa_bfm68.bin is missing (native/tools/make_tddfa_bfm68.py makes it)")
        let stream = try model("tddfa_mobilenet_v1").outputs[0]
        let decoded = try XCTUnwrap(PostProcess.tddfaLandmarks(CoreMLEngine.tensor([Float](repeating: 0, count: 62), like: stream)))
        XCTAssertEqual(decoded.points.count, 68)
        let expected: [Int: (Double, Double)] = [0: (34.04, 36.67), 8: (58.97, 101.37), 30: (59.06, 57.05), 36: (44.01, 35.52), 45: (74.00, 35.61)]
        for (index, point) in expected {
            XCTAssertEqual(Double(decoded.points[index].x), point.0, accuracy: 0.05, "point \(index)")
            XCTAssertEqual(Double(decoded.points[index].y), point.1, accuracy: 0.05, "point \(index)")
        }
        XCTAssertEqual(decoded.pose.yaw, 0.109, accuracy: 0.01)
        XCTAssertEqual(decoded.pose.pitch, 5.048, accuracy: 0.01)
        XCTAssertEqual(decoded.pose.roll, -0.062, accuracy: 0.01)
    }

    /// A head turned 30 degrees about the vertical axis gives yaw 30 (matrix2angle).
    func testHeadPoseYaw() {
        let a = Float(30) * .pi / 180
        // Rows of the camera matrix (scaled rotation about y, then offset): R = Ry(a) x 0.002.
        let p: [Float] = [cos(a) * 0.002, 0, sin(a) * 0.002, 60, 0, 0.002, 0, 70, -sin(a) * 0.002, 0, cos(a) * 0.002, -60]
        let pose = PostProcess.headPose(p + [Float](repeating: 0, count: 50))
        XCTAssertEqual(pose.yaw, -30, accuracy: 0.01)
        XCTAssertEqual(pose.pitch, 0, accuracy: 0.01)
        XCTAssertEqual(pose.roll, 0, accuracy: 0.01)
    }

    /// The same people keep their numbers in a second picture; a newcomer gets the next one; no name is
    /// given twice in one picture.
    func testReIdentificationNumbers() throws {
        func unit(_ v: [Float]) -> [Float] { let n = sqrt(v.reduce(0) { $0 + $1 * $1 }); return v.map { $0 / n } }
        let a = unit([1, 0, 0, 0]), b = unit([0, 1, 0, 0]), c = unit([0, 0, 1, 0])
        func people(_ vectors: [[Float]]) -> [DescribedObject] {
            vectors.map { DescribedObject(boundingBox: .zero, confidence: 1, embedding: $0) }
        }
        var gallery = ReIdentification.gallery(for: try model("repvgg_a0_person_reid_512"))
        var first = people([a, b])
        ReIdentification.name(&first, gallery: &gallery)
        XCTAssertEqual(first.map(\.name), ["Person 1", "Person 2"])
        var second = people([unit([0.1, 1, 0, 0]), c, unit([1, 0.2, 0, 0]), unit([1, 0.3, 0, 0])])
        ReIdentification.name(&second, gallery: &gallery)
        XCTAssertEqual(second.map(\.name), ["Person 2", "Person 3", "Person 1", "Person 4"])
        XCTAssertNil(second[1].similarity)
        XCTAssertEqual(try XCTUnwrap(second[2].similarity), 1 / sqrt(1.04), accuracy: 0.001)
    }

    /// Clip input: frame t's red, green and blue are channels 3t...3t+2, normalized and quantized.
    func testVideoClipLayout() throws {
        let r3d = try model("r3d_18")
        let pixels = 112 * 112
        let frames = (0..<16).map { t in [UInt8](repeating: 0, count: pixels * 3).enumerated().map { i, _ in UInt8(i % 3 == 0 ? 10 * t : 128) } }
        let input = VideoClip.input(frames, model: r3d)
        XCTAssertEqual(input.count, pixels * 48)
        let stream = r3d.inputs[0]
        func expected(_ value: Float, _ channel: Int) -> UInt8 {
            UInt8(clamping: Int(((value - VideoClip.mean[channel]) / VideoClip.std[channel] / stream.qpScale! + stream.qpZp!).rounded()))
        }
        for t in [0, 7, 15] {
            XCTAssertEqual(input[5 * 48 + 3 * t], expected(Float(10 * t), 0))
            XCTAssertEqual(input[5 * 48 + 3 * t + 2], expected(128, 2))
        }
    }

    /// A 24 per second source gives 12 frames a second; the first answer comes with frame 16, then one
    /// every 8 frames.
    func testVideoClipBeat() throws {
        let r3d = try model("r3d_18")
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        var clip = VideoClip()
        var answers: [Int] = []
        for frame in 0..<96 {
            if clip.add(image, at: Double(frame) / 24, model: r3d) != nil {
                answers.append(frame)
                clip.actions = [Classification(label: "x", classIndex: 0, probability: 1)]
            }
        }
        XCTAssertEqual(answers, [30, 46, 62, 78, 94])
    }
}
