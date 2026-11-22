import CoreGraphics
import XCTest
@testable import StudioCore

/// Rep counter rules, on synthetic keypoint sequences: one rep is the work position then the rest position.
final class RepCounterTests: XCTestCase {
    /// A person whose watched joint (both sides) bends to `angle` degrees for `exercise`.
    private func body(_ angle: Double, _ exercise: Exercise = .squats, id: Int? = 1, seen: Bool = true) -> BodyPose {
        var k = Array(repeating: BodyPoint(0, 0, seen ? 0.9 : 0.1), count: 17)
        let triplets: [(Int, Int, Int)]
        switch exercise {
        case .squats, .lunges: triplets = [(11, 13, 15), (12, 14, 16)]
        case .pushUps, .pullUps: triplets = [(5, 7, 9), (6, 8, 10)]
        case .sitUps: triplets = [(5, 11, 13), (6, 12, 14)]
        case .jumpingJacks: triplets = [(11, 5, 9), (12, 6, 10)]
        }
        let turn = (180 - angle) * .pi / 180
        for (side, t) in triplets.enumerated() {
            let bx = 200.0 + Double(side) * 150, by = 300.0
            k[t.1] = BodyPoint(bx, by, k[t.1].c)
            k[t.0] = BodyPoint(bx, by - 100, k[t.0].c)
            k[t.2] = BodyPoint(bx + 100 * sin(turn), by + 100 * cos(turn), k[t.2].c)
        }
        return BodyPose(points: k, id: id)
    }

    /// Feeds angles one frame each (30 FPS) and returns the counter.
    @discardableResult
    private func feed(_ counter: RepCounter, _ angles: [Double], id: Int = 1, from start: Double = 0) -> [[Int]] {
        angles.enumerated().map { counter.update([body($0.element, counter.exercise, id: id)], now: start + Double($0.offset) / 30) }
    }

    private func rep(_ low: Double = 90, _ high: Double = 170, frames: Int = 4) -> [Double] {
        Array(repeating: high, count: frames) + Array(repeating: low, count: frames) + Array(repeating: high, count: frames)
    }

    func testAnglesAreMeasured() {
        XCTAssertEqual(Exercise.squats.angle(body(100))!, 100, accuracy: 0.01)
        XCTAssertEqual(Exercise.jumpingJacks.angle(body(140, .jumpingJacks))!, 140, accuracy: 0.01)
        XCTAssertNil(Exercise.squats.angle(body(100, seen: false)))
    }

    func testOneRepIsDownThenUp() {
        let counter = RepCounter(exercise: .squats)
        let counted = feed(counter, rep())
        XCTAssertEqual(counter.people[1]?.count, 1)
        XCTAssertEqual(counted.filter { !$0.isEmpty }, [[1]])   // reported once, on the way up
        // Down only: not counted yet.
        feed(counter, Array(repeating: 90, count: 5), from: 1)
        XCTAssertEqual(counter.people[1]?.count, 1)
        feed(counter, Array(repeating: 170, count: 5), from: 2)
        XCTAssertEqual(counter.total, 2)
    }

    func testDeadBandAndJitterDoNotCount() {
        let counter = RepCounter(exercise: .squats)
        // Hovering between the thresholds (115-155) never counts.
        feed(counter, [170, 170, 150, 130, 120, 140, 125, 150, 170, 170])
        XCTAssertEqual(counter.total, 0)
        // A single deep frame (a keypoint glitch) is not a rep: it needs two frames in a row.
        feed(counter, [170, 170, 90, 170, 170, 90, 170, 170], from: 1)
        XCTAssertEqual(counter.total, 0)
        // Jitter around the bottom and around the top of one real rep: still one.
        feed(counter, [170, 100, 100, 112, 96, 118, 100, 160, 158, 170, 150, 170, 170], from: 2)
        XCTAssertEqual(counter.total, 1)
    }

    func testPeopleKeepTheirOwnCounts() {
        let counter = RepCounter(exercise: .squats)
        // Person 1 does two reps while person 2 does one, in the same frames.
        let a = rep() + rep(), b = rep() + Array(repeating: 170, count: 12)
        for i in 0..<a.count {
            counter.update([body(a[i], id: 1), body(b[i], id: 2), body(a[i], id: nil)], now: Double(i) / 30)
        }
        XCTAssertEqual(counter.people[1]?.count, 2)
        XCTAssertEqual(counter.people[2]?.count, 1)
        XCTAssertEqual(counter.people.count, 2)   // the untracked pose is skipped
        XCTAssertEqual(counter.total, 3)
        // Person 2 leaves: forgotten after a while, but the total keeps their rep.
        for i in 0..<10 { counter.update([body(170, id: 1)], now: 2 + Double(i)) }
        XCTAssertNil(counter.people[2])
        XCTAssertEqual(counter.total, 3)
        counter.reset()
        XCTAssertEqual(counter.total, 0)
    }

    func testEveryExerciseCountsItsOwnDirection() {
        for exercise in Exercise.allCases {
            let counter = RepCounter(exercise: exercise)
            let rest = exercise.work < exercise.rest ? exercise.rest + 15 : exercise.rest - 15
            let work = exercise.work < exercise.rest ? exercise.work - 15 : exercise.work + 15
            feed(counter, rep(work, rest) + rep(work, rest))
            XCTAssertEqual(counter.total, 2, exercise.title)
        }
    }

    func testHalfRepGivesAHint() {
        let counter = RepCounter(exercise: .squats)
        feed(counter, [170, 170, 140, 130, 128, 130, 150, 170, 170])   // two thirds of the way down
        XCTAssertEqual(counter.total, 0)
        XCTAssertEqual(counter.people[1]?.hint, "Go lower")
        // A full rep clears it.
        feed(counter, rep(), from: 1)
        XCTAssertEqual(counter.people[1]?.hint, "")
        XCTAssertEqual(counter.total, 1)
        // Hidden legs: a hint to show them, and the count stays.
        counter.update([body(90, seen: false)], now: 3)
        XCTAssertEqual(counter.people[1]?.hint, Exercise.squats.visibilityHint)
        XCTAssertEqual(counter.total, 1)
    }

    func testChangingTheExerciseStartsAgain() {
        let counter = RepCounter(exercise: .squats)
        feed(counter, rep())
        counter.exercise = .pushUps
        XCTAssertEqual(counter.total, 0)
    }
}
