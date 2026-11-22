import AVFoundation
import SwiftUI
import UGenKit
import UniformTypeIdentifiers

/// Speech to text with Whisper on the stick: record with the microphone or open an audio file.
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
                Button("Try the sample") { transcribeSample() }.disabled(working || recorder != nil)
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
            // `-autospeech` transcribes the bundled sample at launch (used when testing from the Mac).
            if CommandLine.arguments.contains("-autospeech"), !working { transcribeSample() }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.audio, .movie]) { result in
            guard case .success(let url) = result else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            transcribe(url) { if accessed { url.stopAccessingSecurityScopedResource() } }
        }
    }

    /// A short spoken sentence shipped with the app, for trying speech to text without recording.
    private func transcribeSample() {
        guard let url = Bundle.main.url(forResource: "speech_sample", withExtension: "wav") else { return }
        transcribe(url) {}
    }

    private func startRecording() {
        note = ""
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
        recorder?.stop()
        recorder = nil
        recordingSince = nil
        try? AVAudioSession.sharedInstance().setActive(false)
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
