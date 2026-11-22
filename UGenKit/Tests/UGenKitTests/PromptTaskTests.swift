import CoreGraphics
import XCTest
@testable import StudioCore

/// The two prompt tasks: YOLO-World ("Find anything") and CLIP on each detected object ("Describe each
/// object"), on hand-made tensors with known answers.
final class PromptTaskTests: XCTestCase {
    private func model(_ name: String) throws -> ModelInfo { try XCTUnwrap(ModelCatalog.everything.first { $0.name == name }) }

    func testLayoutsAndCompanions() throws {
        let world = try model("yolo_world_v2s")
        XCTAssertTrue(OpenVocabulary.isOpenVocabulary(world))
        XCTAssertEqual(OpenVocabulary.slots(of: world), 80)
        XCTAssertEqual(VisionTask.allCases.filter { VisionPipeline.supports($0, model: world) }, [.findAnything])
        XCTAssertEqual(VisionTask.findAnything.companionModels(for: world), [OpenVocabulary.textEncoderName])
        XCTAssertEqual(ModelCatalog.models(for: VisionTask.findAnything.rawValue).filter { VisionPipeline.supports(.findAnything, model: $0) }.map(\.name),
                       ["yolo_world_v2s"])
        // Other two-input models stay out (stereo depth has its own task).
        XCTAssertFalse(OpenVocabulary.isOpenVocabulary(try model(StereoDepth.modelName)))

        // Describing: every CLIP image encoder, with its own text encoder and the chosen detector.
        let encoders = ModelCatalog.models(for: VisionTask.describeObjects.rawValue).filter { VisionPipeline.supports(.describeObjects, model: $0) }
        XCTAssertEqual(Set(encoders.map(\.name)), Set(CLIPModels.pairs.map(\.image)))
        let saved = ObjectCLIP.settings
        defer { ObjectCLIP.settings = saved }
        ObjectCLIP.settings = ObjectCLIP.Settings(objects: .vehicles, detector: "yolov8m")
        XCTAssertEqual(VisionTask.describeObjects.companionModels(for: try model("clip_vit_b_16_image_encoder")), ["clip_vit_b_16_text_encoder", "yolov8m"])
        ObjectCLIP.settings.objects = .faces
        XCTAssertEqual(ObjectCLIP.settings.detectorName, FaceRecognition.detectorName)
    }

    /// The text input: prompts repeated over the 80 slots, quantized with the input's zero point and scale.
    func testTextFrame() throws {
        let world = try model("yolo_world_v2s")
        let stream = world.inputs[1]
        let a = (0..<512).map { Float($0 % 7) * 0.02 - 0.06 }, b = (0..<512).map { Float($0 % 5) * -0.03 + 0.05 }
        let frame = try OpenVocabulary.textFrame([a, b], model: world)
        XCTAssertEqual(frame.count, stream.frameSize)
        let values = Tensor(stream: stream, bytes: frame).floats()
        for slot in [0, 1, 2, 79] {
            let expected = slot % 2 == 0 ? a : b
            for i in [0, 3, 511] {
                XCTAssertEqual(values[slot * 512 + i], expected[i], accuracy: (stream.qpScale ?? 1) / 2 + 1e-6, "slot \(slot) value \(i)")
            }
        }
        XCTAssertThrowsError(try OpenVocabulary.textFrame([], model: world))
        XCTAssertThrowsError(try OpenVocabulary.textFrame([[0.1, 0.2]], model: world))
    }

    /// One cell of the stride-8 grid sure of the second prompt: its box from the distance bins (expectation of a
    /// softmax over 16 bins, times the stride, from the cell centre); padded slots and the other grids are ignored.
    func testDetections() throws {
        let world = try model("yolo_world_v2s")
        var tensors: [Tensor] = []
        let row = 10, column = 20, sides = [2, 3, 4, 5]
        for stream in world.outputs {
            let cells = (stream.height ?? 0) * (stream.width ?? 0), features = stream.features ?? 0
            var values = [Float](repeating: 0, count: cells * features)
            let cell = row * (stream.width ?? 0) + column
            if stream.height == 80 {
                if features == 64 {
                    for (side, bin) in sides.enumerated() { values[cell * 64 + side * 16 + bin] = 30 }
                } else {
                    values[cell * 80 + 1] = 0.9
                    values[cell * 80 + 3] = 0.95   // a slot past the prompts (a repeat): not read
                }
            }
            tensors.append(CoreMLEngine.tensor(values, like: stream))
        }
        let frame = PreparedFrame(rgb: [], width: 640, height: 640, sourceWidth: 640, sourceHeight: 640,
                                  contentRect: CGRect(x: 0, y: 0, width: 640, height: 640), sourceRegion: CGRect(x: 0, y: 0, width: 1, height: 1))
        let found = OpenVocabulary.detections(tensors, frame: frame, labels: ["dog", "bicycle"])
        XCTAssertEqual(found.count, 1)
        let item = try XCTUnwrap(found.first)
        XCTAssertEqual(item.label, "bicycle")
        XCTAssertEqual(item.classIndex, 1)
        XCTAssertEqual(item.confidence, 0.9, accuracy: 0.001)
        // Centre (20.5, 10.5) x 8 = (164, 84); left 16, top 24, right 32, bottom 40.
        let box = item.boundingBox
        XCTAssertEqual(Double(box.minX) * 640, 148, accuracy: 0.1)
        XCTAssertEqual(Double(box.minY) * 640, 60, accuracy: 0.1)
        XCTAssertEqual(Double(box.maxX) * 640, 196, accuracy: 0.1)
        XCTAssertEqual(Double(box.maxY) * 640, 124, accuracy: 0.1)
        // Without prompt names (replays) every slot counts.
        XCTAssertEqual(OpenVocabulary.detections(tensors, frame: frame, labels: []).map(\.label).sorted(), ["prompt 2", "prompt 4"])
    }

    func testObjectKinds() {
        XCTAssertEqual(ObjectCLIP.Objects.people.labels, ["person"])
        XCTAssertTrue(ObjectCLIP.Objects.vehicles.labels?.isSuperset(of: ["car", "bus", "truck", "bicycle", "motorcycle"]) ?? false)
        XCTAssertNil(ObjectCLIP.Objects.everything.labels)
        // Every label named exists in the detectors' COCO set.
        for kind in ObjectCLIP.Objects.allCases { XCTAssertTrue((kind.labels ?? []).isSubset(of: Set(Labels.coco)), kind.rawValue) }
    }

    /// The result list of a CLIP pair: background prompts marked, each keeping its prompt's index.
    func testPromptClassifications() {
        let scores = CLIP.scores(image: [1, 0], prompts: [("hat", [0, 1], false), ("no hat", [1, 0], true)], scale: 100)
        let sorted = CLIP.classifications(scores.sorted { $0.probability > $1.probability }, prompts: ["hat", "no hat"])
        XCTAssertEqual(sorted.map(\.label), ["not: no hat", "hat"])
        XCTAssertEqual(sorted.map(\.classIndex), [1, 0])
    }
}
