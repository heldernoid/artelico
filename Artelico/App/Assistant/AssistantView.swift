import AVFoundation
import SwiftUI
import WhisperKit

/// One request to the assistant and what happened to it.
struct AssistantTurn: Identifiable {
    let id = UUID()
    var request: String
    var tool = ""
    var score: Float = 0
    var scores: [(String, Float)] = []
    var parameters = ""
    var answer = ""
    var timings: [(String, Double)] = []
    var failed = false
}

/// The voice assistant pipeline, after hailo-apps' Voice-to-Action demo, all on this device:
/// speech (Whisper) -> tool choice (MiniLM embeddings) -> parameters (GGUF language model, JSON) ->
/// the tool -> the answer spoken (Apple's speech synthesis).
@MainActor
final class AssistantEngine: ObservableObject {
    enum Stage: String { case idle = "Ready", listening = "Listening…", transcribing = "Transcribing…", choosing = "Choosing a tool…",
                          extracting = "Reading the details…", running = "Working…", speaking = "Speaking…" }

    @Published var stage: Stage = .idle
    @Published var turns: [AssistantTurn] = []
    @Published var note = ""
    private var selector: ToolSelector?
    private var recorder: AVAudioRecorder?
    private let speaker = AVSpeechSynthesizer()
    private var recordingURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("assistant-request.wav") }

    var busy: Bool { stage != .idle && stage != .listening }

    func startListening() {
        note = ""
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                note = "Microphone access is off. Allow it in Settings > Apps > Artelico."
                return
            }
            do {
                speaker.stopSpeaking(at: .immediate)
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                try AVAudioSession.sharedInstance().setActive(true)
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                               AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
                let newRecorder = try AVAudioRecorder(url: recordingURL, settings: settings)
                guard newRecorder.record() else { throw CocoaError(.fileWriteUnknown) }
                recorder = newRecorder
                stage = .listening
            } catch {
                note = "Recording could not start: \(error.localizedDescription)"
            }
        }
    }

    func stopListening(studio: StudioModel, whisperModel: String, speak: Bool) {
        recorder?.stop()
        recorder = nil
        Task { await handleRecording(studio: studio, whisperModel: whisperModel, speak: speak) }
    }

    private func handleRecording(studio: StudioModel, whisperModel: String, speak: Bool) async {
        stage = .transcribing
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let samples = try AudioLoader.samples(from: recordingURL)
            guard Double(samples.count) / Double(AudioLoader.sampleRate) > 0.3 else { stage = .idle; note = "That was too short."; return }
            let kit = try await studio.whisperKit(whisperModel)
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: DecodingOptions(task: .transcribe))
            let text = results.flatMap(\.segments).map(\.text).joined(separator: " ")
                .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { stage = .idle; note = "I didn't catch that."; return }
            await handle(text, studio: studio, speak: speak, transcribeSeconds: seconds(clock.now - start))
        } catch {
            stage = .idle
            note = "\(error)"
        }
    }

    /// Runs a request (spoken or typed) through tool choice, parameters and the tool.
    func handle(_ request: String, studio: StudioModel, speak: Bool, transcribeSeconds: Double? = nil) async {
        var turn = AssistantTurn(request: request)
        if let transcribeSeconds { turn.timings.append(("speech to text", transcribeSeconds)) }
        turns.insert(turn, at: 0)
        func update() { if let index = turns.firstIndex(where: { $0.id == turn.id }) { turns[index] = turn } }
        let clock = ContinuousClock()
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        do {
            stage = .choosing
            var mark = clock.now
            if selector == nil {
                let created = try await ToolSelector(folder: StudioModel.modelsDirectory)
                try await created.prepare(AssistantTools.all)
                selector = created
            }
            let choice = try await selector!.select(request, tools: AssistantTools.all)
            turn.tool = choice.tool
            turn.score = choice.score
            turn.scores = choice.scores
            turn.timings.append(("tool choice", seconds(clock.now - mark)))
            update()

            let tool = AssistantTools.all.first { $0.name == choice.tool } ?? AssistantTools.none
            var parameters: [String: Any] = [:]
            if let prompt = tool.prompt {
                stage = .extracting
                mark = clock.now
                parameters = try await extract(request, prompt: prompt, studio: studio)
                turn.parameters = (try? String(data: JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys]), encoding: .utf8)) ?? ""
                turn.timings.append(("details", seconds(clock.now - mark)))
                update()
            }

            stage = .running
            mark = clock.now
            turn.answer = try await tool.run(parameters, AssistantContext(studio: studio, request: request))
            turn.timings.append((tool.title.lowercased(), seconds(clock.now - mark)))
            update()
        } catch {
            turn.answer = "Something went wrong: \(error)"
            turn.failed = true
            update()
        }
        saveForTesting(turn)
        if speak, !turn.answer.isEmpty {
            stage = .speaking
            let utterance = AVSpeechUtterance(string: turn.answer)
            utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier == "en" ? Locale.current.identifier.replacingOccurrences(of: "_", with: "-") : "en-US")
            speaker.speak(utterance)
            while speaker.isSpeaking { try? await Task.sleep(for: .milliseconds(200)) }
        }
        stage = .idle
    }

    /// Asks the language model for the tool's parameters as JSON (deterministic, short).
    private func extract(_ request: String, prompt: String, studio: StudioModel) async throws -> [String: Any] {
        guard let model = studio.assistantModel else { return [:] }
        let llm = try await studio.languageModel(model, keepSpeech: true)
        var parameters = LlamaEngine.Parameters()
        parameters.temperature = 0
        parameters.maxTokens = 120
        let box = TextBox()
        let today = DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .none)
        _ = try await llm.generate([
            .init(role: "system", content: prompt + "\nToday is \(today)."),
            .init(role: "user", content: request + (model.title.hasPrefix("Qwen3") ? " /no_think" : "")),
        ], parameters: parameters) { box.append($0) }
        let text = visibleAnswer(box.text)
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"),
              let data = String(text[open...close]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Writes the last turn to Documents/assistant-result.txt (read from the Mac without a screenshot).
    private func saveForTesting(_ turn: AssistantTurn) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let lines = ["request: \(turn.request)", String(format: "tool: %@ (similarity %.2f)", turn.tool, turn.score),
                     "parameters: \(turn.parameters)", "answer: \(turn.answer)",
                     "timings: " + turn.timings.map { String(format: "%@ %.2f s", $0.0, $0.1) }.joined(separator: ", ")]
        try? lines.joined(separator: "\n").write(to: documents.appendingPathComponent("assistant-result.txt"), atomically: true, encoding: .utf8)
    }
}

/// The voice assistant screen.
struct AssistantView: View {
    @EnvironmentObject private var studio: StudioModel
    @StateObject private var engine = AssistantEngine()
    @AppStorage("assistant.speak") private var speak = true
    @AppStorage("assistant.whisper") private var whisperModel = "openai_whisper-base"
    @AppStorage("assistant.model") private var modelID = GGUFModel.catalog[0].id
    @AppStorage("assistant.home") private var home = ""
    @AppStorage("assistant.work") private var work = ""
    @AppStorage("assistant.searxng") private var searxng = ""
    @State private var typed = ""
    @State private var showSettings = false

    private let examples = ["What's the weather in Lisbon tomorrow?", "How long to drive to the airport?", "Turn on the torch",
                            "Search the web for the Hailo-10H", "Remember Ana's phone is 912 345 678", "What's Ana's phone?",
                            "Set a timer for five minutes", "What can you do?"]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if engine.turns.isEmpty { intro }
                    ForEach(engine.turns) { turn in TurnCard(turn: turn) }
                }
                .padding()
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            if !engine.note.isEmpty { Text(engine.note).font(.callout).foregroundStyle(.red).padding(.horizontal) }
            controls
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: { Label("Settings", systemImage: "slider.horizontal.3") }
            }
        }
        .sheet(isPresented: $showSettings) { settings }
        .onAppear {
            // `-assistant "<request>"` runs one typed request at launch (testing from the Mac).
            let arguments = CommandLine.arguments
            if let index = arguments.firstIndex(of: "-assistant"), index + 1 < arguments.count, engine.turns.isEmpty {
                let request = arguments[index + 1]
                Task { await engine.handle(request, studio: studio, speak: speak) }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voice assistant").font(.title2.weight(.semibold))
            Text("Tap the microphone and ask. Whisper turns your voice into text, MiniLM picks the tool, \(studio.assistantModel?.title ?? "the language model") fills in the details, and the answer is spoken. Everything runs on this \(StudioModel.deviceKind); only weather, routes and web searches go online.")
                .font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 8) {
                ForEach(examples, id: \.self) { example in
                    Button { Task { await engine.handle(example, studio: studio, speak: speak) } } label: {
                        Text(example).font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(engine.busy)
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Text(engine.stage.rawValue).font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                TextField("Or type a request", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
                    .disabled(engine.busy || engine.stage == .listening)
                Button {
                    engine.stage == .listening ? engine.stopListening(studio: studio, whisperModel: whisperModel, speak: speak) : engine.startListening()
                } label: {
                    Image(systemName: engine.stage == .listening ? "stop.fill" : "mic.fill")
                        .font(.title2).frame(width: 56, height: 56)
                        .foregroundStyle(.white)
                        .background(engine.stage == .listening ? Color.red : Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(engine.busy)
            }
        }
        .padding()
        .background(.bar)
    }

    private func send() {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typed = ""
        Task { await engine.handle(text, studio: studio, speak: speak) }
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("Models") {
                    Picker("Language model", selection: $modelID) {
                        ForEach(studio.languageModels.filter { $0.purpose == .chat }) { Text($0.title).tag($0.id) }
                    }
                    Picker("Speech model", selection: $whisperModel) {
                        ForEach(StudioModel.whisperModels.supported, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Speak the answers", isOn: $speak)
                }
                Section {
                    TextField("Home address", text: $home)
                    TextField("Work address", text: $work)
                } header: { Text("Places") } footer: { Text("Used for \"from home\" and \"to work\". Routes come from Apple Maps.") }
                Section {
                    TextField("https://searx.example.org", text: $searxng)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                } header: { Text("Web search") } footer: {
                    Text("Leave empty to search DuckDuckGo and Wikipedia directly. With your own SearXNG server (JSON output enabled), searches go there instead.")
                }
                Section("Privacy") {
                    Text("Speech, tool choice and answers stay on this \(StudioModel.deviceKind). The weather tool sends the city name to Open-Meteo, routes go to Apple Maps, and web searches go to the search service above.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Assistant settings")
            .toolbar { Button("Done") { showSettings = false } }
        }
    }
}

private struct TurnCard: View {
    let turn: AssistantTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.request).font(.callout.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .trailing)
            if !turn.tool.isEmpty {
                HStack(spacing: 6) {
                    Chip(text: turn.tool, systemImage: "wrench.and.screwdriver")
                    Chip(text: String(format: "similarity %.2f", turn.score), systemImage: "point.3.connected.trianglepath.dotted")
                }
                if !turn.parameters.isEmpty { Text(turn.parameters).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            if turn.answer.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                Text(turn.answer).foregroundStyle(turn.failed ? .red : .primary).textSelection(.enabled)
            }
            if !turn.timings.isEmpty {
                Text(turn.timings.map { String(format: "%@ %.2f s", $0.0, $0.1) }.joined(separator: " · "))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
