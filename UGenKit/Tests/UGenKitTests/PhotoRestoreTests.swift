import XCTest
@testable import StudioCore

/// PhotoRestore: the demo's tile plan and brightness cap (PhotoRestore/test_restore_engine.py ideas), and
/// the tiled runner with a fake model.
final class PhotoRestoreTests: XCTestCase {
    func testTileStarts() {
        XCTAssertEqual(PhotoRestore.tileStarts(300, tile: 400), [0])
        XCTAssertEqual(PhotoRestore.tileStarts(400, tile: 400), [0])
        let s = PhotoRestore.tileStarts(1000, tile: 400, overlap: 16)
        XCTAssertEqual(s.first, 0); XCTAssertEqual(s.last, 600)
        for (a, b) in zip(s, s.dropFirst()) { XCTAssertLessThanOrEqual(b - a, 384) }   // always overlapping
    }

    func testBrightenStrengthCap() {
        XCTAssertEqual(PhotoRestore.brightenStrength(meanBrightness: 20), 0.9, accuracy: 1e-9)
        XCTAssertEqual(PhotoRestore.brightenStrength(meanBrightness: 93.75), 0.45, accuracy: 1e-9)
        XCTAssertEqual(PhotoRestore.brightenStrength(meanBrightness: 200), 0.15, accuracy: 1e-9)
        XCTAssertEqual(PhotoRestore.brightenStrength(meanBrightness: 20, user: 0.3), 0.3, accuracy: 1e-9)
    }

    /// An "upscale x2" engine that returns each input pixel twice in each direction (floats 0...1).
    actor DoublingEngine: InferenceEngine {
        let tile: Int
        init(tile: Int) { self.tile = tile }
        var loadedModel: ModelInfo? { nil }
        var queueSize: Int { 1 }
        func infer(inputs: [[UInt8]], model: String?) async throws -> [Tensor] {
            let input = inputs[0]
            var out = [Float](repeating: 0, count: tile * 2 * tile * 2 * 3)
            for y in 0..<(tile * 2) { for x in 0..<(tile * 2) { for c in 0..<3 {
                out[(y * tile * 2 + x) * 3 + c] = Float(input[((y / 2) * tile + x / 2) * 3 + c]) / 255
            } } }
            let stream = ModelInfo.testPicture(name: "fake_x2", tile: tile, scale: 2).outputs[0]
            return [CoreMLEngine.tensor(out, like: stream)]
        }
        func submit(inputs: [[UInt8]], model: String?) async throws {}
        func collect() async throws -> [Tensor] { [] }
    }

    func testTiledRunMatchesTheModelEverywhere() async throws {
        // A 100 x 70 gradient through 40 x 40 tiles must come out as a clean 2x copy (no seams).
        let width = 100, height = 70
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height { for x in 0..<width { rgb[(y * width + x) * 3] = UInt8(x * 2); rgb[(y * width + x) * 3 + 1] = UInt8(y * 3); rgb[(y * width + x) * 3 + 2] = 77 } }
        let model = ModelInfo.testPicture(name: "fake_x2", tile: 40, scale: 2)
        let out = try await PhotoRestore.run(rgb, width: width, height: height, model: model, device: DoublingEngine(tile: 40))
        XCTAssertEqual(out.width, 200); XCTAssertEqual(out.height, 140)
        for (x, y) in [(0, 0), (57, 33), (99, 69), (31, 31), (32, 32)] {
            for dy in 0..<2 { for dx in 0..<2 {
                let d = ((y * 2 + dy) * 200 + x * 2 + dx) * 3
                XCTAssertEqual(out.rgb[d], UInt8(x * 2)); XCTAssertEqual(out.rgb[d + 1], UInt8(y * 3)); XCTAssertEqual(out.rgb[d + 2], 77)
            } }
        }
    }

    func testBlend() {
        let a: [UInt8] = [0, 0, 0], b: [UInt8] = [200, 100, 50]
        XCTAssertEqual(PhotoRestore.blend(original: a, width: 1, height: 1, processed: b, outWidth: 1, outHeight: 1, strength: 0.5), [100, 50, 25])
        XCTAssertEqual(PhotoRestore.blend(original: a, width: 1, height: 1, processed: b, outWidth: 1, outHeight: 1, strength: 1), b)
    }
}

extension ModelInfo {
    /// A picture-to-picture model description (float output) for tests.
    static func testPicture(name: String, tile: Int, scale: Int) -> ModelInfo {
        let json = """
        {"name": "\(name)", "tasks": ["super_resolution"], "url": "", "defaultFor": [], "inputs": [{"name": "in", "type": "UINT8", "order": "NHWC",
         "height": \(tile), "width": \(tile), "features": 3, "elements": \(tile * tile * 3), "frameSize": \(tile * tile * 3)}],
         "outputs": [{"name": "out", "type": "FLOAT32", "order": "NHWC", "height": \(tile * scale), "width": \(tile * scale), "features": 3,
         "elements": \(tile * scale * tile * scale * 3), "frameSize": \(tile * scale * tile * scale * 12)}], "nms": null}
        """
        return try! JSONDecoder().decode(ModelInfo.self, from: Data(json.utf8))
    }
}
