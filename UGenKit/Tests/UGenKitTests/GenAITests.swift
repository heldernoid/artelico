import CoreGraphics
import CUGenRT
import ImageIO
import XCTest
@testable import StudioCore
@testable import UGenKit

/// The GenAI client: message encoding, HEF transfer plan and chat templates without a device, and the
/// services on the real stick.
///
/// The device tests only run with `UGEN_DEVICE_TESTS=1` in the environment. Those that need a GenAI
/// model file are skipped when the file is missing or still being downloaded.
final class GenAITests: XCTestCase {
    /// The project folder (UGenKit's parent), found from this file's own path.
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let smallHEF = root.appendingPathComponent("models/yolov8n.hef")

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private func bytes(_ hex: String) -> Data {
        let digits = Array(hex.filter { !$0.isWhitespace })
        return Data(stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! })
    }

    private func ascii(_ text: String) -> String { hex(Data(text.utf8)) }

    /// Compares ignoring the spaces that make the expected bytes readable.
    private func assertBytes(_ data: Data, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(hex(data), expected.filter { !$0.isWhitespace }, file: file, line: line)
    }

    // MARK: Requests
    // Expected bytes are worked out by hand from genai_scheme.proto: a field's key is
    // (number << 3 | wire type), wire type 0 = varint, 2 = length-delimited, 5 = 32-bit. In front goes
    // the action id from serializer.hpp as 4 bytes, little-endian.

    func testActionIDs() {
        // The order of `enum class HailoGenAIActionID`.
        let expected: [(GenAIAction, UInt32)] = [
            (.llmAcquireKVCache, 0), (.llmCreate, 1), (.llmGetGeneratorParams, 2), (.llmGeneratorCreate, 3),
            (.llmGeneratorWrite, 4), (.llmGeneratorGenerate, 5), (.llmGeneratorRead, 6), (.llmGeneratorAbort, 7),
            (.llmGeneratorRelease, 8), (.llmTokenize, 9), (.llmClearContext, 10), (.llmGetContext, 11), (.llmSetContext, 12),
            (.llmSetEndOfGenerationSequence, 13), (.llmGetEndOfGenerationSequence, 14), (.llmSetStopTokens, 15),
            (.llmGetStopTokens, 16), (.llmGetContextUsageSize, 17), (.llmGetMaxContextCapacity, 18), (.llmRelease, 19),
            (.vlmCreate, 20), (.vlmGeneratorGenerate, 21), (.checkHefExists, 22), (.speechCreate, 23),
            (.speechGenerate, 24), (.speechRelease, 25), (.speechTokenize, 26),
        ]
        for (action, value) in expected { XCTAssertEqual(action.rawValue, value) }
    }

    func testRequestsWithoutFields() {
        assertBytes(GenAIRequest.empty(.llmAcquireKVCache), "00000000")
        assertBytes(GenAIRequest.empty(.llmGetGeneratorParams), "02000000")
        assertBytes(GenAIRequest.empty(.llmGeneratorWrite), "04000000")
        assertBytes(GenAIRequest.empty(.llmGeneratorGenerate), "05000000")
        assertBytes(GenAIRequest.empty(.llmGeneratorAbort), "07000000")
        assertBytes(GenAIRequest.empty(.llmGeneratorRelease), "08000000")
        assertBytes(GenAIRequest.empty(.llmClearContext), "0a000000")
        assertBytes(GenAIRequest.empty(.llmGetEndOfGenerationSequence), "0e000000")
        assertBytes(GenAIRequest.empty(.llmGetStopTokens), "10000000")
        assertBytes(GenAIRequest.empty(.llmGetContextUsageSize), "11000000")
        assertBytes(GenAIRequest.empty(.llmGetMaxContextCapacity), "12000000")
        assertBytes(GenAIRequest.empty(.llmRelease), "13000000")
        assertBytes(GenAIRequest.empty(.speechRelease), "19000000")
    }

    func testCheckHefExistsRequest() {
        // hef_path = 1 (key 0a), hash = 2 (key 12)
        assertBytes(GenAIRequest.checkHefExists(path: "/a.hef", hash: "0a69"),
                    "16000000  0a 06 2f612e686566  12 04 30613639")
    }

    func testLLMCreateRequest() {
        let chunks = [HEFChunk(name: "h", size: 300, offset: 0), HEFChunk(name: "CCWs", size: 5, offset: 300)]
        // group_id = 3 (1a); chunks_to_transfer = 4 (22) { name = 1 (0a); size = 2 (10); offset = 3 (18) };
        // total_hef_size = 6 (30). 300 is ac 02 and 305 is b1 02 as varints. A zero offset is left out.
        assertBytes(GenAIRequest.llmCreate(groupID: "g", chunks: chunks, totalSize: 305),
                    "01000000  1a 01 67  22 06 0a0168 10ac02  22 0b 0a0443435773 1005 18ac02  30 b102")
        // lora_name = 1 (0a), hef_path = 2 (12), tokenizer_on_host = 5 (28)
        assertBytes(GenAIRequest.llmCreate(lora: "L", hefPath: "/p", groupID: "", tokenizerOnHost: true),
                    "01000000  0a 01 4c  12 02 2f70  28 01")
        // The default group id is the one the reference sends for a default VDevice.
        assertBytes(GenAIRequest.llmCreate(), "01000000 1a 19" + ascii("FORCE_GET_FIRST_AVAILABLE"))
    }

    func testVLMCreateRequest() {
        // group_id = 1 (0a); hef_path = 2 (12); chunks_to_transfer = 3 (1a); tokenizer_on_host = 4 (20); total_hef_size = 5 (28)
        assertBytes(GenAIRequest.vlmCreate(groupID: "g", chunks: [HEFChunk(name: "h", size: 300, offset: 0)], totalSize: 300),
                    "14000000  0a 01 67  1a 06 0a0168 10ac02  28 ac02")
        assertBytes(GenAIRequest.vlmCreate(hefPath: "/p", groupID: "g", tokenizerOnHost: true),
                    "14000000  0a 01 67  12 02 2f70  20 01")
    }

    func testGeneratorCreateRequest() {
        var parameters = GenerationParameters(temperature: 0.5, topP: 0.25, topK: 20, frequencyPenalty: 1.5,
                                              maxGeneratedTokens: 1024, doSample: true, seed: 7)
        // generator_params = 1 (0a), 24 bytes: temperature = 1 (0d, float 0.5 = 3f000000 little-endian),
        // top_p = 2 (15, 0.25 = 3e800000), top_k = 3 (18), frequency_penalty = 4 (25, 1.5 = 3fc00000),
        // max_generated_tokens = 5 (28, 1024 = 80 08), do_sample = 6 (30), seed = 7 (38)
        assertBytes(GenAIRequest.generatorCreate(parameters),
                    "03000000  0a 18  0d 0000003f  15 0000803e  18 14  25 0000c03f  28 8008  30 01  38 07")
        // Zeros and false are left out; the random seed is 0xffffffff, five bytes as a varint.
        parameters = GenerationParameters(temperature: 0, topP: 0, topK: 0, frequencyPenalty: 0, maxGeneratedTokens: 0, doSample: false)
        assertBytes(GenAIRequest.generatorCreate(parameters), "03000000  0a 06  38 ffffffff0f")
    }

    func testGeneratorReadRequest() {
        // generation_input = 1 (0a) { initial_prompt = 1 (0a); tokens = 2 (12, packed) }
        assertBytes(GenAIRequest.generatorRead(prompt: "Hi", tokens: [1, 300]), "06000000  0a 09  0a 02 4869  12 03 01 ac02")
        // 151645 = dd a0 09
        assertBytes(GenAIRequest.generatorRead(prompt: "", tokens: [151_645]), "06000000  0a 05  12 03 dda009")
        // The input message is written even when it is empty.
        assertBytes(GenAIRequest.generatorRead(prompt: "", tokens: []), "06000000  0a 00")
    }

    func testOtherLLMRequests() {
        assertBytes(GenAIRequest.llmTokenize("Hi"), "09000000  0a 02 4869")
        // repeated int32, packed: -1 is sign-extended to ten bytes
        assertBytes(GenAIRequest.setEndOfGenerationSequence(tokens: [151_645, -1]),
                    "0d000000  0a 0d  dda009  ffffffffffffffffff01")
        // tokenized_stop_tokens = 1 (0a) { tokens = 1 (0a, packed) }
        assertBytes(GenAIRequest.setStopTokens([[1, 2], [3]]), "0f000000  0a 04 0a 02 0102  0a 03 0a 01 03")
    }

    func testVLMGenerateRequest() {
        // number_of_frames = 1 (08); video_frames_count_per_video = 3 (1a, packed); raw_embeddings = 4 (20)
        assertBytes(GenAIRequest.vlmGenerate(frames: 1), "15000000  08 01")
        assertBytes(GenAIRequest.vlmGenerate(frames: 1, videoFrameCounts: [2, 3], rawEmbeddings: true),
                    "15000000  08 01  1a 02 0203  20 01")
        assertBytes(GenAIRequest.vlmGenerate(frames: 0), "15000000")
    }

    func testSpeechRequests() {
        // group_id = 1 (0a), 25 characters
        assertBytes(GenAIRequest.speechCreate(), "17000000 0a 19" + ascii("FORCE_GET_FIRST_AVAILABLE"))
        // generator_params = 1 (0a) { task_type = 1 (08); language = 2 (12); repetition_penalty = 3 (1d, 1.0 = 3f800000) }
        assertBytes(GenAIRequest.speechGenerate(task: SpeechTask.translate.rawValue, language: "en", repetitionPenalty: 1),
                    "18000000  0a 0b  08 01  12 02 656e  1d 0000803f")
        // Transcribing with automatic language detection: task 0 and the empty language are left out.
        assertBytes(GenAIRequest.speechGenerate(task: SpeechTask.transcribe.rawValue, language: "", repetitionPenalty: 1),
                    "18000000  0a 05  1d 0000803f")
        assertBytes(GenAIRequest.speechTokenize("a"), "1a000000  0a 01 61")
    }

    // MARK: Replies

    private func assertStatus(_ expected: Int32, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case UGenError.deviceStatus(_, let status) = error else {
                return XCTFail("expected a device status, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(status, expected, file: file, line: line)
        }
    }

    private func assertProtocolError(file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case UGenError.client(_, let code) = error else {
                return XCTFail("expected a client error, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(code, Int32(UGEN_ERR_PROTOCOL), file: file, line: line)
        }
    }

    func testStatusReplies() throws {
        // Success is status 0, which proto3 leaves out: the reply is the action id alone.
        XCTAssertNoThrow(try GenAIReply.status(bytes("00000000"), .llmAcquireKVCache, step: ""))
        XCTAssertNoThrow(try GenAIReply.status(bytes("19000000 08 00"), .speechRelease, step: ""))
        // status = 1 (08): 61 is HAILO_NOT_FOUND
        assertStatus(61) { try GenAIReply.status(bytes("17000000 08 3d"), .speechCreate, step: "") }
        // Values above 127 take two bytes: 200 = c8 01
        assertStatus(200) { try GenAIReply.status(bytes("03000000 08 c801"), .llmGeneratorCreate, step: "") }
        // A reply to another request, one that is too short, and one that is cut off.
        assertProtocolError { try GenAIReply.status(bytes("01000000"), .llmAcquireKVCache, step: "") }
        assertProtocolError { try GenAIReply.status(bytes("0000"), .llmAcquireKVCache, step: "") }
        assertProtocolError { try GenAIReply.status(bytes("00000000 08"), .llmAcquireKVCache, step: "") }
    }

    func testCreateReplies() throws {
        // status = 1; prompt_template = 2 (12); embedding_features = 3 (18), 1536 = 80 0c
        XCTAssertEqual(try GenAIReply.llmCreate(bytes("01000000 12 03 616263 18 800c"), step: ""),
                       GenAIReply.Create(promptTemplate: "abc", embeddingFeatures: 1536))
        assertStatus(4) { _ = try GenAIReply.llmCreate(bytes("01000000 08 04"), step: "") }

        // frame_format = 2 (12) { format_order = 1; format_type = 2 }; frame_shape = 3 (1a) { height = 1;
        // width = 2; features = 3 }, 336 = d0 02; prompt_template = 4 (22); embedding_features = 5 (28);
        // image_pad_token_id = 6 (30); video_pad_token_id = 7 (38); embeddings_per_frame = 8 (40), 144 = 90 01
        let reply = bytes("14000000  12 04 0801 1001  1a 08 08d002 10d002 1803  22 01 78  28 800c  30 01  38 02  40 9001")
        XCTAssertEqual(try GenAIReply.vlmCreate(reply, step: ""),
                       GenAIReply.VLMCreate(formatOrder: 1, formatType: 1, height: 336, width: 336, features: 3, promptTemplate: "x",
                                            embeddingFeatures: 1536, imagePadTokenID: 1, videoPadTokenID: 2, embeddingsPerFrame: 144))
        assertStatus(8) { _ = try GenAIReply.vlmCreate(bytes("14000000 08 08"), step: "") }

        // hef_exists = 2 (10)
        XCTAssertTrue(try GenAIReply.hefExists(bytes("16000000 10 01"), step: ""))
        XCTAssertFalse(try GenAIReply.hefExists(bytes("16000000"), step: ""))
    }

    func testGeneratorReplies() throws {
        // generator_params = 1, status = 2 (10)
        let parameters = try GenAIReply.generatorParams(
            bytes("02000000  0a 18  0d 0000003f  15 0000803e  18 14  25 0000c03f  28 8008  30 01  38 07"), step: "")
        XCTAssertEqual(parameters, GenerationParameters(temperature: 0.5, topP: 0.25, topK: 20, frequencyPenalty: 1.5,
                                                        maxGeneratedTokens: 1024, doSample: true, seed: 7))
        assertStatus(2) { _ = try GenAIReply.generatorParams(bytes("02000000 10 02"), step: "") }

        // initial_prefix_tokens = 2, packed (12) and one value per key (10)
        XCTAssertEqual(try GenAIReply.generatorGenerate(bytes("05000000 12 03 01 ac02"), step: ""), [1, 300])
        XCTAssertEqual(try GenAIReply.generatorGenerate(bytes("05000000 10 01 10 ac02"), step: ""), [1, 300])
        XCTAssertEqual(try GenAIReply.generatorGenerate(bytes("05000000"), step: ""), [])

        // generation_output = 1 (0a) { output_token_str = 1; output_token_id = 2 }; generation_status = 2 (10);
        // status = 3 (18); is_context_full = 4 (20)
        XCTAssertEqual(try GenAIReply.generatorRead(bytes("06000000  0a 08 0a 02 4869 10 dda009  10 02  20 01"), step: ""),
                       GenAIReply.Read(text: "Hi", tokenID: 151_645, status: .logicalEnd, isContextFull: true))
        XCTAssertEqual(try GenAIReply.generatorRead(bytes("06000000  0a 02 10 05"), step: ""),
                       GenAIReply.Read(text: "", tokenID: 5, status: .generating, isContextFull: false))
        assertStatus(8) { _ = try GenAIReply.generatorRead(bytes("06000000 18 08"), step: "") }
        // A generation status the client does not know.
        assertProtocolError { _ = try GenAIReply.generatorRead(bytes("06000000 10 09"), step: "") }
    }

    func testOtherLLMReplies() throws {
        // tokens = 1 (0a), status = 2
        XCTAssertEqual(try GenAIReply.llmTokenize(bytes("09000000 0a 03 01 ac02"), step: ""), [1, 300])
        // end_of_generation_sequence = 1; end_of_generation_sequence_tokens = 2; status = 3
        let sequence = try GenAIReply.endOfGenerationSequence(bytes("0e000000 0a 0a" + ascii("<|im_end|>") + "12 03 dda009"), step: "")
        XCTAssertEqual(sequence.text, "<|im_end|>")
        XCTAssertEqual(sequence.tokens, [151_645])
        // stop_tokens = 1 (repeated string); tokenized_stop_tokens = 2 { tokens = 1 }; status = 3
        let stops = try GenAIReply.stopTokens(bytes("10000000 0a 01 61 0a 01 62 12 03 0a 01 05"), step: "")
        XCTAssertEqual(stops.texts, ["a", "b"])
        XCTAssertEqual(stops.tokens, [[5]])
        // status = 1; the count = 2 (10), 2048 = 80 10
        XCTAssertEqual(try GenAIReply.count(bytes("12000000 10 8010"), .llmGetMaxContextCapacity, step: ""), 2048)
        XCTAssertEqual(try GenAIReply.count(bytes("11000000"), .llmGetContextUsageSize, step: ""), 0)
    }

    func testSpeechReplies() throws {
        // generator_params = 2 (12) { task_type = 1; language = 2; repetition_penalty = 3 (1d) }
        XCTAssertEqual(try GenAIReply.speechCreate(bytes("17000000 12 09 12 02 656e 1d 0000803f"), step: ""),
                       GenAIReply.SpeechDefaults(task: 0, language: "en", repetitionPenalty: 1))
        // segments_infos = 2 (12) { start_sec = 1 (0d); end_sec = 2 (15); text = 3 (1a) }; 0.5 = 3f000000,
        // 2.0 = 40000000, 4.0 = 40800000. A start of 0 is left out.
        let reply = bytes("18000000  12 0f 0d 0000003f 15 00000040 1a 03 206869  12 08 15 00008040 1a 01 61")
        let segments = try GenAIReply.speechGenerate(reply, step: "")
        XCTAssertEqual(segments, [SpeechToText.Segment(start: 0.5, end: 2, text: " hi"), SpeechToText.Segment(start: 0, end: 4, text: "a")])
        XCTAssertEqual(segments.text, "hia")
        XCTAssertEqual(try GenAIReply.speechGenerate(bytes("18000000"), step: ""), [])
        assertStatus(2) { _ = try GenAIReply.speechGenerate(bytes("18000000 08 02"), step: "") }
        // tokens = 1, status = 2
        XCTAssertEqual(try GenAIReply.speechTokenize(bytes("1a000000 0a 02 0102"), step: ""), [1, 2])
    }

    func testProtoReaderSkipsUnknownFields() throws {
        // field 9 as 64-bit, field 10 as bytes, then status = 1
        let message = try ProtoMessage(bytes("49 0102030405060708  52 02 aabb  08 07"))
        XCTAssertEqual(message.uint(1), 7)
        XCTAssertThrowsError(try ProtoMessage(bytes("0a 05 00")))   // length runs past the end
        XCTAssertThrowsError(try ProtoMessage(bytes("0b")))          // wire type 3 is not used
    }

    // MARK: HEF transfer plan

    func testTransferPlanOfHandBuiltHEF() throws {
        // ProtoHEFHef: header = 1 (some bytes, ignored), external_resources = 7 (3a) { offset = 1; size = 2; name = 3 }
        let resource = "08 04 10 03 1a 0e" + ascii("tokenizer.json")   // offset 4, size 3
        let proto = bytes("0a 02 0801  3a 14" + resource)
        XCTAssertEqual(proto.count, 26)
        var hef = bytes("01484546 00000003 0000001a")      // magic, version 3, proto size 26
        hef += bytes("0102030405060708")                    // xxh3
        hef += bytes("0000000000000006")                    // weights size with padding: 2 + 4
        hef += bytes("00000002")                            // padding after the proto
        hef += bytes("0000000000000000 0000000000000000 0000000000000000")   // additional info, proto xxh3, reserved
        XCTAssertEqual(hef.count, HEFTransferPlan.headerSize)
        hef += proto + bytes("0000") + bytes("aabbccdd") + bytes("112233")   // proto, padding, weights, tokenizer

        let plan = try HEFTransferPlan(hef: hef)
        XCTAssertEqual(plan.chunks, [
            HEFChunk(name: "header+proto+padding", size: 84, offset: 0),
            HEFChunk(name: "tokenizer.json", size: 3, offset: 88),
            HEFChunk(name: "CCWs", size: 4, offset: 84),
        ])
        XCTAssertEqual(plan.totalSize, 91)
        XCTAssertEqual(plan.hash, "0807060504030201")

        XCTAssertThrowsError(try HEFTransferPlan(hef: Data(repeating: 0, count: 100)))
        XCTAssertThrowsError(try HEFTransferPlan(hef: hef.prefix(86)))   // the tokenizer lies outside
        var old = hef
        old[7] = 2
        XCTAssertThrowsError(try HEFTransferPlan(hef: old))
    }

    func testTransferPlanOfRealHEF() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.smallHEF.path), "yolov8n.hef is missing")
        let hef = try Data(contentsOf: Self.smallHEF)
        let plan = try HEFTransferPlan(hef: hef)
        // From the header as xxd shows it: proto size 0xd8a0, weights with padding 0x6a69e8, padding 0x728,
        // xxh3 37 78 65 80 42 42 69 0a. A vision model has no external resources.
        let zeroPoint: UInt64 = 56 + 0xd8a0 + 0x728
        XCTAssertEqual(plan.chunks, [
            HEFChunk(name: "header+proto+padding", size: zeroPoint, offset: 0),
            HEFChunk(name: "CCWs", size: 0x6a69e8 - 0x728, offset: zeroPoint),
        ])
        XCTAssertEqual(plan.hash, "0a69424280657837")
        XCTAssertEqual(plan.totalSize, UInt64(hef.count))
    }

    // MARK: Chat templates

    /// The chat template of Qwen2.5-Instruct as published with the model.
    static let qwenTemplate = #"""
    {%- if tools %}
        {{- '<|im_start|>system\n' }}
        {%- if messages[0]['role'] == 'system' %}
            {{- messages[0]['content'] }}
        {%- else %}
            {{- 'You are Qwen, created by Alibaba Cloud. You are a helpful assistant.' }}
        {%- endif %}
        {{- "\n\n# Tools\n\nYou may call one or more functions to assist with the user query.\n\nYou are provided with function signatures within <tools></tools> XML tags:\n<tools>" }}
        {%- for tool in tools %}
            {{- "\n" }}
            {{- tool | tojson }}
        {%- endfor %}
        {{- "\n</tools>\n\nFor each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags:\n<tool_call>\n{\"name\": <function-name>, \"arguments\": <args-json-object>}\n</tool_call><|im_end|>\n" }}
    {%- else %}
        {%- if messages[0]['role'] == 'system' %}
            {{- '<|im_start|>system\n' + messages[0]['content'] + '<|im_end|>\n' }}
        {%- else %}
            {{- '<|im_start|>system\nYou are Qwen, created by Alibaba Cloud. You are a helpful assistant.<|im_end|>\n' }}
        {%- endif %}
    {%- endif %}
    {%- for message in messages %}
        {%- if (message.role == "user") or (message.role == "system" and not loop.first) or (message.role == "assistant" and not message.tool_calls) %}
            {{- '<|im_start|>' + message.role + '\n' + message.content + '<|im_end|>' + '\n' }}
        {%- elif message.role == "assistant" %}
            {{- '<|im_start|>' + message.role }}
            {%- if message.content %}
                {{- '\n' + message.content }}
            {%- endif %}
            {%- for tool_call in message.tool_calls %}
                {%- if tool_call.function is defined %}
                    {%- set tool_call = tool_call.function %}
                {%- endif %}
                {{- '\n<tool_call>\n{"name": "' }}
                {{- tool_call.name }}
                {{- '", "arguments": ' }}
                {{- tool_call.arguments | tojson }}
                {{- '}\n</tool_call>' }}
            {%- endfor %}
            {{- '<|im_end|>\n' }}
        {%- elif message.role == "tool" %}
            {%- if (loop.index0 == 0) or (messages[loop.index0 - 1].role != "tool") %}
                {{- '<|im_start|>user' }}
            {%- endif %}
            {{- '\n<tool_response>\n' }}
            {{- message.content }}
            {{- '\n</tool_response>' }}
            {%- if loop.last or (messages[loop.index0 + 1].role != "tool") %}
                {{- '<|im_end|>\n' }}
            {%- endif %}
        {%- endif %}
    {%- endfor %}
    {%- if add_generation_prompt %}
        {{- '<|im_start|>assistant\n' }}
    {%- endif %}
    """#

    /// The chat template of Qwen2-VL-Instruct as published with the model.
    static let qwenVLTemplate = "{% set image_count = namespace(value=0) %}{% set video_count = namespace(value=0) %}"
        + "{% for message in messages %}{% if loop.first and message['role'] != 'system' %}<|im_start|>system\n"
        + "You are a helpful assistant.<|im_end|>\n{% endif %}<|im_start|>{{ message['role'] }}\n"
        + "{% if message['content'] is string %}{{ message['content'] }}<|im_end|>\n{% else %}"
        + "{% for content in message['content'] %}{% if content['type'] == 'image' or 'image' in content or 'image_url' in content %}"
        + "{% set image_count.value = image_count.value + 1 %}{% if add_vision_id %}Picture {{ image_count.value }}: {% endif %}"
        + "<|vision_start|><|image_pad|><|vision_end|>{% elif content['type'] == 'video' or 'video' in content %}"
        + "{% set video_count.value = video_count.value + 1 %}{% if add_vision_id %}Video {{ video_count.value }}: {% endif %}"
        + "<|vision_start|><|video_pad|><|vision_end|>{% elif 'text' in content %}{{ content['text'] }}{% endif %}{% endfor %}<|im_end|>\n"
        + "{% endif %}{% endfor %}{% if add_generation_prompt %}<|im_start|>assistant\n{% endif %}"

    func testQwenChatTemplate() throws {
        let template = try ChatTemplate(Self.qwenTemplate)
        XCTAssertEqual(try template.render(messages: [.system("Be brief."), .user("Hi"), .assistant("Hello."), .user("Bye")],
                                           addGenerationPrompt: true),
                       "<|im_start|>system\nBe brief.<|im_end|>\n<|im_start|>user\nHi<|im_end|>\n"
                           + "<|im_start|>assistant\nHello.<|im_end|>\n<|im_start|>user\nBye<|im_end|>\n<|im_start|>assistant\n")
        XCTAssertEqual(try template.render(messages: [.user("Hi")], addGenerationPrompt: false),
                       "<|im_start|>system\nYou are Qwen, created by Alibaba Cloud. You are a helpful assistant.<|im_end|>\n"
                           + "<|im_start|>user\nHi<|im_end|>\n")
    }

    func testQwenVLChatTemplate() throws {
        let template = try ChatTemplate(Self.qwenVLTemplate)
        XCTAssertEqual(try template.render(messages: [.system("Look."), .user("What is this?", images: 1)], addGenerationPrompt: true),
                       "<|im_start|>system\nLook.<|im_end|>\n<|im_start|>user\n<|vision_start|><|image_pad|><|vision_end|>"
                           + "What is this?<|im_end|>\n<|im_start|>assistant\n")
        XCTAssertEqual(try template.render(messages: [.user("Compare.", images: 2)], addGenerationPrompt: true),
                       "<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n<|im_start|>user\n"
                           + "<|vision_start|><|image_pad|><|vision_end|><|vision_start|><|image_pad|><|vision_end|>"
                           + "Compare.<|im_end|>\n<|im_start|>assistant\n")
    }

    func testPromptHandlerSendsOnlyNewTurnsAfterTheFirst() throws {
        var handler = try PromptTemplateHandler(source: Self.qwenTemplate)
        XCTAssertEqual(try handler.render([.system("Be brief."), .user("Hi")]),
                       "<|im_start|>system\nBe brief.<|im_end|>\n<|im_start|>user\nHi<|im_end|>\n<|im_start|>assistant\n")
        // The stick already holds the system prompt and the first exchange.
        XCTAssertEqual(try handler.render([.user("More")]), "<|im_start|>user\nMore<|im_end|>\n<|im_start|>assistant\n")
        XCTAssertThrowsError(try handler.render([.system("Again"), .user("x")]))
        XCTAssertThrowsError(try handler.render([]))
        handler.reset()
        XCTAssertEqual(try handler.render([.user("Hi")]),
                       "<|im_start|>system\nYou are Qwen, created by Alibaba Cloud. You are a helpful assistant.<|im_end|>\n"
                           + "<|im_start|>user\nHi<|im_end|>\n<|im_start|>assistant\n")

        var vision = try PromptTemplateHandler(source: Self.qwenVLTemplate)
        _ = try vision.render([.user("First", images: 1)])
        XCTAssertEqual(try vision.render([.user("Second", images: 1)]),
                       "<|im_start|>user\n<|vision_start|><|image_pad|><|vision_end|>Second<|im_end|>\n<|im_start|>assistant\n")
    }

    /// The chat template stored in a GenAI model file ("chat_template" in its hailo-config.json part),
    /// which is what the server hands back when the model is created. nil if the file is not there.
    private func storedChatTemplate(_ name: String) throws -> String? {
        guard let url = try? modelFile(name) else { return nil }
        let hef = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let chunk = try HEFTransferPlan(hef: hef).chunks.first(where: { $0.name == "hailo-config.json" }) else { return nil }
        let json = hef.subdata(in: Int(chunk.offset)..<Int(chunk.offset + chunk.size))
        return (try JSONSerialization.jsonObject(with: json) as? [String: Any])?["chat_template"] as? String
    }

    /// The templates of the real model files, when they are present, give the prompts written out here
    /// by hand from the template texts.
    func testChatTemplatesOfModelFiles() throws {
        var checked = 0
        let chatML = "<|im_start|>system\nBe brief.<|im_end|>\n<|im_start|>user\nHi<|im_end|>\n"
            + "<|im_start|>assistant\nHello.<|im_end|>\n<|im_start|>user\nBye<|im_end|>\n<|im_start|>assistant\n"
        let conversation: [ChatMessage] = [.system("Be brief."), .user("Hi"), .assistant("Hello."), .user("Bye")]
        for name in ["Qwen2.5-1.5B-Instruct.hef", "Qwen2.5-Coder-1.5B-Instruct.hef", "Qwen3-1.7B-Instruct.hef", "Qwen2-VL-2B-Instruct.hef"] {
            guard let source = try storedChatTemplate(name) else { continue }
            checked += 1
            XCTAssertEqual(try ChatTemplate(source).render(messages: conversation, addGenerationPrompt: true), chatML, name)
            var handler = try PromptTemplateHandler(source: source)
            _ = try handler.render([.user("Hi")])
            XCTAssertEqual(try handler.render([.user("More")]), "<|im_start|>user\nMore<|im_end|>\n<|im_start|>assistant\n", name)
        }
        for name in ["Qwen2-VL-2B-Instruct.hef", "Qwen3-1.7B-Instruct.hef"] {
            guard let source = try storedChatTemplate(name) else { continue }
            XCTAssertEqual(try ChatTemplate(source).render(messages: [.system("Look."), .user("What is this?", images: 1)], addGenerationPrompt: true),
                           "<|im_start|>system\nLook.<|im_end|>\n<|im_start|>user\n<|vision_start|><|image_pad|><|vision_end|>"
                               + "What is this?<|im_end|>\n<|im_start|>assistant\n", name)
        }
        if let source = try storedChatTemplate("Llama3.2-1B-Instruct.hef") {
            checked += 1
            // The template writes today's date into the system prompt.
            var now = time(nil)
            var parts = tm()
            localtime_r(&now, &parts)
            var buffer = [CChar](repeating: 0, count: 64)
            strftime(&buffer, buffer.count, "%d %b %Y", &parts)
            let header = "<|start_header_id|>system<|end_header_id|>\n\nCutting Knowledge Date: December 2023\n"
                + "Today Date: \(String(cString: buffer))\n\n"
            XCTAssertEqual(try ChatTemplate(source).render(messages: [.system(" Be brief. "), .user("Hi")], addGenerationPrompt: true),
                           header + "Be brief.<|eot_id|><|start_header_id|>user<|end_header_id|>\n\nHi<|eot_id|>"
                               + "<|start_header_id|>assistant<|end_header_id|>\n\n")
            var handler = try PromptTemplateHandler(source: source)
            XCTAssertEqual(try handler.render([.user("Hi")]),
                           header + "<|eot_id|><|start_header_id|>user<|end_header_id|>\n\nHi<|eot_id|>"
                               + "<|start_header_id|>assistant<|end_header_id|>\n\n")
            XCTAssertEqual(try handler.render([.user("More")]),
                           "<|start_header_id|>user<|end_header_id|>\n\nMore<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n")
        }
        try XCTSkipIf(checked == 0, "no GenAI model file is present")
    }

    func testTemplateLanguage() throws {
        func render(_ source: String, _ messages: [ChatMessage] = [.user("Hi")]) throws -> String {
            try ChatTemplate(source).render(messages: messages, addGenerationPrompt: true)
        }
        // Block tags take the newline after them and the indentation before them; output tags do not.
        XCTAssertEqual(try render("a\n  {% if true %}\n  b\n  {% endif %}\nc {{ 1 + 2 }}\n"), "a\n  b\nc 3")
        XCTAssertEqual(try render("x {%- if false %}1{% elif messages | length == 1 %}2{% else %}3{% endif -%} y"), "x2y")
        XCTAssertEqual(try render("{% for m in messages %}{{ loop.index }}/{{ loop.length }}:{{ m.role | upper }}"
                                      + "{% if not loop.last %},{% endif %}{% endfor %}", [.user("a"), .assistant("b")]),
                       "1/2:USER,2/2:ASSISTANT")
        XCTAssertEqual(try render("{{ messages[-1].content ~ '!' if add_generation_prompt else 'no' }}"), "Hi!")
        XCTAssertEqual(try render("{% set ns = namespace(n=0) %}{% for i in range(3) %}{% set ns.n = ns.n + i %}{% endfor %}{{ ns.n }}"), "3")
        XCTAssertEqual(try render("{{ '  a b '.strip().split(' ') | join('-') }} {{ messages[0]['content'][1:] }} {{ missing is defined }}"),
                       "a-b i False")
        XCTAssertEqual(try render("{{ {'a': [1, 'x']} | tojson }}{# a comment #}"), "{\"a\": [1, \"x\"]}")
        XCTAssertEqual(try render("{{ bos_token }}{% if tools %}T{% endif %}{{ 7 // 2 }} {{ 7 % 4 }} {{ 'b' in 'abc' }}"), "3 3 True")
        // What the interpreter does not know is reported, not ignored.
        XCTAssertThrowsError(try ChatTemplate("{% macro m() %}{% endmacro %}"))
        XCTAssertThrowsError(try ChatTemplate("{% if true %}"))
        XCTAssertThrowsError(try render("{{ raise_exception('no') }}"))
    }

    func testGenerationParameterChecks() {
        let good = GenerationParameters(temperature: 0.7, topP: 0.8, topK: 20, frequencyPenalty: 1.1, maxGeneratedTokens: 100, doSample: true)
        XCTAssertNoThrow(try good.validate())
        var bad = good
        bad.temperature = 0
        XCTAssertThrowsError(try bad.validate())
        bad = good
        bad.topP = 1.5
        XCTAssertThrowsError(try bad.validate())
        bad = good
        bad.topK = 0
        XCTAssertThrowsError(try bad.validate())
        bad = good
        bad.frequencyPenalty = 0
        XCTAssertThrowsError(try bad.validate())
    }

    // MARK: Device

    private func requireDevice() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UGEN_DEVICE_TESTS"] == "1",
                          "Set UGEN_DEVICE_TESTS=1 to run on the real stick.")
    }

    /// A GenAI model file that has finished downloading: present, not empty, with no Firefox ".part"
    /// file beside it, and starting with the HEF magic.
    private func modelFile(_ name: String) throws -> URL {
        let folder = Self.root.appendingPathComponent("models")
        let url = folder.appendingPathComponent(name)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        try XCTSkipUnless(size > 0, "\(name) is missing or empty")
        // Firefox names the partial file after the target with a random piece inserted: "Qwen2.Ab12.5-1.5B.hef.part".
        let others = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let partial = others.contains { other in
            guard other.hasSuffix(".part") else { return false }
            let pieces = other.split(separator: ".", omittingEmptySubsequences: false)
            return other == name + ".part" || pieces.indices.contains { index in
                var rest = pieces
                rest.remove(at: index)
                return rest.joined(separator: ".") == name + ".part"
            }
        }
        try XCTSkipIf(partial, "\(name) is still being downloaded")
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try XCTSkipUnless(handle.readData(ofLength: 4) == Data([0x01, 0x48, 0x45, 0x46]), "\(name) is not a HEF")
        return url
    }

    private func connect(_ device: UGenDevice) async throws {
        if try await device.connect() == .loader {
            try await device.bootRuntime(image: Self.root.appendingPathComponent("images/core-image-hailo-hailo10-usb-dongle.ext4"))
        }
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func deviceStatus(_ error: Error) -> Int32? {
        if case UGenError.deviceStatus(_, let status) = error { return status }
        return nil
    }

    /// Every request the LLM and VLM servers answer without a model, then a create request with a HEF
    /// that is not a GenAI model. Requests that would make the server touch a model it does not have
    /// (read, tokenize, clear context, context usage) are left out: the server does not check for that.
    private func exerciseTextServer(_ device: UGenDevice, port: UInt32, name: String, expectedDefaults: GenerationParameters,
                                    create: ([HEFChunk], UInt64) -> Data, createAction: GenAIAction) async throws {
        let session = try await device.openGenAISession(port: port)
        func execute(_ request: Data) async throws -> Data { try await device.genaiExecute(session, step: name, [request]) }

        try GenAIReply.status(try await execute(GenAIRequest.empty(.llmAcquireKVCache)), .llmAcquireKVCache, step: name)
        let hef = try Data(contentsOf: Self.smallHEF, options: .mappedIfSafe)
        let plan = try HEFTransferPlan(hef: hef)
        let exists = try GenAIReply.hefExists(try await execute(GenAIRequest.checkHefExists(path: Self.smallHEF.path, hash: plan.hash)), step: name)
        XCTAssertFalse(exists)

        let defaults = try GenAIReply.generatorParams(try await execute(GenAIRequest.empty(.llmGetGeneratorParams)), step: name)
        print("\(name): default generation parameters without a model: \(defaults)")
        XCTAssertEqual(defaults, expectedDefaults)

        // The server keeps the parameters of the last generator and reports them back.
        let chosen = GenerationParameters(temperature: 0.25, topP: 0.5, topK: 7, frequencyPenalty: 1.5, maxGeneratedTokens: 33,
                                          doSample: false, seed: 12345)
        try GenAIReply.status(try await execute(GenAIRequest.generatorCreate(chosen)), .llmGeneratorCreate, step: name)
        let echoed = try GenAIReply.generatorParams(try await execute(GenAIRequest.empty(.llmGetGeneratorParams)), step: name)
        XCTAssertEqual(echoed, chosen)

        try GenAIReply.status(try await execute(GenAIRequest.empty(.llmGeneratorWrite)), .llmGeneratorWrite, step: name)
        let prefix = try GenAIReply.generatorGenerate(try await execute(GenAIRequest.empty(.llmGeneratorGenerate)), step: name)
        XCTAssertEqual(prefix, [])
        try GenAIReply.status(try await execute(GenAIRequest.empty(.llmGeneratorAbort)), .llmGeneratorAbort, step: name)
        try GenAIReply.status(try await execute(GenAIRequest.empty(.llmGeneratorRelease)), .llmGeneratorRelease, step: name)

        try GenAIReply.status(try await execute(GenAIRequest.setStopTokens([[1, 2], [300]])), .llmSetStopTokens, step: name)
        let stops = try GenAIReply.stopTokens(try await execute(GenAIRequest.empty(.llmGetStopTokens)), step: name)
        XCTAssertEqual(stops.tokens, [[1, 2], [300]])
        XCTAssertEqual(stops.texts, [])   // there is no tokenizer to turn them into text

        try GenAIReply.status(try await execute(GenAIRequest.setEndOfGenerationSequence(tokens: [151_645, 7])),
                              .llmSetEndOfGenerationSequence, step: name)
        let recovery = try GenAIReply.endOfGenerationSequence(try await execute(GenAIRequest.empty(.llmGetEndOfGenerationSequence)), step: name)
        XCTAssertEqual(recovery.tokens, [151_645, 7])
        XCTAssertEqual(recovery.text, "")

        let capacity = try GenAIReply.count(try await execute(GenAIRequest.empty(.llmGetMaxContextCapacity)), .llmGetMaxContextCapacity, step: name)
        print("\(name): context capacity without a model: \(capacity)")

        // The HEF goes up in parts, each acknowledged, and the server then finds that it is no LLM.
        let clock = ContinuousClock()
        let start = clock.now
        let reply = try await device.genaiCreate(session, step: name, request: create(plan.chunks, plan.totalSize), hef: hef, chunks: plan.chunks)
        let status = try GenAIReply.body(reply, createAction, step: name).uint(1)
        print("\(name): create with yolov8n.hef answered status \(status) after \(String(format: "%.1f", seconds(clock.now - start))) s")
        XCTAssertNotEqual(status, 0)
        XCTAssertThrowsError(try GenAIReply.status(reply, createAction, step: name)) { XCTAssertNotNil(self.deviceStatus($0)) }

        // The session still answers.
        let after = try GenAIReply.generatorParams(try await execute(GenAIRequest.empty(.llmGetGeneratorParams)), step: name)
        XCTAssertEqual(after, chosen)
        try GenAIReply.status(try await execute(GenAIRequest.empty(.llmRelease)), .llmRelease, step: name)
        await device.genaiClose(session)
    }

    func testServicesWithoutAModelOnDevice() async throws {
        try requireDevice()
        let device = UGenDevice()
        do {
            try await connect(device)

            // Speech to text: only create and release are safe without a model.
            var session = try await device.openGenAISession(port: UInt32(UGEN_SPEECH_TO_TEXT_PORT))
            let hef = try Data(contentsOf: Self.smallHEF, options: .mappedIfSafe)
            let reply = try await device.genaiExecute(session, step: "speech", [GenAIRequest.speechCreate(), hef],
                                                      timeout: UGenDevice.genaiCreateTimeout)
            let status = try GenAIReply.body(reply, .speechCreate, step: "speech").uint(1)
            print("speech: create with yolov8n.hef answered status \(status)")
            XCTAssertNotEqual(status, 0)
            XCTAssertThrowsError(try GenAIReply.speechCreate(reply, step: "speech")) { XCTAssertNotNil(self.deviceStatus($0)) }
            // The session still answers: a second create fails the same way, and release succeeds.
            let again = try await device.genaiExecute(session, step: "speech", [GenAIRequest.speechCreate(), hef],
                                                      timeout: UGenDevice.genaiCreateTimeout)
            XCTAssertEqual(try GenAIReply.body(again, .speechCreate, step: "speech").uint(1), status)
            try GenAIReply.status(try await device.genaiExecute(session, step: "speech", [GenAIRequest.empty(.speechRelease)]),
                                  .speechRelease, step: "speech")
            await device.genaiClose(session)
            // And it can be opened again.
            session = try await device.openGenAISession(port: UInt32(UGEN_SPEECH_TO_TEXT_PORT))
            await device.genaiClose(session)
            do {
                _ = try await device.genaiExecute(session, step: "speech", [GenAIRequest.empty(.speechRelease)])
                XCTFail("a closed session must not be usable")
            } catch {}

            // What each server starts with before a model sets its own: LLMServer::DEFAULT_GENERATION_* in
            // llm_server.hpp, the VLM server's own (near-greedy) values, and HAILO_RANDOM_SEED.
            let llmDefaults = GenerationParameters(temperature: 0.7, topP: 0.8, topK: 20, frequencyPenalty: 1.1,
                                                   maxGeneratedTokens: 1024, doSample: true, seed: .max)
            let vlmDefaults = GenerationParameters(temperature: 0.01, topP: 0.1, topK: 1, frequencyPenalty: 1.0,
                                                   maxGeneratedTokens: 1024, doSample: false, seed: .max)
            try await exerciseTextServer(device, port: UInt32(UGEN_LLM_PORT), name: "LLM", expectedDefaults: llmDefaults, create: {
                GenAIRequest.llmCreate(chunks: $0, totalSize: $1)
            }, createAction: .llmCreate)
            try await exerciseTextServer(device, port: UInt32(UGEN_VLM_PORT), name: "VLM", expectedDefaults: vlmDefaults, create: {
                GenAIRequest.vlmCreate(chunks: $0, totalSize: $1)
            }, createAction: .vlmCreate)

            // The vision service takes over again.
            let identity = try await device.identify()
            XCTAssertFalse(identity.firmwareVersion.isEmpty)
        } catch {
            await device.disconnect()
            throw error
        }
        await device.disconnect()
    }

    /// The public types report a model the server refuses as a device status, and leave the stick usable.
    func testCreatingWithAVisionModelFailsCleanlyOnDevice() async throws {
        try requireDevice()
        let device = UGenDevice()
        do {
            try await connect(device)
            do {
                _ = try await SpeechToText(hef: Self.smallHEF, device: device)
                XCTFail("a vision model must be refused")
            } catch {
                XCTAssertNotNil(deviceStatus(error), "\(error)")
            }
            do {
                _ = try await ChatModel(hef: Self.smallHEF, device: device)
                XCTFail("a vision model must be refused")
            } catch {
                XCTAssertNotNil(deviceStatus(error), "\(error)")
            }
            let identity = try await device.identify()
            XCTAssertFalse(identity.firmwareVersion.isEmpty)
        } catch {
            await device.disconnect()
            throw error
        }
        await device.disconnect()
    }

    /// Speaks `text` with the Mac's `say` and returns it as mono 16 kHz float samples.
    private func speech(_ text: String) throws -> [Float] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ugenkit-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", file.path, "--data-format=LEI16@16000", text]
        try process.run()
        process.waitUntilExit()
        try XCTSkipUnless(process.terminationStatus == 0, "say could not produce audio")

        // RIFF: find the "data" chunk; the samples are 16-bit little-endian, one channel.
        let wav = [UInt8](try Data(contentsOf: file))
        var position = 12
        while position + 8 <= wav.count {
            let id = String(decoding: wav[position..<position + 4], as: UTF8.self)
            let size = Int(wav[position + 4]) | Int(wav[position + 5]) << 8 | Int(wav[position + 6]) << 16 | Int(wav[position + 7]) << 24
            if id == "data" {
                let end = min(position + 8 + size, wav.count)
                return stride(from: position + 8, to: end - 1, by: 2).map {
                    Float(Int16(bitPattern: UInt16(wav[$0]) | UInt16(wav[$0 + 1]) << 8)) / 32768
                }
            }
            position += 8 + size + (size & 1)
        }
        throw XCTSkip("the audio file from say has no data")
    }

    func testSpeechToTextOnDevice() async throws {
        try requireDevice()
        let hef = try modelFile("Whisper-Base.hef")
        let samples = try speech("The quick brown fox jumps over the lazy dog.")
        let audioSeconds = Double(samples.count) / Double(SpeechToText.sampleRate)
        XCTAssertGreaterThan(audioSeconds, 1)

        let clock = ContinuousClock()
        let device = UGenDevice()
        do {
            try await connect(device)
            var start = clock.now
            let model = try await SpeechToText(hef: hef, device: device)
            let loadSeconds = seconds(clock.now - start)
            XCTAssertGreaterThan(model.defaultRepetitionPenalty, 0)

            func words(_ segments: [SpeechToText.Segment]) -> String {
                segments.text.lowercased().filter { $0.isLetter || $0 == " " }
            }
            // Language detected by the model.
            start = clock.now
            var segments = try await model.transcribe(samples: samples)
            let detectSeconds = seconds(clock.now - start)
            print("speech: \(segments)")
            XCTAssertFalse(segments.isEmpty)
            for word in ["quick", "brown", "fox", "lazy", "dog"] { XCTAssertTrue(words(segments).contains(word), "\(word) in \(segments.text)") }
            for segment in segments {
                XCTAssertGreaterThanOrEqual(segment.start, 0)
                XCTAssertGreaterThan(segment.end, segment.start)
                XCTAssertLessThanOrEqual(segment.end, 30.5)
            }

            // Language given.
            start = clock.now
            segments = try await model.transcribe(samples: samples, language: "en")
            let givenSeconds = seconds(clock.now - start)
            for word in ["quick", "brown", "fox", "lazy", "dog"] { XCTAssertTrue(words(segments).contains(word), "\(word) in \(segments.text)") }

            // Translating English speech gives English text.
            segments = try await model.transcribe(samples: samples, task: .translate, language: "en")
            XCTAssertTrue(words(segments).contains("fox"), segments.text)

            let tokens = try await model.tokenize(" fox")
            XCTAssertFalse(tokens.isEmpty)

            // A language the model does not know is refused with a status, and the model stays usable.
            do {
                _ = try await model.transcribe(samples: samples, language: "not a language")
                XCTFail("an unknown language must be refused")
            } catch {
                XCTAssertNotNil(deviceStatus(error), "\(error)")
            }
            segments = try await model.transcribe(samples: samples, language: "en")
            XCTAssertTrue(words(segments).contains("fox"), segments.text)

            print(String(format: "speech: model load %.1f s; %.2f s of audio: %.2f s with language detection (%.2f s per second of audio), "
                             + "%.2f s with the language given (%.2f s per second of audio)",
                         loadSeconds, audioSeconds, detectSeconds, detectSeconds / audioSeconds, givenSeconds, givenSeconds / audioSeconds))

            await model.release()
            do {
                _ = try await model.transcribe(samples: samples)
                XCTFail("a released model must not be usable")
            } catch {}
            // The stick is free for vision work again.
            _ = try await device.identify()
        } catch {
            await device.disconnect()
            throw error
        }
        await device.disconnect()
    }

    /// Collects a generation and how long the first piece and the whole took.
    private func rate(_ result: (text: String, pieces: Int, first: Double, total: Double)) -> Double {
        Double(max(result.pieces - 1, 0)) / max(result.total - result.first, 0.001)
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> (text: String, pieces: Int, first: Double, total: Double) {
        let clock = ContinuousClock()
        let start = clock.now
        var text = ""
        var pieces = 0
        var first = 0.0
        for try await piece in stream {
            if pieces == 0 { first = seconds(clock.now - start) }
            pieces += 1
            text += piece
        }
        return (text, pieces, first, seconds(clock.now - start))
    }

    private func chat(with name: String) async throws {
        try requireDevice()
        let hef = try modelFile(name)
        let clock = ContinuousClock()
        let device = UGenDevice()
        do {
            try await connect(device)
            let start = clock.now
            let model = try await ChatModel(hef: hef, device: device)
            let loadSeconds = seconds(clock.now - start)
            print("\(name): defaults \(model.defaultParameters)")
            print("\(name): chat template:\n\(model.promptTemplate)")
            XCTAssertFalse(model.promptTemplate.isEmpty)
            let capacity = try await model.maxContextCapacity()
            XCTAssertGreaterThan(capacity, 0)

            var parameters = model.defaultParameters
            parameters.maxGeneratedTokens = 48
            parameters.seed = 1
            try await model.clearContext()
            var result = try await collect(model.generate(
                messages: [.system("You are a helpful assistant. Answer in one short sentence."), .user("What is the capital of France?")],
                parameters: parameters))
            print("\(name): \"\(result.text)\"")
            XCTAssertGreaterThan(result.pieces, 1, "the answer should arrive in pieces")
            XCTAssertTrue(result.text.contains("Paris"), result.text)
            XCTAssertFalse(result.text.contains("<|im_end|>"))
            var end = await model.lastGenerationEnd
            XCTAssertNotNil(end)
            let usage = try await model.contextUsage()
            XCTAssertGreaterThan(usage, 0)
            print(String(format: "\(name): model load %.1f s; first piece after %.2f s; %d pieces in %.2f s; "
                             + "ended with \(String(describing: end)); context \(usage) of \(capacity) tokens",
                         loadSeconds, result.first, result.pieces, result.total))

            // A follow-up turn: only the new message is sent, the stick remembers the rest.
            result = try await collect(model.generate(messages: [.user("And of Italy?")], parameters: parameters))
            print("\(name): follow-up \"\(result.text)\"")
            XCTAssertTrue(result.text.contains("Rome"), result.text)

            // Clearing makes the stick forget: the context shrinks, and a system message is accepted again.
            let before = try await model.contextUsage()
            try await model.clearContext()
            let cleared = try await model.contextUsage()
            print("\(name): context \(before) tokens before clearing, \(cleared) after")
            XCTAssertLessThan(cleared, before)

            // The token limit ends a generation. Long enough to measure the rate after the first piece.
            parameters.maxGeneratedTokens = 64
            result = try await collect(model.generate(messages: [.system("You are a storyteller."), .user("Write a long story about a dragon.")],
                                                      parameters: parameters))
            end = await model.lastGenerationEnd
            XCTAssertEqual(end, .maxTokens)
            XCTAssertLessThanOrEqual(result.pieces, 64)
            print(String(format: "\(name): %d pieces, first after %.2f s, then %.1f per second", result.pieces, result.first, rate(result)))

            // Stopping early aborts on the stick, and the model can be used again.
            parameters.maxGeneratedTokens = 200
            try await model.clearContext()
            var seen = 0
            for try await _ in model.generate(messages: [.user("Write a long story about a dragon.")], parameters: parameters) {
                seen += 1
                if seen == 5 { break }
            }
            for _ in 0..<100 {
                if await model.lastGenerationEnd != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            end = await model.lastGenerationEnd
            XCTAssertEqual(end, .aborted)
            try await model.clearContext()
            parameters.maxGeneratedTokens = 24
            result = try await collect(model.generate(messages: [.user("Say hello.")], parameters: parameters))
            XCTAssertFalse(result.text.isEmpty)

            let tokens = try await model.tokenize("Hello")
            XCTAssertFalse(tokens.isEmpty)
            let recovery = try await model.recoverySequence()
            let stops = try await model.stopTokens()
            print("\(name): recovery sequence \"\(recovery)\", stop tokens \(stops)")

            await model.release()
            _ = try await device.identify()
        } catch {
            await device.disconnect()
            throw error
        }
        await device.disconnect()
    }

    /// Creating a model while another is still on the stick: the new one takes the stick's one session,
    /// which makes the device drop the old model, so nothing has to be released by hand.
    func testReplacingAModelWithoutReleaseOnDevice() async throws {
        try requireDevice()
        let first = try modelFile("Qwen2.5-1.5B-Instruct.hef")
        let second = try modelFile("Qwen2-VL-2B-Instruct.hef")
        let third = try modelFile("Llama3.2-1B-Instruct.hef")
        let device = UGenDevice()
        do {
            try await connect(device)
            let chat = try await ChatModel(hef: first, device: device)
            var parameters = chat.defaultParameters
            parameters.maxGeneratedTokens = 8
            var result = try await collect(chat.generate(messages: [.user("Say hello.")], parameters: parameters))
            XCTAssertFalse(result.text.isEmpty)

            // 2.5 GB is on the stick; the 3.3 GB model goes up without a release.
            let vision = try await VisionChatModel(hef: second, device: device)
            XCTAssertGreaterThan(vision.frameSize, 0)
            do {
                _ = try await collect(chat.generate(messages: [.user("Still there?")], parameters: parameters))
                XCTFail("the replaced model must not be usable")
            } catch {
                print("replaced model: \(error)")
            }
            await chat.release()   // releasing the replaced model must leave the new one alone

            let llama = try await ChatModel(hef: third, device: device)
            parameters = llama.defaultParameters
            parameters.maxGeneratedTokens = 8
            result = try await collect(llama.generate(messages: [.user("Say hello.")], parameters: parameters))
            print("third model without any release: \"\(result.text)\"")
            XCTAssertFalse(result.text.isEmpty)
            // Left on the stick on purpose: disconnecting frees it.
        } catch {
            await device.disconnect()
            throw error
        }
        await device.disconnect()
    }

    func testChatOnDevice() async throws { try await chat(with: "Qwen2.5-1.5B-Instruct.hef") }
    func testCoderChatOnDevice() async throws { try await chat(with: "Qwen2.5-Coder-1.5B-Instruct.hef") }
    func testQwen3ChatOnDevice() async throws { try await chat(with: "Qwen3-1.7B-Instruct.hef") }
    func testLlamaChatOnDevice() async throws { try await chat(with: "Llama3.2-1B-Instruct.hef") }

    func testVisionChatOnDevice() async throws {
        try requireDevice()
        let name = "Qwen2-VL-2B-Instruct.hef"
        let hef = try modelFile(name)
        let imageURL = Self.root.appendingPathComponent("testdata/bus.jpg")
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw XCTSkip("testdata/bus.jpg is missing")
        }
        let clock = ContinuousClock()
        let device = UGenDevice()
        do {
            try await connect(device)
            let start = clock.now
            let model = try await VisionChatModel(hef: hef, device: device)
            let loadSeconds = seconds(clock.now - start)
            print("\(name): image input \(model.frameWidth)x\(model.frameHeight)x\(model.frameChannels), format order \(model.frameFormatOrder), "
                + "type \(model.frameFormatType), \(model.frameSize) bytes; defaults \(model.defaultParameters)")
            print("\(name): chat template:\n\(model.promptTemplate)")
            let frame = try model.prepareFrame(image)
            XCTAssertEqual(frame.count, model.frameSize)

            var parameters = model.defaultParameters
            parameters.maxGeneratedTokens = 64
            parameters.seed = 1
            try await model.clearContext()
            let messages: [ChatMessage] = [
                .system("You are a helpful assistant that analyzes images and answers questions about them."),
                .user("What is in this picture?", images: 1),
            ]
            let result = try await collect(model.generate(messages: messages, frames: [frame], parameters: parameters))
            print("\(name): \"\(result.text)\"")
            XCTAssertGreaterThan(result.pieces, 1)
            XCTAssertTrue(result.text.lowercased().contains("bus"), result.text)
            let end = await model.lastGenerationEnd
            print(String(format: "\(name): model load %.1f s; first piece after %.2f s; %d pieces in %.2f s "
                             + "(%.1f per second after the first); ended with \(String(describing: end))",
                         loadSeconds, result.first, result.pieces, result.total, rate(result)))

            // The number of images has to match the messages, and their size the model.
            do {
                _ = try await collect(model.generate(messages: messages, frames: [], parameters: parameters))
                XCTFail("a missing image must be refused")
            } catch {}
            do {
                _ = try await collect(model.generate(messages: messages, frames: [[1, 2, 3]], parameters: parameters))
                XCTFail("a wrong image size must be refused")
            } catch {}

            await model.release()
            _ = try await device.identify()
        } catch {
            await device.disconnect()
            throw error
        }
        await device.disconnect()
    }
}
