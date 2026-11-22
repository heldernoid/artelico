import Foundation
import SwiftUI

/// One public road camera.
struct RoadCamera: Codable, Identifiable, Hashable {
    let name: String
    let region: String
    let country: String
    /// "video" for a live HLS stream, "image" for a still picture the camera replaces every minute or so.
    let kind: String
    let url: String

    var id: String { url }
    var isVideo: Bool { kind == "video" }
}

/// Where a full camera list can be fetched from, as listed in streams.json ("catalogues").
/// format "511": a 511 traveller-information site (`host`), whose /List/GetData/Cameras pages list each camera.
/// format "list": `list` returns a JSON array of {id, name, highway_display?, marked_stale?}; each camera's
/// still picture is `image` with {id} replaced.
struct CameraCatalogue: Codable, Hashable {
    let format: String
    let region: String
    let country: String
    var host: String?
    var list: String?
    var image: String?
}

/// The built-in camera list plus whatever has been fetched from the public catalogues.
/// Both come from streams.json in the app: either a plain array of cameras, or
/// {"cameras": [...], "catalogues": [...]}. A copy of the source without that data has an empty list;
/// a cameras.json (the same array format) put in the app's Documents folder is used instead.
@MainActor
final class StreamCatalog: ObservableObject {
    @Published var cameras: [RoadCamera] = []
    @Published var fetching = false
    @Published var note = ""
    @Published private(set) var catalogues: [CameraCatalogue] = []

    private struct BuiltIn: Decodable {
        var cameras: [RoadCamera] = []
        var catalogues: [CameraCatalogue] = []
    }

    private static var savedURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("cameras.json")
    }

    private static func builtIn() -> BuiltIn {
        guard let url = Bundle.main.url(forResource: "streams", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return BuiltIn() }
        if let list = try? JSONDecoder().decode([RoadCamera].self, from: data) { return BuiltIn(cameras: list) }
        return (try? JSONDecoder().decode(BuiltIn.self, from: data)) ?? BuiltIn()
    }

    init() {
        catalogues = Self.builtIn().catalogues
        if let data = try? Data(contentsOf: Self.savedURL), let saved = try? JSONDecoder().decode([RoadCamera].self, from: data), !saved.isEmpty {
            cameras = saved
            note = "\(saved.count) cameras (cameras.json in this app's folder)"
        } else {
            loadBuiltIn()
        }
    }

    func loadBuiltIn() {
        let list = Self.builtIn().cameras
        cameras = list
        note = list.isEmpty
            ? "No cameras built in. Put a cameras.json in this app's folder (Files app, or the Mac app's container), or enter a stream address"
            : "\(list.count) built-in cameras, each checked when the app was built"
        try? FileManager.default.removeItem(at: Self.savedURL)
    }

    /// Downloads the complete current lists from the public catalogues (several thousand cameras).
    /// Addresses in the full list are not checked one by one.
    func fetchAll() async {
        fetching = true
        defer { fetching = false }
        var all: [RoadCamera] = []
        var failed: [String] = []
        for catalogue in catalogues {
            do {
                switch catalogue.format {
                case "511": all += try await Self.fetch511(catalogue)
                case "list": all += try await Self.fetchList(catalogue)
                default: continue
                }
            } catch { failed.append(catalogue.region) }
        }
        guard !all.isEmpty else {
            note = "Could not reach any catalogue. Kept the current list."
            return
        }
        cameras = all.sorted { ($0.isVideo ? 0 : 1, $0.country, $0.region, $0.name) < ($1.isVideo ? 0 : 1, $1.country, $1.region, $1.name) }
        if let data = try? JSONEncoder().encode(cameras) { try? data.write(to: Self.savedURL, options: .atomic) }
        note = "\(cameras.count) cameras fetched" + (failed.isEmpty ? "" : "; unreachable: \(failed.joined(separator: ", "))")
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPad)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        return request
    }

    private struct Page: Decodable {
        struct Camera: Decodable {
            struct View: Decodable {
                let imageUrl: String?
                let videoUrl: String?
                let isVideoAuthRequired: Bool?
                let videoDisabled: Bool?
                let disabled: Bool?
                let blocked: Bool?
            }
            let roadway: String?
            let location: String?
            let images: [View]?
        }
        let recordsTotal: Int?
        let data: [Camera]?
    }

    private static func fetch511(_ catalogue: CameraCatalogue) async throws -> [RoadCamera] {
        guard let host = catalogue.host else { return [] }
        let region = catalogue.region, country = catalogue.country
        var result: [RoadCamera] = []
        var start = 0
        var total = 1
        while start < total, start < 3000 {
            let query = "{\"columns\":[{\"data\":null,\"name\":\"\"}],\"order\":[],\"start\":\(start),\"length\":100,\"search\":{\"value\":\"\"}}"
            var components = URLComponents(string: "https://\(host)/List/GetData/Cameras")!
            components.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "lang", value: "en")]
            let (data, _) = try await URLSession.shared.data(for: request(components.url!))
            let page = try JSONDecoder().decode(Page.self, from: data)
            total = page.recordsTotal ?? 0
            for camera in page.data ?? [] {
                guard let view = camera.images?.first(where: { $0.disabled != true && $0.blocked != true }) else { continue }
                let parts = [camera.roadway, camera.location].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0.uppercased() != "N/A" }
                let name = parts.isEmpty ? "Camera" : parts.joined(separator: " · ")
                if let video = view.videoUrl, !video.isEmpty, view.isVideoAuthRequired != true, view.videoDisabled != true {
                    result.append(RoadCamera(name: name, region: region, country: country, kind: "video", url: video))
                } else if let image = view.imageUrl {
                    result.append(RoadCamera(name: name, region: region, country: country, kind: "image", url: "https://\(host)\(image)"))
                }
            }
            start += 100
        }
        return result
    }

    private static func fetchList(_ catalogue: CameraCatalogue) async throws -> [RoadCamera] {
        struct Webcam: Decodable {
            let id: Int
            let name: String
            let highway_display: String?
            let marked_stale: Bool?
        }
        guard let list = catalogue.list.flatMap(URL.init(string:)), let image = catalogue.image else { return [] }
        let (data, _) = try await URLSession.shared.data(for: request(list))
        return try JSONDecoder().decode([Webcam].self, from: data).filter { $0.marked_stale != true }.map {
            let highway = ($0.highway_display ?? "").isEmpty ? "" : "Hwy \($0.highway_display!) · "
            return RoadCamera(name: "\(highway)\($0.name)", region: catalogue.region, country: catalogue.country, kind: "image",
                              url: image.replacingOccurrences(of: "{id}", with: String($0.id)))
        }
    }
}

/// Searchable camera list. Choosing a camera hands its address back.
struct CameraListView: View {
    @ObservedObject var catalog: StreamCatalog
    let choose: (RoadCamera) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var videoOnly = false

    private var filtered: [RoadCamera] {
        catalog.cameras.filter { camera in
            (!videoOnly || camera.isVideo) &&
            (search.isEmpty || camera.name.localizedCaseInsensitiveContains(search) || camera.region.localizedCaseInsensitiveContains(search))
        }
    }

    private var regions: [(name: String, cameras: [RoadCamera])] {
        var order: [String] = []
        var groups: [String: [RoadCamera]] = [:]
        for camera in filtered {
            let key = "\(camera.region), \(camera.country)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(camera)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Live video only", isOn: $videoOnly)
                    if !catalog.catalogues.isEmpty {
                        Button(catalog.fetching ? "Fetching…" : "Fetch the full lists from the web") {
                            Task { await catalog.fetchAll() }
                        }
                        .disabled(catalog.fetching)
                    }
                    Button("Back to the built-in list") { catalog.loadBuiltIn() }
                } footer: {
                    Text("\(catalog.note). Cameras marked with a video icon are live streams; the others are still pictures that change every minute or so.")
                }
                ForEach(regions, id: \.name) { region in
                    Section("\(region.name) (\(region.cameras.count))") {
                        // Long fetched lists are cut per region; search narrows them down.
                        ForEach(region.cameras.prefix(search.isEmpty ? 60 : 300)) { camera in
                            Button {
                                choose(camera)
                                dismiss()
                            } label: {
                                Label(camera.name, systemImage: camera.isVideo ? "video.fill" : "photo")
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Road or place")
            .navigationTitle("Road cameras")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}
