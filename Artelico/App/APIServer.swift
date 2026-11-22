import Foundation
import ImageIO
import SwiftUI
import StudioCore
import UIKit

/// The REST API: lets other devices on the same network run models on this device.
///
///   GET  /v1/status                       engine, compute units, loaded model
///   GET  /v1/models                       models and whether each is on this device
///   POST /v1/vision/<task>?model=<name>   body: an image (JPEG, PNG, HEIC). Returns the result as JSON.
///        optional: &tiles=2|3 (detection), &prompts=a,b,-c (tagging, zero_shot_object_detection, object_clip),
///        &objects=people|vehicles|animals|faces|everything and &detector=<model> (object_clip; kept as the app's choice),
///        &render=1 (returns a PNG with the result drawn)
///
/// iOS and iPadOS suspend apps that are not on screen, so the API only answers while Artelico is open.
extension StudioModel {
    static let apiPort: UInt16 = 8080

    func startAPI() {
        guard apiServer == nil else { return }
        let server = HTTPServer(port: Self.apiPort) { [weak self] request in
            guard let self else { return .error(503, "The app is shutting down.") }
            return await self.handleAPI(request)
        }
        do {
            try server.start()
            apiServer = server
            apiRunning = true
            apiNote = ""
            UIApplication.shared.isIdleTimerDisabled = true  // keep the iPad awake while serving
        } catch {
            apiNote = "Could not start the API on port \(Self.apiPort): \(error.localizedDescription)"
        }
    }

    func stopAPI() {
        apiServer?.stop()
        apiServer = nil
        apiRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// This iPad's address on Wi-Fi, for showing the API's URL.
    static var wifiAddress: String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return nil }
        defer { freeifaddrs(first) }
        for pointer in sequence(first: start, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: interface.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    private func handleAPI(_ request: HTTPRequest) async -> HTTPResponse {
        apiRequests += 1
        let parts = request.path.split(separator: "/").map(String.init)
        switch (request.method, parts) {
        case ("GET", []), ("GET", ["v1"]):
            return .json(["service": "Artelico on \(StudioModel.deviceKind)", "endpoints": [
                "GET /v1/status", "GET /v1/models",
                "POST /v1/vision/<task>?model=<name>  (body: image; optional tiles, prompts, render=1)",
            ], "tasks": VisionTask.allCases.map(\.rawValue)])

        case ("GET", ["v1", "status"]):
            return .json(["engine": "Core ML", "computeUnits": computeUnits.title, "status": self.status, "busy": liveRunning,
                          "loadedModel": (loadedModel as Any?) ?? NSNull()])

        case ("GET", ["v1", "models"]):
            return .json(ModelCatalog.all.map { model -> [String: Any] in
                ["name": model.name, "tasks": VisionTask.allCases.filter { VisionPipeline.supports($0, model: model) }.map(\.rawValue),
                 "input": [model.inputWidth, model.inputHeight], "onDevice": installed.contains(model.name)]
            })

        case ("POST", let path) where path.count == 3 && path[0] == "v1" && path[1] == "vision":
            return await inTurn { await self.runVision(taskName: path[2], request: request) }

        case (_, let path) where path.first == "v1":
            return .error(404, "No such endpoint. GET /v1 lists them.")
        default:
            return .error(404, "Not found. The API lives under /v1.")
        }
    }

    /// Runs API requests one after another. Loading a model replaces the one in use, so two requests at
    /// once (for example a client that gave up on a slow first load and sent the next) would unload each
    /// other's models.
    private func inTurn(_ work: @escaping @MainActor () async -> HTTPResponse) async -> HTTPResponse {
        let previous = apiTurn
        let mine = Task { @MainActor in
            await previous?.value
            return await work()
        }
        apiTurn = Task { _ = await mine.value }
        return await mine.value
    }

    private func runVision(taskName: String, request: HTTPRequest) async -> HTTPResponse {
        guard let task = VisionTask(rawValue: taskName) else {
            return .error(404, "Unknown task “\(taskName)”. Tasks: \(VisionTask.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        guard task != .stereoDepth else { return .error(400, "Stereo depth needs two pictures and is not offered over the API.") }
        guard !liveRunning else { return .error(409, "The stick is busy with the live view on the \(StudioModel.deviceKind). Stop it and try again.") }

        let candidates = ModelCatalog.models(for: task.rawValue).filter { VisionPipeline.supports(task, model: $0) }
        let model: ModelInfo
        if let name = request.query["model"] {
            guard let chosen = candidates.first(where: { $0.name == name }) else {
                return .error(400, "Model “\(name)” cannot do \(task.rawValue). Models: \(candidates.map(\.name).joined(separator: ", ")).")
            }
            model = chosen
        } else if let first = candidates.first {
            model = first
        } else {
            return .error(400, "No model for \(task.rawValue).")
        }

        guard !request.body.isEmpty, let source = CGImageSourceCreateWithData(request.body as CFData, nil) else {
            return .error(400, "Send the picture as the request body (JPEG, PNG or HEIC).")
        }
        // Apply the photo's EXIF orientation while decoding, and cap very large pictures.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 4096]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return .error(400, "The request body is not a picture this \(StudioModel.deviceKind) can read.")
        }

        let tiles = task == .detection ? min(max(Int(request.query["tiles"] ?? "1") ?? 1, 1), 3) : 1
        let prompts = (request.query["prompts"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if task == .tagging, prompts.isEmpty { return .error(400, "Tagging needs prompts, for example ?prompts=car,truck,-empty road") }
        if task == .findAnything, prompts.isEmpty { return .error(400, "Finding needs prompts, for example ?prompts=red backpack,dog,bicycle") }
        if task == .describeObjects {
            if prompts.isEmpty { return .error(400, "Describing needs prompts, for example ?prompts=wearing a hat,wearing a backpack") }
            // Like the app's pickers: the choice stays for Photos and Live too.
            var settings = objectSettings
            if let text = request.query["objects"] {
                guard let objects = ObjectCLIP.Objects(rawValue: text) else {
                    return .error(400, "objects is one of " + ObjectCLIP.Objects.allCases.map(\.rawValue).joined(separator: ", "))
                }
                settings.objects = objects
            }
            if let name = request.query["detector"] {
                guard let detector = ModelCatalog.model(named: name),
                      VisionPipeline.supports(settings.objects == .faces ? .face : .detection, model: detector) else {
                    return .error(400, "\(name) is not a \(settings.objects == .faces ? "face" : "object") detector.")
                }
                if settings.objects == .faces { settings.faceDetector = name } else { settings.detector = name }
            }
            objectSettings = settings
        }

        do {
            let clock = ContinuousClock()
            let start = clock.now
            try await prepare(model, task: task)
            let result: VisionResult
            if needsPipeline(task, tiles: tiles) {
                result = try await runPipeline(task, on: image, tiles: tiles, prompts: prompts)
            } else {
                result = try await VisionPipeline.run(task, on: image, device: device).result
            }
            let elapsed = clock.now - start
            let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15

            if request.query["render"] == "1", let rendered = VisionRenderer.render(result, over: image) {
                let data = NSMutableData()
                if let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, rendered, nil)
                    if CGImageDestinationFinalize(destination) { return HTTPResponse(contentType: "image/png", body: data as Data) }
                }
            }
            return .json(["task": task.rawValue, "model": model.name, "image": [image.width, image.height],
                          "milliseconds": (milliseconds * 10).rounded() / 10, "summary": result.summary, "result": result.jsonObject])
        } catch {
            fail(error)
            return .error(500, "\(error)")
        }
    }

    // MARK: Language endpoints

    static func multipartParts(_ body: Data, boundary: String) -> [(name: String, filename: String?, data: Data)] {
        let delimiter = Data("--\(boundary)".utf8)
        let headerEnd = Data("\r\n\r\n".utf8)
        var parts: [(String, String?, Data)] = []
        var position = body.startIndex
        while let start = body.range(of: delimiter, in: position..<body.endIndex) {
            guard let next = body.range(of: delimiter, in: start.upperBound..<body.endIndex) else { break }
            // Between two delimiters: CRLF, headers, blank line, data, CRLF.
            let section = body[start.upperBound..<next.lowerBound]
            if let split = section.range(of: headerEnd),
               let headers = String(data: section[section.startIndex..<split.lowerBound], encoding: .utf8) {
                var data = section[split.upperBound..<section.endIndex]
                if data.suffix(2) == Data("\r\n".utf8) { data = data.dropLast(2) }
                func attribute(_ key: String) -> String? {
                    guard let range = headers.range(of: "\(key)=\"") else { return nil }
                    let rest = headers[range.upperBound...]
                    return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
                }
                if let name = attribute("name") { parts.append((name, attribute("filename"), Data(data))) }
            }
            position = next.lowerBound
        }
        return parts
    }
}
