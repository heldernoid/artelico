import CoreGraphics
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import Network
import VideoToolbox

// A small RTSP 1.0 client: RTSP over TCP with RTP interleaved on the same connection, H.264 only,
// decoded with VideoToolbox. No third-party code.
//
// Layout of this file:
//   RTSPClient          the public class
//   RTSPSession         one connection attempt: RTSP state machine, keep-alive, hand-off to the decoder
//   RTSPStreamParser    splits the TCP byte stream into RTSP messages and interleaved RTP packets
//   RTSPSDP             SDP parsing and control-URL resolution
//   RTSPAuth            Basic and Digest authentication
//   H264Depacketizer    RTP payload (RFC 6184) to access units
//   H264Decoder         VTDecompressionSession wrapper

// MARK: - Public API

/// An error with a message that can be shown to the user as it is.
public struct RTSPError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Plays the H.264 video of an RTSP stream and hands out the newest decoded frame.
public final class RTSPClient: @unchecked Sendable {
    private let url: URL
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var session: RTSPSession?

    /// - Parameters:
    ///   - url: `rtsp://[user:password@]host[:port]/path`. Port 554 is used if none is given.
    ///   - timeout: how long `start()` waits for the first decoded frame.
    public init(url: URL, timeout: TimeInterval = 15) {
        self.url = url
        self.timeout = timeout
    }

    deinit { session?.shutdown() }

    /// Connects and returns once the first frame has been decoded. Throws `RTSPError` otherwise.
    public func start() async throws {
        let session = RTSPSession(url: url, timeout: timeout)
        let previous: RTSPSession? = lock.withLock {
            let old = self.session
            self.session = session
            return old
        }
        previous?.shutdown()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.start { continuation.resume(with: $0) }
            }
        } onCancel: {
            session.shutdown()
        }
    }

    /// Sends TEARDOWN and closes the connection. `start()` may be called again afterwards.
    public func stop() {
        let current: RTSPSession? = lock.withLock {
            let old = session
            session = nil
            return old
        }
        current?.shutdown()
    }

    /// The newest decoded frame, once; nil until another one arrives.
    public func takeLatest() -> CGImage? {
        lock.withLock { session }?.takeLatest()
    }

    /// Set if the stream ended or broke after `start()` succeeded.
    public var failure: String? {
        lock.withLock { session }?.failure
    }

    /// Number of frames decoded since `start()`.
    public var framesDecoded: Int {
        lock.withLock { session }?.framesDecoded ?? 0
    }
}

// MARK: - Session

/// One connection to a camera. RTSP state lives on `queue`; decoding happens on `decodeQueue`;
/// the few values read from other threads are behind `lock`.
final class RTSPSession: @unchecked Sendable {
    private enum Phase: String { case idle, connecting, options = "OPTIONS", describe = "DESCRIBE", setup = "SETUP", play = "PLAY", playing, closed }

    private struct PendingRequest {
        let method: String
        let uri: String
        let headers: [(String, String)]
        let authRetried: Bool
        let handler: (RTSPResponse) -> Void
    }

    static let userAgent = "UGenKit-RTSP/1.0"
    /// After starting, the stream counts as broken if no video data arrives for this long.
    static let stallTimeout: TimeInterval = 10
    /// Access units waiting for the decoder above which new ones are dropped.
    static let maxBacklog = 12

    private let url: URL
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "ugen.rtsp")
    private let decodeQueue = DispatchQueue(label: "ugen.rtsp.decode", qos: .userInitiated)
    private let decoder = H264Decoder()

    // On `queue`.
    private var phase = Phase.idle
    private var connection: NWConnection?
    private var connectionReady = false
    private var waitingError: String?
    private var parser = RTSPStreamParser()
    private var cseq = 0
    private var pending: [Int: PendingRequest] = [:]
    private var credentials: (user: String, password: String)?
    private var challenge: RTSPAuth.Challenge?
    private var nonceCount = 0
    private var requestURL = ""
    private var playURL = ""
    private var hostLabel = ""
    private var sessionID: String?
    private var sessionTimeout: TimeInterval = 60
    private var supportsGetParameter = false
    private var rtpChannel: UInt8 = 0
    private var depacketizer = H264Depacketizer()
    private var completion: ((Result<Void, Error>) -> Void)?
    private var started = false
    private var timer: DispatchSourceTimer?
    private var deadline: TimeInterval = 0
    private var lastKeepAlive: TimeInterval = 0
    private var lastMedia: TimeInterval = 0
    private var rtpPackets = 0
    private var accessUnits = 0
    private var keyframes = 0

    // Behind `lock`.
    private let lock = NSLock()
    private var latest: CGImage?
    private var failureMessage: String?
    private var decodedCount = 0
    private var backlog = 0
    private var dropUntilKeyframe = false
    private var closed = false

    init(url: URL, timeout: TimeInterval) {
        self.url = url
        self.timeout = timeout
    }

    // MARK: Called from any thread

    func takeLatest() -> CGImage? {
        lock.withLock {
            let image = latest
            latest = nil
            return image
        }
    }

    var failure: String? { lock.withLock { failureMessage } }
    var framesDecoded: Int { lock.withLock { decodedCount } }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            guard self.phase == .idle else {
                completion(.failure(RTSPError("The stream was stopped before it started.")))
                return
            }
            self.completion = completion
            self.connect()
        }
    }

    func shutdown() {
        queue.async {
            if let completion = self.completion {
                self.completion = nil
                completion(.failure(RTSPError("The stream was stopped before the first picture arrived.")))
            }
            self.close(teardown: true)
        }
    }

    // MARK: Connection

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func connect() {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "rtsp" || scheme == "rtsps", let host = url.host(percentEncoded: false), !host.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            fail("This is not a valid RTSP address. It should look like rtsp://user:password@192.168.1.10:554/stream.")
            return
        }
        let secure = scheme == "rtsps"
        let portNumber = url.port ?? (secure ? 322 : 554)
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: portNumber)), portNumber > 0 else {
            fail("The port in this RTSP address is not valid.")
            return
        }
        if let user = url.user(percentEncoded: false), !user.isEmpty {
            credentials = (user, url.password(percentEncoded: false) ?? "")
        }
        // The address sent to the camera must not contain the user name and password.
        components.user = nil
        components.password = nil
        requestURL = components.string ?? url.absoluteString
        playURL = requestURL
        hostLabel = "\(host):\(portNumber)"

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = max(1, Int(min(timeout, 10)))
        let parameters = NWParameters(tls: secure ? NWProtocolTLS.Options() : nil, tcp: tcp)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        self.connection = connection
        phase = .connecting
        deadline = now() + timeout

        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.phase != .closed else { return }
            switch state {
            case .ready:
                guard !self.connectionReady else { return }
                self.connectionReady = true
                self.receive(on: connection)
                self.sendOptions()
            case .waiting(let error):
                // Usually the network is not reachable yet, or iPadOS is still asking for permission to
                // use the local network. A refused connection will not get better by waiting.
                self.waitingError = Self.describe(error)
                if case .posix(let code) = error, code == .ECONNREFUSED {
                    self.fail("Could not connect to \(self.hostLabel): the connection was refused. Check the address and port.")
                }
            case .failed(let error):
                if self.connectionReady {
                    self.fail("The connection to the camera was lost: \(Self.describe(error)).")
                } else {
                    self.fail("Could not connect to \(self.hostLabel): \(Self.describe(error)).")
                }
            default:
                break
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer

        connection.start(queue: queue)
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error, let text = strerror(code.rawValue) {
            return String(cString: text).lowercased()
        }
        return error.localizedDescription
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, self.phase != .closed else { return }
            if let data, !data.isEmpty {
                for item in self.parser.append(data) {
                    switch item {
                    case .interleaved(let channel, let payload):
                        if channel == self.rtpChannel { self.handleRTP(payload) }
                    case .response(let response):
                        self.handle(response)
                    case .request:
                        break  // Requests from the camera (for example ANNOUNCE) are ignored.
                    }
                    if self.phase == .closed { return }
                }
            }
            if let error {
                self.fail("The connection to the camera was lost: \(Self.describe(error)).")
            } else if isComplete {
                self.fail(self.started ? "The camera closed the connection." : "The camera closed the connection during \(self.phaseLabel()).")
            } else {
                self.receive(on: connection)
            }
        }
    }

    private func phaseLabel() -> String {
        switch phase {
        case .options, .describe, .setup, .play: return "the RTSP \(phase.rawValue) request"
        case .playing: return "playback"
        default: return "connection setup"
        }
    }

    // MARK: Timer: start timeout, keep-alive, stall detection

    private func tick() {
        guard phase != .closed else { return }
        let time = now()
        if !started {
            if time >= deadline { fail(timeoutMessage()) }
            return
        }
        if time - lastMedia > Self.stallTimeout {
            fail("The camera stopped sending video.")
            return
        }
        if time - lastKeepAlive >= max(1, sessionTimeout / 2) {
            lastKeepAlive = time
            // A request with the Session header keeps the session alive. GET_PARAMETER is the usual one;
            // OPTIONS is used if the camera did not list GET_PARAMETER.
            send(method: supportsGetParameter ? "GET_PARAMETER" : "OPTIONS", uri: playURL) { _ in }
        }
    }

    private func timeoutMessage() -> String {
        let seconds = Int(timeout.rounded())
        switch phase {
        case .idle, .connecting:
            let reason = waitingError.map { " (\($0))" } ?? ""
            return "Could not connect to \(hostLabel) within \(seconds) seconds\(reason)."
        case .options, .describe, .setup, .play:
            return "The camera did not answer the RTSP \(phase.rawValue) request within \(seconds) seconds."
        case .playing, .closed:
            if rtpPackets == 0 { return "The camera accepted the request but sent no video data within \(seconds) seconds." }
            if keyframes == 0 { return "Video data is arriving, but the camera sent no keyframe within \(seconds) seconds." }
            let status = decoder.lastErrorStatus
            return status == 0
                ? "Video data is arriving, but no picture could be decoded within \(seconds) seconds."
                : "The video could not be decoded (VideoToolbox error \(status))."
        }
    }

    // MARK: Requests

    private func send(method: String, uri: String, headers: [(String, String)] = [], authRetried: Bool = false,
                      handler: @escaping (RTSPResponse) -> Void) {
        guard let connection, phase != .closed else { return }
        cseq += 1
        pending[cseq] = PendingRequest(method: method, uri: uri, headers: headers, authRetried: authRetried, handler: handler)
        connection.send(content: requestData(method: method, uri: uri, cseq: cseq, headers: headers), completion: .contentProcessed { _ in })
    }

    private func requestData(method: String, uri: String, cseq: Int, headers: [(String, String)]) -> Data {
        var text = "\(method) \(uri) RTSP/1.0\r\nCSeq: \(cseq)\r\nUser-Agent: \(Self.userAgent)\r\n"
        if let sessionID { text += "Session: \(sessionID)\r\n" }
        if let authorization = authorization(method: method, uri: uri) { text += "Authorization: \(authorization)\r\n" }
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }

    private func authorization(method: String, uri: String) -> String? {
        guard let credentials, let challenge else { return nil }
        switch challenge.scheme {
        case .basic:
            return RTSPAuth.basicHeader(user: credentials.user, password: credentials.password)
        case .digest:
            nonceCount += 1
            return RTSPAuth.digestHeader(challenge: challenge, user: credentials.user, password: credentials.password,
                                         method: method, uri: uri, nonceCount: nonceCount, cnonce: RTSPAuth.makeCnonce())
        }
    }

    private func handle(_ response: RTSPResponse) {
        guard let number = response.cseq, let request = pending.removeValue(forKey: number) else { return }
        guard response.status == 401 else {
            request.handler(response)
            return
        }
        guard credentials != nil else {
            fail("The camera asks for a user name and password. Put them in the address: rtsp://user:password@\(hostLabel)/…")
            return
        }
        guard let offered = RTSPAuth.choose(response.headers(named: "WWW-Authenticate")) else {
            fail("The camera asks for a kind of sign-in this client does not support (only Basic and Digest are supported).")
            return
        }
        // A second 401 means the credentials are wrong, unless the camera only says its nonce expired.
        if request.authRetried && !offered.stale {
            fail("The camera rejected the user name or password (401 Unauthorized).")
            return
        }
        challenge = offered
        nonceCount = 0
        send(method: request.method, uri: request.uri, headers: request.headers, authRetried: !offered.stale || request.authRetried,
             handler: request.handler)
    }

    // MARK: RTSP steps

    private func sendOptions() {
        phase = .options
        send(method: "OPTIONS", uri: requestURL) { [weak self] response in
            guard let self else { return }
            // Some cameras answer OPTIONS oddly; only DESCRIBE decides whether the stream exists.
            let methods = response.header("Public")?.uppercased() ?? ""
            self.supportsGetParameter = methods.contains("GET_PARAMETER")
            self.sendDescribe()
        }
    }

    private func sendDescribe() {
        phase = .describe
        send(method: "DESCRIBE", uri: requestURL, headers: [("Accept", "application/sdp")]) { [weak self] response in
            guard let self else { return }
            switch response.status {
            case 200:
                self.handleDescription(response)
            case 404:
                self.fail("The camera has no stream at this address (404 Not Found). Check the path after the host name.")
            case 301, 302, 303, 305:
                let target = response.header("Location").map { " to \($0)" } ?? ""
                self.fail("The camera redirects this address\(target). Redirects are not followed; use the new address.")
            default:
                self.fail("The camera refused the request for the stream description (\(response.status) \(response.reason)).")
            }
        }
    }

    private func handleDescription(_ response: RTSPResponse) {
        let sdp = RTSPSDP.parse(String(decoding: response.body, as: UTF8.self))
        guard let track = sdp.h264Track() else {
            let codecs = sdp.videoCodecs
            if codecs.contains(where: { $0 == "H265" || $0 == "HEVC" }) {
                fail("This stream is H.265 (HEVC), which is not supported. Set the camera to H.264.")
            } else if codecs.isEmpty {
                fail("This stream has no H.264 video track.")
            } else {
                fail("This stream has no H.264 video track (it offers \(codecs.joined(separator: ", "))). Set the camera to H.264.")
            }
            return
        }
        let base = response.header("Content-Base") ?? response.header("Content-Location") ?? requestURL
        let trackURL = RTSPSDP.resolve(control: track.control, base: base)
        playURL = RTSPSDP.resolve(control: sdp.sessionControl, base: base)
        depacketizer.payloadType = track.payloadType
        let clockRate = track.clockRate
        decodeQueue.async { [decoder] in
            decoder.clockRate = Int32(clamping: clockRate)
            for set in track.parameterSets { decoder.setParameterSet(set) }
        }

        phase = .setup
        send(method: "SETUP", uri: trackURL, headers: [("Transport", "RTP/AVP/TCP;unicast;interleaved=0-1")]) { [weak self] response in
            guard let self else { return }
            switch response.status {
            case 200:
                self.handleSetup(response)
            case 461:
                self.fail("This camera only offers UDP for its video, which this client does not support (461 Unsupported Transport). Turn on \"RTSP over TCP\" in the camera if it has that setting.")
            default:
                self.fail("The camera refused to set up the video track (\(response.status) \(response.reason)).")
            }
        }
    }

    private func handleSetup(_ response: RTSPResponse) {
        if let header = response.header("Session") {
            let parts = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            if let id = parts.first, !id.isEmpty { sessionID = id }
            for part in parts.dropFirst() where part.lowercased().hasPrefix("timeout=") {
                if let seconds = TimeInterval(part.dropFirst("timeout=".count)), seconds > 0 { sessionTimeout = seconds }
            }
        }
        if let transport = response.header("Transport")?.lowercased(), let range = transport.range(of: "interleaved=") {
            let digits = transport[range.upperBound...].prefix { $0.isNumber }
            if let channel = UInt8(digits) { rtpChannel = channel }
        }
        phase = .play
        send(method: "PLAY", uri: playURL, headers: [("Range", "npt=0.000-")]) { [weak self] response in
            guard let self else { return }
            guard response.status == 200 else {
                self.fail("The camera refused to start the stream (\(response.status) \(response.reason)).")
                return
            }
            self.phase = .playing
            self.lastKeepAlive = self.now()
        }
    }

    // MARK: Media

    private func handleRTP(_ packet: Data) {
        rtpPackets += 1
        lastMedia = now()
        for unit in depacketizer.push(packet) {
            accessUnits += 1
            if unit.containsKeyframe { keyframes += 1 }
            // If the decoder is behind, drop instead of queueing; decoding then resumes at the next keyframe.
            let accepted: Bool = lock.withLock {
                if backlog >= Self.maxBacklog {
                    dropUntilKeyframe = true
                    return false
                }
                backlog += 1
                return true
            }
            guard accepted else { continue }
            decodeQueue.async { [weak self] in self?.decode(unit) }
        }
    }

    /// On `decodeQueue`.
    private func decode(_ unit: H264AccessUnit) {
        let (waiting, resync, isClosed): (Int, Bool, Bool) = lock.withLock {
            backlog -= 1
            let resync = dropUntilKeyframe
            dropUntilKeyframe = false
            return (backlog, resync, closed)
        }
        guard !isClosed else { return }
        if resync { decoder.needsKeyframe = true }
        // While more units are waiting, this one is decoded (later frames depend on it) but no picture is made.
        guard let image = decoder.decode(unit, skipOutput: waiting > 0) else { return }
        let first: Bool = lock.withLock {
            guard !closed else { return false }
            latest = image
            decodedCount += 1
            return decodedCount == 1
        }
        if first { queue.async { self.firstFrameDecoded() } }
    }

    private func firstFrameDecoded() {
        guard phase != .closed, !started else { return }
        started = true
        lastMedia = now()
        if let completion {
            self.completion = nil
            completion(.success(()))
        }
    }

    // MARK: Ending

    private func fail(_ message: String) {
        guard phase != .closed else { return }
        if let completion {
            self.completion = nil
            completion(.failure(RTSPError(message)))
        } else if started {
            lock.withLock { if failureMessage == nil { failureMessage = message } }
        }
        close(teardown: true)
    }

    private func close(teardown: Bool) {
        guard phase != .closed else { return }
        phase = .closed
        timer?.cancel()
        timer = nil
        pending.removeAll()
        lock.withLock {
            closed = true
            latest = nil
        }
        if let connection {
            self.connection = nil
            connection.stateUpdateHandler = nil
            if teardown, connectionReady, sessionID != nil {
                cseq += 1
                let request = requestData(method: "TEARDOWN", uri: playURL, cseq: cseq, headers: [])
                connection.send(content: request, completion: .contentProcessed { _ in connection.cancel() })
                // In case the camera no longer reads from the connection.
                queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }
            } else {
                connection.cancel()
            }
        }
        decodeQueue.async { [decoder] in decoder.invalidate() }
    }
}

// MARK: - RTSP messages and interleaved framing

struct RTSPResponse {
    var status: Int
    var reason: String
    var headers: [(name: String, value: String)]
    var body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func headers(named name: String) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    var cseq: Int? { header("CSeq").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
}

/// Splits the bytes of an RTSP connection into RTSP messages and interleaved packets (`$`, channel,
/// 16-bit length, data). Data may be fed in pieces of any size.
struct RTSPStreamParser {
    enum Item {
        case interleaved(channel: UInt8, payload: Data)
        case response(RTSPResponse)
        /// A request sent by the server; only its method is kept.
        case request(method: String)
    }

    static let maxHeaderBytes = 64 * 1024
    private var buffer: [UInt8] = []
    /// Bytes thrown away because they were neither a packet nor a message.
    private(set) var skippedBytes = 0

    mutating func append(_ data: Data) -> [Item] {
        buffer.append(contentsOf: data)
        var items: [Item] = []
        var head = 0
        scan: while head < buffer.count {
            let byte = buffer[head]
            let available = buffer.count - head
            if byte == 0x24 {  // "$"
                guard available >= 4 else { break scan }
                let length = Int(buffer[head + 2]) << 8 | Int(buffer[head + 3])
                guard available >= 4 + length else { break scan }
                items.append(.interleaved(channel: buffer[head + 1], payload: Data(buffer[(head + 4)..<(head + 4 + length)])))
                head += 4 + length
            } else if byte == 13 || byte == 10 {
                head += 1
            } else if byte >= 0x41 && byte <= 0x5A {  // A-Z: an RTSP message starts with "RTSP/" or a method name
                let limit = min(buffer.count, head + Self.maxHeaderBytes)
                // The first line must mention RTSP, otherwise this is not a message.
                if let lineEnd = Self.find([13, 10], in: buffer, from: head, to: limit) {
                    if !Self.contains(Array("RTSP/".utf8), in: buffer, from: head, to: lineEnd) {
                        head += 1; skippedBytes += 1
                        continue scan
                    }
                } else if available > 512 {
                    head += 1; skippedBytes += 1
                    continue scan
                } else {
                    break scan
                }
                guard let headerEnd = Self.find([13, 10, 13, 10], in: buffer, from: head, to: limit) else {
                    if available >= Self.maxHeaderBytes {
                        head += 1; skippedBytes += 1
                        continue scan
                    }
                    break scan
                }
                let lines = String(decoding: buffer[head..<headerEnd], as: UTF8.self).components(separatedBy: "\r\n")
                var headers: [(name: String, value: String)] = []
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers.append((String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                                    String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
                }
                let lengthText = headers.first { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }?.value
                let bodyLength = max(0, lengthText.flatMap { Int($0) } ?? 0)
                let bodyStart = headerEnd + 4
                guard buffer.count >= bodyStart + bodyLength else { break scan }
                let first = lines[0].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                if lines[0].hasPrefix("RTSP/") {
                    let status = first.count > 1 ? Int(first[1]) ?? 0 : 0
                    let reason = first.count > 2 ? String(first[2]) : ""
                    items.append(.response(RTSPResponse(status: status, reason: reason, headers: headers,
                                                        body: Data(buffer[bodyStart..<(bodyStart + bodyLength)]))))
                } else {
                    items.append(.request(method: first.first.map(String.init) ?? ""))
                }
                head = bodyStart + bodyLength
            } else {
                head += 1; skippedBytes += 1
            }
        }
        if head > 0 { buffer.removeFirst(head) }
        return items
    }

    private static func find(_ pattern: [UInt8], in bytes: [UInt8], from: Int, to: Int) -> Int? {
        guard to - from >= pattern.count else { return nil }
        var index = from
        while index <= to - pattern.count {
            var matched = true
            for offset in 0..<pattern.count where bytes[index + offset] != pattern[offset] {
                matched = false
                break
            }
            if matched { return index }
            index += 1
        }
        return nil
    }

    private static func contains(_ pattern: [UInt8], in bytes: [UInt8], from: Int, to: Int) -> Bool {
        find(pattern, in: bytes, from: from, to: to) != nil
    }
}

// MARK: - SDP

/// The parts of a session description this client needs.
struct RTSPSDP {
    struct Format: Equatable {
        var encoding: String
        var clockRate: Int
    }

    struct Media {
        var kind: String
        var payloadTypes: [Int]
        var control: String?
        var formats: [Int: Format] = [:]
        var parameters: [Int: [String: String]] = [:]
    }

    struct VideoTrack: Equatable {
        var control: String?
        var payloadType: Int
        var clockRate: Int
        var packetizationMode: Int
        var sps: Data?
        var pps: Data?
        /// Every parameter set listed in `sprop-parameter-sets`, in order.
        var parameterSets: [Data]
    }

    var sessionControl: String?
    var media: [Media] = []

    static func parse(_ text: String) -> RTSPSDP {
        var sdp = RTSPSDP()
        // "\r\n" is a single Character in Swift, so compare with isNewline rather than with "\n".
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                let fields = line.dropFirst(2).split(separator: " ")
                guard let kind = fields.first else { continue }
                sdp.media.append(Media(kind: kind.lowercased(), payloadTypes: fields.dropFirst(3).compactMap { Int($0) }))
            } else if line.hasPrefix("a=") {
                let attribute = line.dropFirst(2)
                let name: Substring, value: Substring
                if let colon = attribute.firstIndex(of: ":") {
                    name = attribute[..<colon]
                    value = attribute[attribute.index(after: colon)...]
                } else {
                    name = attribute
                    value = ""
                }
                switch name.lowercased() {
                case "control":
                    let control = value.trimmingCharacters(in: .whitespaces)
                    if sdp.media.isEmpty { sdp.sessionControl = control } else { sdp.media[sdp.media.count - 1].control = control }
                case "rtpmap":
                    // a=rtpmap:96 H264/90000
                    let fields = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    guard !sdp.media.isEmpty, fields.count == 2, let type = Int(fields[0]) else { continue }
                    let codec = fields[1].split(separator: "/")
                    guard let encoding = codec.first else { continue }
                    let rate = codec.count > 1 ? Int(codec[1].trimmingCharacters(in: .whitespaces)) ?? 90000 : 90000
                    sdp.media[sdp.media.count - 1].formats[type] = Format(encoding: encoding.uppercased(), clockRate: rate)
                case "fmtp":
                    // a=fmtp:96 packetization-mode=1; profile-level-id=42001F; sprop-parameter-sets=Z0..,aM..
                    let fields = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    guard !sdp.media.isEmpty, let type = fields.first.flatMap({ Int($0) }) else { continue }
                    var parameters: [String: String] = [:]
                    if fields.count == 2 {
                        for pair in fields[1].split(separator: ";") {
                            let trimmed = pair.trimmingCharacters(in: .whitespaces)
                            // Split at the first "=" only: base64 values end in "=".
                            guard let equals = trimmed.firstIndex(of: "=") else { continue }
                            parameters[trimmed[..<equals].lowercased()] = String(trimmed[trimmed.index(after: equals)...])
                        }
                    }
                    sdp.media[sdp.media.count - 1].parameters[type] = parameters
                default:
                    break
                }
            }
        }
        return sdp
    }

    /// Names of the video codecs on offer, for error messages.
    var videoCodecs: [String] {
        media.filter { $0.kind == "video" }.flatMap { track in
            track.payloadTypes.compactMap { type in
                track.formats[type]?.encoding ?? (type == 26 ? "JPEG" : type == 32 ? "MPEG" : type == 33 ? "MPEG-TS" : nil)
            }
        }
    }

    /// The first H.264 video track.
    func h264Track() -> VideoTrack? {
        for track in media where track.kind == "video" {
            for type in track.payloadTypes {
                guard let format = track.formats[type], format.encoding == "H264" else { continue }
                let parameters = track.parameters[type] ?? [:]
                var sets: [Data] = []
                for encoded in (parameters["sprop-parameter-sets"] ?? "").split(separator: ",") {
                    if let data = Self.decodeBase64(String(encoded)), !data.isEmpty { sets.append(data) }
                }
                return VideoTrack(control: track.control, payloadType: type, clockRate: format.clockRate,
                                  packetizationMode: parameters["packetization-mode"].flatMap { Int($0) } ?? 0,
                                  sps: sets.first { $0[$0.startIndex] & 0x1F == 7 },
                                  pps: sets.first { $0[$0.startIndex] & 0x1F == 8 },
                                  parameterSets: sets)
            }
        }
        return nil
    }

    private static func decodeBase64(_ text: String) -> Data? {
        var padded = text.trimmingCharacters(in: .whitespaces)
        while padded.count % 4 != 0 { padded.append("=") }
        return Data(base64Encoded: padded)
    }

    /// Turns an `a=control` value into the address to send requests to. The value is an absolute address,
    /// a path relative to `base`, or `*` (or missing), which means `base` itself.
    static func resolve(control: String?, base: String) -> String {
        guard let control = control?.trimmingCharacters(in: .whitespaces), !control.isEmpty, control != "*" else { return base }
        if control.contains("://") { return control }
        if control.hasPrefix("/"), let schemeEnd = base.range(of: "://") {
            // A path from the root of the server.
            let afterScheme = base[schemeEnd.upperBound...]
            let authorityEnd = afterScheme.firstIndex(of: "/") ?? afterScheme.endIndex
            return String(base[..<authorityEnd]) + control
        }
        return base.hasSuffix("/") ? base + control : base + "/" + control
    }
}

// MARK: - Authentication

enum RTSPAuth {
    enum Scheme: Equatable { case basic, digest }

    struct Challenge: Equatable {
        var scheme: Scheme
        var realm = ""
        var nonce = ""
        var opaque: String?
        var qop: [String] = []
        var algorithm: String?
        var stale = false
    }

    /// Parses one `WWW-Authenticate` value.
    static func parseChallenge(_ header: String) -> Challenge? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let schemeEnd = trimmed.firstIndex(of: " ") ?? trimmed.endIndex
        let schemeName = trimmed[..<schemeEnd].lowercased()
        guard schemeName == "basic" || schemeName == "digest" else { return nil }
        var challenge = Challenge(scheme: schemeName == "basic" ? .basic : .digest)
        let parameters = parseParameters(String(trimmed[schemeEnd...]))
        challenge.realm = parameters["realm"] ?? ""
        challenge.nonce = parameters["nonce"] ?? ""
        challenge.opaque = parameters["opaque"]
        challenge.algorithm = parameters["algorithm"]
        challenge.stale = parameters["stale"]?.lowercased() == "true"
        challenge.qop = (parameters["qop"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return challenge
    }

    /// `key=value, key="quoted, value"` pairs; keys are lowercased.
    static func parseParameters(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            while index < characters.count, characters[index] == " " || characters[index] == "," || characters[index] == "\t" { index += 1 }
            var key = ""
            while index < characters.count, characters[index] != "=", characters[index] != "," {
                key.append(characters[index])
                index += 1
            }
            guard index < characters.count, characters[index] == "=" else { continue }
            index += 1
            var value = ""
            if index < characters.count, characters[index] == "\"" {
                index += 1
                while index < characters.count, characters[index] != "\"" {
                    if characters[index] == "\\", index + 1 < characters.count { index += 1 }
                    value.append(characters[index])
                    index += 1
                }
                index += 1
            } else {
                while index < characters.count, characters[index] != "," {
                    value.append(characters[index])
                    index += 1
                }
                value = value.trimmingCharacters(in: .whitespaces)
            }
            result[key.trimmingCharacters(in: .whitespaces).lowercased()] = value
        }
        return result
    }

    private static func isUsable(_ challenge: Challenge) -> Bool {
        guard challenge.scheme == .digest else { return true }
        let algorithm = challenge.algorithm?.uppercased() ?? "MD5"
        return (algorithm == "MD5" || algorithm == "SHA-256") && (challenge.qop.isEmpty || challenge.qop.contains("auth"))
    }

    /// Picks the challenge to answer when the server offers several: Digest MD5, then Digest SHA-256, then Basic.
    static func choose(_ headers: [String]) -> Challenge? {
        let usable = headers.compactMap(parseChallenge).filter(isUsable)
        return usable.first { $0.scheme == .digest && ($0.algorithm?.uppercased() ?? "MD5") == "MD5" }
            ?? usable.first { $0.scheme == .digest }
            ?? usable.first
    }

    static func basicHeader(user: String, password: String) -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    private static func hash(_ text: String, algorithm: String?) -> String {
        let data = Data(text.utf8)
        if algorithm?.uppercased() == "SHA-256" {
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The `response` value of a Digest answer. `qop` is nil for servers that do not send one (RFC 2069 style).
    static func digestResponse(user: String, password: String, realm: String, nonce: String, method: String, uri: String,
                               qop: String? = nil, nonceCount: String = "", cnonce: String = "", algorithm: String? = nil) -> String {
        let ha1 = hash("\(user):\(realm):\(password)", algorithm: algorithm)
        let ha2 = hash("\(method):\(uri)", algorithm: algorithm)
        if let qop {
            return hash("\(ha1):\(nonce):\(nonceCount):\(cnonce):\(qop):\(ha2)", algorithm: algorithm)
        }
        return hash("\(ha1):\(nonce):\(ha2)", algorithm: algorithm)
    }

    static func digestHeader(challenge: Challenge, user: String, password: String, method: String, uri: String,
                             nonceCount: Int, cnonce: String) -> String {
        let qop: String? = challenge.qop.contains("auth") ? "auth" : nil
        let count = String(format: "%08x", nonceCount)
        let response = digestResponse(user: user, password: password, realm: challenge.realm, nonce: challenge.nonce, method: method,
                                      uri: uri, qop: qop, nonceCount: count, cnonce: cnonce, algorithm: challenge.algorithm)
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var header = "Digest username=\(quoted(user)), realm=\(quoted(challenge.realm)), nonce=\(quoted(challenge.nonce)), uri=\(quoted(uri)), response=\"\(response)\""
        if let algorithm = challenge.algorithm { header += ", algorithm=\(algorithm)" }
        if let opaque = challenge.opaque { header += ", opaque=\(quoted(opaque))" }
        if let qop { header += ", qop=\(qop), nc=\(count), cnonce=\(quoted(cnonce))" }
        return header
    }

    static func makeCnonce() -> String {
        (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

// MARK: - RTP H.264 depacketization (RFC 6184)

/// The NAL units of one picture, without start codes or length prefixes.
struct H264AccessUnit: Equatable {
    var nals: [Data]
    var timestamp: UInt32
    /// Packets were lost, so the unit is incomplete and must not be decoded.
    var damaged: Bool

    var containsKeyframe: Bool { nals.contains { !$0.isEmpty && $0[$0.startIndex] & 0x1F == 5 } }
}

/// Collects RTP packets into access units. Handles single NAL units, STAP-A and FU-A.
struct H264Depacketizer {
    /// If set, packets with another payload type are ignored.
    var payloadType: Int?
    private(set) var lostPackets = 0

    private var expectedSequence: UInt16?
    private var nals: [Data] = []
    private var timestamp: UInt32 = 0
    private var damaged = false
    private var fragment: [UInt8]?

    init(payloadType: Int? = nil) {
        self.payloadType = payloadType
    }

    /// Returns the access units completed by this packet (usually none or one).
    mutating func push(_ packet: Data) -> [H264AccessUnit] {
        let bytes = [UInt8](packet)
        guard bytes.count >= 12, bytes[0] >> 6 == 2 else { return [] }
        let marker = bytes[1] & 0x80 != 0
        if let payloadType, Int(bytes[1] & 0x7F) != payloadType { return [] }
        let sequence = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let packetTime = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        var start = 12 + Int(bytes[0] & 0x0F) * 4
        if bytes[0] & 0x10 != 0 {  // header extension
            guard bytes.count >= start + 4 else { return [] }
            start += 4 + (Int(bytes[start + 2]) << 8 | Int(bytes[start + 3])) * 4
        }
        var end = bytes.count
        if bytes[0] & 0x20 != 0, end > start {  // padding
            let padding = Int(bytes[end - 1])
            guard padding > 0, padding <= end - start else { return [] }
            end -= padding
        }
        guard start <= end else { return [] }

        var output: [H264AccessUnit] = []
        func flush(_ nals: inout [Data], _ damaged: inout Bool, time: UInt32) {
            if !nals.isEmpty || damaged { output.append(H264AccessUnit(nals: nals, timestamp: time, damaged: damaged)) }
            nals = []
            damaged = false
        }

        var gap = false
        if let expectedSequence, expectedSequence != sequence {
            gap = true
            lostPackets += Int(sequence &- expectedSequence)
            fragment = nil
            // The picture being collected may have lost its end.
            if !nals.isEmpty { damaged = true }
        }
        expectedSequence = sequence &+ 1

        // A new timestamp starts a new picture even if the marker bit of the last one was missed.
        if packetTime != timestamp {
            flush(&nals, &damaged, time: timestamp)
            fragment = nil
        }
        timestamp = packetTime
        if gap { damaged = true }

        if start < end {
            let header = bytes[start]
            switch header & 0x1F {
            case 1...23:  // single NAL unit
                nals.append(Data(bytes[start..<end]))
                fragment = nil
            case 24:  // STAP-A: several NAL units, each with a 16-bit length
                var index = start + 1
                while index + 2 <= end {
                    let size = Int(bytes[index]) << 8 | Int(bytes[index + 1])
                    index += 2
                    guard size > 0, index + size <= end else {
                        damaged = true
                        break
                    }
                    nals.append(Data(bytes[index..<(index + size)]))
                    index += size
                }
            case 28:  // FU-A: one NAL unit spread over several packets
                guard end - start >= 2 else { break }
                let fragmentHeader = bytes[start + 1]
                if fragmentHeader & 0x80 != 0 {
                    var unit: [UInt8] = [(header & 0xE0) | (fragmentHeader & 0x1F)]
                    unit.append(contentsOf: bytes[(start + 2)..<end])
                    fragment = unit
                } else if fragment != nil {
                    fragment?.append(contentsOf: bytes[(start + 2)..<end])
                } else {
                    damaged = true  // the first fragment was lost
                }
                if fragmentHeader & 0x40 != 0, let unit = fragment {
                    nals.append(Data(unit))
                    fragment = nil
                }
            default:
                break  // STAP-B, MTAP and FU-B belong to the interleaved mode, which cameras do not use.
            }
        }
        if marker {
            flush(&nals, &damaged, time: timestamp)
            fragment = nil
        }
        return output
    }
}

// MARK: - Decoding

/// Decodes access units to pictures. Use from one queue at a time (`lastErrorStatus` may be read from anywhere).
final class H264Decoder: @unchecked Sendable {
    var clockRate: Int32 = 90000
    /// No picture is decoded until a keyframe arrives.
    var needsKeyframe = true

    private var sps: [UInt32: Data] = [:]
    private var pps: [UInt32: Data] = [:]
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private let lock = NSLock()
    private var outputImage: CGImage?
    private var errorStatus: OSStatus = 0

    deinit { invalidate() }

    /// The last VideoToolbox error, 0 if there was none.
    var lastErrorStatus: OSStatus { lock.withLock { errorStatus } }

    /// Size of the video, known once SPS and PPS have been seen.
    var dimensions: (width: Int, height: Int)? {
        guard let format = currentFormat() else { return nil }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        return (Int(size.width), Int(size.height))
    }

    func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    /// Stores an SPS or PPS. If it differs from the one in use, the decoder is rebuilt and waits for a keyframe.
    func setParameterSet(_ nal: Data) {
        guard let first = nal.first else { return }
        let bytes = [UInt8](nal)
        switch first & 0x1F {
        case 7:
            // seq_parameter_set_id follows the header byte and profile, constraint flags and level.
            let id = Self.readExpGolomb(bytes, bitOffset: 32) ?? 0
            guard sps[id] != nal else { return }
            sps[id] = nal
        case 8:
            let id = Self.readExpGolomb(bytes, bitOffset: 8) ?? 0
            guard pps[id] != nal else { return }
            pps[id] = nal
        default:
            return
        }
        format = nil
        invalidate()
        needsKeyframe = true
    }

    /// Reads one unsigned Exp-Golomb number. Good enough for the ids at the start of SPS and PPS.
    static func readExpGolomb(_ bytes: [UInt8], bitOffset: Int) -> UInt32? {
        var position = bitOffset
        func bit() -> UInt32? {
            guard position / 8 < bytes.count else { return nil }
            let value = UInt32(bytes[position / 8] >> (7 - UInt8(position % 8))) & 1
            position += 1
            return value
        }
        var zeros = 0
        while true {
            guard let next = bit() else { return nil }
            if next == 1 { break }
            zeros += 1
            if zeros > 31 { return nil }
        }
        var value: UInt32 = 0
        for _ in 0..<zeros {
            guard let next = bit() else { return nil }
            value = value << 1 | next
        }
        return (UInt32(1) << UInt32(zeros)) - 1 + value
    }

    private func currentFormat() -> CMVideoFormatDescription? {
        if let format { return format }
        guard !sps.isEmpty, !pps.isEmpty else { return nil }
        let sets = sps.keys.sorted().compactMap { sps[$0] } + pps.keys.sorted().compactMap { pps[$0] }
        var blob: [UInt8] = []
        var offsets: [Int] = []
        for set in sets {
            offsets.append(blob.count)
            blob.append(contentsOf: set)
        }
        let sizes = sets.map(\.count)
        var created: CMVideoFormatDescription?
        let status: OSStatus = blob.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return -1 }
            let pointers = offsets.map { base + $0 }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &created)
        }
        if status != noErr { lock.withLock { errorStatus = status } }
        format = created
        return created
    }

    private func currentSession() -> VTDecompressionSession? {
        if let session { return session }
        guard let format = currentFormat() else { return nil }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                                                  imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                                  decompressionSessionOut: &created)
        if status != noErr { lock.withLock { errorStatus = status } }
        if let created { VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
        session = created
        return created
    }

    /// Decodes one access unit. Returns nil if there is no picture: still waiting for a keyframe, the unit
    /// was damaged, decoding failed, or `skipOutput` was set (the unit is then decoded only so that later
    /// ones can refer to it).
    func decode(_ unit: H264AccessUnit, skipOutput: Bool = false) -> CGImage? {
        var isKeyframe = false
        var slices: [Data] = []
        for nal in unit.nals {
            guard let first = nal.first else { continue }
            switch first & 0x1F {
            case 7, 8: setParameterSet(nal)
            case 9: break  // access unit delimiter
            case 5:
                isKeyframe = true
                slices.append(nal)
            default:
                slices.append(nal)
            }
        }
        if unit.damaged {
            needsKeyframe = true
            return nil
        }
        guard slices.contains(where: { (1...5).contains($0[$0.startIndex] & 0x1F) }) else { return nil }
        if needsKeyframe && !isKeyframe { return nil }
        guard let session = currentSession(), let format else { return nil }

        // AVCC form: every NAL unit is preceded by its length as a 32-bit big-endian number.
        var sample = Data(capacity: slices.reduce(0) { $0 + $1.count + 4 })
        for nal in slices {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { sample.append(contentsOf: $0) }
            sample.append(nal)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: sample.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: sample.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        let copied: OSStatus = sample.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(unit.timestamp), timescale: max(1, clockRate)),
                                        decodeTimeStamp: .invalid)
        var size = sample.count
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &buffer) == noErr, let buffer else { return nil }

        // No asynchronous flag: the call returns after the handler has run.
        lock.withLock { outputImage = nil }
        var infoFlags = VTDecodeInfoFlags()
        let flags: VTDecodeFrameFlags = skipOutput ? [._DoNotOutputFrame] : []
        var handlerStatus: OSStatus = noErr
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: buffer, flags: flags, infoFlagsOut: &infoFlags) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            guard status == noErr, let imageBuffer else {
                self.lock.withLock { if status != noErr { handlerStatus = status } }
                return
            }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(imageBuffer, options: nil, imageOut: &image)
            self.lock.withLock { self.outputImage = image }
        }
        let failed: OSStatus = lock.withLock { status != noErr ? status : handlerStatus }
        if failed != noErr {
            lock.withLock { errorStatus = failed }
            needsKeyframe = true
            // The session becomes invalid when an iPad app goes to the background; build a new one next time.
            if failed == kVTInvalidSessionErr { invalidate() }
            return nil
        }
        needsKeyframe = false
        return lock.withLock {
            let image = outputImage
            outputImage = nil
            return skipOutput ? nil : image
        }
    }
}
