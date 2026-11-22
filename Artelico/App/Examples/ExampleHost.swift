import SwiftUI
import StudioCore

// The examples folder is compiled into both apps: Artelico (Core ML, llama.cpp and WhisperKit on this
// device) and Hailo Studio (everything on the UGen300 stick). Each app's `ExampleSupport.swift` gives
// StudioModel the same few members, used by the examples:
//
//   var exampleEngine: any InferenceEngine                 where the vision models run
//   func canUse(_ name: String) -> Bool                     the model is here (Artelico) or can be fetched (Hailo Studio)
//   func modelLabel(_ name: String) -> String               its name in model pickers
//   func loadExtra(_ model: ModelInfo) async throws         load a model next to the main one
//   func loadAlone(_ model: ModelInfo) async throws         load only this model (Photo restore)
//   func exampleLanguageModels(_ use: LanguageUse) -> [ExampleLanguageModel]
//   static func defaultLanguageModel(_ use: LanguageUse) -> String
//   func exampleStream(modelID:system:user:picture:maxTokens:temperature:onText:) async throws -> AnswerStats
//   func exampleTranscribe(_ samples: [Float]) async throws -> String
//   static let examplesRunOn: String                        "on this iPad", "on the UGen300 stick"

/// The app's name as shown on the home screen.
enum ExampleApp {
    static var name: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "this app" }
}

/// What a language model is used for in an example.
enum LanguageUse {
    /// Questions about a picture.
    case pictures
    /// Text in, text out.
    case chat
    /// Writing programs (a coding model first, if there is one).
    case code
}

/// A language model an example can use.
struct ExampleLanguageModel: Identifiable, Hashable {
    let id: String
    let title: String
    /// Shown in the picker, e.g. "Qwen3 VL 2B (1200 MB to download)".
    let label: String
}

/// How an answer went.
struct AnswerStats {
    let model: String
    let tokens: Int
    let tokensPerSecond: Double

    var summary: String { String(format: "%@ · %d tokens at %.1f per second", model, tokens, tokensPerSecond) }
}

/// A model picker for one use, remembering the choice.
struct LanguagePicker: View {
    @EnvironmentObject private var studio: StudioModel
    let use: LanguageUse
    @Binding var modelID: String

    var body: some View {
        let models = studio.exampleLanguageModels(use)
        Picker("Model", selection: $modelID) {
            ForEach(models) { Text($0.label).tag($0.id) }
        }
        .pickerStyle(.menu)
        .onAppear {
            if !models.contains(where: { $0.id == modelID }), let first = models.first { modelID = first.id }
        }
    }
}
