import PhotosUI
import SwiftUI
import UGenKit

/// Runs one task on a picture: a sample, a photo from the library, or one taken with the camera.
struct VisionView: View {
    @EnvironmentObject private var studio: StudioModel
    @State private var task: VisionTask = .detection
    @State private var modelName = "yolov8m"
    @State private var source: CGImage?
    @State private var sourceName: String?
    @State private var second: CGImage?
    @State private var rendered: CGImage?
    @State private var result: VisionResult?
    @State private var timings: [String] = []
    @State private var running = false
    @State private var note = ""
    @State private var showOriginal = false
    @State private var enrollName = ""
    @State private var pickedSecond: PhotosPickerItem?
    @AppStorage("vision.tiles") private var tiles = 1
    @AppStorage("clip.prompts") private var promptText = "car, truck, bus, person, bicycle, -empty road"

    private var prompts: [String] {
        promptText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TaskModelPicker(task: $task, modelName: $modelName)
                TaskOptions(task: task, tiles: $tiles, promptText: $promptText)
                Spacer()
            }
            .padding(.horizontal).padding(.vertical, 8)

            HStack(alignment: .top, spacing: 14) {
                picture
                sidePanel.frame(width: 300)
            }
            .padding(.horizontal).padding(.bottom, 10)
            .frame(maxHeight: .infinity)

            PictureChooser(key: task.rawValue, selected: sourceName) { image, name in
                source = image
                sourceName = name
                clearResult()
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let rendered, let file = temporaryPNG(rendered) {
                    ShareLink(item: file) { Label("Share result", systemImage: "square.and.arrow.up") }
                }
                Button { run() } label: { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(source == nil || running || modelName.isEmpty)
            }
        }
        .onChange(of: task) { _, newTask in
            clearResult()
            // Offer a picture that suits the new task if the current one is a sample that does not.
            if let name = sourceName, let current = SamplePicture.all.first(where: { $0.file == name }), !current.tasks.contains(newTask.rawValue) {
                useBestSample(for: newTask)
            }
        }
        .onChange(of: modelName) { _, _ in clearResult() }
        .onChange(of: pickedSecond) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self) { second = decodePicture(data) }
            }
        }
        .onAppear {
            // Testing from the Mac: `-task <task> <model>` and `-sample <file>` choose what `-autorun` runs.
            let arguments = CommandLine.arguments
            if let index = arguments.firstIndex(of: "-task"), index + 2 < arguments.count, let wanted = VisionTask(rawValue: arguments[index + 1]) {
                task = wanted
                modelName = arguments[index + 2]
            }
            if let index = arguments.firstIndex(of: "-sample"), index + 1 < arguments.count,
               let sample = SamplePicture.all.first(where: { $0.file == arguments[index + 1] }), let image = sample.load() {
                source = image
                sourceName = sample.file
            }
            if source == nil { useBestSample(for: task) }
            // After the task change above has been handled (it clears the result).
            if arguments.contains("-autorun") { DispatchQueue.main.async { run() } }
        }
    }

    private var picture: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground))
            if let image = (showOriginal ? source : rendered) ?? source {
                Image(decorative: image, scale: 1).resizable().scaledToFit().padding(6)
                    .overlay(alignment: .bottomLeading) {
                        // Where the sample picture comes from (not for the user's own photos).
                        if let name = sourceName, SamplePicture.all.contains(where: { $0.file == name }) { CreditTag(file: name).padding(6) }
                    }
            } else {
                ContentUnavailableView("No picture", systemImage: "photo", description: Text("Pick one from the strip below."))
            }
            if running {
                ProgressView().controlSize(.large).padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .overlay(alignment: .topLeading) {
            if rendered != nil {
                Toggle("Show original", isOn: $showOriginal).toggleStyle(.button).buttonStyle(.bordered).padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidePanel: some View {
        ScrollView {
            VStack(spacing: 12) {
                if task == .stereoDepth {
                    Panel(title: "Right view") {
                        Text("The chosen picture is the left view. Pick the matching right view.").font(.callout).foregroundStyle(.secondary)
                        HStack {
                            PhotosPicker(second == nil ? "Choose photo" : "Change", selection: $pickedSecond, matching: .images)
                            Button("Use sample") { second = SamplePicture.all.first { $0.file == "stereo_right.jpg" }?.load() }
                        }
                        if second != nil { Label("Right view ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout) }
                    }
                }
                if task == .face {
                    Panel(title: "Known people") {
                        FaceEmbedderPicker(disabled: running)
                        TextField("Name for the largest face", text: $enrollName).textFieldStyle(.roundedBorder)
                        Button("Remember this face") { enroll() }
                            .disabled(enrollName.trimmingCharacters(in: .whitespaces).isEmpty || source == nil || running)
                        ForEach(studio.gallery.people.keys.sorted(), id: \.self) { name in
                            HStack {
                                Label(name, systemImage: "person.crop.circle")
                                Spacer()
                                Button(role: .destructive) { studio.forget(name) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
                if task == .videoClassification {
                    Panel(title: "One picture") {
                        Text("The model names the action in 16 frames of video. A photo is repeated 16 times, so it sees no movement and guesses from the scene alone: approximate. Live gives it real video.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if task == .personReID {
                    Panel(title: "People seen") {
                        Text("Everyone gets a number; the same person keeps it in the next pictures and in Live.").font(.callout).foregroundStyle(.secondary)
                        Button("Count from 1 again") { studio.forgetSessionFaces() }
                    }
                }
                Panel(title: "Result") {
                    if let result {
                        ResultList(result: result)
                    } else if note.isEmpty {
                        Text("Tap Run to send this picture to the stick.").font(.callout).foregroundStyle(.secondary)
                    }
                    if !note.isEmpty { Text(note).font(.callout).foregroundStyle(.red) }
                }
                if !timings.isEmpty {
                    Panel(title: "Timing") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(timings, id: \.self) { Chip(text: $0, systemImage: "timer") }
                        }
                    }
                }
            }
        }
    }

    private func clearResult() {
        rendered = nil
        result = nil
        timings = []
        note = ""
        showOriginal = false
    }

    private func useBestSample(for task: VisionTask) {
        guard let sample = SamplePicture.ordered(for: task.rawValue).first, let image = sample.load() else { return }
        source = image
        sourceName = sample.file
        if task == .stereoDepth { second = SamplePicture.all.first { $0.file == "stereo_right.jpg" }?.load() }
    }

    private func enroll() {
        guard let image = source, let model = ModelCatalog.model(named: modelName) else { return }
        let name = enrollName.trimmingCharacters(in: .whitespaces)
        running = true
        Task {
            defer { running = false }
            do {
                try await studio.prepare(model, task: .face)
                let count = try await studio.enroll(name, from: image)
                note = count == 0 ? "No face found in this picture." : ""
                if count > 0 {
                    enrollName = ""
                    run()
                }
            } catch {
                studio.fail(error)
                note = "\(error)"
            }
        }
    }

    private func run() {
        guard let image = source, let model = ModelCatalog.model(named: modelName), !running else { return }
        let task = self.task
        let tiles = task == .detection ? self.tiles : 1
        running = true
        note = ""
        Task {
            defer { running = false }
            do {
                let clock = ContinuousClock()
                var start = clock.now
                try await studio.prepare(model, task: task)
                let loading = clock.now - start
                start = clock.now
                var lines: [String] = []
                let outcome: VisionResult
                if studio.needsPipeline(task, tiles: tiles) {
                    outcome = try await studio.runPipeline(task, on: image, tiles: tiles, prompts: prompts, second: second)
                    lines.append("total \(formatMilliseconds(clock.now - start))")
                } else {
                    let (value, times) = try await VisionPipeline.run(task, on: image, device: studio.device)
                    outcome = value
                    lines = ["prepare \(formatMilliseconds(times.prepare))", "inference \(formatMilliseconds(times.inference))",
                             "decode \(formatMilliseconds(times.decode))"]
                }
                if loading > .milliseconds(50) { lines.insert("model load \(formatMilliseconds(loading))", at: 0) }
                result = outcome
                rendered = VisionRenderer.render(outcome, over: image)
                timings = lines
                showOriginal = false
            } catch {
                studio.fail(error)
                note = "\(error)"
            }
        }
    }
}
