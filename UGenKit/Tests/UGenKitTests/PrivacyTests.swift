import CoreGraphics
import XCTest
@testable import StudioCore

final class PrivacyTests: XCTestCase {
    /// A width x height picture filled with one grey level.
    private func picture(_ width: Int, _ height: Int, grey: UInt8) -> CGImage {
        let bytes = [UInt8](repeating: grey, count: width * height * 4)
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// The red value at (x, y), top-left origin.
    private func red(_ image: CGImage, _ x: Int, _ y: Int) -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return pixel[0]
    }

    func testSolidStyleCoversTheBoxOnly() throws {
        let image = picture(200, 100, grey: 255)
        let region = PrivacyRegion(kind: .face, box: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.4))   // pixels x 20...60, y 20...60
        let out = try XCTUnwrap(PrivacyFilter.apply(image, regions: [region], style: .fill))
        XCTAssertEqual(out.width, 200)
        XCTAssertLessThan(red(out, 40, 40), 60, "inside the box is filled")
        XCTAssertGreaterThan(red(out, 150, 40), 240, "outside the box is untouched")
        XCTAssertGreaterThan(red(out, 40, 90), 240, "below the box is untouched (no upside-down mask)")
    }

    func testPersonMaskHidesTheMaskNotTheWholeBox() throws {
        // A 20x10 mask over the whole picture with only its left half set; the box claims the whole picture.
        var bits = [UInt8](repeating: 0, count: 20 * 10)
        for y in 0..<10 { for x in 0..<10 { bits[y * 20 + x] = 255 } }
        let person = Instance(detection: Detection(label: "person", classIndex: 0, confidence: 0.9, boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1)),
                              maskWidth: 20, maskHeight: 10, mask: bits)
        let out = try XCTUnwrap(PrivacyFilter.apply(picture(200, 100, grey: 255), regions: PrivacyScan.people([person]), style: .fill))
        XCTAssertLessThan(red(out, 40, 50), 60)
        XCTAssertGreaterThan(red(out, 170, 50), 240)
    }

    func testNoRegionsReturnsThePicture() {
        let image = picture(10, 10, grey: 128)
        XCTAssertTrue(PrivacyFilter.apply(image, regions: [], style: .blur) === image)
    }

    func testHoldKeepsAMissedFaceForAWhile() {
        var hold = RegionHold(seconds: 0.5)
        let face = PrivacyRegion(kind: .face, box: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1))
        XCTAssertEqual(hold.update([face], time: 0).count, 1)
        XCTAssertEqual(hold.update([], time: 0.3).count, 1, "missed for 0.3 s: still hidden")
        XCTAssertEqual(hold.update([], time: 0.6).count, 0, "gone for longer than the hold")
    }

    func testHoldReplacesARegionFoundAgain() {
        var hold = RegionHold(seconds: 1)
        _ = hold.update([PrivacyRegion(kind: .face, box: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1))], time: 0)
        let moved = hold.update([PrivacyRegion(kind: .face, box: CGRect(x: 0.42, y: 0.4, width: 0.1, height: 0.1))], time: 0.1)
        XCTAssertEqual(moved.count, 1, "the same face, moved a little, is not hidden twice")
        XCTAssertEqual(moved[0].box.minX, 0.42, accuracy: 1e-9)
        let plate = hold.update([PrivacyRegion(kind: .plate, box: CGRect(x: 0.42, y: 0.4, width: 0.1, height: 0.1))], time: 0.2)
        XCTAssertEqual(plate.count, 2, "a plate does not replace a face")
    }

    func testGrowStaysInsideThePicture() {
        let box = PrivacyScan.grow(CGRect(x: 0, y: 0.05, width: 0.2, height: 0.2), x: 0.2, top: 0.5, bottom: 0.1)
        XCTAssertEqual(box.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(box.minY, 0, accuracy: 1e-9)
        XCTAssertEqual(box.maxX, 0.24, accuracy: 1e-9)
        XCTAssertEqual(box.maxY, 0.27, accuracy: 1e-9)
    }
}
