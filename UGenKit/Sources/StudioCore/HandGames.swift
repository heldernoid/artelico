import CoreGraphics
import Foundation

// Rules for the hand examples (gesture caption, fruit ninja, air band), ported from the UGen300 demos
// (vendor/ref-ugen300-demos/HandDemos). Hands come from the pose model's wrists and elbows plus
// hand_landmark_lite (21 points); the games work in a 1280 x 720 picture like the demo.

// MARK: - Reading hands

/// One hand: 21 points as fractions of the picture, which arm it belongs to, and whose.
public struct HandPoints: Sendable {
    public var side: String          // "L" or "R" (the person's own left or right, from the pose)
    public var person: Int           // index of the pose it came from (track number when known)
    public var points: [CGPoint]
    public var box: CGRect           // the square that was read, fractions of the picture

    public init(side: String, person: Int, points: [CGPoint], box: CGRect) {
        self.side = side; self.person = person; self.points = points; self.box = box
    }

    public func mirrored() -> HandPoints {
        HandPoints(side: side, person: person, points: points.map { CGPoint(x: 1 - $0.x, y: $0.y) },
                   box: CGRect(x: 1 - box.maxX, y: box.minY, width: box.width, height: box.height))
    }
}

/// Reads hands as the HandDemos do: for each person, a square past each wrist (along the forearm) goes
/// through hand_landmark_lite (224 x 224), whose 21 points are mapped back to the picture. Like MediaPipe,
/// the square is turned so the hand points up (the model reads upright hands far better: a thumbs-up
/// turned 90 degrees drops from 0.98 to 0.17 hand confidence), squares without a hand are dropped, and
/// with a `HandSmoother` the square and the points are steadied from frame to frame.
public enum HandReader {
    public static let modelName = "hand_landmark_lite"
    public static let side = 224
    /// Below this "a hand is present" score the square holds no hand (an arm, a sleeve, the background).
    public static let presenceThreshold: Float = 0.5

    public static func read(_ image: CGImage, poses: [Pose], device: any InferenceEngine, maxHands: Int = 4,
                            smoother: HandSmoother? = nil, time: TimeInterval = 0) async throws -> [HandPoints] {
        let width = Double(image.width), height = Double(image.height)
        guard let pixels = RGBAPixels(image) else { return [] }
        var hands: [HandPoints] = []
        for (index, pose) in poses.enumerated() {
            let body = BodyPose(pose, aspect: width / height, width: width)
            for (sideName, wrist, elbow) in [("R", BodyPose.rightWrist, BodyPose.rightElbow), ("L", BodyPose.leftWrist, BodyPose.leftElbow)] {
                guard hands.count < maxHands, let square = HandCrop.box(body, wrist: wrist, elbow: elbow) else { continue }
                let person = pose.trackID ?? index, key = "\(person)\(sideName)"
                var box = RotatedSquare(cx: square.x + square.size / 2, cy: square.y + square.size / 2, size: square.size,
                                        angle: HandCrop.uprightAngle(body, wrist: wrist, elbow: elbow))
                if let smoother { box = smoother.steady(box, key: key, time: time) }
                let tensors = try await device.infer(inputs: [pixels.crop(box, side: side)], model: modelName)
                // Outputs: hand present (1 value, first), landmarks in input pixels (63), handedness (1), world
                // coordinates in metres (63, small values). Take the 63 values in pixels.
                let singles = tensors.map { $0.floats() }.filter { $0.count == 1 }.map { $0[0] }
                if let presence = singles.first, presence < presenceThreshold { smoother?.forget(key); continue }
                let candidates = tensors.map { $0.floats() }.filter { $0.count == 63 }
                guard let landmarks = candidates.max(by: { ($0.map(abs).max() ?? 0) < ($1.map(abs).max() ?? 0) }) else { continue }
                var points = (0..<21).map { i -> CGPoint in
                    let p = box.toPicture(u: Double(landmarks[i * 3]), v: Double(landmarks[i * 3 + 1]), side: Double(side))
                    return CGPoint(x: p.x / width, y: p.y / height)
                }
                if let smoother { points = smoother.filter(points, key: key, time: time, scale: CGSize(width: width, height: height)) }
                hands.append(HandPoints(side: sideName, person: person, points: points,
                                        box: CGRect(x: (box.cx - box.size / 2) / width, y: (box.cy - box.size / 2) / height,
                                                    width: box.size / width, height: box.size / height)))
            }
        }
        smoother?.dropUnseen(before: time - 1)
        return hands
    }

    /// The square (x, y, size in pixels) scaled to 224 x 224 as RGB bytes; outside the picture is black.
    public static func crop(_ image: CGImage, x: Double, y: Double, size: Double) -> [UInt8]? {
        guard size >= 8 else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let scale = Double(side) / size
            // Core Graphics has y up: place the picture so the square's top-left lands at the top-left.
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: -x * scale, y: Double(side) - (Double(image.height) - y) * scale,
                                           width: Double(image.width) * scale, height: Double(image.height) * scale))
            return true
        }
        guard ok else { return nil }
        var rgb = [UInt8](repeating: 0, count: side * side * 3)
        for i in 0..<(side * side) {
            rgb[i * 3] = pixels[i * 4]; rgb[i * 3 + 1] = pixels[i * 4 + 1]; rgb[i * 3 + 2] = pixels[i * 4 + 2]
        }
        return rgb
    }
}

// MARK: - Hand crop from the pose

public enum HandCrop {
    /// The square around a hand: along the forearm past the wrist (size 1.1 x forearm, at least 60 px),
    /// or above the wrist when the elbow is not seen. Returns (x, y, size) in the body's pixels.
    public static func box(_ body: BodyPose, wrist: Int, elbow: Int, conf: Double = 0.35) -> (x: Double, y: Double, size: Double)? {
        let w = body[wrist]
        guard w.c >= conf else { return nil }
        let e = body[elbow]
        let size: Double, cx: Double, cy: Double
        if e.c >= conf {
            let forearm = hypot(w.x - e.x, w.y - e.y)
            size = max(60, forearm * 1.1)
            let dx = (w.x - e.x) / max(forearm, 1e-6), dy = (w.y - e.y) / max(forearm, 1e-6)
            cx = w.x + dx * size * 0.35; cy = w.y + dy * size * 0.35
        } else {
            size = body.height * 0.28; cx = w.x; cy = w.y - size * 0.2
        }
        return (cx - size / 2, cy - size / 2, size)
    }

    /// How far to turn the picture (radians) so the hand, past the wrist along the forearm, points up.
    /// 0 when the elbow is not seen.
    public static func uprightAngle(_ body: BodyPose, wrist: Int, elbow: Int, conf: Double = 0.35) -> Double {
        let w = body[wrist], e = body[elbow]
        guard w.c >= conf, e.c >= conf, hypot(w.x - e.x, w.y - e.y) > 1 else { return 0 }
        // Forearm direction (elbow to wrist), in picture coordinates (y down); "up" is -pi/2.
        return -Double.pi / 2 - atan2(w.y - e.y, w.x - e.x)
    }

    /// MediaPipe's 21-point hand skeleton.
    public static let edges: [(Int, Int)] = [(0, 1), (1, 2), (2, 3), (3, 4), (0, 5), (5, 6), (6, 7), (7, 8), (5, 9), (9, 10), (10, 11), (11, 12),
                                             (9, 13), (13, 14), (14, 15), (15, 16), (13, 17), (17, 18), (18, 19), (19, 20), (0, 17)]
}

// MARK: - GestureCaption

public enum HandSign: String, Sendable, CaseIterable {
    case ok, heart, thumbsUp, thumbsDown, rock, fist, one, two, three, four, five, pinky, unknown

    public var caption: String {
        switch self {
        case .ok: return "OK"
        case .heart: return "Finger heart"
        case .thumbsUp: return "Thumbs up"
        case .thumbsDown: return "Thumbs down"
        case .rock: return "Rock on"
        case .fist: return "0 · Fist"
        case .one: return "1"
        case .two: return "2 · Peace"
        case .three: return "3"
        case .four: return "4"
        case .five: return "5 · Open hand"
        case .pinky: return "Pinky promise"
        case .unknown: return "…"
        }
    }

    public var symbol: String {
        switch self {
        case .ok: return "👌"
        case .heart: return "🫰"
        case .thumbsUp: return "👍"
        case .thumbsDown: return "👎"
        case .rock: return "🤘"
        case .fist: return "✊"
        case .one: return "☝️"
        case .two: return "✌️"
        case .three: return "3️⃣"
        case .four: return "4️⃣"
        case .five: return "🖐️"
        case .pinky: return "🤙"
        case .unknown: return "❔"
        }
    }
}

public enum HandSigns {
    static let tip = ["thumb": 4, "index": 8, "middle": 12, "ring": 16, "pinky": 20]
    static let pip = ["index": 6, "middle": 10, "ring": 14, "pinky": 18]

    static func d(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(Double(a.x - b.x), Double(a.y - b.y)) }

    /// Straight fingers: a fingertip farther from the wrist than its middle joint x 1.15; thumb: tip
    /// farther from the pinky's base than the thumb's base x 1.25. Works for any hand direction.
    public static func fingers(_ p: [CGPoint]) -> [String: Bool] {
        var s: [String: Bool] = [:]
        for f in ["index", "middle", "ring", "pinky"] { s[f] = d(p[tip[f]!], p[0]) > d(p[pip[f]!], p[0]) * 1.15 }
        s["thumb"] = d(p[4], p[17]) > d(p[2], p[17]) * 1.25
        return s
    }

    public static func classify(_ p: [CGPoint]) -> HandSign {
        guard p.count == 21 else { return .unknown }
        let s = fingers(p)
        let ext = ["index", "middle", "ring", "pinky"].map { s[$0]! }
        let n = ext.filter { $0 }.count
        let size = max(d(p[0], p[9]), 1e-6)
        let thumbTouchesIndex = d(p[4], p[8]) < size * 0.4
        if thumbTouchesIndex && s["middle"]! && s["ring"]! && s["pinky"]! { return .ok }
        if thumbTouchesIndex && n == 0 { return .heart }
        if s["thumb"]! && n == 0 { return p[4].y < p[2].y ? .thumbsUp : .thumbsDown }
        if s["index"]! && s["pinky"]! && !s["middle"]! && !s["ring"]! { return .rock }
        if n == 0 { return .fist }
        if ext == [true, false, false, false] { return .one }
        if ext == [true, true, false, false] { return .two }
        if ext == [true, true, true, false] { return .three }
        if n == 4 { return s["thumb"]! ? .five : .four }
        if ext == [false, false, false, true] { return .pinky }
        return .unknown
    }
}

/// Shows a sign only after it has been seen `frames` frames in a row (no flicker).
public final class SignSmoother {
    public let frames: Int
    private var last: HandSign?
    private var count = 0
    public private(set) var stable: HandSign?

    public init(frames: Int = 4) { self.frames = frames }

    @discardableResult
    public func update(_ sign: HandSign) -> HandSign? {
        if sign == last { count += 1 } else { last = sign; count = 1 }
        if count >= frames { stable = sign }
        return stable
    }
}

// MARK: - FruitNinja

/// Does the segment p0-p1 touch the circle (centre c, radius r)?
public func segmentHitsCircle(_ p0: CGPoint, _ p1: CGPoint, _ c: CGPoint, _ r: Double) -> Bool {
    let dx = Double(p1.x - p0.x), dy = Double(p1.y - p0.y)
    let l2 = dx * dx + dy * dy
    let t = l2 == 0 ? 0 : max(0, min(1, (Double(c.x - p0.x) * dx + Double(c.y - p0.y) * dy) / l2))
    return hypot(Double(p0.x) + t * dx - Double(c.x), Double(p0.y) + t * dy - Double(c.y)) <= r
}

/// The game: fruit thrown up from below the 1280 x 720 field; a fast fingertip stroke through a fruit cuts
/// it (+1), a bomb costs 5; rounds last `seconds`.
public final class FruitGame {
    public struct Item: Identifiable, Sendable {
        public let id: Int
        public let kind: Int          // index into `kinds`, -1 = bomb
        public var x: Double, y: Double, vx: Double, vy: Double
        public let radius: Double
        public var cutAt: TimeInterval?
        public var halves: [(x: Double, y: Double, vx: Double, vy: Double)] = []
        public var isBomb: Bool { kind < 0 }
    }

    public enum Phase: Sendable { case ready, playing, over }

    public static let width = 1280.0, height = 720.0, gravity = 1400.0
    /// Name, radius.
    public static let kinds: [(name: String, radius: Double)] = [("apple", 34), ("watermelon", 46), ("orange", 32), ("grapes", 28), ("lemon", 30)]

    public let seconds: TimeInterval
    public private(set) var phase: Phase = .ready
    public private(set) var score = 0
    public private(set) var best: Int
    public private(set) var items: [Item] = []
    public private(set) var startedAt: TimeInterval = 0
    public private(set) var trails: [String: [(point: CGPoint, time: TimeInterval)]] = [:]
    /// How fast the game runs: 1 normal, 0.5 half speed (the fruit fly the same arcs, slower; new fruit come
    /// less often to match).
    public var speed = 1.0
    /// How big the fruit and bombs are (and the area that counts as a hit): 1 normal.
    public var size = 1.0
    private var lastSpawn: TimeInterval = 0
    private var nextGap = 0.7
    private var nextID = 0
    private var random: () -> Double

    public init(seconds: TimeInterval = 30, best: Int = 0, random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.seconds = seconds; self.best = best; self.random = random
    }

    public func remaining(now: TimeInterval) -> TimeInterval { phase == .playing ? max(0, seconds - (now - startedAt)) : 0 }

    public func start(now: TimeInterval) {
        phase = .playing; score = 0; items = []; startedAt = now; lastSpawn = now; trails = [:]
    }

    private func spawn() {
        let bomb = random() < 0.18
        let kind = bomb ? -1 : min(Self.kinds.count - 1, Int(random() * Double(Self.kinds.count)))
        let radius = (bomb ? 34 : Self.kinds[kind].radius) * size
        items.append(Item(id: nextID, kind: kind, x: 200 + random() * (Self.width - 400), y: Self.height + 40,
                          vx: -160 + random() * 320, vy: -(900 + random() * 250), radius: radius))
        nextID += 1
    }

    /// One frame: fingertips (key = which hand, point in the 1280 x 720 field). Returns what was cut.
    @discardableResult
    public func update(tips: [(key: String, point: CGPoint)], now: TimeInterval, dt: TimeInterval) -> [Item] {
        let dt = min(0.1, max(0, dt))
        for tip in tips { trails[tip.key, default: []].append((tip.point, now)) }
        for key in trails.keys { trails[key] = trails[key]!.filter { now - $0.time < 0.35 } }
        var cut: [Item] = []
        guard phase == .playing else { return cut }
        if now - startedAt >= seconds {
            phase = .over; best = max(best, score)
            return cut
        }
        if now - lastSpawn > nextGap / speed {
            spawn(); lastSpawn = now; nextGap = 0.5 + random() * 0.4
        }
        for i in items.indices {
            let step = dt * speed   // game time: the same arcs, faster or slower
            items[i].vy += Self.gravity * step; items[i].x += items[i].vx * step; items[i].y += items[i].vy * step
            for h in items[i].halves.indices {
                items[i].halves[h].vy += Self.gravity * step
                items[i].halves[h].x += items[i].halves[h].vx * step; items[i].halves[h].y += items[i].halves[h].vy * step
            }
            guard items[i].cutAt == nil else { continue }
            for trail in trails.values where trail.count >= 2 {
                let a = trail[trail.count - 2].point, b = trail[trail.count - 1].point
                guard segmentHitsCircle(a, b, CGPoint(x: items[i].x, y: items[i].y), items[i].radius + 6) else { continue }
                let speed = hypot(Double(b.x - a.x), Double(b.y - a.y)) / max(dt, 1e-3)
                guard speed > 250 else { continue }
                let direction = b.x >= a.x ? 1.0 : -1.0
                items[i].cutAt = now
                items[i].halves = [(items[i].x, items[i].y, items[i].vx - 150 * direction, items[i].vy * 0.5),
                                   (items[i].x, items[i].y, items[i].vx + 150 * direction, items[i].vy * 0.5)]
                score += items[i].isBomb ? -5 : 1
                cut.append(items[i])
                break
            }
        }
        items.removeAll { $0.y > Self.height + 80 || ($0.cutAt.map { now - $0 > 0.8 } ?? false) }
        return cut
    }
}

// MARK: - AirBand

/// Three zones across the picture: drums (left), piano (middle, 8 keys), guitar (right). Several people
/// can play at once; each hand is followed by an id.
public final class AirBand {
    public enum Event: Equatable, Sendable {
        case drum(Drum)
        case piano(key: Int, high: Bool)
        case chord(Int)
    }

    public enum Drum: String, Sendable { case kick, snare, hihat }
    public enum Zone: Sendable { case drums, piano, guitar }

    public static let noteNames = ["Do", "Re", "Mi", "Fa", "Sol", "La", "Si", "Do'"]
    public static let noteFrequencies = [261.6, 293.7, 329.6, 349.2, 392.0, 440.0, 493.9, 523.3]
    public static let chords: [(name: String, notes: [Double])] = [("C", [261.6, 329.6, 392.0]), ("G", [196.0, 246.9, 392.0]),
                                                                    ("Am", [220.0, 261.6, 329.6]), ("F", [174.6, 220.0, 349.2])]

    public let width: Double, height: Double
    private var previous: [String: (x: Double, y: Double, t: TimeInterval)] = [:]
    private var lastFire: [String: TimeInterval] = [:]
    private var lastKey: [String: Int?] = [:]

    public init(width: Double = 1280, height: Double = 720) { self.width = width; self.height = height }

    public func zone(_ x: Double) -> Zone { x < width / 3 ? .drums : (x < 2 * width / 3 ? .piano : .guitar) }

    /// Drums: a quick downward hit (> 900 px/s) plays hi-hat / snare / kick by height. Piano: entering a
    /// key plays it (the upper part of the picture an octave higher). Guitar: a downward strum (> 700 px/s)
    /// plays one of four chords by height.
    public func update(_ hands: [(id: String, x: Double, y: Double)], now: TimeInterval) -> [Event] {
        var events: [Event] = []
        for hand in hands {
            let p = previous[hand.id] ?? (hand.x, hand.y, now)
            let vy = (hand.y - p.y) / max(1e-3, now - p.t)
            let fired = lastFire[hand.id] ?? -.infinity
            switch zone(hand.x) {
            case .drums:
                if vy > 900, now - fired > 0.18 {
                    events.append(.drum(hand.y < height * 0.4 ? .hihat : hand.y < height * 0.7 ? .snare : .kick)); lastFire[hand.id] = now
                }
                lastKey[hand.id] = .some(nil)
            case .piano:
                let key = max(0, min(7, Int((hand.x - width / 3) / (width / 3) * 8)))
                if (lastKey[hand.id] ?? nil) != key, now - fired > 0.08 {
                    events.append(.piano(key: key, high: hand.y < height * 0.45)); lastFire[hand.id] = now
                }
                lastKey[hand.id] = key
            case .guitar:
                if vy > 700, now - fired > 0.3 {
                    events.append(.chord(max(0, min(3, Int(hand.y / height * 4))))); lastFire[hand.id] = now
                }
                lastKey[hand.id] = .some(nil)
            }
            previous[hand.id] = (hand.x, hand.y, now)
        }
        return events
    }
}
