import AVFoundation
import PhotosUI
import SwiftUI
import StudioCore
import UniformTypeIdentifiers
import WebKit

// The language examples from the UGen300 demos (V2 Outfit advisor, V3 Fridge chef, Calories, Face
// report, OfflineCode, Meeting notes). The language models run where the app runs them (ExampleHost.swift).

// MARK: - Camera snapshots

/// A camera preview without a model, for taking one picture (with a self-timer).
@MainActor
final class CameraSnapper: ObservableObject {
    @Published var frame: CGImage?
    @Published var running = false
    @Published var countdown: Int?
    @Published var front = true
    private var source: CameraSource?
    private var loop: Task<Void, Never>?

    func start() {
        stop()
        let camera = CameraSource(position: front ? .front : .back)
        source = camera
        running = true
        loop = Task {
            do {
                try await camera.start()
                while !Task.isCancelled {
                    if let image = camera.takeLatest() { frame = image }
                    try await Task.sleep(for: .milliseconds(60))
                }
            } catch {}
            camera.stop()
        }
    }

    func stop() {
        loop?.cancel(); loop = nil
        source?.stop(); source = nil
        running = false
        countdown = nil
    }

    /// Waits `seconds` (showing the countdown), then returns the current frame and stops the camera.
    func snap(after seconds: Int) async -> CGImage? {
        for left in stride(from: seconds, to: 0, by: -1) {
            countdown = left
            ToneSynth.shared.play(880, seconds: 0.08, bright: true, volume: 0.25)
            try? await Task.sleep(for: .seconds(1))
            if !running { return nil }
        }
        countdown = nil
        ToneSynth.shared.play(1320, seconds: 0.15, bright: true, volume: 0.3)
        let picture = frame
        stop()
        return picture
    }
}

/// Camera with a self-timer, or a photo from the library. `image` is the chosen picture.
struct PictureSource: View {
    @Binding var image: CGImage?
    var startFront = true
    var timer = 3
    @StateObject private var camera = CameraSnapper()
    @State private var picked: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground))
                if camera.running, let frame = camera.frame {
                    Image(decorative: frame, scale: 1).resizable().scaledToFit()
                        .scaleEffect(x: camera.front ? -1 : 1, y: 1)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                } else if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    ContentUnavailableView("No picture", systemImage: "camera", description: Text("Use the camera or choose a photo."))
                }
                if let n = camera.countdown {
                    Text("\(n)").font(.system(size: 110, weight: .heavy, design: .rounded)).foregroundStyle(.white).shadow(radius: 10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if camera.running {
                    Button { Task { if let shot = await camera.snap(after: timer) { image = shot } } } label: {
                        Label("Take picture (\(timer) s)", systemImage: "camera.shutter.button")
                    }
                    .buttonStyle(.borderedProminent).disabled(camera.countdown != nil)
                    Button("Cancel") { camera.stop() }
                } else {
                    Button { camera.front = startFront; camera.start() } label: { Label("Camera", systemImage: "camera") }
                    PhotosPicker(selection: $picked, matching: .images) { Label("Photo", systemImage: "photo") }
                }
                if camera.running {
                    Button { camera.front.toggle(); camera.start() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera") }
                }
            }
        }
        .onChange(of: picked) { _, item in
            Task { if let data = try? await item?.loadTransferable(type: Data.self), let picture = UIImage(data: data)?.uprightCGImage { image = picture } }
        }
        .onDisappear { camera.stop() }
    }
}

// MARK: - Shared pieces

/// An answer that streams in, with a copy button.
struct AnswerBox: View {
    let text: String
    let working: Bool
    var placeholder = "The answer appears here."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if text.isEmpty {
                    if working { ProgressView("Thinking… (the first answer also loads the model)") } else { Text(placeholder).foregroundStyle(.secondary) }
                } else {
                    Text(LocalizedStringKey(text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topTrailing) {
            if !text.isEmpty && !working {
                Button { UIPasteboard.general.string = text } label: { Image(systemName: "doc.on.doc") }.padding(8)
            }
        }
    }
}

// MARK: - Picture questions (outfit, fridge)

/// One picture, a few prepared questions, a streamed answer: the shape of V2 and V3.
struct PictureQuestionView: View {
    struct Preset: Identifiable {
        let title: String
        let system: String?
        let question: String
        var id: String { title }
    }

    let title: String
    let intro: String
    let presets: [Preset]
    var front = true
    var timer = 3
    var allowCustom = true
    var maxTokens = 400

    @EnvironmentObject private var studio: StudioModel
    @AppStorage("examples.vlm") private var modelID = StudioModel.defaultLanguageModel(.pictures)
    @State private var image: CGImage?
    @State private var answer = ""
    @State private var working = false
    @State private var custom = ""
    @State private var note = ""
    @State private var task: Task<Void, Never>?

    var body: some View {
        ExampleLayout(panelWidth: 380) {
            VStack(spacing: 8) {
                Text(intro).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                PictureSource(image: $image, startFront: front, timer: timer)
            }
        } panel: {
            VStack(alignment: .leading, spacing: 10) {
                LanguagePicker(use: .pictures, modelID: $modelID)
                ForEach(presets) { preset in
                    Button { ask(preset.system, preset.question) } label: { Label(preset.title, systemImage: "sparkles").frame(maxWidth: .infinity, alignment: .leading) }
                        .buttonStyle(.bordered).disabled(image == nil || working)
                }
                if allowCustom {
                    HStack {
                        TextField("Or ask your own question", text: $custom).textFieldStyle(.roundedBorder).onSubmit { ask(nil, custom) }
                        Button { ask(nil, custom) } label: { Image(systemName: "arrow.up.circle.fill") }.disabled(image == nil || working || custom.isEmpty)
                    }
                }
                if working { Button("Stop", role: .destructive) { task?.cancel() } }
                AnswerBox(text: answer, working: working).frame(minHeight: 260)
                if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 4)
        }
        .navigationTitle(title)
        .onDisappear { task?.cancel() }
    }

    private func ask(_ system: String?, _ question: String) {
        guard let image, !question.isEmpty else { return }
        answer = ""; note = ""; working = true
        task = Task {
            defer { working = false }
            do {
                let stats = try await studio.exampleStream(modelID: modelID, system: system, user: question, picture: image, maxTokens: maxTokens) { answer = $0 }
                note = stats.summary
            } catch is CancellationError {
            } catch {
                note = "\(error)"
            }
        }
    }
}

struct OutfitAdvisorExampleView: View {
    static let system = """
    You are a professional stylist. Comment on the whole outfit of the person in the picture in three sections, \
    each starting with its title in bold on its own line, in a friendly tone that gives confidence:
    **Current outfit**: 1-2 sentences on what they are wearing (pieces, colours, overall style).
    **Suggestions**: 2-3 specific, practical improvements.
    **Summary**: one encouraging sentence.
    No small talk.
    """

    var body: some View {
        PictureQuestionView(title: "Outfit advisor",
                            intro: "Stand back so your whole outfit is in the picture, then take it with the self-timer (or choose a photo).",
                            presets: [.init(title: "Rate my outfit", system: Self.system,
                                            question: "Comment on this person's outfit in the three sections: Current outfit, Suggestions, Summary."),
                                      .init(title: "What to wear with it", system: nil,
                                            question: "Suggest shoes, accessories and a jacket that would go with this outfit, and say why.")],
                            front: true, timer: 5, maxTokens: 300)
    }
}

struct FridgeChefExampleView: View {
    var body: some View {
        PictureQuestionView(title: "Fridge chef",
                            intro: "Show your ingredients (the real thing or a photo of your fridge), then ask for ideas.",
                            presets: [.init(title: "Ingredients and recipes", system: nil,
                                            question: "You are a cooking assistant. First list the ingredients you see, then suggest one or two home dishes that use them, each with short steps."),
                                      .init(title: "Just the ingredients", system: nil, question: "List all the ingredients you can see."),
                                      .init(title: "Two recipes with steps", system: nil,
                                            question: "Suggest two home dishes made with the ingredients in the picture, each with 3-4 simple steps.")],
                            front: false, timer: 3, maxTokens: 450)
    }
}

// Face report: FaceReportExample.swift (two steps, scores and a sketch).

// MARK: - Calories

struct CaloriesExampleView: View {
    @EnvironmentObject private var studio: StudioModel
    @AppStorage("examples.vlm") private var modelID = StudioModel.defaultLanguageModel(.pictures)
    @State private var image: CGImage?
    @State private var raw = ""
    @State private var items: [Nutrition.Item] = []
    @State private var working = false
    @State private var note = ""
    @State private var log = Nutrition.DailyLog.load(CaloriesExampleView.logURL)

    static var logURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("calories-today.json") }

    var body: some View {
        ExampleLayout(panelWidth: 380) {
            VStack(spacing: 8) {
                Text("Point the camera at a meal (or choose a photo). Estimates only.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                PictureSource(image: $image, startFront: false, timer: 2)
            }
        } panel: {
            VStack(alignment: .leading, spacing: 10) {
                LanguagePicker(use: .pictures, modelID: $modelID)
                Button { estimate() } label: { Label("Estimate calories", systemImage: "fork.knife") }
                    .buttonStyle(.borderedProminent).disabled(image == nil || working)
                if working { ProgressView("Looking at the food…") }
                if !items.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow { Text("Food").bold(); Text("Portion").bold(); Text("kcal").bold(); Text("Protein").bold() }
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            GridRow {
                                Text(item.item)
                                Text(item.portion).foregroundStyle(.secondary)
                                Text("\(item.kcal)").monospacedDigit()
                                Text("\(item.proteinGrams) g").monospacedDigit()
                            }
                        }
                        Divider()
                        GridRow {
                            Text("Total").bold(); Text("")
                            Text("\(Nutrition.totals(items).kcal)").bold().monospacedDigit()
                            Text("\(Nutrition.totals(items).proteinGrams) g").bold().monospacedDigit()
                        }
                    }
                    Button { log.add(items, saveTo: Self.logURL); items = [] } label: { Label("Add to today", systemImage: "plus.circle") }
                } else if !raw.isEmpty && !working {
                    Text("No food recognised. The model said:").font(.caption)
                    Text(raw).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Text("\(log.kcal)").font(.system(size: 44, weight: .bold, design: .rounded)).foregroundStyle(.orange)
                    Text("kcal today · \(log.proteinGrams) g protein · \(log.meals.count) meal\(log.meals.count == 1 ? "" : "s")").font(.callout)
                }
                ForEach(Array(log.meals.enumerated().reversed()), id: \.offset) { _, meal in
                    HStack {
                        Text(meal.time.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(meal.items.map(\.item).joined(separator: ", ")).lineLimit(1)
                        Spacer()
                        Text("\(meal.kcal) kcal").monospacedDigit()
                    }
                }
                if !log.meals.isEmpty { Button("Clear today", role: .destructive) { log.clear(saveTo: Self.logURL) } }
                if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                Text("Small models guess; treat the numbers as rough estimates. Today's list starts empty each day.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Calories")
    }

    private func estimate() {
        guard let image else { return }
        raw = ""; items = []; note = ""; working = true
        Task {
            defer { working = false }
            do {
                let stats = try await studio.exampleStream(modelID: modelID, system: nil, user: Nutrition.prompt, picture: image, maxTokens: 260, temperature: 0.15) { raw = $0 }
                items = Nutrition.parseItems(raw)
                note = stats.summary
            } catch {
                note = "\(error)"
            }
        }
    }
}

// MARK: - OfflineCode

/// Runs JavaScript in a throwaway web view: no network (content security policy), no files, and the
/// whole page is discarded after `timeout` seconds if it has not finished.
@MainActor
final class JavaScriptRunner: NSObject, WKNavigationDelegate {
    struct Result { var output: String; var error: String?; var seconds: Double; var timedOut: Bool }

    private var webView: WKWebView?
    private var loaded: CheckedContinuation<Void, Never>?

    func run(_ code: String, timeout: Double = 10) async -> Result {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        webView = view
        await withCheckedContinuation { continuation in
            loaded = continuation
            view.loadHTMLString("""
            <html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'"></head><body></body></html>
            """, baseURL: nil)
        }
        let started = Date()
        let wrapper = """
        const lines = [];
        const show = (...a) => lines.push(a.map(x => typeof x === 'string' ? x : JSON.stringify(x)).join(' '));
        console.log = show; console.info = show; console.warn = show; console.error = show;
        try {
            const result = await (new Function('return (async () => {\\n' + code + '\\n})()'))();
            if (result !== undefined) show(result);
            return { out: lines.join('\\n'), err: null };
        } catch (e) {
            return { out: lines.join('\\n'), err: String(e) };
        }
        """
        let outcome: Result = await withCheckedContinuation { continuation in
            var finished = false
            let finish: (Result) -> Void = { result in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: result)
            }
            view.callAsyncJavaScript(wrapper, arguments: ["code": code], in: nil, in: .defaultClient) { result in
                let seconds = Date().timeIntervalSince(started)
                switch result {
                case .success(let value):
                    let dictionary = value as? [String: Any]
                    finish(Result(output: dictionary?["out"] as? String ?? "", error: dictionary?["err"] as? String, seconds: seconds, timedOut: false))
                case .failure(let error):
                    finish(Result(output: "", error: error.localizedDescription, seconds: seconds, timedOut: false))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                finish(Result(output: "", error: "Stopped after \(Int(timeout)) seconds.", seconds: timeout, timedOut: true))
            }
        }
        // Throw the page (and its process) away every time.
        view.stopLoading()
        view.navigationDelegate = nil
        webView = nil
        return outcome
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in loaded?.resume(); loaded = nil }
    }
}

struct OfflineCodeExampleView: View {
    @EnvironmentObject private var studio: StudioModel
    @AppStorage("examples.coder") private var modelID = StudioModel.defaultLanguageModel(.code)
    @State private var request = ""
    @State private var answer = ""
    @State private var working = false
    @State private var output = ""
    @State private var runInfo = ""
    @State private var running = false
    @State private var runner = JavaScriptRunner()
    @State private var note = ""
    @State private var task: Task<Void, Never>?

    static let system = """
    You are a coding assistant on a phone. Write programs in JavaScript: they run in this app, print with console.log, \
    and have no network, no files and no browser page. Give one complete code block in ```javascript, then at most \
    three short sentences of explanation. If the user asks for another language, show it, but also give a JavaScript version that runs.
    """

    private var code: (language: String, code: String)? { CodeBlocks.last(answer) }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                LanguagePicker(use: .code, modelID: $modelID)
                Spacer()
                if working { Button("Stop", role: .destructive) { task?.cancel() } }
            }
            .padding(.horizontal)
            HStack {
                TextField("What should the program do? e.g. the first 20 prime numbers", text: $request, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4).onSubmit(ask)
                Button(action: ask) { Image(systemName: "arrow.up.circle.fill").font(.title2) }.disabled(request.isEmpty || working)
            }
            .padding(.horizontal)
            ExampleLayout(panelWidth: 420) {
                AnswerBox(text: CodeBlocks.textOnly(answer), working: working, placeholder: "Ask for a small program. The model writes JavaScript, which you can run here.")
            } panel: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(code.map { $0.language.capitalized } ?? "Code").font(.headline)
                        Spacer()
                        if let code {
                            Button { UIPasteboard.general.string = code.code } label: { Label("Copy", systemImage: "doc.on.doc") }
                            Button { run() } label: { Label("Run", systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent).disabled(running || working || code.language != "javascript")
                        }
                    }
                    ScrollView([.vertical, .horizontal]) {
                        Text(code?.code ?? "").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    .frame(minHeight: 200)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                    if let code, code.language != "javascript" {
                        Text("Only JavaScript runs on this \(StudioModel.deviceKind); \(code.language) code can be copied.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Output").font(.headline)
                    ScrollView {
                        Text(output.isEmpty ? (running ? "Running…" : " ") : output).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    .frame(minHeight: 120)
                    .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.green)
                    if !runInfo.isEmpty { Text(runInfo).font(.caption).foregroundStyle(.secondary) }
                    Text("The code runs in an isolated page: no internet, no files, stopped after 10 seconds.").font(.caption2).foregroundStyle(.secondary)
                    if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("Offline code")
        .task {
            // `-jstest`: checks the sandbox from the Mac (output, error, endless loop, network) and writes
            // Documents/js-test.txt.
            guard CommandLine.arguments.contains("-jstest") else { return }
            var lines: [String] = []
            for (name, code) in [("print", "for (let i = 0; i < 3; i++) console.log('line', i); return 6 * 7"),
                                 ("error", "null.x"),
                                 ("loop", "while (true) {}"),
                                 ("network", "const r = await fetch('https://example.com'); console.log(r.status)")] {
                let r = await runner.run(code, timeout: name == "loop" ? 3 : 10)
                lines.append("\(name): out=\(r.output.debugDescription) err=\(r.error ?? "nil") timedOut=\(r.timedOut) s=\(String(format: "%.2f", r.seconds))")
            }
            let after = await runner.run("console.log('still works')")
            lines.append("after: out=\(after.output.debugDescription) err=\(after.error ?? "nil")")
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("js-test.txt")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func ask() {
        guard !request.isEmpty, !working else { return }
        answer = ""; output = ""; runInfo = ""; note = ""; working = true
        let question = request
        task = Task {
            defer { working = false }
            do {
                let stats = try await studio.exampleStream(modelID: modelID, system: Self.system, user: question, maxTokens: 700, temperature: 0.2) { answer = $0 }
                note = stats.summary
            } catch is CancellationError {
            } catch {
                note = "\(error)"
            }
        }
    }

    private func run() {
        guard let code, code.language == "javascript" else { return }
        running = true; output = ""; runInfo = ""
        Task {
            let result = await runner.run(code.code)
            output = result.output + (result.error.map { (result.output.isEmpty ? "" : "\n") + "Error: \($0)" } ?? "")
            runInfo = result.timedOut ? "Stopped: took longer than 10 s." : String(format: "Finished in %.2f s.", result.seconds)
            running = false
        }
    }
}

// MARK: - Meeting notes

struct MeetingNotesExampleView: View {
    @EnvironmentObject private var studio: StudioModel
    @AppStorage("examples.notesModel") private var modelID = StudioModel.defaultLanguageModel(.chat)
    @State private var recorder: AVAudioRecorder?
    @State private var recordingSince: Date?
    @State private var importing = false
    @State private var transcript = ""
    @State private var summary = ""
    @State private var stage = ""
    @State private var working = false

    private var recordingURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("meeting.wav") }

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                if let since = recordingSince {
                    Button(role: .destructive) { stopRecording() } label: { Label("Stop", systemImage: "stop.circle.fill") }.buttonStyle(.borderedProminent)
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(Duration.seconds(context.date.timeIntervalSince(since)).formatted(.time(pattern: .minuteSecond))).monospacedDigit()
                    }
                } else {
                    Button { startRecording() } label: { Label("Record a meeting", systemImage: "mic.circle.fill") }.buttonStyle(.borderedProminent).disabled(working)
                    Button { importing = true } label: { Label("Audio file", systemImage: "waveform") }.disabled(working)
                    Button("Sample") { if let url = Bundle.main.url(forResource: "speech_sample", withExtension: "wav") { process(url) } }.disabled(working)
                }
                LanguagePicker(use: .chat, modelID: $modelID).fixedSize()
            }
            .fixedSize()
            .padding(.horizontal)
            }
            if !stage.isEmpty { Text(stage).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal) }
            ExampleLayout(panelWidth: 400) {
                VStack(alignment: .leading) {
                    Text("Transcript").font(.headline)
                    AnswerBox(text: transcript, working: working && summary.isEmpty && transcript.isEmpty, placeholder: "Record a meeting or choose an audio file. Speech is turned into text with Whisper \(StudioModel.examplesRunOn).")
                }
            } panel: {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Notes").font(.headline)
                        Spacer()
                        if !summary.isEmpty { ShareLink(item: summary + "\n\n---\nTranscript:\n" + transcript) { Label("Share", systemImage: "square.and.arrow.up") } }
                    }
                    AnswerBox(text: summary, working: working && !transcript.isEmpty, placeholder: "Key points, action items and decisions appear here.")
                        .frame(minHeight: 320)
                    Text("Nothing leaves this \(StudioModel.deviceKind) (the models run \(StudioModel.examplesRunOn)). Names and facts not said in the meeting are not invented (\"Not mentioned\").").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Meeting notes")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-import.\(url.pathExtension)")
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.copyItem(at: url, to: copy)
            if access { url.stopAccessingSecurityScopedResource() }
            process(copy)
        }
        .onDisappear { recorder?.stop() }
    }

    private func startRecording() {
        Task {
            guard await AVAudioApplication.requestRecordPermission() else { stage = "Microphone access is off (Settings > Apps > \(ExampleApp.name))."; return }
            do {
                try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
                try AVAudioSession.sharedInstance().setActive(true)
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                               AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
                let newRecorder = try AVAudioRecorder(url: recordingURL, settings: settings)
                guard newRecorder.record() else { throw StudioError.invalidInput("Recording could not start.") }
                recorder = newRecorder
                recordingSince = Date()
                UIApplication.shared.isIdleTimerDisabled = true
                transcript = ""; summary = ""; stage = "Recording… keep the app open."
            } catch {
                stage = "\(error)"
            }
        }
    }

    private func stopRecording() {
        recorder?.stop()
        recorder = nil
        recordingSince = nil
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false)
        process(recordingURL)
    }

    private func process(_ url: URL) {
        working = true; transcript = ""; summary = ""
        Task {
            defer { working = false }
            do {
                stage = "Turning speech into text…"
                let samples = try AudioLoader.samples(from: url)
                guard samples.count > 8_000 else { throw StudioError.invalidInput("The recording is too short.") }
                transcript = try await studio.exampleTranscribe(samples)
                guard !transcript.isEmpty else { throw StudioError.invalidInput("No speech was found in the recording.") }
                // Like the demo: if the notes do not have the three sections, try once more.
                for attempt in 1...2 {
                    stage = attempt == 1 ? "Writing the notes…" : "The first notes were not in the right format; trying again…"
                    let stats = try await studio.exampleStream(modelID: modelID, system: MeetingNotes.system, user: MeetingNotes.userMessage(transcript),
                                                               maxTokens: 500, temperature: attempt == 1 ? 0.2 : 0.5) { summary = $0 }
                    stage = String(format: "%.0f s of audio · notes by %@", Double(samples.count) / 16_000, stats.model)
                    if MeetingNotes.looksValid(summary) { break }
                }
            } catch {
                stage = "\(error)"
            }
        }
    }
}
