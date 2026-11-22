import SwiftUI
import StudioCore

/// Y3 "Air instrument": the picture is cut into coloured strips, each a note. Move a hand into a strip
/// to play it; several people can play at once.
struct AirInstrumentExampleView: View {
    @EnvironmentObject private var studio: StudioModel
    @StateObject private var runner = PoseRunner()
    @AppStorage("air.zones") private var zones = 5
    @AppStorage("air.bright") private var bright = false
    @State private var instrument = AirInstrument(zones: 5)
    @State private var lit: [Int: Date] = [:]
    @State private var notesPlayed = 0

    private static let names = ["Do", "Re", "Mi", "Sol", "La", "Do'", "Re'", "Mi'"]
    private static let colors: [Color] = [.cyan, .green, .yellow, .orange, .pink, .purple, .blue, .mint]

    var body: some View {
        VStack(spacing: 10) {
            PoseControls(runner: runner, samples: [SampleMedia.office, SampleMedia.street], start: start)
            ExampleLayout(panelWidth: 280) {
                PoseStage(runner: runner, placeholder: "Tap Start, stand back and wave your hands through the coloured strips.") { size in
                    TimelineView(.animation) { timeline in
                        Canvas { context, _ in
                            let strip = size.width / CGFloat(zones)
                            for zone in 0..<zones {
                                let rect = CGRect(x: CGFloat(zone) * strip, y: 0, width: strip, height: size.height)
                                let age = lit[zone].map { timeline.date.timeIntervalSince($0) } ?? 10
                                let glow = max(0, 1 - age / 0.35)
                                context.fill(Path(rect), with: .color(Self.colors[zone % 8].opacity(0.12 + 0.45 * glow)))
                                context.stroke(Path(rect), with: .color(.white.opacity(0.25)), lineWidth: 1)
                                context.draw(Text(Self.names[zone % 8]).font(.title2.bold()).foregroundColor(.white),
                                             at: CGPoint(x: rect.midX, y: 28))
                            }
                            for pose in runner.poses {
                                for joint in [BodyPose.leftWrist, BodyPose.rightWrist] where pose.keypoints[joint].confidence > 0.5 {
                                    let p = pose.keypoints[joint].position
                                    let c = CGPoint(x: p.x * size.width, y: p.y * size.height)
                                    context.fill(Path(ellipseIn: CGRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28)), with: .color(.white.opacity(0.9)))
                                }
                            }
                        }
                    }
                }
            } panel: {
                ExamplePanel {
                    Text("Air instrument").font(.headline)
                    Text("Each strip is a note. Moving a hand into a strip plays it; keeping it there is silent.").font(.callout)
                    Stepper("Notes: \(zones)", value: $zones, in: 3...8)
                        .onChange(of: zones) { _, value in instrument = AirInstrument(zones: value) }
                    Toggle("Bright sound", isOn: $bright)
                    LabeledContent("Notes played", value: "\(notesPlayed)")
                    Button("Test the sound") { for i in 0..<zones { ToneSynth.shared.play(ToneSynth.scale[i], bright: bright, delay: Double(i) * 0.12) } }
                    Text("Turn the volume up. Several people can play at once.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Air instrument")
        .onDisappear { runner.stop() }
        .modifier(AutoStart(start: start))
    }

    private func start() {
        instrument = AirInstrument(zones: zones)
        runner.start(studio: studio) { frame in
            for zone in instrument.update(frame.bodies(), now: frame.time) {
                ToneSynth.shared.play(ToneSynth.scale[zone % ToneSynth.scale.count], seconds: 0.3, bright: bright)
                lit[zone] = Date()
                notesPlayed += 1
            }
        }
    }
}

/// Y5 "Yoga coach": six poses in random order. Hold each for the set time; hints say what to fix.
struct YogaExampleView: View {
    @EnvironmentObject private var studio: StudioModel
    @StateObject private var runner = PoseRunner()
    @AppStorage("yoga.hold") private var hold = 8.0
    @State private var round = YogaRound()
    @State private var state: YogaRound.State?

    var body: some View {
        VStack(spacing: 10) {
            PoseControls(runner: runner, samples: [SampleMedia.office, SampleMedia.street], start: start)
            ExampleLayout(panelWidth: 330) {
                PoseStage(runner: runner, tint: { _, _ in state?.coach?.inPose == true ? .green : .orange },
                          placeholder: "Tap Start and step back until your whole body is in the picture.") { _ in
                    if state?.celebrating == true {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 90)).foregroundStyle(.green)
                            Text("Well done!").font(.largeTitle.bold()).foregroundStyle(.white).shadow(radius: 6)
                        }
                        .transition(.scale)
                    } else if let hint = state?.coach?.hint, !hint.isEmpty {
                        VStack {
                            Spacer()
                            Text(hint).font(.title3.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .background(.black.opacity(0.6), in: Capsule())
                                .padding(.bottom, 16)
                        }
                    }
                }
            } panel: {
                ExamplePanel { panel }
            }
        }
        .navigationTitle("Yoga coach")
        .onDisappear { runner.stop() }
        .modifier(AutoStart(start: start))
    }

    @ViewBuilder private var panel: some View {
        if state?.finished == true || round.finished {
            Image(systemName: "trophy.fill").font(.system(size: 56)).foregroundStyle(.yellow)
            Text("All \(round.pool.count) poses done").font(.title2.bold())
            Button("Another round") { restart() }.buttonStyle(.borderedProminent)
        } else {
            let coach = state?.coach
            HStack {
                Text(coach?.title ?? round.currentPose?.title ?? "").font(.title.bold())
                Spacer()
                Text("\(round.completed + 1) / \(round.pool.count)").font(.headline.monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(Array((coach?.steps ?? round.currentPose?.steps ?? []).enumerated()), id: \.offset) { index, step in
                Label(step, systemImage: "\(index + 1).circle.fill")
            }
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 14)
                Circle().trim(from: 0, to: (coach?.held ?? 0) / max(hold, 0.1))
                    .stroke(coach?.inPose == true ? Color.green : Color.orange, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: coach?.held ?? 0)
                VStack {
                    Text(String(format: "%.0f s", max(0, hold - (coach?.held ?? 0)))).font(.title.bold().monospacedDigit())
                    Text(coach?.inPose == true ? "Hold it" : "Get into the pose").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, height: 150)
            .frame(maxWidth: .infinity)
            HStack {
                Button("Skip") { round.skip() }
                Spacer()
                Button("Restart") { restart() }
            }
            Divider()
            Stepper(String(format: "Hold for %.0f s", hold), value: $hold, in: 3...30)
                .onChange(of: hold) { _, _ in restart() }
        }
    }

    private func restart() {
        round = YogaRound(holdTarget: hold)
        state = nil
    }

    private func start() {
        restart()
        runner.start(studio: studio) { frame in
            let body = frame.mainPose.map { BodyPose($0, aspect: frame.aspect) }
            let wasFinished = round.finished
            let next = round.update(body, now: frame.time)
            if next.justCompletedPose { ToneSynth.shared.chime() }
            if next.finished && !wasFinished {
                for (i, f) in [523.25, 659.25, 783.99, 1046.5, 783.99, 1046.5].enumerated() { ToneSynth.shared.play(f, seconds: 0.3, delay: Double(i) * 0.13) }
            }
            withAnimation(.snappy) { state = next }
        }
    }
}
