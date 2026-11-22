import SwiftUI
import StudioCore

/// Face report in two steps (the UGen300 FACE1 demo): the picture model writes what it sees as JSON, a text
/// model turns that into scores and advice, and the card adds a pencil sketch (Core Image). Scores are about
/// the photo and the styling, never about looks (rules in StudioCore/FaceReport.swift). Hailo Studio swaps
/// the picture model and the text model on the stick; Artelico loads one GGUF after the other.
struct FaceReportExampleView: View {
    enum Stage: Equatable { case idle, looking, writing, done, failed(String) }

    @EnvironmentObject private var studio: StudioModel
    @AppStorage("examples.vlm") private var observerID = StudioModel.defaultLanguageModel(.pictures)
    @AppStorage("facereport.writer") private var writerID = StudioModel.defaultLanguageModel(.chat)
    @State private var image: CGImage?
    @State private var crop: CGImage?
    @State private var sketch: CGImage?
    @State private var observations: [String: String] = [:]
    @State private var report = FaceReport.Report()
    @State private var rawObserver = ""
    @State private var rawWriter = ""
    @State private var stage = Stage.idle
    @State private var notes: [String] = []
    @State private var task: Task<Void, Never>?
    @State private var showRaw = false
    @State private var exported: Image?

    private var working: Bool { stage == .looking || stage == .writing }

    var body: some View {
        ExampleLayout(panelWidth: 380) {
            VStack(spacing: 8) {
                Text("Look at the camera in good light, or choose a photo. Only this picture is used, and nothing is saved.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                if stage == .done {
                    ScrollView { card.padding(4) }
                } else {
                    PictureSource(image: $image, startFront: true, timer: 3)
                }
            }
        } panel: {
            VStack(alignment: .leading, spacing: 10) {
                Text("1. Picture model (looks)").font(.caption).foregroundStyle(.secondary)
                LanguagePicker(use: .pictures, modelID: $observerID)
                Text("2. Text model (scores and writes)").font(.caption).foregroundStyle(.secondary)
                LanguagePicker(use: .chat, modelID: $writerID)
                HStack {
                    Button { make() } label: { Label("Make my report", systemImage: "sparkles") }
                        .buttonStyle(.borderedProminent).disabled(image == nil || working)
                    if working { Button("Stop", role: .destructive) { task?.cancel() } }
                    if stage == .done {
                        Button("New picture") { stage = .idle }
                        if let exported { ShareLink(item: exported, preview: SharePreview("Face report", image: exported)) { Image(systemName: "square.and.arrow.up") } }
                    }
                }
                switch stage {
                case .looking: ProgressView("Step 1: the picture model describes the face…")
                case .writing: ProgressView("Step 2: the text model scores and writes…")
                case .failed(let problem): Text(problem).foregroundStyle(.red).font(.callout)
                default: EmptyView()
                }
                ForEach(notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                if !rawObserver.isEmpty {
                    DisclosureGroup("What the models wrote", isExpanded: $showRaw) {
                        Text("Picture model:\n\(rawObserver)\n\nText model:\n\(rawWriter)")
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                Text("Scores rate the photo and the styling (light, sharpness, framing, expression, how hair and clothes go together), never how a face looks. For fun only, not professional advice.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("Face report")
        .onDisappear { task?.cancel() }
        .task { await testRun() }
    }

    // MARK: The two steps

    private func make() {
        guard let image else { return }
        task = Task { await run(image) }
    }

    private func run(_ picture: CGImage) async {
        stage = .looking
        notes = []; rawObserver = ""; rawWriter = ""; observations = [:]; report = FaceReport.Report(); exported = nil
        let (face, found) = FaceReport.faceCrop(picture)
        crop = face
        sketch = FaceReport.pencilSketch(face)
        if !found { notes.append("No face found: the whole picture is used.") }
        do {
            let seen = try await studio.exampleStream(modelID: observerID, system: FaceReport.observerSystem, user: FaceReport.observerQuestion,
                                                      picture: face, maxTokens: 320, temperature: 0.1) { rawObserver = $0 }
            notes.append("Looked: " + seen.summary)
            observations = FaceReport.parseObservations(rawObserver)
            guard observations.count >= 3 else {
                stage = .failed("The picture model did not describe the face in the expected form. Try again or choose another picture model.")
                return
            }
            stage = .writing
            // Like FACE1, a second try when the first answer has no usable fields.
            for attempt in 1...2 {
                let wrote = try await studio.exampleStream(modelID: writerID, system: FaceReport.writerSystem, user: FaceReport.writerMessage(observations),
                                                           maxTokens: 480, temperature: attempt == 1 ? 0.3 : 0.6) { rawWriter = $0 }
                report = FaceReport.parseReport(rawWriter)
                notes.append("Wrote: " + wrote.summary)
                if report.isUsable && !report.scoresLookCopied { break }
            }
            guard report.isUsable else {
                stage = .failed("The text model did not answer in the expected form. Try again or choose another text model.")
                return
            }
            stage = .done
            exported = renderCard()
        } catch is CancellationError {
            stage = .idle
        } catch {
            stage = .failed("\(error)")
        }
        logIfTesting()
    }

    // MARK: The report card

    private var card: some View {
        FaceReportCard(crop: crop, sketch: sketch, observations: observations, report: report)
    }

    @MainActor private func renderCard() -> Image? {
        let renderer = ImageRenderer(content: card.frame(width: 620).padding(10).background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        return renderer.uiImage.map { Image(uiImage: $0) }
    }

    // MARK: Testing from the Mac

    /// `-facereport <picture>` makes the report for that picture and prints both answers and the parsed result.
    private func testRun() async {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-facereport"), index + 1 < arguments.count, stage == .idle,
              let picture = FacePhotoEnrolSheet.load(URL(fileURLWithPath: arguments[index + 1])) else { return }
        image = picture
        await run(picture)
    }

    private func logIfTesting() {
        guard CommandLine.arguments.contains("-facereport") else { return }
        let scores = FaceReport.scoreKeys.map { "\($0)=\(report.scores[$0].map(String.init) ?? "-")" }.joined(separator: " ")
        let text = """
        FACEREPORT stage: \(stage)
        FACEREPORT observer raw: \(rawObserver)
        FACEREPORT writer raw: \(rawWriter)
        FACEREPORT observations: \(observations.count) of \(FaceReport.observationKeys.count)
        FACEREPORT scores: \(scores) overall=\(report.overall.map(String.init) ?? "-")
        FACEREPORT strengths: \(report.strengths.count), tips: \(report.tips.count)
        FACEREPORT notes: \(notes.joined(separator: " | "))

        """
        FileHandle.standardError.write(Data(text.utf8))
    }
}

/// The card: photo and sketch, scores, summary, what was seen, strengths and tips.
struct FaceReportCard: View {
    let crop: CGImage?
    let sketch: CGImage?
    let observations: [String: String]
    let report: FaceReport.Report

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text("Face style report").font(.title2.bold())
                    Text("Photo and styling · for fun").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let overall = report.overall {
                    Text("\(overall)").font(.system(size: 44, weight: .bold, design: .rounded)).foregroundStyle(.tint)
                }
            }
            HStack(spacing: 10) {
                picture(crop, title: "Photo")
                picture(sketch, title: "Sketch").overlay { guides }
            }
            .frame(height: 220)
            VStack(spacing: 6) {
                ForEach(FaceReport.scoreKeys, id: \.self) { key in
                    HStack {
                        Text(FaceReport.scoreTitles[key] ?? key).frame(width: 110, alignment: .leading)
                        ProgressView(value: Double(report.scores[key] ?? 0), total: 100)
                        Text(report.scores[key].map(String.init) ?? "–").monospacedDigit().frame(width: 32, alignment: .trailing)
                    }
                    .font(.callout)
                }
            }
            if !report.summary.isEmpty { Text(report.summary).font(.callout.italic()) }
            if !observations.isEmpty {
                section("Seen") {
                    ForEach(FaceReport.observationKeys.filter { observations[$0] != nil }, id: \.self) { key in
                        Text("**\(key.replacingOccurrences(of: "_", with: " ").capitalized)**: \(observations[key] ?? "")").font(.caption)
                    }
                }
            }
            if !report.strengths.isEmpty {
                section("Strengths") { ForEach(report.strengths, id: \.self) { Label($0, systemImage: "checkmark").font(.callout) } }
            }
            if !report.tips.isEmpty {
                section("Tips") { ForEach(report.tips, id: \.0) { Text("**\($0.0)**: \($0.1)").font(.callout) } }
            }
            Text("Made \(StudioModel.examplesRunOn) by a picture model and a text model. For fun only, not professional advice.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func picture(_ image: CGImage?, title: String) -> some View {
        // A clear cell of the row's size holds the picture, so a filled picture cannot widen the row.
        Color.gray.opacity(0.15)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                Text(title).font(.caption2.bold()).foregroundStyle(.white).padding(4).background(.black.opacity(0.5), in: Capsule()).padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// FACE1's proportion guides on the sketch: thirds across, fifths down.
    private var guides: some View {
        GeometryReader { geometry in
            Path { path in
                let size = geometry.size
                for i in 1...3 { let y = size.height * CGFloat(i) / 4; path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)) }
                for i in 1...4 { let x = size.width * CGFloat(i) / 5; path.move(to: CGPoint(x: x, y: size.height * 0.15)); path.addLine(to: CGPoint(x: x, y: size.height * 0.85)) }
            }
            .stroke(Color.gray.opacity(0.45), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            content()
        }
    }
}
