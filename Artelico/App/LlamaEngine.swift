import Foundation
import llama

/// A GGUF language model running with llama.cpp on this device (GPU through Metal), optionally with an
/// image encoder (mmproj) for questions about pictures.
///
/// Each call to `generate` starts from an empty context and evaluates the whole conversation; chats
/// here are short, and it keeps the engine simple and stateless between messages.
actor LlamaEngine {
    struct Message: Sendable {
        var role: String      // "system", "user" or "assistant"
        var content: String
    }

    struct Parameters: Sendable {
        var maxTokens = 512
        var temperature: Float = 0.7
        var topP: Float = 0.9
        var minP: Float = 0.05
    }

    struct Picture: Sendable {
        var rgb: [UInt8]      // width x height x 3
        var width: Int
        var height: Int
    }

    struct Stats: Sendable {
        var promptTokens = 0
        var promptSeconds = 0.0
        var generatedTokens = 0
        var generationSeconds = 0.0
        var tokensPerSecond: Double { generationSeconds > 0 ? Double(generatedTokens) / generationSeconds : 0 }
    }

    enum Failure: Error, CustomStringConvertible {
        case load(String), evaluate(String), contextFull
        var description: String {
            switch self {
            case .load(let what): return "Could not load \(what)."
            case .evaluate(let what): return "The model failed while \(what)."
            case .contextFull: return "The conversation is longer than the model's memory. Start a new chat."
            }
        }
    }

    let name: String
    let contextLength: Int
    nonisolated let canSeePictures: Bool
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let vision: OpaquePointer?
    private var cancelled = false

    private static let backend: Void = { llama_backend_init() }()

    /// Loads `modelPath` (and `visionPath`, the matching mmproj file, for image questions).
    init(name: String, modelPath: String, visionPath: String? = nil, contextLength: Int = 4096) throws {
        _ = Self.backend
        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0          // the simulator has no usable Metal for this
        #else
        modelParams.n_gpu_layers = 999        // everything on the GPU
        #endif
        guard let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw Failure.load((modelPath as NSString).lastPathComponent)
        }
        let threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextLength)
        contextParams.n_batch = 512
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw Failure.load("a context for \(name)")
        }
        var vision: OpaquePointer?
        if let visionPath {
            var visionParams = mtmd_context_params_default()
            #if targetEnvironment(simulator)
            visionParams.use_gpu = false
            #else
            visionParams.use_gpu = true
            #endif
            visionParams.n_threads = threads
            visionParams.print_timings = false
            vision = mtmd_init_from_file(visionPath, model, visionParams)
            if vision == nil {
                llama_free(context)
                llama_model_free(model)
                throw Failure.load((visionPath as NSString).lastPathComponent)
            }
        }
        self.name = name
        self.contextLength = contextLength
        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
        self.vision = vision
        self.canSeePictures = vision != nil
    }

    deinit {
        if let vision { mtmd_free(vision) }
        llama_free(context)
        llama_model_free(model)
    }

    func cancel() { cancelled = true }

    // MARK: Prompt

    /// The conversation in the model's own chat format (its built-in template, else ChatML).
    private func prompt(_ messages: [Message]) -> String {
        let template = llama_model_chat_template(model, nil)
        let roles = messages.map { strdup($0.role)! }
        let contents = messages.map { strdup($0.content)! }
        defer { roles.forEach { free($0) }; contents.forEach { free($0) } }
        var chat = zip(roles, contents).map { llama_chat_message(role: $0, content: $1) }
        let needed = llama_chat_apply_template(template, &chat, chat.count, true, nil, 0)
        if needed > 0 {
            var buffer = [CChar](repeating: 0, count: Int(needed) + 1)
            let written = llama_chat_apply_template(template, &chat, chat.count, true, &buffer, Int32(buffer.count))
            if written > 0 { return String(cString: buffer) }
        }
        // Unknown template: ChatML, which most instruction-tuned models understand.
        return messages.map { "<|im_start|>\($0.role)\n\($0.content)<|im_end|>\n" }.joined() + "<|im_start|>assistant\n"
    }

    private func tokens(_ text: String, addSpecial: Bool) -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        var result = [llama_token](repeating: 0, count: Int(utf8Count) + 16)
        var count = llama_tokenize(vocab, text, utf8Count, &result, Int32(result.count), addSpecial, true)
        if count < 0 {
            result = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, utf8Count, &result, Int32(result.count), addSpecial, true)
        }
        return Array(result.prefix(Int(max(0, count))))
    }

    private func bytes(of token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(Int(max(0, count))).map { UInt8(bitPattern: $0) }
    }

    // MARK: Generation

    /// The marker that stands for the picture inside a message (put it where the picture belongs).
    nonisolated static var pictureMarker: String { String(cString: mtmd_default_marker()) }

    /// Answers the conversation, calling `onText` with each new piece of text as it is produced.
    func generate(_ messages: [Message], picture: Picture? = nil, parameters: Parameters = Parameters(),
                  onText: @Sendable (String) -> Void) async throws -> Stats {
        cancelled = false
        var stats = Stats()
        llama_memory_clear(llama_get_memory(context), true)
        let text = prompt(messages)
        let clock = ContinuousClock()
        var mark = clock.now
        var position: Int32 = 0

        if let picture, let vision {
            let bitmap = picture.rgb.withUnsafeBufferPointer { mtmd_bitmap_init(UInt32(picture.width), UInt32(picture.height), $0.baseAddress) }
            let chunks = mtmd_input_chunks_init()
            defer { mtmd_bitmap_free(bitmap); mtmd_input_chunks_free(chunks) }
            let status: Int32 = text.withCString { pointer in
                var input = mtmd_input_text(text: pointer, text_len: strlen(pointer), add_special: true, parse_special: true)
                var bitmaps: [OpaquePointer?] = [bitmap]
                return bitmaps.withUnsafeMutableBufferPointer { list in
                    list.baseAddress!.withMemoryRebound(to: OpaquePointer?.self, capacity: 1) {
                        mtmd_tokenize(vision, chunks, &input, UnsafePointer($0), 1)
                    }
                }
            }
            guard status == 0 else { throw Failure.evaluate("reading the picture (code \(status))") }
            var newPosition: llama_pos = 0
            guard mtmd_helper_eval_chunks(vision, context, chunks, 0, 0, 512, true, &newPosition) == 0 else {
                throw Failure.evaluate("reading the picture and question")
            }
            position = newPosition
        } else {
            var input = tokens(text, addSpecial: true)
            guard input.count < contextLength - 8 else { throw Failure.contextFull }
            var start = 0
            while start < input.count {
                let count = min(512, input.count - start)
                let status = input.withUnsafeMutableBufferPointer { buffer in
                    llama_decode(context, llama_batch_get_one(buffer.baseAddress! + start, Int32(count)))
                }
                guard status == 0 else { throw Failure.evaluate("reading the conversation (code \(status))") }
                start += count
            }
            position = Int32(input.count)
        }
        stats.promptTokens = Int(position)
        stats.promptSeconds = seconds(clock.now - mark)
        mark = clock.now

        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        defer { llama_sampler_free(chain) }
        if parameters.temperature <= 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(parameters.topP, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_min_p(parameters.minP, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_temp(parameters.temperature))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
        }

        var pending: [UInt8] = []
        for _ in 0..<parameters.maxTokens {
            if cancelled || Task.isCancelled { break }
            var token = llama_sampler_sample(chain, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            stats.generatedTokens += 1
            // Pieces can end in the middle of a multi-byte character: hold bytes until they decode.
            pending += bytes(of: token)
            if let piece = String(bytes: pending, encoding: .utf8) {
                onText(piece)
                pending = []
            } else if pending.count > 8 {
                onText(String(decoding: pending, as: UTF8.self))
                pending = []
            }
            guard Int(position) + 1 < contextLength else { break }
            let status = llama_decode(context, llama_batch_get_one(&token, 1))
            guard status == 0 else { throw Failure.evaluate("writing the answer (code \(status))") }
            position += 1
            await Task.yield()   // lets cancel() in
        }
        if !pending.isEmpty { onText(String(decoding: pending, as: UTF8.self)) }
        stats.generationSeconds = seconds(clock.now - mark)
        return stats
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
