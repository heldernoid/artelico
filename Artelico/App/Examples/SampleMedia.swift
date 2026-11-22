import CryptoKit
import SwiftUI

/// The sample pictures bundled with the apps and Hailo's demo videos, with where each one comes from.
/// Shared by Artelico and Hailo Studio. The videos (hailo-apps resources, MIT licence, © Hailo) are in
/// huggingface.co/helmo/artelico-models under samples/videos/; one downloads the first time it is chosen
/// and is kept on the device.
enum SampleMedia {
    struct Credit {
        let who: String
        let licence: String
        let link: URL
    }

    static let hailo = Credit(who: "Hailo", licence: "hailo-apps, MIT licence", link: URL(string: "https://github.com/hailo-ai/hailo-apps")!)
    static let demos = Credit(who: "UGen300 demos", licence: "MIT licence", link: URL(string: "https://github.com/erp0917-stack/ugen300-demos")!)
    static let mediapipe = Credit(who: "Google MediaPipe", licence: "Apache-2.0", link: URL(string: "https://github.com/google-ai-edge/mediapipe")!)

    /// Who made a bundled sample picture or one of the demo videos.
    static func credit(for file: String) -> Credit? {
        switch file {
        case "plate_sample.png": return demos
        case "thumbs_up.jpg": return mediapipe
        case "speech_sample.wav", "": return nil
        default: return hailo   // every other sample picture and all the videos
        }
    }

    static func isVideo(_ file: String) -> Bool { file.hasSuffix(".mp4") }

    /// A demo video: a menu entry (title, file) like the sample pictures.
    static func video(_ title: String, _ file: String) -> (title: String, file: String) { ("🎬 \(title) (Hailo)", file) }

    static let street = video("People walking in a street", "example.mp4")
    static let office = video("Two people in an office", "walk_in_room.mp4")
    static let drive = video("Driving in traffic", "full_mov_slow.mp4")
    static let aerial = video("Traffic from above", "tiling_visdrone_720p.mp4")
    static let squats = video("Gym class doing squats", "grok-squats.mp4")
    static let face = video("A person talking to the camera", "face_recognition.mp4")
    static let text = video("Text on wooden blocks", "ocr.mp4")
    static let highway = video("Highway lanes", "lane_detection.mp4")
    static let parcels = video("Parcels with barcodes", "barcode.mp4")
    static let toy = video("A toy on a table", "clip_example.mp4")
    static let allVideos = [street, office, drive, aerial, squats, face, text, highway, parcels, toy]

    /// The repository commit that holds the videos.
    static let videoBase = URL(string: "https://huggingface.co/helmo/artelico-models/resolve/f9537295cef67e21ed9045aa959de4b6722ef833/samples/videos/")!

    static var videoFolder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sample-videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Size and SHA-256 of each video at that commit (from the repository's file list), to check downloads.
    static let videoChecks: [String: (bytes: Int64, sha256: String)] = [
        "barcode.mp4": (590_333, "e2222e3e4d96d04259454b52c3e89f54cce6d68a494023ed5403a98cf95b6959"),
        "clip_example.mp4": (5_734_187, "160303fe424b380c13b35dc02d6f18093cfba1fbf03c2bd2a40cceb21065d89a"),
        "example.mp4": (2_222_921, "c4cdec38c71ebe693a25def6a159b0b71f87233e7a844fc297206c0537ecdc25"),
        "example_640.mp4": (1_625_397, "d36486029f416499dd7759c279c13e51c1d21d7c3d75c8819feea52457667c70"),
        "face_recognition.mp4": (38_037_396, "0a837aef6ec7db70c7b0a3b2fc42364ee4da871420556d233bb41f589938a98e"),
        "full_mov_slow.mp4": (95_497_347, "51fd5aab45cabf4bef1c90859345befa8b37b6c7a6962e8a7114cb519695fdd5"),
        "grok-squats.mp4": (2_632_241, "ff8f97bf5c9a5605df568378899ec7a07a8b8745fe7ffc5c3f459041907a7733"),
        "lane_detection.mp4": (17_715_707, "05f1b850355a8f6b36ae40904efa783b804d25bb62da06895eb86a1c5e0c5234"),
        "ocr.mp4": (1_095_611, "54419e5380e9bbbdf12173e6eb2191dcc37e44d4ece86c569edad8cb426e1bd5"),
        "tiling_visdrone_720p.mp4": (3_946_582, "2e2d965950dc5e9855fc571a80288a7df55b5810e308ce6b18e3f83bcb89e278"),
        "walk_in_room.mp4": (15_249_127, "2fd0ecdece9d11ca17a804e713d38b19dd6333f421e3fd44b47da92a811d7e98"),   // re-encoded: seekable keyframes
    ]

    /// The video on this device, downloading it the first time. A download is kept only when its SHA-256
    /// matches; a kept file of the wrong size (cut short, changed) is downloaded again.
    static func localVideo(_ file: String) async throws -> URL {
        let fm = FileManager.default
        let local = videoFolder.appendingPathComponent(file)
        let check = videoChecks[file]
        if fm.fileExists(atPath: local.path) {
            let size = (try? fm.attributesOfItem(atPath: local.path)[.size] as? Int64) ?? -1
            if check == nil || size == check?.bytes { return local }
            try? fm.removeItem(at: local)
        }
        let (temporary, response) = try await URLSession.shared.download(from: videoBase.appendingPathComponent(file))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? fm.removeItem(at: temporary)
            throw SourceError(description: "The sample video could not be downloaded. Check the internet connection.")
        }
        if let check {
            let digest = try await Task.detached(priority: .utility) { try sha256(of: temporary) }.value
            guard digest == check.sha256 else {
                try? fm.removeItem(at: temporary)
                throw SourceError(description: "The sample video arrived damaged (checksum differs). Try again.")
            }
        }
        try? fm.removeItem(at: local)
        try fm.moveItem(at: temporary, to: local)
        return local
    }

    /// The sample videos downloaded to this device so far, with their total size.
    static func downloadedVideos() -> (count: Int, bytes: Int64) {
        let files = (try? FileManager.default.contentsOfDirectory(at: videoFolder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let videos = files.filter { $0.pathExtension == "mp4" }
        let bytes = videos.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return (videos.count, bytes)
    }

    /// Deletes the downloaded sample videos (each downloads again when it is next chosen).
    static func removeDownloadedVideos() {
        try? FileManager.default.removeItem(at: videoFolder)
    }

    /// SHA-256 of a file, read in 4 MB pieces so a large video never sits in memory whole.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Rows for the device screen: how many sample videos are on this device and a button to remove them.
struct SampleVideoRows: View {
    @State private var downloaded = SampleMedia.downloadedVideos()
    @State private var confirming = false

    var body: some View {
        LabeledContent("Sample videos downloaded",
                       value: downloaded.count == 0 ? "None" : "\(downloaded.count) of \(SampleMedia.videoChecks.count) · \(ByteCountFormatter.string(fromByteCount: downloaded.bytes, countStyle: .file))")
        Button("Remove downloaded videos", role: .destructive) { confirming = true }
            .disabled(downloaded.count == 0)
            .confirmationDialog("Remove the \(downloaded.count) downloaded sample videos?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    SampleMedia.removeDownloadedVideos()
                    downloaded = SampleMedia.downloadedVideos()
                }
            } message: {
                Text("Each one downloads again the next time it is chosen.")
            }
            .onAppear { downloaded = SampleMedia.downloadedVideos() }
            #if DEBUG
            .task { await SampleMedia.checkTestIfRequested(); downloaded = SampleMedia.downloadedVideos() }
            #endif
    }
}

/// A small tag on a sample picture or video saying where it comes from (with a link).
struct CreditTag: View {
    let file: String

    var body: some View {
        if let credit = SampleMedia.credit(for: file) {
            Link(destination: credit.link) {
                Text("\(SampleMedia.isVideo(file) ? "🎬 Video" : "📷 Picture"): \(credit.who) · \(credit.licence)")
                    .font(.caption2).foregroundStyle(.white).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
            }
            .padding(8)
        }
    }
}

#if DEBUG
extension SampleMedia {
    /// Test from the Mac (the app's folder is not readable from outside): `-videochecktest <file>` damages
    /// that downloaded video, gets it again through `localVideo`, then removes all videos, printing each step.
    static func checkTestIfRequested() async {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-videochecktest"), index + 1 < arguments.count else { return }
        let file = arguments[index + 1]
        func log(_ line: String) { FileHandle.standardError.write(Data("videochecktest: \(line)\n".utf8)) }
        let local = videoFolder.appendingPathComponent(file)
        try? Data("not a video".utf8).write(to: local)
        log("damaged \(file): \(downloadedVideos())")
        do {
            let url = try await localVideo(file)
            let digest = try sha256(of: url)
            log("fetched again, sha256 matches: \(digest == videoChecks[file]?.sha256), \(downloadedVideos())")
        } catch {
            log("failed: \(error)")
        }
        removeDownloadedVideos()
        log("after remove: \(downloadedVideos())")
    }
}
#endif
