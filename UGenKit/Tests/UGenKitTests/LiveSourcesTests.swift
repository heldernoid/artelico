import CoreGraphics
import XCTest
@testable import StudioCore

final class LiveSourcesTests: XCTestCase {
    func testMeterSplitsFramesPerSource() {
        var meter = FrameRateMeter(sources: 3, window: 1)
        // Source 0 every 0.05 s, source 1 every 0.1 s, source 2 never, for one second.
        var changed = false
        for step in 0...20 {
            let time = 100 + Double(step) * 0.05
            changed = meter.tick(source: 0, at: time) || changed
            if step % 2 == 0 { changed = meter.tick(source: 1, at: time) || changed }
        }
        XCTAssertTrue(changed)
        XCTAssertEqual(meter.perSource[0], 21, accuracy: 0.5)
        XCTAssertEqual(meter.perSource[1], 10, accuracy: 0.5)
        XCTAssertEqual(meter.perSource[2], 0)
        XCTAssertEqual(meter.total, meter.perSource.reduce(0, +), accuracy: 1e-9)
        XCTAssertFalse(meter.tick(source: 7, at: 200), "an unknown source is ignored")
    }

    func testSourceLimit() {
        let gigabyte: UInt64 = 1024 * 1024 * 1024
        XCTAssertEqual(LiveSources.limit(physicalMemory: 8 * gigabyte, isMac: true), 4)
        XCTAssertEqual(LiveSources.limit(physicalMemory: 4 * gigabyte, isMac: true), 4)
        XCTAssertEqual(LiveSources.limit(physicalMemory: 8 * gigabyte, isMac: false), 4)
        XCTAssertEqual(LiveSources.limit(physicalMemory: 3_970_000_000, isMac: false), 4, "a 4 GB iPhone reports about 3.7 GiB")
        XCTAssertEqual(LiveSources.limit(physicalMemory: 3 * gigabyte, isMac: false), 2)
    }

    private func face(_ name: String?, x: Double = 0.1, size: Double = 0.2) -> Face {
        Face(boundingBox: CGRect(x: x, y: 0.1, width: size, height: size), confidence: 0.9, landmarks: [], name: name)
    }

    private func picture(_ width: Int, _ height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    func testSightingsBecomeVisitsPerSource() {
        var log = SightingLog()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let frame = picture(640, 360)
        // Ann on source 0 for 2 s, then on source 1 at 10 s; Bob once on source 1; an unnamed face is ignored.
        for step in 0...20 {
            log.record(.faces([face("Ann"), face(nil, x: 0.6)]), source: 0, at: start + Double(step) * 0.1, frame: frame)
        }
        log.record(.faces([face("Ann")]), source: 1, at: start + 10, frame: frame)
        log.record(.described([DescribedObject(boundingBox: CGRect(x: 0.5, y: 0.2, width: 0.2, height: 0.6), confidence: 0.8, name: "Person 1")]),
                   source: 1, at: start + 11, frame: frame)
        // Ann back on source 0 after a long gap: a new visit.
        log.record(.faces([face("Ann")]), source: 0, at: start + 20, frame: frame)

        XCTAssertEqual(log.people.map(\.name), ["Ann", "Person 1"])
        let ann = log.people[0]
        XCTAssertEqual(ann.visits.map(\.source), [0, 1, 0])
        XCTAssertEqual(ann.visits[0].frames, 21)
        XCTAssertEqual(ann.visits[0].end.timeIntervalSince(ann.visits[0].start), 2, accuracy: 1e-6)
        XCTAssertEqual(ann.firstSource, 0)
        XCTAssertEqual(ann.lastSource, 0)
        XCTAssertEqual(ann.sources, [0, 1])
        XCTAssertEqual(ann.lastSeen, start + 20)
        XCTAssertEqual(log.timeline.first?.name, "Ann", "newest visit first")
        XCTAssertEqual(log.timeline.count, 4)

        let thumbnail = try! XCTUnwrap(ann.thumbnail)
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), SightingLog.thumbnailSide)
        XCTAssertGreaterThan(thumbnail.width, 50)

        let csv = log.csv().split(separator: "\n")
        XCTAssertEqual(csv.count, 5)
        XCTAssertEqual(csv[0], "name,source,start,end,frames")
        XCTAssertTrue(csv[1].hasPrefix("Ann,1,"), "sources are numbered from 1 as on screen")
    }
}
