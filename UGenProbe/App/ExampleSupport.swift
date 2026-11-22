import CoreGraphics
import SwiftUI
import UGenKit

/// Hailo Studio's side of the examples (see Artelico/App/Examples/ExampleHost.swift, compiled into both
/// apps): vision, language and speech models all run on the UGen300 stick. The stick holds either the
/// vision models or one language model at a time.
extension StudioModel {
    nonisolated static let examplesRunOn = "on the UGen300 stick"

    var exampleEngine: any InferenceEngine { device }

    /// Stick models are downloaded the first time they are used, so any model with a download address can be used.
    func canUse(_ name: String) -> Bool { installed.contains(name) || ModelCatalog.model(named: name)?.url != nil }

    func modelLabel(_ name: String) -> String {
        if installed.contains(name) { return name }
        return canUse(name) ? "\(name) (downloads on first use)" : "\(name) (not available)"
    }

    /// Puts `model` on the stick next to the main one (downloading it first if needed).
    func loadExtra(_ model: ModelInfo) async throws {
        if await device.loadedModelNames.contains(model.name) { return }
        if !installed.contains(model.name) {
            status = "Downloading \(model.name)…"
            try await download(model)
        }
        try await device.addModel(hef: Self.fileURL(for: model), info: model)
        status = "Ready"
    }

    /// Makes `model` the only model on the stick.
    func loadAlone(_ model: ModelInfo) async throws {
        try await prepare(model)
    }

    func exampleLanguageModels(_ use: LanguageUse) -> [ExampleLanguageModel] {
        let names: [String]
        switch use {
        case .pictures: names = [Self.visionChatModelName]
        case .chat: names = Self.chatModelNames
        case .code: names = Self.chatModelNames.filter { $0.contains("Coder") } + Self.chatModelNames.filter { !$0.contains("Coder") }
        }
        let ready = names.filter { installed.contains($0) }, missing = names.filter { !installed.contains($0) }
        return (ready + missing).map { name in
            ExampleLanguageModel(id: name, title: name, label: installed.contains(name) ? name : "\(name) (add it on the Device page)")
        }
    }

    static func defaultLanguageModel(_ use: LanguageUse) -> String {
        switch use {
        case .pictures: return visionChatModelName
        case .chat: return chatModelNames[0]
        case .code: return chatModelNames.first { $0.contains("Coder") } ?? chatModelNames[0]
        }
    }

    /// Streams an answer from the stick (about `picture` when given, with the image model). Every call
    /// starts a fresh conversation on the stick. Cancelling the calling task stops the stick too.
    func exampleStream(modelID: String, system: String?, user: String, picture: CGImage? = nil, maxTokens: Int = 400,
                       temperature: Float = 0.3, onText: @escaping @MainActor (String) -> Void) async throws -> AnswerStats {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let stream: AsyncThrowingStream<String, Error>
        let name: String
        if let picture {
            let model = try await visionChat()
            name = Self.visionChatModelName
            try await model.clearContext()
            var parameters = model.defaultParameters
            parameters.maxGeneratedTokens = UInt32(maxTokens)
            parameters.temperature = temperature
            parameters.doSample = temperature > 0
            // The instructions go in front of the question: the image model is used with user turns only.
            let question = (system.map { $0 + "\n\n" } ?? "") + user
            stream = model.generate(messages: [.user(question, images: 1)], frames: [try model.prepareFrame(picture)], parameters: parameters)
        } else {
            let model = try await chat(named: modelID)
            name = modelID
            try await model.clearContext()
            var parameters = model.defaultParameters
            parameters.maxGeneratedTokens = UInt32(maxTokens)
            parameters.temperature = temperature
            parameters.doSample = temperature > 0
            var messages: [ChatMessage] = []
            if let system { messages.append(.system(system)) }
            messages.append(.user(user + (modelID.hasPrefix("Qwen3") ? " /no_think" : "")))
            stream = model.generate(messages: messages, parameters: parameters)
        }
        let clock = ContinuousClock()
        let start = clock.now
        var text = ""
        var pieces = 0
        do {
            for try await piece in stream {
                text += piece
                pieces += 1
                onText(ModelText.withoutThinking(text))
            }
        } catch {
            if !(error is CancellationError) { fail(error) }
            throw error
        }
        try Task.checkCancellation()
        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return AnswerStats(model: name, tokens: pieces, tokensPerSecond: seconds > 0 ? Double(pieces) / seconds : 0)
    }

    /// Speech (mono 16 kHz) to text with Whisper on the stick.
    func exampleTranscribe(_ samples: [Float]) async throws -> String {
        let model = try await speech()
        let duration = samples.count / SpeechToText.sampleRate
        let segments = try await model.transcribe(samples: samples, timeout: .seconds(max(120, duration)))
        return segments.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
