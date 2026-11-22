import CoreGraphics
import XCTest
@testable import StudioCore
@testable import UGenKit

final class TrackerTests: XCTestCase {
    // MARK: Helpers

    /// A detection whose box is centred on (x, y).
    private func detection(
        x: Double, y: Double, width: Double = 0.1, height: Double = 0.1,
        confidence: Float = 0.9, classIndex: Int = 0
    ) -> Detection {
        Detection(
            label: "class \(classIndex)",
            classIndex: classIndex,
            confidence: confidence,
            boundingBox: CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
        )
    }

    /// The track number given to the detection centred on (x, y), if it was reported.
    private func trackID(in results: [TrackedDetection], x: Double, y: Double) -> Int? {
        results.first {
            abs(Double($0.detection.boundingBox.midX) - x) < 1e-9 && abs(Double($0.detection.boundingBox.midY) - y) < 1e-9
        }?.trackID
    }

    // MARK: (a) Crossing objects

    func testObjectsCrossingInNeighbouringLanesKeepTheirIDs() {
        var tracker = ObjectTracker()
        for frame in 0..<60 {
            let rightward = 0.1 + 0.0125 * Double(frame)
            let leftward = 0.9 - 0.0125 * Double(frame)
            let results = tracker.update([detection(x: rightward, y: 0.50), detection(x: leftward, y: 0.53)])
            XCTAssertEqual(results.count, 2, "frame \(frame)")
            XCTAssertEqual(trackID(in: results, x: rightward, y: 0.50), 1, "frame \(frame)")
            XCTAssertEqual(trackID(in: results, x: leftward, y: 0.53), 2, "frame \(frame)")
        }
    }

    /// Same lane, same size: just after they pass, each detection overlaps the *other* object's last
    /// box more than its own, so only the motion prediction keeps the numbers apart.
    func testObjectsCrossingInTheSameLaneKeepTheirIDs() {
        var tracker = ObjectTracker()
        for frame in 0..<41 {
            let rightward = 0.10 + 0.02 * Double(frame)
            let leftward = 0.91 - 0.02 * Double(frame)
            // Alternate the input order to show that IDs do not depend on it.
            var input = [detection(x: rightward, y: 0.5), detection(x: leftward, y: 0.5)]
            if frame % 2 == 1 { input.reverse() }
            let results = tracker.update(input)
            XCTAssertEqual(results.count, 2, "frame \(frame)")
            XCTAssertEqual(trackID(in: results, x: rightward, y: 0.5), 1, "frame \(frame)")
            XCTAssertEqual(trackID(in: results, x: leftward, y: 0.5), 2, "frame \(frame)")
        }
    }

    // MARK: (b) Disappearing objects

    func testObjectMissingForLessThanTheLostWindowKeepsItsID() {
        var tracker = ObjectTracker(maxLostFrames: 10)
        var frame = 0
        func position() -> Double { 0.2 + 0.01 * Double(frame) }

        for _ in 0..<10 {
            XCTAssertEqual(tracker.update([detection(x: position(), y: 0.5)]).map(\.trackID), [1])
            frame += 1
        }
        for _ in 0..<5 {
            XCTAssertTrue(tracker.update([]).isEmpty)
            frame += 1
        }
        for _ in 0..<10 {
            XCTAssertEqual(tracker.update([detection(x: position(), y: 0.5)]).map(\.trackID), [1])
            frame += 1
        }
    }

    func testObjectMissingForExactlyTheLostWindowKeepsItsID() {
        var tracker = ObjectTracker(maxLostFrames: 10)
        for _ in 0..<5 { _ = tracker.update([detection(x: 0.5, y: 0.5)]) }
        for _ in 0..<10 { _ = tracker.update([]) }
        XCTAssertEqual(tracker.update([detection(x: 0.5, y: 0.5)]).map(\.trackID), [1])
    }

    func testObjectMissingForLongerThanTheLostWindowGetsANewID() {
        var tracker = ObjectTracker(maxLostFrames: 10)
        for _ in 0..<5 {
            XCTAssertEqual(tracker.update([detection(x: 0.5, y: 0.5)]).map(\.trackID), [1])
        }
        for _ in 0..<11 { _ = tracker.update([]) }

        // It is a new object now: not reported until seen `minimumHits` (2) times in a row, then number 2.
        XCTAssertTrue(tracker.update([detection(x: 0.5, y: 0.5)]).isEmpty)
        for _ in 0..<5 {
            XCTAssertEqual(tracker.update([detection(x: 0.5, y: 0.5)]).map(\.trackID), [2])
        }
    }

    func testOtherObjectsKeepTheirIDsWhileOneIsMissing() {
        var tracker = ObjectTracker()
        let staying = detection(x: 0.2, y: 0.2)
        let blinking = detection(x: 0.7, y: 0.7)
        for frame in 0..<30 {
            let hidden = (10..<15).contains(frame)
            let results = tracker.update(hidden ? [staying] : [staying, blinking])
            XCTAssertEqual(results.map(\.trackID), hidden ? [1] : [1, 2], "frame \(frame)")
        }
    }

    // MARK: (c) Confidence dips

    func testConfidenceDipBetweenTheThresholdsKeepsTheID() {
        var tracker = ObjectTracker(highConfidenceThreshold: 0.5, lowConfidenceThreshold: 0.1)
        for frame in 0..<30 {
            let confidence: Float = (10..<20).contains(frame) ? 0.2 : 0.9
            let results = tracker.update([detection(x: 0.2 + 0.01 * Double(frame), y: 0.5, confidence: confidence)])
            XCTAssertEqual(results.map(\.trackID), [1], "frame \(frame)")
            XCTAssertEqual(results.first?.detection.confidence, confidence)
        }
    }

    func testLowConfidenceDetectionsNeverStartATrack() {
        var tracker = ObjectTracker()
        for _ in 0..<10 {
            XCTAssertTrue(tracker.update([detection(x: 0.5, y: 0.5, confidence: 0.3)]).isEmpty)
        }
        // The first confident object afterwards still gets number 1.
        _ = tracker.update([detection(x: 0.5, y: 0.5)])
        XCTAssertEqual(tracker.update([detection(x: 0.5, y: 0.5)]).map(\.trackID), [1])
    }

    func testDetectionsBelowTheLowThresholdAreIgnored() {
        var tracker = ObjectTracker()
        for _ in 0..<3 { _ = tracker.update([detection(x: 0.5, y: 0.5)]) }
        XCTAssertTrue(tracker.update([detection(x: 0.5, y: 0.5, confidence: 0.05)]).isEmpty)
        XCTAssertEqual(tracker.update([detection(x: 0.5, y: 0.5)]).map(\.trackID), [1])
    }

    // MARK: (d) Still scene

    func testStillSceneKeepsTheSameIDsAndCreatesNoExtraTracks() {
        var tracker = ObjectTracker()
        let scene = [
            detection(x: 0.2, y: 0.2),
            detection(x: 0.25, y: 0.22),  // overlaps the first one
            detection(x: 0.7, y: 0.3, width: 0.3, height: 0.2),
            detection(x: 0.5, y: 0.8, classIndex: 2),
            detection(x: 0.9, y: 0.9, confidence: 0.3),  // never confident enough to be tracked
        ]
        for frame in 0..<50 {
            let results = tracker.update(scene)
            XCTAssertEqual(results.map(\.trackID), [1, 2, 3, 4], "frame \(frame)")
            XCTAssertEqual(results.map(\.detection), Array(scene.prefix(4)), "frame \(frame)")
        }
        // Had any extra track been created, this newcomer would not get number 5.
        let newcomer = detection(x: 0.1, y: 0.8)
        _ = tracker.update(scene + [newcomer])
        XCTAssertEqual(tracker.update(scene + [newcomer]).map(\.trackID), [1, 2, 3, 4, 5])
    }

    // MARK: (e) Classes

    func testOverlappingObjectsOfDifferentClassesDoNotSwapIDs() {
        var tracker = ObjectTracker()
        // A person (class 0) walks right past a parked bicycle (class 1) of the same size.
        for frame in 0..<60 {
            let personX = 0.2 + 0.01 * Double(frame)
            let person = detection(x: personX, y: 0.5, classIndex: 0)
            let bicycle = detection(x: 0.5, y: 0.5, classIndex: 1)
            // Alternate the input order as well.
            let results = tracker.update(frame % 2 == 0 ? [person, bicycle] : [bicycle, person])
            XCTAssertEqual(results.count, 2, "frame \(frame)")
            XCTAssertEqual(results.first { $0.detection.classIndex == 0 }?.trackID, 1, "frame \(frame)")
            XCTAssertEqual(results.first { $0.detection.classIndex == 1 }?.trackID, 2, "frame \(frame)")
        }
    }

    func testClassChangeStartsANewTrackOnlyWhenMatchingByClass() {
        let before = detection(x: 0.5, y: 0.5, classIndex: 0)
        let after = detection(x: 0.5, y: 0.5, classIndex: 1)

        var strict = ObjectTracker()
        _ = strict.update([before])
        XCTAssertTrue(strict.update([after]).isEmpty)
        XCTAssertEqual(strict.update([after]).map(\.trackID), [2])

        var relaxed = ObjectTracker(matchSameClassOnly: false)
        _ = relaxed.update([before])
        XCTAssertEqual(relaxed.update([after]).map(\.trackID), [1])
    }

    // MARK: (f) Numbering

    func testIDsAreNeverReusedAndRestartAfterReset() {
        var tracker = ObjectTracker(maxLostFrames: 3)
        var seen: [Int] = []
        // Ten objects appear one after another at different places; each is gone before the next.
        for object in 0..<10 {
            let x = 0.05 + 0.09 * Double(object)
            for _ in 0..<4 {
                let ids = tracker.update([detection(x: x, y: 0.5, width: 0.05)]).map(\.trackID)
                if let id = ids.first, seen.last != id { seen.append(id) }
            }
            for _ in 0..<5 { _ = tracker.update([]) }
        }
        XCTAssertEqual(seen, Array(1...10))

        // The same place as the first object, long after it was dropped: still a fresh number.
        _ = tracker.update([detection(x: 0.05, y: 0.5, width: 0.05)])
        XCTAssertEqual(tracker.update([detection(x: 0.05, y: 0.5, width: 0.05)]).map(\.trackID), [11])

        tracker.reset()
        XCTAssertEqual(tracker.update([detection(x: 0.3, y: 0.3), detection(x: 0.7, y: 0.7)]).map(\.trackID), [1, 2])
    }

    // MARK: Confirmation

    func testNewTrackIsReportedAfterMinimumHitsExceptOnTheFirstFrame() {
        var tracker = ObjectTracker(minimumHits: 3)
        let first = detection(x: 0.2, y: 0.2)
        let late = detection(x: 0.8, y: 0.8)
        // Objects present on the very first frame are reported at once.
        XCTAssertEqual(tracker.update([first]).map(\.trackID), [1])
        XCTAssertEqual(tracker.update([first, late]).map(\.trackID), [1])
        XCTAssertEqual(tracker.update([first, late]).map(\.trackID), [1])
        XCTAssertEqual(tracker.update([first, late]).map(\.trackID), [1, 2])
    }

    func testOneFrameFlickerDoesNotConsumeAnID() {
        var tracker = ObjectTracker()
        let steady = detection(x: 0.2, y: 0.2)
        _ = tracker.update([steady])
        XCTAssertEqual(tracker.update([steady, detection(x: 0.8, y: 0.8)]).map(\.trackID), [1])
        XCTAssertEqual(tracker.update([steady]).map(\.trackID), [1])
        let real = detection(x: 0.5, y: 0.8)
        _ = tracker.update([steady, real])
        XCTAssertEqual(tracker.update([steady, real]).map(\.trackID), [1, 2])
    }

    func testEmptyAndInvalidInput() {
        var tracker = ObjectTracker()
        XCTAssertTrue(tracker.update([]).isEmpty)
        let broken = Detection(label: "x", classIndex: 0, confidence: 0.9, boundingBox: CGRect(x: 0.5, y: 0.5, width: 0, height: 0.1))
        let notFinite = Detection(label: "x", classIndex: 0, confidence: 0.9, boundingBox: CGRect(x: CGFloat.nan, y: 0.5, width: 0.1, height: 0.1))
        for _ in 0..<3 {
            XCTAssertTrue(tracker.update([broken, notFinite]).isEmpty)
        }
    }

    // MARK: Assignment solver

    func testAssignmentMatchesBruteForceOnSmallMatrices() {
        var generator = SplitMix64(seed: 42)
        for _ in 0..<300 {
            let rows = Int(generator.next() % 6) + 1
            let columns = Int(generator.next() % 6) + 1
            let cost = (0..<rows).map { _ in (0..<columns).map { _ in Double(generator.next() % 100) } }

            let assignment = Assignment.solve(cost: cost)
            XCTAssertEqual(assignment.count, rows)
            let used = assignment.compactMap { $0 }
            XCTAssertEqual(used.count, min(rows, columns))
            XCTAssertEqual(Set(used).count, used.count, "a column was used twice")
            var total = 0.0
            for (row, column) in assignment.enumerated() {
                if let column { total += cost[row][column] }
            }
            XCTAssertEqual(total, bruteForceMinimum(cost), accuracy: 1e-9)
        }
    }

    func testAssignmentPrefersTheBestTotalOverTheBestSinglePair() {
        // Greedy would take (0,0) = 1 first and be forced into (1,1) = 100.
        let assignment = Assignment.solve(cost: [[1, 2], [2, 100]])
        XCTAssertEqual(assignment, [1, 0])
        XCTAssertEqual(Assignment.solve(cost: []).count, 0)
        XCTAssertEqual(Assignment.solve(cost: [[], []]), [nil, nil])
    }

    /// The cheapest total when min(rows, columns) pairs must be made, by trying every possibility.
    private func bruteForceMinimum(_ cost: [[Double]]) -> Double {
        let rows = cost.count, columns = cost[0].count
        // Make sure there are at most as many rows as columns, then every row gets a column.
        if rows > columns {
            return bruteForceMinimum((0..<columns).map { column in (0..<rows).map { cost[$0][column] } })
        }
        func best(row: Int, usedColumns: Set<Int>) -> Double {
            if row == rows { return 0 }
            var smallest = Double.infinity
            for column in 0..<columns where !usedColumns.contains(column) {
                smallest = min(smallest, cost[row][column] + best(row: row + 1, usedColumns: usedColumns.union([column])))
            }
            return smallest
        }
        return best(row: 0, usedColumns: [])
    }
}

/// A small fixed-seed random number generator, so the test is the same on every run.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
