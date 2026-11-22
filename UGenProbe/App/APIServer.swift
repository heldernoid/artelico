import Foundation
import ImageIO
import SwiftUI
import UGenKit
import UIKit

/// The REST API: lets other devices on the same network use the stick through this iPad.
///
///   GET  /v1/status                       stick state, firmware, loaded model
///   GET  /v1/models                       models and whether each is on the iPad
///   POST /v1/vision/<task>?model=<name>   body: an image (JPEG, PNG, HEIC). Returns the result as JSON.
///        optional: &tiles=2|3 (detection), &prompts=a,b,-c (tagging, zero_shot_object_detection, object_clip),
///        &objects=people|vehicles|animals|faces|everything and &detector=<model> (object_clip; kept as the app's choice),
///        &render=1 (returns a PNG with the result drawn)
///   POST /v1/chat/completions             OpenAI-style JSON: {"model", "messages", "max_tokens", "temperature"}. Not streamed.
///   POST /v1/audio/transcriptions         body: an audio file, or OpenAI-style multipart with a "file" part.
///        optional: ?language=en, ?task=translate
///   POST /v1/vision/ask?question=<text>   body: an image. Returns the vision-language model's answer.
///
/// iPadOS suspends apps that are not on screen, so the API only answers while Hailo Studio is open.
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
            return .json(["service": "Hailo Studio for \(StudioModel.deviceKind)", "endpoints": [
                "GET /v1/status", "GET /v1/models",
                "POST /v1/vision/<task>?model=<name>  (body: image; optional tiles, prompts, render=1)",
                "POST /v1/vision/ask?question=<text>  (body: image)",
                "POST /v1/chat/completions  (OpenAI-style JSON, not streamed)",
                "POST /v1/audio/transcriptions  (body: audio file or multipart 'file'; optional language, task=translate)",
            ], "chatModels": installedChatModels, "tasks": VisionTask.allCases.map(\.rawValue)])

        case ("GET", ["v1", "status"]):
            var status: [String: Any] = ["stick": mode.rawValue, "status": self.status, "busy": liveRunning,
                                         "loadedModel": loadedModel ?? NSNull()]
            if let identity {
                status["firmware"] = identity.firmwareVersion
                if let temperature = identity.chipTemperatureCelsius { status["chipTemperatureCelsius"] = Double(temperature) }
                if let current = identity.currentLimitMilliamps { status["usbCurrentMilliamps"] = Int(current) }
            }
            return .json(status)

        case ("GET", ["v1", "models"]):
            return .json(ModelCatalog.all.map { model -> [String: Any] in
                ["name": model.name, "tasks": VisionTask.allCases.filter { VisionPipeline.supports($0, model: model) }.map(\.rawValue),
                 "input": [model.inputWidth, model.inputHeight], "onDevice": installed.contains(model.name), "bytes": model.fileSize ?? 0]
            })

        case ("POST", ["v1", "chat", "completions"]):
            return await runChat(request)
        case ("POST", ["v1", "audio", "transcriptions"]):
            return await runTranscription(request)
        case ("POST", ["v1", "vision", "ask"]):
            return await runAsk(request)
        case ("POST", let path) where path.count == 3 && path[0] == "v1" && path[1] == "vision":
            return await inTurn { await self.runVision(taskName: path[2], request: request) }

        case ("GET", ["v1", "debug", "window"]) where CommandLine.arguments.contains("-testshots"):
            // Testing from the Mac only (launch argument -testshots): a picture of this app's own window.
            guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else {
                return .error(503, "No window.")
            }
            let png = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            return HTTPResponse(contentType: "image/png", body: png)

        case (_, let path) where path.first == "v1":
            return .error(404, "No such endpoint. GET /v1 lists them.")
        default:
            return .error(404, "Not found. The API lives under /v1.")
        }
    }

    /// Runs API requests one after another. Loading a model replaces the one on the stick, so two
    /// requests at once (for example a client that gave up on a slow load and sent the next) would unload
    /// each other's models.
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

    private func runChat(_ request: HTTPRequest) async -> HTTPResponse {
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let rawMessages = object["messages"] as? [[String: Any]], !rawMessages.isEmpty else {
            return .error(400, "Send JSON with a \"messages\" array of {\"role\", \"content\"}.")
        }
        var messages: [ChatMessage] = []
        for item in rawMessages {
            guard let role = item["role"] as? String, let content = item["content"] as? String else {
                return .error(400, "Each message needs a text \"role\" and \"content\".")
            }
            switch role {
            case "system": messages.append(.system(content))
            case "assistant": messages.append(.assistant(content))
            default: messages.append(.user(content))
            }
        }
        let name = (object["model"] as? String).flatMap { installedChatModels.contains($0) ? $0 : nil } ?? installedChatModels.first
        guard let name else { return .error(503, "No chat model is on this \(StudioModel.deviceKind).") }
        do {
            let model = try await chat(named: name)
            // Each request carries its whole conversation, so start from an empty context.
            try await model.clearContext()
            var parameters = model.defaultParameters
            if let limit = object["max_tokens"] as? Int { parameters.maxGeneratedTokens = UInt32(min(max(limit, 1), 2048)) }
            if let temperature = object["temperature"] as? Double {
                parameters.temperature = Float(temperature)
                parameters.doSample = temperature > 0
            }
            var text = ""
            var pieces = 0
            for try await piece in model.generate(messages: messages, parameters: parameters) {
                text += piece
                pieces += 1
            }
            let finish = (await model.lastGenerationEnd) == .maxTokens ? "length" : "stop"
            return .json(["id": "chatcmpl-\(UUID().uuidString.prefix(8))", "object": "chat.completion", "model": name,
                          "created": Int(Date().timeIntervalSince1970),
                          "choices": [["index": 0, "finish_reason": finish, "message": ["role": "assistant", "content": text]]],
                          "usage": ["completion_tokens": pieces]])
        } catch {
            fail(error)
            return .error(500, "\(error)")
        }
    }

    private func runAsk(_ request: HTTPRequest) async -> HTTPResponse {
        let question = request.query["question"] ?? "What is in this picture?"
        guard let source = CGImageSourceCreateWithData(request.body as CFData, nil) else {
            return .error(400, "Send the picture as the request body (JPEG, PNG or HEIC).")
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 2048]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return .error(400, "The request body is not a picture this \(StudioModel.deviceKind) can read.")
        }
        do {
            let model = try await visionChat()
            try await model.clearContext()
            var parameters = model.defaultParameters
            if let limit = Int(request.query["max_tokens"] ?? "") { parameters.maxGeneratedTokens = UInt32(min(max(limit, 1), 1024)) }
            var answer = ""
            for try await piece in model.generate(messages: [.user(question, images: 1)], frames: [try model.prepareFrame(image)], parameters: parameters) {
                answer += piece
            }
            return .json(["model": Self.visionChatModelName, "question": question, "answer": answer])
        } catch {
            fail(error)
            return .error(500, "\(error)")
        }
    }

    private func runTranscription(_ request: HTTPRequest) async -> HTTPResponse {
        var audio = request.body
        var fields = request.query
        var fileExtension = "wav"
        // OpenAI clients send multipart/form-data with the audio in a part named "file".
        if let type = request.headers["content-type"], type.lowercased().hasPrefix("multipart/form-data"),
           let boundary = type.components(separatedBy: "boundary=").last?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) {
            let parts = Self.multipartParts(request.body, boundary: boundary)
            guard let file = parts.first(where: { $0.name == "file" }) else { return .error(400, "The form has no \"file\" part.") }
            audio = file.data
            if let name = file.filename, let dot = name.lastIndex(of: ".") { fileExtension = String(name[name.index(after: dot)...]) }
            for part in parts where part.name != "file" {
                fields[part.name] = String(data: part.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if let type = request.headers["content-type"]?.lowercased() {
            if type.contains("mpeg") { fileExtension = "mp3" } else if type.contains("mp4") || type.contains("m4a") { fileExtension = "m4a" }
            else if type.contains("flac") { fileExtension = "flac" } else if type.contains("aiff") { fileExtension = "aiff" }
        }
        guard !audio.isEmpty else { return .error(400, "Send an audio file as the request body.") }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("api-audio-\(UUID().uuidString).\(fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try audio.write(to: url)
            let samples = try AudioLoader.samples(from: url)
            let duration = Double(samples.count) / Double(SpeechToText.sampleRate)
            let model = try await speech()
            let language = fields["language"].flatMap { $0.isEmpty ? nil : $0.lowercased() }
            let task: SpeechTask = fields["task"] == "translate" ? .translate : .transcribe
            let segments = try await model.transcribe(samples: samples, task: task, language: language, timeout: .seconds(max(120, Int(duration))))
            return .json(["text": segments.map(\.text).joined().trimmingCharacters(in: .whitespaces), "duration": (duration * 100).rounded() / 100,
                          "segments": segments.map { ["start": $0.start, "end": $0.end, "text": $0.text] }])
        } catch {
            fail(error)
            return .error(500, "\(error)")
        }
    }

    /// Splits a multipart/form-data body into its parts.
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
