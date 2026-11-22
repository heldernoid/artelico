import CoreGraphics
import XCTest
@testable import StudioCore

final class SteadyVideoTests: XCTestCase {
    /// A model at 13 frames per second on a 30 fps video: the step settles on 2 or 3 and stays there for
    /// seconds, and the video keeps up with the clock.
    func testPacerStepsEvenlyAndKeepsUp() {
        var pacer = FramePacer(frameRate: 30)
        var steps: [Int] = []
        var now = 0.0
        for _ in 0..<(13 * 20) {
            steps.append(pacer.advance(now: now))
            now += 1.0 / 13
        }
        let changes = zip(steps.dropFirst(), steps.dropFirst(2)).filter { $0 != $1 }.count
        XCTAssertLessThanOrEqual(changes, 10, "the step changes rarely (here at most every 2 s)")
        XCTAssertTrue(Set(steps.dropFirst()).isSubset(of: [1, 2, 3, 4]))
        XCTAssertEqual(pacer.shown, now, accuracy: 0.5, "the video stays within the tolerance of real time")
    }

    /// A model faster than the video: every frame is shown, at the video's own speed, none early.
    func testPacerWaitsWhenTheModelIsFast() {
        var pacer = FramePacer(frameRate: 25)
        var shownFrames = 0
        var now = 0.0
        while now < 4 {
            shownFrames += pacer.advance(now: now)
            now += 1.0 / 100
        }
        XCTAssertEqual(Double(shownFrames), 4 * 25, accuracy: 2)
    }

    /// A box that jitters a few pixels around a still place is steadied; a real jump is followed at once.
    func testSmootherSteadiesJitterButFollowsMovement() {
        var smoother = TrackSmoother()
        var raw: [CGFloat] = [], steady: [CGFloat] = []
        for k in 0..<60 {
            let jitter = CGFloat(k % 2 == 0 ? 0.004 : -0.004)
            let box = CGRect(x: 0.4 + jitter, y: 0.4, width: 0.2, height: 0.3)
            raw.append(box.minX)
            steady.append(smoother.box(box, id: 1, time: Double(k) / 15).minX)
        }
        func spread(_ v: ArraySlice<CGFloat>) -> CGFloat { (v.max() ?? 0) - (v.min() ?? 0) }
        XCTAssertLessThan(spread(steady[30...]), spread(raw[30...]) * 0.5)

        var moved = CGRect.zero
        for k in 60..<64 { moved = smoother.box(CGRect(x: 0.7, y: 0.4, width: 0.2, height: 0.3), id: 1, time: Double(k) / 15) }
        XCTAssertEqual(moved.minX, 0.7, accuracy: 0.03, "a fast move is followed within a few frames")
    }

    /// The tracker steadies numbered poses; turned off, it gives the raw positions.
    func testTrackerSteadiesPosesUnlessTurnedOff() {
        func pose(_ x: CGFloat) -> Pose {
            Pose(confidence: 0.9, boundingBox: CGRect(x: x, y: 0.2, width: 0.2, height: 0.6),
                 keypoints: (0..<17).map { _ in Pose.Keypoint(position: CGPoint(x: x + 0.1, y: 0.5), confidence: 0.9) })
        }
        var steady = ObjectTracker(), plain = ObjectTracker()
        plain.steadies = false
        var lastSteady: Pose?, lastPlain: Pose?
        for k in 0..<30 {
            let x: CGFloat = 0.4 + (k % 2 == 0 ? 0.005 : -0.005)
            if case .poses(let p) = steady.track(.poses([pose(x)]), time: Double(k) / 15) { lastSteady = p.first }
            if case .poses(let p) = plain.track(.poses([pose(x)]), time: Double(k) / 15) { lastPlain = p.first }
        }
        XCTAssertEqual(lastPlain?.keypoints[0].position.x ?? 0, 0.495, accuracy: 1e-9)
        XCTAssertEqual(lastSteady?.keypoints[0].position.x ?? 0, 0.5, accuracy: 0.003)
        XCTAssertNotNil(lastSteady?.trackID)
    }
}
