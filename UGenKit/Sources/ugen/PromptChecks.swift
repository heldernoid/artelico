import CoreGraphics
import Foundation
import UGenKit

// The two prompt tasks on the stick or with Core ML (text tables and packages from native/coreml):
//
//   ugen find [--coreml | --stick-text] <prompt,prompt,...> <image> [out.png | result.json]
//        YOLO-World: boxes for the prompts (bare names, embedded by clip_vit_b_32_text_encoder with Core ML)
//   ugen describe [--coreml] [--objects people|vehicles|animals|faces|everything] [--detector <model>]
//                 <image encoder> <prompt,prompt,...> <image> [out.png | result.json]
//        each object the detector finds, matched against the prompts with the image encoder's CLIP pair

private var coreMLFolder: URL { root.appendingPathComponent("native/coreml") }

private func prompts(_ text: String) -> [String] {
    text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// Loads `models` (the first one primary) on Core ML or the stick.
private func engine(coreML: Bool, models: [ModelInfo], stick: UGenDevice) async throws -> any InferenceEngine {
    if coreML {
        let native = CoreMLEngine()
        for (index, model) in models.enumerated() {
            try await native.load(model, from: coreMLFolder.appendingPathComponent("\(model.name).mlpackage"), computeUnits: .all, primary: index == 0)
        }
        return native
    }
    try await connectRuntime(stick)
    _ = try await loadModel(models[0].name, on: stick)
    for model in models.dropFirst() {
        try await stick.addModel(hef: root.appendingPathComponent("models/\(model.name).hef"), info: model)
    }
    return stick
}

/// Writes the result as a picture or (with `extra` fields) as JSON.
private func save(_ result: VisionResult, over image: CGImage, to path: String, extra: [String: Any] = [:]) throws {
    if path.hasSuffix(".json") {
        var object = result.jsonObject
        object.merge(extra) { a, _ in a }
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
    } else if let rendered = VisionRenderer.render(result, over: image) {
        savePNG(rendered, to: path)
    }
    print("wrote \(path)")
}

func findCheck(_ arguments: [String], stick: UGenDevice) async throws {
    var args = arguments
    let coreML = args.first == "--coreml"
    if coreML { args.removeFirst() }
    // As Hailo Studio, the prompts are embedded with Core ML (the stick's 8-bit text encoder is too coarse for
    // YOLO-World); --stick-text uses the stick's, for comparison.
    let stickText = args.first == "--stick-text"
    if stickText { args.removeFirst() }
    guard args.count >= 2, let model = ModelCatalog.model(named: "yolo_world_v2s"),
          let text = ModelCatalog.model(named: OpenVocabulary.textEncoderName), let pair = CLIPModels.pair(forText: text.name) else {
        fail("usage: ugen find [--coreml | --stick-text] <prompt,prompt,...> <image> [out.png | result.json]")
    }
    let device = try await engine(coreML: coreML, models: stickText ? [model, text] : [model], stick: stick)
    let textDevice = stickText ? device : try await engine(coreML: true, models: [text], stick: stick)
    var tagger = CLIPTagger(encoder: try CLIPTextEncoder(pair: pair, folder: coreMLFolder))
    let clock = ContinuousClock()
    var start = clock.now
    try await tagger.setPrompts(prompts(args[0]), device: textDevice, prefix: "")
    print(String(format: "%d prompts in %.0f ms (%@)", tagger.prompts.count, milliseconds(clock.now - start), stickText ? "stick" : "Core ML"))
    let image = loadImage(args[1])
    // Twice: the first run includes warming up.
    _ = try await VisionPipeline.run(.findAnything, on: image, device: device, prompts: tagger)
    start = clock.now
    let (result, _) = try await VisionPipeline.run(.findAnything, on: image, device: device, prompts: tagger)
    print(String(format: "%@ (%.0f ms): %@", URL(fileURLWithPath: args[1]).lastPathComponent, milliseconds(clock.now - start), result.summary))
    if args.count > 2 { try save(result, over: image, to: args[2], extra: ["textEmb": tagger.prompts.map(\.embedding)]) }
}

func describeCheck(_ arguments: [String], stick: UGenDevice) async throws {
    var args = arguments
    var coreML = false, textCoreML = false
    var settings = ObjectCLIP.Settings()
    while let flag = args.first, flag.hasPrefix("--") {
        args.removeFirst()
        switch flag {
        case "--coreml": coreML = true
        case "--text-coreml": textCoreML = true   // prompts with Core ML, pictures on the stick (finding which side differs)
        case "--objects": settings.objects = ObjectCLIP.Objects(rawValue: args.removeFirst()) ?? .people
        case "--detector":
            let name = args.removeFirst()
            if settings.objects == .faces { settings.faceDetector = name } else { settings.detector = name }
        default: fail("unknown option \(flag)")
        }
    }
    guard args.count >= 3, let pair = CLIPModels.pair(forImage: args[0]), let encoder = ModelCatalog.model(named: pair.image),
          let text = ModelCatalog.model(named: pair.text), let detector = ModelCatalog.model(named: settings.detectorName) else {
        fail("usage: ugen describe [--coreml] [--objects \(ObjectCLIP.Objects.allCases.map(\.rawValue).joined(separator: "|"))] [--detector <model>] <image encoder> <prompt,prompt,...> <image> [out.png | result.json]")
    }
    // As Hailo Studio: a text encoder that does not fit next to its image encoder reads the prompts alone first.
    let together = coreML || pair.stickLoadsBoth
    var device = try await engine(coreML: coreML, models: together ? [encoder, text, detector] : [text], stick: stick)
    var tagger = CLIPTagger(encoder: try CLIPTextEncoder(pair: pair, folder: coreMLFolder))
    try await tagger.setPrompts(prompts(args[1]), device: textCoreML ? try await engine(coreML: true, models: [text], stick: stick) : device)
    if !together { device = try await engine(coreML: false, models: [encoder, detector], stick: stick) }
    let image = loadImage(args[2])
    _ = try await ObjectCLIP.run(image, prompts: tagger, settings: settings, device: device)   // warming up
    let clock = ContinuousClock()
    let start = clock.now
    let found = try await ObjectCLIP.run(image, prompts: tagger, settings: settings, device: device)
    print(String(format: "%@ + %@, %@ (%.0f ms, %@):", pair.image, settings.detectorName, settings.objects.rawValue,
                 milliseconds(clock.now - start), coreML ? "Core ML" : "stick"))
    for item in found {
        let box = item.boundingBox
        print(String(format: "  %@ %.2f [%.3f %.3f %.3f %.3f]: ", item.label ?? "?", item.confidence, box.minX, box.minY, box.maxX, box.maxY)
              + item.attributes.prefix(3).map { String(format: "%@ %.3f", $0.label, $0.probability) }.joined(separator: ", "))
    }
    if args.count > 3 { try save(.described(found), over: image, to: args[3]) }
}

/// native-map's second input for YOLO-World: these prompts embedded by Core ML's text encoder (the same frame
/// goes to the stick and to Core ML).
func openVocabularyFrame(_ text: String, model: ModelInfo) async throws -> [UInt8] {
    guard let encoder = ModelCatalog.model(named: OpenVocabulary.textEncoderName), let pair = CLIPModels.pair(forText: encoder.name) else {
        fail("\(OpenVocabulary.textEncoderName) is missing")
    }
    let native = CoreMLEngine()
    try await native.load(encoder, from: coreMLFolder.appendingPathComponent("\(encoder.name).mlpackage"), computeUnits: .all)
    var tagger = CLIPTagger(encoder: try CLIPTextEncoder(pair: pair, folder: coreMLFolder))
    try await tagger.setPrompts(prompts(text), device: native, prefix: "")
    return try OpenVocabulary.textFrame(tagger.prompts.map(\.embedding), model: model)
}
