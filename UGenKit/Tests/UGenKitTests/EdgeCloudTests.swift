import XCTest
@testable import StudioCore

final class EdgeCloudTests: XCTestCase {
    func testCloudTimeIsTwoRoundTripsPlusServer() {
        let c = EdgeCloudComparison(edgeMilliseconds: 10, framesPerSecond: 30, frames: 0, connectMilliseconds: 20)
        XCTAssertEqual(c.cloudNetworkMilliseconds, 40)
        XCTAssertEqual(c.cloudMilliseconds, 290)
        XCTAssertEqual(c.cloudFramesPerSecond!, 1000 / 290, accuracy: 1e-9)
        XCTAssertEqual(c.speedup!, 29, accuracy: 1e-9)
    }

    func testOfflineHasNoCloudNumbers() {
        let c = EdgeCloudComparison(edgeMilliseconds: 10, framesPerSecond: 30, frames: 5, connectMilliseconds: nil)
        XCTAssertNil(c.cloudMilliseconds)
        XCTAssertNil(c.cloudFramesPerSecond)
        XCTAssertNil(c.speedup)
    }

    func testCosts() {
        // As the demo: 1000 frames at US$1.5 per 1000; a month is 8 h x 22 days at the current speed.
        let c = EdgeCloudComparison(edgeMilliseconds: 10, framesPerSecond: 30, frames: 1000, connectMilliseconds: 20)
        XCTAssertEqual(c.cloudDollarsSoFar, 1.5, accuracy: 1e-9)
        XCTAssertEqual(c.cloudDollarsPerMonth, 30 * 3600 * 8 * 22 * 1.5 / 1000, accuracy: 1e-6)   // 28,512
    }
}
