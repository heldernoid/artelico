import CoreGraphics
import Foundation

// Rules of the "Rep counter" example: counts repetitions of an exercise for every tracked person at once.
// Same method as hailo-apps' `--aigym` mode (standalone_apps/yolo26/pose_estimation/aigym.py, after
// Ultralytics AIGym): one joint angle per exercise, two thresholds with a dead band between them
// (hysteresis), and a rep counted when the person comes back to the rest position after the work position.
// Added here: a phase change must last `confirmFrames` frames (a single jittery frame changes nothing),
// form hints for half reps, and people forgotten after a while out of sight.

/// The exercises the counter knows, each with the angle it watches and its two thresholds.
public enum Exercise: String, CaseIterable, Identifiable, Sendable {
    case squats, pushUps, pullUps, sitUps, jumpingJacks, lunges

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .squats: return "Squats"
        case .pushUps: return "Push-ups"
        case .pullUps: return "Pull-ups"
        case .sitUps: return "Sit-ups or crunches"
        case .jumpingJacks: return "Jumping jacks"
        case .lunges: return "Lunges"
        }
    }

    /// What the angle is, for the screen.
    public var measures: String {
        switch self {
        case .squats: return "knee angle (hip, knee, ankle)"
        case .pushUps, .pullUps: return "elbow angle (shoulder, elbow, wrist)"
        case .sitUps: return "hip angle (shoulder, hip, knee)"
        case .jumpingJacks: return "arm angle at the shoulder (hip, shoulder, wrist)"
        case .lunges: return "the more bent knee"
        }
    }

    /// The angle in the rest position (standing, arms straight, lying back, arms down).
    public var rest: Double {
        switch self {
        case .squats: return 155
        case .pushUps: return 150
        case .pullUps: return 145
        case .sitUps: return 120
        case .jumpingJacks: return 50
        case .lunges: return 155
        }
    }

    /// The angle the rep has to reach. Jumping jacks open up (the angle grows); the others close.
    public var work: Double {
        switch self {
        case .squats: return 115
        case .pushUps: return 100
        case .pullUps: return 85
        case .sitUps: return 95
        case .jumpingJacks: return 125
        case .lunges: return 115
        }
    }

    /// Said when a rep turned back before reaching `work`.
    public var shortHint: String {
        switch self {
        case .squats, .lunges, .pushUps: return "Go lower"
        case .pullUps: return "Pull higher"
        case .sitUps: return "Come up higher"
        case .jumpingJacks: return "Arms higher"
        }
    }

    /// Said when the angle can't be measured (joints not seen).
    public var visibilityHint: String {
        switch self {
        case .squats, .lunges: return "Show your hips, knees and ankles"
        case .pushUps, .pullUps: return "Show your shoulders, elbows and wrists"
        case .sitUps: return "Show your shoulders, hips and knees"
        case .jumpingJacks: return "Show your hips, shoulders and hands"
        }
    }

    private var triplets: [(Int, Int, Int)] {
        switch self {
        case .squats, .lunges:
            return [(BodyPose.leftHip, BodyPose.leftKnee, BodyPose.leftAnkle), (BodyPose.rightHip, BodyPose.rightKnee, BodyPose.rightAnkle)]
        case .pushUps, .pullUps:
            return [(BodyPose.leftShoulder, BodyPose.leftElbow, BodyPose.leftWrist), (BodyPose.rightShoulder, BodyPose.rightElbow, BodyPose.rightWrist)]
        case .sitUps:
            return [(BodyPose.leftShoulder, BodyPose.leftHip, BodyPose.leftKnee), (BodyPose.rightShoulder, BodyPose.rightHip, BodyPose.rightKnee)]
        case .jumpingJacks:
            return [(BodyPose.leftHip, BodyPose.leftShoulder, BodyPose.leftWrist), (BodyPose.rightHip, BodyPose.rightShoulder, BodyPose.rightWrist)]
        }
    }

    /// This frame's angle: the mean of the sides that are seen (as aigym), except lunges, which follow the
    /// front (more bent) knee, since the back leg is often hidden or straighter.
    public func angle(_ body: BodyPose, conf: Double = 0.4) -> Double? {
        let sides = triplets.compactMap { jointAngle(body.point($0.0, conf), body.point($0.1, conf), body.point($0.2, conf)) }
        guard !sides.isEmpty else { return nil }
        return self == .lunges ? sides.min() : sides.reduce(0, +) / Double(sides.count)
    }

    /// How far into the rep an angle is: 0 at rest, 1 at the work threshold (can go past both).
    public func depth(_ angle: Double) -> Double { (angle - rest) / (work - rest) }
}

/// Counts one person's reps.
public struct RepTracker: Sendable {
    public enum Phase: String, Sendable { case rest, work }

    public private(set) var count = 0
    /// Nil until the person has held one of the two positions (someone who appears mid-rep, in the work
    /// position, counts that rep when they come back up, as aigym does).
    public private(set) var phase: Phase?
    public private(set) var angle: Double?
    public private(set) var hint = ""
    public private(set) var lastCount: TimeInterval = -.infinity
    public private(set) var lastSeen: TimeInterval
    private var pending: Phase?
    private var pendingFrames = 0
    /// The deepest point (as `Exercise.depth`) since the person last left the rest position.
    private var deepest = 0.0
    private var hintUntil: TimeInterval = -.infinity

    public init(now: TimeInterval) { lastSeen = now }

    /// One frame. Returns true when a rep was just counted.
    public mutating func update(_ body: BodyPose, exercise: Exercise, confirmFrames: Int, now: TimeInterval) -> Bool {
        lastSeen = now
        if now > hintUntil { hint = "" }
        guard let angle = exercise.angle(body) else {
            self.angle = nil
            pending = nil; pendingFrames = 0
            hint = exercise.visibilityHint
            hintUntil = now
            return false
        }
        self.angle = angle
        let depth = exercise.depth(angle)
        if phase != .work { deepest = max(deepest, depth) }
        let candidate: Phase? = depth >= 1 ? .work : (depth <= 0 ? .rest : nil)
        guard let candidate, candidate != phase else { pending = nil; pendingFrames = 0; return false }
        if candidate == pending { pendingFrames += 1 } else { pending = candidate; pendingFrames = 1 }
        guard pendingFrames >= confirmFrames else { return false }
        let from = phase
        phase = candidate
        pending = nil; pendingFrames = 0
        deepest = 0
        guard from == .work, candidate == .rest else {
            if candidate == .work { hint = "" }
            return false
        }
        count += 1
        lastCount = now
        hint = ""
        return true
    }

    /// Back at rest without having reached the work position: a half rep, which earns a hint ("Go lower")
    /// when it went at least about half way.
    mutating func checkHalfRep(_ exercise: Exercise, now: TimeInterval) {
        guard phase == .rest, let angle, exercise.depth(angle) <= 0 else { return }
        if deepest >= 0.45 && deepest < 1 {
            hint = exercise.shortHint
            hintUntil = now + 2.5
        }
        deepest = 0
    }
}

/// Everyone's counts. People are told apart by their tracking number; poses without one are skipped
/// (the tracker gives numbers once a person has been seen twice), so one person's reps never go to another.
public final class RepCounter {
    public var exercise: Exercise { didSet { if exercise != oldValue { reset() } } }
    public let confirmFrames: Int
    /// A person out of sight longer than this is forgotten (aigym: 60 frames).
    public let forgetAfter: TimeInterval
    public private(set) var people: [Int: RepTracker] = [:]
    /// Reps of people already forgotten, so the total does not drop when someone leaves.
    public private(set) var departedReps = 0

    public init(exercise: Exercise = .squats, confirmFrames: Int = 2, forgetAfter: TimeInterval = 4) {
        self.exercise = exercise
        self.confirmFrames = confirmFrames
        self.forgetAfter = forgetAfter
    }

    public var total: Int { departedReps + people.values.reduce(0) { $0 + $1.count } }

    public func reset() {
        people = [:]
        departedReps = 0
    }

    /// One frame. Returns the tracking numbers of the people who just finished a rep.
    @discardableResult
    public func update(_ bodies: [BodyPose], now: TimeInterval) -> [Int] {
        var counted: [Int] = []
        for body in bodies {
            guard let id = body.id else { continue }
            var tracker = people[id] ?? RepTracker(now: now)
            if tracker.update(body, exercise: exercise, confirmFrames: confirmFrames, now: now) { counted.append(id) }
            tracker.checkHalfRep(exercise, now: now)
            people[id] = tracker
        }
        for (id, tracker) in people where now - tracker.lastSeen > forgetAfter {
            departedReps += tracker.count
            people[id] = nil
        }
        return counted.sorted()
    }
}
