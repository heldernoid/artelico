import SwiftUI
import StudioCore

/// FaceCheckIn (UGen300 demo): enrol a face in a few seconds, then people check in just by being seen.
/// Only the identity vector is kept (in the app's face list, shared with the Photos and Live face
/// task); no picture of anyone is stored.
struct FaceCheckInExampleView: View {
    enum Enrolment: Equatable {
        case idle
        case naming
        case countdown(until: Double)
        case sampling(since: Double, box: CGRect?)
    }

    @EnvironmentObject private var studio: StudioModel
    @StateObject private var runner = PoseRunner(task: .face, source: .front)
    @AppStorage("checkin.threshold") private var threshold = 0.45
    @AppStorage("checkin.showScores") private var showScores = false
    @State private var book = CheckInBook()
    @State private var labels: [(name: String?, score: Float?)] = []
    @State private var enrolment = Enrolment.idle
    @State private var enrolName = ""
    @State private var samples: [[Float]] = []
    @State private var frameCount = 0
    @State private var banner: String?
    @State private var now = 0.0
    @State private var enrollingPhotos = false
    private static let testing = CommandLine.arguments.contains("-enrolfolder")
    /// Photos or a folder given with `-enrolfolder <path>` (testing from the Mac), enrolled once the models are loaded.
    @State private var testFolder = CommandLine.arguments.firstIndex(of: "-enrolfolder").flatMap { index in
        index + 1 < CommandLine.arguments.count ? URL(fileURLWithPath: CommandLine.arguments[index + 1]) : nil
    }

    var body: some View {
        VStack(spacing: 10) {
            PoseControls(runner: runner, sources: [.front, .back, .video], samples: [SampleMedia.face], start: start)
            ExampleLayout(panelWidth: 320) {
                PoseStage(runner: runner, placeholder: "Tap Start. Enrol yourself, then step out and back in to check in.") { size in
                    BoxLayer(items: runner.faces.enumerated().map { index, face in
                        let label: (name: String?, score: Float?) = index < labels.count ? labels[index] : (nil, nil)
                        var text = label.name.map { book.isChecked($0) ? "\($0) ✓" : $0 } ?? "Not enrolled"
                        if showScores, let score = label.score { text += String(format: "  %.2f", score) }
                        return .init(box: face.boundingBox, label: text, color: label.name == nil ? .gray : .green)
                    }, size: size)
                    overlay
                }
            } panel: {
                ExamplePanel { panel }
            }
        }
        .navigationTitle("Face check-in")
        .onDisappear { runner.stop() }
        .modifier(AutoStart(start: start))
        .sheet(isPresented: $enrollingPhotos) {
            FacePhotoEnrolSheet(initial: testFolder.map { [$0] } ?? []) { names in
                runner.paused = false
                guard testFolder != nil else { return }
                // Testing: close the sheet, let the video play past everyone, then remove the test names again.
                testFolder = nil
                enrollingPhotos = false
                Task {
                    try? await Task.sleep(for: .seconds(70))
                    names.forEach(studio.forget)
                    FileHandle.standardError.write(Data("ENROL forgot \(names.joined(separator: ", "))\n".utf8))
                }
            }
                .onAppear { runner.paused = true }
                .onDisappear { runner.paused = false }
        }
        .onChange(of: frameCount > 0) { _, analysing in
            if analysing, testFolder != nil, !enrollingPhotos { enrollingPhotos = true }
        }
        .alert("Who is this?", isPresented: Binding(get: { enrolment == .naming }, set: { if !$0 && enrolment == .naming { enrolment = .idle } })) {
            TextField("Name", text: $enrolName)
            Button("Start (3 s)") { enrolment = .countdown(until: now + 3); samples = [] }.disabled(enrolName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { enrolment = .idle }
        } message: {
            Text("Look at the camera. After a 3-second countdown, five samples of the largest face are taken.")
        }
    }

    @ViewBuilder private var overlay: some View {
        switch enrolment {
        case .countdown(let until):
            Text("\(max(1, Int(ceil(until - now))))").font(.system(size: 120, weight: .heavy, design: .rounded))
                .foregroundStyle(.white).shadow(radius: 10)
        case .sampling:
            VStack {
                Spacer()
                Label("Hold still… \(samples.count)/5", systemImage: "camera.metering.center.weighted").font(.title2.bold())
                    .foregroundStyle(.white).padding(12).background(.blue, in: Capsule()).padding(.bottom, 16)
            }
        default:
            if let banner {
                VStack {
                    Text(banner).font(.title.bold()).foregroundStyle(.white).padding(.horizontal, 20).padding(.vertical, 12)
                        .background(.green, in: Capsule()).padding(.top, 16)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder private var panel: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(book.checked.count)").font(.system(size: 64, weight: .bold, design: .rounded)).foregroundStyle(.green)
            Text("checked in").font(.title3).foregroundStyle(.secondary)
        }
        ForEach(Array(book.checked.reversed().prefix(8).enumerated()), id: \.offset) { _, entry in
            HStack {
                Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(.green)
                Text(entry.name)
                Spacer()
                Text(entry.time.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        HStack {
            Button("Clear the list") { book.reset(now: now) }.disabled(book.checked.isEmpty)
            Spacer()
            ShareLink(item: csv, preview: SharePreview("check-in.csv")) { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(book.checked.isEmpty)
        }
        Divider()
        Button { enrolName = ""; enrolment = .naming } label: { Label("Enrol a face", systemImage: "person.badge.plus") }
            .buttonStyle(.borderedProminent).disabled(!runner.running || enrolment != .idle)
        // The face models are loaded once check-in has analysed a frame; the camera pauses meanwhile.
        Button { enrollingPhotos = true } label: { Label("Enrol from photos…", systemImage: "photo.stack") }
            .disabled(!runner.running || frameCount == 0 || enrolment != .idle)
        Text("Enrolled").font(.headline)
        if studio.gallery.people.isEmpty {
            Text("Nobody yet.").foregroundStyle(.secondary)
        }
        ForEach(studio.gallery.people.keys.sorted(), id: \.self) { name in
            HStack {
                Text(name)
                Spacer()
                Button(role: .destructive) { studio.forget(name); book.remove(name) } label: { Image(systemName: "trash") }
            }
        }
        FaceEmbedderPicker(disabled: runner.running)
        Divider()
        VStack(alignment: .leading) {
            Text(String(format: "Match at %.2f similarity or more", threshold)).font(.callout)
            Slider(value: $threshold, in: 0.3...0.7)
        }
        Toggle("Show similarity", isOn: $showScores)
        Text("Only a 512-number identity vector is kept per person, never a photo. A name is given only when one person clearly matches best.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var csv: String {
        "time,name\n" + book.checked.map { "\($0.time.formatted(.iso8601)),\($0.name)" }.joined(separator: "\n")
    }

    private func start() {
        frameCount = 0
        runner.start(studio: studio) { frame in
            now = frame.time
            frameCount += 1
            var gallery = studio.gallery
            gallery.threshold = Float(threshold)
            let matches = frame.faces.map { gallery.confidentMatch($0.embedding) }
            // Scores: the best similarity even when below the threshold, for the "Show similarity" option.
            labels = zip(frame.faces, matches).map { item, match in
                (match?.name, match?.similarity ?? gallery.people.values.flatMap { $0 }.map { known in
                    zip(known, item.embedding).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                }.max())
            }
            enrol(frame)
            guard enrolment == .idle else { return }
            let new = book.update(Set(matches.compactMap { $0?.name }), now: frame.time)
            if !new.isEmpty {
                if Self.testing { FileHandle.standardError.write(Data("CHECKIN \(new.joined(separator: ", ")) at \(Int(frame.time))\n".utf8)) }
                ToneSynth.shared.play(1400, seconds: 0.12, bright: true, volume: 0.35)
                withAnimation { banner = "Welcome, \(new.joined(separator: ", "))!" }
                let shown = banner
                Task {
                    try? await Task.sleep(for: .seconds(2.5))
                    if banner == shown { withAnimation { banner = nil } }
                }
            }
        }
    }

    /// Countdown, then a sample of the locked face every third frame until there are five (at most 6 s).
    private func enrol(_ frame: PoseFrame) {
        switch enrolment {
        case .countdown(let until) where frame.time >= until:
            let largest = frame.faces.max { $0.face.boundingBox.width * $0.face.boundingBox.height < $1.face.boundingBox.width * $1.face.boundingBox.height }
            enrolment = .sampling(since: frame.time, box: largest?.face.boundingBox)
        case .sampling(let since, let locked):
            if frame.time - since > 6 {
                finishEnrolment()
                return
            }
            guard frameCount % 3 == 0 else { return }
            // Follow the face that was largest when the countdown ended (overlap of at least 0.3).
            let candidate = frame.faces.max { a, b in
                locked.map { boxIoU($0, a.face.boundingBox) < boxIoU($0, b.face.boundingBox) }
                    ?? (a.face.boundingBox.width < b.face.boundingBox.width)
            }
            guard let candidate else { return }
            if let locked, boxIoU(locked, candidate.face.boundingBox) < 0.3 { return }
            samples.append(candidate.embedding)
            enrolment = .sampling(since: since, box: candidate.face.boundingBox)
            if samples.count >= 5 { finishEnrolment() }
        default:
            break
        }
    }

    private func finishEnrolment() {
        let name = enrolName.trimmingCharacters(in: .whitespaces)
        if let vector = FaceGallery.average(samples), !name.isEmpty {
            studio.enroll(name, embedding: vector)
            book.remove(name)
            ToneSynth.shared.chime()
            withAnimation { banner = "\(name) enrolled (\(samples.count) samples)" }
        } else {
            withAnimation { banner = "No face seen. Try again, closer to the camera." }
        }
        samples = []
        enrolment = .idle
        let shown = banner
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if banner == shown { withAnimation { banner = nil } }
        }
    }
}
