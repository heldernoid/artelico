import SwiftUI
import StudioCore

/// Privacy camera: faces, licence plates and/or whole people are hidden in every frame before it is shown or
/// recorded, so the original picture never appears (the idea of hailo-apps' face-blur overlay). Rules in
/// StudioCore/Privacy.swift.
struct PrivacyCameraExampleView: View {
    @EnvironmentObject private var studio: StudioModel
    /// The main model segments people and vehicles: people's masks, and where to look for plates.
    @StateObject private var runner = PoseRunner(task: .instanceSegmentation, source: .back)
    @AppStorage("privacy.faces") private var hideFaces = true
    @AppStorage("privacy.plates") private var hidePlates = true
    @AppStorage("privacy.text") private var hideText = false
    @AppStorage("privacy.people") private var hidePeople = false
    @AppStorage("privacy.style") private var styleName = PrivacyStyle.blur.rawValue
    @AppStorage("privacy.outlines") private var outlines = false
    @State private var hidden: [PrivacyRegion] = []
    @State private var hold = RegionHold()
    @State private var recorder: Recorder?
    @State private var saved: URL?

    /// The face detector: the best one here, or scrfd_10g (downloaded when Start is tapped).
    private var faceDetector: ModelInfo? {
        let name = PrivacyScan.faceDetectorNames.first { studio.canUse($0) } ?? PrivacyScan.faceDetectorNames[0]
        return ModelCatalog.model(named: name)
    }

    var body: some View {
        VStack(spacing: 10) {
            PoseControls(runner: runner, sources: [.back, .front, .video, .stream, .picture],
                         samples: [("Street with a bus", "bus.jpg"), ("Plate and signs (All text)", "plate_sample.png"),
                                   SampleMedia.street, SampleMedia.office, SampleMedia.face, SampleMedia.drive], start: start)
            ExampleLayout(panelWidth: 300) {
                PoseStage(runner: runner, placeholder: "Tap Start: faces, plates or whole people are hidden before the picture is shown.") { size in
                    if outlines {
                        BoxLayer(items: hidden.map { region in
                            var box = region.box
                            if runner.mirrored { box.origin.x = 1 - box.maxX }
                            return .init(box: box, label: region.kind.rawValue, color: Self.color(region.kind), width: 2)
                        }, size: size)
                    }
                }
            } panel: {
                ExamplePanel { panel }
            }
        }
        .navigationTitle("Privacy camera")
        .onDisappear { runner.stop(); stopRecording() }
        .modifier(AutoStart(start: start))
    }

    @ViewBuilder private var panel: some View {
        Text("Hidden now").font(.headline).foregroundStyle(.secondary)
        HStack(spacing: 18) {
            ForEach(PrivacyRegion.Kind.allCases, id: \.self) { kind in
                VStack {
                    Text("\(hidden.filter { $0.kind == kind }.count)").font(.system(size: 40, weight: .bold, design: .rounded))
                        .contentTransition(.numericText()).animation(.snappy, value: hidden.count)
                    Text(Self.title(kind)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Toggle("Faces", isOn: $hideFaces)
        Toggle("Licence plates", isOn: $hidePlates)
        Toggle("All text (signs, papers, screens)", isOn: $hideText)
        Toggle("Whole people", isOn: $hidePeople)
        Picker("Look", selection: $styleName) {
            ForEach(PrivacyStyle.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
        Toggle("Show outlines", isOn: $outlines)
        Divider()
        HStack {
            Button { recorder == nil ? startRecording() : stopRecording() } label: {
                Label(recorder == nil ? "Record" : "Stop recording", systemImage: recorder == nil ? "record.circle" : "stop.circle.fill")
            }
            .buttonStyle(.borderedProminent).tint(recorder == nil ? .accentColor : .red)
            .disabled(!runner.running && recorder == nil)
            if let saved {
                ShareLink(item: saved) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        }
        if let saved {
            Text("Saved \(saved.lastPathComponent) (only the hidden version is recorded).").font(.caption).foregroundStyle(.secondary)
        }
        Divider()
        Text("Every frame is cleaned before it is shown or recorded: the original never appears on screen and nothing else is kept. "
             + "A face the detector misses for a moment stays hidden at its last place for \(String(format: "%.1f", hold.seconds)) s.")
            .font(.caption).foregroundStyle(.secondary)
        Text("Faces: \(faceDetector?.name ?? "none") · plates: text found on vehicles, and all text, by \(TextReader.detectorName) · people: masks from \(runner.modelName). "
             + "Far-away or side-on faces can be missed; turn on Whole people for the strictest setting. Runs \(StudioModel.examplesRunOn).")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func start() {
        hold.reset(); hidden = []
        let required = [faceDetector, ModelCatalog.model(named: TextReader.detectorName)].compactMap { $0 }
        runner.start(studio: studio, required: required, filter: { image, instances in
            let device = studio.exampleEngine
            var found: [PrivacyRegion] = []
            if hideFaces, let detector = faceDetector {
                found += try await PrivacyScan.faces(image, detector: detector, device: device)
            }
            if hideText {
                found += try await PrivacyScan.text(image, device: device)   // plates included
            } else if hidePlates {
                found += try await PrivacyScan.plates(image, vehicles: PrivacyScan.vehicles(instances), device: device)
            }
            if hidePeople { found += PrivacyScan.people(instances) }
            let regions = hold.update(found, time: ProcessInfo.processInfo.systemUptime)
            hidden = regions
            let style = PrivacyStyle(rawValue: styleName) ?? .blur
            // Fails closed: when the picture cannot be cleaned the camera stops instead of showing it.
            guard let clean = await Task.detached(priority: .userInitiated, operation: { PrivacyFilter.apply(image, regions: regions, style: style) }).value else {
                throw StudioError.invalidInput("The picture could not be cleaned, so it is not shown.")
            }
            return clean
        }) { frame in
            recorder?.append(frame.image)
        }
    }

    private func startRecording() {
        guard let image = runner.image else { return }
        saved = nil
        recorder = try? Recorder(firstFrame: image, name: "privacy")
    }

    private func stopRecording() {
        guard let current = recorder else { return }
        recorder = nil
        Task { saved = await current.finish() }
    }

    static func title(_ kind: PrivacyRegion.Kind) -> String {
        switch kind {
        case .face: return "faces"
        case .plate: return "plates"
        case .text: return "texts"
        case .person: return "people"
        }
    }

    static func color(_ kind: PrivacyRegion.Kind) -> Color {
        switch kind {
        case .face: return .yellow
        case .plate: return .cyan
        case .text: return .orange
        case .person: return .pink
        }
    }
}
