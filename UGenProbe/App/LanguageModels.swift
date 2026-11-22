import AVFoundation
import Foundation
import UGenKit

/// Loading and switching the chat, image-question and speech models. Only one of them, or the vision
/// models, is on the stick at a time; loading one replaces whatever was there.
extension StudioModel {
    static let chatModelNames = ["Qwen2.5-1.5B-Instruct", "Qwen3-1.7B-Instruct", "Llama3.2-1B-Instruct", "Qwen2.5-Coder-1.5B-Instruct"]
    static let visionChatModelName = "Qwen2-VL-2B-Instruct"
    static let speechModelName = "Whisper-Base"

    var installedChatModels: [String] { Self.chatModelNames.filter { installed.contains($0) } }

    private func languageFile(_ name: String) throws -> URL {
        guard installed.contains(name) else {
            throw UGenError.invalidInput("\(name) is not on this \(StudioModel.deviceKind). Add it on the Device page.")
        }
        return Self.modelsDirectory.appendingPathComponent("\(name).hef")
    }

    private func readyForLanguageModel(_ name: String, seconds: String) async throws {
        guard !liveRunning else { throw UGenError.invalidInput("Stop the live view first; the stick can do one thing at a time.") }
        if await device.mode != .runtime { try await connect() }
        status = "Loading \(name) (\(seconds))…"
    }

    /// Forgets the language models. Called before a vision model is loaded, which takes their place on the stick.
    func dropLanguageModels() {
        chatModel = nil
        chatModelName = nil
        visionChatModel = nil
        speechModel = nil
    }

    func chat(named name: String) async throws -> ChatModel {
        if let chatModel, chatModelName == name { return chatModel }
        let file = try languageFile(name)
        try await readyForLanguageModel(name, seconds: "about 6 seconds")
        dropLanguageModels()
        let model = try await ChatModel(hef: file, device: device)
        chatModel = model
        chatModelName = name
        loadedModel = name
        status = "Ready"
        return model
    }

    func visionChat() async throws -> VisionChatModel {
        if let visionChatModel { return visionChatModel }
        let file = try languageFile(Self.visionChatModelName)
        try await readyForLanguageModel(Self.visionChatModelName, seconds: "about 9 seconds")
        dropLanguageModels()
        let model = try await VisionChatModel(hef: file, device: device)
        visionChatModel = model
        loadedModel = Self.visionChatModelName
        status = "Ready"
        return model
    }

    func speech() async throws -> SpeechToText {
        if let speechModel { return speechModel }
        let file = try languageFile(Self.speechModelName)
        try await readyForLanguageModel(Self.speechModelName, seconds: "about 2 seconds")
        dropLanguageModels()
        let model = try await SpeechToText(hef: file, device: device)
        speechModel = model
        loadedModel = Self.speechModelName
        status = "Ready"
        return model
    }
}

enum AudioLoader {
    /// Reads any audio file the system can open and returns mono 16 kHz samples in -1...1, which is
    /// what the speech model takes.
    static func samples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SpeechToText.sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw UGenError.invalidInput("This audio format cannot be converted.")
        }
        let capacity = AVAudioFrameCount(Double(file.length) * target.sampleRate / file.processingFormat.sampleRate) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw UGenError.invalidInput("Not enough memory for this recording.")
        }
        try file.read(into: input)
        var fed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        guard let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
