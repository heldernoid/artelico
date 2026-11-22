import CoreGraphics
import Foundation

/// Enrolling faces from photos named after the person ("Ann Smith.jpg", "ann_smith-2.png") or kept in a
/// folder per person ("Ann Smith/1.jpg"). Each photo should show one face; group photos are refused unless
/// one face clearly dominates, so a stranger is never stored under someone's name.
public enum FaceEnrolment {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp"]

    /// The person a photo belongs to. `folder` is the folder the photo is in, below the picked folder (nil when
    /// the photo was picked on its own or lies directly in the picked folder): its name wins, so "Ann/1.jpg" is Ann.
    public static func personName(file: String, folder: String? = nil) -> String? {
        if let folder, let name = clean(folder) { return name }
        return clean((file as NSString).deletingPathExtension)
    }

    /// "ann_smith-02" -> "Ann Smith", "Bob (3)" -> "Bob", "IMG_1234" -> nil (a camera's file name, not a person).
    static func clean(_ raw: String) -> String? {
        var text = raw.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
        // A trailing number, with an optional separator or brackets, numbers several photos of one person.
        if let range = text.range(of: #"[\s\-]*[\(\[]?\d+[\)\]]?\s*$"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        text = text.split(separator: " ").joined(separator: " ")
        guard !text.isEmpty, text.rangeOfCharacter(from: .letters) != nil else { return nil }
        let camera = ["img", "dsc", "dscn", "pxl", "photo", "image", "screenshot", "scan"]
        if camera.contains(text.lowercased()) { return nil }
        // Keep names written with capitals as they are; capitalise all-lowercase ones.
        return text == text.lowercased() ? text.capitalized : text
    }

    /// What to do with the faces found in one photo.
    public enum Decision: Equatable {
        case enrol(index: Int)
        case noFace
        /// More than one face and none clearly largest.
        case severalFaces(count: Int)
    }

    /// One face: enrol it. Several: the largest, when it is at least twice the area of the next (a portrait
    /// with someone small in the background); otherwise nothing.
    public static func decide(boxes: [CGRect]) -> Decision {
        guard !boxes.isEmpty else { return .noFace }
        let areas = boxes.map { Double($0.width * $0.height) }
        let order = areas.indices.sorted { areas[$0] > areas[$1] }
        if order.count == 1 || areas[order[0]] >= 2 * areas[order[1]] { return .enrol(index: order[0]) }
        return .severalFaces(count: boxes.count)
    }

    /// The photos to enrol from what was picked: image files as they are, folders searched (one level of
    /// subfolders, each named after a person). Returns (photo, person name or nil when the name is unusable).
    public static func photos(in picked: [URL]) -> [(url: URL, name: String?)] {
        var found: [(URL, String?)] = []
        let files = FileManager.default
        for url in picked {
            var isFolder: ObjCBool = false
            guard files.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            if !isFolder.boolValue {
                if isImage(url) { found.append((url, personName(file: url.lastPathComponent))) }
                continue
            }
            let entries = (try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let inner = (try? files.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                    for photo in inner.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where isImage(photo) {
                        found.append((photo, personName(file: photo.lastPathComponent, folder: entry.lastPathComponent)))
                    }
                } else if isImage(entry) {
                    found.append((entry, personName(file: entry.lastPathComponent)))
                }
            }
        }
        return found
    }

    static func isImage(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }
}
