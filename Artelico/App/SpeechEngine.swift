import AVFoundation
import Foundation
import StudioCore
import WhisperKit

/// Holds the loaded Whisper model for `StudioModel`.
final class LoadedWhisper: @unchecked Sendable {
    var kit: WhisperKit?
}

/// Speech to text with Whisper on this device (WhisperKit: Core ML, mostly on the Neural Engine).
/// Models come from huggingface.co/argmaxinc/whisperkit-coreml and are kept in the models folder.
extension StudioModel {
    /// Where Whisper models are stored (a "whisper" folder inside the models folder).
    static var whisperFolder: URL {
        let url = modelsDirectory.appendingPathComponent("whisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The Whisper models WhisperKit supports on this device, and the one it recommends.
    static var whisperModels: (recommended: String, supported: [String]) {
        let support = WhisperKit.recommendedModels()
        return (support.default, support.supported)
    }

    /// Folder of a model downloaded earlier, if it is still there.
    private func downloadedWhisperFolder(_ variant: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: "whisper.folder.\(variant)") else { return nil }
        let url = Self.whisperFolder.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func isWhisperDownloaded(_ variant: String) -> Bool { downloadedWhisperFolder(variant) != nil }

    /// Downloads (first time only) and loads a Whisper model; keeps it loaded for the next call.
    func whisperKit(_ variant: String) async throws -> WhisperKit {
        if let kit = speech.kit, whisperModel == variant { return kit }
        speech.kit = nil
        whisperModel = nil
        var folder = downloadedWhisperFolder(variant)
        if folder == nil {
            status = "Downloading \(variant)…"
            speechProgress = 0
            defer { speechProgress = nil }
            let downloaded = try await WhisperKit.download(variant: variant, downloadBase: Self.whisperFolder) { [weak self] progress in
                Task { @MainActor in
                    // A late update must not bring the bar back once the download has finished (speechProgress nil).
                    if self?.speechProgress != nil { self?.speechProgress = progress.fractionCompleted }
                }
            }
            // Remember it relative to the whisper folder, which survives moving the models folder.
            let base = Self.whisperFolder.standardizedFileURL.path
            let full = downloaded.standardizedFileURL.path
            let relative = full.hasPrefix(base) ? String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : full
            UserDefaults.standard.set(relative, forKey: "whisper.folder.\(variant)")
            folder = downloaded
        }
        status = "Loading \(variant)…"
        let config = WhisperKitConfig(modelFolder: folder!.path, verbose: false, logLevel: .error, prewarm: true, load: true, download: false)
        let kit = try await WhisperKit(config)
        speech.kit = kit
        whisperModel = variant
        status = "Ready"
        return kit
    }

    func deleteWhisper(_ variant: String) {
        if whisperModel == variant { speech.kit = nil; whisperModel = nil }
        if let folder = downloadedWhisperFolder(variant) { try? FileManager.default.removeItem(at: folder) }
        UserDefaults.standard.removeObject(forKey: "whisper.folder.\(variant)")
        objectWillChange.send()
    }
}

/// One stretch of recognised speech, in seconds from the start of the audio.
struct SpeechSegment: Hashable {
    var start: Float
    var end: Float
    var text: String
}

enum AudioLoader {
    static let sampleRate = 16_000

    /// Reads any audio file the system can open and returns mono 16 kHz samples in -1...1, which is
    /// what Whisper takes.
    static func samples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw StudioError.invalidInput("This audio format cannot be converted.")
        }
        let capacity = AVAudioFrameCount(Double(file.length) * target.sampleRate / file.processingFormat.sampleRate) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw StudioError.invalidInput("Not enough memory for this recording.")
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
