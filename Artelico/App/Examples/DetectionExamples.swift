import Charts
import SwiftUI
import StudioCore

// The detection examples (UGen300 demos HeadCount, TrafficCount, MissingCheck, PlateGate) on this
// device's own chip. Rules in StudioCore/DetectionGames.swift.

/// Boxes with a label tag, drawn over the picture in display coordinates.
struct BoxLayer: View {
    struct Item {
        var box: CGRect
        var label: String
        var color: Color
        var width: CGFloat = 3
    }
    let items: [Item]
    let size: CGSize

    var body: some View {
        Canvas { context, _ in
            for item in items {
                let r = CGRect(x: item.box.minX * size.width, y: item.box.minY * size.height,
                               width: item.box.width * size.width, height: item.box.height * size.height)
                context.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(item.color), lineWidth: item.width)
                guard !item.label.isEmpty else { continue }
                let resolved = context.resolve(Text(item.label).font(.caption.bold()).foregroundColor(.black))
                let s = resolved.measure(in: size)
                let tag = CGRect(x: r.minX, y: max(r.minY - s.height - 4, 0), width: s.width + 10, height: s.height + 4)
                context.fill(Path(roundedRect: tag, cornerRadius: 4), with: .color(item.color))
                context.draw(resolved, at: CGPoint(x: tag.minX + 5, y: tag.minY + 2), anchor: .topLeading)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - HeadCount

/// HeadCount: people in view, numbered, with the peak and a 60-second chart. Freeze keeps the count
/// while you pan to another part of the room.
struct HeadCountExampleView: View {
    @EnvironmentObject private var studio: StudioModel
    @StateObject private var runner = PoseRunner(task: .detection, source: .back)
    @State private var people: [Detection] = []
    @State private var recent: [Int] = []
    @State private var count = 0
    @State private var peak = 0
    @State private var history: [(time: Double, value: Int)] = []
    @AppStorage("headcount.conf") private var threshold = 0.3

    var body: some View {
        VStack(spacing: 10) {
            PoseControls(runner: runner, sources: [.back, .front, .video, .stream, .picture], samples: [("Street with people", "bus.jpg"), SampleMedia.street, SampleMedia.office], start: start)
            ExampleLayout(panelWidth: 300) {
                PoseStage(runner: runner, placeholder: "Tap Start and point the camera at the room.") { size in
                    BoxLayer(items: people.enumerated().map { .init(box: $0.element.boundingBox, label: "\($0.offset + 1)", color: .green) }, size: size)
                    if runner.paused {
                        VStack { Label("Frozen", systemImage: "snowflake").font(.headline).padding(8).background(.orange, in: Capsule()).padding(10); Spacer() }
                    }
                }
            } panel: {
                ExamplePanel {
                    Text("People now").font(.headline).foregroundStyle(.secondary)
                    Text("\(count)").font(.system(size: 96, weight: .bold, design: .rounded)).foregroundStyle(count > 0 ? .green : .primary)
                        .contentTransition(.numericText()).animation(.snappy, value: count)
                    LabeledContent("Peak", value: "\(peak)")
                    Chart(history, id: \.time) { point in
                        LineMark(x: .value("s", point.time), y: .value("People", point.value)).interpolationMethod(.stepEnd)
                    }
                    .chartXAxis(.hidden)
                    .frame(height: 100)
                    Text("Last 60 seconds").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(runner.paused ? "Unfreeze" : "Freeze") { runner.paused.toggle() }.disabled(!runner.running)
                        Spacer()
                        Button("Reset peak") { peak = count }
                    }
                    Slider(value: $threshold, in: 0.15...0.7) { Text("Confidence") }
                    Text(String(format: "Counts people found with at least %.0f%% confidence. No pictures are kept and nobody is identified.", threshold * 100))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Head count")
        .onDisappear { runner.stop() }
        .modifier(AutoStart(start: start))
    }

    private func start() {
        peak = 0; history = []; recent = []
        runner.start(studio: studio) { frame in
            people = frame.detections.filter { $0.label == "person" && Double($0.confidence) >= threshold }
            recent = Array((recent + [people.count]).suffix(3))
            count = recent.sorted()[recent.count / 2]   // median of 3 frames: no flicker
            peak = max(peak, count)
            history = (history + [(frame.time, count)]).filter { frame.time - $0.time <= 60 }
        }
    }
}

// MARK: - TrafficCount

/// TrafficCount: people and vehicles followed with a number, counted once when they cross the line,
/// up and down separately, with the flow per minute.
struct TrafficCountExampleView: View {
    @EnvironmentObject private var studio: StudioModel
    @StateObject private var runner = PoseRunner(task: .detection, source: .stream)
    @AppStorage("traffic.line") private var line = 0.6
    @State private var tracker = CentroidTracker()
    @State private var counter = LineCounter(lineY: 0.6 * 720)
    @State private var tracks: [CentroidTracker.Track] = []
    @State private var events: [(time: Double, label: String, direction: LineCounter.Direction, clock: Date)] = []
    @State private var now = 0.0
    @State private var frameHeight = 720.0

    static let classes: [(label: String, name: String, one: String, color: Color)] = [
        ("person", "People", "Person", .green), ("bicycle", "Bicycles", "Bicycle", .yellow), ("motorcycle", "Motorbikes", "Motorbike", .orange),
        ("car", "Cars", "Car", .blue), ("bus", "Buses", "Bus", .purple), ("truck", "Trucks", "Truck", .pink),
    ]
    static func color(_ label: String) -> Color { classes.first { $0.label == label }?.color ?? .gray }

    var body: some View {
        VStack(spacing: 10) {
            PoseControls(runner: runner, sources: [.stream, .back, .front, .video], samples: [SampleMedia.drive, SampleMedia.aerial, SampleMedia.street], start: start)
            ExampleLayout(panelWidth: 320) {
                PoseStage(runner: runner, placeholder: "Choose a road camera (or the camera, or a video), then tap Start.") { size in
                    Canvas { context, _ in
                        let y = line * size.height
                        var path = Path(); path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(path, with: .color(.orange), style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                        let scale = CGSize(width: size.width / 1280, height: size.height / frameHeight)
                        for t in tracks where t.missed == 0 {
                            let c = Self.color(t.label)
                            var trail = Path()
                            for (i, p) in t.history.suffix(15).enumerated() {
                                let q = CGPoint(x: p.x * scale.width, y: p.y * scale.height)
                                if i == 0 { trail.move(to: q) } else { trail.addLine(to: q) }
                            }
                            context.stroke(trail, with: .color(c), lineWidth: 2)
                        }
                    }
                    BoxLayer(items: tracks.filter { $0.missed == 0 }.map { t in
                        .init(box: CGRect(x: t.box.minX / 1280, y: t.box.minY / frameHeight, width: t.box.width / 1280, height: t.box.height / frameHeight),
                              label: "\(Self.classes.first { $0.label == t.label }?.one ?? t.label) #\(t.id)",
                              color: Self.color(t.label), width: 2)
                    }, size: size)
                }
            } panel: {
                ExamplePanel { panel }
            }
        }
        .navigationTitle("Traffic count")
        .onDisappear { runner.stop() }
        .modifier(AutoStart(start: start))
    }

    @ViewBuilder private var panel: some View {
        Text("\(counter.total)").font(.system(size: 72, weight: .bold, design: .rounded)).foregroundStyle(.orange)
            .frame(maxWidth: .infinity)
        Text("crossed the line · \(events.filter { now - $0.time <= 60 }.count) in the last minute").font(.callout)
            .frame(maxWidth: .infinity)
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                Text("↓ down").font(.caption).foregroundStyle(.secondary)
                Text("↑ up").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Self.classes, id: \.label) { item in
                GridRow {
                    Label(item.name, systemImage: "circle.fill").foregroundStyle(item.color).labelStyle(.titleAndIcon)
                    Text("\(counter.count(item.label, .down))").monospacedDigit()
                    Text("\(counter.count(item.label, .up))").monospacedDigit()
                }
            }
        }
        Divider()
        VStack(alignment: .leading) {
            Text(String(format: "Counting line at %.0f%% of the height", line * 100)).font(.callout)
            Slider(value: $line, in: 0.1...0.9).onChange(of: line) { _, value in counter.lineY = value * frameHeight }
        }
        HStack {
            Button("Reset") { counter = LineCounter(lineY: line * frameHeight); events = [] }
            Spacer()
            ShareLink(item: csv, preview: SharePreview("traffic-count.csv")) { Label("Log", systemImage: "square.and.arrow.up") }
                .disabled(events.isEmpty)
        }
        Text("Each object counts once, the first time its centre crosses the line. Nothing is recorded but the counts.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var csv: String {
        "time,class,direction\n" + events.map { "\($0.clock.formatted(.iso8601)),\($0.label),\($0.direction.rawValue)" }.joined(separator: "\n")
    }

    private func start() {
        tracker = CentroidTracker()
        counter = LineCounter(lineY: line * 720)
        events = []
        runner.start(studio: studio) { frame in
            frameHeight = 1280 / frame.aspect
            counter.lineY = line * frameHeight
            let wanted = Set(Self.classes.map(\.label))
            let detections = frame.detections.filter { wanted.contains($0.label) && $0.confidence >= 0.35 }.map {
                (label: $0.label, box: CGRect(x: $0.boundingBox.minX * 1280, y: $0.boundingBox.minY * frameHeight,
                                              width: $0.boundingBox.width * 1280, height: $0.boundingBox.height * frameHeight))
            }
            tracks = tracker.update(detections)
            for crossing in counter.update(tracks) {
                events.append((frame.time, crossing.label, crossing.direction, Date()))
                ToneSynth.shared.play(crossing.direction == .down ? 659.25 : 783.99, seconds: 0.12, volume: 0.25)
            }
            now = frame.time
        }
    }
}

// MARK: - MissingCheck

/// MissingCheck: remember what is on the table; red when something is taken away, yellow when
/// something new appears, green when all is as it was.
struct MissingCheckExampleView: View {
    @EnvironmentObject private var studio: StudioModel
    @StateObject private var runner = PoseRunner(task: .detection, source: .back)
    @AppStorage("missing.ignorePeople") private var ignorePeople = true
    @AppStorage("missing.sound") private var sound = true
    @State private var check = MissingCheck()
    @State private var status = MissingCheck.Status(armed: false, missing: [], extra: [], present: [])
    @State private var labels: [String] = []
    @State private var boxes: [Detection] = []
    @State private var lastBeep = Date.distantPast

    var body: some View {
        VStack(spacing: 10) {
            PoseControls(runner: runner, sources: [.back, .front, .video, .picture], samples: [("Street with a bus", "bus.jpg"), SampleMedia.office, SampleMedia.parcels], start: start)
            ExampleLayout(panelWidth: 300) {
                PoseStage(runner: runner, placeholder: "Point the camera at the table, tap Start, then Remember.") { size in
                    BoxLayer(items: boxes.map { d in
                        let known = check.baseline.contains(d.label)
                        return .init(box: d.boundingBox, label: d.label, color: !status.armed ? .white : known ? .green : .yellow)
                    }, size: size)
                    VStack {
                        Spacer()
                        banner.padding(12)
                    }
                }
            } panel: {
                ExamplePanel {
                    Button {
                        check.setBaseline(labels)
                        status = check.update(labels)
                    } label: { Label(check.baseline.isEmpty ? "Remember what is here" : "Remember again", systemImage: "camera.metering.matrix") }
                        .buttonStyle(.borderedProminent).disabled(!runner.running)
                    if !check.baseline.isEmpty { Button("Forget") { check.clear(); status = check.update(labels) } }
                    if status.armed {
                        Text("Should be here").font(.headline)
                        ForEach(check.baseline, id: \.self) { item in
                            Label(item, systemImage: status.missing.contains(item) ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(status.missing.contains(item) ? .red : .green)
                        }
                        if !status.extra.isEmpty {
                            Text("Not expected").font(.headline)
                            ForEach(status.extra, id: \.self) { Label($0, systemImage: "plus.circle.fill").foregroundStyle(.orange) }
                        }
                    } else {
                        Text("Seen now: " + (labels.isEmpty ? "nothing" : Set(labels).sorted().joined(separator: ", "))).font(.callout)
                    }
                    Divider()
                    Toggle("Ignore people", isOn: $ignorePeople).onChange(of: ignorePeople) { _, on in check.ignored = on ? ["person"] : [] }
                    Toggle("Sound alerts", isOn: $sound)
                    Text("Lay out the things to watch, move everything else away, and tap Remember. Low beep: something is missing. Two high beeps: something extra.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Missing check")
        .onDisappear { runner.stop() }
        .modifier(AutoStart(start: start))
    }

    @ViewBuilder private var banner: some View {
        let (text, color): (String, Color) = !status.armed ? ("Not watching yet", .gray)
            : !status.missing.isEmpty ? ("MISSING \(status.missing.count): \(status.missing.joined(separator: ", "))", .red)
            : !status.extra.isEmpty ? ("EXTRA \(status.extra.count): \(status.extra.joined(separator: ", "))", .orange)
            : ("ALL OK", .green)
        Text(text).font(.title3.bold()).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(color, in: Capsule())
    }

    private func start() {
        check = MissingCheck(ignored: ignorePeople ? ["person"] : [])
        runner.start(studio: studio) { frame in
            boxes = frame.detections.filter { $0.confidence >= 0.4 && !(ignorePeople && $0.label == "person") }
            labels = boxes.map(\.label)
            status = check.update(labels)
            guard sound, status.armed, Date().timeIntervalSince(lastBeep) >= 1.2 else { return }
            if !status.missing.isEmpty {
                ToneSynth.shared.play(600, seconds: 0.35, bright: true, volume: 0.5); lastBeep = Date()
            } else if !status.extra.isEmpty {
                ToneSynth.shared.play(1100, seconds: 0.12, bright: true, volume: 0.45)
                ToneSynth.shared.play(1100, seconds: 0.12, bright: true, volume: 0.45, delay: 0.18)
                lastBeep = Date()
            }
        }
    }
}

// MARK: - PlateGate

/// PlateGate: finds vehicles, reads the licence plate with the text models, checks it against a list
/// and opens (or keeps closed) a parking barrier. Works on a photo when there is no car around.
struct PlateGateExampleView: View {
    @EnvironmentObject private var studio: StudioModel
    @StateObject private var runner = PoseRunner(task: .detection, source: .picture)
    @AppStorage("plates.allowed") private var allowedText = "ABC-1234"
    @AppStorage("plates.auto") private var automatic = true
    @State private var vehicles: [Detection] = []
    @State private var plateBoxes: [CGRect] = []
    @State private var lastPlate: (text: String, allowed: Bool)?
    @State private var gate = GateBarrier()
    @State private var reading = false
    @State private var lastRead = Date.distantPast
    @State private var log: [(time: Date, plate: String, allowed: Bool)] = []
    @State private var newPlate = ""
    @State private var latest: CGImage?

    private static let vehicleLabels: Set<String> = ["car", "truck", "bus", "motorcycle"]
    private var allowed: [String] { allowedText.split(separator: ",").map { String($0) } }
    private var textModels: [ModelInfo] { [TextReader.detectorName, TextReader.recognizerName].compactMap { ModelCatalog.model(named: $0) } }
    private var textModelsHere: Bool { textModels.allSatisfy { studio.canUse($0.name) } }

    var body: some View {
        VStack(spacing: 10) {
            PoseControls(runner: runner, sources: [.picture, .back, .front, .video, .stream], samples: [("Car plate ABC-1234", "plate_sample.png"), ("Street with a bus", "bus.jpg")], start: start)
            ExampleLayout(panelWidth: 320) {
                PoseStage(runner: runner, placeholder: "Choose a photo of a car or try Samples → Car plate (or point the camera at one), then tap Start.") { size in
                    BoxLayer(items: vehicles.map { .init(box: $0.boundingBox, label: $0.label, color: .cyan, width: 2) }
                             + plateBoxes.map { .init(box: $0, label: lastPlate?.text ?? "", color: lastPlate?.allowed == true ? .green : .red) }, size: size)
                }
            } panel: {
                ExamplePanel { panel }
            }
        }
        .navigationTitle("Plate gate")
        .onDisappear { runner.stop() }
        .modifier(AutoStart(start: start))
    }

    @ViewBuilder private var panel: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let (angle, gateState) = gate.display(now: t)
            Canvas { context, size in
                let base = CGPoint(x: 40, y: size.height - 20)
                context.fill(Path(roundedRect: CGRect(x: base.x - 14, y: base.y - 40, width: 28, height: 60), cornerRadius: 4), with: .color(.gray))
                let length = size.width - 70
                let end = CGPoint(x: base.x + length * cos(angle * .pi / 180), y: base.y - 30 - length * sin(angle * .pi / 180))
                var arm = Path(); arm.move(to: CGPoint(x: base.x, y: base.y - 30)); arm.addLine(to: end)
                context.stroke(arm, with: .color(gateState == .denied ? .red : .white), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                for k in 1...5 {
                    let f = CGFloat(k) / 6
                    let p = CGPoint(x: base.x + (end.x - base.x) * f, y: base.y - 30 + (end.y - base.y + 30) * f)
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.red))
                }
            }
            .frame(height: 150)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
        }
        if let lastPlate {
            Text(lastPlate.text).font(.system(size: 34, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 14).padding(.vertical, 4)
                .background(.white, in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(.black)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.black, lineWidth: 3))
            Label(lastPlate.allowed ? "Allowed: barrier opens" : "Not on the list", systemImage: lastPlate.allowed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.headline).foregroundStyle(lastPlate.allowed ? .green : .red)
            if !lastPlate.allowed {
                Button("Add \(lastPlate.text) to the list") { add(lastPlate.text) }
            }
        } else {
            Text(reading ? "Reading…" : "No plate read yet").foregroundStyle(.secondary)
        }
        HStack {
            Button { readNow() } label: { Label("Read plate", systemImage: "text.viewfinder") }
                .buttonStyle(.borderedProminent).disabled(!runner.running || reading || !textModelsHere)
            Toggle("Automatic", isOn: $automatic).fixedSize()
        }
        if !textModelsHere {
            Text("Reading plates needs the text models ocr_det and ocr on this \(StudioModel.deviceKind).").font(.caption).foregroundStyle(.red)
        }
        Divider()
        Text("Allowed plates").font(.headline)
        ForEach(allowed, id: \.self) { plate in
            HStack {
                Text(plate).font(.body.monospaced())
                Spacer()
                Button(role: .destructive) { allowedText = allowed.filter { $0 != plate }.joined(separator: ",") } label: { Image(systemName: "minus.circle") }
            }
        }
        HStack {
            TextField("AA-00-AA", text: $newPlate).textFieldStyle(.roundedBorder).textInputAutocapitalization(.characters).autocorrectionDisabled()
            Button("Add") { if let p = PlateText.normalize(newPlate) { add(p) }; newPlate = "" }
        }
        if !log.isEmpty {
            Divider()
            Text("Log").font(.headline)
            ForEach(Array(log.suffix(8).reversed().enumerated()), id: \.offset) { _, entry in
                HStack {
                    Text(entry.time.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(entry.plate).font(.callout.monospaced())
                    Spacer()
                    Image(systemName: entry.allowed ? "checkmark" : "xmark").foregroundStyle(entry.allowed ? .green : .red)
                }
            }
        }
    }

    private func add(_ plate: String) {
        guard !allowed.contains(plate) else { return }
        allowedText = (allowed + [plate]).joined(separator: ",")
        if lastPlate?.text == plate { lastPlate = (plate, true); gate.open(now: Date.timeIntervalSinceReferenceDate) }
    }

    private func start() {
        lastPlate = nil; plateBoxes = []
        runner.start(studio: studio, extra: textModels) { frame in
            latest = frame.image
            vehicles = frame.detections.filter { Self.vehicleLabels.contains($0.label) && $0.confidence >= 0.4 }
            if automatic, !reading, textModelsHere, Date().timeIntervalSince(lastRead) > 2, !vehicles.isEmpty || runner.source == .picture {
                readNow()
            }
        }
    }

    /// Reads text inside each vehicle box (or the whole picture when there is none) and keeps the
    /// best plate-shaped result.
    private func readNow() {
        guard let image = latest, !reading else { return }
        reading = true
        lastRead = Date()
        let regions = vehicles.isEmpty ? [CGRect(x: 0, y: 0, width: 1, height: 1)] : vehicles.map(\.boundingBox)
        let mirrored = runner.mirrored
        Task {
            var best: (text: String, confidence: Float, box: CGRect)?
            for region in regions {
                // Back to the camera's own coordinates when the picture is shown mirrored.
                let r = mirrored ? CGRect(x: 1 - region.maxX, y: region.minY, width: region.width, height: region.height) : region
                let pixels = CGRect(x: r.minX * CGFloat(image.width), y: r.minY * CGFloat(image.height),
                                    width: r.width * CGFloat(image.width), height: r.height * CGFloat(image.height)).integral
                guard let crop = image.cropping(to: pixels), let found = try? await TextReader.read(crop, device: studio.exampleEngine) else { continue }
                for text in found {
                    guard let plate = PlateText.normalize(text.text) else { continue }
                    if best == nil || text.confidence > best!.confidence {
                        let xs = text.corners.map(\.x), ys = text.corners.map(\.y)
                        var box = CGRect(x: region.minX + (xs.min() ?? 0) * region.width, y: region.minY + (ys.min() ?? 0) * region.height,
                                         width: ((xs.max() ?? 0) - (xs.min() ?? 0)) * region.width, height: ((ys.max() ?? 0) - (ys.min() ?? 0)) * region.height)
                        if mirrored { box.origin.x = region.minX + region.maxX - box.maxX }
                        best = (plate, text.confidence, box)
                    }
                }
            }
            reading = false
            guard let best else { return }
            let isAllowed = allowed.contains(best.text)
            let changed = lastPlate?.text != best.text
            lastPlate = (best.text, isAllowed)
            plateBoxes = [best.box]
            if changed || gate.display(now: Date.timeIntervalSinceReferenceDate).state == .closed {
                let now = Date.timeIntervalSinceReferenceDate
                if isAllowed { gate.open(now: now); ToneSynth.shared.chime() } else { gate.deny(now: now); ToneSynth.shared.play(220, seconds: 0.4, bright: true, volume: 0.4) }
                // The barrier reopens for a car that stays (as the demo), but the log notes it once per 30 s.
                if let last = log.last, last.plate == best.text, Date().timeIntervalSince(last.time) < 30 {} else {
                    log.append((Date(), best.text, isAllowed))
                }
            }
        }
    }
}
