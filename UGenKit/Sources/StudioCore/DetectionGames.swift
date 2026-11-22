import CoreGraphics
import Foundation

// Rules for the detection examples (head count, traffic count, missing check, plate gate), ported from
// the UGen300 demos (vendor/ref-ugen300-demos: HeadCount, Traffic, MissingCheck). Boxes are in any
// consistent unit (the app uses fractions of the picture); times are passed in.

// MARK: - Traffic: tracking and line counting

public func boxIoU(_ a: CGRect, _ b: CGRect) -> Double {
    let inter = a.intersection(b)
    guard !inter.isNull else { return 0 }
    let i = Double(inter.width * inter.height)
    let u = Double(a.width * a.height + b.width * b.height) - i
    return u > 0 ? i / u : 0
}

/// Follows boxes from frame to frame: pairs by overlap (or, without overlap, centres within
/// `maxDistance`), best pairs first; a track missed for more than `maxMissed` frames is dropped.
public final class CentroidTracker {
    public final class Track {
        public let id: Int
        public internal(set) var box: CGRect
        public internal(set) var label: String
        public internal(set) var missed = 0
        /// Recent centres, oldest first (at most 30).
        public internal(set) var history: [CGPoint]

        init(id: Int, box: CGRect, label: String) {
            self.id = id; self.box = box; self.label = label
            history = [CGPoint(x: box.midX, y: box.midY)]
        }
    }

    public let maxMissed: Int
    public let iouThreshold: Double
    public let maxDistance: Double
    public private(set) var tracks: [Int: Track] = [:]
    private var nextID = 1

    public init(maxMissed: Int = 10, iouThreshold: Double = 0.2, maxDistance: Double = 80) {
        self.maxMissed = maxMissed; self.iouThreshold = iouThreshold; self.maxDistance = maxDistance
    }

    /// `detections`: (label, box). Returns the live tracks, oldest first.
    @discardableResult
    public func update(_ detections: [(label: String, box: CGRect)]) -> [Track] {
        var pairs: [(score: Double, id: Int, index: Int)] = []
        for (id, track) in tracks {
            for (j, d) in detections.enumerated() {
                var s = boxIoU(track.box, d.box)
                if s < iouThreshold {
                    let dx = Double(d.box.midX - track.box.midX), dy = Double(d.box.midY - track.box.midY)
                    if hypot(dx, dy) > maxDistance { continue }
                    s = 0.01
                }
                pairs.append((s, id, j))
            }
        }
        pairs.sort { ($0.score, $0.id, $0.index) > ($1.score, $1.id, $1.index) }
        var matched = Set<Int>(), used = Set<Int>()
        for p in pairs where !matched.contains(p.id) && !used.contains(p.index) {
            let t = tracks[p.id]!
            t.box = detections[p.index].box; t.label = detections[p.index].label; t.missed = 0
            t.history = Array((t.history + [CGPoint(x: t.box.midX, y: t.box.midY)]).suffix(30))
            matched.insert(p.id); used.insert(p.index)
        }
        var created = Set<Int>()
        for (j, d) in detections.enumerated() where !used.contains(j) {
            tracks[nextID] = Track(id: nextID, box: d.box, label: d.label)
            created.insert(nextID); nextID += 1
        }
        for (id, t) in tracks where !matched.contains(id) && !created.contains(id) {
            t.missed += 1
            if t.missed > maxMissed { tracks[id] = nil }
        }
        return tracks.keys.sorted().map { tracks[$0]! }
    }
}

/// Counts each track once when its centre crosses the horizontal line `lineY`, by direction.
public final class LineCounter {
    public enum Direction: String, Sendable { case up, down }

    public var lineY: Double
    public private(set) var counted: [Int: Direction] = [:]
    /// counts[label][direction]
    public private(set) var counts: [String: [Direction: Int]] = [:]

    public init(lineY: Double) { self.lineY = lineY }

    /// New crossings this frame: (track, label, direction).
    @discardableResult
    public func update(_ tracks: [CentroidTracker.Track]) -> [(id: Int, label: String, direction: Direction)] {
        var new: [(Int, String, Direction)] = []
        for t in tracks where counted[t.id] == nil && t.history.count >= 2 {
            let y0 = Double(t.history[t.history.count - 2].y), y1 = Double(t.history[t.history.count - 1].y)
            if (y0 < lineY && lineY <= y1) || (y1 < lineY && lineY <= y0) {
                let d: Direction = y1 > y0 ? .down : .up
                counted[t.id] = d
                counts[t.label, default: [:]][d, default: 0] += 1
                new.append((t.id, t.label, d))
            }
        }
        return new
    }

    public func count(_ label: String, _ direction: Direction) -> Int { counts[label]?[direction] ?? 0 }
    public var total: Int { counts.values.reduce(0) { $0 + $1.values.reduce(0, +) } }
}

// MARK: - Missing check

/// Remembers which kinds of object are on the table, then reports what is missing (not seen in any of
/// the last `window` frames) and what is extra (a kind that was not there).
public final class MissingCheck {
    public struct Status: Sendable {
        public var armed: Bool
        public var missing: [String]
        public var extra: [String]
        public var present: [String]
        public var allOK: Bool { armed && missing.isEmpty && extra.isEmpty }

        public init(armed: Bool, missing: [String], extra: [String], present: [String]) {
            self.armed = armed; self.missing = missing; self.extra = extra; self.present = present
        }
    }

    public let window: Int
    public var ignored: Set<String>
    public private(set) var baseline: [String] = []
    private var history: [String: [Bool]] = [:]

    public init(window: Int = 8, ignored: Set<String> = ["person"]) {
        self.window = window; self.ignored = ignored
    }

    static func norm(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }

    /// Takes the kinds seen now as the list of what should be there.
    public func setBaseline(_ labels: [String]) {
        var seen = Set<String>()
        baseline = labels.filter { !ignored.contains($0) && seen.insert(Self.norm($0)).inserted }.sorted()
        history = Dictionary(uniqueKeysWithValues: baseline.map { ($0, []) })
    }

    public func clear() { baseline = []; history = [:] }

    public func update(_ labels: [String]) -> Status {
        let now = Set(labels.filter { !ignored.contains($0) }.map(Self.norm))
        guard !baseline.isEmpty else { return Status(armed: false, missing: [], extra: [], present: now.sorted()) }
        var missing: [String] = [], present: [String] = []
        for item in baseline {
            history[item] = Array((history[item, default: []] + [now.contains(Self.norm(item))]).suffix(window))
            if history[item]!.contains(true) { present.append(item) } else { missing.append(item) }
        }
        let known = Set(baseline.map(Self.norm))
        let extra = Set(labels.filter { !ignored.contains($0) && !known.contains(Self.norm($0)) }).sorted()
        return Status(armed: true, missing: missing, extra: extra, present: present)
    }
}

// MARK: - Plate gate

public enum PlateText {
    /// Taiwan (the demo's own: ABC-1234, 1234-AB, ...) and Portugal (AA-00-AA, 00-AA-00, 00-00-AA, AA-00-00).
    static let taiwan = try! NSRegularExpression(pattern: "^(?:[A-Z]{2,3}-?\\d{3,4}|\\d{3,4}-?[A-Z]{2,3}|[A-Z]{3}-?\\d{4}|\\d{4}-?[A-Z]{2})$")
    static let portugal = try! NSRegularExpression(pattern: "^(?:[A-Z]{2}\\d{2}[A-Z]{2}|\\d{2}[A-Z]{2}\\d{2}|\\d{4}[A-Z]{2}|[A-Z]{2}\\d{4})$")

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// The text as a plate in a standard form, or nil when it does not look like one. Letter O becomes
    /// zero, as in the demo (the OCR mixes them up); in a Portuguese pattern a zero in a letter pair goes back to O.
    public static func normalize(_ text: String) -> String? {
        let spaced = text.uppercased().map { $0.isWhitespace || $0 == "·" || $0 == "." ? "-" : $0 }
        let cleaned = String(spaced).filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        var t = cleaned.replacingOccurrences(of: "O", with: "0")
        while t.contains("--") { t = t.replacingOccurrences(of: "--", with: "-") }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !t.isEmpty else { return nil }
        let plain = t.replacingOccurrences(of: "-", with: "")
        // Two separators (AA-00-AA) is the Portuguese layout; try it first.
        if t.filter({ $0 == "-" }).count == 2, let pt = portuguese(plain) { return pt }
        if matches(taiwan, t) || matches(taiwan, plain) {
            let chars = Array(plain)
            let letters = chars.prefix { $0.isLetter }.count, digits = chars.prefix { $0.isNumber }.count
            if letters >= 2, letters <= 3, chars.dropFirst(letters).allSatisfy(\.isNumber), (3...4).contains(chars.count - letters) {
                return String(chars[..<letters]) + "-" + String(chars[letters...])
            }
            if digits >= 3, digits <= 4, chars.dropFirst(digits).allSatisfy(\.isLetter), (2...3).contains(chars.count - digits) {
                return String(chars[..<digits]) + "-" + String(chars[digits...])
            }
            return plain
        }
        return portuguese(plain)
    }

    /// Portugal: three pairs, letters and digits. Restores O inside a pair that must be letters.
    static func portuguese(_ plain: String) -> String? {
        if plain.count == 6 {
            let pairs = stride(from: 0, to: 6, by: 2).map { i -> String in
                let s = plain.index(plain.startIndex, offsetBy: i)
                return String(plain[s..<plain.index(s, offsetBy: 2)])
            }
            let kinds = pairs.map { p -> Character in
                if p.allSatisfy(\.isNumber) { return "9" }
                if p.allSatisfy({ $0.isLetter || $0 == "0" }) { return "A" }
                return "?"
            }
            let letterPairs = Set([[Character("A"), "9", "A"], ["9", "A", "9"], ["9", "9", "A"], ["A", "9", "9"]].map { String($0) })
            // A pair of zeros could be letters (OO) or digits; prefer the pattern that is valid.
            var shape = String(kinds)
            if !letterPairs.contains(shape) {
                for (i, p) in pairs.enumerated() where p == "00" {
                    var k = Array(shape); k[i] = k[i] == "9" ? "A" : "9"
                    if letterPairs.contains(String(k)) { shape = String(k); break }
                }
            }
            guard letterPairs.contains(shape) else { return nil }
            let fixed = zip(pairs, shape).map { p, k in k == "A" ? p.replacingOccurrences(of: "0", with: "O") : p }
            return fixed.joined(separator: "-")
        }
        return nil
    }
}

/// The barrier: opens over one second, stays open five, a refusal shows for three.
public struct GateBarrier: Sendable {
    public enum State: String, Sendable { case closed, opening, open, denied }

    public private(set) var state: State = .closed
    private var since: TimeInterval = 0

    public init() {}

    public mutating func open(now: TimeInterval) { state = .opening; since = now }
    public mutating func deny(now: TimeInterval) { state = .denied; since = now }

    /// Angle and state at `now` without changing anything (for drawing): opening for 1 s, open for 5 s
    /// after that, a refusal shown for 3 s.
    public func display(now: TimeInterval) -> (angle: Double, state: State) {
        let t = now - since
        switch state {
        case .opening, .open:
            if state == .opening && t < 1 { return (t * 90, .opening) }
            let openFor = state == .opening ? t - 1 : t
            return openFor <= 5 ? (90, .open) : (0, .closed)
        case .denied:
            return t <= 3 ? (0, .denied) : (0, .closed)
        case .closed:
            return (0, .closed)
        }
    }

    /// The arm's angle in degrees (0 = down, 90 = up), advancing the state with time.
    public mutating func angle(now: TimeInterval) -> Double {
        switch state {
        case .opening:
            let a = min(90, (now - since) * 90)
            if a >= 90 { state = .open; since = now }
            return a
        case .open:
            if now - since > 5 { state = .closed; return 0 }
            return 90
        case .denied:
            if now - since > 3 { state = .closed }
            return 0
        case .closed:
            return 0
        }
    }
}

// MARK: - Face check-in

extension FaceGallery {
    /// Like `match`, but refuses when the runner-up person is within `margin` of the best and also over
    /// the threshold (two people too alike to tell apart), as in the FaceCheckIn demo. One score per person:
    /// their best-matching sample.
    public func confidentMatch(_ embedding: [Float], margin: Float = 0.08) -> (name: String, similarity: Float)? {
        var scores: [(String, Float)] = []
        for (name, embeddings) in people {
            let best = embeddings.filter { $0.count == embedding.count }.map { known in
                zip(known, embedding).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            }.max()
            if let best { scores.append((name, best)) }
        }
        scores.sort { $0.1 > $1.1 }
        guard let first = scores.first, first.1.isFinite, first.1 >= threshold else { return nil }
        if scores.count > 1, first.1 - scores[1].1 < margin, scores[1].1 >= threshold { return nil }
        return first
    }

    /// The average of several samples, scaled to length 1 (what enrolment stores).
    public static func average(_ samples: [[Float]]) -> [Float]? {
        guard let n = samples.first?.count, n > 0, samples.allSatisfy({ $0.count == n }) else { return nil }
        var sum = [Float](repeating: 0, count: n)
        for s in samples { for i in 0..<n { sum[i] += s[i] } }
        let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
        guard norm > 0, norm.isFinite else { return nil }
        return sum.map { $0 / norm }
    }
}

/// Who has checked in: a name counts after being seen for `confirm` seconds in a row; after a reset
/// nobody checks in for `grace` seconds (so the people still in front of the camera are not re-added at once).
public final class CheckInBook {
    public let confirm: TimeInterval
    public let grace: TimeInterval
    public private(set) var checked: [(name: String, time: Date)] = []
    private var firstSeen: [String: TimeInterval] = [:]
    private var quietUntil: TimeInterval = -.infinity

    public init(confirm: TimeInterval = 0.6, grace: TimeInterval = 3) {
        self.confirm = confirm; self.grace = grace
    }

    public func isChecked(_ name: String) -> Bool { checked.contains { $0.name == name } }

    /// Names recognised in this frame; returns the ones that just checked in.
    @discardableResult
    public func update(_ names: Set<String>, now: TimeInterval, clock: Date = Date()) -> [String] {
        var new: [String] = []
        for name in names {
            if firstSeen[name] == nil { firstSeen[name] = now }
            if now - firstSeen[name]! >= confirm, !isChecked(name), now >= quietUntil {
                checked.append((name, clock)); new.append(name)
            }
        }
        for name in firstSeen.keys where !names.contains(name) { firstSeen[name] = nil }
        return new.sorted()
    }

    public func reset(now: TimeInterval) {
        checked = []; firstSeen = [:]; quietUntil = now + grace
    }

    public func remove(_ name: String) {
        checked.removeAll { $0.name == name }; firstSeen[name] = nil
    }
}
