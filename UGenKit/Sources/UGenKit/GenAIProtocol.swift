import CUGenRT
import Foundation

// Wire format of the HailoRT 5.3.0 GenAI services, ported from hailo-ai/hailort v5.3.0:
// common/genai/serializer/{genai_scheme.proto, serializer.cpp} for the messages, hef/hef.cpp
// (`Hef::hash`, `Hef::parse_hef_for_transfer`) for how a HEF is cut up for the LLM and VLM servers, and
// genai/llm/minja_wrapper for how chat messages become a prompt.
//
// A request is a 4-byte little-endian action id followed by the protobuf message for that action. A
// reply has the same shape and repeats the action id. The `GenAIRpcRequest` oneof in the .proto is not
// used on the wire.

// MARK: - Protobuf

/// Writes protobuf (proto3) fields the way the C++ runtime does: scalar fields holding their default
/// (0, false, empty) are left out, repeated numbers are packed, and fields go in field-number order
/// (the caller's job).
struct ProtoWriter {
    private(set) var data = Data()

    mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    private mutating func tag(_ field: Int, _ wireType: UInt64) {
        varint(UInt64(field) << 3 | wireType)
    }

    mutating func uint(_ field: Int, _ value: UInt64) {
        guard value != 0 else { return }
        tag(field, 0)
        varint(value)
    }

    mutating func bool(_ field: Int, _ value: Bool) {
        uint(field, value ? 1 : 0)
    }

    mutating func float(_ field: Int, _ value: Float) {
        guard value.bitPattern != 0 else { return }
        tag(field, 5)
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func string(_ field: Int, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        guard !value.isEmpty else { return }
        tag(field, 2)
        varint(UInt64(value.count))
        data.append(value)
    }

    /// A nested message. Written even when empty, as C++ does for a message that was set.
    mutating func message(_ field: Int, _ value: ProtoWriter) {
        tag(field, 2)
        varint(UInt64(value.data.count))
        data.append(value.data)
    }

    mutating func packed(_ field: Int, _ values: [UInt32]) {
        var inner = ProtoWriter()
        for value in values { inner.varint(UInt64(value)) }
        bytes(field, inner.data)
    }

    /// `repeated int32`: negative values are sign-extended to 64 bits, which takes ten bytes each.
    mutating func packed(_ field: Int, _ values: [Int32]) {
        var inner = ProtoWriter()
        for value in values { inner.varint(UInt64(bitPattern: Int64(value))) }
        bytes(field, inner.data)
    }
}

/// A decoded protobuf message: its fields in the order they appeared. Unknown fields are kept and
/// ignored by the accessors.
struct ProtoMessage {
    enum Value: Equatable {
        case varint(UInt64)
        case fixed32(UInt32)
        case fixed64(UInt64)
        case bytes(Data)
    }

    struct Malformed: Error {}

    private(set) var fields: [(number: Int, value: Value)] = []

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        var position = 0

        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard position < bytes.count, shift < 64 else { throw Malformed() }
                let byte = bytes[position]
                position += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
        }
        func fixed(_ size: Int) throws -> UInt64 {
            guard position + size <= bytes.count else { throw Malformed() }
            var result: UInt64 = 0
            for i in 0..<size { result |= UInt64(bytes[position + i]) << UInt64(8 * i) }
            position += size
            return result
        }

        while position < bytes.count {
            let key = try varint()
            let number = Int(key >> 3)
            guard number > 0 else { throw Malformed() }
            switch key & 7 {
            case 0: fields.append((number, .varint(try varint())))
            case 1: fields.append((number, .fixed64(try fixed(8))))
            case 5: fields.append((number, .fixed32(UInt32(try fixed(4)))))
            case 2:
                let length = try varint()
                guard length <= UInt64(bytes.count - position) else { throw Malformed() }
                fields.append((number, .bytes(Data(bytes[position..<position + Int(length)]))))
                position += Int(length)
            default: throw Malformed()
            }
        }
    }

    /// The last value of a scalar field, or 0 when it is absent (proto3 default).
    func uint(_ field: Int) -> UInt64 {
        for entry in fields.reversed() where entry.number == field {
            if case .varint(let value) = entry.value { return value }
        }
        return 0
    }

    func bool(_ field: Int) -> Bool { uint(field) != 0 }

    func float(_ field: Int) -> Float {
        for entry in fields.reversed() where entry.number == field {
            if case .fixed32(let value) = entry.value { return Float(bitPattern: value) }
        }
        return 0
    }

    func bytes(_ field: Int) -> Data {
        for entry in fields.reversed() where entry.number == field {
            if case .bytes(let value) = entry.value { return value }
        }
        return Data()
    }

    func string(_ field: Int) -> String { String(decoding: bytes(field), as: UTF8.self) }

    func strings(_ field: Int) -> [String] { repeatedBytes(field).map { String(decoding: $0, as: UTF8.self) } }

    func repeatedBytes(_ field: Int) -> [Data] {
        fields.compactMap { entry in
            if entry.number == field, case .bytes(let value) = entry.value { return value }
            return nil
        }
    }

    /// A nested message; an absent one reads as empty, like proto3.
    func message(_ field: Int) throws -> ProtoMessage { try ProtoMessage(bytes(field)) }

    func messages(_ field: Int) throws -> [ProtoMessage] { try repeatedBytes(field).map { try ProtoMessage($0) } }

    /// A repeated number field, whether it was sent packed or one value per tag.
    func repeatedVarints(_ field: Int) throws -> [UInt64] {
        var result: [UInt64] = []
        for entry in fields where entry.number == field {
            switch entry.value {
            case .varint(let value): result.append(value)
            case .bytes(let packed):
                var position = packed.startIndex
                while position < packed.endIndex {
                    var value: UInt64 = 0
                    var shift: UInt64 = 0
                    while true {
                        guard position < packed.endIndex, shift < 64 else { throw Malformed() }
                        let byte = packed[position]
                        position += 1
                        value |= UInt64(byte & 0x7f) << shift
                        if byte & 0x80 == 0 { break }
                        shift += 7
                    }
                    result.append(value)
                }
            default: throw Malformed()
            }
        }
        return result
    }

    func repeatedUInt32(_ field: Int) throws -> [UInt32] { try repeatedVarints(field).map { UInt32(truncatingIfNeeded: $0) } }
    func repeatedInt32(_ field: Int) throws -> [Int32] { try repeatedVarints(field).map { Int32(truncatingIfNeeded: $0) } }
}

// MARK: - Actions

/// `HailoGenAIActionID` in serializer.hpp. The numbers are the enum's order there, which is not the
/// order of the oneof in the .proto.
enum GenAIAction: UInt32 {
    case llmAcquireKVCache = 0
    case llmCreate = 1
    case llmGetGeneratorParams = 2
    case llmGeneratorCreate = 3
    case llmGeneratorWrite = 4
    case llmGeneratorGenerate = 5
    case llmGeneratorRead = 6
    case llmGeneratorAbort = 7
    case llmGeneratorRelease = 8
    case llmTokenize = 9
    case llmClearContext = 10
    case llmGetContext = 11
    case llmSetContext = 12
    case llmSetEndOfGenerationSequence = 13
    case llmGetEndOfGenerationSequence = 14
    case llmSetStopTokens = 15
    case llmGetStopTokens = 16
    case llmGetContextUsageSize = 17
    case llmGetMaxContextCapacity = 18
    case llmRelease = 19
    case vlmCreate = 20
    case vlmGeneratorGenerate = 21
    case checkHefExists = 22
    case speechCreate = 23
    case speechGenerate = 24
    case speechRelease = 25
    case speechTokenize = 26
}

/// One piece of a HEF sent to the LLM or VLM server: `HefChunksInfo`.
struct HEFChunk: Equatable {
    let name: String
    let size: UInt64
    /// Offset in the file, which is also the offset in the server's copy.
    let offset: UInt64
}

/// What `LLMGeneratorCompletion::Status` says about a generation.
enum GenerationStatus: UInt32 {
    case generating = 0
    case maxTokensReached = 1
    case logicalEnd = 2
    case aborted = 3
}

// MARK: - Requests

/// Builds the bytes of each request: action id, then the protobuf message.
enum GenAIRequest {
    /// The group id the reference client sends for a VDevice with default parameters (group "UNIQUE"):
    /// `get_group_id_as_string` replaces it with this, which makes the server share its VDevice.
    static let defaultGroupID = "FORCE_GET_FIRST_AVAILABLE"

    static func frame(_ action: GenAIAction, _ body: ProtoWriter = ProtoWriter()) -> Data {
        var data = Data()
        withUnsafeBytes(of: action.rawValue.littleEndian) { data.append(contentsOf: $0) }
        data.append(body.data)
        return data
    }

    /// For every request whose message has no fields (acquire KV cache, get generator params, generator
    /// write / generate / abort / release, clear context, the getters, and both release requests).
    static func empty(_ action: GenAIAction) -> Data { frame(action) }

    private static func chunkList(_ field: Int, _ chunks: [HEFChunk], into writer: inout ProtoWriter) {
        for chunk in chunks {
            var message = ProtoWriter()
            message.string(1, chunk.name)
            message.uint(2, chunk.size)
            message.uint(3, chunk.offset)
            writer.message(field, message)
        }
    }

    /// GenAI_Check_Hef_Exists_Request { hef_path = 1; hash = 2 }
    static func checkHefExists(path: String, hash: String) -> Data {
        var w = ProtoWriter()
        w.string(1, path)
        w.string(2, hash)
        return frame(.checkHefExists, w)
    }

    /// LLM_Create_Request { lora_name = 1; hef_path = 2; group_id = 3; chunks_to_transfer = 4;
    /// tokenizer_on_host = 5; total_hef_size = 6 }. `hefPath` is set only when the server already has
    /// the file, and then there are no chunks.
    static func llmCreate(lora: String = "", hefPath: String = "", groupID: String = defaultGroupID,
                          chunks: [HEFChunk] = [], tokenizerOnHost: Bool = false, totalSize: UInt64 = 0) -> Data {
        var w = ProtoWriter()
        w.string(1, lora)
        w.string(2, hefPath)
        w.string(3, groupID)
        chunkList(4, chunks, into: &w)
        w.bool(5, tokenizerOnHost)
        w.uint(6, totalSize)
        return frame(.llmCreate, w)
    }

    /// VLM_Create_Request { group_id = 1; hef_path = 2; chunks_to_transfer = 3; tokenizer_on_host = 4;
    /// total_hef_size = 5 }
    static func vlmCreate(hefPath: String = "", groupID: String = defaultGroupID, chunks: [HEFChunk] = [],
                          tokenizerOnHost: Bool = false, totalSize: UInt64 = 0) -> Data {
        var w = ProtoWriter()
        w.string(1, groupID)
        w.string(2, hefPath)
        chunkList(3, chunks, into: &w)
        w.bool(4, tokenizerOnHost)
        w.uint(5, totalSize)
        return frame(.vlmCreate, w)
    }

    /// LLM_Generator_Create_Request { generator_params = 1 { temperature = 1; top_p = 2; top_k = 3;
    /// frequency_penalty = 4; max_generated_tokens = 5; do_sample = 6; seed = 7 } }
    static func generatorCreate(_ parameters: GenerationParameters) -> Data {
        var p = ProtoWriter()
        p.float(1, parameters.temperature)
        p.float(2, parameters.topP)
        p.uint(3, UInt64(parameters.topK))
        p.float(4, parameters.frequencyPenalty)
        p.uint(5, UInt64(parameters.maxGeneratedTokens))
        p.bool(6, parameters.doSample)
        p.uint(7, UInt64(parameters.seed))
        var w = ProtoWriter()
        w.message(1, p)
        return frame(.llmGeneratorCreate, w)
    }

    /// LLM_Generator_Read_Request { generation_input = 1 { initial_prompt = 1; tokens = 2; embeddings = 3 } }.
    /// With the tokenizer on the server, the first read of a generation carries the prompt and the
    /// prefix tokens the server handed out; every later one carries the token the server returned last.
    static func generatorRead(prompt: String, tokens: [UInt32]) -> Data {
        var input = ProtoWriter()
        input.string(1, prompt)
        input.packed(2, tokens)
        var w = ProtoWriter()
        w.message(1, input)
        return frame(.llmGeneratorRead, w)
    }

    /// LLM_Tokenize_Request { prompt = 1 }
    static func llmTokenize(_ text: String) -> Data {
        var w = ProtoWriter()
        w.string(1, text)
        return frame(.llmTokenize, w)
    }

    /// LLM_Set_End_Of_Generation_Sequence_Request { end_of_generation_sequence_tokens = 1 }
    static func setEndOfGenerationSequence(tokens: [Int32]) -> Data {
        var w = ProtoWriter()
        w.packed(1, tokens)
        return frame(.llmSetEndOfGenerationSequence, w)
    }

    /// LLM_Set_Stop_Tokens_Request { tokenized_stop_tokens = 1 { tokens = 1 } }
    static func setStopTokens(_ sequences: [[Int32]]) -> Data {
        var w = ProtoWriter()
        for sequence in sequences {
            var s = ProtoWriter()
            s.packed(1, sequence)
            w.message(1, s)
        }
        return frame(.llmSetStopTokens, w)
    }

    /// VLM_Generator_Generate_Request { number_of_frames = 1; video_frames_count_per_video = 3;
    /// raw_embeddings = 4 }. The frames follow as one buffer each.
    static func vlmGenerate(frames: Int, videoFrameCounts: [UInt32] = [], rawEmbeddings: Bool = false) -> Data {
        var w = ProtoWriter()
        w.uint(1, UInt64(frames))
        w.packed(3, videoFrameCounts)
        w.bool(4, rawEmbeddings)
        return frame(.vlmGeneratorGenerate, w)
    }

    /// Speech2Text_Create_Request { group_id = 1 }. The whole HEF follows as one buffer.
    static func speechCreate(groupID: String = defaultGroupID) -> Data {
        var w = ProtoWriter()
        w.string(1, groupID)
        return frame(.speechCreate, w)
    }

    /// Speech2Text_Generate_Request { generator_params = 1 { task_type = 1; language = 2;
    /// repetition_penalty = 3 } }. The audio follows as one buffer.
    static func speechGenerate(task: UInt32, language: String, repetitionPenalty: Float) -> Data {
        var p = ProtoWriter()
        p.uint(1, UInt64(task))
        p.string(2, language)
        p.float(3, repetitionPenalty)
        var w = ProtoWriter()
        w.message(1, p)
        return frame(.speechGenerate, w)
    }

    /// Speech2Text_Tokenize_Request { text = 1 }
    static func speechTokenize(_ text: String) -> Data {
        var w = ProtoWriter()
        w.string(1, text)
        return frame(.speechTokenize, w)
    }
}

// MARK: - Replies

/// Decodes replies. Every reply carries a hailo_status; a non-zero one is thrown as
/// `UGenError.deviceStatus`, and a reply that cannot be read as `UGenError.client` with
/// `UGEN_ERR_PROTOCOL`.
enum GenAIReply {
    struct Create: Equatable {
        var promptTemplate: String
        var embeddingFeatures: UInt32
    }

    struct VLMCreate: Equatable {
        var formatOrder: UInt32
        var formatType: UInt32
        var height: UInt32
        var width: UInt32
        var features: UInt32
        var promptTemplate: String
        var embeddingFeatures: UInt32
        var imagePadTokenID: UInt32
        var videoPadTokenID: UInt32
        var embeddingsPerFrame: UInt32
    }

    struct Read: Equatable {
        var text: String
        var tokenID: UInt32
        var status: GenerationStatus
        var isContextFull: Bool
    }

    struct SpeechDefaults: Equatable {
        var task: UInt32
        var language: String
        var repetitionPenalty: Float
    }

    /// Checks the action id and parses the message that follows it.
    static func body(_ reply: Data, _ action: GenAIAction, step: String) throws -> ProtoMessage {
        let bytes = [UInt8](reply.prefix(4))
        guard bytes.count == 4 else { throw UGenError.client(step: step, code: Int32(UGEN_ERR_PROTOCOL)) }
        let id = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        guard id == action.rawValue, let message = try? ProtoMessage(Data(reply.dropFirst(4))) else {
            throw UGenError.client(step: step, code: Int32(UGEN_ERR_PROTOCOL))
        }
        return message
    }

    private static func parsed(_ reply: Data, _ action: GenAIAction, statusField: Int, step: String) throws -> ProtoMessage {
        let message = try body(reply, action, step: step)
        let status = message.uint(statusField)
        guard status == 0 else { throw UGenError.deviceStatus(step: step, status: Int32(truncatingIfNeeded: status)) }
        return message
    }

    private static func protocolError(_ step: String) -> UGenError { .client(step: step, code: Int32(UGEN_ERR_PROTOCOL)) }

    /// For replies that hold nothing but `status = 1`.
    static func status(_ reply: Data, _ action: GenAIAction, step: String) throws {
        _ = try parsed(reply, action, statusField: 1, step: step)
    }

    /// GenAI_Check_Hef_Exists_Reply { status = 1; hef_exists = 2 }
    static func hefExists(_ reply: Data, step: String) throws -> Bool {
        try parsed(reply, .checkHefExists, statusField: 1, step: step).bool(2)
    }

    /// LLM_Create_Reply { status = 1; prompt_template = 2; embedding_features = 3 }
    static func llmCreate(_ reply: Data, step: String) throws -> Create {
        let m = try parsed(reply, .llmCreate, statusField: 1, step: step)
        return Create(promptTemplate: m.string(2), embeddingFeatures: UInt32(truncatingIfNeeded: m.uint(3)))
    }

    /// VLM_Create_Reply { status = 1; frame_format = 2 { format_order = 1; format_type = 2 };
    /// frame_shape = 3 { height = 1; width = 2; features = 3 }; prompt_template = 4;
    /// embedding_features = 5; image_pad_token_id = 6; video_pad_token_id = 7; embeddings_per_frame = 8 }
    static func vlmCreate(_ reply: Data, step: String) throws -> VLMCreate {
        let m = try parsed(reply, .vlmCreate, statusField: 1, step: step)
        guard let format = try? m.message(2), let shape = try? m.message(3) else { throw protocolError(step) }
        func u32(_ message: ProtoMessage, _ field: Int) -> UInt32 { UInt32(truncatingIfNeeded: message.uint(field)) }
        return VLMCreate(formatOrder: u32(format, 1), formatType: u32(format, 2),
                         height: u32(shape, 1), width: u32(shape, 2), features: u32(shape, 3),
                         promptTemplate: m.string(4), embeddingFeatures: u32(m, 5), imagePadTokenID: u32(m, 6),
                         videoPadTokenID: u32(m, 7), embeddingsPerFrame: u32(m, 8))
    }

    /// LLM_Get_Generator_Params_Reply { generator_params = 1; status = 2 }
    static func generatorParams(_ reply: Data, step: String) throws -> GenerationParameters {
        let m = try parsed(reply, .llmGetGeneratorParams, statusField: 2, step: step)
        guard let p = try? m.message(1) else { throw protocolError(step) }
        return GenerationParameters(temperature: p.float(1), topP: p.float(2), topK: UInt32(truncatingIfNeeded: p.uint(3)),
                                    frequencyPenalty: p.float(4), maxGeneratedTokens: UInt32(truncatingIfNeeded: p.uint(5)),
                                    doSample: p.bool(6), seed: UInt32(truncatingIfNeeded: p.uint(7)))
    }

    /// LLM_Generator_Generate_Reply { status = 1; initial_prefix_tokens = 2 }
    static func generatorGenerate(_ reply: Data, step: String) throws -> [UInt32] {
        let m = try parsed(reply, .llmGeneratorGenerate, statusField: 1, step: step)
        guard let tokens = try? m.repeatedUInt32(2) else { throw protocolError(step) }
        return tokens
    }

    /// LLM_Generator_Read_Reply { generation_output = 1 { output_token_str = 1; output_token_id = 2 };
    /// generation_status = 2; status = 3; is_context_full = 4 }
    static func generatorRead(_ reply: Data, step: String) throws -> Read {
        let m = try parsed(reply, .llmGeneratorRead, statusField: 3, step: step)
        guard let output = try? m.message(1), let status = GenerationStatus(rawValue: UInt32(truncatingIfNeeded: m.uint(2))) else {
            throw protocolError(step)
        }
        return Read(text: output.string(1), tokenID: UInt32(truncatingIfNeeded: output.uint(2)), status: status,
                    isContextFull: m.bool(4))
    }

    /// LLM_Tokenize_Reply { tokens = 1; status = 2 }
    static func llmTokenize(_ reply: Data, step: String) throws -> [Int32] {
        let m = try parsed(reply, .llmTokenize, statusField: 2, step: step)
        guard let tokens = try? m.repeatedInt32(1) else { throw protocolError(step) }
        return tokens
    }

    /// LLM_Get_End_Of_Generation_Sequence_Reply { end_of_generation_sequence = 1;
    /// end_of_generation_sequence_tokens = 2; status = 3 }
    static func endOfGenerationSequence(_ reply: Data, step: String) throws -> (text: String, tokens: [Int32]) {
        let m = try parsed(reply, .llmGetEndOfGenerationSequence, statusField: 3, step: step)
        guard let tokens = try? m.repeatedInt32(2) else { throw protocolError(step) }
        return (m.string(1), tokens)
    }

    /// LLM_Get_Stop_Tokens_Reply { stop_tokens = 1; tokenized_stop_tokens = 2 { tokens = 1 }; status = 3 }
    static func stopTokens(_ reply: Data, step: String) throws -> (texts: [String], tokens: [[Int32]]) {
        let m = try parsed(reply, .llmGetStopTokens, statusField: 3, step: step)
        guard let sequences = try? m.messages(2).map({ try $0.repeatedInt32(1) }) else { throw protocolError(step) }
        return (m.strings(1), sequences)
    }

    /// LLM_Get_Context_Usage_Size_Reply { status = 1; context_usage = 2 } and
    /// LLM_Get_Max_Context_Capacity_Reply { status = 1; max_context_capacity = 2 }
    static func count(_ reply: Data, _ action: GenAIAction, step: String) throws -> Int {
        Int(truncatingIfNeeded: try parsed(reply, action, statusField: 1, step: step).uint(2))
    }

    /// Speech2Text_Create_Reply { status = 1; generator_params = 2 { task_type = 1; language = 2;
    /// repetition_penalty = 3 } }
    static func speechCreate(_ reply: Data, step: String) throws -> SpeechDefaults {
        let m = try parsed(reply, .speechCreate, statusField: 1, step: step)
        guard let p = try? m.message(2) else { throw protocolError(step) }
        return SpeechDefaults(task: UInt32(truncatingIfNeeded: p.uint(1)), language: p.string(2), repetitionPenalty: p.float(3))
    }

    /// Speech2Text_Generate_Reply { status = 1; segments_infos = 2 { start_sec = 1; end_sec = 2; text = 3 } }
    static func speechGenerate(_ reply: Data, step: String) throws -> [SpeechToText.Segment] {
        let m = try parsed(reply, .speechGenerate, statusField: 1, step: step)
        guard let segments = try? m.messages(2) else { throw protocolError(step) }
        return segments.map { SpeechToText.Segment(start: Double($0.float(1)), end: Double($0.float(2)), text: $0.string(3)) }
    }

    /// Speech2Text_Tokenize_Reply { tokens = 1; status = 2 }
    static func speechTokenize(_ reply: Data, step: String) throws -> [Int32] {
        let m = try parsed(reply, .speechTokenize, statusField: 2, step: step)
        guard let tokens = try? m.repeatedInt32(1) else { throw protocolError(step) }
        return tokens
    }
}

// MARK: - HEF transfer

/// How a HEF goes to the LLM and VLM servers (`Hef::parse_hef_for_transfer`): the header with the
/// protobuf description and its padding, then each external resource (tokenizer, embeddings, config
/// and so on) in the order the HEF lists them, then the weights ("CCWs").
struct HEFTransferPlan: Equatable {
    static let headerChunkName = "header+proto+padding"
    static let weightsChunkName = "CCWs"

    /// Size of a version 3 HEF header: magic, version, proto size, then xxh3 (8), weights size with
    /// padding (8), padding size (4), additional info size (8), proto xxh3 (8), reserved (8). Big-endian.
    static let headerSize = 56

    let chunks: [HEFChunk]
    let totalSize: UInt64
    /// `Hef::hash`: the file's xxh3 as 16 lowercase hex digits. The reference prints the bytes of the
    /// number as it sits in memory on a little-endian machine, so they come out in reverse file order.
    let hash: String

    init(hef: Data) throws {
        func invalid(_ reason: String) -> UGenError { .invalidInput("Not a usable HEF: \(reason).") }
        guard hef.count >= Self.headerSize else { throw invalid("the file is too short") }
        let header = [UInt8](hef.prefix(Self.headerSize))
        func big(_ offset: Int, _ size: Int) -> UInt64 {
            header[offset..<offset + size].reduce(0) { $0 << 8 | UInt64($1) }
        }
        guard big(0, 4) == 0x0148_4546 else { throw invalid("it does not start with the HEF magic") }
        guard big(4, 4) >= 3 else { throw invalid("only HEF version 3 and later can be sent to the GenAI servers") }
        let protoSize = big(8, 4)
        let weightsWithPadding = big(20, 8)
        let padding = big(28, 4)
        let zeroPoint = UInt64(Self.headerSize) + protoSize + padding
        guard zeroPoint <= UInt64(hef.count), weightsWithPadding >= padding else { throw invalid("the header sizes do not fit the file") }

        // ProtoHEFHef.external_resources = 7 { offset = 1; size = 2; name = 3; xxhash = 4 }.
        // Offsets count from the end of the header, description and padding.
        let protoStart = hef.startIndex + Self.headerSize
        guard let description = try? ProtoMessage(hef.subdata(in: protoStart..<protoStart + Int(protoSize))),
              let resources = try? description.messages(7) else {
            throw invalid("its description cannot be parsed")
        }
        var chunks = [HEFChunk(name: Self.headerChunkName, size: zeroPoint, offset: 0)]
        for resource in resources {
            chunks.append(HEFChunk(name: resource.string(3), size: resource.uint(2), offset: zeroPoint + resource.uint(1)))
        }
        chunks.append(HEFChunk(name: Self.weightsChunkName, size: weightsWithPadding - padding, offset: zeroPoint))
        for chunk in chunks where chunk.offset > UInt64(hef.count) || chunk.size > UInt64(hef.count) - chunk.offset {
            throw invalid("the part \"\(chunk.name)\" lies outside the file")
        }
        self.chunks = chunks
        totalSize = UInt64(hef.count)
        hash = header[12..<20].reversed().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Chat template

/// Turns chat messages into the prompt text, as `PromptTemplateHandler` (minja_wrapper.cpp) does with
/// the Jinja chat template the server returns when the model is created.
///
/// The device keeps the conversation between generations, so only the first prompt after a context
/// reset is rendered in full. Later ones are rendered with a placeholder message in front, and the
/// text that the placeholder alone produces is cut off the start, leaving only the new turns.
struct PromptTemplateHandler {
    private static let placeholder = ChatMessage(role: "TMP", content: "TMP")

    let template: ChatTemplate
    private let placeholderPrefix: String
    private(set) var isFirst = true

    init(source: String) throws {
        template = try ChatTemplate(source)
        placeholderPrefix = try template.render(messages: [Self.placeholder], addGenerationPrompt: false)
    }

    mutating func render(_ messages: [ChatMessage]) throws -> String {
        guard !messages.isEmpty else { throw UGenError.invalidInput("There are no messages to send.") }
        if isFirst {
            isFirst = false
            return try template.render(messages: messages, addGenerationPrompt: true)
        }
        guard !messages.contains(where: { $0.role == "system" }) else {
            throw UGenError.invalidInput("A system message can only come first after the context was cleared.")
        }
        let prompt = try template.render(messages: [Self.placeholder] + messages, addGenerationPrompt: true)
        // The reference erases that many bytes without checking that they match.
        return String(decoding: prompt.utf8.dropFirst(placeholderPrefix.utf8.count), as: UTF8.self)
    }

    mutating func reset() { isFirst = true }
}

/// A small Jinja interpreter, enough for the chat templates of the models Hailo ships (Qwen2.5,
/// Qwen2-VL and other ChatML-style templates): `if` / `elif` / `else`, `for` with `loop`, `set` (also
/// on a `namespace`), expressions with comparisons, `in`, `is` tests, `+`, `~`, indexing, slices,
/// filters and a few string methods. Blocks are trimmed the way HuggingFace and minja do it
/// (trim_blocks and lstrip_blocks). `macro`, `call`, `filter` blocks and template inheritance are not
/// supported and are reported when the template is parsed.
///
/// The variables are `messages`, `add_generation_prompt`, and `bos_token` / `eos_token` as empty
/// strings (what the reference passes). `tools` is undefined. `strftime_now(format)` gives the current
/// local time, as in minja (the Llama 3.2 template puts today's date in the system prompt with it).
struct ChatTemplate {
    struct TemplateError: Error, CustomStringConvertible {
        let message: String
        var description: String { "Chat template: \(message)" }
    }

    private let nodes: [Node]

    init(_ source: String) throws {
        var parser = TemplateParser(pieces: try TemplateLexer.split(source))
        nodes = try parser.parseBody(until: [])
    }

    func render(messages: [ChatMessage], addGenerationPrompt: Bool) throws -> String {
        let scope = Scope()
        scope.set("messages", .array(messages.map(\.templateValue)))
        scope.set("add_generation_prompt", .bool(addGenerationPrompt))
        scope.set("bos_token", .string(""))
        scope.set("eos_token", .string(""))
        // minja offers this function to templates; the value only marks the name as defined.
        scope.set("strftime_now", .bool(true))
        var output = ""
        try Interpreter.run(nodes, scope, &output)
        return output
    }
}

extension ChatMessage {
    /// The message as the template sees it: `{"role": ..., "content": ...}` where the content is a
    /// string for a text-only message, and otherwise a list of `{"type": "text", "text": ...}` and
    /// `{"type": "image"}` entries.
    var templateValue: TemplateValue {
        let content: TemplateValue
        if parts.count == 1, case .text(let text) = parts[0] {
            content = .string(text)
        } else {
            content = .array(parts.map { part in
                switch part {
                case .text(let text): return .object([("type", .string("text")), ("text", .string(text))])
                case .image: return .object([("type", .string("image"))])
                }
            })
        }
        return .object([("role", .string(role)), ("content", content)])
    }
}

/// A value inside a template.
indirect enum TemplateValue {
    case undefined
    case none
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([TemplateValue])
    /// Keys keep their order, as in JSON and Python.
    case object([(String, TemplateValue)])
    case namespace(TemplateNamespace)

    var isTruthy: Bool {
        switch self {
        case .undefined, .none: return false
        case .bool(let value): return value
        case .int(let value): return value != 0
        case .double(let value): return value != 0
        case .string(let value): return !value.isEmpty
        case .array(let value): return !value.isEmpty
        case .object(let value): return !value.isEmpty
        case .namespace: return true
        }
    }

    /// What `{{ value }}` prints.
    var text: String {
        switch self {
        case .undefined: return ""
        case .none: return "None"
        case .bool(let value): return value ? "True" : "False"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return value
        case .array, .object, .namespace: return json
        }
    }

    var json: String {
        switch self {
        case .undefined, .none: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value):
            var out = "\""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default:
                    if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
                }
            }
            return out + "\""
        case .array(let values): return "[" + values.map(\.json).joined(separator: ", ") + "]"
        case .object(let entries):
            return "{" + entries.map { TemplateValue.string($0.0).json + ": " + $0.1.json }.joined(separator: ", ") + "}"
        case .namespace(let namespace):
            return TemplateValue.object(namespace.fields.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }).json
        }
    }

    var number: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    func member(_ name: String) -> TemplateValue {
        switch self {
        case .object(let entries): return entries.last { $0.0 == name }?.1 ?? .undefined
        case .namespace(let namespace): return namespace.fields[name] ?? .undefined
        default: return .undefined
        }
    }

    static func == (a: TemplateValue, b: TemplateValue) -> Bool {
        switch (a, b) {
        case (.undefined, .undefined), (.none, .none): return true
        case (.string(let x), .string(let y)): return x == y
        case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy { $0 == $1 }
        case (.object(let x), .object(let y)):
            return x.count == y.count && x.allSatisfy { entry in y.contains { $0.0 == entry.0 && $0.1 == entry.1 } }
        case (.namespace(let x), .namespace(let y)): return x === y
        default:
            if let x = a.number, let y = b.number { return x == y }
            return false
        }
    }
}

/// `namespace(...)`: the one kind of value a template can change from inside a loop.
final class TemplateNamespace {
    var fields: [String: TemplateValue] = [:]
}

private final class Scope {
    private var variables: [String: TemplateValue] = [:]
    private let parent: Scope?

    init(parent: Scope? = nil) { self.parent = parent }

    func get(_ name: String) -> TemplateValue {
        variables[name] ?? parent?.get(name) ?? .undefined
    }

    func set(_ name: String, _ value: TemplateValue) { variables[name] = value }
}

// MARK: Template syntax tree

private indirect enum Expression {
    case literal(TemplateValue)
    case variable(String)
    case list([Expression])
    case dictionary([(Expression, Expression)])
    case member(Expression, String)
    case index(Expression, Expression)
    case slice(Expression, Expression?, Expression?, Expression?)
    case call(Expression, [Expression], [(String, Expression)])
    case filter(Expression, String, [Expression])
    case test(Expression, String, negated: Bool)
    case not(Expression)
    case negate(Expression)
    case binary(String, Expression, Expression)
    case conditional(condition: Expression, then: Expression, otherwise: Expression?)
}

private indirect enum Node {
    case text(String)
    case output(Expression)
    case conditional([(condition: Expression, body: [Node])], otherwise: [Node])
    case loop(targets: [String], sequence: Expression, body: [Node], otherwise: [Node])
    case assign(name: String, member: String?, value: Expression)
    case assignBlock(name: String, body: [Node])
}

// MARK: Template lexer

private enum TemplatePiece {
    case text(String)
    case output([Token])
    case statement([Token])
}

private enum Token: Equatable {
    case name(String)
    case string(String)
    case int(Int)
    case double(Double)
    case symbol(String)
}

private enum TemplateLexer {
    /// Cuts the source into text, `{{ }}` and `{% %}` pieces, applying `-` whitespace control,
    /// lstrip_blocks (spaces before a block tag at the start of a line go) and trim_blocks (the newline
    /// right after a block tag goes).
    static func split(_ source: String) throws -> [TemplatePiece] {
        let chars = Array(source)
        var pieces: [TemplatePiece] = []
        var text = ""
        var i = 0
        var trimNext = false   // "-%}" or "-}}" came before: drop leading whitespace of the next text
        var dropNewline = false   // a block tag came before: drop one newline

        var atStart = true   // nothing has been emitted yet: the text begins a line

        func flushText(stripTrailing: Bool, lstripBlock: Bool, last: Bool = false) {
            var t = Substring(text)
            text = ""
            if stripTrailing {
                while let end = t.last, end.isWhitespace { t.removeLast() }
            } else if lstripBlock {
                // Remove spaces and tabs back to the start of the line, if nothing else is on it.
                var end = t.endIndex
                while end > t.startIndex, t[t.index(before: end)] == " " || t[t.index(before: end)] == "\t" { end = t.index(before: end) }
                let atLineStart = end == t.startIndex ? atStart : t[t.index(before: end)].isNewline
                if atLineStart { t = t[..<end] }
            }
            if trimNext {
                t = t.drop { $0.isWhitespace }
            } else if dropNewline, let first = t.first, first == "\n" || first == "\r\n" {
                t.removeFirst()
            }
            // Like Jinja with keep_trailing_newline off: one newline at the very end goes.
            if last, let end = t.last, end == "\n" || end == "\r\n" { t.removeLast() }
            atStart = false
            if !t.isEmpty { pieces.append(.text(String(t))) }
        }

        while i < chars.count {
            guard chars[i] == "{", i + 1 < chars.count, "{%#".contains(chars[i + 1]) else {
                text.append(chars[i])
                i += 1
                continue
            }
            let kind = chars[i + 1]
            let close: [Character] = kind == "{" ? ["}", "}"] : (kind == "%" ? ["%", "}"] : ["#", "}"])
            var j = i + 2
            let stripBefore = j < chars.count && chars[j] == "-"
            if stripBefore { j += 1 }
            // Find the closing delimiter, skipping string literals.
            var k = j
            var quote: Character?
            var found = false
            while k + 1 < chars.count {
                let c = chars[k]
                if let q = quote {
                    if c == "\\" { k += 2; continue }
                    if c == q { quote = nil }
                } else if kind != "#", c == "'" || c == "\"" {
                    quote = c
                } else if c == close[0], chars[k + 1] == close[1] {
                    found = true
                    break
                }
                k += 1
            }
            guard found else { throw ChatTemplate.TemplateError(message: "a tag is not closed") }
            let stripAfter = k > j && chars[k - 1] == "-"
            let inner = String(chars[j..<(stripAfter ? k - 1 : k)])

            flushText(stripTrailing: stripBefore, lstripBlock: kind != "{")
            trimNext = stripAfter
            dropNewline = kind != "{"
            switch kind {
            case "{": pieces.append(.output(try tokenize(inner)))
            case "%": pieces.append(.statement(try tokenize(inner)))
            default: break
            }
            i = k + 2
        }
        flushText(stripTrailing: false, lstripBlock: false, last: true)
        return pieces
    }

    static func tokenize(_ source: String) throws -> [Token] {
        let chars = Array(source)
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isLetter || c == "_" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                tokens.append(.name(String(chars[i..<j])))
                i = j
            } else if c.isNumber {
                var j = i
                while j < chars.count, chars[j].isNumber { j += 1 }
                if j + 1 < chars.count, chars[j] == ".", chars[j + 1].isNumber {
                    j += 1
                    while j < chars.count, chars[j].isNumber { j += 1 }
                    guard let value = Double(String(chars[i..<j])) else { throw ChatTemplate.TemplateError(message: "bad number") }
                    tokens.append(.double(value))
                } else {
                    guard let value = Int(String(chars[i..<j])) else { throw ChatTemplate.TemplateError(message: "bad number") }
                    tokens.append(.int(value))
                }
                i = j
            } else if c == "'" || c == "\"" {
                var value = ""
                var j = i + 1
                var closed = false
                while j < chars.count {
                    if chars[j] == "\\", j + 1 < chars.count {
                        switch chars[j + 1] {
                        case "n": value.append("\n")
                        case "t": value.append("\t")
                        case "r": value.append("\r")
                        default: value.append(chars[j + 1])
                        }
                        j += 2
                    } else if chars[j] == c {
                        closed = true
                        break
                    } else {
                        value.append(chars[j])
                        j += 1
                    }
                }
                guard closed else { throw ChatTemplate.TemplateError(message: "a string is not closed") }
                tokens.append(.string(value))
                i = j + 1
            } else {
                let two = i + 1 < chars.count ? String(chars[i...i + 1]) : ""
                if ["==", "!=", "<=", ">=", "//", "**"].contains(two) {
                    tokens.append(.symbol(two))
                    i += 2
                } else if "()[]{}.,:|+-*/%~<>=".contains(c) {
                    tokens.append(.symbol(String(c)))
                    i += 1
                } else {
                    throw ChatTemplate.TemplateError(message: "unexpected character \"\(c)\"")
                }
            }
        }
        return tokens
    }
}

// MARK: Template parser

private struct TemplateParser {
    let pieces: [TemplatePiece]
    var position = 0
    /// The statement that ended the last body, for the caller to look at.
    var terminator: [Token] = []

    init(pieces: [TemplatePiece]) { self.pieces = pieces }

    mutating func parseBody(until terminators: Set<String>) throws -> [Node] {
        var nodes: [Node] = []
        while position < pieces.count {
            let piece = pieces[position]
            position += 1
            switch piece {
            case .text(let text): nodes.append(.text(text))
            case .output(let tokens):
                var expression = ExpressionParser(tokens: tokens)
                nodes.append(.output(try expression.parseWhole()))
            case .statement(let tokens):
                guard case .name(let keyword)? = tokens.first else { throw ChatTemplate.TemplateError(message: "empty tag") }
                if terminators.contains(keyword) {
                    terminator = tokens
                    return nodes
                }
                nodes.append(try parseStatement(keyword, Array(tokens.dropFirst())))
            }
        }
        guard terminators.isEmpty else {
            throw ChatTemplate.TemplateError(message: "missing {% \(terminators.sorted().joined(separator: " / ")) %}")
        }
        return nodes
    }

    private mutating func parseStatement(_ keyword: String, _ rest: [Token]) throws -> Node {
        switch keyword {
        case "if":
            var branches: [(condition: Expression, body: [Node])] = []
            var otherwise: [Node] = []
            var condition = rest
            while true {
                var parser = ExpressionParser(tokens: condition)
                let expression = try parser.parseWhole()
                let body = try parseBody(until: ["elif", "else", "endif"])
                branches.append((expression, body))
                guard case .name(let end)? = terminator.first else { break }
                if end == "elif" {
                    condition = Array(terminator.dropFirst())
                    continue
                }
                if end == "else" { otherwise = try parseBody(until: ["endif"]) }
                break
            }
            return .conditional(branches, otherwise: otherwise)
        case "for":
            var targets: [String] = []
            var index = 0
            while index < rest.count {
                if case .name(let name) = rest[index], name != "in" {
                    targets.append(name)
                    index += 1
                    if index < rest.count, rest[index] == .symbol(",") { index += 1 }
                } else {
                    break
                }
            }
            guard !targets.isEmpty, index < rest.count, rest[index] == .name("in") else {
                throw ChatTemplate.TemplateError(message: "malformed for tag")
            }
            var parser = ExpressionParser(tokens: Array(rest[(index + 1)...]))
            let sequence = try parser.parseWhole()
            let body = try parseBody(until: ["else", "endfor"])
            var otherwise: [Node] = []
            if terminator.first == .name("else") { otherwise = try parseBody(until: ["endfor"]) }
            return .loop(targets: targets, sequence: sequence, body: body, otherwise: otherwise)
        case "set":
            guard case .name(let name)? = rest.first else { throw ChatTemplate.TemplateError(message: "malformed set tag") }
            var index = 1
            var member: String?
            if rest.count > 2, rest[1] == .symbol("."), case .name(let field) = rest[2] {
                member = field
                index = 3
            }
            if index == rest.count, member == nil {
                return .assignBlock(name: name, body: try parseBody(until: ["endset"]))
            }
            guard index < rest.count, rest[index] == .symbol("=") else { throw ChatTemplate.TemplateError(message: "malformed set tag") }
            var parser = ExpressionParser(tokens: Array(rest[(index + 1)...]))
            return .assign(name: name, member: member, value: try parser.parseWhole())
        default:
            throw ChatTemplate.TemplateError(message: "the tag \"\(keyword)\" is not supported")
        }
    }
}

private struct ExpressionParser {
    let tokens: [Token]
    var position = 0

    init(tokens: [Token]) { self.tokens = tokens }

    private var current: Token? { position < tokens.count ? tokens[position] : nil }

    private mutating func accept(_ symbol: String) -> Bool {
        if current == .symbol(symbol) { position += 1; return true }
        return false
    }

    private mutating func acceptName(_ name: String) -> Bool {
        if current == .name(name) { position += 1; return true }
        return false
    }

    private mutating func expect(_ symbol: String) throws {
        guard accept(symbol) else { throw ChatTemplate.TemplateError(message: "expected \"\(symbol)\"") }
    }

    mutating func parseWhole() throws -> Expression {
        let expression = try parseExpression()
        guard position == tokens.count else { throw ChatTemplate.TemplateError(message: "unexpected text after an expression") }
        return expression
    }

    mutating func parseExpression() throws -> Expression {
        let value = try parseOr()
        if acceptName("if") {
            let condition = try parseOr()
            let otherwise = acceptName("else") ? try parseExpression() : nil
            return .conditional(condition: condition, then: value, otherwise: otherwise)
        }
        return value
    }

    private mutating func parseOr() throws -> Expression {
        var left = try parseAnd()
        while acceptName("or") { left = .binary("or", left, try parseAnd()) }
        return left
    }

    private mutating func parseAnd() throws -> Expression {
        var left = try parseNot()
        while acceptName("and") { left = .binary("and", left, try parseNot()) }
        return left
    }

    private mutating func parseNot() throws -> Expression {
        if acceptName("not") { return .not(try parseNot()) }
        return try parseComparison()
    }

    private mutating func parseComparison() throws -> Expression {
        var left = try parseAdditive()
        while true {
            if case .symbol(let symbol)? = current, ["==", "!=", "<", ">", "<=", ">="].contains(symbol) {
                position += 1
                left = .binary(symbol, left, try parseAdditive())
            } else if acceptName("in") {
                left = .binary("in", left, try parseAdditive())
            } else if current == .name("not"), position + 1 < tokens.count, tokens[position + 1] == .name("in") {
                position += 2
                left = .not(.binary("in", left, try parseAdditive()))
            } else if acceptName("is") {
                let negated = acceptName("not")
                guard case .name(let test)? = current else { throw ChatTemplate.TemplateError(message: "expected a test after \"is\"") }
                position += 1
                left = .test(left, test, negated: negated)
            } else {
                return left
            }
        }
    }

    private mutating func parseAdditive() throws -> Expression {
        var left = try parseMultiplicative()
        while case .symbol(let symbol)? = current, ["+", "-", "~"].contains(symbol) {
            position += 1
            left = .binary(symbol, left, try parseMultiplicative())
        }
        return left
    }

    private mutating func parseMultiplicative() throws -> Expression {
        var left = try parseUnary()
        while case .symbol(let symbol)? = current, ["*", "/", "//", "%"].contains(symbol) {
            position += 1
            left = .binary(symbol, left, try parseUnary())
        }
        return left
    }

    private mutating func parseUnary() throws -> Expression {
        if accept("-") { return .negate(try parseUnary()) }
        var value = try parsePostfix()
        while accept("|") {
            guard case .name(let name)? = current else { throw ChatTemplate.TemplateError(message: "expected a filter name") }
            position += 1
            var arguments: [Expression] = []
            if accept("(") { arguments = try parseArguments().positional }
            value = .filter(value, name, arguments)
        }
        return value
    }

    private mutating func parseArguments() throws -> (positional: [Expression], named: [(String, Expression)]) {
        var positional: [Expression] = []
        var named: [(String, Expression)] = []
        while !accept(")") {
            if case .name(let name)? = current, position + 1 < tokens.count, tokens[position + 1] == .symbol("=") {
                position += 2
                named.append((name, try parseExpression()))
            } else {
                positional.append(try parseExpression())
            }
            if !accept(",") {
                try expect(")")
                break
            }
        }
        return (positional, named)
    }

    private mutating func parsePostfix() throws -> Expression {
        var value = try parsePrimary()
        while true {
            if accept(".") {
                guard case .name(let name)? = current else { throw ChatTemplate.TemplateError(message: "expected a name after \".\"") }
                position += 1
                value = .member(value, name)
            } else if accept("[") {
                var parts: [Expression?] = []
                var isSlice = false
                var part: Expression? = (current == .symbol(":") || current == .symbol("]")) ? nil : try parseExpression()
                while accept(":") {
                    isSlice = true
                    parts.append(part)
                    part = (current == .symbol(":") || current == .symbol("]")) ? nil : try parseExpression()
                }
                parts.append(part)
                try expect("]")
                if isSlice {
                    guard parts.count <= 3 else { throw ChatTemplate.TemplateError(message: "malformed slice") }
                    value = .slice(value, parts[0], parts.count > 1 ? parts[1] : nil, parts.count > 2 ? parts[2] : nil)
                } else {
                    guard let index = parts[0] else { throw ChatTemplate.TemplateError(message: "empty index") }
                    value = .index(value, index)
                }
            } else if accept("(") {
                let arguments = try parseArguments()
                value = .call(value, arguments.positional, arguments.named)
            } else {
                return value
            }
        }
    }

    private mutating func parsePrimary() throws -> Expression {
        guard let token = current else { throw ChatTemplate.TemplateError(message: "an expression ends too early") }
        position += 1
        switch token {
        case .string(let value): return .literal(.string(value))
        case .int(let value): return .literal(.int(value))
        case .double(let value): return .literal(.double(value))
        case .name(let name):
            switch name {
            case "true", "True": return .literal(.bool(true))
            case "false", "False": return .literal(.bool(false))
            case "none", "None": return .literal(.none)
            default: return .variable(name)
            }
        case .symbol("("):
            let value = try parseExpression()
            try expect(")")
            return value
        case .symbol("["):
            var items: [Expression] = []
            while !accept("]") {
                items.append(try parseExpression())
                if !accept(",") {
                    try expect("]")
                    break
                }
            }
            return .list(items)
        case .symbol("{"):
            var entries: [(Expression, Expression)] = []
            while !accept("}") {
                let key = try parseExpression()
                try expect(":")
                entries.append((key, try parseExpression()))
                if !accept(",") {
                    try expect("}")
                    break
                }
            }
            return .dictionary(entries)
        case .symbol(let symbol):
            throw ChatTemplate.TemplateError(message: "unexpected \"\(symbol)\"")
        }
    }
}

// MARK: Template interpreter

private enum Interpreter {
    static func run(_ nodes: [Node], _ scope: Scope, _ output: inout String) throws {
        for node in nodes {
            switch node {
            case .text(let text): output += text
            case .output(let expression): output += try evaluate(expression, scope).text
            case .conditional(let branches, let otherwise):
                var done = false
                for branch in branches where try evaluate(branch.condition, scope).isTruthy {
                    try run(branch.body, scope, &output)
                    done = true
                    break
                }
                if !done { try run(otherwise, scope, &output) }
            case .loop(let targets, let sequenceExpression, let body, let otherwise):
                let items: [TemplateValue]
                switch try evaluate(sequenceExpression, scope) {
                case .array(let values): items = values
                case .object(let entries): items = entries.map { .string($0.0) }
                case .string(let value): items = value.map { .string(String($0)) }
                case .undefined, .none: items = []
                default: throw ChatTemplate.TemplateError(message: "a for loop needs a list")
                }
                if items.isEmpty {
                    try run(otherwise, scope, &output)
                    continue
                }
                for (index, item) in items.enumerated() {
                    let inner = Scope(parent: scope)
                    if targets.count == 1 {
                        inner.set(targets[0], item)
                    } else {
                        guard case .array(let parts) = item, parts.count == targets.count else {
                            throw ChatTemplate.TemplateError(message: "a for loop cannot unpack its items")
                        }
                        for (target, part) in zip(targets, parts) { inner.set(target, part) }
                    }
                    inner.set("loop", .object([
                        ("index", .int(index + 1)), ("index0", .int(index)),
                        ("first", .bool(index == 0)), ("last", .bool(index == items.count - 1)),
                        ("length", .int(items.count)),
                        ("revindex", .int(items.count - index)), ("revindex0", .int(items.count - index - 1)),
                        ("previtem", index > 0 ? items[index - 1] : .undefined),
                        ("nextitem", index + 1 < items.count ? items[index + 1] : .undefined),
                    ]))
                    try run(body, inner, &output)
                }
            case .assign(let name, let member, let valueExpression):
                let value = try evaluate(valueExpression, scope)
                if let member {
                    guard case .namespace(let namespace) = scope.get(name) else {
                        throw ChatTemplate.TemplateError(message: "\"\(name)\" is not a namespace")
                    }
                    namespace.fields[member] = value
                } else {
                    scope.set(name, value)
                }
            case .assignBlock(let name, let body):
                var captured = ""
                try run(body, scope, &captured)
                scope.set(name, .string(captured))
            }
        }
    }

    static func evaluate(_ expression: Expression, _ scope: Scope) throws -> TemplateValue {
        switch expression {
        case .literal(let value): return value
        case .variable(let name): return scope.get(name)
        case .list(let items): return .array(try items.map { try evaluate($0, scope) })
        case .dictionary(let entries):
            return .object(try entries.map { (try evaluate($0.0, scope).text, try evaluate($0.1, scope)) })
        case .member(let base, let name): return try evaluate(base, scope).member(name)
        case .index(let baseExpression, let indexExpression):
            let base = try evaluate(baseExpression, scope)
            let index = try evaluate(indexExpression, scope)
            switch (base, index) {
            case (.array(let values), .int(let i)):
                let position = i < 0 ? values.count + i : i
                return values.indices.contains(position) ? values[position] : .undefined
            case (.string(let value), .int(let i)):
                let chars = Array(value)
                let position = i < 0 ? chars.count + i : i
                return chars.indices.contains(position) ? .string(String(chars[position])) : .undefined
            case (_, .string(let key)): return base.member(key)
            default: return .undefined
            }
        case .slice(let baseExpression, let startExpression, let endExpression, let stepExpression):
            let base = try evaluate(baseExpression, scope)
            func bound(_ expression: Expression?) throws -> Int? {
                guard let expression else { return nil }
                guard case .int(let value) = try evaluate(expression, scope) else { return nil }
                return value
            }
            let step = try bound(stepExpression) ?? 1
            guard step == 1 || step == -1 else { throw ChatTemplate.TemplateError(message: "only slice steps 1 and -1 are supported") }
            func cut<T>(_ items: [T]) throws -> [T] {
                let ordered = step == 1 ? items : Array(items.reversed())
                // With step -1, bounds are given in the original order; only [::-1] is common.
                if step == -1, startExpression != nil || endExpression != nil {
                    throw ChatTemplate.TemplateError(message: "a reversed slice with bounds is not supported")
                }
                func clamp(_ value: Int) -> Int { min(max(value < 0 ? ordered.count + value : value, 0), ordered.count) }
                let start = clamp(try bound(startExpression) ?? 0)
                let end = clamp(try bound(endExpression) ?? ordered.count)
                return start < end ? Array(ordered[start..<end]) : []
            }
            switch base {
            case .array(let values): return .array(try cut(values))
            case .string(let value): return .string(String(try cut(Array(value))))
            default: return .undefined
            }
        case .call(let callee, let positional, let named):
            return try call(callee, positional, named, scope)
        case .filter(let valueExpression, let name, let arguments):
            return try filter(try evaluate(valueExpression, scope), name, try arguments.map { try evaluate($0, scope) })
        case .test(let valueExpression, let name, let negated):
            let value = try evaluate(valueExpression, scope)
            let result: Bool
            switch name {
            case "defined": if case .undefined = value { result = false } else { result = true }
            case "undefined": if case .undefined = value { result = true } else { result = false }
            case "none": if case .none = value { result = true } else { result = false }
            case "string": if case .string = value { result = true } else { result = false }
            case "boolean": if case .bool = value { result = true } else { result = false }
            case "true": if case .bool(true) = value { result = true } else { result = false }
            case "false": if case .bool(false) = value { result = true } else { result = false }
            case "integer": if case .int = value { result = true } else { result = false }
            case "float": if case .double = value { result = true } else { result = false }
            case "number":
                switch value {
                case .int, .double: result = true
                default: result = false
                }
            case "mapping": if case .object = value { result = true } else { result = false }
            case "sequence", "iterable":
                switch value {
                case .array, .string, .object: result = true
                default: result = false
                }
            default: throw ChatTemplate.TemplateError(message: "the test \"\(name)\" is not supported")
            }
            return .bool(result != negated)
        case .not(let inner): return .bool(!(try evaluate(inner, scope).isTruthy))
        case .negate(let inner):
            switch try evaluate(inner, scope) {
            case .int(let value): return .int(-value)
            case .double(let value): return .double(-value)
            default: throw ChatTemplate.TemplateError(message: "\"-\" needs a number")
            }
        case .conditional(let condition, let then, let otherwise):
            if try evaluate(condition, scope).isTruthy { return try evaluate(then, scope) }
            return try otherwise.map { try evaluate($0, scope) } ?? .undefined
        case .binary(let op, let leftExpression, let rightExpression):
            // "and" / "or" return one of their operands and only look at the right one when needed.
            if op == "and" {
                let left = try evaluate(leftExpression, scope)
                return left.isTruthy ? try evaluate(rightExpression, scope) : left
            }
            if op == "or" {
                let left = try evaluate(leftExpression, scope)
                return left.isTruthy ? left : try evaluate(rightExpression, scope)
            }
            return try binary(op, try evaluate(leftExpression, scope), try evaluate(rightExpression, scope))
        }
    }

    private static func binary(_ op: String, _ left: TemplateValue, _ right: TemplateValue) throws -> TemplateValue {
        switch op {
        case "==": return .bool(left == right)
        case "!=": return .bool(!(left == right))
        case "~": return .string(left.text + right.text)
        case "in":
            switch right {
            case .array(let values): return .bool(values.contains { $0 == left })
            case .object(let entries): return .bool(entries.contains { $0.0 == left.text })
            case .string(let value):
                guard case .string(let needle) = left else { return .bool(false) }
                return .bool(needle.isEmpty || value.contains(needle))
            default: return .bool(false)
            }
        case "<", ">", "<=", ">=":
            if case .string(let a) = left, case .string(let b) = right {
                return .bool(op == "<" ? a < b : op == ">" ? a > b : op == "<=" ? a <= b : a >= b)
            }
            guard let a = left.number, let b = right.number else { throw ChatTemplate.TemplateError(message: "cannot compare these values") }
            return .bool(op == "<" ? a < b : op == ">" ? a > b : op == "<=" ? a <= b : a >= b)
        case "+":
            switch (left, right) {
            case (.int(let a), .int(let b)): return .int(a + b)
            case (.array(let a), .array(let b)): return .array(a + b)
            case (.string, _), (_, .string): return .string(left.text + right.text)
            default: break
            }
        case "-", "*", "/", "//", "%":
            if case .int(let a) = left, case .int(let b) = right, op != "/" {
                if op == "-" { return .int(a - b) }
                if op == "*" { return .int(a * b) }
                guard b != 0 else { throw ChatTemplate.TemplateError(message: "division by zero") }
                // Python rounds towards negative infinity.
                let quotient = Int((Double(a) / Double(b)).rounded(.down))
                return .int(op == "//" ? quotient : a - quotient * b)
            }
        default: break
        }
        guard let a = left.number, let b = right.number else {
            throw ChatTemplate.TemplateError(message: "\"\(op)\" cannot be applied to these values")
        }
        switch op {
        case "+": return .double(a + b)
        case "-": return .double(a - b)
        case "*": return .double(a * b)
        case "/": return .double(a / b)
        case "//": return .double((a / b).rounded(.down))
        default: return .double(a - (a / b).rounded(.down) * b)
        }
    }

    private static func call(_ callee: Expression, _ positional: [Expression], _ named: [(String, Expression)],
                             _ scope: Scope) throws -> TemplateValue {
        let arguments = try positional.map { try evaluate($0, scope) }
        if case .variable(let name) = callee {
            switch name {
            case "namespace":
                let namespace = TemplateNamespace()
                for (key, value) in named { namespace.fields[key] = try evaluate(value, scope) }
                return .namespace(namespace)
            case "range":
                let numbers = arguments.compactMap { value -> Int? in if case .int(let i) = value { return i } else { return nil } }
                guard numbers.count == arguments.count, (1...2).contains(numbers.count) else {
                    throw ChatTemplate.TemplateError(message: "range needs one or two whole numbers")
                }
                let start = numbers.count == 2 ? numbers[0] : 0
                let end = numbers[numbers.count - 1]
                return .array(start < end ? (start..<end).map { .int($0) } : [])
            case "strftime_now":
                guard case .string(let format)? = arguments.first else {
                    throw ChatTemplate.TemplateError(message: "strftime_now needs a format")
                }
                var now = time(nil)
                var parts = tm()
                localtime_r(&now, &parts)
                var buffer = [CChar](repeating: 0, count: 256)
                let length = strftime(&buffer, buffer.count, format, &parts)
                return .string(String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self))
            case "raise_exception":
                throw ChatTemplate.TemplateError(message: arguments.first?.text ?? "the template raised an error")
            default:
                throw ChatTemplate.TemplateError(message: "the function \"\(name)\" is not supported")
            }
        }
        guard case .member(let baseExpression, let method) = callee else {
            throw ChatTemplate.TemplateError(message: "this call is not supported")
        }
        let base = try evaluate(baseExpression, scope)
        func text(_ index: Int) -> String? {
            guard index < arguments.count, case .string(let value) = arguments[index] else { return nil }
            return value
        }
        switch (base, method) {
        case (.string(let value), "strip"): return .string(trim(value, text(0), leading: true, trailing: true))
        case (.string(let value), "lstrip"): return .string(trim(value, text(0), leading: true, trailing: false))
        case (.string(let value), "rstrip"): return .string(trim(value, text(0), leading: false, trailing: true))
        case (.string(let value), "startswith"): return .bool(value.hasPrefix(text(0) ?? "\u{0}"))
        case (.string(let value), "endswith"): return .bool(value.hasSuffix(text(0) ?? "\u{0}"))
        case (.string(let value), "upper"): return .string(value.uppercased())
        case (.string(let value), "lower"): return .string(value.lowercased())
        case (.string(let value), "split"):
            guard let separator = text(0), !separator.isEmpty else {
                return .array(value.split(whereSeparator: \.isWhitespace).map { .string(String($0)) })
            }
            return .array(value.components(separatedBy: separator).map { .string($0) })
        case (.object(let entries), "items"): return .array(entries.map { .array([.string($0.0), $0.1]) })
        case (.object(let entries), "keys"): return .array(entries.map { .string($0.0) })
        case (.object(let entries), "values"): return .array(entries.map { $0.1 })
        case (.object, "get"):
            guard let key = text(0) else { return .none }
            let found = base.member(key)
            if case .undefined = found { return arguments.count > 1 ? arguments[1] : .none }
            return found
        default:
            throw ChatTemplate.TemplateError(message: "the method \"\(method)\" is not supported here")
        }
    }

    private static func trim(_ value: String, _ characters: String?, leading: Bool, trailing: Bool) -> String {
        let strip: (Character) -> Bool = characters.map { set in { set.contains($0) } } ?? { $0.isWhitespace }
        var result = Substring(value)
        if leading { result = result.drop(while: strip) }
        if trailing {
            while let last = result.last, strip(last) { result.removeLast() }
        }
        return String(result)
    }

    private static func filter(_ value: TemplateValue, _ name: String, _ arguments: [TemplateValue]) throws -> TemplateValue {
        switch name {
        case "trim": return .string(trim(value.text, nil, leading: true, trailing: true))
        case "string": return .string(value.text)
        case "safe": return value
        case "tojson": return .string(value.json)
        case "upper": return .string(value.text.uppercased())
        case "lower": return .string(value.text.lowercased())
        case "length", "count":
            switch value {
            case .string(let text): return .int(text.count)
            case .array(let values): return .int(values.count)
            case .object(let entries): return .int(entries.count)
            default: return .int(0)
            }
        case "default", "d":
            let fallback = arguments.first ?? .string("")
            if case .undefined = value { return fallback }
            if arguments.count > 1, arguments[1].isTruthy, !value.isTruthy { return fallback }
            return value
        case "first":
            if case .array(let values) = value { return values.first ?? .undefined }
            return .undefined
        case "last":
            if case .array(let values) = value { return values.last ?? .undefined }
            return .undefined
        case "list":
            switch value {
            case .array: return value
            case .string(let text): return .array(text.map { .string(String($0)) })
            case .object(let entries): return .array(entries.map { .string($0.0) })
            default: return .array([])
            }
        case "join":
            guard case .array(let values) = value else { return .string(value.text) }
            return .string(values.map(\.text).joined(separator: arguments.first?.text ?? ""))
        case "int":
            switch value {
            case .int: return value
            case .double(let number): return .int(Int(number))
            case .string(let text): return .int(Int(text.trimmingCharacters(in: .whitespaces)) ?? 0)
            case .bool(let flag): return .int(flag ? 1 : 0)
            default: return .int(0)
            }
        default:
            throw ChatTemplate.TemplateError(message: "the filter \"\(name)\" is not supported")
        }
    }
}
