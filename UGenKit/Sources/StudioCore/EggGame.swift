import CoreGraphics
import Foundation

// Rules of the "Catch the eggs" example, after hailo-apps' easter_game (pipeline_apps/easter_game):
// players catch eggs with their hands (wrist keypoints), each tracked person is a player with a score,
// and a round has a countdown. There, eggs sit still for 3 s at random spots; here they fall from the
// top, faster and more often as the round goes on, and one that reaches the bottom is a miss.

public final class EggGame {
    public struct Egg: Identifiable, Sendable {
        public let id: Int
        public var x: Double, y: Double
        public let radius: Double
        public let vy: Double
        /// Colour of the shell (index into the screen's palette); golden eggs are worth more.
        public let kind: Int
        public let golden: Bool
        /// A small sideways sway, so the eggs don't fall like stones.
        public let swayPhase: Double
        public var points: Int { golden ? 3 : 1 }
    }

    public enum Event: Sendable {
        case caught(egg: Egg, player: Int)
        case missed(Egg)
    }

    /// A "+1" floating up where an egg was caught.
    public struct Pop: Sendable {
        public let x: Double, y: Double
        public let text: String
        public let player: Int
        public let time: TimeInterval
    }

    public enum Phase: Sendable { case ready, playing, over }

    public static let kinds = 5
    /// The field is `width` wide; its height follows the picture (set every frame).
    public static let width = 1000.0

    public let seconds: TimeInterval
    public var height = 750.0
    /// 1 or 2 players.
    public var playerCount = 1
    /// How fast the eggs fall and come (1 normal) and how big they are, as in Fruit ninja.
    public var speed = 1.0
    public var size = 1.0

    public private(set) var phase: Phase = .ready
    public private(set) var eggs: [Egg] = []
    public private(set) var scores: [Int] = [0, 0]
    public private(set) var misses = 0
    public private(set) var best: Int
    public private(set) var pops: [Pop] = []
    public private(set) var startedAt: TimeInterval = 0
    /// Which tracked person plays which slot (0 or 1).
    public private(set) var players: [Int: Int] = [:]
    /// Each player's hands this frame (for drawing the catch circles).
    public private(set) var hands: [(player: Int, point: CGPoint)] = []
    private var lastSeen: [Int: TimeInterval] = [:]
    private var nextSpawn: TimeInterval = 0
    private var nextID = 0
    private var random: () -> Double

    public init(seconds: TimeInterval = 60, best: Int = 0, random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.seconds = seconds; self.best = best; self.random = random
    }

    public func remaining(now: TimeInterval) -> TimeInterval { phase == .playing ? max(0, seconds - (now - startedAt)) : 0 }

    /// 0 at the start of a round, 1 at the end: drives the rising speed.
    public func progress(now: TimeInterval) -> Double { phase == .playing ? min(1, max(0, (now - startedAt) / seconds)) : 0 }

    /// How fast eggs fall now (field pixels per second of game time): 2.2 times faster by the end.
    public func fallSpeed(now: TimeInterval) -> Double { 190 * (1 + 1.2 * progress(now: now)) }

    /// Seconds between eggs now (real time): about one a second at first, three a second at the end with
    /// two players.
    public func spawnGap(now: TimeInterval) -> Double {
        1.1 / (1 + 1.4 * progress(now: now)) / (playerCount == 2 ? 1.6 : 1) / speed
    }

    public var catchRadius: Double { 38 * size }

    public func start(now: TimeInterval) {
        phase = .playing
        eggs = []; pops = []; scores = [0, 0]; misses = 0
        startedAt = now; nextSpawn = now + 0.6
    }

    /// Where a hand is: the wrist pushed a third of a forearm further out (the palm, which does the
    /// catching), or the wrist alone when the elbow isn't seen.
    public static func palms(_ body: BodyPose, conf: Double = 0.3) -> [CGPoint] {
        [(BodyPose.leftWrist, BodyPose.leftElbow), (BodyPose.rightWrist, BodyPose.rightElbow)].compactMap { wrist, elbow in
            guard let w = body.point(wrist, conf) else { return nil }
            guard let e = body.point(elbow, conf) else { return w }
            return CGPoint(x: w.x + 0.35 * (w.x - e.x), y: w.y + 0.35 * (w.y - e.y))
        }
    }

    /// Gives tracked people player slots. Between rounds the biggest people (nearest the camera) are the
    /// players, picked again every frame; during a round a person keeps their slot while seen, and a slot
    /// is freed after 1.5 s out of sight and goes to the next new person, again the biggest first.
    private func assignPlayers(_ bodies: [BodyPose], now: TimeInterval) {
        if phase != .playing { players = [:] }
        for body in bodies { if let id = body.id { lastSeen[id] = now } }
        for (id, slot) in players where now - (lastSeen[id] ?? -.infinity) > 1.5 || slot >= playerCount { players[id] = nil }
        let byHeight = bodies.filter { $0.id != nil }.sorted { Self.height($0) > Self.height($1) }
        for body in byHeight {
            guard let id = body.id, players[id] == nil else { continue }
            guard let free = (0..<playerCount).first(where: { slot in !players.values.contains(slot) }) else { break }
            players[id] = free
        }
    }

    private static func height(_ body: BodyPose) -> Double {
        let ys = body.points.filter { $0.c >= 0.3 }.map(\.y)
        return (ys.max() ?? 0) - (ys.min() ?? 0)
    }

    private func spawn(now: TimeInterval) {
        let radius = 30 * size
        let golden = random() < 0.1
        eggs.append(Egg(id: nextID, x: radius * 2 + random() * (Self.width - radius * 4), y: -radius * 1.4, radius: radius,
                        vy: fallSpeed(now: now) * (0.85 + 0.3 * random()), kind: min(Self.kinds - 1, Int(random() * Double(Self.kinds))),
                        golden: golden, swayPhase: random() * 2 * .pi))
        nextID += 1
    }

    /// One frame: the people in field coordinates (`Self.width` wide, `height` high). Returns what happened.
    @discardableResult
    public func update(_ bodies: [BodyPose], now: TimeInterval, dt: TimeInterval) -> [Event] {
        assignPlayers(bodies, now: now)
        hands = bodies.flatMap { body in
            body.id.flatMap { players[$0] }.map { slot in Self.palms(body).map { (slot, $0) } } ?? []
        }
        pops.removeAll { now - $0.time > 0.9 }
        guard phase == .playing else { return [] }
        if now - startedAt >= seconds {
            phase = .over
            best = max(best, scores.max() ?? 0)
            eggs = []
            return []
        }
        if now >= nextSpawn {
            spawn(now: now)
            nextSpawn = now + spawnGap(now: now) * (0.7 + 0.6 * random())
        }
        let step = min(0.1, max(0, dt)) * speed   // game time: slower or faster with the speed setting
        var events: [Event] = []
        var kept: [Egg] = []
        for var egg in eggs {
            egg.y += egg.vy * step
            egg.x = min(Self.width - egg.radius, max(egg.radius, egg.x + sin(now * 2.5 + egg.swayPhase) * 40 * step))
            // The nearest hand within reach catches it.
            let reach = egg.radius + catchRadius
            let catcher = hands.map { (player: $0.player, d: hypot(Double($0.point.x) - egg.x, Double($0.point.y) - egg.y)) }
                .filter { $0.d <= reach }.min { $0.d < $1.d }
            if let catcher {
                scores[catcher.player] += egg.points
                pops.append(Pop(x: egg.x, y: egg.y, text: "+\(egg.points)", player: catcher.player, time: now))
                events.append(.caught(egg: egg, player: catcher.player))
            } else if egg.y - egg.radius > height {
                misses += 1
                events.append(.missed(egg))
            } else {
                kept.append(egg)
            }
        }
        eggs = kept
        return events
    }
}
