import AVFoundation
import SwiftUI
import StudioCore
import UniformTypeIdentifiers
import WhisperKit

/// Speech to text with Whisper on this device: record with the microphone, open an audio file, or try
/// a bundled sample (six languages, SpeechSamples.swift). The audio used is shown in a player.
struct SpeechView: View {
    @EnvironmentObject private var studio: StudioModel
    @Environment(\.horizontalSizeClass) private var widthClass
    @AppStorage("speech.translate") private var translate = false
    @AppStorage("speech.language") private var language = ""
    @AppStorage("speech.model") private var variant = SpeechView.defaultModel
    @State private var segments: [SpeechSegment] = []
    @State private var note = ""
    @State private var info = ""
    @State private var working = false
    @State private var recorder: AVAudioRecorder?
    @State private var recordingSince: Date?
    @State private var choosingFile = false
    @StateObject private var clip = AudioClip()

    /// Whisper base: the size Hailo Studio runs on the stick, quick to download (about 140 MB). Larger
    /// ones (small, large-v3 turbo) are in the picker; WhisperKit's own recommendation is marked there.
    static var defaultModel: String {
        let supported = StudioModel.whisperModels.supported
        return supported.first { $0 == "openai_whisper-base" } ?? StudioModel.whisperModels.recommended
    }

    private var recordingURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("artelico-recording.wav") }
    private var transcript: String { segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces) }
    private var narrow: Bool { widthClass == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            modelRow
            if narrow {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { actionButtons }
                    optionControls
                }
            } else {
                HStack { actionButtons; optionControls; Spacer() }
            }
            AudioClipView(clip: clip)
            if let progress = studio.speechProgress {
                ProgressView(value: progress) { Text("Downloading \(variant)…").font(.caption) }
            }
            if !info.isEmpty { Text(info).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            if !note.isEmpty { Text(note).font(.callout).foregroundStyle(.red) }

            List {
                if segments.isEmpty {
                    Text("Record something or open an audio file. Whisper runs on this \(StudioModel.deviceKind); the audio never leaves it.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%.1f – %.1f s", segment.start, segment.end)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(segment.text.trimmingCharacters(in: .whitespaces)).textSelection(.enabled)
                    }
                }
            }
            .listStyle(.plain)
        }
        .padding()
        .navigationTitle("Speech to text")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !transcript.isEmpty { ShareLink(item: transcript) { Label("Share text", systemImage: "square.and.arrow.up") } }
            }
        }
        .onAppear {
            // `-speechmodel <name>` picks the Whisper model (testing from the Mac).
            if let index = CommandLine.arguments.firstIndex(of: "-speechmodel"), index + 1 < CommandLine.arguments.count {
                variant = CommandLine.arguments[index + 1]
            }
            if !StudioModel.whisperModels.supported.contains(variant) { variant = Self.defaultModel }
            // `-autospeech` transcribes a bundled sample at launch (used when testing from the Mac).
            // `-speechsample <file>` picks which sample (for example assis_pt.mp3).
            if CommandLine.arguments.contains("-autospeech"), !working {
                let arguments = CommandLine.arguments
                let wanted = arguments.firstIndex(of: "-speechsample").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
                transcribeSample(SpeechSample.all.first { $0.file == wanted } ?? SpeechSample.all[0])
            }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.audio, .movie]) { result in
            guard case .success(let url) = result else { return }
            // A copy, so the player can keep it after the file's access ends.
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("artelico-audio-" + url.lastPathComponent)
            try? FileManager.default.removeItem(at: copy)
            do { try FileManager.default.copyItem(at: url, to: copy) } catch { note = "\(error.localizedDescription)"; return }
            clip.use(copy, caption: url.lastPathComponent, play: true)
            note = "Press Transcribe to turn it into text."
        }
    }

    private var modelRow: some View {
        HStack {
            Picker("Model", selection: $variant) {
                ForEach(StudioModel.whisperModels.supported, id: \.self) { name in
                    Text(label(for: name)).tag(name)
                }
            }
            .pickerStyle(.menu)
            .disabled(working || recorder != nil)
            if studio.whisperModel == variant {
                Label("Loaded", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            }
            Spacer()
        }
    }

    private func label(for name: String) -> String {
        var text = name
        if name == StudioModel.whisperModels.recommended { text += " (recommended)" }
        if studio.isWhisperDownloaded(name) { text += " ✓" }
        return text
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button(recorder == nil ? "Record" : "Stop") { recorder == nil ? startRecording() : stopRecording() }
            .buttonStyle(.borderedProminent)
            .tint(recorder == nil ? .accentColor : .red)
            .disabled(working)
        Button("Open file") { choosingFile = true }.disabled(working || recorder != nil)
        SpeechSampleMenu(chosen: clip.sample) { useSample($0) }.disabled(working || recorder != nil)
        // A sample or a file waits for this: choosing one only shows it in the player.
        Button("Transcribe") { if let url = clip.url { transcribe(url) {} } }
            .disabled(working || recorder != nil || clip.url == nil)
        if let recordingSince {
            TimelineView(.periodic(from: recordingSince, by: 0.5)) { context in
                Label(String(format: "%.0f s", context.date.timeIntervalSince(recordingSince)), systemImage: "record.circle.fill").foregroundStyle(.red)
            }
        }
        if working { ProgressView() }
    }

    @ViewBuilder
    private var optionControls: some View {
        Toggle("Translate to English", isOn: $translate).fixedSize()
        TextField("Language code (blank = detect)", text: $language)
            .textFieldStyle(.roundedBorder).frame(maxWidth: 230)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
    }

    /// A spoken sample shipped with the app: it sets the language and plays. Transcribe turns it into text, so
    /// choosing a sample never loads or downloads a model. (`transcribeSample` does both, for `-autospeech`.)
    private func useSample(_ sample: SpeechSample) {
        guard let url = sample.url else { return }
        language = sample.language
        clip.use(url, caption: sample.title, sample: sample, play: true)
        note = "Press Transcribe to turn it into text."
    }

    private func transcribeSample(_ sample: SpeechSample = SpeechSample.all[0]) {
        useSample(sample)
        if let url = sample.url { transcribe(url) {} }
    }

    private func startRecording() {
        note = ""
        clip.pause()
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                note = "Microphone access is off. Allow it in Settings > Apps > Artelico."
                return
            }
            do {
                try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
                try AVAudioSession.sharedInstance().setActive(true)
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                               AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
                let newRecorder = try AVAudioRecorder(url: recordingURL, settings: settings)
                guard newRecorder.record() else { throw StudioError.invalidInput("Recording could not start.") }
                recorder = newRecorder
                recordingSince = Date()
            } catch {
                note = "\(error.localizedDescription)"
            }
        }
    }

    private func stopRecording() {
        let seconds = recordingSince.map { Date().timeIntervalSince($0) } ?? 0
        recorder?.stop()
        recorder = nil
        recordingSince = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        clip.use(recordingURL, caption: String(format: "Your recording (%.0f s)", seconds), play: false)
        transcribe(recordingURL) {}
    }

    private func transcribe(_ url: URL, done: @escaping () -> Void) {
        working = true
        note = ""
        info = ""
        let wantedLanguage = language.trimmingCharacters(in: .whitespaces).lowercased()
        let options = DecodingOptions(task: translate ? .translate : .transcribe,
                                      language: wantedLanguage.isEmpty ? nil : wantedLanguage,
                                      detectLanguage: wantedLanguage.isEmpty)
        let chosen = variant
        Task {
            defer { working = false; done() }
            do {
                let samples = try AudioLoader.samples(from: url)
                let duration = Double(samples.count) / Double(AudioLoader.sampleRate)
                guard duration > 0.2 else { throw StudioError.invalidInput("The recording is too short.") }
                let clock = ContinuousClock()
                var mark = clock.now
                let kit = try await studio.whisperKit(chosen)
                let loadSeconds = seconds(clock.now - mark)
                mark = clock.now
                let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
                let transcribeSeconds = seconds(clock.now - mark)
                segments = results.flatMap(\.segments).map {
                    SpeechSegment(start: $0.start, end: $0.end, text: Self.cleaned($0.text))
                }
                let detected = results.first?.language ?? "?"
                info = String(format: "%.1f s of audio transcribed in %.2f s with %@ (language: %@; model ready in %.1f s)",
                              duration, transcribeSeconds, chosen, detected, loadSeconds)
                saveForTesting()
            } catch {
                note = "\(error)"
                info = ""
                saveForTesting()
            }
        }
    }

    /// Whisper's text carries special tokens such as <|startoftranscript|>; keep only the words.
    private static func cleaned(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Writes the last result to Documents/speech-result.txt so it can be read from the Mac
    /// (`devicectl device copy from`) without a screenshot.
    private func saveForTesting() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let text = [info, note, transcript].filter { !$0.isEmpty }.joined(separator: "\n")
        try? text.write(to: documents.appendingPathComponent("speech-result.txt"), atomically: true, encoding: .utf8)
    }
}
