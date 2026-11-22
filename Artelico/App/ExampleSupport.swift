import CoreGraphics
import SwiftUI
import StudioCore
import WhisperKit

/// Artelico's side of the examples (see Examples/ExampleHost.swift): Core ML for the vision models,
/// llama.cpp for the language models and WhisperKit for speech, all on this device.
extension StudioModel {
    nonisolated static let examplesRunOn = "on this \(deviceKind)"

    var exampleEngine: any InferenceEngine { device }

    /// Core ML packages are copied in by hand: only the ones here can be used.
    func canUse(_ name: String) -> Bool { installed.contains(name) }

    func modelLabel(_ name: String) -> String { installed.contains(name) ? name : "\(name) (downloads when used)" }

    /// Loads `model` next to the main one (already loaded ones are kept).
    func loadExtra(_ model: StudioCore.ModelInfo) async throws {
        if await device.loadedModelNames.contains(model.name) { return }
        // Downloaded first when it is not here yet (models an example needs next to the main one).
        if !installed.contains(model.name) { try await download(model) }
        try await device.load(model, from: Self.fileURL(for: model), computeUnits: computeUnits.units, primary: false)
    }

    /// Loads only `model` (as the main one), unloading the others.
    func loadAlone(_ model: StudioCore.ModelInfo) async throws {
        await device.unloadAll()
        loadedModel = nil
        try await device.load(model, from: Self.fileURL(for: model), computeUnits: computeUnits.units, primary: true)
        loadedModel = model.name
    }

    func exampleLanguageModels(_ use: LanguageUse) -> [ExampleLanguageModel] {
        let purpose: GGUFModel.Purpose = use == .pictures ? .vision : .chat
        var models = languageModels.filter { $0.purpose == purpose }
        if use == .code { models.sort { $0.title.contains("Coder") && !$1.title.contains("Coder") } }
        let ready = models.filter { isDownloaded($0) }, missing = models.filter { !isDownloaded($0) }
        return (ready + missing).map { model in
            ExampleLanguageModel(id: model.id, title: model.title,
                                 label: isDownloaded(model) ? model.title : "\(model.title) (\(model.megabytes + (model.visionMegabytes ?? 0)) MB to download)")
        }
    }

    static func defaultLanguageModel(_ use: LanguageUse) -> String {
        switch use {
        case .pictures: return GGUFModel.catalog.first { $0.purpose == .vision }!.id
        case .chat: return GGUFModel.catalog.first { $0.purpose == .chat }!.id
        case .code: return "qwen2.5-coder-1.5b-instruct-q4_k_m.gguf"
        }
    }

    /// Streams an answer (about `picture` when given). Qwen3 is asked not to think, and any thinking it
    /// does is removed from what `onText` gets. Cancelling the calling task stops llama.cpp too.
    func exampleStream(modelID: String, system: String?, user: String, picture: CGImage? = nil, maxTokens: Int = 400,
                       temperature: Float = 0.3, onText: @escaping @MainActor (String) -> Void) async throws -> AnswerStats {
        guard let model = languageModels.first(where: { $0.id == modelID }) else { throw StudioError.invalidInput("Choose a model.") }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let llm = try await languageModel(model, forPictures: picture != nil)
        var messages: [LlamaEngine.Message] = []
        if let system { messages.append(.init(role: "system", content: system)) }
        let noThink = model.title.hasPrefix("Qwen3") ? " /no_think" : ""
        messages.append(.init(role: "user", content: (picture != nil ? LlamaEngine.pictureMarker + "\n" : "") + user + noThink))
        let rgb = picture.flatMap { AskImageView.rgb($0, longestSide: 1024) }
        if picture != nil, rgb == nil { throw StudioError.invalidInput("This picture cannot be read.") }
        var parameters = LlamaEngine.Parameters()
        parameters.maxTokens = maxTokens
        parameters.temperature = temperature
        let (pieces, sink) = AsyncStream<String>.makeStream()
        let work = Task.detached {
            defer { sink.finish() }
            return try await llm.generate(messages, picture: rgb, parameters: parameters) { sink.yield($0) }
        }
        // llama.cpp does not see Swift cancellation: stop it by hand.
        let stats = try await withTaskCancellationHandler {
            var text = ""
            for await piece in pieces {
                text += piece
                onText(ModelText.withoutThinking(text))
            }
            let stats = try await work.value
            try Task.checkCancellation()
            return stats
        } onCancel: {
            Task { await llm.cancel() }
        }
        return AnswerStats(model: model.title, tokens: stats.generatedTokens, tokensPerSecond: stats.tokensPerSecond)
    }

    /// Speech (mono 16 kHz) to text with the Whisper model chosen on the Speech page.
    func exampleTranscribe(_ samples: [Float]) async throws -> String {
        let variant = UserDefaults.standard.string(forKey: "speech.model") ?? SpeechView.defaultModel
        let kit = try await whisperKit(variant)
        let results = try await kit.transcribe(audioArray: samples)
        return results.flatMap(\.segments).map {
            $0.text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
