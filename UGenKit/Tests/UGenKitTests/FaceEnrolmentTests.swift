import CoreGraphics
import XCTest
@testable import StudioCore

final class FaceEnrolmentTests: XCTestCase {
    func testNamesFromFiles() {
        XCTAssertEqual(FaceEnrolment.personName(file: "Ann Smith.jpg"), "Ann Smith")
        XCTAssertEqual(FaceEnrolment.personName(file: "ann_smith-02.png"), "Ann Smith")
        XCTAssertEqual(FaceEnrolment.personName(file: "Bob (3).HEIC"), "Bob")
        XCTAssertEqual(FaceEnrolment.personName(file: "Jean-Luc 2.jpg"), "Jean-Luc")
        XCTAssertEqual(FaceEnrolment.personName(file: "McAllister.jpg"), "McAllister", "capitals kept")
        XCTAssertNil(FaceEnrolment.personName(file: "IMG_1234.JPG"), "a camera's file name is not a person")
        XCTAssertNil(FaceEnrolment.personName(file: "0001.jpg"))
        XCTAssertEqual(FaceEnrolment.personName(file: "IMG_1234.JPG", folder: "Carla"), "Carla", "the folder names the person")
    }

    func testDecision() {
        let big = CGRect(x: 0.3, y: 0.2, width: 0.3, height: 0.4)
        let small = CGRect(x: 0.8, y: 0.1, width: 0.05, height: 0.07)
        let alike = CGRect(x: 0.0, y: 0.2, width: 0.28, height: 0.38)
        XCTAssertEqual(FaceEnrolment.decide(boxes: []), .noFace)
        XCTAssertEqual(FaceEnrolment.decide(boxes: [big]), .enrol(index: 0))
        XCTAssertEqual(FaceEnrolment.decide(boxes: [small, big]), .enrol(index: 1), "a small face in the background is ignored")
        XCTAssertEqual(FaceEnrolment.decide(boxes: [big, alike, small]), .severalFaces(count: 3))
    }

    func testFolderPerPerson() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("enrol-\(UUID().uuidString)")
        let files = FileManager.default
        try files.createDirectory(at: root.appendingPathComponent("Dana"), withIntermediateDirectories: true)
        for path in ["Dana/IMG_1.jpg", "Dana/IMG_2.png", "Eve 1.jpg", "notes.txt"] {
            try Data([0]).write(to: root.appendingPathComponent(path))
        }
        defer { try? files.removeItem(at: root) }
        let found = FaceEnrolment.photos(in: [root]).map { "\($0.url.lastPathComponent)=\($0.name ?? "-")" }
        XCTAssertEqual(found, ["IMG_1.jpg=Dana", "IMG_2.png=Dana", "Eve 1.jpg=Eve"])
    }
}
