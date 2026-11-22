import CoreGraphics
import XCTest
@testable import StudioCore

/// Rules of the detection examples. Tracker, line counter and plate cases are the demo's own
/// (Traffic/test_traffic_logic.py), ported; missing check, Portuguese plates and the barrier are new.
final class DetectionGamesTests: XCTestCase {
    private func r(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> CGRect { CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1) }

    func testIoU() {
        XCTAssertEqual(boxIoU(r(0, 0, 10, 10), r(5, 5, 15, 15)), 25.0 / 175.0, accuracy: 1e-9)
        XCTAssertEqual(boxIoU(r(0, 0, 10, 10), r(20, 20, 30, 30)), 0)
    }

    func testTrackerKeepsIDAndCountsOnce() {
        let tracker = CentroidTracker(), counter = LineCounter(lineY: 100)
        var ids = Set<Int>()
        for k in 0..<12 {
            let y = 40.0 + Double(k) * 12
            let tracks = tracker.update([("car", r(100, y, 160, y + 40))])
            ids.insert(tracks[0].id)
            counter.update(tracks)
        }
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(counter.count("car", .down), 1)
        XCTAssertEqual(counter.total, 1)
    }

    func testTwoObjectsDifferentIDsAndDirections() {
        let tracker = CentroidTracker(), counter = LineCounter(lineY: 100)
        for k in 0..<12 {
            let s = Double(k) * 12
            counter.update(tracker.update([("car", r(50, 40 + s, 110, 80 + s)), ("person", r(400, 160 - s, 430, 220 - s))]))
        }
        XCTAssertEqual(counter.count("car", .down), 1)
        XCTAssertEqual(counter.count("person", .up), 1)
    }

    func testTrackExpires() {
        let tracker = CentroidTracker(maxMissed: 2)
        tracker.update([("car", r(0, 0, 10, 10))])
        for _ in 0..<4 { tracker.update([]) }
        XCTAssertTrue(tracker.tracks.isEmpty)
    }

    func testNormalizePlate() {
        XCTAssertEqual(PlateText.normalize("ABC-1234"), "ABC-1234")
        XCTAssertEqual(PlateText.normalize("abc1234"), "ABC-1234")
        XCTAssertEqual(PlateText.normalize("1234-AB"), "1234-AB")
        XCTAssertEqual(PlateText.normalize("AB0-123"), "AB-0123")
        XCTAssertNil(PlateText.normalize("台北市"))
        XCTAssertNil(PlateText.normalize(""))
        // Portugal
        XCTAssertEqual(PlateText.normalize("AA-00-AA"), "AA-00-AA")
        XCTAssertEqual(PlateText.normalize("12 AB 34"), "12-AB-34")
        XCTAssertEqual(PlateText.normalize("12-34-XO"), "12-34-XO")    // O read as 0, put back in a letter pair
        XCTAssertEqual(PlateText.normalize("AB-12-34"), "AB-12-34")
        XCTAssertNil(PlateText.normalize("HELLO"))
    }

    func testMissingCheck() {
        let check = MissingCheck(window: 3)
        XCTAssertFalse(check.update(["cup", "mouse"]).armed)
        check.setBaseline(["cup", "mouse", "person", "cup"])
        XCTAssertEqual(check.baseline, ["cup", "mouse"])
        XCTAssertTrue(check.update(["cup", "mouse", "person"]).allOK)            // people are ignored
        // The mouse disappears: still "present" for the window, then missing.
        XCTAssertTrue(check.update(["cup"]).missing.isEmpty)
        XCTAssertTrue(check.update(["cup"]).missing.isEmpty)
        XCTAssertEqual(check.update(["cup"]).missing, ["mouse"])
        let status = check.update(["cup", "mouse", "cell phone"])
        XCTAssertEqual(status.missing, [])
        XCTAssertEqual(status.extra, ["cell phone"])
        XCTAssertFalse(status.allOK)
    }

    func testBarrier() {
        var gate = GateBarrier()
        XCTAssertEqual(gate.angle(now: 0), 0)
        gate.open(now: 10)
        XCTAssertEqual(gate.angle(now: 10.5), 45, accuracy: 1e-9)
        XCTAssertEqual(gate.angle(now: 11.2), 90)
        XCTAssertEqual(gate.state, .open)
        XCTAssertEqual(gate.angle(now: 15), 90)
        XCTAssertEqual(gate.angle(now: 16.3), 0)
        XCTAssertEqual(gate.state, .closed)
        var shown = GateBarrier()
        shown.open(now: 0)
        XCTAssertEqual(shown.display(now: 0.5).angle, 45, accuracy: 1e-9)
        XCTAssertEqual(shown.display(now: 3).state, .open)
        XCTAssertEqual(shown.display(now: 6.5).state, .closed)
        XCTAssertEqual(shown.state, .opening)   // drawing does not change it
        gate.deny(now: 20)
        XCTAssertEqual(gate.state, .denied)
        _ = gate.angle(now: 23.5)
        XCTAssertEqual(gate.state, .closed)
    }
}

/// FaceCheckIn (the demo's test_face_engine.py match cases, ported, and the check-in rules).
final class FaceCheckInTests: XCTestCase {
    private func unit(_ seed: UInt64) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        var v = (0..<512).map { _ -> Float in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2000) / 1000 - 1
        }
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 }); v = v.map { $0 / n }
        return v
    }
    private func mix(_ a: [Float], _ wa: Float, _ b: [Float], _ wb: Float) -> [Float] { zip(a, b).map { $0 * wa + $1 * wb } }

    func testMatchAndAmbiguity() {
        var g = FaceGallery(); g.threshold = 0.45
        let a = unit(1)
        g.enroll("A", embedding: a); g.enroll("B", embedding: unit(2))
        XCTAssertEqual(g.confidentMatch(mix(a, 0.9, unit(3), 0.1))?.name, "A")
        XCTAssertNil(g.confidentMatch(unit(9)))
        // Two people almost the same: nobody is named.
        var twins = FaceGallery(); twins.threshold = 0.45
        twins.enroll("A", embedding: a); twins.enroll("B", embedding: mix(a, 0.98, unit(5), 0.02))
        XCTAssertNil(twins.confidentMatch(a))
        twins.remove("B"); twins.enroll("B", embedding: unit(6))
        XCTAssertEqual(twins.confidentMatch(a)?.name, "A")
    }

    func testAverageIsUnitLength() {
        let avg = FaceGallery.average([unit(1), unit(1), unit(2)])!
        XCTAssertEqual(sqrt(avg.reduce(0) { $0 + $1 * $1 }), 1, accuracy: 1e-5)
        XCTAssertNil(FaceGallery.average([]))
    }

    func testCheckInNeedsAMomentAndResetHasGrace() {
        let book = CheckInBook(confirm: 0.6, grace: 3)
        XCTAssertEqual(book.update(["Ana"], now: 0), [])
        XCTAssertEqual(book.update(["Ana"], now: 0.3), [])
        XCTAssertEqual(book.update(["Ana"], now: 0.7), ["Ana"])
        XCTAssertEqual(book.update(["Ana"], now: 1.0), [])        // only once
        _ = book.update([], now: 1.1)                             // left the picture
        XCTAssertEqual(book.update(["Rui"], now: 1.2), [])
        XCTAssertEqual(book.update([], now: 1.5), [])             // a gap restarts the moment
        XCTAssertEqual(book.update(["Rui"], now: 1.6), [])
        XCTAssertEqual(book.update(["Rui"], now: 2.3), ["Rui"])
        book.reset(now: 3)
        XCTAssertTrue(book.checked.isEmpty)
        XCTAssertEqual(book.update(["Ana"], now: 4), [])
        XCTAssertEqual(book.update(["Ana"], now: 5.9), [])        // still in the grace period
        XCTAssertEqual(book.update(["Ana"], now: 6.1), ["Ana"])
    }
}
