import CoreGraphics
import ImageIO
import XCTest
@testable import StudioCore
@testable import UGenKit

/// Tagging from text (CLIP, TinyCLIP, SigLIP, SigLIP 2). The tokenizers for CLIP and SigLIP are bundled; the
/// token tables live in native/coreml (native/tools/clip_assets.py) and tests that need them are skipped when
/// they are missing.
///
/// `testEndToEndOnDevice` drives the real stick and only runs with `UGEN_DEVICE_TESTS=1` in the
/// environment, so that a plain `swift test` never takes the device.
final class CLIPTests: XCTestCase {
    /// The project folder (UGenKit/Tests/UGenKitTests/ is three levels down).
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let tables = root.appendingPathComponent("native/coreml")

    private func file(_ path: String) throws -> URL {
        let url = Self.root.appendingPathComponent(path)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "\(path) is missing")
        return url
    }

    private func clipTokenizer() throws -> CLIPTokenizer {
        try CLIPTokenizer(contentsOf: CLIPModels.bundledTokenizer("clip_tokenizer"))
    }

    // MARK: Tokenizers

    /// Expected ids come from the HuggingFace `tokenizers` library (what the reference app uses).
    func testTokenizerMatchesReference() throws {
        let tokenizer = try clipTokenizer()
        let cases: [(String, [Int])] = [
            ("a photo of a cat", [49406, 320, 1125, 539, 320, 2368, 49407]),
            ("a diagram", [49406, 320, 22697, 49407]),
            ("A photo of a Raspberry Pi", [49406, 320, 1125, 539, 320, 13615, 5357, 49407]),
            ("A photo of a bus", [49406, 320, 1125, 539, 320, 2840, 49407]),
            ("unicorn mouse pad", [49406, 15660, 9301, 7601, 49407]),
            ("Hello, World!", [49406, 3306, 267, 1002, 256, 49407]),
            ("  it's   a\tdog's toy... ", [49406, 585, 568, 320, 1929, 568, 5988, 678, 49407]),
            ("don't stop!!! (ever)", [49406, 847, 713, 1691, 995, 263, 1247, 264, 49407]),
            ("3D-printed robot 2024", [49406, 274, 323, 268, 7978, 8797, 273, 271, 273, 275, 49407]),
            ("café №5 naïve", [49406, 15304, 8604, 500, 276, 1097, 35689, 563, 49407]),
            ("emoji 🙂 test", [49406, 16327, 14860, 1628, 49407]),
            ("<|endoftext|> x", [49406, 49407, 343, 49407]),
            ("", [49406, 49407]),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(tokenizer.encode(text), expected, "\"\(text)\"")
        }
    }

    func testTokenizerCutsLongPromptsTo77() throws {
        let tokenizer = try clipTokenizer()
        let ids = tokenizer.encode(Array(repeating: "supercalifragilistic", count: 40).joined(separator: " "))
        // The reference keeps the first 77 ids, which drops the end token.
        var expected = [49406]
        for _ in 0..<15 { expected += [1642, 2857, 13093, 2076, 1561] }
        expected.append(1642)
        XCTAssertEqual(ids, expected)
    }

    /// 424 phrases (the apps' prompts, punctuation, digits, accents, emoji, random dictionary words), ids from
    /// Hugging Face's tokenizers (testdata/configs/clip_reference_tokens.json says which).
    func testAllTokenizersMatchHuggingFace() throws {
        struct Reference: Decodable { let tests: [String]; let clip: [[Int]]; let siglip: [[Int]]; let siglip2: [[Int]] }
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: file("testdata/configs/clip_reference_tokens.json")))
        let clip = try clipTokenizer()
        let siglip = try SentencePieceTokenizer(contentsOf: CLIPModels.bundledTokenizer("siglip_tokenizer"))
        var mismatches = 0
        for (text, expected) in zip(reference.tests, reference.clip) where clip.encode(text) != expected {
            mismatches += 1; XCTFail("CLIP \"\(text)\": \(clip.encode(text)) != \(expected)")
        }
        for (text, expected) in zip(reference.tests, reference.siglip) where siglip.encode(text, length: 64) != expected {
            mismatches += 1; XCTFail("SigLIP \"\(text)\": \(siglip.encode(text, length: 64)) != \(expected)")
        }
        let gemmaFile = Self.tables.appendingPathComponent("siglip2_b_32_256_text_encoder.tokenizer.json")
        guard FileManager.default.fileExists(atPath: gemmaFile.path) else { throw XCTSkip("siglip2 tokenizer.json is missing") }
        let gemma = try SentencePieceTokenizer(contentsOf: gemmaFile)
        for (text, expected) in zip(reference.tests, reference.siglip2) where gemma.encode(text, length: 64) != expected {
            mismatches += 1; XCTFail("SigLIP 2 \"\(text)\": \(gemma.encode(text, length: 64)) != \(expected)")
        }
        XCTAssertEqual(mismatches, 0)
    }

    // MARK: Data files and text input

    func testFloat16NPY() throws {
        // np.save of np.array([[1, -2.5], [0.099975586, 65504]], np.float16)
        var data = Data([0x93] + Array("NUMPY".utf8) + [1, 0])
        var header = "{'descr': '<f2', 'fortran_order': False, 'shape': (2, 2), }"
        header += String(repeating: " ", count: 128 - 10 - header.count - 1) + "\n"   // data starts at byte 128
        data.append(UInt8(header.count & 0xFF)); data.append(UInt8(header.count >> 8))
        data.append(contentsOf: Array(header.utf8))
        for value: Float16 in [1, -2.5, 0.099975586, 65504] { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("half-\(UUID().uuidString).npy")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let array = try NPYFloatArray(contentsOf: url)
        XCTAssertEqual(array.shape, [2, 2])
        XCTAssertEqual(array.row(0), [1, -2.5])
        XCTAssertEqual(array.row(1), [0.099975586, 65504])
    }

    func testNPYRejectsOtherFiles() throws {
        XCTAssertThrowsError(try NPYFloatArray(contentsOf: CLIPModels.bundledTokenizer("clip_tokenizer")))
    }

    /// Hailo's float32 table for clip_vit_b_32; expected raw values were computed with NumPy:
    /// clip(rint(row / scale + zero point)) as uint16.
    func testTextInputMatchesReference() throws {
        let table = try NPYFloatArray(contentsOf: file("testdata/configs/token_embedding_lut.npy"))
        let model = try XCTUnwrap(ModelCatalog.model(named: "clip_vit_b_32_text_encoder"))
        let ids = try clipTokenizer().encode("a photo of a cat")
        XCTAssertEqual(ids.firstIndex(of: CLIPTokenizer.endToken), 6)
        let frame = try CLIP.textFrame(ids: ids, tokenEmbeddings: table, model: model)
        XCTAssertEqual(frame.count, 77 * 512 * 2)

        func row(_ position: Int) -> [Int] {
            (0..<512).map { Int(frame[(position * 512 + $0) * 2]) | Int(frame[(position * 512 + $0) * 2 + 1]) << 8 }
        }
        // (position, first four values, last two values, sum of the row)
        let expected: [(Int, [Int], [Int], Int)] = [
            (0, [4139, 4213, 4031, 4337], [4043, 4208], 2161637),   // start token 49406
            (1, [3907, 3831, 3908, 4383], [4583, 3794], 2151004),   // "a" = 320
            (4, [3907, 3831, 3908, 4383], [4583, 3794], 2151004),
            (6, [3954, 4296, 4231, 4665], [3790, 4200], 2156119),   // end token 49407
            (7, [4044, 3941, 4523, 5784], [3241, 3746], 2150213),   // padding: token 0
            (76, [4044, 3941, 4523, 5784], [3241, 3746], 2150213),
        ]
        for (position, head, tail, sum) in expected {
            let values = row(position)
            XCTAssertEqual(Array(values.prefix(4)), head, "position \(position)")
            XCTAssertEqual(Array(values.suffix(2)), tail, "position \(position)")
            XCTAssertEqual(values.reduce(0, +), sum, "position \(position)")
        }
    }

    /// Every pair's models are in the table, the image encoder runs the tagging task with the text encoder as
    /// its companion, and (when the tables are there) each table fits its encoder's input.
    func testPairsFitTheModelTable() throws {
        XCTAssertEqual(Set(CLIPModels.pairs.map(\.image)).count, CLIPModels.pairs.count)
        for pair in CLIPModels.pairs {
            let image = try XCTUnwrap(ModelCatalog.model(named: pair.image), pair.image)
            let text = try XCTUnwrap(ModelCatalog.model(named: pair.text), pair.text)
            XCTAssertTrue(VisionPipeline.supports(.tagging, model: image), pair.image)
            XCTAssertFalse(VisionPipeline.supports(.tagging, model: text), pair.text)
            XCTAssertEqual(VisionTask.tagging.companionModels(for: image), [pair.text])
            XCTAssertEqual(text.inputs.first?.width, pair.family == .clip ? 77 : 64, pair.text)
            guard CLIPModels.missingFiles(for: pair, in: Self.tables).isEmpty else { continue }
            let encoder = try CLIPTextEncoder(pair: pair, folder: Self.tables)
            XCTAssertEqual(encoder.tokenEmbeddings.rowLength, text.inputs.first?.features, pair.text)
            if let projection = encoder.projection {
                XCTAssertEqual(projection.shape[0], text.outputs.first?.features, pair.text)
                XCTAssertEqual(projection.shape[1], image.outputs.first?.features, pair.text)
            } else {
                XCTAssertEqual(text.outputs.first?.features, image.outputs.first?.features, pair.text)
            }
        }
    }

    // MARK: Embeddings and scores

    func testFinalNormThenProjection() throws {
        // PyTorch: F.layer_norm(x, (4,), w, b) @ P for x = [1, 2, 3, 4], w = [1, 1, 2, 2], b = [0, 0, 0, 1].
        let normed = CLIP.layerNorm([1, 2, 3, 4], weight: [1, 1, 2, 2], bias: [0, 0, 0, 1])
        for (value, expected) in zip(normed, [-1.3416355, -0.4472118, 0.8944236, 3.6832707] as [Float]) {
            XCTAssertEqual(value, expected, accuracy: 1e-5)
        }
    }

    func testImageEmbeddingIsDequantizedAndNormalized() {
        let stream = StreamInfo(name: "out", type: "UINT8", order: "NHWC", frameSize: 4, height: 1, width: 1, features: 4,
                                qpZp: 10, qpScale: 0.5, classes: nil, maxBoxes: nil)
        // Real values (16-10)/2 = 3, (2-10)/2 = -4, 0, 0: length 5.
        let embedding = CLIP.imageEmbedding(from: Tensor(stream: stream, bytes: [16, 2, 10, 10]))
        XCTAssertEqual(embedding[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(embedding[1], -0.8, accuracy: 1e-6)
        XCTAssertEqual(embedding[2], 0, accuracy: 1e-6)
    }

    func testScoresAreSoftmaxOfScaledSimilarity() {
        let image: [Float] = [1, 0, 0]
        let scores = CLIP.scores(image: image, prompts: [
            (text: "first", embedding: [0.30, 0.1, 0], negative: false),
            (text: "second", embedding: [0.28, 0.9, 0], negative: false),
            (text: "background", embedding: [0.25, 0, 0.5], negative: true),
        ])
        let weights = [exp(30.0), exp(28.0), exp(25.0)]
        let total = weights.reduce(0, +)
        XCTAssertEqual(scores.map(\.text), ["first", "second", "background"])
        for (score, weight) in zip(scores, weights) {
            XCTAssertEqual(Double(score.probability), weight / total, accuracy: 1e-6)
        }
        XCTAssertEqual(scores[0].similarity, 0.30, accuracy: 1e-6)
        XCTAssertEqual(scores.reduce(0) { $0 + $1.probability }, 1, accuracy: 1e-5)
        XCTAssertEqual(CLIP.bestMatch(scores)?.text, "first")           // 0.876 > 0.8
        XCTAssertNil(CLIP.bestMatch(scores, threshold: 0.9))
        XCTAssertTrue(CLIP.scores(image: image, prompts: []).isEmpty)
        // TinyCLIP's scale of 50 halves the gaps.
        let tiny = CLIP.scores(image: image, prompts: [(text: "a", embedding: [0.30, 0, 0], negative: false), (text: "b", embedding: [0.28, 0, 0], negative: false)], scale: 50)
        XCTAssertEqual(Double(tiny[0].probability), 1 / (1 + exp(-1.0)), accuracy: 1e-6)

        // A background prompt that wins is never reported.
        let background = CLIP.scores(image: image, prompts: [
            (text: "thing", embedding: [0.2, 0, 0], negative: false),
            (text: "desk", embedding: [0.3, 0, 0], negative: true),
        ])
        XCTAssertNil(CLIP.bestMatch(background, threshold: 0))
    }

    func testParsePrompt() {
        XCTAssertEqual(CLIP.parsePrompt("keyboard")?.text, "keyboard")
        XCTAssertEqual(CLIP.parsePrompt("keyboard")?.negative, false)
        XCTAssertEqual(CLIP.parsePrompt("- wooden desk ")?.text, "wooden desk")
        XCTAssertEqual(CLIP.parsePrompt("-wooden desk")?.negative, true)
        XCTAssertNil(CLIP.parsePrompt("-"))
        XCTAssertNil(CLIP.parsePrompt(""))
    }

    // MARK: Real device

    private func loadImage(_ path: String) throws -> CGImage {
        let url = try file(path)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "cannot open \(path)")
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), "cannot decode \(path)")
    }

    /// Every pair whose tables are in native/coreml tags the sample pictures right on the stick.
    func testEndToEndOnDevice() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UGEN_DEVICE_TESTS"] == "1",
                          "Set UGEN_DEVICE_TESTS=1 to run on the real stick.")
        let labels = ["bus", "dog", "bicycle", "apple", "living room", "cat"]
        // Image and the labels that count as right for it.
        let images: [(path: String, accepted: Set<String>)] = [
            ("Artelico/Samples/bus.jpg", ["bus"]),
            ("Artelico/Samples/dog_bicycle.jpg", ["dog", "bicycle"]),
            ("Artelico/Samples/apple.jpg", ["apple"]),
        ]
        let pictures = try images.map { try loadImage($0.path) }
        let device = UGenDevice()
        defer { Task { await device.disconnect() } }
        if try await device.connect() == .loader {
            try await device.bootRuntime(image: Self.root.appendingPathComponent("images/core-image-hailo-hailo10-usb-dongle.ext4"))
        }
        for pair in CLIPModels.pairs where CLIPModels.missingFiles(for: pair, in: Self.tables).isEmpty {
            let image = try XCTUnwrap(ModelCatalog.model(named: pair.image)), text = try XCTUnwrap(ModelCatalog.model(named: pair.text))
            func hef(_ model: ModelInfo) -> URL { Self.root.appendingPathComponent("models/\(model.name).hef") }
            var tagger = CLIPTagger(encoder: try CLIPTextEncoder(pair: pair, folder: Self.tables))
            if pair.stickLoadsBoth {
                try await device.loadModel(hef: hef(image), info: image)
                try await device.addModel(hef: hef(text), info: text)
                try await tagger.setPrompts(labels, device: device)
            } else {
                try await device.loadModel(hef: hef(text), info: text)
                try await tagger.setPrompts(labels, device: device)
                try await device.loadModel(hef: hef(image), info: image)
            }
            for (expected, picture) in zip(images, pictures) {
                let scores = try await tagger.tag(picture, device: device)
                let best = try XCTUnwrap(scores.first)
                print("\(pair.image) \(expected.path): \(best.text) \(best.probability)")
                XCTAssertTrue(expected.accepted.contains(best.text), "\(pair.image) \(expected.path): best prompt was \"\(best.text)\"")
            }
        }
    }
}
