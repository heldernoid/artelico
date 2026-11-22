import CoreML
import Foundation
import StudioCore

/// Picks the assistant tool for a request with all-MiniLM-L6-v2 sentence embeddings (Core ML), as in
/// hailo-apps' v2a_demo/tool_selector.py: each tool's description sentences are embedded once; a request
/// goes to the tool with the most similar sentence (cosine), if that tool's threshold is met, else "none".
actor ToolSelector {
    static let modelName = "all_minilm_l6_v2"
    static let length = 64

    private let model: MLModel
    private let tokenizer: WordPieceTokenizer
    private var toolVectors: [(tool: String, vector: [Float])] = []

    /// `folder` holds all_minilm_l6_v2.mlpackage and all_minilm_l6_v2.vocab.txt.
    init(folder: URL) async throws {
        let package = folder.appendingPathComponent("\(Self.modelName).mlpackage")
        let vocabulary = folder.appendingPathComponent("\(Self.modelName).vocab.txt")
        guard FileManager.default.fileExists(atPath: package.path), FileManager.default.fileExists(atPath: vocabulary.path) else {
            throw StudioError.invalidInput("The assistant needs \(Self.modelName).mlpackage and its vocab.txt in the models folder.")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        model = try await MLModel.load(contentsOf: try await CoreMLEngine.compiledModel(at: package), configuration: configuration)
        tokenizer = try WordPieceTokenizer(vocabularyFile: vocabulary)
    }

    func prepare(_ tools: [AssistantTool]) throws {
        toolVectors = []
        for tool in tools {
            for sentence in tool.descriptions { toolVectors.append((tool.name, try embed(sentence))) }
        }
    }

    func embed(_ text: String) throws -> [Float] {
        let (ids, mask) = tokenizer.encode(text, length: Self.length)
        let idArray = try MLMultiArray(shape: [1, NSNumber(value: Self.length)], dataType: .int32)
        let maskArray = try MLMultiArray(shape: [1, NSNumber(value: Self.length)], dataType: .int32)
        for i in 0..<Self.length {
            idArray[i] = NSNumber(value: ids[i])
            maskArray[i] = NSNumber(value: mask[i])
        }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input_ids": idArray, "attention_mask": maskArray]))
        guard let embedding = output.featureValue(for: "embedding")?.multiArrayValue else { return [] }
        return CoreMLEngine.contiguous(embedding)
    }

    /// The chosen tool, its best similarity, and the best similarity of every tool (for display).
    func select(_ request: String, tools: [AssistantTool]) throws -> (tool: String, score: Float, scores: [(String, Float)]) {
        // Explicit wording first ("search the web for ...", "remember ...", "Ana's phone").
        for tool in tools {
            if let trigger = tool.trigger, request.range(of: trigger, options: [.regularExpression, .caseInsensitive]) != nil {
                return (tool.name, 1, [(tool.name, 1)])
            }
        }
        let query = try embed(request)
        var best: [String: Float] = [:]
        for (tool, vector) in toolVectors {
            var dot: Float = 0
            for i in 0..<min(query.count, vector.count) { dot += query[i] * vector[i] }
            best[tool] = max(best[tool] ?? -1, dot)
        }
        let ranked = best.sorted { $0.value > $1.value }
        guard let top = ranked.first else { return ("none", 0, []) }
        let threshold = tools.first { $0.name == top.key }?.threshold ?? 1
        return (top.value >= threshold ? top.key : "none", top.value, ranked.map { ($0.key, $0.value) })
    }
}
