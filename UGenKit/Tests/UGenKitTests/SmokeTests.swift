import XCTest
@testable import StudioCore
@testable import UGenKit

final class SmokeTests: XCTestCase {
    func testCatalogLoads() {
        XCTAssertEqual(ModelCatalog.all.count, 216)   // 206 Model Zoo Hailo-10H models + the hailo-apps ones (step 69)
        XCTAssertNotNil(ModelCatalog.model(named: "yolov8m"))
    }
}
