import CoreGraphics
import XCTest
@testable import StudioCore

/// RetinaFace / LightFace anchor decoding, per-channel dequantization, class-score segmentation and the
/// per-embedder face lists, on hand-made tensors with known answers.
final class FaceAndSegmentationTests: XCTestCase {
    private func model(_ name: String) throws -> ModelInfo { try XCTUnwrap(ModelCatalog.everything.first { $0.name == name }) }

    /// A frame whose input covers the whole source picture (no letterbox), so input pixels map linearly.
    private func frame(_ model: ModelInfo) -> PreparedFrame {
        PreparedFrame(rgb: [], width: model.inputWidth, height: model.inputHeight, sourceWidth: model.inputWidth,
                      sourceHeight: model.inputHeight, contentRect: CGRect(x: 0, y: 0, width: model.inputWidth, height: model.inputHeight))
    }

    /// Float32 outputs of `model`: class tensors (`classFeatures` channels) say "background" everywhere
    /// (logits 5, 0), the rest is 0; `edit` then fills in values per stream.
    private func tensors(_ model: ModelInfo, classFeatures: Set<Int>, edit: (StreamInfo, inout [Float]) -> Void) -> [Tensor] {
        model.outputs.map { stream in
            let count = (stream.height ?? 1) * (stream.width ?? 1) * (stream.features ?? 1)
            var values = [Float](repeating: 0, count: count)
            if classFeatures.contains(stream.features ?? 0) { for i in stride(from: 0, to: count, by: 2) { values[i] = 5 } }
            edit(stream, &values)
            return Tensor(stream: stream.asFloat32, bytes: values.withUnsafeBytes { Array($0) })
        }
    }

    func testLayoutsAreRecognised() throws {
        XCTAssertTrue(PostProcess.faceAnchors(for: try model("lightface_slim"))?.landmarks == false)
        XCTAssertTrue(PostProcess.faceAnchors(for: try model("retinaface_mobilenet_v1"))?.landmarks == true)
        XCTAssertNil(PostProcess.faceAnchors(for: try model("scrfd_10g")))
        for name in ["lightface_slim", "retinaface_mobilenet_v1", "scrfd_10g"] {
            XCTAssertTrue(VisionPipeline.supports(.face, model: try model(name)), name)
        }
        for name in ["deeplab_v3_mobilenet_v2", "unet_mobilenet_v2", "deeplab_v3_mobilenet_v2_wo_dilation"] {
            XCTAssertTrue(VisionPipeline.supports(.semanticSegmentation, model: try model(name)), name)
        }
        XCTAssertFalse(FaceRecognition.findsLandmarks(try model("lightface_slim")))
        XCTAssertTrue(FaceRecognition.findsLandmarks(try model("scrfd_10g")))
    }

    /// One LightFace anchor (stride 16, row 5, column 7, size 48) says "face" with zero offsets: the box
    /// is the anchor itself, centred on (7.5 x 16, 5.5 x 16) = (120, 88).
    func testLightFaceAnchorBox() throws {
        let lightface = try model("lightface_slim")
        let anchor = (5 * 20 + 7) * 2 + 1   // cell (5, 7) of the 15 x 20 grid, second of 2 anchors
        let outputs = tensors(lightface, classFeatures: [4, 6]) { stream, values in
            if stream.height == 15, stream.features == 4 { values[2 * anchor] = 0; values[2 * anchor + 1] = 5 }
        }
        let faces = PostProcess.anchorFaces(outputs, frame: frame(lightface), anchors: .lightFace)
        XCTAssertEqual(faces.count, 1)
        let box = try XCTUnwrap(faces.first).boundingBox
        XCTAssertEqual(box.midX * 320, 120, accuracy: 0.01)
        XCTAssertEqual(box.midY * 240, 88, accuracy: 0.01)
        XCTAssertEqual(box.width * 320, 48, accuracy: 0.01)
        XCTAssertEqual(faces[0].confidence, 1 / (1 + exp(-5)), accuracy: 1e-5)
        XCTAssertTrue(faces[0].landmarks.isEmpty)
    }

    /// RetinaFace: offsets move the centre by d / 10 x size, scale the size by exp(d / 5), and place
    /// landmarks like the centre.
    func testRetinaFaceOffsetsAndLandmarks() throws {
        let retina = try model("retinaface_mobilenet_v1")
        let anchor = (10 * 40 + 20) * 2   // stride 32: cell (10, 20) of 23 x 40, first anchor (size 256)
        let outputs = tensors(retina, classFeatures: [4]) { stream, values in
            guard stream.height == 23 else { return }
            switch stream.features {
            case 4: values[2 * anchor] = 0; values[2 * anchor + 1] = 5
            case 8: values[4 * anchor] = 1; values[4 * anchor + 2] = 5 * log(0.5)   // x + 25.6, width 128
            case 20: values[10 * anchor] = -2; values[10 * anchor + 1] = 1   // first landmark: x - 51.2, y + 25.6
            default: break
            }
        }
        let faces = PostProcess.anchorFaces(outputs, frame: frame(retina), anchors: .retinaFace)
        XCTAssertEqual(faces.count, 1)
        let face = try XCTUnwrap(faces.first)
        XCTAssertEqual(face.boundingBox.midX * 1280, 20.5 * 32 + 25.6, accuracy: 0.01)
        XCTAssertEqual(face.boundingBox.width * 1280, 128, accuracy: 0.01)
        XCTAssertEqual(face.boundingBox.height * 736, 256, accuracy: 0.01)
        XCTAssertEqual(face.landmarks.count, 5)
        XCTAssertEqual(face.landmarks[0].x * 1280, 20.5 * 32 - 51.2, accuracy: 0.01)
        XCTAssertEqual(face.landmarks[0].y * 736, 10.5 * 32 + 25.6, accuracy: 0.01)
    }

    func testPerChannelDequantization() {
        var stream = StreamInfo(name: "out", type: "UINT8", order: "NHWC", frameSize: 4, height: 1, width: 2, features: 2,
                                qpZp: 0, qpScale: 0, classes: nil, maxBoxes: nil)
        stream.qpZps = [10, 100]
        stream.qpScales = [0.5, 2]
        let tensor = Tensor(stream: stream, bytes: [12, 101, 10, 98])
        XCTAssertEqual(tensor.floats(), [1, 2, 0, -4])
        let float = tensor.withPerChannelDequantized
        XCTAssertEqual(float.stream.type, "FLOAT32")
        XCTAssertEqual(float.floats(), [1, 2, 0, -4])
    }

    /// unet_mobilenet_v2: three scores per pixel; the best one wins and the pet labels apply.
    func testClassScoreSegmentation() throws {
        let unet = try model("unet_mobilenet_v2")
        let stream = StreamInfo(name: "out", type: "UINT8", order: "NHWC", frameSize: 12, height: 2, width: 2, features: 3,
                                qpZp: 117, qpScale: 0.11, classes: nil, maxBoxes: nil)
        let tensor = Tensor(stream: stream, bytes: [200, 10, 10, 10, 200, 10, 10, 10, 200, 10, 200, 10])
        let map = PostProcess.segmentation(tensor, model: unet)
        XCTAssertEqual(map.classes, [0, 1, 2, 1])
        XCTAssertEqual(map.labels, ["pet", "background", "pet outline"])
        XCTAssertEqual(map.background, 1)
        let voc = Labels.segmentation(for: try model("deeplab_v3_mobilenet_v2"))
        XCTAssertEqual(voc.labels.count, 21)
        XCTAssertEqual(voc.labels[12], "dog")
        XCTAssertEqual(voc.colors[12], [64, 0, 128])
        XCTAssertEqual(voc.colors[15], [192, 128, 128])
    }

    func testFaceListsPerEmbedder() throws {
        // A list saved before the embedder could be chosen belongs to MobileFaceNet.
        let old = try JSONDecoder().decode(FaceGallery.self, from: Data(#"{"people":{"Ann":[[1,0]]},"threshold":0.4}"#.utf8))
        XCTAssertEqual(old.embedder, "arcface_mobilefacenet")
        XCTAssertEqual(FaceGallery.fileName(for: "arcface_mobilefacenet"), "faces.json")
        XCTAssertEqual(FaceGallery.fileName(for: "arcface_r50"), "faces-arcface_r50.json")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var r50 = FaceGallery(embedder: "arcface_r50")
        r50.enroll("Bo", embedding: [0, 1])
        r50.save(to: folder)
        XCTAssertEqual(FaceGallery.load(from: folder, embedder: "arcface_r50").people.keys.sorted(), ["Bo"])
        XCTAssertTrue(FaceGallery.load(from: folder, embedder: "arcface_mobilefacenet").people.isEmpty)
    }
}
