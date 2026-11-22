import SwiftUI
import UGenKit
import UniformTypeIdentifiers

/// Stick status and the models stored on the iPad or Mac.
struct DeviceView: View {
    @EnvironmentObject private var studio: StudioModel
    @State private var downloadingAll = false
    @State private var browserDownload: LanguageModelFile?
    @State private var choosingFolder = false

    private let taskOrder = ["detection", "pose", "instance_segmentation", "segment_everything", "classification", "depth", "semantic_segmentation",
                             "oriented_detection", "super_resolution", "ocr", "lane_detection", "face", "face_attribute", "face_landmarks", "person_attribute", "person_re_id",
                             "video_classification", "clip", "stereo_depth", "embedding"]

    private func title(_ task: String) -> String {
        VisionTask(rawValue: task)?.title ?? task.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func usable(_ model: ModelInfo) -> Bool {
        VisionTask.allCases.contains { VisionPipeline.supports($0, model: model) }
    }

    var body: some View {
        List {
            Section {
                MemoryRows(loaded: studio.loadedModel.map { ["\($0) (on the stick)"] } ?? [])
            } header: {
                Text("This \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : UIDevice.current.userInterfaceIdiom == .mac ? "Mac" : "iPhone")")
            } footer: {
                Text("Models run on the stick, in its own memory; this is what the app itself uses on this device (pictures, video, results).")
            }
            Section {
                SampleVideoRows()
            } header: {
                Text("Sample videos")
            } footer: {
                Text("Hailo's demo videos download from the Artelico model repository the first time one is chosen, are checked (SHA-256) and kept on this device.")
            }

            Section("Stick") {
                LabeledContent("State", value: studio.mode == .runtime ? "Running" : studio.mode.rawValue.capitalized)
                if let identity = studio.identity {
                    LabeledContent("Firmware", value: identity.firmwareVersion)
                    LabeledContent("Chip", value: identity.architecture == 6 ? "Hailo-10H" : "architecture \(identity.architecture)")
                    if let current = identity.currentLimitMilliamps {
                        LabeledContent("USB-C power offered", value: "\(current) mA")
                        if current < 3000 {
                            Text("Hailo recommends a 3,000 mA source for full performance.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ChipStatsRows()
                LabeledContent("Loaded model", value: studio.loadedModel ?? "None")
                Button("Reconnect") {
                    Task { do { try await studio.connect() } catch { studio.fail(error) } }
                }
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
                Text("Lets other devices on the same Wi-Fi send pictures to the stick through this \(StudioModel.deviceKind). It answers only while this app is open; the \(StudioModel.deviceKind) is kept awake while it is on. There is no password, so use it on a network you trust.")
            }

            Section {
                LabeledContent("On this \(StudioModel.deviceKind)", value: "\(studio.installed.count) models, \(formatBytes(studio.installedBytes))")
                LabeledContent("Folder") {
                    Text(StudioModel.chosenModelsFolder.map(\.path) ?? StudioModel.defaultModelsFolderName)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                Button("Use a models folder…") { choosingFolder = true }
                if StudioModel.chosenModelsFolder != nil {
                    Button("Use the default folder again") { studio.useDefaultModelsFolder() }
                }
                Button(downloadingAll ? "Downloading…" : "Download all usable models") { downloadAll() }
                    .disabled(downloadingAll)
            } header: {
                Text("Models")
            } footer: {
                Text("Models download from Hailo's servers the first time they are used, into the folder above. If you already have the .hef files, choose their folder and the app uses them where they are, without copying; new downloads then go there too. Models marked “not decoded yet” run on the stick, but this app cannot turn their output into a picture yet.")
            }

            Section {
                ForEach(LanguageModelFile.all) { file in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                            Text("\(file.purpose) · \(formatBytes(file.size))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if studio.installed.contains(file.name) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Button(role: .destructive) {
                                try? FileManager.default.removeItem(at: StudioModel.modelsDirectory.appendingPathComponent("\(file.name).hef"))
                                studio.refreshInstalled()
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        } else {
                            Button("Download") { browserDownload = file }.buttonStyle(.bordered)
                        }
                    }
                }
                Button("Check again") { studio.refreshInstalled() }
            } header: {
                Text("Chat, image questions and speech")
            } footer: {
                Text("These come from dev-public.hailo.ai, which only serves web browsers, so Download opens the address in a browser window inside the app and saves the file from there. You can also put the files in the models folder yourself, or choose a folder that already has them.")
            }

            ForEach(taskOrder, id: \.self) { task in
                let models = ModelCatalog.models(for: task)
                if !models.isEmpty {
                    Section(title(task)) {
                        ForEach(models) { model in ModelRow(model: model, usable: usable(model)) }
                    }
                }
            }
        }
        .navigationTitle("Device and models")
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            do { try studio.useModelsFolder(try result.get()) } catch { studio.fail(error) }
        }
        .sheet(item: $browserDownload) { file in
            WebDownloadView(title: file.name, address: file.address,
                            destination: StudioModel.modelsDirectory.appendingPathComponent("\(file.name).hef")) {
                studio.refreshInstalled()
            }
        }
    }

    private func downloadAll() {
        downloadingAll = true
        Task {
            for model in ModelCatalog.all where usable(model) && !studio.installed.contains(model.name) {
                do { try await studio.download(model) } catch { studio.fail(error); break }
            }
            downloadingAll = false
        }
    }
}

struct ModelRow: View {
    @EnvironmentObject private var studio: StudioModel
    let model: ModelInfo
    let usable: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                Text("\(model.inputWidth)×\(model.inputHeight) · \(formatBytes(model.fileSize ?? 0))\(usable ? "" : " · not decoded yet")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = studio.downloads[model.name] {
                ProgressView(value: progress).frame(width: 90)
            } else if studio.installed.contains(model.name) {
                Button(role: .destructive) { studio.delete(model) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            } else {
                Button { Task { do { try await studio.download(model) } catch { studio.fail(error) } } } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

/// The language and speech models. They are not in the vision model table and cannot be downloaded
/// by the app (see the footer in the list).
struct LanguageModelFile: Identifiable {
    let name: String
    let purpose: String
    let size: Int

    var id: String { name }
    /// Where Hailo publishes the file for the 5.3 runtime.
    var address: URL { URL(string: "https://dev-public.hailo.ai/v5.3.0/blob/\(name).hef")! }

    static let all = [
        LanguageModelFile(name: "Whisper-Base", purpose: "Speech to text", size: 130_206_034),
        LanguageModelFile(name: "Qwen2.5-1.5B-Instruct", purpose: "Chat", size: 2_464_582_493),
        LanguageModelFile(name: "Qwen2-VL-2B-Instruct", purpose: "Questions about a picture", size: 3_255_444_179),
        LanguageModelFile(name: "Qwen2.5-Coder-1.5B-Instruct", purpose: "Chat about code", size: 1_677_961_416),
        LanguageModelFile(name: "Qwen3-1.7B-Instruct", purpose: "Chat", size: 2_880_748_478),
        LanguageModelFile(name: "Llama3.2-1B-Instruct", purpose: "Chat", size: 1_402_376_894),
    ]
}
