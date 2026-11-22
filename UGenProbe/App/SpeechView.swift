import AVFoundation
import SwiftUI
import UGenKit
import UniformTypeIdentifiers

/// Speech to text with Whisper on the stick: record with the microphone, open an audio file, or try a
/// bundled sample (six languages, SpeechSamples.swift). The audio used is shown in a player.
struct SpeechView: View {
    @EnvironmentObject private var studio: StudioModel
    @AppStorage("speech.translate") private var translate = false
    @AppStorage("speech.language") private var language = ""
    @State private var segments: [SpeechToText.Segment] = []
    @State private var note = ""
    @State private var info = ""
    @State private var working = false
    @State private var recorder: AVAudioRecorder?
    @State private var recordingSince: Date?
    @State private var choosingFile = false
    @StateObject private var clip = AudioClip()

    private var recordingURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("hailo-studio-recording.wav") }
    private var transcript: String { segments.map(\.text).joined().trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(recorder == nil ? "Record" : "Stop and transcribe") { recorder == nil ? startRecording() : stopRecording() }
                    .buttonStyle(.borderedProminent)
                    .tint(recorder == nil ? .accentColor : .red)
                    .disabled(working)
                Button("Open audio file") { choosingFile = true }.disabled(working || recorder != nil)
                SpeechSampleMenu(chosen: clip.sample) { useSample($0) }.disabled(working || recorder != nil)
                // A sample or a file waits for this: choosing one only shows it in the player.
                Button("Transcribe") { if let url = clip.url { transcribe(url) {} } }
                    .disabled(working || recorder != nil || clip.url == nil)
                Toggle("Translate to English", isOn: $translate).fixedSize()
                TextField("Language code (blank = detect)", text: $language)
                    .textFieldStyle(.roundedBorder).frame(width: 230)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Spacer()
                if let recordingSince {
                    TimelineView(.periodic(from: recordingSince, by: 0.5)) { context in
                        Label(String(format: "%.0f s", context.date.timeIntervalSince(recordingSince)), systemImage: "record.circle.fill").foregroundStyle(.red)
                    }
                }
                if working { ProgressView() }
            }
            AudioClipView(clip: clip)
            if !info.isEmpty { Text(info).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            if !note.isEmpty { Text(note).font(.callout).foregroundStyle(.red) }

            List {
                if segments.isEmpty {
                    Text("Record something or open an audio file. The audio is sent to the stick and never leaves the \(StudioModel.deviceKind).").foregroundStyle(.secondary)
                }
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    HStack(alignment: .top) {
                        Text(String(format: "%5.1f – %5.1f", segment.start, segment.end)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        Text(segment.text.trimmingCharacters(in: .whitespaces)).textSelection(.enabled)
                    }
                }
            }
        }
        .padding()
        .navigationTitle("Speech to text")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !transcript.isEmpty { ShareLink(item: transcript) { Label("Share text", systemImage: "square.and.arrow.up") } }
            }
        }
        .onAppear {
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
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("hailo-studio-audio-" + url.lastPathComponent)
            try? FileManager.default.removeItem(at: copy)
            do { try FileManager.default.copyItem(at: url, to: copy) } catch { note = "\(error.localizedDescription)"; return }
            clip.use(copy, caption: url.lastPathComponent, play: true)
            note = "Press Transcribe to turn it into text."
        }
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
                note = "Microphone access is off. Allow it in Settings > Apps > Hailo Studio."
                return
            }
            do {
                try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
                try AVAudioSession.sharedInstance().setActive(true)
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                               AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
                let newRecorder = try AVAudioRecorder(url: recordingURL, settings: settings)
                guard newRecorder.record() else { throw UGenError.invalidInput("Recording could not start.") }
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
        let task: SpeechTask = translate ? .translate : .transcribe
        Task {
            defer { working = false; done() }
            do {
                let samples = try AudioLoader.samples(from: url)
                let duration = Double(samples.count) / Double(SpeechToText.sampleRate)
                guard duration > 0.2 else { throw UGenError.invalidInput("The recording is too short.") }
                let model = try await studio.speech()
                let clock = ContinuousClock()
                let start = clock.now
                segments = try await model.transcribe(samples: samples, task: task, language: wantedLanguage.isEmpty ? nil : wantedLanguage,
                                                      timeout: .seconds(max(120, Int(duration))))
                let elapsed = clock.now - start
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                info = String(format: "%.1f s of audio transcribed in %.1f s", duration, seconds)
            } catch {
                studio.fail(error)
                note = "\(error)"
            }
        }
    }
}
