import Foundation
import Network

/// One HTTP request as received.
public struct HTTPRequest: Sendable {
    public let method: String
    /// Path without the query string, e.g. "/v1/status".
    public let path: String
    public let query: [String: String]
    /// Header names are lower-cased.
    public let headers: [String: String]
    public let body: Data
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data

    public init(status: Int = 200, contentType: String = "application/json", body: Data = Data()) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    /// A JSON response from any JSON-compatible value (dictionaries, arrays, strings, numbers).
    public static func json(_ value: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: data)
    }

    public static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message], status: status)
    }
}

/// A small HTTP/1.1 server on Network.framework: one request per connection, bodies sized by
/// Content-Length, no TLS. Meant for a trusted local network.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    /// Largest request body accepted (a photo fits easily; a long audio clip fits too).
    public static let maximumBody = 64 * 1024 * 1024

    private let port: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "ugen.http")
    private var listener: NWListener?

    public init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    /// Starts listening. Throws if the port cannot be opened.
    public func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw StudioError.invalidInput("Port \(port) is not valid.") }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch Self.parse(buffer) {
            case .request(let request):
                Task {
                    let response = await self.handler(request)
                    self.send(response, on: connection)
                }
            case .invalid(let reason):
                self.send(.error(400, reason), on: connection)
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        let reasons = [200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict",
                       413: "Payload Too Large", 500: "Internal Server Error", 503: "Service Unavailable"]
        var head = "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Status")\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    enum Parsed {
        case incomplete
        case invalid(String)
        case request(HTTPRequest)
    }

    /// Parses a request once its head and whole body have arrived.
    static func parse(_ buffer: Data) -> Parsed {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > 64 * 1024 ? .invalid("Request head is too large.") : .incomplete
        }
        guard let head = String(data: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8) else {
            return .invalid("Request head is not text.")
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid("Malformed request line.") }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length <= maximumBody else { return .invalid("Body is larger than \(maximumBody) bytes.") }
        let bodyStart = headEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }

        let target = String(requestLine[1])
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(pieces[0]).removingPercentEncoding ?? String(pieces[0])
                let value = pieces.count > 1 ? (String(pieces[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(pieces[1])) : ""
                query[key] = value
            }
        }
        let path = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        return .request(HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, query: query, headers: headers,
                                    body: Data(buffer[bodyStart..<(bodyStart + length)])))
    }
}

extension VisionResult {
    /// A JSON-compatible description of the result. Boxes and points are normalized to the picture
    /// (0...1, origin at the top-left). Dense maps are summarised by size only.
    public var jsonObject: [String: Any] {
        func box(_ rect: CGRect) -> [String: Double] {
            ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
        }
        func point(_ p: CGPoint) -> [String: Double] { ["x": Double(p.x), "y": Double(p.y)] }
        func detection(_ d: Detection) -> [String: Any] {
            ["label": d.label, "class": d.classIndex, "confidence": Double(d.confidence), "box": box(d.boundingBox)]
        }
        switch self {
        case .detections(let found):
            return ["type": "detections", "detections": found.map(detection)]
        case .poses(let found):
            return ["type": "poses", "poses": found.map { pose -> [String: Any] in
                var item: [String: Any] = ["confidence": Double(pose.confidence), "box": box(pose.boundingBox),
                                           "keypoints": pose.keypoints.map { ["x": Double($0.position.x), "y": Double($0.position.y), "confidence": Double($0.confidence)] }]
                if let id = pose.trackID { item["track"] = id }
                return item
            }]
        case .classifications(let found):
            return ["type": "classifications", "classifications": found.map { ["label": $0.label, "class": $0.classIndex, "probability": Double($0.probability)] }]
        case .depth(let map):
            return ["type": "depth", "width": map.width, "height": map.height,
                    "minimum": Double(map.values.min() ?? 0), "maximum": Double(map.values.max() ?? 0)]
        case .segmentation(let map):
            let present = Set(map.classes).sorted().map { Int($0) < map.labels.count ? map.labels[Int($0)] : "class \($0)" }
            return ["type": "segmentation", "width": map.width, "height": map.height, "classes": present]
        case .instances(let found):
            return ["type": "instances", "instances": found.map { instance -> [String: Any] in
                var item = detection(instance.detection)
                item["maskPixels"] = instance.mask.reduce(0) { $0 + ($1 > 127 ? 1 : 0) }
                item["maskSize"] = [instance.maskWidth, instance.maskHeight]
                return item
            }]
        case .orientedDetections(let found):
            return ["type": "orientedDetections", "detections": found.map { ["label": $0.label, "class": $0.classIndex, "confidence": Double($0.confidence), "corners": $0.corners.map(point)] }]
        case .lanes(let found):
            return ["type": "lanes", "lanes": found.map { $0.points.map(point) }]
        case .faces(let found):
            return ["type": "faces", "faces": found.map { face -> [String: Any] in
                var item: [String: Any] = ["confidence": Double(face.confidence), "box": box(face.boundingBox), "landmarks": face.landmarks.map(point)]
                if let name = face.name { item["name"] = name }
                return item
            }]
        case .text(let found):
            return ["type": "text", "regions": found.map { ["text": $0.text, "confidence": Double($0.confidence), "corners": $0.corners.map(point)] }]
        case .image(let output):
            return ["type": "image", "width": output.image.width, "height": output.image.height]
        case .described(let found):
            return ["type": "described", "objects": found.map { item -> [String: Any] in
                var entry: [String: Any] = ["confidence": Double(item.confidence), "box": box(item.boundingBox),
                                            "attributes": item.attributes.map { ["label": $0.label, "class": $0.classIndex, "probability": Double($0.probability)] }]
                if let label = item.label { entry["label"] = label }
                if let name = item.name { entry["name"] = name }
                if let similarity = item.similarity { entry["similarity"] = Double(similarity) }
                return entry
            }]
        case .faceLandmarks(let found):
            return ["type": "faceLandmarks", "faces": found.map { face -> [String: Any] in
                var entry: [String: Any] = ["confidence": Double(face.confidence), "box": box(face.boundingBox), "points": face.points.map(point)]
                if let pose = face.headPose { entry["headPose"] = ["yaw": Double(pose.yaw), "pitch": Double(pose.pitch), "roll": Double(pose.roll)] }
                return entry
            }]
        }
    }
}
