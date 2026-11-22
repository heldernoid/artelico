import Foundation
import StudioCore
import UIKit

/// Vision models download from the Artelico model repository on Hugging Face the first time they are
/// used. `manifest.json` there lists each model's files with size and SHA-256 (written by
/// native/tools/package_hf.py). A model is downloaded into a temporary folder, every file is checked,
/// and only then moved into the models folder, so a broken download never leaves half a model behind.
extension StudioModel {
    static let modelRepository = "helmo/artelico-models"
    /// A fixed commit of the repository, so later uploads cannot change what this build downloads.
    static let modelRevision = "922f2602f2a1b313e357e83e004a2d47feddc7f1"

    static var modelRepositoryURL: URL {
        URL(string: "https://huggingface.co/\(modelRepository)/resolve/\(modelRevision)/")!
    }

    struct RemoteFile: Decodable, Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
    }

    struct RemoteModel: Decodable, Sendable {
        let licence: String
        let source: String
        let coreml: [RemoteFile]
    }

    struct RemoteManifest: Decodable, Sendable {
        let models: [String: RemoteModel]
    }

    private static var manifestCache: RemoteManifest?

    /// The repository's manifest (fetched once per launch).
    func remoteManifest() async throws -> RemoteManifest {
        if let cached = Self.manifestCache { return cached }
        let (data, response) = try await URLSession.shared.data(from: Self.modelRepositoryURL.appendingPathComponent("manifest.json"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw StudioError.invalidInput("The model list could not be downloaded. Check the internet connection.")
        }
        let manifest = try JSONDecoder().decode(RemoteManifest.self, from: data)
        Self.manifestCache = manifest
        remoteSizes = manifest.models.mapValues { $0.coreml.reduce(0) { $0 + $1.bytes } }
        return manifest
    }

    /// Brings the small files next to models already on this device up to date: an output map
    /// (`.native.json`) that is missing or differs from the repository's (a model downloaded or copied before
    /// its map was made or fixed). Packages are left alone; only these few kilobytes are fetched.
    func refreshModelMaps() async {
        #if DEBUG
        // Testing with `-modelsfolder` points at the folder where maps are made: it may be newer than the repository.
        if CommandLine.arguments.contains("-modelsfolder") { return }
        #endif
        guard let manifest = try? await remoteManifest() else { return }
        let fm = FileManager.default
        for name in installed {
            for file in manifest.models[name]?.coreml ?? [] where file.path.hasSuffix(".native.json") {
                let local = Self.modelsDirectory.appendingPathComponent(String(file.path.dropFirst("coreml/".count)))
                if fm.fileExists(atPath: local.path), (try? Self.sha256(of: local)) == file.sha256 { continue }
                guard let (data, response) = try? await URLSession.shared.data(from: Self.modelRepositoryURL.appendingPathComponent(file.path)),
                      (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                try? data.write(to: local, options: .atomic)
            }
        }
        // A package re-converted in the repository (e.g. clip_resnet_50_text_encoder, float16 -> float32) has a new
        // Manifest.json inside: download that model again; the old copy stays usable until the new one is in.
        for name in installed {
            guard let model = ModelCatalog.model(named: name),
                  let file = manifest.models[name]?.coreml.first(where: { $0.path.hasSuffix(".mlpackage/Manifest.json") }) else { continue }
            let local = Self.modelsDirectory.appendingPathComponent(String(file.path.dropFirst("coreml/".count)))
            guard fm.fileExists(atPath: local.path), (try? Self.sha256(of: local)) != file.sha256 else { continue }
            try? await download(model, replacing: true)
        }
    }

    /// Downloads `model` (Core ML package, output map and any extra files) into the models folder.
    /// `replacing` downloads it again over the copy already there.
    func download(_ model: ModelInfo, replacing: Bool = false) async throws {
        guard replacing || !installed.contains(model.name) else { return }
        let manifest: RemoteManifest
        do { manifest = try await remoteManifest() } catch {
            throw StudioError.invalidInput("\(model.name) is not on this \(Self.deviceKind) and the model list could not be downloaded (\(error.localizedDescription)).")
        }
        guard let remote = manifest.models[model.name], !remote.coreml.isEmpty else {
            throw StudioError.invalidInput("\(model.name) is not in the model repository. Copy \(model.name).mlpackage into the models folder by hand (Device and models).")
        }

        // Already downloading (a tap in the model list, then a demo that needs it): wait for that one.
        while modelDownloads[model.name] != nil { try await Task.sleep(for: .milliseconds(200)) }
        if !replacing, installed.contains(model.name) { return }
        modelDownloads[model.name] = 0
        defer { modelDownloads[model.name] = nil }

        let fm = FileManager.default
        let staging = Self.modelsDirectory.appendingPathComponent(".downloading/\(model.name)", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let total = remote.coreml.reduce(0) { $0 + $1.bytes }
        var done: Int64 = 0
        let megabytes = { (bytes: Int64) in String(format: "%.0f", Double(bytes) / 1e6) }
        for file in remote.coreml {
            let relative = String(file.path.dropFirst("coreml/".count))
            let target = staging.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let before = done
            let name = model.name
            let (temporary, response) = try await FileDownloader.download(Self.modelRepositoryURL.appendingPathComponent(file.path)) { [weak self] progress in
                Task { @MainActor in
                    self?.status = "Downloading \(name): \(megabytes(before + progress.received)) of \(megabytes(total)) MB"
                    if self?.modelDownloads[name] != nil { self?.modelDownloads[name] = Double(before + progress.received) / Double(max(total, 1)) }
                }
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? fm.removeItem(at: temporary)
                throw StudioError.invalidInput("Download of \(file.path) failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
            }
            let digest = try await Task.detached(priority: .utility) { try Self.sha256(of: temporary) }.value
            guard digest == file.sha256 else {
                try? fm.removeItem(at: temporary)
                throw StudioError.invalidInput("\(file.path) arrived damaged (checksum differs). Try again.")
            }
            try fm.moveItem(at: temporary, to: target)
            done += file.bytes
        }

        // Everything arrived and checks out: move it into the models folder.
        for item in try fm.contentsOfDirectory(atPath: staging.path) {
            let destination = Self.modelsDirectory.appendingPathComponent(item)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: staging.appendingPathComponent(item), to: destination)
        }
        // The compiled copy of a replaced package is stale.
        try? fm.removeItem(at: Self.modelsDirectory.appendingPathComponent("\(model.name).mlmodelc"))
        refreshInstalled()
        status = "Downloaded \(model.name)"
    }

    /// Fetches files that belong next to `model` but are not in the models folder (a model downloaded before
    /// they were added to the repository), checked against the manifest. A file the repository does not list
    /// comes from `fallback` when it has an address for it.
    func downloadExtraFiles(_ names: [String], of model: String, fallback: (String) -> URL? = { _ in nil }) async throws {
        guard !names.isEmpty else { return }
        let listed = (try? await remoteManifest())?.models[model]?.coreml ?? []
        for name in names {
            let remote = listed.first { $0.path == "coreml/\(name)" }
            guard let address = remote.map({ Self.modelRepositoryURL.appendingPathComponent($0.path) }) ?? fallback(name) else {
                throw StudioError.invalidInput("\(name) is not in the model repository yet. Copy it next to \(model).mlpackage in the models folder.")
            }
            let (temporary, response) = try await FileDownloader.download(address) { [weak self] progress in
                Task { @MainActor in self?.status = "Downloading \(name): \(progress.received / 1_000_000) MB" }
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? FileManager.default.removeItem(at: temporary)
                throw StudioError.invalidInput("Download of \(name) failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
            }
            if let remote, try await Task.detached(priority: .utility, operation: { try Self.sha256(of: temporary) }).value != remote.sha256 {
                try? FileManager.default.removeItem(at: temporary)
                throw StudioError.invalidInput("\(name) arrived damaged (checksum differs). Try again.")
            }
            let destination = Self.modelsDirectory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    /// The models in the repository that are not on this device yet (known once the manifest is fetched).
    var missingModels: [ModelInfo] {
        ModelCatalog.all.filter { !installed.contains($0.name) && remoteSizes[$0.name] != nil }
    }
    /// Whether the app can run `model` yet (its outputs are decoded for at least one task).
    static func usable(_ model: ModelInfo) -> Bool {
        VisionTask.allCases.contains { VisionPipeline.supports($0, model: model) }
    }
    /// Models some screen of the app runs: main models and the helpers next to them.
    static func runs(_ model: ModelInfo) -> Bool { usable(model) || DeviceView.helperRoles[model.name] != nil }
    /// Total download size of `models`, from the manifest.
    func downloadSize(_ models: [ModelInfo]) -> Int { Int(models.reduce(0) { $0 + (remoteSizes[$1.name] ?? 0) }) }

    /// Downloads every model not here yet, one after the other. A model that fails is skipped and named at the
    /// end; `stopDownloadingAll` stops after cancelling the one in progress (what finished stays).
    func downloadAll(onlyUsable: Bool = false) {
        guard downloadAllTask == nil else { return }
        downloadAllTask = Task {
            defer { downloadAllTask = nil; downloadAllProgress = nil; UIApplication.shared.isIdleTimerDisabled = false }
            do { _ = try await remoteManifest() } catch { fail(error); return }
            let queue = missingModels.filter { !onlyUsable || Self.runs($0) }
            guard !queue.isEmpty else { return }
            // A locked screen suspends the app and cancels the download, so keep it awake meanwhile.
            UIApplication.shared.isIdleTimerDisabled = true
            var failed: [String] = []
            for (k, model) in queue.enumerated() {
                if Task.isCancelled { break }
                downloadAllProgress = (k, queue.count)
                do { try await download(model) } catch {
                    if Task.isCancelled { break }
                    failed.append(model.name)
                }
            }
            if Task.isCancelled { status = "Stopped downloading" }
            else if failed.isEmpty { status = "Downloaded \(queue.count) models" }
            else { status = "Downloaded \(queue.count - failed.count) of \(queue.count) models; failed: \(failed.joined(separator: ", ")). Try again." }
        }
    }

    func stopDownloadingAll() { downloadAllTask?.cancel() }

    /// Download size of `model` from the manifest, when it has been fetched.
    func downloadBytes(_ name: String) -> Int64? {
        Self.manifestCache?.models[name]?.coreml.reduce(0) { $0 + $1.bytes }
    }
}

#if DEBUG
import ImageIO
import UIKit

extension StudioModel {
    /// Test on a device: `-redownload <name>` deletes that model, downloads it again from the model
    /// repository, runs it on the bus sample and writes Documents/redownload-test.txt (read back with
    /// `devicectl device copy from`).
    func redownloadTestIfRequested() async {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-redownload"), index + 1 < arguments.count,
              let model = ModelCatalog.model(named: arguments[index + 1]) else { return }
        let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("redownload-test.txt")
        var lines = ["\(model.name) on \(UIDevice.current.model) \(UIDevice.current.systemVersion), from \(Self.modelRepository)@\(Self.modelRevision.prefix(7))"]
        func write() { try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8) }
        delete(model)
        lines.append("deleted: \(!installed.contains(model.name))")
        write()
        let clock = ContinuousClock()
        do {
            let start = clock.now
            try await download(model)
            lines.append("downloaded in \(clock.now - start), installed: \(installed.contains(model.name))")
            write()
            let task = VisionTask.allCases.first { VisionPipeline.supports($0, model: model) } ?? .classification
            try await prepare(model, task: task)
            guard let url = Bundle.main.url(forResource: "bus", withExtension: "jpg"),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw StudioError.invalidInput("no bus sample") }
            let ran = clock.now
            let result = needsPipeline(task, tiles: 1)
                ? try await runPipeline(task, on: image, tiles: 1, prompts: [])
                : try await VisionPipeline.run(task, on: image, device: device).result
            lines.append("\(task.rawValue) in \(clock.now - ran): \(result.summary)")
            lines.append("OK")
        } catch {
            lines.append("FAILED: \(error)")
        }
        write()
    }
}
#endif

