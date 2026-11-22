import CoreGraphics
import Foundation

/// "Seen on camera X": who was seen on which Live source and when, for faces named by recognition or
/// numbered by re-identification, and people numbered by person re-identification. The idea of hailo-apps'
/// reid_multisource ("first created at src N"), kept as a timeline instead of a label.
public struct SightingLog {
    /// One stretch of time a person was on one source without a gap longer than `SightingLog.gap`.
    public struct Visit: Equatable, Sendable {
        public let source: Int
        public let start: Date
        public internal(set) var end: Date
        public internal(set) var frames: Int
    }

    public struct Person: Identifiable {
        public var id: String { name }
        public let name: String
        /// Oldest first.
        public internal(set) var visits: [Visit]
        /// The largest view of the person so far (a small copy, not a reference to the frame).
        public internal(set) var thumbnail: CGImage?
        var thumbnailArea: Double = 0

        public var firstSeen: Date { visits[0].start }
        public var lastSeen: Date { visits.map(\.end).max() ?? firstSeen }
        public var firstSource: Int { visits[0].source }
        public var lastSource: Int { visits.max { $0.end < $1.end }?.source ?? firstSource }
        /// The sources the person appeared on, in order.
        public var sources: [Int] { Array(Set(visits.map(\.source))).sorted() }
    }

    /// A visit ends when the person has not been seen on that source for this long. Covers missed
    /// detections and the frames a busy model skips with four sources.
    public static let gap: TimeInterval = 3
    /// Thumbnails are this many pixels on their longer side.
    public static let thumbnailSide = 96

    /// In order of first sighting.
    public private(set) var people: [Person] = []

    public init() {}

    /// Notes everyone named in one result of `source`. `frame` is the picture the result belongs to, used
    /// for thumbnails (only cut when a person is new or seen larger than before). Returns the names whose
    /// visit to this source starts now.
    @discardableResult
    public mutating func record(_ result: VisionResult, source: Int, at time: Date, frame: CGImage?) -> [String] {
        var arrived: [String] = []
        for (name, box) in Self.named(in: result) {
            let index: Int
            if let found = people.firstIndex(where: { $0.name == name }) {
                index = found
            } else {
                people.append(Person(name: name, visits: []))
                index = people.count - 1
            }
            if people[index].note(source: source, at: time) { arrived.append(name) }
            let area = Double(box.width * box.height)
            if area > people[index].thumbnailArea * 1.2, let frame, let small = Self.thumbnail(of: frame, box: box) {
                people[index].thumbnail = small
                people[index].thumbnailArea = area
            }
        }
        return arrived
    }

    /// Every visit of everyone, newest first: the timeline.
    public var timeline: [(name: String, visit: Visit)] {
        people.flatMap { person in person.visits.map { (person.name, $0) } }.sorted { $0.visit.start > $1.visit.start }
    }

    /// The log as CSV (name, source, start, end, frames) for sharing; sources are numbered from 1 as on screen.
    public func csv() -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = ["name,source,start,end,frames"]
        for person in people {
            for visit in person.visits {
                let name = person.name.contains(",") ? "\"\(person.name)\"" : person.name
                lines.append("\(name),\(visit.source + 1),\(format.string(from: visit.start)),\(format.string(from: visit.end)),\(visit.frames)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The names a result carries, with their boxes (fractions of the picture, top-left origin).
    static func named(in result: VisionResult) -> [(String, CGRect)] {
        switch result {
        case .faces(let faces): return faces.compactMap { face in face.name.map { ($0, face.boundingBox) } }
        case .described(let objects): return objects.compactMap { object in object.name.map { ($0, object.boundingBox) } }
        default: return []
        }
    }

    /// A small copy of the box (grown by a fifth so a face keeps its hair and chin).
    static func thumbnail(of frame: CGImage, box: CGRect) -> CGImage? {
        let width = Double(frame.width), height = Double(frame.height)
        let grown = box.insetBy(dx: -box.width * 0.1, dy: -box.height * 0.1)
        let pixels = CGRect(x: grown.minX * width, y: grown.minY * height, width: grown.width * width, height: grown.height * height)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard pixels.width >= 4, pixels.height >= 4, let cut = frame.cropping(to: pixels) else { return nil }
        let scale = min(1, Double(thumbnailSide) / max(pixels.width, pixels.height))
        let outWidth = max(1, Int(pixels.width * scale)), outHeight = max(1, Int(pixels.height * scale))
        // Drawing into a new context makes an independent copy; `cropping` alone would keep the whole frame alive.
        guard let context = CGContext(data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cut, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
        return context.makeImage()
    }
}

extension SightingLog.Person {
    /// Returns true when a new visit starts.
    mutating func note(source: Int, at time: Date) -> Bool {
        if let last = visits.lastIndex(where: { $0.source == source }), time.timeIntervalSince(visits[last].end) <= SightingLog.gap {
            visits[last].end = max(visits[last].end, time)
            visits[last].frames += 1
            return false
        }
        visits.append(SightingLog.Visit(source: source, start: time, end: time, frames: 1))
        return true
    }
}
