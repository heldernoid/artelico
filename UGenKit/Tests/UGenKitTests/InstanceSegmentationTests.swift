import CoreGraphics
import XCTest
@testable import StudioCore

/// YOLACT, YOLO26-seg, FastSAM and the device's byte-mask output, on hand-made tensors with known answers.
/// Tensors go through `CoreMLEngine.tensor`, the same conversion Core ML outputs get.
final class InstanceSegmentationTests: XCTestCase {
    private func model(_ name: String) throws -> ModelInfo { try XCTUnwrap(ModelCatalog.everything.first { $0.name == name }) }

    /// A frame whose input covers the whole source picture (no letterbox), so input pixels map linearly.
    private func frame(_ model: ModelInfo) -> PreparedFrame {
        PreparedFrame(rgb: [], width: model.inputWidth, height: model.inputHeight, sourceWidth: model.inputWidth,
                      sourceHeight: model.inputHeight, contentRect: CGRect(x: 0, y: 0, width: model.inputWidth, height: model.inputHeight))
    }

    /// All outputs at `fill` per stream (default 0), then edited per stream.
    private func tensors(_ model: ModelInfo, fill: (StreamInfo) -> Float = { _ in 0 }, edit: (StreamInfo, inout [Float]) -> Void) -> [Tensor] {
        model.outputs.map { stream in
            var values = [Float](repeating: fill(stream), count: (stream.height ?? 1) * (stream.width ?? 1) * (stream.features ?? 1))
            edit(stream, &values)
            return CoreMLEngine.tensor(values, like: stream)
        }
    }

    func testLayoutsAreRecognised() throws {
        for name in ["yolo26n_seg", "yolo26s_seg", "yolo26m_seg", "yolo26l_seg", "yolov5n_seg_hpp", "yolov5s_seg_hpp", "yolov5m_seg_hpp",
                     "yolact_regnetx_800mf", "yolact_regnetx_1.6gf", "yolov8n_seg", "yolov5n_seg"] {
            XCTAssertTrue(VisionPipeline.supports(.instanceSegmentation, model: try model(name)), name)
            XCTAssertFalse(VisionPipeline.supports(.segmentEverything, model: try model(name)), name)
        }
        XCTAssertTrue(VisionPipeline.supports(.segmentEverything, model: try model("fast_sam_s")))
        XCTAssertFalse(VisionPipeline.supports(.instanceSegmentation, model: try model("fast_sam_s")))
        XCTAssertTrue(VisionPipeline.isYOLACT(try model("yolact_regnetx_800mf")))
        XCTAssertFalse(VisionPipeline.isYOLACT(try model("yolov8n_seg")))
    }

    /// One YOLACT anchor (32 x 32 grid, row 10, column 20, scale 48 x 2^(1/3), aspect 0.5) says "person"
    /// with zero offsets: the box is the prior itself.
    func testYOLACTPriorBox() throws {
        let yolact = try model("yolact_regnetx_800mf")
        let anchor = (10 * 32 + 20) * 9 + 4
        let outputs = tensors(yolact) { stream, values in
            if stream.features == 729 {
                for a in 0..<(values.count / 81) { values[a * 81] = 5 }   // background everywhere
                if stream.height == 32 { values[anchor * 81] = 0; values[anchor * 81 + 1] = 10 }
            }
        }
        let found = PostProcess.instances(outputs, model: yolact, frame: frame(yolact))
        XCTAssertEqual(found.count, 1)
        let item = try XCTUnwrap(found.first)
        XCTAssertEqual(item.detection.label, "person")
        let scale = 48 * pow(2, 1.0 / 3), ratio = 0.5.squareRoot()
        XCTAssertEqual(item.detection.boundingBox.midX * 512, 20.5 / 32 * 512, accuracy: 0.5)
        XCTAssertEqual(item.detection.boundingBox.midY * 512, 10.5 / 32 * 512, accuracy: 0.5)
        XCTAssertEqual(item.detection.boundingBox.width * 512, scale * ratio, accuracy: 0.5)
        XCTAssertEqual(item.detection.boundingBox.height * 512, scale / ratio, accuracy: 0.5)
    }

    /// YOLO26-seg: one stride-8 cell (row 10, column 20) with distances 1, 1, 2, 2 and a coefficient that
    /// switches on prototype channel 0: the mask fills the box, at prototype resolution (input / 4).
    func testYOLO26SegBoxAndMask() throws {
        let yolo = try model("yolo26n_seg")
        let cell = 10 * 80 + 20
        let outputs = tensors(yolo, fill: { $0.features == 80 ? -10 : 0 }) { stream, values in
            switch (stream.height, stream.features) {
            case (80, 80): values[cell * 80 + 2] = 5   // car
            case (80, 4): values[cell * 4] = 1; values[cell * 4 + 1] = 1; values[cell * 4 + 2] = 2; values[cell * 4 + 3] = 2
            case (80, 32): values[cell * 32] = 3
            case (160, 32): for i in stride(from: 0, to: values.count, by: 32) { values[i] = 1 }
            default: break
            }
        }
        let found = PostProcess.instances(outputs, model: yolo, frame: frame(yolo))
        XCTAssertEqual(found.count, 1)
        let item = try XCTUnwrap(found.first)
        XCTAssertEqual(item.detection.label, "car")
        XCTAssertEqual(item.detection.boundingBox.minX * 640, 156, accuracy: 0.5)
        XCTAssertEqual(item.detection.boundingBox.maxY * 640, 100, accuracy: 0.5)
        XCTAssertEqual(item.maskWidth, 160)
        XCTAssertEqual(item.mask.filter { $0 != 0 }.count, 6 * 6)   // columns 39..44, rows 19..24
    }

    /// FastSAM: the YOLOv8-seg layout with one score; instances are numbered and have no class.
    func testFastSAMSegmentsAreNumbered() throws {
        let sam = try model("fast_sam_s")
        let cell = 5 * 20 + 5
        let outputs = tensors(sam) { stream, values in
            guard stream.height == 20 else { return }
            switch stream.features {
            case 1: values[cell] = 0.9
            case 64: for side in 0..<4 { values[cell * 64 + side * 16 + 2] = 10 }   // distance 2 on every side
            default: break
            }
        }
        let found = PostProcess.instances(outputs, model: sam, frame: frame(sam))
        XCTAssertEqual(found.count, 1)
        let item = try XCTUnwrap(found.first)
        XCTAssertEqual(item.detection.label, "object 1")
        XCTAssertEqual(item.detection.classIndex, -1)
        XCTAssertEqual(item.detection.boundingBox.minX * 640, 112, accuracy: 1)
        XCTAssertEqual(item.detection.boundingBox.maxX * 640, 240, accuracy: 1)
    }

    /// HailoRT's NMS_WITH_BYTE_MASK buffer: count, 46-byte headers, each followed by its box-sized mask.
    func testByteMaskOutput() throws {
        let hpp = try model("yolov5n_seg_hpp")
        func detection(_ box: [Float], score: Float, classIndex: UInt16, mask: [UInt8], at offset: Int) -> [UInt8] {
            var header = Data()
            for value in box + [score] { withUnsafeBytes(of: value.bitPattern.littleEndian) { header.append(contentsOf: $0) } }
            withUnsafeBytes(of: classIndex.littleEndian) { header.append(contentsOf: $0) }
            for value in [UInt64(mask.count), 0, UInt64(offset + 46)] { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
            return Array(header) + mask
        }
        // Box x 160..320, y 64..192 (y_min, x_min, y_max, x_max of 640): 160 x 128 mask, left half set.
        let mask = (0..<128).flatMap { _ in [UInt8](repeating: 1, count: 80) + [UInt8](repeating: 0, count: 80) }
        var bytes: [UInt8] = [2, 0]
        bytes += detection([0.1, 0.25, 0.3, 0.5], score: 0.9, classIndex: 16, mask: mask, at: bytes.count)
        bytes += detection([0, 0, 0.01, 0.01], score: 0.1, classIndex: 0, mask: [UInt8](repeating: 1, count: 49), at: bytes.count)
        let stream = hpp.outputs[0]
        // Letterboxed: the picture fills x 80..560 of the input.
        let letterboxed = PreparedFrame(rgb: [], width: 640, height: 640, sourceWidth: 480, sourceHeight: 640,
                                        contentRect: CGRect(x: 80, y: 0, width: 480, height: 640))
        let found = PostProcess.instances([Tensor(stream: stream, bytes: bytes)], model: hpp, frame: letterboxed)
        XCTAssertEqual(found.count, 1)   // the second is below 0.3
        let item = try XCTUnwrap(found.first)
        XCTAssertEqual(item.detection.label, "dog")
        XCTAssertEqual(item.maskWidth, 480)
        XCTAssertEqual(item.mask.filter { $0 != 0 }.count, 80 * 128)
        XCTAssertEqual(item.mask[64 * 480 + (160 - 80)], 255)
        XCTAssertEqual(item.mask[64 * 480 + (240 - 80)], 0)
        XCTAssertEqual(item.detection.boundingBox.minX, (160.0 - 80) / 480, accuracy: 1e-4)
    }
}
