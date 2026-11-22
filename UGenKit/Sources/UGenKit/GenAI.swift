import CoreGraphics
import CUGenRT
import Foundation

// Client for the GenAI services of HailoRT 5.3.0 on the stick: speech to text (Whisper), chat (LLM) and
// questions about images (VLM). Ported from hailo-ai/hailort v5.3.0, libhailort/src/genai and
// common/genai. The message encoding is in GenAIProtocol.swift.
//
// Each service listens on its own port and speaks a simpler protocol than the vision service: every
// buffer is sent as an 8-byte little-endian size followed by the bytes, a request is one or more
// buffers, and the reply is one buffer. The stick gives this process one session at a time, so creating
// a GenAI model closes the vision session (releasing its models) and any other GenAI model, and using
// the vision API again closes the GenAI model.

// MARK: - Framing

extension UGenDevice {
    /// Largest piece handed to one `ugen_session_write` call (the reference sends files in pieces of
    /// this size too). The C core cuts it further into USB transfers of at most 1 MB.
    static let genaiPieceSize = 64 << 20
    /// A reply larger than this is taken as a sign that the stream is out of step.
    static let genaiMaxReplySize: UInt64 = 256 << 20
    /// How long the server may take to answer a create request. It waits up to two minutes for parts
    /// of the model by itself before giving up.
    static let genaiCreateTimeout: Duration = .seconds(300)
    /// How long one token may take (`LONG_TIMEOUT` in the reference).
    static let genaiTokenTimeout: Duration = .seconds(120)

    /// Throws unless `id` is the GenAI session that is open now.
    func genaiRequire(_ id: Int) throws {
        guard genaiPort != nil, genaiSessionID == id else {
            throw UGenError.invalidInput("This GenAI model is no longer on the stick: it was released, or the stick was used for something else.")
        }
    }

    /// Closes the GenAI session if it is still the one with this id.
    func genaiClose(_ id: Int) {
        if genaiPort != nil, genaiSessionID == id { closeGenAISession() }
    }

    /// Maps a result of the C session calls. After a failure the position in the stream is unknown, so
    /// the session is closed.
    private func genaiCheck(_ step: String, _ status: Int32) throws {
        guard status != Int32(UGEN_OK) else { return }
        let transportError = genaiSession.last_transport_error
        closeGenAISession()
        if status == Int32(UGEN_ERR_TRANSPORT) { throw UGenError.usbTransfer(step: step, code: transportError) }
        if status >= 0x10000 { throw UGenError.client(step: step, code: status) }
        throw UGenError.deviceStatus(step: step, status: status)
    }

    private func genaiWriteRaw(_ data: Data, step: String) throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + Self.genaiPieceSize, data.endIndex)
            let status = data[offset..<end].withUnsafeBytes { bytes in
                ugen_session_write(&genaiSession, bytes.baseAddress, UInt32(bytes.count))
            }
            try genaiCheck(step, status)
            offset = end
        }
    }

    private func genaiReadRaw(_ count: Int, step: String) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            ugen_session_read(&genaiSession, bytes.baseAddress, UInt32(bytes.count))
        }
        try genaiCheck(step, status)
        return data
    }

    /// One buffer: its size as 8 bytes, little-endian, then the bytes. An empty buffer is the size alone.
    private func genaiWriteBuffer(_ data: Data, step: String) throws {
        var size = Data()
        withUnsafeBytes(of: UInt64(data.count).littleEndian) { size.append(contentsOf: $0) }
        try genaiWriteRaw(size, step: step)
        try genaiWriteRaw(data, step: step)
    }

    private func genaiReadBuffer(step: String) throws -> Data {
        let header = try genaiReadRaw(8, step: step)
        let size = header.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard size <= Self.genaiMaxReplySize else {
            closeGenAISession()
            throw UGenError.client(step: step, code: Int32(UGEN_ERR_PROTOCOL))
        }
        return try genaiReadRaw(Int(size), step: step)
    }

    private func genaiSetTimeout(_ timeout: Duration?) {
        guard let timeout else { return }
        let milliseconds = timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000
        ugen_driver_set_bulk_timeout(UInt32(clamping: max(1, milliseconds)))
    }

    /// Sends the buffers of one request and reads the reply (`SessionWrapper::execute`).
    /// - Parameter timeout: How long each USB transfer may take; nil keeps the transport's default (60 s).
    func genaiExecute(_ id: Int, step: String, _ buffers: [Data], timeout: Duration? = nil) throws -> Data {
        try genaiRequire(id)
        genaiSetTimeout(timeout)
        defer { ugen_driver_set_bulk_timeout(0) }
        for buffer in buffers { try genaiWriteBuffer(buffer, step: step) }
        return try genaiReadBuffer(step: step)
    }

    /// Sends a create request followed by the parts of a HEF, and reads the reply. This is how the LLM
    /// and VLM servers take a model (`SessionWrapper::send_file_chunked`): after the request buffer,
    /// each part goes as bare bytes with no size in front, and the server answers every part with one
    /// byte, 1, once it has all of it. The reply buffer comes after the last part.
    func genaiCreate(_ id: Int, step: String, request: Data, hef: Data, chunks: [HEFChunk]) throws -> Data {
        try genaiRequire(id)
        genaiSetTimeout(Self.genaiCreateTimeout)
        defer { ugen_driver_set_bulk_timeout(0) }
        try genaiWriteBuffer(request, step: step)
        for chunk in chunks {
            let start = hef.startIndex + Int(chunk.offset)
            try genaiWriteRaw(hef[start..<start + Int(chunk.size)], step: "\(step) (send \(chunk.name))")
            let acknowledgement = try genaiReadRaw(1, step: "\(step) (send \(chunk.name))")
            guard acknowledgement.first == 1 else {
                closeGenAISession()
                throw UGenError.client(step: "\(step) (send \(chunk.name))", code: Int32(UGEN_ERR_PROTOCOL))
            }
        }
        return try genaiReadBuffer(step: step)
    }
}

// MARK: - Shared types

/// Sampling settings for a chat or image-question generation (`LLMGeneratorParams`). Start from the
/// model's `defaultParameters`, which the device reports from the model file, and change what you need.
public struct GenerationParameters: Sendable, Equatable {
    /// `seed` value that makes the device pick a new random seed for every generation.
    public static let randomSeed = UInt32.max

    /// Must be above 0. Higher values give more varied text.
    public var temperature: Float
    /// 0...1: only the most likely tokens whose probabilities add up to this are considered.
    public var topP: Float
    /// At least 1: only this many of the most likely tokens are considered.
    public var topK: UInt32
    /// Must not be 0. Values above 1 discourage repeating tokens; 1 changes nothing.
    public var frequencyPenalty: Float
    /// Where generation stops if the model does not end by itself. The prompt does not count.
    public var maxGeneratedTokens: UInt32
    /// false always takes the most likely token (temperature, topP and topK are then unused).
    public var doSample: Bool
    public var seed: UInt32

    public init(temperature: Float, topP: Float, topK: UInt32, frequencyPenalty: Float, maxGeneratedTokens: UInt32,
                doSample: Bool, seed: UInt32 = GenerationParameters.randomSeed) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.frequencyPenalty = frequencyPenalty
        self.maxGeneratedTokens = maxGeneratedTokens
        self.doSample = doSample
        self.seed = seed
    }

    /// The checks the reference client makes before it sends the parameters.
    func validate() throws {
        guard temperature > 0 else { throw UGenError.invalidInput("Temperature must be above 0.") }
        guard (0...1).contains(topP) else { throw UGenError.invalidInput("Top-p must be between 0 and 1.") }
        guard topK >= 1 else { throw UGenError.invalidInput("Top-k must be at least 1.") }
        guard frequencyPenalty != 0 else { throw UGenError.invalidInput("The frequency penalty must not be 0.") }
    }
}

/// One turn of a conversation.
public struct ChatMessage: Sendable, Equatable {
    public enum Part: Sendable, Equatable {
        case text(String)
        /// Stands for one image. The pixels are passed separately, in the order the images appear.
        case image
    }

    /// "system", "user" or "assistant".
    public var role: String
    public var parts: [Part]

    public init(role: String, content: String) {
        self.role = role
        parts = [.text(content)]
    }

    public init(role: String, parts: [Part]) {
        self.role = role
        self.parts = parts
    }

    public static func system(_ text: String) -> ChatMessage { ChatMessage(role: "system", content: text) }
    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: "user", content: text) }
    public static func assistant(_ text: String) -> ChatMessage { ChatMessage(role: "assistant", content: text) }

    /// A user turn with `images` images in front of the text, for `VisionChatModel`.
    public static func user(_ text: String, images: Int) -> ChatMessage {
        ChatMessage(role: "user", parts: Array(repeating: .image, count: images) + [.text(text)])
    }

    var imageCount: Int { parts.filter { $0 == .image }.count }
}

/// Why a generation stopped.
public enum GenerationEnd: Sendable, Equatable {
    /// `maxGeneratedTokens` was reached.
    case maxTokens
    /// The model ended its answer.
    case endOfText
    /// The generation was cancelled.
    case aborted
}

// MARK: - Speech to text

public enum SpeechTask: UInt32, Sendable {
    /// Write down what is said, in the language it is said in.
    case transcribe = 0
    /// Write down what is said, translated to English.
    case translate = 1
}

/// Speech to text with a Whisper model on the stick (for example Whisper-Base.hef).
///
/// Audio format: mono PCM, 32-bit float samples in -1.0..<1.0, at 16 000 samples per second
/// (`SpeechToText.sampleRate`). The samples go to the device as they are in memory, little-endian.
/// Stereo, integer or other-rate audio has to be converted first. The device cuts long audio into
/// chunks by itself (30 seconds each for Whisper).
///
/// ```swift
/// let speech = try await SpeechToText(hef: whisperURL, device: device)
/// let segments = try await speech.transcribe(samples: samples, language: "en")
/// print(segments.text)
/// await speech.release()
/// ```
/// Creating it closes the vision session and any other GenAI model on `device`.
public actor SpeechToText {
    /// A stretch of the audio and what was said in it.
    public struct Segment: Sendable, Equatable {
        /// Seconds from the start of the audio.
        public let start: Double
        public let end: Double
        public let text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// Samples per second the model needs.
    public static let sampleRate = 16_000

    /// The model's own setting, used when `transcribe` is not given one. 1 means no penalty.
    public nonisolated let defaultRepetitionPenalty: Float

    private let device: UGenDevice
    private let session: Int
    private var released = false

    /// Uploads the model and gets it ready. The whole file goes over USB, which takes a while.
    public init(hef: URL, device: UGenDevice) async throws {
        // Mapped, not read: the file is paged in piece by piece as it is sent.
        let model = try Data(contentsOf: hef, options: .alwaysMapped)
        guard !model.isEmpty else { throw UGenError.invalidInput("The HEF is empty.") }
        let session = try await device.openGenAISession(port: UInt32(UGEN_SPEECH_TO_TEXT_PORT))
        do {
            // The request, then the whole HEF as a second buffer.
            let step = "create speech-to-text"
            let reply = try await device.genaiExecute(session, step: step, [GenAIRequest.speechCreate(), model],
                                                      timeout: UGenDevice.genaiCreateTimeout)
            defaultRepetitionPenalty = try GenAIReply.speechCreate(reply, step: step).repetitionPenalty
        } catch {
            await device.genaiClose(session)
            throw error
        }
        self.device = device
        self.session = session
    }

    /// Turns speech into text.
    /// - Parameters:
    ///   - samples: Mono 16 kHz audio as floats in -1.0..<1.0 (see the type's description).
    ///   - task: `.translate` gives English text whatever the spoken language.
    ///   - language: Two-letter code such as "en" or "de". nil lets the model detect it from the start of the audio.
    ///   - repetitionPenalty: Above 0; nil uses the model's default.
    ///   - timeout: How long to wait for the answer, which comes all at once when the device is done.
    /// - Returns: The segments in order. Their texts joined give the whole transcript (`segments.text`).
    public func transcribe(samples: [Float], task: SpeechTask = .transcribe, language: String? = nil,
                           repetitionPenalty: Float? = nil, timeout: Duration = .seconds(120)) async throws -> [Segment] {
        guard !released else { throw UGenError.noModelLoaded }
        guard !samples.isEmpty else { throw UGenError.invalidInput("There is no audio.") }
        let penalty = repetitionPenalty ?? defaultRepetitionPenalty
        guard penalty > 0 else { throw UGenError.invalidInput("The repetition penalty must be above 0.") }

        let request = GenAIRequest.speechGenerate(task: task.rawValue, language: language ?? "", repetitionPenalty: penalty)
        let audio = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let step = "speech to text"
        let reply = try await device.genaiExecute(session, step: step, [request, audio], timeout: timeout)
        return try GenAIReply.speechGenerate(reply, step: step)
    }

    /// The model's token ids for a piece of text.
    public func tokenize(_ text: String) async throws -> [Int32] {
        guard !released else { throw UGenError.noModelLoaded }
        let step = "tokenize"
        return try GenAIReply.speechTokenize(try await device.genaiExecute(session, step: step, [GenAIRequest.speechTokenize(text)]), step: step)
    }

    /// Frees the model on the stick. The object cannot be used afterwards. `UGenDevice.disconnect()`
    /// frees it as well.
    public func release() async {
        guard !released else { return }
        released = true
        // The server drops its state on this request and cannot take another, so the session goes too.
        _ = try? await device.genaiExecute(session, step: "release speech-to-text", [GenAIRequest.empty(.speechRelease)])
        await device.genaiClose(session)
    }
}

extension Array where Element == SpeechToText.Segment {
    /// The whole transcript.
    public var text: String {
        map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Chat and image questions

/// What the LLM and the VLM clients share: the VLM server takes the LLM's requests for everything but
/// creating the model and starting a generation.
actor GenAITextModel {
    enum Kind {
        case llm, vlm
    }

    enum Input: Sendable {
        case messages([ChatMessage])
        case prompt(String)
    }

    nonisolated let kind: Kind
    nonisolated let defaults: GenerationParameters
    nonisolated let promptTemplate: String
    /// What the VLM server said about its image input; nil for the LLM.
    nonisolated let frame: GenAIReply.VLMCreate?

    private let device: UGenDevice
    private let session: Int
    private var template: PromptTemplateHandler?
    private var templateProblem: String?
    private var recoverySequence: String
    private var generating = false
    private var released = false
    private(set) var lastEnd: GenerationEnd?
    private(set) var contextIsFull = false

    private init(kind: Kind, device: UGenDevice, session: Int, defaults: GenerationParameters, promptTemplate: String,
                 frame: GenAIReply.VLMCreate?, recoverySequence: String) {
        self.kind = kind
        self.device = device
        self.session = session
        self.defaults = defaults
        self.promptTemplate = promptTemplate
        self.frame = frame
        self.recoverySequence = recoverySequence
        if promptTemplate.isEmpty {
            templateProblem = "This model has no chat template; pass the prompt as text."
        } else {
            do {
                template = try PromptTemplateHandler(source: promptTemplate)
            } catch {
                templateProblem = "This model's chat template cannot be used (\(error)); pass the prompt as text."
            }
        }
    }

    /// Uploads the HEF and creates the model on the stick.
    static func create(kind: Kind, hef: URL, device: UGenDevice) async throws -> GenAITextModel {
        // Mapped, not read: these files run to several gigabytes and are paged in piece by piece as
        // they are sent. Sizes and offsets are 64-bit throughout; one write call takes at most 64 MB.
        let model = try Data(contentsOf: hef, options: .alwaysMapped)
        let plan = try HEFTransferPlan(hef: model)
        let name = kind == .llm ? "LLM" : "VLM"
        let session = try await device.openGenAISession(port: UInt32(kind == .llm ? UGEN_LLM_PORT : UGEN_VLM_PORT))
        do {
            func execute(_ step: String, _ request: Data) async throws -> Data {
                try await device.genaiExecute(session, step: step, [request])
            }
            // The order of the reference client: take the device's one KV cache, ask whether the device
            // already has this file (at the same path, with the same hash), then create the model.
            var step = "acquire KV cache"
            try GenAIReply.status(try await execute(step, GenAIRequest.empty(.llmAcquireKVCache)), .llmAcquireKVCache, step: step)

            let path = hef.standardizedFileURL.path
            step = "check for the HEF on the device"
            let onDevice = try GenAIReply.hefExists(try await execute(step, GenAIRequest.checkHefExists(path: path, hash: plan.hash)), step: step)

            step = "create \(name)"
            let request: Data
            switch (kind, onDevice) {
            case (.llm, true): request = GenAIRequest.llmCreate(hefPath: path)
            case (.llm, false): request = GenAIRequest.llmCreate(chunks: plan.chunks, totalSize: plan.totalSize)
            case (.vlm, true): request = GenAIRequest.vlmCreate(hefPath: path)
            case (.vlm, false): request = GenAIRequest.vlmCreate(chunks: plan.chunks, totalSize: plan.totalSize)
            }
            let reply = onDevice
                ? try await device.genaiExecute(session, step: step, [request], timeout: UGenDevice.genaiCreateTimeout)
                : try await device.genaiCreate(session, step: step, request: request, hef: model, chunks: plan.chunks)
            let source: String
            var frame: GenAIReply.VLMCreate?
            if kind == .llm {
                source = try GenAIReply.llmCreate(reply, step: step).promptTemplate
            } else {
                let created = try GenAIReply.vlmCreate(reply, step: step)
                source = created.promptTemplate
                frame = created
            }

            step = "get generation defaults"
            let defaults = try GenAIReply.generatorParams(try await execute(step, GenAIRequest.empty(.llmGetGeneratorParams)), step: step)

            // Not part of creating the model in the reference, which asks for this on demand.
            step = "get recovery sequence"
            let recovery = try GenAIReply.endOfGenerationSequence(
                try await execute(step, GenAIRequest.empty(.llmGetEndOfGenerationSequence)), step: step).text

            return GenAITextModel(kind: kind, device: device, session: session, defaults: defaults, promptTemplate: source,
                                  frame: frame, recoverySequence: recovery)
        } catch {
            await device.genaiClose(session)
            throw error
        }
    }

    private func execute(_ step: String, _ request: Data, _ extra: [Data] = [], timeout: Duration? = nil) async throws -> Data {
        guard !released else { throw UGenError.noModelLoaded }
        return try await device.genaiExecute(session, step: step, [request] + extra, timeout: timeout)
    }

    private func requireIdle() throws {
        guard !generating else { throw UGenError.invalidInput("A generation is in progress.") }
    }

    // MARK: Generation

    nonisolated func generate(_ input: Input, frames: [[UInt8]], parameters: GenerationParameters?,
                              hiding: Set<String>?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(input, frames: frames, parameters: parameters ?? self.defaults, hiding: hiding, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ input: Input, frames: [[UInt8]], parameters: GenerationParameters, hiding: Set<String>?,
                     _ continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        guard !released else { throw UGenError.noModelLoaded }
        try requireIdle()
        try parameters.validate()
        if let frame {
            let size = VisionChatModel.frameSize(frame)
            for bytes in frames where bytes.count != size {
                throw UGenError.invalidInput("An image is \(bytes.count) bytes; the model needs \(size).")
            }
            if case .messages(let messages) = input {
                let placeholders = messages.reduce(0) { $0 + $1.imageCount }
                guard placeholders == frames.count else {
                    throw UGenError.invalidInput("The messages mention \(placeholders) image(s) but \(frames.count) were passed.")
                }
            }
        }
        generating = true
        defer { generating = false }
        lastEnd = nil

        var step = "create generator"
        try GenAIReply.status(try await execute(step, GenAIRequest.generatorCreate(parameters)), .llmGeneratorCreate, step: step)

        // The prompt is built here, on the client; the server only ever sees the finished text.
        var prompt: String
        switch input {
        case .prompt(let text): prompt = text
        case .messages(let messages):
            guard template != nil else { throw UGenError.invalidInput(templateProblem ?? "This model has no chat template.") }
            prompt = try template!.render(messages)
        }
        guard !prompt.isEmpty else { throw UGenError.invalidInput("The prompt is empty.") }

        var tokens: [UInt32] = []
        if kind == .llm {
            // The write request carries nothing in 5.3.0; the prompt goes with the first read.
            step = "write prompt"
            try GenAIReply.status(try await execute(step, GenAIRequest.empty(.llmGeneratorWrite)), .llmGeneratorWrite, step: step)
            step = "start generation"
            tokens = try GenAIReply.generatorGenerate(try await execute(step, GenAIRequest.empty(.llmGeneratorGenerate)), step: step)
        } else {
            // The images go with the request, one buffer each; the server runs its image encoder on them.
            step = "start generation"
            let request = GenAIRequest.vlmGenerate(frames: frames.count)
            try GenAIReply.status(try await execute(step, request, frames.map { Data($0) }, timeout: UGenDevice.genaiTokenTimeout),
                                  .vlmGeneratorGenerate, step: step)
        }

        // One request per token. The first carries the prompt (and the tokens the server handed out);
        // each later one hands back the token the server just produced. The server says when it is done.
        let hidden = hiding ?? Self.endMarkers.union(recoverySequence.isEmpty ? [] : [recoverySequence])
        step = "read token"
        var abortSent = false
        while true {
            let reply = try GenAIReply.generatorRead(
                try await execute(step, GenAIRequest.generatorRead(prompt: prompt, tokens: tokens), timeout: UGenDevice.genaiTokenTimeout),
                step: step)
            if reply.isContextFull { contextIsFull = true }
            if !reply.text.isEmpty, !hidden.contains(reply.text) { continuation.yield(reply.text) }
            switch reply.status {
            case .generating: break
            case .maxTokensReached: lastEnd = .maxTokens
            case .logicalEnd: lastEnd = .endOfText
            case .aborted: lastEnd = .aborted
            }
            if reply.status != .generating { break }
            prompt = ""
            tokens = [reply.tokenID]
            // After an abort the server still hands out its recovery sequence, ending with "aborted".
            if Task.isCancelled, !abortSent {
                abortSent = true
                try GenAIReply.status(try await execute("abort", GenAIRequest.empty(.llmGeneratorAbort)), .llmGeneratorAbort, step: "abort")
            }
        }

        if kind == .llm {
            step = "release generator"
            try GenAIReply.status(try await execute(step, GenAIRequest.empty(.llmGeneratorRelease)), .llmGeneratorRelease, step: step)
        }
    }

    /// Pieces that mark the end of a turn rather than being part of the answer.
    static let endMarkers: Set<String> = ["<|im_end|>", "<|endoftext|>"]

    // MARK: Other requests

    func clearContext() async throws {
        try requireIdle()
        let step = "clear context"
        try GenAIReply.status(try await execute(step, GenAIRequest.empty(.llmClearContext)), .llmClearContext, step: step)
        template?.reset()
        contextIsFull = false
    }

    func tokenize(_ text: String) async throws -> [Int32] {
        try requireIdle()
        let step = "tokenize"
        return try GenAIReply.llmTokenize(try await execute(step, GenAIRequest.llmTokenize(text)), step: step)
    }

    func contextUsage() async throws -> Int {
        try requireIdle()
        let step = "get context usage"
        return try GenAIReply.count(try await execute(step, GenAIRequest.empty(.llmGetContextUsageSize)), .llmGetContextUsageSize, step: step)
    }

    func maxContextCapacity() async throws -> Int {
        try requireIdle()
        let step = "get context capacity"
        return try GenAIReply.count(try await execute(step, GenAIRequest.empty(.llmGetMaxContextCapacity)), .llmGetMaxContextCapacity, step: step)
    }

    func stopTokens() async throws -> [String] {
        try requireIdle()
        let step = "get stop tokens"
        return try GenAIReply.stopTokens(try await execute(step, GenAIRequest.empty(.llmGetStopTokens)), step: step).texts
    }

    func setStopTokens(_ texts: [String]) async throws {
        var sequences: [[Int32]] = []
        for text in texts {
            let tokens = try await tokenize(text)
            if !tokens.isEmpty { sequences.append(tokens) }
        }
        let step = "set stop tokens"
        try GenAIReply.status(try await execute(step, GenAIRequest.setStopTokens(sequences)), .llmSetStopTokens, step: step)
    }

    func currentRecoverySequence() async throws -> String {
        try requireIdle()
        let step = "get recovery sequence"
        recoverySequence = try GenAIReply.endOfGenerationSequence(
            try await execute(step, GenAIRequest.empty(.llmGetEndOfGenerationSequence)), step: step).text
        return recoverySequence
    }

    func setRecoverySequence(_ text: String) async throws {
        let tokens = try await tokenize(text)
        let step = "set recovery sequence"
        try GenAIReply.status(try await execute(step, GenAIRequest.setEndOfGenerationSequence(tokens: tokens)),
                              .llmSetEndOfGenerationSequence, step: step)
        recoverySequence = text
    }

    func release() async {
        guard !released else { return }
        // The server drops its state on this request and cannot take another, so the session goes too.
        _ = try? await execute("release", GenAIRequest.empty(.llmRelease))
        released = true
        await device.genaiClose(session)
    }
}

/// Chat with a language model on the stick (for example Qwen2.5-1.5B-Instruct.hef).
///
/// ```swift
/// let chat = try await ChatModel(hef: qwenURL, device: device)
/// var parameters = chat.defaultParameters
/// parameters.temperature = 0.7
/// parameters.maxGeneratedTokens = 256
/// try await chat.clearContext()
/// for try await piece in chat.generate(messages: [.system("You are a helpful assistant."), .user("Hello!")],
///                                      parameters: parameters) {
///     print(piece, terminator: "")
/// }
/// await chat.release()
/// ```
///
/// The stick remembers the conversation. After `clearContext()` (or right after creation) the messages
/// may start with a system message and should hold the whole conversation so far. Without clearing,
/// pass only the new turns: they are added to what the stick already has, and a system message is
/// refused. To do what the web app does, call `clearContext()` and pass the whole history every time.
///
/// Creating it closes the vision session and any other GenAI model on `device`. One generation runs at
/// a time. Call `release()` when done; `UGenDevice.disconnect()` frees the model as well.
public final class ChatModel: Sendable {
    let core: GenAITextModel

    /// Uploads the model and gets it ready. The file is sent in parts over USB, which takes a while for
    /// a model of a gigabyte or more.
    public init(hef: URL, device: UGenDevice) async throws {
        core = try await GenAITextModel.create(kind: .llm, hef: hef, device: device)
    }

    /// The settings the model file asks for.
    public var defaultParameters: GenerationParameters { core.defaults }

    /// The model's Jinja chat template, or "" if it has none.
    public var promptTemplate: String { core.promptTemplate }

    /// Starts an answer to `messages` and delivers it piece by piece (roughly a token at a time). The
    /// stream ends when the model is done or `maxGeneratedTokens` is reached; `lastGenerationEnd` then
    /// says which. Stopping the iteration early, or cancelling the task that iterates, aborts the
    /// generation on the stick.
    /// - Parameters:
    ///   - parameters: nil uses `defaultParameters`.
    ///   - hiding: Pieces to leave out. nil leaves out the end-of-turn markers ("<|im_end|>",
    ///     "<|endoftext|>" and the model's recovery sequence); pass an empty set to get everything.
    public func generate(messages: [ChatMessage], parameters: GenerationParameters? = nil,
                         hiding: Set<String>? = nil) -> AsyncThrowingStream<String, Error> {
        core.generate(.messages(messages), frames: [], parameters: parameters, hiding: hiding)
    }

    /// The same for a prompt that is already complete, with the model's special tokens written out. The
    /// chat template is not applied.
    public func generate(prompt: String, parameters: GenerationParameters? = nil,
                         hiding: Set<String>? = nil) -> AsyncThrowingStream<String, Error> {
        core.generate(.prompt(prompt), frames: [], parameters: parameters, hiding: hiding)
    }

    /// Why the last generation stopped; nil while one runs or if it failed.
    public var lastGenerationEnd: GenerationEnd? { get async { await core.lastEnd } }

    /// Whether the stick reported during a generation that its conversation memory is full. Clear the
    /// context when it is.
    public var isContextFull: Bool { get async { await core.contextIsFull } }

    /// Makes the stick forget the conversation.
    public func clearContext() async throws { try await core.clearContext() }

    /// The model's token ids for a piece of text.
    public func tokenize(_ text: String) async throws -> [Int32] { try await core.tokenize(text) }

    /// Tokens the conversation takes up on the stick, and how many fit.
    public func contextUsage() async throws -> Int { try await core.contextUsage() }
    public func maxContextCapacity() async throws -> Int { try await core.maxContextCapacity() }

    /// Texts that end a generation when the model produces them.
    public func stopTokens() async throws -> [String] { try await core.stopTokens() }
    public func setStopTokens(_ texts: [String]) async throws { try await core.setStopTokens(texts) }

    /// The text the stick adds to its conversation memory when a generation is cut short (by the token
    /// limit or an abort), so that the next turn starts cleanly.
    public func recoverySequence() async throws -> String { try await core.currentRecoverySequence() }
    public func setRecoverySequence(_ text: String) async throws { try await core.setRecoverySequence(text) }

    /// Frees the model on the stick. The object cannot be used afterwards.
    public func release() async { await core.release() }
}

/// Questions about images with a vision-language model on the stick (for example Qwen2-VL-2B-Instruct.hef).
///
/// The model takes images of one fixed size, which the stick reports when the model is created:
/// `frameWidth` x `frameHeight` pixels with `frameChannels` values each. `prepareFrame(_:)` scales an
/// image to that size (stretching it, as the web app does) and lays the pixels out as the model wants.
///
/// ```swift
/// let vision = try await VisionChatModel(hef: qwenVLURL, device: device)
/// try await vision.clearContext()
/// let frame = try vision.prepareFrame(cgImage)
/// let messages: [ChatMessage] = [
///     .system("You are a helpful assistant that analyzes images and answers questions about them."),
///     .user("What is in this picture?", images: 1),
/// ]
/// for try await piece in vision.generate(messages: messages, frames: [frame]) { print(piece, terminator: "") }
/// ```
/// Everything said about the conversation memory for `ChatModel` holds here too.
public final class VisionChatModel: Sendable {
    let core: GenAITextModel
    private let frame: GenAIReply.VLMCreate

    public init(hef: URL, device: UGenDevice) async throws {
        core = try await GenAITextModel.create(kind: .vlm, hef: hef, device: device)
        // The VLM create reply always carries the frame description.
        frame = core.frame ?? GenAIReply.VLMCreate(formatOrder: 0, formatType: 0, height: 0, width: 0, features: 0, promptTemplate: "",
                                                   embeddingFeatures: 0, imagePadTokenID: 0, videoPadTokenID: 0, embeddingsPerFrame: 0)
    }

    public var frameWidth: Int { Int(frame.width) }
    public var frameHeight: Int { Int(frame.height) }
    /// Values per pixel (3 for RGB).
    public var frameChannels: Int { Int(frame.features) }
    /// `hailo_format_order_t` of the image input: 1 is NHWC (rows of interleaved RGB pixels).
    public var frameFormatOrder: UInt32 { frame.formatOrder }
    /// `hailo_format_type_t` of the image input: 1 is one byte per value.
    public var frameFormatType: UInt32 { frame.formatType }
    /// Bytes in one image as the model takes it.
    public var frameSize: Int { Self.frameSize(frame) }

    public var defaultParameters: GenerationParameters { core.defaults }
    public var promptTemplate: String { core.promptTemplate }

    static func frameSize(_ frame: GenAIReply.VLMCreate) -> Int {
        let bytesPerValue: Int
        switch frame.formatType {
        case UInt32(UGEN_FORMAT_TYPE_UINT16): bytesPerValue = 2
        case UInt32(UGEN_FORMAT_TYPE_FLOAT32): bytesPerValue = 4
        default: bytesPerValue = 1
        }
        return Int(frame.height) * Int(frame.width) * Int(frame.features) * bytesPerValue
    }

    /// Scales `image` to the model's input size, ignoring its aspect ratio, and returns the bytes to
    /// pass to `generate`. Works for models that take 8-bit RGB, which is what Hailo's VLMs do.
    public func prepareFrame(_ image: CGImage) throws -> [UInt8] {
        // hailo_format_order_t: 0 auto, 1 NHWC, 3 FCR, 10 RGB888 are rows of interleaved pixels; 11 NCHW is one plane per channel.
        let interleaved: Set<UInt32> = [0, 1, 3, 10]
        guard frame.features == 3, frame.formatType <= UInt32(UGEN_FORMAT_TYPE_UINT8),
              interleaved.contains(frame.formatOrder) || frame.formatOrder == 11 else {
            throw UGenError.invalidInput("This model's image input (\(frame.features) channels, format order \(frame.formatOrder), "
                + "type \(frame.formatType)) is not 8-bit RGB; prepare the \(frameSize) bytes yourself.")
        }
        let rgb = try ImagePrep.prepare(image, width: frameWidth, height: frameHeight, mode: .stretch).rgb
        guard frame.formatOrder == 11 else { return rgb }
        let pixels = frameWidth * frameHeight
        var planar = [UInt8](repeating: 0, count: rgb.count)
        for pixel in 0..<pixels {
            for channel in 0..<3 { planar[channel * pixels + pixel] = rgb[pixel * 3 + channel] }
        }
        return planar
    }

    /// Starts an answer to `messages` about the images in `frames` and delivers it piece by piece, as
    /// `ChatModel.generate` does.
    /// - Parameter frames: One entry of `frameSize` bytes per `.image` part in the messages, in order.
    public func generate(messages: [ChatMessage], frames: [[UInt8]], parameters: GenerationParameters? = nil,
                         hiding: Set<String>? = nil) -> AsyncThrowingStream<String, Error> {
        core.generate(.messages(messages), frames: frames, parameters: parameters, hiding: hiding)
    }

    /// The same for a prompt that is already complete, with one image placeholder of the model's own
    /// kind written out per frame. The chat template is not applied.
    public func generate(prompt: String, frames: [[UInt8]], parameters: GenerationParameters? = nil,
                         hiding: Set<String>? = nil) -> AsyncThrowingStream<String, Error> {
        core.generate(.prompt(prompt), frames: frames, parameters: parameters, hiding: hiding)
    }

    public var lastGenerationEnd: GenerationEnd? { get async { await core.lastEnd } }
    public var isContextFull: Bool { get async { await core.contextIsFull } }

    public func clearContext() async throws { try await core.clearContext() }
    public func tokenize(_ text: String) async throws -> [Int32] { try await core.tokenize(text) }
    public func contextUsage() async throws -> Int { try await core.contextUsage() }
    public func maxContextCapacity() async throws -> Int { try await core.maxContextCapacity() }
    public func stopTokens() async throws -> [String] { try await core.stopTokens() }
    public func setStopTokens(_ texts: [String]) async throws { try await core.setStopTokens(texts) }
    public func recoverySequence() async throws -> String { try await core.currentRecoverySequence() }
    public func setRecoverySequence(_ text: String) async throws { try await core.setRecoverySequence(text) }

    /// Frees the model on the stick. The object cannot be used afterwards.
    public func release() async { await core.release() }
}
