import Foundation

// CLIP-style zero-shot tagging: text prompts scored against an image.
//
// Port of Hailo's reference app (hailo-apps, pipeline_apps/clip: clip_text_utils.py and
// text_image_matcher.py), extended to every image / text encoder pair of the Model Zoo (CLIPModels.swift).
// Everything here is pure: the caller runs the encoders on the device (`CLIPTagger` does the whole thing).
//
//     let encoder = try CLIPTextEncoder(pair: pair, folder: folder)
//     let (frame, end) = try encoder.input(for: "A photo of a dog")
//     let text = try encoder.embedding(from: device.infer(inputs: [frame], model: pair.text)[0], endPosition: end)
//     ...the image encoder on the picture stretched to its input size...
//     let image = CLIP.imageEmbedding(from: device.infer(inputs: [prepared.rgb], model: pair.image)[0])
//     let scores = CLIP.scores(image: image, prompts: [(text: "dog", embedding: text, negative: false)], scale: pair.logitScale)

// MARK: - Tokenizer

/// CLIP's byte-pair-encoding tokenizer, loaded from a HuggingFace `tokenizers` JSON file.
public struct CLIPTokenizer: Sendable {
    public static let startToken = 49406
    public static let endToken = 49407
    public static let maxLength = 77

    private let vocab: [String: Int]
    /// Merge priority by "left right"; lower merges first.
    private let ranks: [String: Int]
    private let endOfWordSuffix: String
    private let unknownID: Int
    private let startID: Int
    private let endID: Int
    private let special: [String: Int]

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any],
              let vocab = model["vocab"] as? [String: Int],
              let merges = model["merges"] as? [Any] else {
            throw StudioError.invalidInput("Not a tokenizers JSON file with a BPE vocabulary: \(url.lastPathComponent)")
        }
        var ranks = [String: Int](minimumCapacity: merges.count)
        for (rank, merge) in merges.enumerated() {
            // Newer files store ["a", "b"], older ones "a b".
            if let pair = merge as? [String], pair.count == 2 {
                ranks[pair[0] + " " + pair[1]] = rank
            } else if let pair = merge as? String {
                ranks[pair] = rank
            } else {
                throw StudioError.invalidInput("Unreadable merge rule \(rank) in \(url.lastPathComponent)")
            }
        }
        self.vocab = vocab
        self.ranks = ranks
        self.endOfWordSuffix = model["end_of_word_suffix"] as? String ?? "</w>"
        self.startID = vocab["<|startoftext|>"] ?? Self.startToken
        self.endID = vocab["<|endoftext|>"] ?? Self.endToken
        self.unknownID = (model["unk_token"] as? String).flatMap { vocab[$0] } ?? self.endID
        self.special = ["<|startoftext|>": startID, "<|endoftext|>": endID]
    }

    /// Token ids for `text`: start token, the text's tokens, end token; cut to 77 like the reference
    /// (`encoding.ids[:77]`), which can cut the end token off a very long prompt.
    public func encode(_ text: String) -> [Int] {
        // Normalizer: NFC, runs of whitespace to one space, lower case.
        var normalized = text.precomposedStringWithCanonicalMapping
        normalized = Self.whitespace.stringByReplacingMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized), withTemplate: " ")
        normalized = normalized.lowercased()

        var ids = [startID]
        let range = NSRange(normalized.startIndex..., in: normalized)
        Self.splitter.enumerateMatches(in: normalized, range: range) { match, _, _ in
            guard let match, let pieceRange = Range(match.range, in: normalized) else { return }
            let piece = String(normalized[pieceRange])
            if let id = special[piece] {
                ids.append(id)
            } else {
                ids.append(contentsOf: bpe(piece))
            }
        }
        ids.append(endID)
        return Array(ids.prefix(Self.maxLength))
    }

    /// Splits one word into vocabulary tokens by applying the merge rules in rank order.
    private func bpe(_ word: String) -> [Int] {
        // Byte-level alphabet: every UTF-8 byte becomes one character.
        var symbols = word.utf8.map { String(Self.byteAlphabet[Int($0)]) }
        guard !symbols.isEmpty else { return [] }
        symbols[symbols.count - 1] += endOfWordSuffix

        while symbols.count > 1 {
            var bestRank = Int.max
            var bestLeft = "", bestRight = ""
            for i in 0..<(symbols.count - 1) {
                if let rank = ranks[symbols[i] + " " + symbols[i + 1]], rank < bestRank {
                    bestRank = rank
                    bestLeft = symbols[i]
                    bestRight = symbols[i + 1]
                }
            }
            if bestRank == Int.max { break }
            var merged: [String] = []
            merged.reserveCapacity(symbols.count)
            var i = 0
            while i < symbols.count {
                if i + 1 < symbols.count, symbols[i] == bestLeft, symbols[i + 1] == bestRight {
                    merged.append(bestLeft + bestRight)
                    i += 2
                } else {
                    merged.append(symbols[i])
                    i += 1
                }
            }
            symbols = merged
        }
        return symbols.map { vocab[$0] ?? unknownID }
    }

    private static let whitespace = try! NSRegularExpression(pattern: "\\s+")
    /// CLIP's word splitter: special tokens, English contractions, runs of letters, single digits,
    /// runs of anything else that is not whitespace.
    private static let splitter = try! NSRegularExpression(
        pattern: "<\\|startoftext\\|>|<\\|endoftext\\|>|'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+")

    /// GPT-2's byte-to-character table: printable bytes map to themselves, the rest to U+0100 onwards.
    private static let byteAlphabet: [Character] = {
        var table = [Character](repeating: " ", count: 256)
        var next: UInt32 = 256
        for byte in 0..<256 {
            let printable = (33...126).contains(byte) || (161...172).contains(byte) || (174...255).contains(byte)
            if printable {
                table[byte] = Character(Unicode.Scalar(UInt32(byte))!)
            } else {
                table[byte] = Character(Unicode.Scalar(next)!)
                next += 1
            }
        }
        return table
    }()
}

// MARK: - .npy reader

/// A little-endian float32 or float16 array from a NumPy `.npy` file, memory-mapped rather than copied.
/// Rows are handed out as float32 (float16 tables, used for the large token tables, are widened per row).
public struct NPYFloatArray: Sendable {
    public let shape: [Int]
    private let data: Data
    private let offset: Int
    /// Bytes per value: 4 (float32) or 2 (float16).
    private let width: Int

    public var count: Int { shape.reduce(1, *) }
    /// Number of rows (first dimension).
    public var rows: Int { shape.first ?? 1 }
    /// Values per row (product of the remaining dimensions).
    public var rowLength: Int { shape.dropFirst().reduce(1, *) }

    public init(contentsOf url: URL) throws {
        func bad(_ why: String) -> StudioError { .invalidInput("\(url.lastPathComponent): \(why)") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 10, data.prefix(6).elementsEqual([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]) else { throw bad("not a .npy file") }
        let major = data[data.startIndex + 6]
        let headerStart: Int, headerLength: Int
        switch major {
        case 1:
            headerLength = Int(data[data.startIndex + 8]) | Int(data[data.startIndex + 9]) << 8
            headerStart = 10
        case 2, 3:
            guard data.count >= 12 else { throw bad("truncated header") }
            headerLength = (0..<4).reduce(0) { $0 | Int(data[data.startIndex + 8 + $1]) << (8 * $1) }
            headerStart = 12
        default:
            throw bad("unsupported .npy version \(major)")
        }
        guard data.count >= headerStart + headerLength,
              let header = String(data: data.subdata(in: (data.startIndex + headerStart)..<(data.startIndex + headerStart + headerLength)), encoding: .utf8) else {
            throw bad("truncated header")
        }
        func value(after key: String) -> Substring? {
            guard let keyRange = header.range(of: "'\(key)':") else { return nil }
            return header[keyRange.upperBound...].drop { $0 == " " }
        }
        guard let descr = value(after: "descr"), let width = ["'<f4'": 4, "'=f4'": 4, "'<f2'": 2, "'=f2'": 2].first(where: { descr.hasPrefix($0.key) })?.value else {
            throw bad("only little-endian float32 ('<f4') and float16 ('<f2') are supported")
        }
        guard let order = value(after: "fortran_order"), order.hasPrefix("False") else {
            throw bad("only C-ordered arrays are supported")
        }
        guard let shapeText = value(after: "shape"), shapeText.hasPrefix("("), let close = shapeText.firstIndex(of: ")") else {
            throw bad("no shape in header")
        }
        let shape = shapeText[shapeText.index(after: shapeText.startIndex)..<close]
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let offset = headerStart + headerLength
        guard shape.allSatisfy({ $0 >= 0 }), data.count - offset == shape.reduce(1, *) * width else {
            throw bad("data size does not match shape \(shape)")
        }
        self.shape = shape
        self.data = data
        self.offset = offset
        self.width = width
    }

    /// Calls `body` with row `index` of the array (the values of the remaining dimensions, in C order).
    public func withRow<R>(_ index: Int, _ body: (UnsafeBufferPointer<Float>) throws -> R) rethrows -> R {
        precondition(index >= 0 && index < rows, "row out of range")
        let length = rowLength
        return try data.withUnsafeBytes { raw in
            let slice = UnsafeRawBufferPointer(rebasing: raw[(offset + index * length * width)..<(offset + (index + 1) * length * width)])
            if width == 2 {
                let wide = [Float](unsafeUninitializedCapacity: length) { out, initialized in
                    for i in 0..<length { out[i] = Float(Float16(bitPattern: slice.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self))) }
                    initialized = length
                }
                return try wide.withUnsafeBufferPointer(body)
            }
            if Int(bitPattern: slice.baseAddress) % MemoryLayout<Float>.alignment == 0 {
                return try body(slice.bindMemory(to: Float.self))
            }
            let copy = [Float](unsafeUninitializedCapacity: length) { out, initialized in
                UnsafeMutableRawBufferPointer(out).copyMemory(from: slice)
                initialized = length
            }
            return try copy.withUnsafeBufferPointer(body)
        }
    }

    public func row(_ index: Int) -> [Float] { withRow(index) { Array($0) } }
}

/// One prompt's result for an image.
public struct CLIPScore: Sendable, Hashable {
    public let text: String
    /// Softmax over all prompts of the model's logit scale x cosine similarity; the scores of one image sum to 1.
    public let probability: Float
    /// Cosine similarity between the image and the prompt (dot product of the unit vectors).
    public let similarity: Float
    /// A background prompt: it takes probability away from the others but is never reported as a tag.
    public let negative: Bool
}

// MARK: - CLIP

public enum CLIP {
    /// The reference app and Hailo Studio put this in front of every prompt before encoding it.
    public static let promptPrefix = "A photo of a "
    /// The reference matcher's default threshold on the best probability.
    public static let defaultThreshold: Float = 0.8
    /// OpenAI CLIP's logit scale (exp of its trained 4.6052), used by the reference matcher.
    public static let defaultScale: Float = 100
    /// Hailo Studio's default prompts.
    public static let defaultPrompts = ["keyboard", "spinner", "Raspberry Pi", "unicorn mouse pad", "-wooden desk"]

    /// Splits what the user typed into the prompt text and whether it is a background prompt
    /// (it starts with "-"), as Hailo Studio does. Returns nil for an empty prompt.
    public static func parsePrompt(_ prompt: String) -> (text: String, negative: Bool)? {
        let negative = prompt.hasPrefix("-")
        let text = (negative ? String(prompt.dropFirst()) : prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (text, negative)
    }

    /// The text encoder's input frame: each token id's row of the embedding table, quantized to the model's
    /// UINT16 input (the encoders start after the token lookup; the position embedding is added on the chip).
    /// `ids` is cut or padded with id 0 to the model's length. Padding after CLIP's end token does not change
    /// its output (causal attention); SigLIP's ids come padded already.
    public static func textFrame(ids: [Int], tokenEmbeddings: NPYFloatArray, model: ModelInfo) throws -> [UInt8] {
        guard let input = model.inputs.first, input.type == "UINT16" else {
            throw StudioError.invalidInput("\(model.name) is not a CLIP text encoder (it needs one UINT16 input).")
        }
        let length = input.width ?? CLIPTokenizer.maxLength
        let size = input.features ?? tokenEmbeddings.rowLength
        guard tokenEmbeddings.shape.count == 2, tokenEmbeddings.rowLength == size, input.frameSize == length * size * 2 else {
            throw StudioError.invalidInput("Token embedding table \(tokenEmbeddings.shape) does not fit \(model.name)'s input (\(length) x \(size)).")
        }
        var ids = Array(ids.prefix(length))
        ids += [Int](repeating: 0, count: length - ids.count)
        guard ids.allSatisfy({ $0 >= 0 && $0 < tokenEmbeddings.rows }) else {
            throw StudioError.invalidInput("The tokenizer produced an id outside the embedding table.")
        }

        // raw = round(value / scale + zero point), clamped to the UINT16 range (HailoRT's quantization).
        let zeroPoint = input.qpZp ?? 0
        let scale = input.qpScale ?? 1
        var frame = [UInt8](repeating: 0, count: input.frameSize)
        for (position, id) in ids.enumerated() {
            tokenEmbeddings.withRow(id) { row in
                var out = position * size * 2
                for value in row {
                    let raw = UInt16(min(max((value / scale + zeroPoint).rounded(.toNearestOrEven), 0), 65535))
                    frame[out] = UInt8(raw & 0xFF)
                    frame[out + 1] = UInt8(raw >> 8)
                    out += 2
                }
            }
        }
        return frame
    }

    /// A CLIP prompt's unit-length embedding: the text encoder's output row at the end-of-text position, through
    /// the final layer norm when the encoder stops before it (`finalNorm`: weight row, bias row; TinyCLIP),
    /// multiplied by the text projection (row vector x matrix) and L2-normalized.
    public static func textEmbedding(from output: Tensor, endPosition: Int, projection: NPYFloatArray,
                                     finalNorm: NPYFloatArray? = nil) throws -> [Float] {
        let size = output.features
        guard projection.shape.count == 2, projection.shape[0] == size else {
            throw StudioError.invalidInput("Text projection \(projection.shape) does not fit an encoder output of \(size) features.")
        }
        let values = output.floats()
        guard endPosition >= 0, (endPosition + 1) * size <= values.count else {
            throw StudioError.invalidInput("End position \(endPosition) is outside the encoder output.")
        }
        var state = Array(values[(endPosition * size)..<((endPosition + 1) * size)])
        if let finalNorm {
            guard finalNorm.shape == [2, size] else { throw StudioError.invalidInput("Final norm \(finalNorm.shape) does not fit \(size) features.") }
            state = layerNorm(state, weight: finalNorm.row(0), bias: finalNorm.row(1))
        }
        let outSize = projection.shape[1]
        var projected = [Float](repeating: 0, count: outSize)
        for i in 0..<size {
            let weight = state[i]
            projection.withRow(i) { row in
                for j in 0..<outSize { projected[j] += weight * row[j] }
            }
        }
        return normalized(projected)
    }

    /// PyTorch's LayerNorm (epsilon 1e-5) over one vector.
    static func layerNorm(_ x: [Float], weight: [Float], bias: [Float]) -> [Float] {
        let mean = x.reduce(0, +) / Float(x.count)
        let variance = x.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(x.count)
        let scale = 1 / (variance + 1e-5).squareRoot()
        return x.indices.map { (x[$0] - mean) * scale * weight[$0] + bias[$0] }
    }

    /// The image's (or a SigLIP prompt's) unit-length embedding from the encoder's output.
    public static func imageEmbedding(from output: Tensor) -> [Float] {
        normalized(output.floats())
    }

    /// The reference matcher's scores: the dot product of the image with every prompt, times `scale` (the
    /// model's logit scale; 100 for OpenAI CLIP), through a softmax over all prompts (background prompts included).
    public static func scores(image: [Float], prompts: [(text: String, embedding: [Float], negative: Bool)], scale: Float = defaultScale) -> [CLIPScore] {
        guard !prompts.isEmpty else { return [] }
        let similarities = prompts.map { prompt -> Double in
            var sum = 0.0
            for i in 0..<min(image.count, prompt.embedding.count) { sum += Double(image[i]) * Double(prompt.embedding[i]) }
            return sum
        }
        // exp(scale d) / sum, computed relative to the largest so nothing overflows.
        let top = similarities.max() ?? 0
        let weights = similarities.map { exp(Double(scale) * ($0 - top)) }
        let total = weights.reduce(0, +)
        return prompts.indices.map {
            CLIPScore(text: prompts[$0].text, probability: Float(weights[$0] / total), similarity: Float(similarities[$0]), negative: prompts[$0].negative)
        }
    }

    /// The tag to show for an image, as the reference decides it: the highest-probability prompt,
    /// unless that is a background prompt or its probability is not above `threshold`.
    public static func bestMatch(_ scores: [CLIPScore], threshold: Float = defaultThreshold) -> CLIPScore? {
        guard let best = scores.max(by: { $0.probability < $1.probability }) else { return nil }
        return best.negative || !(best.probability > threshold) ? nil : best
    }

    /// Scores as a result list: background prompts as "not: <prompt>", each with its prompt's index in `prompts`.
    public static func classifications(_ scores: [CLIPScore], prompts: [String]) -> [Classification] {
        scores.map { score in
            Classification(label: (score.negative ? "not: " : "") + score.text,
                           classIndex: prompts.firstIndex(of: score.text) ?? 0, probability: score.probability)
        }
    }

    /// v / (|v| + 1e-8), as the reference normalizes text embeddings.
    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot() + 1e-8
        return vector.map { $0 / norm }
    }
}
