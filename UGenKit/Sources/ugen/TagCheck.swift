import CoreGraphics
import Foundation
import UGenKit

/// `ugen tag [--coreml] [--json out.json] <image encoder> <label,label,...> <image> [image ...]`: tagging from
/// text with an image encoder and its text encoder (CLIPModels.pairs), on the stick or with Core ML. Prompts
/// are "A photo of a <label>" as in the apps. Prints every prompt's cosine similarity and probability per
/// picture; `--json` also writes the token ids and embeddings, for comparing with the Python reference.
/// The text files come from native/coreml (native/tools/clip_assets.py).
func tagCheck(_ arguments: [String], stick: UGenDevice) async throws {
    var args = arguments
    let coreML = args.first == "--coreml"
    if coreML { args.removeFirst() }
    var jsonPath: String?
    if args.first == "--json", args.count > 1 { jsonPath = args[1]; args.removeFirst(2) }
    guard args.count >= 3, let pair = CLIPModels.pair(forImage: args[0]),
          let image = ModelCatalog.model(named: pair.image), let text = ModelCatalog.model(named: pair.text) else {
        fail("usage: ugen tag [--coreml] [--json out.json] <\(CLIPModels.pairs.map(\.image).joined(separator: "|"))> <label,label,...> <image> [image ...]")
    }
    let folder = root.appendingPathComponent("native/coreml")
    let engine: any InferenceEngine
    var oneAtATime = false
    if coreML {
        let native = CoreMLEngine()
        try await native.load(image, from: folder.appendingPathComponent("\(image.name).mlpackage"), computeUnits: .all)
        try await native.load(text, from: folder.appendingPathComponent("\(text.name).mlpackage"), computeUnits: .all, primary: false)
        engine = native
    } else {
        try await connectRuntime(stick)
        if pair.stickLoadsBoth {
            _ = try await loadModel(image.name, on: stick)
            try await stick.addModel(hef: root.appendingPathComponent("models/\(text.name).hef"), info: text)
        } else {
            print("the two encoders do not fit on the stick together: the text encoder first, then the image encoder")
            oneAtATime = true
            _ = try await loadModel(text.name, on: stick)
        }
        engine = stick
    }
    var tagger = CLIPTagger(encoder: try CLIPTextEncoder(pair: pair, folder: folder))
    let labels = args[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    let clock = ContinuousClock()
    var start = clock.now
    try await tagger.setPrompts(labels, device: engine)
    if oneAtATime { _ = try await loadModel(image.name, on: stick) }
    print(String(format: "%@ + %@ (%@): %d prompts in %.0f ms", pair.image, pair.text, coreML ? "Core ML" : "stick", labels.count,
                 milliseconds(clock.now - start)))
    var report: [String: Any] = [
        "image": pair.image, "text": pair.text, "labels": labels,
        "ids": labels.map { tagger.encoder.ids(for: CLIP.promptPrefix + $0) },
        "textEmb": tagger.prompts.map(\.embedding),
    ]
    var imageEmbeddings: [[Float]] = [], cosines: [[Float]] = []
    for path in args.dropFirst(2) {
        start = clock.now
        let embedding = try await tagger.imageEmbedding(loadImage(path), device: engine)
        let ms = milliseconds(clock.now - start)
        let scores = CLIP.scores(image: embedding, prompts: tagger.prompts, scale: pair.logitScale)
        imageEmbeddings.append(embedding)
        cosines.append(scores.map(\.similarity))
        let ranked = scores.sorted { $0.probability > $1.probability }.prefix(4)
        print(String(format: "  %@ (%.0f ms): ", URL(fileURLWithPath: path).lastPathComponent, ms)
              + ranked.map { String(format: "%@ %.3f (cos %.3f)", $0.text, $0.probability, $0.similarity) }.joined(separator: ", "))
    }
    report["imageEmb"] = imageEmbeddings
    report["cos"] = cosines
    if let jsonPath {
        try JSONSerialization.data(withJSONObject: report).write(to: URL(fileURLWithPath: jsonPath))
    }
}
