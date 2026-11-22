import Charts
import SwiftUI
import StudioCore
import UserNotifications

/// WakeUp "Squat alarm": an alarm that only stops after a number of squats in front of the camera.
/// iOS does not let an app ring while it is closed, so the alarm rings while the app is open; a
/// notification at the same time reminds you to open it.
struct SquatAlarmExampleView: View {
    enum Phase { case idle, armed, ringing, done }

    @EnvironmentObject private var studio: StudioModel
    @StateObject private var runner = PoseRunner()
    @AppStorage("squat.target") private var target = 5
    @State private var wakeTime = Calendar.current.date(byAdding: .minute, value: 1, to: Date()) ?? Date()
    @State private var phase: Phase = .idle
    @State private var counter = SquatCounter()
    @State private var status: SquatCounter.Status?
    @State private var lastBeat = Date.distantPast

    var body: some View {
        VStack(spacing: 10) {
            PoseControls(runner: runner, samples: [SampleMedia.squats, SampleMedia.office], start: startCamera)
            ExampleLayout(panelWidth: 320) {
                PoseStage(runner: runner, tint: { _, _ in status?.phase == .down ? .orange : .green },
                          placeholder: "When the alarm rings, stand back so your legs are in the picture.") { _ in
                    if phase == .ringing {
                        VStack {
                            Text("\(status?.count ?? 0) / \(target)").font(.system(size: 80, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white).shadow(radius: 8)
                                .contentTransition(.numericText())
                            Spacer()
                            if status?.visible == false {
                                Text("Step back so the camera sees your knees and ankles").font(.headline).foregroundStyle(.white)
                                    .padding(10).background(.black.opacity(0.6), in: Capsule()).padding(.bottom, 14)
                            }
                        }
                        .padding(.top, 12)
                    }
                }
            } panel: {
                ExamplePanel { panel }
            }
        }
        .navigationTitle("Squat alarm")
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { now in tick(now) }
        .onDisappear { runner.stop(); UIApplication.shared.isIdleTimerDisabled = false }
        .modifier(AutoStart(start: ringNow))
    }

    @ViewBuilder private var panel: some View {
        switch phase {
        case .idle:
            Text("Wake up with squats").font(.title2.bold())
            DatePicker("Ring at", selection: $wakeTime, displayedComponents: .hourAndMinute)
            Stepper("Squats to stop it: \(target)", value: $target, in: 1...30)
            Button { arm() } label: { Label("Set the alarm", systemImage: "alarm") }.buttonStyle(.borderedProminent)
            Button("Ring now (try it)") { ringNow() }
            Text("Keep \(ExampleApp.name) open with the screen on: iOS only lets it ring while it is open. A notification reminds you at the same time.")
                .font(.caption).foregroundStyle(.secondary)
        case .armed:
            Image(systemName: "alarm.fill").font(.system(size: 50)).foregroundStyle(.orange)
            Text("Rings at \(wakeTime.formatted(date: .omitted, time: .shortened))").font(.title2.bold())
            Text(timeLeft).font(.title3.monospacedDigit()).foregroundStyle(.secondary)
            Text("\(target) squats will stop it.").font(.callout)
            Button("Cancel the alarm", role: .destructive) { cancel() }
        case .ringing:
            Label("Wake up!", systemImage: "bell.and.waves.left.and.right.fill").font(.title.bold()).foregroundStyle(.red)
            Text("Do \(target) squats to stop the alarm.").font(.headline)
            if let angle = status?.angle {
                Gauge(value: min(max(angle, 60), 180), in: 60...180) {
                    Text("Knee")
                } currentValueLabel: {
                    Text("\(Int(angle))°")
                }
                .gaugeStyle(.accessoryLinear)
                .tint(Gradient(colors: [.orange, .yellow, .green]))
                Text(status?.phase == .down ? "Down… now stand up" : "Standing: squat down").font(.callout)
            }
            Button("Stop without squats", role: .destructive) { finish(success: false) }.font(.caption)
        case .done:
            Image(systemName: "sun.max.fill").font(.system(size: 60)).foregroundStyle(.yellow)
            Text("Good morning!").font(.largeTitle.bold())
            Text("\(counter.count) squats done.").font(.title3)
            Button("Set another alarm") { phase = .idle }.buttonStyle(.borderedProminent)
        }
    }

    private var timeLeft: String {
        let seconds = max(0, Int(wakeTime.timeIntervalSinceNow))
        return String(format: "in %d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    private func nextOccurrence(of time: Date) -> Date {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return Calendar.current.nextDate(after: Date(), matching: parts, matchingPolicy: .nextTime) ?? time
    }

    private func arm() {
        wakeTime = nextOccurrence(of: wakeTime)
        phase = .armed
        UIApplication.shared.isIdleTimerDisabled = true
        let content = UNMutableNotificationContent()
        content.title = "Squat alarm"
        content.body = "Open \(ExampleApp.name) and do \(target) squats to stop the alarm."
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.hour, .minute], from: wakeTime), repeats: false)
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "squat-alarm", content: content, trigger: trigger))
        }
    }

    private func cancel() {
        phase = .idle
        UIApplication.shared.isIdleTimerDisabled = false
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["squat-alarm"])
    }

    private func ringNow() {
        phase = .ringing
        counter = SquatCounter(target: target)
        status = nil
        UIApplication.shared.isIdleTimerDisabled = true
        if !runner.running { startCamera() }
    }

    private func tick(_ now: Date) {
        if phase == .armed, now >= wakeTime { ringNow() }
        if phase == .ringing, now.timeIntervalSince(lastBeat) >= 1.2 {
            lastBeat = now
            ToneSynth.shared.alarmBeat()
        }
    }

    private func startCamera() {
        runner.start(studio: studio) { frame in
            guard phase == .ringing else { return }
            let next = counter.update(frame.mainPose.map { BodyPose($0, aspect: frame.aspect) })
            if next.justCounted { ToneSynth.shared.tick() }
            withAnimation(.snappy) { status = next }
            if next.done { finish(success: true) }
        }
    }

    private func finish(success: Bool) {
        phase = success ? .done : .idle
        UIApplication.shared.isIdleTimerDisabled = false
        runner.stop()
        if success { ToneSynth.shared.chime() }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["squat-alarm"])
    }
}

/// Classroom: raised hands with a seat map, and who is not paying attention (head down, phone, head
/// on the desk, turned away), with a 60-second attention trend.
struct ClassroomExampleView: View {
    @EnvironmentObject private var studio: StudioModel
    @StateObject private var runner = PoseRunner()
    @AppStorage("classroom.phones") private var phonesOn = true
    @AppStorage("classroom.rules") private var rulesText = "phone,sleeping,head_down,turned"
    @State private var people: [Int: Attention.Person] = [:]
    @State private var lastSeen: [Int: TimeInterval] = [:]
    @State private var summary = Attention.Summary()
    @State private var count = 0
    @State private var trend: [(time: Double, value: Double)] = []
    @State private var stateByIndex: [Attention.State] = []
    @State private var raisedByIndex: [Bool] = []

    /// Detectors that know "cell phone", best first.
    private static let detectors = ["yolov11m", "yolov8m", "yolov11s", "yolov8s", "yolov11n", "yolov8n"]
    private var detector: ModelInfo? {
        Self.detectors.first { studio.canUse($0) }.flatMap { ModelCatalog.model(named: $0) }
    }

    private var enabled: Set<Attention.State> {
        Set(rulesText.split(separator: ",").compactMap { Attention.State(rawValue: String($0)) })
    }

    private func color(_ state: Attention.State) -> Color {
        switch state {
        case .ok: return .green
        case .phone: return .red
        case .sleeping: return .gray
        case .headDown: return .cyan
        case .turned: return .purple
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            PoseControls(runner: runner, samples: [SampleMedia.office, SampleMedia.street], start: start)
            ExampleLayout(panelWidth: 340) {
                PoseStage(runner: runner, tint: { index, _ in index < stateByIndex.count ? color(stateByIndex[index]) : .gray },
                          placeholder: "Tap Start and point the camera at the class.") { size in
                    Canvas { context, _ in
                        for (index, pose) in runner.poses.enumerated() where index < stateByIndex.count {
                            let box = pose.boundingBox
                            var label = stateByIndex[index] == .ok ? "" : stateByIndex[index].title
                            if raisedByIndex[index] { label = "✋ " + label }
                            guard !label.isEmpty else { continue }
                            let resolved = context.resolve(Text(label).font(.caption.bold()).foregroundColor(.white))
                            let s = resolved.measure(in: size)
                            let tag = CGRect(x: box.minX * size.width, y: max(box.minY * size.height - s.height - 6, 0), width: s.width + 10, height: s.height + 6)
                            context.fill(Path(roundedRect: tag, cornerRadius: 5), with: .color(color(stateByIndex[index]).opacity(0.85)))
                            context.draw(resolved, at: CGPoint(x: tag.minX + 5, y: tag.minY + 3), anchor: .topLeading)
                        }
                        for d in runner.detections where d.label == "cell phone" {
                            let r = CGRect(x: d.boundingBox.minX * size.width, y: d.boundingBox.minY * size.height,
                                           width: d.boundingBox.width * size.width, height: d.boundingBox.height * size.height)
                            context.stroke(Path(r), with: .color(.red), lineWidth: 3)
                        }
                    }
                }
            } panel: {
                ExamplePanel { panel }
            }
        }
        .navigationTitle("Classroom")
        .onDisappear { runner.stop() }
        .modifier(AutoStart(start: start))
    }

    @ViewBuilder private var panel: some View {
        HStack(spacing: 18) {
            stat("\(count)", "people", .primary)
            stat("\(summary.raised)", "hands up", .orange)
            stat(count == 0 ? "–" : "\(attention)%", "attention", attention >= 80 ? .green : attention >= 60 ? .orange : .red)
        }
        Text("Raised hands by seat").font(.headline)
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        let n = summary.grid[row][column]
                        Text(n == 0 ? "" : "\(n)").font(.headline).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(n == 0 ? Color.secondary.opacity(0.15) : Color.orange, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        Text("Back of the room at the top, as the camera sees it.").font(.caption2).foregroundStyle(.secondary)
        Text("Not paying attention").font(.headline)
        ForEach(Attention.priority, id: \.self) { state in
            HStack {
                Circle().fill(color(state)).frame(width: 10, height: 10)
                Toggle(isOn: Binding(get: { enabled.contains(state) }, set: { on in
                    var set = enabled
                    if on { set.insert(state) } else { set.remove(state) }
                    rulesText = Attention.priority.filter { set.contains($0) }.map(\.rawValue).joined(separator: ",")
                })) {
                    HStack {
                        Text(state.title)
                        Spacer()
                        Text("\(summary.byState[state] ?? 0)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(state == .phone && detector == nil)
        }
        if detector == nil {
            Text("Phones need a detection model on this device (yolov8s or yolov11m, for example).").font(.caption).foregroundStyle(.secondary)
        } else {
            Toggle("Look for phones (\(detector!.name))", isOn: $phonesOn).disabled(runner.running)
        }
        Text("Attention, last 60 seconds").font(.headline)
        Chart(trend, id: \.time) { point in
            LineMark(x: .value("Seconds", point.time), y: .value("Attention", point.value))
                .interpolationMethod(.monotone)
            AreaMark(x: .value("Seconds", point.time), y: .value("Attention", point.value))
                .foregroundStyle(.linearGradient(colors: [.green.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .frame(height: 110)
        Text("States count after they last a moment (hand up 1.2 s, head down 2 s, phone or head on desk 3 s).")
            .font(.caption2).foregroundStyle(.secondary)
    }

    private var attention: Int {
        count == 0 ? 100 : Int((Double(count - summary.inattentive) / Double(count) * 100).rounded())
    }

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack {
            Text(value).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func start() {
        people = [:]; lastSeen = [:]; trend = []
        runner.start(studio: studio, detector: phonesOn ? detector : nil) { frame in
            let width = 1280.0
            let bodies = frame.bodies(width: width)
            let height = width / frame.aspect
            let phones = frame.detections.filter { $0.label == "cell phone" && $0.confidence >= 0.5 }.map {
                CGRect(x: $0.boundingBox.minX * width, y: $0.boundingBox.minY * height, width: $0.boundingBox.width * width, height: $0.boundingBox.height * height)
            }
            let ids = bodies.enumerated().map { $0.element.id ?? -1 - $0.offset }
            let infos = zip(ids, bodies).map { id, b in
                let line = Attention.shoulderLine(b)
                return Attention.PersonInfo(id: id, box: Attention.box(b), shoulderY: line?.y, shoulderWidth: line?.width, wrists: Attention.wrists(b))
            }
            let owned = Attention.assignPhones(phones, to: infos)
            var states: [Attention.State] = []
            var raised: [Bool] = []
            for (id, b) in zip(ids, bodies) {
                let person = people[id] ?? Attention.Person()
                people[id] = person
                lastSeen[id] = frame.time
                states.append(person.update(b, phones: owned[id] ?? [], enabled: enabled, now: frame.time))
                raised.append(person.raised)
            }
            // Forget people not seen for 5 seconds.
            for (id, seen) in lastSeen where frame.time - seen > 5 { people[id] = nil; lastSeen[id] = nil }
            let present = ids.compactMap { people[$0] }
            summary = Attention.summarize(present, width: width, height: height)
            count = present.count
            stateByIndex = states
            raisedByIndex = raised
            if trend.last.map({ frame.time - $0.time >= 1 }) ?? true {
                trend = (trend + [(frame.time, Double(attention))]).filter { frame.time - $0.time <= 60 }
            }
        }
    }
}
