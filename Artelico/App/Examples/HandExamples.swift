import SwiftUI
import StudioCore

// The hand examples (UGen300 HandDemos: GestureCaption, FruitNinja, AirBand) (on this device's chip in Artelico, on the stick in Hailo Studio).
// Rules in StudioCore/HandGames.swift; hands from the pose model + hand_landmark_lite (HandKit.swift).

/// GestureCaption: the sign each hand makes, as a big caption (numbers 0-5, OK, thumbs up/down, rock,
/// finger heart, pinky promise). Rule based, no training.
struct GestureCaptionExampleView: View {
    @EnvironmentObject private var studio: StudioModel
    @StateObject private var runner = PoseRunner(task: .pose, source: .front)
    @State private var smoothers: [String: SignSmoother] = [:]
    @State private var signs: [(key: String, side: String, sign: HandSign, at: CGPoint)] = []
    @State private var seen: [HandSign: Int] = [:]

    var body: some View {
        VStack(spacing: 10) {
            PoseControls(runner: runner, start: start)
            ExampleLayout(panelWidth: 300) {
                PoseStage(runner: runner, tint: { _, _ in .white.opacity(0.35) }, placeholder: "Tap Start and show your hands to the camera.") { size in
                    HandLayer(hands: runner.hands, color: { $0.side == "R" ? .green : .cyan })
                    ForEach(signs, id: \.key) { item in
                        VStack(spacing: 0) {
                            Text(item.sign.symbol).font(.system(size: 54))
                            Text(item.sign.caption).font(.title3.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 4).background(.black.opacity(0.6), in: Capsule())
                        }
                        .position(x: item.at.x * size.width, y: max(60, item.at.y * size.height - 70))
                    }
                }
            } panel: {
                ExamplePanel {
                    Text("Hand signs").font(.headline)
                    if let main = signs.first {
                        HStack {
                            Text(main.sign.symbol).font(.system(size: 64))
                            Text(main.sign.caption).font(.title.bold())
                        }
                    } else {
                        Text("Show a hand").foregroundStyle(.secondary)
                    }
                    Divider()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], alignment: .leading, spacing: 8) {
                        ForEach(HandSign.allCases.filter { $0 != .unknown }, id: \.self) { sign in
                            HStack(spacing: 6) {
                                Text(sign.symbol)
                                Text(sign.caption).font(.caption).lineLimit(1)
                                if (seen[sign] ?? 0) > 0 { Image(systemName: "checkmark").font(.caption2).foregroundStyle(.green) }
                            }
                        }
                    }
                    Text("Try them all: a tick appears next to each sign the camera has seen. Hold a sign still for a moment.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Hand signs")
        .onDisappear { runner.stop() }
        .modifier(AutoStart(start: start))
    }

    private func start() {
        smoothers = [:]
        runner.start(studio: studio, hands: true) { frame in
            var shown: [(String, String, HandSign, CGPoint)] = []
            for hand in frame.hands {
                let key = "\(hand.person)\(hand.side)"
                let smoother = smoothers[key] ?? SignSmoother(frames: 4)
                smoothers[key] = smoother
                if let sign = smoother.update(HandSigns.classify(hand.points)), sign != .unknown {
                    shown.append((key, hand.side, sign, hand.points[9]))
                    if seen[sign] == nil { seen[sign] = 1; ToneSynth.shared.tick() }
                }
            }
            signs = shown.map { (key: $0.0, side: $0.1, sign: $0.2, at: $0.3) }
        }
    }
}

/// FruitNinja: your index fingertip is the blade. Fruit flies up; slice it with a quick stroke, avoid the
/// bombs; 30-second rounds.
struct FruitNinjaExampleView: View {
    @EnvironmentObject private var studio: StudioModel
    @StateObject private var runner = PoseRunner(task: .pose, source: .front)
    @AppStorage("fruit.best") private var best = 0
    /// Fruit size and game speed (1 = the demo's). Big by default: at 1 the fruit look tiny on an iPad.
    @AppStorage("fruit.size") private var fruitSize = 1.5
    @AppStorage("fruit.speed") private var fruitSpeed = 1.0
    @State private var game = FruitGame()
    @State private var lastTime = 0.0
    @State private var now = 0.0
    @State private var tick = 0

    private static let colors: [Color] = [.red, .green, .orange, .purple, .yellow]
    private static let emoji = ["🍎", "🍉", "🍊", "🍇", "🍋"]

    var body: some View {
        VStack(spacing: 10) {
            PoseControls(runner: runner, start: startCamera)
            ZStack {
                PoseStage(runner: runner, tint: { _, _ in .white.opacity(0.2) }, placeholder: "Tap Start, stand back and raise a hand: your index finger is the blade.") { size in
                    field(size)
                }
            }
            .padding(.horizontal, 10)
        }
        .navigationTitle("Fruit ninja")
        .onDisappear { runner.stop() }
        .modifier(AutoStart(start: startCamera))
    }

    @ViewBuilder private func field(_ size: CGSize) -> some View {
        let sx = size.width / FruitGame.width, sy = size.height / FruitGame.height
        ZStack {
            // The fruit and the blade trail redraw on every frame (`tick`); the score and the Play button
            // stay outside, or a tap would be lost when the button is replaced mid-tap.
            ZStack {
            Canvas { context, _ in
                for trail in game.trails.values where trail.count >= 2 {
                    var path = Path()
                    for (i, p) in trail.enumerated() {
                        let q = CGPoint(x: p.point.x * sx, y: p.point.y * sy)
                        if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
                    }
                    context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                }
            }
            ForEach(game.items) { item in
                if item.cutAt == nil {
                    Text(item.isBomb ? "💣" : Self.emoji[item.kind]).font(.system(size: item.radius * 2 * min(sx, sy) * 1.1))
                        .position(x: item.x * sx, y: item.y * sy)
                } else {
                    ForEach(Array(item.halves.enumerated()), id: \.offset) { index, half in
                        Text(item.isBomb ? "💥" : Self.emoji[item.kind]).font(.system(size: item.radius * 2 * min(sx, sy)))
                            .rotationEffect(.degrees(index == 0 ? -40 : 40)).opacity(0.7)
                            .position(x: half.x * sx, y: half.y * sy)
                    }
                }
            }
            }
            .id(tick)
            VStack {
                HStack {
                    Text("Score \(game.score)").font(.title.bold())
                    Spacer()
                    if game.phase == .playing { Text(String(format: "%.0f s", game.remaining(now: now))).font(.title.bold().monospacedDigit()) }
                    Spacer()
                    Text("Best \(best)").font(.title3)
                }
                .foregroundStyle(.white).shadow(radius: 4).padding()
                Spacer()
                if game.phase != .playing {
                    VStack(spacing: 12) {
                        if game.phase == .over { Text("Time! \(game.score) points").font(.largeTitle.bold()).foregroundStyle(.white).shadow(radius: 6) }
                        Button(game.phase == .over ? "Play again" : "Play") {
                            game.size = fruitSize
                            game.speed = fruitSpeed
                            game.start(now: now)
                        }
                        .font(.title2.bold()).buttonStyle(.borderedProminent).disabled(!runner.running)
                        HStack(spacing: 16) {
                            Picker("Fruit size", selection: $fruitSize) {
                                Text("Normal").tag(1.0); Text("Big").tag(1.5); Text("Huge").tag(2.2)
                            }
                            Picker("Speed", selection: $fruitSpeed) {
                                Text("Slow").tag(0.6); Text("Normal").tag(1.0); Text("Fast").tag(1.4)
                            }
                        }
                        .pickerStyle(.segmented).frame(maxWidth: 520)
                        .padding(8).background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                        Text("Slice fruit with a quick stroke of your index finger. Bombs cost 5 points.")
                            .foregroundStyle(.white).shadow(radius: 4)
                    }
                    .padding(.bottom, 40)
                }
            }
        }
    }

    private func startCamera() {
        game = FruitGame(best: best)
        runner.start(studio: studio, hands: true) { frame in
            let dt = lastTime == 0 ? 0.03 : frame.time - lastTime
            lastTime = frame.time
            now = frame.time
            let tips = frame.hands.map { (key: "\($0.person)\($0.side)", point: CGPoint(x: $0.points[8].x * FruitGame.width, y: $0.points[8].y * FruitGame.height)) }
            let wasPlaying = game.phase == .playing
            for item in game.update(tips: tips, now: frame.time, dt: dt) {
                if item.isBomb { ToneSynth.shared.play(150, seconds: 0.3, bright: true, volume: 0.6) } else { ToneSynth.shared.play(1000 + Double(item.kind) * 120, seconds: 0.08, bright: true, volume: 0.35) }
            }
            if wasPlaying, game.phase == .over {
                best = game.best
                ToneSynth.shared.chime()
            }
            tick &+= 1
        }
    }
}

/// AirBand: drums on the left, piano in the middle, guitar on the right. Wave your hands; several
/// people can play together. Wrists only (lowest delay).
struct AirBandExampleView: View {
    @EnvironmentObject private var studio: StudioModel
    @StateObject private var runner = PoseRunner(task: .pose, source: .front)
    @State private var band = AirBand()
    @State private var flashes: [Int: Date] = [:]   // zone (0 drums, 1 piano, 2 guitar) -> when it was played
    @State private var lastEvent = ""

    var body: some View {
        VStack(spacing: 10) {
            PoseControls(runner: runner, start: start)
            PoseStage(runner: runner, tint: { _, _ in .white.opacity(0.4) }, placeholder: "Tap Start, stand back and play: hit down for drums and guitar, slide across the piano keys.") { size in
                TimelineView(.animation) { timeline in
                    Canvas { context, _ in
                        let third = size.width / 3
                        let zones: [(String, Color)] = [("Drums", .red), ("Piano", .green), ("Guitar", .orange)]
                        for (i, zone) in zones.enumerated() {
                            let age = flashes[i].map { timeline.date.timeIntervalSince($0) } ?? 10
                            let glow = max(0, 1 - age / 0.3)
                            context.fill(Path(CGRect(x: CGFloat(i) * third, y: 0, width: third, height: size.height)), with: .color(zone.1.opacity(0.12 + 0.35 * glow)))
                            context.draw(Text(zone.0).font(.title2.bold()).foregroundColor(.white), at: CGPoint(x: (CGFloat(i) + 0.5) * third, y: 24))
                        }
                        for k in 0...8 {   // piano keys
                            let x = third + CGFloat(k) * third / 8
                            var line = Path(); line.move(to: CGPoint(x: x, y: 44)); line.addLine(to: CGPoint(x: x, y: size.height))
                            context.stroke(line, with: .color(.white.opacity(0.25)), lineWidth: 1)
                            if k < 8 {
                                context.draw(Text(AirBand.noteNames[k]).font(.caption.bold()).foregroundColor(.white.opacity(0.8)),
                                             at: CGPoint(x: x + third / 16, y: size.height - 14))
                            }
                        }
                        for (fraction, name) in [(0.4, "hi-hat"), (0.7, "snare"), (1.0, "kick")] {   // drum levels
                            let y = size.height * fraction
                            var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: third, y: y))
                            context.stroke(line, with: .color(.red.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                            context.draw(Text(name).font(.caption).foregroundColor(.white), at: CGPoint(x: 34, y: y - 10))
                        }
                        for (i, chord) in AirBand.chords.enumerated() {   // guitar chords by height
                            context.draw(Text(chord.name).font(.headline).foregroundColor(.white),
                                         at: CGPoint(x: size.width - 26, y: (CGFloat(i) + 0.5) * size.height / 4))
                        }
                        for pose in runner.poses {
                            for joint in [BodyPose.leftWrist, BodyPose.rightWrist] where pose.keypoints[joint].confidence > 0.5 {
                                let p = pose.keypoints[joint].position
                                context.fill(Path(ellipseIn: CGRect(x: p.x * size.width - 12, y: p.y * size.height - 12, width: 24, height: 24)), with: .color(.white))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            Text(lastEvent.isEmpty ? "Turn the volume up." : lastEvent).font(.callout).foregroundStyle(.secondary).padding(.bottom, 6)
        }
        .navigationTitle("Air band")
        .onDisappear { runner.stop() }
        .modifier(AutoStart(start: start))
    }

    private func start() {
        band = AirBand()
        runner.start(studio: studio) { frame in
            var hands: [(id: String, x: Double, y: Double)] = []
            for (index, pose) in frame.poses.enumerated() {
                for (side, joint) in [("L", BodyPose.leftWrist), ("R", BodyPose.rightWrist)] where pose.keypoints[joint].confidence > 0.4 {
                    let p = pose.keypoints[joint].position
                    let id = "\(pose.trackID ?? index)\(side)"
                    hands.append((id, Double(p.x) * 1280, Double(p.y) * 720))
                }
            }
            for event in band.update(hands, now: frame.time) {
                switch event {
                case .drum(let kind):
                    ToneSynth.shared.drum(kind.rawValue); lastEvent = "Drum: \(kind.rawValue)"; flashes[0] = Date()
                case .piano(let key, let high):
                    ToneSynth.shared.piano(AirBand.noteFrequencies[key] * (high ? 2 : 1))
                    lastEvent = "Piano: \(AirBand.noteNames[key])\(high ? " (high)" : "")"; flashes[1] = Date()
                case .chord(let i):
                    AirBand.chords[i].notes.forEach { ToneSynth.shared.pluck($0) }; lastEvent = "Guitar: \(AirBand.chords[i].name)"; flashes[2] = Date()
                }
            }
        }
    }
}
