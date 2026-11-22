import CryptoKit
import Foundation
import StudioCore
import UIKit

/// A GGUF language model from Hugging Face. Vision models also need their image encoder (mmproj).
struct GGUFModel: Identifiable, Hashable, Codable {
    enum Purpose: String, Codable { case chat, vision }

    var id: String { file }
    let title: String
    let purpose: Purpose
    let repo: String
    let file: String
    let megabytes: Int
    var visionFile: String? = nil
    var visionMegabytes: Int? = nil
    let license: String
    var note: String = ""

    static func address(_ repo: String, _ file: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")!
    }

    var totalMegabytes: Int { megabytes + (visionMegabytes ?? 0) }

    /// Chosen models: official publishers (ggml-org = llama.cpp's own, Qwen) and bartowski for Llama
    /// (Meta publishes no GGUF). All 4-bit (Q4_K_M). Sizes checked on Hugging Face, 2026-11-18.
    static let catalog: [GGUFModel] = [
        GGUFModel(title: "Qwen3 1.7B", purpose: .chat, repo: "ggml-org/Qwen3-1.7B-GGUF", file: "Qwen3-1.7B-Q4_K_M.gguf",
                  megabytes: 1282, license: "Apache-2.0", note: "Good default: fast, multilingual."),
        GGUFModel(title: "Gemma 3 1B", purpose: .chat, repo: "ggml-org/gemma-3-1b-it-GGUF", file: "gemma-3-1b-it-Q4_K_M.gguf",
                  megabytes: 806, license: "Gemma", note: "Smallest and quickest."),
        GGUFModel(title: "Llama 3.2 3B", purpose: .chat, repo: "bartowski/Llama-3.2-3B-Instruct-GGUF", file: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
                  megabytes: 2019, license: "Llama 3.2"),
        GGUFModel(title: "Qwen3 4B", purpose: .chat, repo: "Qwen/Qwen3-4B-GGUF", file: "Qwen3-4B-Q4_K_M.gguf",
                  megabytes: 2497, license: "Apache-2.0", note: "Best answers of these; needs more memory."),
        GGUFModel(title: "Qwen2.5 Coder 1.5B", purpose: .chat, repo: "Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF", file: "qwen2.5-coder-1.5b-instruct-q4_k_m.gguf",
                  megabytes: 1066, license: "Apache-2.0", note: "For code (Offline code example)."),
        GGUFModel(title: "SmolVLM2 2.2B", purpose: .vision, repo: "ggml-org/SmolVLM2-2.2B-Instruct-GGUF", file: "SmolVLM2-2.2B-Instruct-Q4_K_M.gguf",
                  megabytes: 1113, visionFile: "mmproj-SmolVLM2-2.2B-Instruct-Q8_0.gguf", visionMegabytes: 593, license: "Apache-2.0",
                  note: "Small picture model."),
        GGUFModel(title: "Qwen2.5-VL 3B", purpose: .vision, repo: "ggml-org/Qwen2.5-VL-3B-Instruct-GGUF", file: "Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf",
                  megabytes: 1930, visionFile: "mmproj-Qwen2.5-VL-3B-Instruct-Q8_0.gguf", visionMegabytes: 845, license: "Apache-2.0",
                  note: "Reads text in pictures well."),
        GGUFModel(title: "Gemma 3 4B", purpose: .vision, repo: "ggml-org/gemma-3-4b-it-GGUF", file: "gemma-3-4b-it-Q4_K_M.gguf",
                  megabytes: 2490, visionFile: "mmproj-model-f16.gguf", visionMegabytes: 851, license: "Gemma",
                  note: "Pictures and chat."),
    ]
}

extension StudioModel {
    static var ggufFolder: URL {
        let url = modelsDirectory.appendingPathComponent("gguf", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Files from different repositories can share a name (several "mmproj-model-f16.gguf"), so the
    /// local name includes the repository.
    static func localFile(_ repo: String, _ file: String) -> URL {
        ggufFolder.appendingPathComponent(repo.replacingOccurrences(of: "/", with: "__") + "__" + file)
    }

    func isDownloaded(_ model: GGUFModel) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.localFile(model.repo, model.file).path) else { return false }
        if let vision = model.visionFile { return fm.fileExists(atPath: Self.localFile(model.repo, vision).path) }
        return true
    }

    /// Models the user added by pasting a Hugging Face link.
    var customLanguageModels: [GGUFModel] {
        guard let data = UserDefaults.standard.data(forKey: "gguf.custom"),
              let saved = try? JSONDecoder().decode([GGUFModel].self, from: data) else { return [] }
        return saved
    }

    var languageModels: [GGUFModel] { GGUFModel.catalog + customLanguageModels }

    /// Adds a model from a link like https://huggingface.co/<org>/<repo>/resolve/main/<file>.gguf
    /// (or .../blob/main/...). An optional second link is its image encoder.
    func addLanguageModel(link: String, visionLink: String?) throws -> GGUFModel {
        func parse(_ text: String) throws -> (repo: String, file: String) {
            guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.host?.hasSuffix("huggingface.co") == true else {
                throw StudioError.invalidInput("Paste a huggingface.co link to a .gguf file.")
            }
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count >= 5, ["resolve", "blob"].contains(parts[2]), parts.last!.hasSuffix(".gguf") else {
                throw StudioError.invalidInput("The link must point to a .gguf file (…/resolve/main/<name>.gguf).")
            }
            return ("\(parts[0])/\(parts[1])", parts[4...].joined(separator: "/"))
        }
        let main = try parse(link)
        let vision = try visionLink.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : try parse($0) }
        let model = GGUFModel(title: (main.file as NSString).deletingPathExtension, purpose: vision == nil ? .chat : .vision,
                              repo: main.repo, file: main.file, megabytes: 0, visionFile: vision?.file, visionMegabytes: vision == nil ? nil : 0,
                              license: "see the model page", note: "Added from a link.")
        var saved = customLanguageModels.filter { $0.id != model.id }
        saved.append(model)
        UserDefaults.standard.set(try JSONEncoder().encode(saved), forKey: "gguf.custom")
        objectWillChange.send()
        return model
    }

    /// Downloads the model file(s), checking each against the SHA-256 that Hugging Face publishes.
    func downloadLanguageModel(_ model: GGUFModel) async throws {
        var files = [model.file]
        if let vision = model.visionFile { files.append(vision) }
        for (index, file) in files.enumerated() {
            let destination = Self.localFile(model.repo, file)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            let expected = try await Self.publishedChecksum(repo: model.repo, file: file)
            llmDownloads[model.id] = 0
            status = "Downloading \(file)…"
            // A locked screen suspends the app and cancels the download, so keep it awake meanwhile.
            UIApplication.shared.isIdleTimerDisabled = true
            defer { llmDownloads[model.id] = nil; llmDownloadInfo[model.id] = nil; status = "Ready"; UIApplication.shared.isIdleTimerDisabled = false }
            // Large files over Wi-Fi drop now and then; FileDownloader continues where it stopped.
            var fetched: (URL, URLResponse)?
            var lastError: Error?
            do {
                let part = Double(index), parts = Double(files.count), name = file
                fetched = try await FileDownloader.download(GGUFModel.address(model.repo, file)) { [weak self] progress in
                    let text = String(format: "%@: %.0f of %.0f MB, %.1f MB/s", name, Double(progress.received) / 1e6,
                                      Double(max(progress.total, 0)) / 1e6, progress.bytesPerSecond / 1e6)
                    Task { @MainActor in
                        self?.llmDownloads[model.id] = (part + progress.fraction) / parts
                        self?.llmDownloadInfo[model.id] = text
                    }
                }
            } catch {
                lastError = error
            }
            guard let (temporary, response) = fetched else { throw lastError ?? StudioError.invalidInput("Download of \(file) failed.") }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? FileManager.default.removeItem(at: temporary)
                throw StudioError.invalidInput("Download of \(file) failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
            }
            if let expected {
                status = "Checking \(file)…"
                let actual = try Self.sha256(of: temporary)
                guard actual == expected else {
                    try? FileManager.default.removeItem(at: temporary)
                    throw StudioError.invalidInput("\(file) did not match its published checksum; it was not kept.")
                }
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        objectWillChange.send()
    }

    func deleteLanguageModel(_ model: GGUFModel) {
        if llmName == model.id { llm = nil; llmName = nil }
        try? FileManager.default.removeItem(at: Self.localFile(model.repo, model.file))
        if let vision = model.visionFile { try? FileManager.default.removeItem(at: Self.localFile(model.repo, vision)) }
        objectWillChange.send()
    }

    /// The SHA-256 Hugging Face lists for a large (LFS) file, or nil if it lists none.
    private static func publishedChecksum(repo: String, file: String) async throws -> String? {
        let folder = (file as NSString).deletingLastPathComponent
        let address = "https://huggingface.co/api/models/\(repo)/tree/main" + (folder.isEmpty ? "" : "/\(folder)")
        let (data, _) = try await URLSession.shared.data(from: URL(string: address)!)
        let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        let entry = entries.first { ($0["path"] as? String) == file }
        return (entry?["lfs"] as? [String: Any])?["oid"] as? String
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Loads a language model (downloading it first if needed). Only one is kept in memory, and the
    /// vision and speech models are released first, since a language model needs most of the memory.
    /// The language model the voice assistant uses for parameters and answers (assistant settings).
    var assistantModel: GGUFModel? {
        let chosen = UserDefaults.standard.string(forKey: "assistant.model") ?? GGUFModel.catalog[0].id
        return languageModels.first { $0.id == chosen } ?? languageModels.first { $0.purpose == .chat }
    }

    /// `keepSpeech` keeps Whisper loaded next to the language model (the voice assistant needs both).
    func languageModel(_ model: GGUFModel, forPictures: Bool = false, keepSpeech: Bool = false) async throws -> LlamaEngine {
        if let llm, llmName == model.id, !forPictures || llm.canSeePictures { return llm }
        if !isDownloaded(model) { try await downloadLanguageModel(model) }
        llm = nil
        llmName = nil
        await device.unloadAll()
        loadedModel = nil
        if !keepSpeech {
            speech.kit = nil
            whisperModel = nil
        }
        status = "Loading \(model.title)…"
        defer { status = "Ready" }
        let main = Self.localFile(model.repo, model.file).path
        let vision = model.visionFile.map { Self.localFile(model.repo, $0).path }
        let engine = try await Task.detached(priority: .userInitiated) {
            try LlamaEngine(name: model.title, modelPath: main, visionPath: vision)
        }.value
        llm = engine
        llmName = model.id
        return engine
    }
}
