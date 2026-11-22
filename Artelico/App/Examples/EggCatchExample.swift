import SwiftUI
import StudioCore

/// "Catch the eggs" (after hailo-apps' easter_game): eggs fall from the top, catch them with your hands.
/// One or two players, each with their own colour and score; the eggs come faster as the round goes on.
struct EggCatchExampleView: View {
    @EnvironmentObject private var studio: StudioModel
    @StateObject private var runner = PoseRunner(task: .pose, source: .front)
    @AppStorage("eggs.best") private var best = 0
    @AppStorage("eggs.players") private var playerCount = 1
    @AppStorage("eggs.size") private var eggSize = 1.3
    @AppStorage("eggs.speed") private var eggSpeed = 1.0
    @State private var game = EggGame()
    @State private var lastTime = 0.0
    @State private var now = 0.0
    @State private var tick = 0
    /// Eggs that hit the floor, drawn broken for a moment.
    @State private var splats: [(x: Double, kind: Int, time: Double)] = []

    static let playerColors: [Color] = [.cyan, Color(red: 1, green: 0.45, blue: 0.7)]
    private static let shells: [(Color, Color)] = [
        (Color(red: 0.55, green: 0.80, blue: 1.00), Color(red: 0.20, green: 0.45, blue: 0.85)),
        (Color(red: 1.00, green: 0.70, blue: 0.80), Color(red: 0.85, green: 0.30, blue: 0.50)),
        (Color(red: 0.70, green: 0.95, blue: 0.60), Color(red: 0.25, green: 0.65, blue: 0.30)),
        (Color(red: 0.85, green: 0.70, blue: 1.00), Color(red: 0.50, green: 0.30, blue: 0.80)),
        (Color(red: 1.00, green: 0.85, blue: 0.55), Color(red: 0.95, green: 0.50, blue: 0.20)),
    ]
    private static let gold = (Color(red: 1.0, green: 0.93, blue: 0.55), Color(red: 0.80, green: 0.55, blue: 0.05))

    var body: some View {
        VStack(spacing: 10) {
            PoseControls(runner: runner, samples: [SampleMedia.office, SampleMedia.street, SampleMedia.squats], start: startCamera)
            PoseStage(runner: runner, tint: tint, placeholder: "Tap Start and stand back so the camera sees you from head to waist. Your hands catch the eggs.") { size in
                field(size)
            }
            .padding(.horizontal, 10)
        }
        .navigationTitle("Catch the eggs")
        .onDisappear { runner.stop() }
        .modifier(AutoStart(start: startCamera))
    }

    /// Players in their colour, everyone else faint.
    private func tint(_ index: Int, _ pose: Pose) -> Color {
        guard let id = pose.trackID, let slot = game.players[id] else { return .white.opacity(0.25) }
        return Self.playerColors[slot]
    }

    @ViewBuilder private func field(_ size: CGSize) -> some View {
        let scale = size.width / EggGame.width
        ZStack {
            // The eggs redraw on every frame (`tick`); the scores and the Play button stay outside, or a tap
            // would be lost when the button is replaced mid-tap (as in Fruit ninja).
            Canvas { context, _ in draw(&context, scale: scale) }.id(tick)
            VStack {
                hud
                Spacer()
                if game.phase != .playing { menu.padding(.bottom, 30) }
            }
        }
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, scale: Double) {
        for egg in game.eggs {
            drawEgg(&context, at: CGPoint(x: egg.x * scale, y: egg.y * scale), radius: egg.radius * scale,
                    colors: egg.golden ? Self.gold : Self.shells[egg.kind % Self.shells.count], golden: egg.golden,
                    tilt: sin(now * 3 + egg.swayPhase) * 0.18)
        }
        for splat in splats {
            let age = now - splat.time
            drawSplat(&context, at: CGPoint(x: splat.x * scale, y: game.height * scale - 14 * scale), radius: 34 * eggSize * scale,
                      color: Self.shells[splat.kind % Self.shells.count].1, fade: max(0, 1 - age / 1.2))
        }
        // The catch circles around each player's hands.
        for hand in game.hands {
            let r = game.catchRadius * scale
            let rect = CGRect(x: hand.point.x * scale - r, y: hand.point.y * scale - r, width: 2 * r, height: 2 * r)
            context.fill(Path(ellipseIn: rect), with: .color(Self.playerColors[hand.player].opacity(0.25)))
            context.stroke(Path(ellipseIn: rect), with: .color(Self.playerColors[hand.player]), lineWidth: 3)
        }
        for pop in game.pops {
            let age = now - pop.time
            context.opacity = max(0, 1 - age / 0.9)
            context.draw(Text(pop.text).font(.system(size: 34, weight: .heavy, design: .rounded)).foregroundColor(Self.playerColors[pop.player]),
                         at: CGPoint(x: pop.x * scale, y: pop.y * scale - age * 90))
            context.opacity = 1
        }
    }

    /// An egg outline: round at the bottom, narrower at the top.
    private static func eggPath(radius r: Double) -> Path {
        var path = Path()
        for step in 0...48 {
            let t = Double(step) / 48 * 2 * .pi
            let point = CGPoint(x: 0.78 * r * cos(t) * (1 + 0.14 * sin(t)), y: r * sin(t))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// A painted egg: shaded shell, a white zigzag band with dots, a shine; golden eggs get a sparkle.
    private func drawEgg(_ context: inout GraphicsContext, at centre: CGPoint, radius r: Double, colors: (Color, Color), golden: Bool, tilt: Double) {
        context.drawLayer { layer in
            layer.translateBy(x: centre.x, y: centre.y)
            layer.rotate(by: .radians(tilt))
            let shape = Self.eggPath(radius: r)
            layer.drawLayer { shadow in
                shadow.addFilter(.shadow(color: .black.opacity(0.45), radius: r * 0.15, x: r * 0.05, y: r * 0.1))
                shadow.fill(shape, with: .radialGradient(Gradient(colors: [colors.0, colors.1]), center: CGPoint(x: -r * 0.3, y: -r * 0.35),
                                                         startRadius: 0, endRadius: r * 1.6))
            }
            layer.clip(to: shape)
            // A zigzag band across the middle, edged with two thin lines, and dots above and below.
            var zigzag = Path()
            let teeth = 6
            for i in 0...teeth * 2 {
                let x = -r + Double(i) * r / Double(teeth)
                let y = (i % 2 == 0 ? -0.12 : 0.12) * r + 0.1 * r
                if i == 0 { zigzag.move(to: CGPoint(x: x, y: y)) } else { zigzag.addLine(to: CGPoint(x: x, y: y)) }
            }
            let band = golden ? Color(red: 1, green: 1, blue: 0.85) : Color.white
            layer.stroke(zigzag, with: .color(band.opacity(0.9)), style: StrokeStyle(lineWidth: r * 0.1, lineJoin: .round))
            for y in [-0.12 * r, 0.32 * r] {
                layer.fill(Path(CGRect(x: -r, y: y - r * 0.025, width: 2 * r, height: r * 0.05)), with: .color(band.opacity(0.75)))
            }
            for (x, y) in [(-0.35, -0.45), (0.0, -0.55), (0.35, -0.45), (-0.4, 0.62), (0.0, 0.7), (0.4, 0.62)] {
                let d = r * 0.11
                layer.fill(Path(ellipseIn: CGRect(x: x * r - d / 2, y: y * r - d / 2, width: d, height: d)), with: .color(band.opacity(0.85)))
            }
            // Shine on the upper left.
            layer.fill(Path(ellipseIn: CGRect(x: -r * 0.5, y: -r * 0.75, width: r * 0.28, height: r * 0.45)), with: .color(.white.opacity(0.45)))
            if golden {
                var star = Path()
                for i in 0..<8 {
                    let a = Double(i) * .pi / 4, d = i % 2 == 0 ? r * 0.32 : r * 0.1
                    let p = CGPoint(x: r * 0.3 + cos(a) * d, y: -r * 0.3 + sin(a) * d)
                    if i == 0 { star.move(to: p) } else { star.addLine(to: p) }
                }
                star.closeSubpath()
                layer.fill(star, with: .color(.white.opacity(0.9)))
            }
            layer.stroke(shape, with: .color(.black.opacity(0.3)), lineWidth: max(1, r * 0.04))
        }
    }

    /// A broken egg on the floor: a yolk in a white puddle and two shell halves.
    private func drawSplat(_ context: inout GraphicsContext, at p: CGPoint, radius r: Double, color: Color, fade: Double) {
        context.drawLayer { layer in
            layer.opacity = fade
            layer.fill(Path(ellipseIn: CGRect(x: p.x - r * 1.3, y: p.y - r * 0.3, width: r * 2.6, height: r * 0.6)), with: .color(.white.opacity(0.9)))
            layer.fill(Path(ellipseIn: CGRect(x: p.x - r * 0.35, y: p.y - r * 0.22, width: r * 0.7, height: r * 0.44)), with: .color(.yellow))
            for side in [-1.0, 1.0] {
                var shell = Path()
                shell.move(to: CGPoint(x: p.x + side * r * 0.9, y: p.y - r * 0.1))
                shell.addQuadCurve(to: CGPoint(x: p.x + side * r * 1.6, y: p.y - r * 0.1), control: CGPoint(x: p.x + side * r * 1.25, y: p.y - r * 0.8))
                shell.addLine(to: CGPoint(x: p.x + side * r * 1.4, y: p.y - r * 0.3))
                shell.addLine(to: CGPoint(x: p.x + side * r * 1.2, y: p.y - r * 0.15))
                shell.closeSubpath()
                layer.fill(shell, with: .color(color))
            }
        }
    }

    // MARK: Scores and menu

    private var hud: some View {
        HStack(alignment: .top) {
            ForEach(0..<playerCount, id: \.self) { slot in
                VStack(alignment: .leading, spacing: 0) {
                    Text(playerCount == 1 ? "Score" : "Player \(slot + 1)").font(.caption.bold())
                    Text("\(game.scores[slot])").font(.system(size: 40, weight: .heavy, design: .rounded).monospacedDigit())
                }
                .foregroundStyle(Self.playerColors[slot])
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }
            Spacer()
            VStack(spacing: 0) {
                Text(game.phase == .playing ? String(format: "%.0f", game.remaining(now: now)) : "–")
                    .font(.system(size: 40, weight: .heavy, design: .rounded).monospacedDigit())
                Text("seconds").font(.caption.bold())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Label("\(game.misses) missed", systemImage: "heart.slash.fill").font(.headline)
                Text("Best \(best)").font(.subheadline)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(12)
    }

    private var menu: some View {
        VStack(spacing: 12) {
            if game.phase == .over {
                Text(resultText).font(.largeTitle.bold()).foregroundStyle(.white).shadow(radius: 6).multilineTextAlignment(.center)
            }
            Button(game.phase == .over ? "Play again" : "Play") { play() }
                .font(.title2.bold()).buttonStyle(.borderedProminent).disabled(!runner.running)
            VStack(spacing: 8) {
                Picker("Players", selection: $playerCount) {
                    Text("1 player").tag(1); Text("2 players").tag(2)
                }
                HStack(spacing: 16) {
                    Picker("Egg size", selection: $eggSize) {
                        Text("Normal").tag(1.0); Text("Big").tag(1.3); Text("Huge").tag(1.8)
                    }
                    Picker("Speed", selection: $eggSpeed) {
                        Text("Slow").tag(0.7); Text("Normal").tag(1.0); Text("Fast").tag(1.35)
                    }
                }
            }
            .pickerStyle(.segmented).frame(maxWidth: 520)
            .padding(8).background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            .environment(\.colorScheme, .dark)   // light labels on the dark strip
            Text("Catch the falling eggs with your hands. Golden eggs are worth 3. They fall faster as time runs out.")
                .foregroundStyle(.white).shadow(radius: 4).multilineTextAlignment(.center)
        }
    }

    private var resultText: String {
        if playerCount == 1 { return "Time! \(game.scores[0]) points" }
        let (a, b) = (game.scores[0], game.scores[1])
        return a == b ? "Time! A draw, \(a) each" : "Time! Player \(a > b ? 1 : 2) wins \(max(a, b)) to \(min(a, b))"
    }

    private func play() {
        game.playerCount = playerCount
        game.size = eggSize
        game.speed = eggSpeed
        splats = []
        game.start(now: now)
        tick &+= 1
    }

    private func startCamera() {
        game = EggGame(best: best)
        game.playerCount = playerCount
        runner.start(studio: studio) { frame in
            let dt = lastTime == 0 ? 0.03 : frame.time - lastTime
            lastTime = frame.time
            now = frame.time
            game.height = EggGame.width / frame.aspect
            #if DEBUG
            // Testing: `-autoplay` starts a round on the first frame.
            if game.phase == .ready, CommandLine.arguments.contains("-autoplay") { play() }
            #endif
            let wasPlaying = game.phase == .playing
            for event in game.update(frame.bodies(width: EggGame.width), now: frame.time, dt: dt) {
                switch event {
                case .caught(let egg, let player):
                    if egg.golden { ToneSynth.shared.chime() } else { ToneSynth.shared.play(player == 0 ? 1046.5 : 784, seconds: 0.12, bright: true, volume: 0.4) }
                case .missed(let egg):
                    splats.append((egg.x, egg.kind, frame.time))
                    ToneSynth.shared.play(150, seconds: 0.25, volume: 0.5)
                }
            }
            splats.removeAll { frame.time - $0.time > 1.2 }
            if wasPlaying, game.phase == .over {
                best = game.best
                ToneSynth.shared.chime()
            }
            tick &+= 1
        }
    }
}
