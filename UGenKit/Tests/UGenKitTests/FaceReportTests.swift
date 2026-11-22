import CoreGraphics
import XCTest
@testable import StudioCore

final class FaceReportTests: XCTestCase {
    func testObservationsFromAFencedAnswer() {
        let answer = """
        Sure! ```json
        {"face_shape": "oval", "eyes":"brown, \\"bright\\"", "hair": "short dark", "glasses":"none", "lighting":"soft light from the le
        """
        let found = FaceReport.parseObservations(answer)
        XCTAssertEqual(found["face_shape"], "oval")
        XCTAssertEqual(found["eyes"], "brown, \"bright\"")
        XCTAssertEqual(found["lighting"], "soft light from the le", "a cut-off last value is kept")
        XCTAssertNil(found["nose"])
        XCTAssertTrue(FaceReport.writerMessage(found).contains("- face shape: oval"))
        // A model that hands back the template is caught.
        let template = FaceReport.observerSystem[FaceReport.observerSystem.firstIndex(of: "{")!...]
        XCTAssertTrue(FaceReport.parseObservations(String(template)).isEmpty)
        XCTAssertFalse(FaceReport.observerSystem.contains("\\("), "the template is filled in")
    }

    func testReportScoresAreClampedAndNeverInvented() {
        let answer = """
        {"lighting": 82, "sharpness": "74", "framing": 140, "expression": 66.6, "summary": "A relaxed portrait.",
         "strength_1": "Natural smile", "strength_2": "", "tip_hair": "Keep the side parting", "tip_photo": "Face the window"}
        """
        let report = FaceReport.parseReport(answer)
        XCTAssertEqual(report.scores, ["lighting": 82, "sharpness": 74, "framing": 100, "expression": 67])
        XCTAssertNil(report.scores["style"], "a missing score stays missing")
        XCTAssertEqual(report.overall, 81)
        XCTAssertEqual(report.summary, "A relaxed portrait.")
        XCTAssertEqual(report.strengths, ["Natural smile"])
        XCTAssertEqual(report.tips.map(\.0), ["Hair", "Photo"])
        XCTAssertTrue(report.isUsable)
        XCTAssertFalse(FaceReport.parseReport("I cannot help with that.").isUsable)
        XCTAssertFalse(report.scoresLookCopied)
        let flat = FaceReport.parseReport(#"{"lighting":<10>,"sharpness":10,"framing":10,"summary":"<20-30 words>"}"#)
        XCTAssertEqual(flat.scores["lighting"], 10)
        XCTAssertTrue(flat.scoresLookCopied)
        XCTAssertEqual(flat.summary, "", "a hint left in place is not a summary")
    }

    func testPencilSketchIsLightWithDarkEdges() throws {
        // A grey picture with a dark grey square: the sketch keeps flat areas near white and draws the edge dark.
        let side = 200
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(gray: 0.2, alpha: 1)
        context.fill(CGRect(x: 60, y: 60, width: 80, height: 80))
        let sketch = try XCTUnwrap(FaceReport.pencilSketch(context.makeImage()!))
        XCTAssertEqual(sketch.width, side)

        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let reader = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        reader.draw(sketch, in: CGRect(x: 0, y: 0, width: side, height: side))
        func grey(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * side + x) * 4] }
        XCTAssertGreaterThan(grey(20, 20), 240, "flat background turns white")
        XCTAssertGreaterThan(grey(100, 100), 200, "flat inside turns light too")
        XCTAssertLessThan(grey(61, 100), 180, "the edge stays dark")
    }
}
