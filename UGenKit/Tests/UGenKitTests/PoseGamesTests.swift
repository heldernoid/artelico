import CoreGraphics
import XCTest
@testable import StudioCore

/// Rules of the pose examples. The gesture and classroom cases are the UGen300 demos' own tests
/// (Y2/test_gesture_logic.py, Classroom/test_attention.py), ported; the others are new.
final class PoseGamesTests: XCTestCase {
    // MARK: Helpers

    /// Y2's test body: everything at belly height (y 300), nose at y 100, a raised wrist at y 30.
    private func gestureBody(rightUp: Bool = false, leftUp: Bool = false) -> BodyPose {
        var p = Array(repeating: BodyPoint(100, 300, 0.9), count: 17)
        p[BodyPose.nose] = BodyPoint(100, 100, 0.9)
        p[BodyPose.leftWrist] = leftUp ? BodyPoint(60, 30, 0.9) : BodyPoint(60, 320, 0.9)
        p[BodyPose.rightWrist] = rightUp ? BodyPoint(140, 30, 0.9) : BodyPoint(140, 320, 0.9)
        return BodyPose(points: p)
    }

    /// Classroom's test person: shoulder width 80. `hide` sets those keypoints' confidence to 0.05.
    private func person(nose: (Double, Double) = (100, 100), eyes: [(Double, Double)] = [(90, 95), (110, 95)],
                        ears: [(Double, Double)] = [(80, 100), (120, 100)], shoulders: [(Double, Double)] = [(60, 160), (140, 160)],
                        elbows: [(Double, Double)] = [(45, 220), (155, 220)], wrists: [(Double, Double)] = [(50, 260), (150, 260)],
                        conf: Double = 0.9, hide: [Int] = [], dy: Double = 0) -> BodyPose {
        var k = Array(repeating: BodyPoint(0, 0, 0), count: 17)
        k[0] = BodyPoint(nose.0, nose.1, conf)
        k[1] = BodyPoint(eyes[0].0, eyes[0].1, conf); k[2] = BodyPoint(eyes[1].0, eyes[1].1, conf)
        k[3] = BodyPoint(ears[0].0, ears[0].1, conf); k[4] = BodyPoint(ears[1].0, ears[1].1, conf)
        k[5] = BodyPoint(shoulders[0].0, shoulders[0].1, conf); k[6] = BodyPoint(shoulders[1].0, shoulders[1].1, conf)
        k[7] = BodyPoint(elbows[0].0, elbows[0].1, conf); k[8] = BodyPoint(elbows[1].0, elbows[1].1, conf)
        k[9] = BodyPoint(wrists[0].0, wrists[0].1, conf); k[10] = BodyPoint(wrists[1].0, wrists[1].1, conf)
        k[11] = BodyPoint(70, 300, conf); k[12] = BodyPoint(130, 300, conf)
        for i in hide { k[i].c = 0.05 }
        return BodyPose(points: k.map { BodyPoint($0.x, $0.y + dy, $0.c) }, width: 1280, height: 720)
    }

    /// A standing person, front view, in a 640 x 480 picture. Knee angles set by moving the knees.
    private func standing(kneeBend: Double = 0, handsUp: Bool = false, armsOut: Bool = false) -> BodyPose {
        var k = Array(repeating: BodyPoint(0, 0, 0.9), count: 17)
        k[BodyPose.nose] = BodyPoint(320, 80, 0.9)
        k[BodyPose.leftEye] = BodyPoint(310, 75, 0.9); k[BodyPose.rightEye] = BodyPoint(330, 75, 0.9)
        k[BodyPose.leftEar] = BodyPoint(300, 80, 0.9); k[BodyPose.rightEar] = BodyPoint(340, 80, 0.9)
        k[BodyPose.leftShoulder] = BodyPoint(280, 130, 0.9); k[BodyPose.rightShoulder] = BodyPoint(360, 130, 0.9)
        if handsUp {
            k[BodyPose.leftElbow] = BodyPoint(270, 80, 0.9); k[BodyPose.rightElbow] = BodyPoint(370, 80, 0.9)
            k[BodyPose.leftWrist] = BodyPoint(280, 30, 0.9); k[BodyPose.rightWrist] = BodyPoint(360, 30, 0.9)
        } else if armsOut {
            k[BodyPose.leftElbow] = BodyPoint(220, 130, 0.9); k[BodyPose.rightElbow] = BodyPoint(420, 130, 0.9)
            k[BodyPose.leftWrist] = BodyPoint(160, 132, 0.9); k[BodyPose.rightWrist] = BodyPoint(480, 128, 0.9)
        } else {
            k[BodyPose.leftElbow] = BodyPoint(270, 190, 0.9); k[BodyPose.rightElbow] = BodyPoint(370, 190, 0.9)
            k[BodyPose.leftWrist] = BodyPoint(270, 250, 0.9); k[BodyPose.rightWrist] = BodyPoint(370, 250, 0.9)
        }
        k[BodyPose.leftHip] = BodyPoint(295, 260, 0.9); k[BodyPose.rightHip] = BodyPoint(345, 260, 0.9)
        // Knee pushed forward (sideways in the picture) by kneeBend pixels bends the leg.
        k[BodyPose.leftKnee] = BodyPoint(295 - kneeBend, 350, 0.9); k[BodyPose.rightKnee] = BodyPoint(345 + kneeBend, 350, 0.9)
        k[BodyPose.leftAnkle] = BodyPoint(295, 440, 0.9); k[BodyPose.rightAnkle] = BodyPoint(345, 440, 0.9)
        return BodyPose(points: k)
    }

    // MARK: Y2 gestures (test_gesture_logic.py)

    func testRawGestures() {
        XCTAssertEqual(HandGestures.raised(gestureBody(rightUp: true)), .right)
        XCTAssertEqual(HandGestures.raised(gestureBody(leftUp: true)), .left)
        XCTAssertEqual(HandGestures.raised(gestureBody(rightUp: true, leftUp: true)), .both)
        XCTAssertEqual(HandGestures.raised(gestureBody()), .none)
    }

    private func feed(_ c: GestureController, _ body: BodyPose, frames: Int, from start: TimeInterval) -> [SlideAction] {
        (0..<frames).compactMap { c.update(HandGestures.raised(body), now: start + Double($0) / 30) }
    }

    func testHoldingAHandUpFlipsOnce() {
        let c = GestureController(confirmFrames: 4, cooldown: 1.2)
        XCTAssertEqual(feed(c, gestureBody(rightUp: true), frames: 6, from: 0), [.next])
        _ = feed(c, gestureBody(), frames: 3, from: 0.2)
        // Hand lowered, then raised again after the cooldown: flips once more.
        XCTAssertEqual(feed(c, gestureBody(rightUp: true), frames: 5, from: 1.6), [.next])
    }

    func testFlickerDoesNotFlip() {
        let c = GestureController(confirmFrames: 4, cooldown: 1.2)
        let fired = feed(c, gestureBody(rightUp: true), frames: 2, from: 0) + feed(c, gestureBody(), frames: 2, from: 0.1)
        XCTAssertTrue(fired.isEmpty)
    }

    func testBothHandsRestartAndLeftGoesBack() {
        let c = GestureController(confirmFrames: 4, cooldown: 1.2)
        XCTAssertEqual(feed(c, gestureBody(rightUp: true, leftUp: true), frames: 5, from: 0), [.restart])
        _ = feed(c, gestureBody(), frames: 2, from: 0.3)
        XCTAssertEqual(feed(c, gestureBody(leftUp: true), frames: 5, from: 2), [.previous])
    }

    // MARK: Y4 hand-raise counter

    func testCountRaisedHands() {
        let up = gestureBody(rightUp: true), down = gestureBody()
        XCTAssertEqual(HandRaiseCounter.count([up, down, up]).raised, 2)
        XCTAssertEqual(HandRaiseCounter.count([up, down, up]).total, 3)
        XCTAssertEqual(HandRaiseCounter.count([]).total, 0)
        // Without a nose, the shoulders are the reference.
        var noNose = up
        noNose.points[BodyPose.nose].c = 0.1
        noNose.points[BodyPose.leftShoulder] = BodyPoint(60, 120, 0.9); noNose.points[BodyPose.rightShoulder] = BodyPoint(140, 120, 0.9)
        XCTAssertTrue(HandRaiseCounter.isRaised(noNose))
    }

    // MARK: Y3 air instrument

    func testAirInstrumentPlaysOnEnteringAZone() {
        let instrument = AirInstrument(zones: 5, cooldown: 0.15)
        var body = gestureBody()
        body.points[BodyPose.leftWrist] = BodyPoint(10, 300, 0.9)    // zone 0
        body.points[BodyPose.rightWrist] = BodyPoint(630, 300, 0.9)  // zone 4
        XCTAssertEqual(Set(instrument.update([body], now: 0)), [0, 4])
        XCTAssertEqual(instrument.update([body], now: 0.05), [])            // staying in a zone is silent
        body.points[BodyPose.rightWrist] = BodyPoint(330, 300, 0.9)              // into zone 2
        XCTAssertEqual(instrument.update([body], now: 0.1), [2])
        body.points[BodyPose.rightWrist] = BodyPoint(630, 300, 0.9)              // back to 4, cooldown long over
        XCTAssertEqual(instrument.update([body], now: 1.0), [4])
        body.points[BodyPose.rightWrist].c = 0.1                                  // wrist lost, then seen again in 4
        XCTAssertEqual(instrument.update([body], now: 1.05), [])
        body.points[BodyPose.rightWrist].c = 0.9
        XCTAssertEqual(instrument.update([body], now: 1.1), [])               // zone 4 still cooling down
        XCTAssertEqual(instrument.zone(ofX: 640, width: 640), 4)
    }

    // MARK: Y5 yoga

    func testYogaPoses() {
        XCTAssertTrue(Yoga.tree.check(standing(handsUp: true)).ok)
        XCTAssertEqual(Yoga.tree.check(standing()).hint, "Raise both hands above your head")
        XCTAssertTrue(Yoga.warrior2.check(standing(armsOut: true)).ok)
        XCTAssertEqual(Yoga.warrior2.check(standing()).hint, "Spread your arms out wide")
        XCTAssertFalse(Yoga.warrior1.check(standing(handsUp: true)).ok)       // straight legs
        XCTAssertTrue(Yoga.warrior1.check(standing(kneeBend: 60, handsUp: true)).ok)
        XCTAssertEqual(Yoga.squat.check(standing()).hint, "Bend your knees and squat down")
    }

    func testYogaHoldTimer() {
        let coach = YogaCoach(Yoga.tree, holdTarget: 2, confirmFrames: 3)
        var state = coach.update(standing(handsUp: true), now: 0)
        XCTAssertFalse(state.inPose)
        state = coach.update(standing(handsUp: true), now: 0.1)
        state = coach.update(standing(handsUp: true), now: 0.2)
        XCTAssertTrue(state.inPose)
        state = coach.update(standing(), now: 1.0)                             // dropped the arms: timer pauses
        XCTAssertFalse(state.inPose)
        XCTAssertEqual(state.held, 0, accuracy: 1e-9)
        for t in stride(from: 1.1, through: 3.5, by: 0.1) { state = coach.update(standing(handsUp: true), now: t) }
        XCTAssertTrue(state.done)
    }

    func testYogaRoundGoesThroughEveryPoseOnce() {
        let round = YogaRound(pool: [Yoga.tree, Yoga.warrior2], holdTarget: 1, celebration: 0.5, shuffled: false)
        XCTAssertEqual(round.currentPose?.id, "tree")
        var t = 0.0
        var state = round.update(standing(handsUp: true), now: t)
        while !state.celebrating { t += 0.1; state = round.update(standing(handsUp: true), now: t) }
        t += 0.6
        state = round.update(standing(armsOut: true), now: t)
        XCTAssertEqual(round.currentPose?.id, "warrior")
        XCTAssertEqual(state.completed, 1)
        round.skip()
        XCTAssertTrue(round.finished)
        XCTAssertTrue(round.update(nil, now: t + 1).finished)
    }

    // MARK: WakeUp squats

    func testSquatCounter() {
        let counter = SquatCounter(target: 2, confirmFrames: 3)
        let up = standing(), down = standing(kneeBend: 120)
        XCTAssertGreaterThan(SquatCounter.kneeAngle(up)!, 160)
        XCTAssertLessThan(SquatCounter.kneeAngle(down)!, 105)
        var counted = 0
        for body in Array(repeating: down, count: 3) + Array(repeating: up, count: 3) + Array(repeating: down, count: 2) + [up] {
            if counter.update(body).justCounted { counted += 1 }
        }
        XCTAssertEqual(counter.count, 1)          // the second dip was only 2 frames
        for body in Array(repeating: down, count: 3) + Array(repeating: up, count: 3) { _ = counter.update(body) }
        XCTAssertEqual(counter.count, 2)
        XCTAssertTrue(counter.done)
        XCTAssertFalse(counter.update(nil).visible)
        XCTAssertEqual(counted, 1)
    }

    // MARK: Classroom (test_attention.py)

    func testAttentiveDefault() {
        XCTAssertEqual(Attention.instantFlags(person()), Attention.Flags())
    }

    func testLaptopViewerIsNotHeadDown() {
        let f = Attention.instantFlags(person(nose: (100, 138), eyes: [(90, 106), (110, 106)]))
        XCTAssertFalse(f.headDown); XCTAssertFalse(f.sleeping)
    }

    func testRealHeadDown() {
        XCTAssertTrue(Attention.instantFlags(person(eyes: [(90, 112), (110, 112)])).headDown)
        XCTAssertTrue(Attention.instantFlags(person(nose: (100, 148))).headDown)
    }

    func testRaiseHandNeedsElbowUpAndWristWellAboveEyes() {
        XCTAssertTrue(Attention.instantFlags(person(elbows: [(45, 120), (155, 220)], wrists: [(50, 20), (150, 260)])).raised)
        XCTAssertFalse(Attention.instantFlags(person(wrists: [(50, 90), (150, 260)])).raised)
        XCTAssertFalse(Attention.instantFlags(person(elbows: [(45, 120), (155, 220)], wrists: [(50, 60), (150, 260)])).raised)
        XCTAssertTrue(Attention.instantFlags(person(elbows: [(45, 60), (155, 220)], hide: [9])).raised)
        XCTAssertFalse(Attention.instantFlags(person(elbows: [(45, 120), (155, 220)], hide: [9])).raised)
    }

    func testSleepingNoseBelowShoulder() {
        XCTAssertTrue(Attention.instantFlags(person(nose: (100, 170))).sleeping)
    }

    func testHeadMissingIsNeverSleeping() {
        for body in [person(hide: [0, 1, 2]), person(hide: [0, 1, 2], dy: 400), person(hide: [0, 1, 2, 3, 4])] {
            let f = Attention.instantFlags(body)
            XCTAssertFalse(f.sleeping); XCTAssertFalse(f.headDown); XCTAssertFalse(f.turned)
        }
    }

    func testFarSmallPersonSkipsFaceRules() {
        let small = person(nose: (100, 100), eyes: [(97, 97), (103, 97)], ears: [(95, 100), (105, 100)], shoulders: [(85, 120), (115, 120)], hide: [2])
        let f = Attention.instantFlags(small)
        XCTAssertFalse(f.turned); XCTAssertFalse(f.headDown)
    }

    func testTurnedOneEye() {
        XCTAssertTrue(Attention.instantFlags(person(hide: [2])).turned)
        var k = person(); k.points[2].c = 0.35
        XCTAssertFalse(Attention.instantFlags(k).turned)
        XCTAssertFalse(Attention.instantFlags(person(hide: [1, 2])).turned)
    }

    private func r(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> CGRect { CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1) }

    func testAssignPhones() {
        let people = [Attention.PersonInfo(id: 1, box: r(0, 0, 200, 300), shoulderY: 160, shoulderWidth: 80, wrists: [CGPoint(x: 100, y: 210)]),
                      Attention.PersonInfo(id: 2, box: r(150, 0, 400, 300), shoulderY: 160, shoulderWidth: 80, wrists: [CGPoint(x: 240, y: 210)])]
        let out = Attention.assignPhones([r(90, 200, 110, 220), r(230, 200, 250, 220), r(90, 50, 110, 70), r(500, 200, 520, 220)], to: people)
        XCTAssertEqual(out, [1: [r(90, 200, 110, 220)], 2: [r(230, 200, 250, 220)]])
        let desk = [Attention.PersonInfo(id: 1, box: r(0, 0, 400, 600), shoulderY: 160, shoulderWidth: 80, wrists: [CGPoint(x: 100, y: 250)])]
        XCTAssertEqual(Attention.assignPhones([r(340, 540, 360, 560)], to: desk), [:])
        let noWrist = [Attention.PersonInfo(id: 1, box: r(0, 0, 400, 600), shoulderY: 160, shoulderWidth: 80, wrists: [])]
        XCTAssertEqual(Attention.assignPhones([r(340, 540, 360, 560)], to: noWrist), [1: [r(340, 540, 360, 560)]])
        XCTAssertEqual(Attention.wrists(person()), [CGPoint(x: 50, y: 260), CGPoint(x: 150, y: 260)])
        XCTAssertEqual(Attention.wrists(person(hide: [9, 10])), [])
    }

    func testHoldTimingPriorityAndFreezeShift() {
        let s = Attention.Person()
        var enabled = Set(Attention.priority)
        let k = person(eyes: [(90, 112), (110, 112)], elbows: [(45, 120), (155, 220)], wrists: [(50, 20), (150, 260)])
        let phone = [r(90, 200, 110, 220)]
        XCTAssertEqual(s.update(k, phones: phone, enabled: enabled, now: 0.0), .ok); XCTAssertFalse(s.raised)
        XCTAssertEqual(s.update(k, phones: phone, enabled: enabled, now: 1.3), .ok); XCTAssertTrue(s.raised)
        XCTAssertEqual(s.update(k, phones: phone, enabled: enabled, now: 2.1), .headDown)
        s.shift(10)
        XCTAssertEqual(s.update(k, phones: phone, enabled: enabled, now: 12.5), .headDown)
        XCTAssertEqual(s.update(k, phones: phone, enabled: enabled, now: 13.1), .phone)
        enabled.remove(.phone)
        XCTAssertEqual(s.update(k, phones: phone, enabled: enabled, now: 13.2), .headDown)
        XCTAssertEqual(s.update(person(), phones: [], enabled: enabled, now: 13.3), .ok); XCTAssertFalse(s.raised)
    }

    func testGridAndSummary() {
        XCTAssertTrue(Attention.gridCell(r(0, 0, 100, 100), width: 1280, height: 720) == (0, 0))
        XCTAssertTrue(Attention.gridCell(r(1200, 650, 1270, 700), width: 1280, height: 720) == (2, 2))
        let a = Attention.Person(); a.set(state: .phone, raised: true, box: r(1200, 650, 1270, 700))
        let b = Attention.Person()
        let out = Attention.summarize([a, b], width: 1280, height: 720)
        XCTAssertEqual(out.raised, 1); XCTAssertEqual(out.grid[2][2], 1); XCTAssertEqual(out.inattentive, 1); XCTAssertEqual(out.byState[.phone], 1)
    }

    func testBoxFromKeypoints() {
        XCTAssertNil(Attention.box(BodyPose(points: Array(repeating: BodyPoint(0, 0, 0), count: 17))))
        let box = Attention.box(person())!
        XCTAssertLessThan(box.minX, 50); XCTAssertGreaterThan(box.maxX, 150); XCTAssertLessThan(box.minY, 95); XCTAssertGreaterThan(box.maxY, 300)
        let head = Attention.box(person(), only: Set(0...6))!
        XCTAssertLessThan(head.maxY, 200)
    }
}
