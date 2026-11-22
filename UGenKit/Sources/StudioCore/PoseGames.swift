import CoreGraphics
import Foundation

// Rules for the pose examples (raise hand to flip, hand-raise counter, air instrument, yoga coach,
// squat alarm, classroom), ported from the UGen300 demos (vendor/ref-ugen300-demos: Y2, Y3, Y4, Y5,
// WakeUp, Classroom). Pure logic: keypoints in, decisions out. Times are passed in, so the rules can be
// tested without waiting.
//
// The demos measure in pixels of a webcam picture (640 wide for the Y series, 1280 x 720 for Classroom),
// and their thresholds are tuned for that. `BodyPose` puts a pose into the same kind of coordinates.

/// One keypoint in "demo pixels": x across, y down, c = confidence.
public struct BodyPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var c: Double

    public init(_ x: Double, _ y: Double, _ c: Double) {
        self.x = x; self.y = y; self.c = c
    }
}

/// The 17 COCO keypoints of one person, in the coordinates of a picture `width` pixels wide.
public struct BodyPose: Sendable {
    public static let nose = 0, leftEye = 1, rightEye = 2, leftEar = 3, rightEar = 4
    public static let leftShoulder = 5, rightShoulder = 6, leftElbow = 7, rightElbow = 8
    public static let leftWrist = 9, rightWrist = 10, leftHip = 11, rightHip = 12
    public static let leftKnee = 13, rightKnee = 14, leftAnkle = 15, rightAnkle = 16

    public var points: [BodyPoint]
    /// The picture size these points are measured in.
    public var width: Double
    public var height: Double
    /// Tracking number, when the pose had one.
    public var id: Int?

    public init(points: [BodyPoint], width: Double = 640, height: Double = 480, id: Int? = nil) {
        precondition(points.count == 17, "a body has 17 keypoints")
        self.points = points; self.width = width; self.height = height; self.id = id
    }

    /// From a decoded pose (positions as fractions of the picture) and the picture's aspect ratio.
    public init(_ pose: Pose, aspect: Double, width: Double = 640) {
        let height = width / max(aspect, 0.01)
        self.init(points: pose.keypoints.map { BodyPoint(Double($0.position.x) * width, Double($0.position.y) * height, Double($0.confidence)) },
                  width: width, height: height, id: pose.trackID)
    }

    /// Left and right swapped on screen (front camera shown as a mirror). Keypoint names stay anatomical.
    public func mirrored() -> BodyPose {
        var copy = self
        copy.points = points.map { BodyPoint(width - $0.x, $0.y, $0.c) }
        return copy
    }

    public subscript(_ index: Int) -> BodyPoint { points[index] }

    /// The point when it is seen with at least `conf`.
    public func point(_ index: Int, _ conf: Double) -> CGPoint? {
        let p = points[index]
        return p.c >= conf ? CGPoint(x: p.x, y: p.y) : nil
    }

    func seen(_ index: Int, _ conf: Double) -> Bool { points[index].c >= conf }
}

/// Angle at `b` (degrees) of the corner a-b-c; nil when a point is missing.
func jointAngle(_ a: CGPoint?, _ b: CGPoint?, _ c: CGPoint?) -> Double? {
    guard let a, let b, let c else { return nil }
    let bax = Double(a.x - b.x), bay = Double(a.y - b.y)
    let bcx = Double(c.x - b.x), bcy = Double(c.y - b.y)
    let na = hypot(bax, bay), nc = hypot(bcx, bcy)
    guard na > 0, nc > 0 else { return nil }
    return acos(max(-1, min(1, (bax * bcx + bay * bcy) / (na * nc)))) * 180 / .pi
}

// MARK: - Y2: raise a hand to flip slides

public enum RaisedHands: String, Sendable {
    case none, right, left, both
}

public enum SlideAction: String, Sendable {
    case next, previous, restart
}

public enum HandGestures {
    /// Which hands are above the head: a wrist more than `margin` pixels above the nose.
    public static func raised(_ body: BodyPose, conf: Double = 0.5, margin: Double = 40) -> RaisedHands {
        guard let nose = body.point(BodyPose.nose, conf) else { return .none }
        let limit = nose.y - margin
        let leftUp = (body.point(BodyPose.leftWrist, conf)?.y).map { $0 < limit } ?? false
        let rightUp = (body.point(BodyPose.rightWrist, conf)?.y).map { $0 < limit } ?? false
        if leftUp && rightUp { return .both }
        if rightUp { return .right }
        if leftUp { return .left }
        return .none
    }
}

/// Turns per-frame gestures into slide actions without flipping by accident: the same gesture for
/// `confirmFrames` frames in a row, the hands lowered between two actions, and a cooldown after each.
public final class GestureController {
    public let confirmFrames: Int
    public let cooldown: TimeInterval
    private var last: RaisedHands = .none
    private var stableCount = 0
    private var armed = true
    private var lastTrigger: TimeInterval = -.infinity

    public init(confirmFrames: Int = 4, cooldown: TimeInterval = 1.2) {
        self.confirmFrames = confirmFrames
        self.cooldown = cooldown
    }

    public func update(_ gesture: RaisedHands, now: TimeInterval) -> SlideAction? {
        if gesture == last { stableCount += 1 } else { stableCount = 1; last = gesture }
        if gesture == .none { armed = true; return nil }
        if now - lastTrigger < cooldown || !armed || stableCount < confirmFrames { return nil }
        let action: SlideAction
        switch gesture {
        case .right: action = .next
        case .left: action = .previous
        case .both: action = .restart
        case .none: return nil
        }
        armed = false
        lastTrigger = now
        return action
    }
}

// MARK: - Y4: count raised hands

public enum HandRaiseCounter {
    /// A wrist more than `margin` above the nose (or, without a nose, above the shoulders' mean height).
    public static func isRaised(_ body: BodyPose, conf: Double = 0.5, margin: Double = 20) -> Bool {
        let base: Double
        if let nose = body.point(BodyPose.nose, conf) {
            base = nose.y
        } else if let l = body.point(BodyPose.leftShoulder, conf), let r = body.point(BodyPose.rightShoulder, conf) {
            base = (l.y + r.y) / 2
        } else {
            return false
        }
        for wrist in [BodyPose.leftWrist, BodyPose.rightWrist] {
            if let w = body.point(wrist, conf), w.y < base - margin { return true }
        }
        return false
    }

    /// (people with a hand up, people seen).
    public static func count(_ bodies: [BodyPose], conf: Double = 0.5, margin: Double = 20) -> (raised: Int, total: Int) {
        (bodies.filter { isRaised($0, conf: conf, margin: margin) }.count, bodies.count)
    }
}

// MARK: - Y3: air instrument

/// The picture is cut into `zones` vertical strips, one note each. A wrist that moves into a new strip
/// plays that strip's note (not while it stays there); the same note waits `cooldown` before it plays again.
public final class AirInstrument {
    public let zones: Int
    public let cooldown: TimeInterval
    private var lastZone: [String: Int] = [:]
    private var lastFire: [Int: TimeInterval] = [:]

    public init(zones: Int = 5, cooldown: TimeInterval = 0.15) {
        self.zones = zones
        self.cooldown = cooldown
    }

    public func zone(ofX x: Double, width: Double) -> Int {
        max(0, min(zones - 1, Int(x / width * Double(zones))))
    }

    /// Notes to play for this frame. Each person's wrists are followed separately (by tracking number
    /// when there is one, else by position in the list).
    public func update(_ bodies: [BodyPose], conf: Double = 0.5, now: TimeInterval) -> [Int] {
        var fired: [Int] = []
        var seenKeys = Set<String>()
        for (index, body) in bodies.enumerated() {
            let person = body.id.map { "#\($0)" } ?? "\(index)"
            for (hand, joint) in [("L", BodyPose.leftWrist), ("R", BodyPose.rightWrist)] {
                let key = person + hand
                seenKeys.insert(key)
                let zone = body.point(joint, conf).map { self.zone(ofX: Double($0.x), width: body.width) }
                if let zone, zone != lastZone[key], now - (lastFire[zone] ?? -.infinity) >= cooldown {
                    fired.append(zone)
                    lastFire[zone] = now
                }
                lastZone[key] = zone
            }
        }
        for key in lastZone.keys where !seenKeys.contains(key) { lastZone[key] = nil }
        return fired
    }
}

// MARK: - Y5: yoga coach

public struct YogaPose: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let steps: [String]
    /// (in the pose, what to fix next).
    public let check: @Sendable (BodyPose) -> (ok: Bool, hint: String)
}

public enum Yoga {
    static let conf = 0.45

    static func legsVisible(_ b: BodyPose, conf: Double = 0.4) -> Bool {
        (b.seen(BodyPose.leftKnee, conf) && b.seen(BodyPose.leftAnkle, conf)) || (b.seen(BodyPose.rightKnee, conf) && b.seen(BodyPose.rightAnkle, conf))
    }

    static func torso(_ b: BodyPose) -> Double? {
        guard let ls = b.point(BodyPose.leftShoulder, conf), let rs = b.point(BodyPose.rightShoulder, conf),
              let lh = b.point(BodyPose.leftHip, conf), let rh = b.point(BodyPose.rightHip, conf) else { return nil }
        return abs(Double(lh.y + rh.y) / 2 - Double(ls.y + rs.y) / 2)
    }

    static func kneeAngles(_ b: BodyPose) -> [Double] {
        [jointAngle(b.point(BodyPose.leftHip, conf), b.point(BodyPose.leftKnee, conf), b.point(BodyPose.leftAnkle, conf)),
         jointAngle(b.point(BodyPose.rightHip, conf), b.point(BodyPose.rightKnee, conf), b.point(BodyPose.rightAnkle, conf))].compactMap { $0 }
    }

    static func handsOverHead(_ b: BodyPose) -> Bool? {
        guard let nose = b.point(BodyPose.nose, conf), let lw = b.point(BodyPose.leftWrist, conf), let rw = b.point(BodyPose.rightWrist, conf) else { return nil }
        return lw.y < nose.y && rw.y < nose.y
    }

    public static let tree = YogaPose(id: "tree", title: "Tree",
                                      steps: ["Stand tall", "Raise both arms", "Hands above your head"]) { b in
        guard b.point(BodyPose.nose, conf) != nil else { return (false, "Show your head to the camera") }
        guard b.seen(BodyPose.leftWrist, conf), b.seen(BodyPose.rightWrist, conf) else { return (false, "Raise both hands so the camera sees them") }
        return handsOverHead(b) == true ? (true, "") : (false, "Raise both hands above your head")
    }

    public static let warrior2 = YogaPose(id: "warrior", title: "Warrior II",
                                          steps: ["Feet apart", "Arms out to the sides", "Level with your shoulders"]) { b in
        guard let ls = b.point(BodyPose.leftShoulder, conf), let rs = b.point(BodyPose.rightShoulder, conf) else { return (false, "Show your shoulders to the camera") }
        guard let lw = b.point(BodyPose.leftWrist, conf), let rw = b.point(BodyPose.rightWrist, conf) else { return (false, "Raise both arms to the sides") }
        let shoulderY = Double(ls.y + rs.y) / 2, shoulderW = abs(Double(ls.x - rs.x))
        let tolerance = max(40, shoulderW * 0.4)
        let level = abs(Double(lw.y) - shoulderY) < tolerance && abs(Double(rw.y) - shoulderY) < tolerance
        let wide = abs(Double(lw.x - rw.x)) > shoulderW * 1.3
        if !wide { return (false, "Spread your arms out wide") }
        if !level { return (false, "Keep your arms level with your shoulders") }
        return (true, "")
    }

    public static let warrior1 = YogaPose(id: "warrior1", title: "Warrior I",
                                          steps: ["Step one foot forward", "Bend the front knee", "Raise both arms up"]) { b in
        guard let up = handsOverHead(b) else { return (false, "Raise both hands overhead") }
        if !up { return (false, "Raise both hands above your head") }
        if !legsVisible(b) { return (false, "Step back so the camera sees your legs") }
        return kneeAngles(b).contains { $0 < 150 } ? (true, "") : (false, "Bend your front knee (lunge)")
    }

    public static let triangle = YogaPose(id: "triangle", title: "Triangle",
                                          steps: ["Feet wide apart", "Lean to one side", "One arm up, one down"]) { b in
        guard let ls = b.point(BodyPose.leftShoulder, conf), let rs = b.point(BodyPose.rightShoulder, conf),
              let lw = b.point(BodyPose.leftWrist, conf), let rw = b.point(BodyPose.rightWrist, conf) else { return (false, "Show your shoulders and both hands") }
        let shoulderW = abs(Double(ls.x - rs.x))
        if shoulderW < 1 { return (false, "Face the camera") }
        if abs(Double(lw.x - rw.x)) <= shoulderW * 1.2 { return (false, "Spread your arms apart") }
        if abs(Double(lw.y - rw.y)) <= shoulderW * 0.7 { return (false, "Tilt: one hand up, one hand down") }
        return (true, "")
    }

    public static let squat = YogaPose(id: "squat", title: "Squat",
                                       steps: ["Feet apart", "Bend your knees, squat down", "Palms together at your chest"]) { b in
        if !legsVisible(b) { return (false, "Step back so the camera sees your legs") }
        let knees = kneeAngles(b)
        if knees.isEmpty || knees.min()! >= 120 { return (false, "Bend your knees and squat down") }
        guard let ls = b.point(BodyPose.leftShoulder, conf), let rs = b.point(BodyPose.rightShoulder, conf),
              let lw = b.point(BodyPose.leftWrist, conf), let rw = b.point(BodyPose.rightWrist, conf) else { return (false, "Bring your hands to your chest") }
        let shoulderW = abs(Double(ls.x - rs.x))
        return hypot(Double(lw.x - rw.x), Double(lw.y - rw.y)) < max(60, shoulderW * 0.5) ? (true, "") : (false, "Put your palms together at your chest")
    }

    public static let treeOneLeg = YogaPose(id: "tree1", title: "Tree, one leg",
                                            steps: ["Stand on one leg", "Lift the other foot", "Raise both arms up"]) { b in
        guard let up = handsOverHead(b) else { return (false, "Raise both hands overhead") }
        if !up { return (false, "Raise both hands above your head") }
        if !legsVisible(b) { return (false, "Step back so the camera sees your legs") }
        guard let la = b.point(BodyPose.leftAnkle, conf), let ra = b.point(BodyPose.rightAnkle, conf), let t = torso(b) else { return (false, "Show both feet to the camera") }
        return abs(Double(la.y - ra.y)) > t * 0.4 ? (true, "") : (false, "Lift one foot off the ground")
    }

    public static let all: [YogaPose] = [tree, warrior2, warrior1, triangle, squat, treeOneLeg]
}

/// One pose: checks every frame, counts the time held once the pose has been right for
/// `confirmFrames` frames in a row, and is done after `holdTarget` seconds.
public final class YogaCoach {
    public struct State: Sendable {
        public var title: String
        public var inPose: Bool
        public var held: TimeInterval
        public var target: TimeInterval
        public var done: Bool
        public var hint: String
        public var steps: [String]
    }

    public let pose: YogaPose
    public let holdTarget: TimeInterval
    public let confirmFrames: Int
    private var stable = 0
    private var accumulated: TimeInterval = 0
    private var lastTick: TimeInterval?
    private(set) public var done = false
    private var hint = ""

    public init(_ pose: YogaPose, holdTarget: TimeInterval = 8, confirmFrames: Int = 3) {
        self.pose = pose; self.holdTarget = holdTarget; self.confirmFrames = confirmFrames
    }

    public func update(_ body: BodyPose?, now: TimeInterval, active: Bool = true) -> State {
        guard active else { stable = 0; lastTick = nil; return state(confirmed: false) }
        let (ok, newHint) = body.map(pose.check) ?? (false, "Step into the camera's view")
        hint = newHint
        stable = ok ? stable + 1 : 0
        let confirmed = stable >= confirmFrames
        if confirmed {
            if let lastTick { accumulated += now - lastTick }
            lastTick = now
            if accumulated >= holdTarget { done = true }
        } else {
            lastTick = nil
        }
        return state(confirmed: confirmed)
    }

    func state(confirmed: Bool) -> State {
        State(title: pose.title, inPose: confirmed, held: min(accumulated, holdTarget), target: holdTarget, done: done,
              hint: confirmed || done ? "" : hint, steps: pose.steps)
    }
}

/// A round of poses in random order, each once; a short celebration between poses; finished after the last.
public final class YogaRound {
    public struct State: Sendable {
        public var coach: YogaCoach.State?
        public var completed: Int
        public var total: Int
        public var celebrating: Bool
        public var finished: Bool
        public var justCompletedPose: Bool
    }

    public let holdTarget: TimeInterval
    public let celebration: TimeInterval
    public let pool: [YogaPose]
    private var deck: [YogaPose] = []
    private var coach: YogaCoach?
    private var celebratingSince: TimeInterval?
    private(set) public var completed = 0
    private(set) public var finished = false

    public init(pool: [YogaPose] = Yoga.all, holdTarget: TimeInterval = 8, celebration: TimeInterval = 2, shuffled: Bool = true) {
        self.pool = pool; self.holdTarget = holdTarget; self.celebration = celebration
        restart(shuffled: shuffled)
    }

    public func restart(shuffled: Bool = true) {
        completed = 0; finished = false; celebratingSince = nil
        deck = shuffled ? pool.shuffled() : pool.reversed()
        coach = nextCoach()
    }

    private func nextCoach() -> YogaCoach? {
        deck.isEmpty ? nil : YogaCoach(deck.removeLast(), holdTarget: holdTarget)
    }

    public var currentPose: YogaPose? { coach?.pose }

    public func skip() {
        guard !finished else { return }
        advance()
    }

    private func advance() {
        completed += 1
        celebratingSince = nil
        coach = nextCoach()
        if coach == nil { finished = true }
    }

    public func update(_ body: BodyPose?, now: TimeInterval) -> State {
        if finished || coach == nil { return State(coach: nil, completed: completed, total: pool.count, celebrating: false, finished: true, justCompletedPose: false) }
        if let since = celebratingSince {
            if now - since >= celebration { advance(); return update(body, now: now) }
            return State(coach: coach!.state(confirmed: false), completed: completed, total: pool.count, celebrating: true, finished: false, justCompletedPose: false)
        }
        let state = coach!.update(body, now: now)
        var just = false
        if state.done { celebratingSince = now; just = true }
        return State(coach: state, completed: completed, total: pool.count, celebrating: state.done, finished: false, justCompletedPose: just)
    }
}

// MARK: - WakeUp: squat counter

/// Stand -> down -> stand counts one squat. Knee angle (hip-knee-ankle, mean of the sides that are
/// seen) above `upAngle` is standing, below `downAngle` is down; a change needs `confirmFrames` frames.
public final class SquatCounter {
    public enum Phase: String, Sendable { case stand, down }

    public struct Status: Sendable {
        public var count: Int
        public var phase: Phase
        public var angle: Double?
        public var visible: Bool
        public var done: Bool
        public var justCounted: Bool
    }

    public let target: Int
    public let upAngle: Double
    public let downAngle: Double
    public let confirmFrames: Int
    public let conf: Double
    private(set) public var count = 0
    private(set) public var phase: Phase = .stand
    private var pending: Phase?
    private var pendingFrames = 0

    public init(target: Int = 5, upAngle: Double = 160, downAngle: Double = 105, confirmFrames: Int = 3, conf: Double = 0.4) {
        self.target = target; self.upAngle = upAngle; self.downAngle = downAngle; self.confirmFrames = confirmFrames; self.conf = conf
    }

    public var done: Bool { count >= target }

    public func reset() { count = 0; phase = .stand; pending = nil; pendingFrames = 0 }

    public static func kneeAngle(_ b: BodyPose, conf: Double = 0.4) -> Double? {
        let sides = [jointAngle(b.point(BodyPose.leftHip, conf), b.point(BodyPose.leftKnee, conf), b.point(BodyPose.leftAnkle, conf)),
                     jointAngle(b.point(BodyPose.rightHip, conf), b.point(BodyPose.rightKnee, conf), b.point(BodyPose.rightAnkle, conf))].compactMap { $0 }
        return sides.isEmpty ? nil : sides.reduce(0, +) / Double(sides.count)
    }

    public func update(_ body: BodyPose?) -> Status {
        guard let body, let angle = Self.kneeAngle(body, conf: conf) else {
            pending = nil; pendingFrames = 0
            return Status(count: count, phase: phase, angle: nil, visible: false, done: done, justCounted: false)
        }
        var just = false
        let candidate: Phase? = angle < downAngle ? .down : (angle > upAngle ? .stand : nil)
        if candidate == nil || candidate == phase {
            pending = nil; pendingFrames = 0
        } else {
            if candidate == pending { pendingFrames += 1 } else { pending = candidate; pendingFrames = 1 }
            if pendingFrames >= confirmFrames {
                if phase == .down, candidate == .stand, !done { count += 1; just = true }
                phase = candidate!
                pending = nil; pendingFrames = 0
            }
        }
        return Status(count: count, phase: phase, angle: angle, visible: true, done: done, justCounted: just)
    }
}

// MARK: - Classroom: raised hands and attention

public enum Attention {
    public static let keypointConf = 0.3
    public static let raiseHold: TimeInterval = 1.2, downHold: TimeInterval = 2.0, phoneHold: TimeInterval = 3.0
    public static let sleepHold: TimeInterval = 3.0, turnHold: TimeInterval = 2.5
    /// In shoulder widths.
    public static let raiseAboveEyes = 0.6, phoneNearWrist = 1.2
    public static let downEyeEar = 0.12, downNoseShoulder = 0.18, turnFarEye = 0.30
    /// People with shoulders narrower than this (pixels of a 1280-wide picture) are too far away for the face rules.
    public static let minShoulderWidthForFace = 60.0

    public enum State: String, Sendable, CaseIterable {
        case ok, phone, sleeping, headDown = "head_down", turned
        public var title: String {
            switch self {
            case .ok: return "Paying attention"
            case .phone: return "Phone"
            case .sleeping: return "Head on desk"
            case .headDown: return "Head down"
            case .turned: return "Turned away"
            }
        }
    }

    /// The rules people can switch off, in priority order.
    public static let priority: [State] = [.phone, .sleeping, .headDown, .turned]

    public struct Flags: Equatable, Sendable {
        public var raised = false, headDown = false, sleeping = false, turned = false
    }

    static func ok(_ b: BodyPose, _ i: Int) -> Bool { b[i].c >= keypointConf }

    public static func shoulderLine(_ b: BodyPose) -> (y: Double, width: Double)? {
        guard ok(b, BodyPose.leftShoulder), ok(b, BodyPose.rightShoulder) else { return nil }
        return ((b[BodyPose.leftShoulder].y + b[BodyPose.rightShoulder].y) / 2, abs(b[BodyPose.leftShoulder].x - b[BodyPose.rightShoulder].x))
    }

    /// This frame's judgement, before the hold times.
    public static func instantFlags(_ b: BodyPose) -> Flags {
        var f = Flags()
        let shoulders = shoulderLine(b)
        let eyes = [BodyPose.leftEye, BodyPose.rightEye].filter { ok(b, $0) }.map { b[$0].y }
        let eyeLine: Double? = eyes.isEmpty ? (ok(b, BodyPose.nose) ? b[BodyPose.nose].y : nil) : eyes.reduce(0, +) / Double(eyes.count)
        // Raised: wrist 0.6 shoulder widths above the eyes and elbow above the shoulders; with the wrist
        // out of the picture, the elbow above the eyes.
        if let s = shoulders, s.width > 0, s.width >= minShoulderWidthForFace * 0.5, let eyeLine {
            for (wrist, elbow) in [(BodyPose.leftWrist, BodyPose.leftElbow), (BodyPose.rightWrist, BodyPose.rightElbow)] {
                let elbowUp = ok(b, elbow) && b[elbow].y < s.y
                if ok(b, wrist) {
                    if elbowUp && b[wrist].y < eyeLine - raiseAboveEyes * s.width { f.raised = true }
                } else if ok(b, elbow) && b[elbow].y < eyeLine {
                    f.raised = true
                }
            }
        }
        // Head down / head on the desk (never judged when the head is not seen).
        if let s = shoulders, s.width > 0 {
            let headSeen = ok(b, BodyPose.nose) || !eyes.isEmpty
            if headSeen && s.width >= minShoulderWidthForFace {
                if ok(b, BodyPose.nose) {
                    if b[BodyPose.nose].y > s.y { f.sleeping = true } else if b[BodyPose.nose].y > s.y - downNoseShoulder * s.width { f.headDown = true }
                }
                let ears = [BodyPose.leftEar, BodyPose.rightEar].filter { ok(b, $0) }.map { b[$0].y }
                if !eyes.isEmpty, !ears.isEmpty,
                   eyes.reduce(0, +) / Double(eyes.count) > ears.reduce(0, +) / Double(ears.count) + downEyeEar * s.width {
                    f.headDown = true
                }
            }
        }
        // Turned: one eye clear, the other hardly seen.
        let le = b[BodyPose.leftEye].c, re = b[BodyPose.rightEye].c
        if let s = shoulders, s.width >= minShoulderWidthForFace, (le >= 0.5 && re < turnFarEye) || (re >= 0.5 && le < turnFarEye) {
            f.turned = true
        }
        return f
    }

    public static func wrists(_ b: BodyPose) -> [CGPoint] {
        [BodyPose.leftWrist, BodyPose.rightWrist].filter { ok(b, $0) }.map { CGPoint(x: b[$0].x, y: b[$0].y) }
    }

    /// A box around the keypoints that are seen, with a margin; `only` limits it to some keypoints.
    public static func box(_ b: BodyPose, pad: Double = 0.25, only: Set<Int>? = nil) -> CGRect? {
        let pts = b.points.enumerated().filter { $0.element.c >= keypointConf && (only?.contains($0.offset) ?? true) }.map(\.element)
        guard pts.count >= 2 else { return nil }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let w = max(xs.max()! - xs.min()!, 20), h = max(ys.max()! - ys.min()!, 20)
        let x1 = (xs.min()! - w * pad).rounded(.towardZero), y1 = (ys.min()! - h * pad * 1.6).rounded(.towardZero)
        let x2 = (xs.max()! + w * pad).rounded(.towardZero), y2 = (ys.max()! + h * pad).rounded(.towardZero)
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    public struct PersonInfo {
        public var id: Int
        public var box: CGRect?
        public var shoulderY: Double?
        public var shoulderWidth: Double?
        public var wrists: [CGPoint]

        public init(id: Int, box: CGRect?, shoulderY: Double?, shoulderWidth: Double?, wrists: [CGPoint]) {
            self.id = id; self.box = box; self.shoulderY = shoulderY; self.shoulderWidth = shoulderWidth; self.wrists = wrists
        }
    }

    /// Each phone goes to the person whose box holds its centre, below that person's shoulders, near a
    /// visible wrist (a phone on the desk does not count) and closest to the box centre.
    public static func assignPhones(_ phones: [CGRect], to people: [PersonInfo]) -> [Int: [CGRect]] {
        var out: [Int: [CGRect]] = [:]
        for phone in phones {
            let cx = phone.midX, cy = phone.midY
            var best: (id: Int, d: Double)?
            for p in people {
                guard let box = p.box, box.minX <= cx, cx <= box.maxX, box.minY <= cy, cy <= box.maxY else { continue }
                if let sy = p.shoulderY, Double(cy) < sy { continue }
                if !p.wrists.isEmpty {
                    let scale = p.shoulderWidth ?? Double(box.width) * 0.5
                    let nearest = p.wrists.map { hypot(Double($0.x - cx), Double($0.y - cy)) }.min()!
                    if nearest > phoneNearWrist * scale { continue }
                }
                let d = pow(Double(box.midX - cx), 2) + pow(Double(box.midY - cy), 2)
                if best == nil || d < best!.d { best = (p.id, d) }
            }
            if let best { out[best.id, default: []].append(phone) }
        }
        return out
    }

    /// 3 x 3 seat map: row 0 = back of the room (top of the picture) ... 2 = front; column 0 = left.
    public static func gridCell(_ box: CGRect, width: Double, height: Double) -> (row: Int, column: Int) {
        (min(2, max(0, Int(Double(box.midY) * 3 / height))), min(2, max(0, Int(Double(box.midX) * 3 / width))))
    }

    /// One per tracked person: a state only counts after it has lasted its hold time.
    public final class Person {
        public private(set) var state: State = .ok
        public internal(set) var raised = false
        public internal(set) var box: CGRect?
        private var since: [String: TimeInterval] = [:]

        public init() {}

        private func hold(_ key: String, _ active: Bool, _ duration: TimeInterval, _ now: TimeInterval) -> Bool {
            guard active else { since[key] = nil; return false }
            if since[key] == nil { since[key] = now }
            return now - since[key]! >= duration
        }

        /// The picture was frozen for `seconds`: pause all the timers.
        public func shift(_ seconds: TimeInterval) {
            for key in since.keys { since[key]! += seconds }
        }

        @discardableResult
        public func update(_ b: BodyPose, phones: [CGRect], enabled: Set<State>, now: TimeInterval, box: CGRect? = nil) -> State {
            self.box = box ?? Attention.box(b)
            let f = instantFlags(b)
            raised = hold("raise", f.raised, raiseHold, now)
            let held: [State: Bool] = [
                .phone: hold("phone", !phones.isEmpty, phoneHold, now),
                .sleeping: hold("sleeping", f.sleeping, sleepHold, now),
                .headDown: hold("head_down", f.headDown && !f.sleeping, downHold, now),
                .turned: hold("turned", f.turned, turnHold, now),
            ]
            state = priority.first { enabled.contains($0) && held[$0] == true } ?? .ok
            return state
        }

        /// For tests and summaries.
        public func set(state: State, raised: Bool, box: CGRect?) {
            self.state = state; self.raised = raised; self.box = box
        }
    }

    public struct Summary: Sendable {
        public var raised = 0
        public var inattentive = 0
        public var byState: [State: Int] = [:]
        public var grid = Array(repeating: Array(repeating: 0, count: 3), count: 3)

        public init() {}
    }

    public static func summarize(_ people: [Person], width: Double, height: Double) -> Summary {
        var out = Summary()
        for p in people {
            if p.raised {
                out.raised += 1
                if let box = p.box { let cell = gridCell(box, width: width, height: height); out.grid[cell.row][cell.column] += 1 }
            }
            if p.state != .ok { out.inattentive += 1; out.byState[p.state, default: 0] += 1 }
        }
        return out
    }
}
