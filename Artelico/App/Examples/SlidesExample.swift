import PDFKit
import SwiftUI
import StudioCore
import UniformTypeIdentifiers

/// Y2 "Raise hand to flip": right hand up = next slide, left hand up = previous, both hands = back to
/// the first. Slides are a built-in deck or any PDF.
struct SlidesExampleView: View {
    @EnvironmentObject private var studio: StudioModel
    @StateObject private var runner = PoseRunner()
    @State private var controller = GestureController()
    @State private var gesture: RaisedHands = .none
    @State private var page = 0
    @State private var pdf: PDFDocument?
    @State private var pdfName = ""
    @State private var choosingPDF = false
    @State private var flash: SlideAction?
    @State private var flashID = 0

    private var pageCount: Int { pdf?.pageCount ?? BuiltInSlides.all.count }

    var body: some View {
        VStack(spacing: 10) {
            PoseControls(runner: runner, samples: [SampleMedia.office, SampleMedia.street], start: start)
            ExampleLayout(panelWidth: 300) {
                slideArea
            } panel: {
                ExamplePanel {
                    PoseStage(runner: runner, placeholder: "Tap Start, stand back so your head and hands are seen.") { _ in EmptyView() }
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Label(gestureText, systemImage: gestureIcon).font(.headline)
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Right hand up: next slide", systemImage: "arrow.right.circle")
                        Label("Left hand up: previous slide", systemImage: "arrow.left.circle")
                        Label("Both hands up: first slide", systemImage: "arrow.counterclockwise.circle")
                        Text("Lower your hand before the next flip.").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    Divider()
                    HStack {
                        Button { choosingPDF = true } label: { Label("Open a PDF", systemImage: "doc") }
                        if pdf != nil { Button("Built-in slides") { pdf = nil; page = 0 } }
                    }
                    if !pdfName.isEmpty, pdf != nil { Text(pdfName).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("Raise hand to flip")
        .fileImporter(isPresented: $choosingPDF, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let document = PDFDocument(url: url) { pdf = document; pdfName = url.lastPathComponent; page = 0 }
        }
        .onDisappear { runner.stop() }
        .modifier(AutoStart(start: start))
    }

    private var slideArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground))
            Group {
                if let pdf, let pdfPage = pdf.page(at: page) {
                    PDFPageImage(page: pdfPage)
                } else {
                    BuiltInSlides.all[min(page, BuiltInSlides.all.count - 1)].view
                }
            }
            .padding(18)
            .id(page)
            .transition(.asymmetric(insertion: .move(edge: flash == .previous ? .leading : .trailing).combined(with: .opacity),
                                    removal: .opacity))
            VStack {
                Spacer()
                HStack {
                    Button { apply(.previous) } label: { Image(systemName: "chevron.left") }.disabled(page == 0)
                    Text("\(page + 1) / \(pageCount)").font(.callout.monospacedDigit())
                    Button { apply(.next) } label: { Image(systemName: "chevron.right") }.disabled(page >= pageCount - 1)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(10)
            }
            if let flash {
                Image(systemName: flash == .next ? "arrow.right.circle.fill" : flash == .previous ? "arrow.left.circle.fill" : "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 90)).foregroundStyle(.white, Color.accentColor)
                    .shadow(radius: 8)
                    .transition(.scale.combined(with: .opacity))
                    .id(flashID)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.25), value: page)
        .animation(.spring(duration: 0.3), value: flashID)
    }

    private var gestureText: String {
        switch gesture {
        case .none: return runner.running ? "Hands down" : "Not watching"
        case .right: return "Right hand up"
        case .left: return "Left hand up"
        case .both: return "Both hands up"
        }
    }

    private var gestureIcon: String {
        switch gesture {
        case .none: return "hand.raised.slash"
        case .right, .left: return "hand.raised"
        case .both: return "hands.clap"
        }
    }

    private func start() {
        controller = GestureController()
        runner.start(studio: studio) { frame in
            let body = frame.mainPose.map { BodyPose($0, aspect: frame.aspect) }
            gesture = body.map { HandGestures.raised($0) } ?? .none
            if let action = controller.update(gesture, now: frame.time) { apply(action) }
        }
    }

    private func apply(_ action: SlideAction) {
        switch action {
        case .next: page = min(page + 1, pageCount - 1)
        case .previous: page = max(page - 1, 0)
        case .restart: page = 0
        }
        flash = action
        flashID += 1
        ToneSynth.shared.play(action == .previous ? 523.25 : 659.25, seconds: 0.15, volume: 0.3)
        let id = flashID
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if flashID == id { withAnimation { flash = nil } }
        }
    }
}

struct PDFPageImage: View {
    let page: PDFPage
    var body: some View {
        let bounds = page.bounds(for: .mediaBox)
        let scale = 1600 / max(bounds.width, 1)
        Image(uiImage: page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox))
            .resizable().scaledToFit()
    }
}

/// The deck shown when no PDF is open: it explains the example while you practise.
enum BuiltInSlides {
    struct Slide {
        let title: String
        let text: String
        let symbol: String
        let colors: [Color]
        var view: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(spacing: 18) {
                    Image(systemName: symbol).font(.system(size: 70, weight: .light))
                    Text(title).font(.largeTitle.bold()).multilineTextAlignment(.center)
                    Text(text).font(.title3).multilineTextAlignment(.center).frame(maxWidth: 560)
                }
                .foregroundStyle(.white)
                .padding(30)
            }
        }
    }

    static let all: [Slide] = [
        Slide(title: "Raise a hand to flip", text: "Your right hand above your head shows the next slide.", symbol: "hand.raised",
              colors: [Color(red: 0.16, green: 0.08, blue: 0.30), Color(red: 0.42, green: 0.16, blue: 0.48)]),
        Slide(title: "Going back", text: "Raise your left hand to go to the previous slide.", symbol: "arrow.left",
              colors: [Color(red: 0.05, green: 0.25, blue: 0.45), Color(red: 0.10, green: 0.50, blue: 0.65)]),
        Slide(title: "No double flips", text: "A flip needs the hand up for a moment, and the hand lowered before the next one.", symbol: "checkmark.shield",
              colors: [Color(red: 0.10, green: 0.35, blue: 0.20), Color(red: 0.20, green: 0.60, blue: 0.35)]),
        Slide(title: "Start over", text: "Both hands up brings you back to the first slide.", symbol: "arrow.counterclockwise",
              colors: [Color(red: 0.50, green: 0.20, blue: 0.05), Color(red: 0.85, green: 0.45, blue: 0.15)]),
        Slide(title: "Nothing leaves the \(StudioModel.deviceKind)", text: "The pose model runs \(StudioModel.examplesRunOn). The camera picture is not sent anywhere.", symbol: "lock.shield",
              colors: [Color(red: 0.30, green: 0.08, blue: 0.20), Color(red: 0.60, green: 0.15, blue: 0.35)]),
        Slide(title: "Your own slides", text: "Open a PDF to present it the same way.", symbol: "doc.richtext",
              colors: [Color(red: 0.15, green: 0.15, blue: 0.18), Color(red: 0.35, green: 0.35, blue: 0.40)]),
    ]
}

/// Y4 "Raise hand counter": how many of the people in view have a hand up.
struct HandCounterExampleView: View {
    @EnvironmentObject private var studio: StudioModel
    @StateObject private var runner = PoseRunner()
    @State private var raisedIDs: [Bool] = []
    @State private var raised = 0
    @State private var total = 0
    @State private var peak = 0
    @State private var history: [Int] = []

    var body: some View {
        VStack(spacing: 10) {
            PoseControls(runner: runner, samples: [SampleMedia.office, SampleMedia.street], start: start)
            ExampleLayout {
                PoseStage(runner: runner, tint: { index, _ in index < raisedIDs.count && raisedIDs[index] ? .green : .gray },
                          placeholder: "Tap Start and point the camera at the room.") { size in
                    Canvas { context, _ in
                        for (index, pose) in runner.poses.enumerated() where index < raisedIDs.count && raisedIDs[index] {
                            let box = pose.boundingBox
                            let p = CGPoint(x: box.midX * size.width, y: max(box.minY * size.height - 24, 14))
                            context.draw(Text(Image(systemName: "hand.raised.fill")).font(.title).foregroundColor(.green), at: p)
                        }
                    }
                }
            } panel: {
                ExamplePanel {
                    Text("Hands up").font(.headline).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(raised)").font(.system(size: 84, weight: .bold, design: .rounded)).foregroundStyle(.green)
                            .contentTransition(.numericText())
                        Text("of \(total)").font(.title.bold()).foregroundStyle(.secondary)
                    }
                    .animation(.snappy, value: raised)
                    if total > 0 {
                        ProgressView(value: Double(raised), total: Double(max(total, 1))).tint(.green)
                        Text("\(Int((Double(raised) / Double(total) * 100).rounded()))% of the people in view").font(.callout)
                    }
                    Divider()
                    LabeledContent("Most at once", value: "\(peak)")
                    Button("Reset") { peak = 0; history = [] }
                    Text("A hand counts when the wrist is clearly above the head.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Hand-raise counter")
        .onDisappear { runner.stop() }
        .modifier(AutoStart(start: start))
    }

    private func start() {
        runner.start(studio: studio) { frame in
            let bodies = frame.bodies()
            raisedIDs = bodies.map { HandRaiseCounter.isRaised($0) }
            // Smooth the number over the last few frames so it does not flicker.
            history = Array((history + [raisedIDs.filter { $0 }.count]).suffix(5))
            raised = history.sorted()[history.count / 2]
            total = bodies.count
            peak = max(peak, raised)
        }
    }
}
