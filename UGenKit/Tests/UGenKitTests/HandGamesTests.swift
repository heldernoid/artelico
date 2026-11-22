import CoreGraphics
import XCTest
@testable import StudioCore

/// Hand examples. The gesture cases are the demo's own (HandDemos/test_gestures.py), ported.
final class HandGamesTests: XCTestCase {
    /// The demo's synthetic hand: wrist at (100, 200), fingers up. `ext`: index, middle, ring, pinky straight.
    private func synth(_ ext: [Bool], thumbOpen: Bool = false, thumbUp: Bool = true, thumbTouchesIndex: Bool = false) -> [CGPoint] {
        var p = Array(repeating: CGPoint.zero, count: 21)
        p[0] = CGPoint(x: 100, y: 200)
        let xs: [CGFloat] = [80, 95, 110, 125], base = [5, 9, 13, 17]
        for (i, straight) in ext.enumerated() {
            let b = base[i], x = xs[i]
            p[b] = CGPoint(x: x, y: 150)
            if straight {
                p[b + 1] = CGPoint(x: x, y: 125); p[b + 2] = CGPoint(x: x, y: 105); p[b + 3] = CGPoint(x: x, y: 85)
            } else {
                p[b + 1] = CGPoint(x: x, y: 140); p[b + 2] = CGPoint(x: x + 5, y: 155); p[b + 3] = CGPoint(x: x + 8, y: 165)
            }
        }
        p[1] = CGPoint(x: 75, y: 185); p[2] = CGPoint(x: 62, y: 170)
        if thumbTouchesIndex {
            p[3] = CGPoint(x: 70, y: 160); p[4] = p[8]
        } else if thumbOpen {
            p[3] = CGPoint(x: 48, y: 155); p[4] = thumbUp ? CGPoint(x: 35, y: 140) : CGPoint(x: 35, y: 200)
        } else {
            p[3] = CGPoint(x: 66, y: 172); p[4] = CGPoint(x: 64, y: 182)
        }
        return p
    }

    func testNumbers() {
        XCTAssertEqual(HandSigns.classify(synth([false, false, false, false])), .fist)
        XCTAssertEqual(HandSigns.classify(synth([true, false, false, false])), .one)
        XCTAssertEqual(HandSigns.classify(synth([true, true, false, false])), .two)
        XCTAssertEqual(HandSigns.classify(synth([true, true, true, false])), .three)
        XCTAssertEqual(HandSigns.classify(synth([true, true, true, true])), .four)
        XCTAssertEqual(HandSigns.classify(synth([true, true, true, true], thumbOpen: true)), .five)
    }

    func testSpecialSigns() {
        XCTAssertEqual(HandSigns.classify(synth([false, false, false, false], thumbOpen: true, thumbUp: true)), .thumbsUp)
        XCTAssertEqual(HandSigns.classify(synth([false, false, false, false], thumbOpen: true, thumbUp: false)), .thumbsDown)
        XCTAssertEqual(HandSigns.classify(synth([true, false, false, true])), .rock)
        XCTAssertEqual(HandSigns.classify(synth([false, true, true, true], thumbTouchesIndex: true)), .ok)
        XCTAssertEqual(HandSigns.classify(synth([false, false, false, false], thumbTouchesIndex: true)), .heart)
        XCTAssertEqual(HandSigns.classify(synth([false, false, false, true])), .pinky)
    }

    func testRotationInvariant() {
        let c = CGPoint(x: 100, y: 150)
        let rotated = synth([true, true, false, false]).map { CGPoint(x: -($0.y - c.y) + c.x, y: ($0.x - c.x) + c.y) }
        XCTAssertEqual(HandSigns.classify(rotated), .two)
    }

    func testSmoother() {
        let s = SignSmoother(frames: 3)
        XCTAssertNil(s.update(.one)); XCTAssertNil(s.update(.one)); XCTAssertEqual(s.update(.one), .one)
        XCTAssertEqual(s.update(.two), .one)
        s.update(.two)
        XCTAssertEqual(s.update(.two), .two)
    }

    func testHandCropFollowsTheForearm() {
        var points = Array(repeating: BodyPoint(0, 0, 0), count: 17)
        points[BodyPose.rightElbow] = BodyPoint(300, 400, 0.9)
        points[BodyPose.rightWrist] = BodyPoint(300, 300, 0.9)     // forearm pointing up, 100 px
        let box = HandCrop.box(BodyPose(points: points, width: 1280, height: 720), wrist: BodyPose.rightWrist, elbow: BodyPose.rightElbow)!
        XCTAssertEqual(box.size, 110, accuracy: 1e-9)
        XCTAssertEqual(box.x + box.size / 2, 300, accuracy: 1e-9)
        XCTAssertEqual(box.y + box.size / 2, 300 - 110 * 0.35, accuracy: 1e-9)  // centre pushed towards the fingers
        points[BodyPose.rightWrist].c = 0.1
        XCTAssertNil(HandCrop.box(BodyPose(points: points), wrist: BodyPose.rightWrist, elbow: BodyPose.rightElbow))
    }

    func testFruitIsCutByAFastStroke() {
        XCTAssertTrue(segmentHitsCircle(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 50, y: 10), 12))
        XCTAssertFalse(segmentHitsCircle(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 50, y: 40), 12))
        // Random sequence: no bomb (0.5 >= 0.18), kind 2, x and speeds from 0.5.
        let game = FruitGame(seconds: 30, random: { 0.5 })
        game.start(now: 0)
        game.update(tips: [], now: 0.8, dt: 0.016)                 // spawns one fruit
        XCTAssertEqual(game.items.count, 1)
        let fruit = game.items[0]
        // A slow stroke through the fruit does nothing; a fast one cuts it.
        let at = CGPoint(x: fruit.x, y: fruit.y)
        game.update(tips: [("R", CGPoint(x: at.x - 0.5, y: at.y))], now: 0.81, dt: 0.01)
        game.update(tips: [("R", CGPoint(x: at.x + 0.5, y: at.y))], now: 0.82, dt: 0.01)   // 100 px/s: too slow
        XCTAssertEqual(game.score, 0)
        let now = game.items[0]
        let cut = game.update(tips: [("R", CGPoint(x: now.x + 60, y: now.y))], now: 0.83, dt: 0.01)
        _ = cut
        game.update(tips: [("R", CGPoint(x: now.x - 60, y: now.y))], now: 0.84, dt: 0.01)
        XCTAssertEqual(game.score, 1)
        game.update(tips: [], now: 31, dt: 0.016)
        XCTAssertEqual(game.phase, .over)
        XCTAssertEqual(game.best, 1)
    }

    func testAirBandZones() {
        let band = AirBand()
        // Piano: entering a key plays it once; the top of the picture is an octave higher.
        XCTAssertEqual(band.update([("a", 660, 200)], now: 0), [.piano(key: 4, high: true)])
        XCTAssertEqual(band.update([("a", 665, 200)], now: 0.2), [])
        XCTAssertEqual(band.update([("a", 700, 500)], now: 0.4), [.piano(key: 5, high: false)])
        // Drums: a quick downward hit near the bottom is the kick.
        _ = band.update([("b", 100, 450)], now: 1.0)
        XCTAssertEqual(band.update([("b", 100, 600)], now: 1.1), [.drum(.kick)])
        // Guitar: a downward strum picks the chord by height.
        _ = band.update([("c", 1100, 100)], now: 2.0)
        XCTAssertEqual(band.update([("c", 1100, 200)], now: 2.1), [.chord(1)])
    }

    func testRotatedSquareMapsCropPointsBackToThePicture() {
        // Turned 90 degrees: the crop's "up" (v smaller) is the picture's +x direction.
        let square = RotatedSquare(cx: 100, cy: 50, size: 224, angle: -Double.pi / 2)
        let centre = square.toPicture(u: 112, v: 112, side: 224)
        XCTAssertEqual(centre.x, 100, accuracy: 1e-9); XCTAssertEqual(centre.y, 50, accuracy: 1e-9)
        let up = square.toPicture(u: 112, v: 12, side: 224)   // 100 crop pixels above the centre
        XCTAssertEqual(up.x, 200, accuracy: 1e-9); XCTAssertEqual(up.y, 50, accuracy: 1e-9)
    }

    func testUprightAngleTurnsTheForearmUp() {
        var points = [CGPoint](repeating: .zero, count: 17), conf = [Double](repeating: 0, count: 17)
        points[BodyPose.rightElbow] = CGPoint(x: 100, y: 100); points[BodyPose.rightWrist] = CGPoint(x: 200, y: 100)   // forearm to the right
        conf[BodyPose.rightElbow] = 1; conf[BodyPose.rightWrist] = 1
        let body = BodyPose(points: zip(points, conf).map { BodyPoint(Double($0.x), Double($0.y), $1) }, width: 640, height: 480)
        let angle = HandCrop.uprightAngle(body, wrist: BodyPose.rightWrist, elbow: BodyPose.rightElbow)
        // Turning the forearm direction (1, 0) by `angle` gives "up" (0, -1).
        XCTAssertEqual(cos(angle), 0, accuracy: 1e-9); XCTAssertEqual(sin(angle), -1, accuracy: 1e-9)
    }

    func testOneEuroFilterSteadiesStillValuesAndFollowsMovement() {
        var still = OneEuroFilter(), noisy: [Double] = [], smoothed: [Double] = []
        var seed: UInt64 = 12345   // fixed pseudo-random noise (+-3 px), so the test is the same every run
        for i in 0..<120 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let x = 100 + (Double(seed >> 11) / Double(1 << 53) * 6 - 3)
            noisy.append(x); smoothed.append(still(x, time: Double(i) / 30))
        }
        func spread(_ v: [Double]) -> Double { let m = v.reduce(0, +) / Double(v.count); return sqrt(v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)) }
        XCTAssertLessThan(spread(Array(smoothed.dropFirst(30))), spread(Array(noisy.dropFirst(30))) / 2)
        var moving = OneEuroFilter(), last = 0.0
        for i in 0..<30 { last = moving(Double(i) * 20, time: Double(i) / 30) }   // 600 px per second
        XCTAssertLessThan(580 - last, 40)   // little lag
    }

    func testFruitSpeedAndSizeSettings() {
        func firstFruit(speed: Double, size: Double) -> FruitGame.Item {
            let game = FruitGame(random: { 0.5 })   // no bombs, middle values
            game.speed = speed; game.size = size
            game.start(now: 0)
            _ = game.update(tips: [], now: 3.0, dt: 0.0)   // spawns one fruit (also at half speed)
            _ = game.update(tips: [], now: 3.1, dt: 0.1)
            XCTAssertEqual(game.items.count, 1)
            return game.items.first ?? FruitGame.Item(id: 0, kind: 0, x: 0, y: 0, vx: 0, vy: 0, radius: 0)
        }
        let normal = firstFruit(speed: 1, size: 1), slow = firstFruit(speed: 0.5, size: 1), big = firstFruit(speed: 1, size: 2)
        let start = FruitGame.height + 40
        XCTAssertEqual(start - slow.y, (start - normal.y) / 2, accuracy: 15)   // half the game time, about half the rise
        XCTAssertEqual(big.radius, normal.radius * 2, accuracy: 1e-9)
    }
}
