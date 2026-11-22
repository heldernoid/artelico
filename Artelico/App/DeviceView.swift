import SwiftUI
import StudioCore
import UniformTypeIdentifiers

/// The engine settings and the models stored on this device.
struct DeviceView: View {
    @EnvironmentObject private var studio: StudioModel
    @State private var choosingFolder = false

    private let taskOrder = ["detection", "pose", "instance_segmentation", "segment_everything", "classification", "depth", "semantic_segmentation",
                             "oriented_detection", "super_resolution", "ocr", "lane_detection", "face", "face_attribute", "face_landmarks", "person_attribute", "person_re_id",
                             "video_classification", "clip", "stereo_depth", "embedding"]

    private func title(_ task: String) -> String {
        VisionTask(rawValue: task)?.title ?? task.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func usable(_ model: ModelInfo) -> Bool { StudioModel.usable(model) }

    /// Models the app uses next to a main model (not chosen on their own), and what for. Each CLIP / SigLIP
    /// text encoder goes with its own image encoder (CLIPModels.pairs).
    static let helperRoles: [String: String] = [
        "arcface_mobilefacenet": "used by face recognition (who the face is)",
        "arcface_r50": "face recognition, when chosen as the recognition model (more accurate)",
        "ocr": "used by Read text and Plate gate (reads the letters)",
        "hand_landmark_lite": "used by the hand demos (21 points per hand)",
        "all_minilm_l6_v2": "used by the Assistant (picks its tools)",
    ].merging(CLIPModels.pairs.map { ($0.text, "used by picture tagging with \($0.image) (reads the prompts)") }) { own, _ in own }

    /// Main models and helpers, by task (the sections of the list).
    private func shown(_ task: String) -> [ModelInfo] {
        ModelCatalog.models(for: task).filter { usable($0) || Self.helperRoles[$0.name] != nil }
    }

    /// Helpers whose task has no section of its own.
    private var otherHelpers: [ModelInfo] {
        let listed = Set(taskOrder.flatMap { shown($0).map(\.name) })
        return ModelCatalog.all.filter { Self.helperRoles[$0.name] != nil && !listed.contains($0.name) }
    }

    /// In the model repository, but nothing in the app runs them yet.
    private var unused: [ModelInfo] {
        ModelCatalog.all.filter { !usable($0) && Self.helperRoles[$0.name] == nil }
    }

    @State private var languageQueue: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                Picker("Run models on", selection: $studio.computeUnits) {
                    ForEach(ComputeChoice.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Loaded model", value: studio.loadedModel ?? "None")
                MemoryRows(loaded: [studio.loadedModel,
                                    studio.llmName.map { name in studio.languageModels.first { $0.id == name }?.title ?? name },
                                    studio.whisperModel.map { "Whisper \($0)" }].compactMap { $0 })
            } header: {
                Text("Engine")
            } footer: {
                Text("Models run with Core ML on this \(StudioModel.deviceKind)'s own chips. Automatic lets Core ML choose, usually the Neural Engine, which is fastest and uses the least power.")
            }

            Section {
                SampleVideoRows()
            } header: {
                Text("Sample videos")
            } footer: {
                Text("Hailo's demo videos download from the Artelico model repository the first time one is chosen, are checked (SHA-256) and kept on this device.")
            }

            Section {
                Toggle("Serve the REST API", isOn: Binding(get: { studio.apiRunning }, set: { $0 ? studio.startAPI() : studio.stopAPI() }))
                if studio.apiRunning {
                    let address = StudioModel.wifiAddress ?? "<this \(StudioModel.deviceKind)'s address>"
                    LabeledContent("Address", value: "http://\(address):\(StudioModel.apiPort)/v1")
                    LabeledContent("Requests answered", value: "\(studio.apiRequests)")
                    Text("curl -X POST --data-binary @photo.jpg \"http://\(address):\(StudioModel.apiPort)/v1/vision/detection?model=yolov8s\"")
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
                if !studio.apiNote.isEmpty { Text(studio.apiNote).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("REST API")
            } footer: {
                Text("Lets other devices on the same Wi-Fi send pictures to \(StudioModel.deviceKind). It answers only while this app is open; the \(StudioModel.deviceKind) is kept awake while it is on. There is no password, so use it on a network you trust.")
            }

            Section {
                LabeledContent("On this \(StudioModel.deviceKind)", value: "\(studio.installed.count) models, \(formatBytes(studio.installedBytes))")
                LabeledContent("Folder") {
                    Text(StudioModel.chosenModelsFolder.map(\.path) ?? StudioModel.defaultModelsFolderName)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                if let progress = studio.downloadAllProgress {
                    HStack {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.of, 1)))
                        Text("\(progress.done + 1) of \(progress.of)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button("Stop", role: .destructive) { studio.stopDownloadingAll() }.buttonStyle(.borderless)
                    }
                } else if !studio.missingModels.isEmpty {
                    let missing = studio.missingModels, runnable = missing.filter(StudioModel.runs)
                    if !runnable.isEmpty && runnable.count < missing.count {
                        Button { studio.downloadAll(onlyUsable: true) } label: {
                            Label("Download the \(runnable.count) models the app runs (\(formatBytes(studio.downloadSize(runnable))))",
                                  systemImage: "arrow.down.circle")
                        }
                    }
                    Button { studio.downloadAll() } label: {
                        Label("Download all \(missing.count) models (\(formatBytes(studio.downloadSize(missing))))",
                              systemImage: "arrow.down.circle.dotted")
                    }
                }
                Button("Use a models folder…") { choosingFolder = true }
                if StudioModel.chosenModelsFolder != nil {
                    Button("Use the default folder again") { studio.useDefaultModelsFolder() }
                }
            } header: {
                Text("Models")
            } footer: {
                Text("Models are Core ML packages (.mlpackage) converted from Hailo's Model Zoo. Each one downloads the first time it is used, from huggingface.co/\(StudioModel.modelRepository), into the folder above. You can also choose a folder that already has them; the app uses them where they are.")
            }

            languageSection

            ForEach(taskOrder, id: \.self) { task in
                let models = shown(task)
                if !models.isEmpty {
                    Section(title(task)) {
                        ForEach(models) { model in ModelRow(model: model, note: Self.helperRoles[model.name]) }
                    }
                }
            }
            if !otherHelpers.isEmpty {
                Section("Helpers") {
                    ForEach(otherHelpers) { model in ModelRow(model: model, note: Self.helperRoles[model.name]) }
                }
            }
            if !unused.isEmpty {
                Section {
                    ForEach(unused) { model in ModelRow(model: model, note: model.tasks.first.map { title($0).lowercased() }) }
                } header: {
                    Text("Not used by the app yet")
                } footer: {
                    Text("These are in the model repository and download like the others, but no screen of the app runs them yet: other CLIP, SigLIP and TinyCLIP encoders, face, person and pose models whose results the app cannot read yet.")
                }
            }
        }
        .navigationTitle("Device and models")
        .task { _ = try? await studio.remoteManifest() }   // download sizes for the buttons
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            do { try studio.useModelsFolder(try result.get()) } catch { studio.fail(error) }
        }
    }
}

extension DeviceView {
    /// The language models (GGUF files for llama.cpp). They come from their makers' Hugging Face
    /// repositories, not from the model repository, so they have their own buttons.
    @ViewBuilder var languageSection: some View {
        let models = studio.languageModels
        let missing = models.filter { !studio.isDownloaded($0) }
        Section {
            if let queue = languageQueue, !queue.isCancelled {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Downloading the language models one after another…").font(.callout)
                    Spacer()
                    Button("Stop", role: .destructive) { languageQueue?.cancel(); languageQueue = nil }.buttonStyle(.borderless)
                }
            } else if !missing.isEmpty {
                Button {
                    languageQueue = Task {
                        for model in missing where !Task.isCancelled {
                            do { try await studio.downloadLanguageModel(model) } catch { if !Task.isCancelled { studio.fail(error) } }
                        }
                        languageQueue = nil
                    }
                } label: {
                    Label("Download all \(missing.count) language models (\(formatBytes(missing.reduce(0) { $0 + $1.totalMegabytes } * 1_000_000)))",
                          systemImage: "arrow.down.circle.dotted")
                }
            }
            ForEach(models) { model in LanguageModelRow(model: model) }
        } header: {
            Text("Language models (GGUF)")
        } footer: {
            Text("Chat, Ask an image, the Assistant and the language examples run these with llama.cpp. They download from their makers' pages on Hugging Face (ggml-org, Qwen, bartowski), not from the Artelico model repository.")
        }
    }
}

struct LanguageModelRow: View {
    @EnvironmentObject private var studio: StudioModel
    let model: GGUFModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                Text("\(model.purpose == .vision ? "pictures and chat" : "chat") · \(model.license)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if studio.isDownloaded(model) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Button(role: .destructive) { studio.deleteLanguageModel(model) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            } else if let progress = studio.llmDownloads[model.id] {
                ProgressView(value: progress).frame(width: 90)
                Text("\(Int(progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Button {
                    Task { do { try await studio.downloadLanguageModel(model) } catch { studio.fail(error) } }
                } label: {
                    Label(formatBytes(model.totalMegabytes * 1_000_000), systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

struct ModelRow: View {
    @EnvironmentObject private var studio: StudioModel
    let model: ModelInfo
    /// What the model is for, when it is a helper or not used yet.
    var note: String? = nil

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                Text("\(model.inputWidth)×\(model.inputHeight)\(note.map { " · \($0)" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if studio.installed.contains(model.name) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Button(role: .destructive) { studio.delete(model) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            } else if let progress = studio.modelDownloads[model.name] {
                ProgressView(value: progress).frame(width: 90)
                Text("\(Int(progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Button {
                    Task {
                        do { try await studio.download(model) } catch { studio.fail(error) }
                    }
                } label: {
                    Label(studio.remoteSizes[model.name].map { formatBytes(Int($0)) } ?? "Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}
