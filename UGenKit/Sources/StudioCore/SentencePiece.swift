import Foundation

/// SentencePiece tokenizers for SigLIP (a unigram model, 32k pieces) and SigLIP 2 (Gemma's BPE model, 256k
/// pieces), read from the JSON that native/tools/clip_assets.py writes from the original `.model` files.
///
/// Matches Hugging Face's tokenizers for these models on normal text (checked on 424 phrases, see
/// SentencePieceTests): SigLIP's `SiglipTokenizer` lowercases, drops ASCII punctuation and encodes "▁" + the
/// words joined by "▁"; Gemma's fast tokenizer replaces spaces with "▁" and merges pairs, best first. Both end
/// with the end-of-text token and pad to the encoder's length. Unknown characters become their UTF-8 bytes
/// (byte fallback). Not covered: Gemma's user-defined pieces (runs of spaces, tabs and HTML tags), because
/// prompts are trimmed and their spaces collapsed first.
public struct SentencePieceTokenizer: Sendable {
    public enum Algorithm: String, Sendable { case unigram, bpe }

    public let algorithm: Algorithm
    /// SigLIP and SigLIP 2 were trained on lowercased text.
    public let lowercase: Bool
    /// SigLIP's tokenizer drops ASCII punctuation (canonicalize_text).
    public let removePunctuation: Bool
    public let endID: Int
    public let padID: Int

    /// Normal pieces by text, with their score (log probability for unigram, merge priority for BPE).
    private let pieces: [String: (id: Int, score: Float)]
    private let byteIDs: [Int]
    private let unknownID: Int
    private let unknownScore: Float
    private let longestPiece: Int

    private struct File: Decodable {
        let algorithm: String
        let pieces: [String]
        let scores: [Float]
        let types: [Int]
        let lowercase: Bool?
        let removePunctuation: Bool?
        let eos: Int
        let pad: Int
    }

    public init(contentsOf url: URL) throws {
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url, options: .mappedIfSafe))
        guard let algorithm = Algorithm(rawValue: file.algorithm), file.pieces.count == file.scores.count, file.pieces.count == file.types.count else {
            throw StudioError.invalidInput("\(url.lastPathComponent) is not a SentencePiece vocabulary.")
        }
        var pieces = [String: (id: Int, score: Float)](minimumCapacity: file.pieces.count)
        var bytes = [Int](repeating: -1, count: 256)
        var unknown = -1, longest = 1
        for (id, piece) in file.pieces.enumerated() {
            switch file.types[id] {
            case 1:   // normal
                pieces[piece] = (id, file.scores[id])
                longest = max(longest, piece.unicodeScalars.count)
            case 2: unknown = id
            case 6:   // "<0x41>"
                if let value = UInt8(piece.dropFirst(3).dropLast(), radix: 16) { bytes[Int(value)] = id }
            default: break   // control, user defined, unused
            }
        }
        guard unknown >= 0, !bytes.contains(-1) else { throw StudioError.invalidInput("\(url.lastPathComponent) has no unknown or byte pieces.") }
        self.algorithm = algorithm
        self.lowercase = file.lowercase ?? false
        self.removePunctuation = file.removePunctuation ?? false
        self.endID = file.eos
        self.padID = file.pad
        self.pieces = pieces
        self.byteIDs = bytes
        self.unknownID = unknown
        // SentencePiece scores an unknown character 10 below the least likely piece.
        self.unknownScore = (pieces.values.map(\.score).min() ?? 0) - 10
        self.longestPiece = longest
    }

    /// Token ids for `text`, ending with the end token and padded with `padID` to `length` (cut to fit).
    public func encode(_ text: String, length: Int) -> [Int] {
        var ids = Array(encodeWithoutPadding(text).prefix(length - 1))
        ids.append(endID)
        return ids + [Int](repeating: padID, count: length - ids.count)
    }

    /// The text's tokens, without end token or padding.
    public func encodeWithoutPadding(_ text: String) -> [Int] {
        var normalized = text
        if lowercase { normalized = normalized.lowercased() }
        if removePunctuation { normalized = String(normalized.unicodeScalars.filter { !Self.asciiPunctuation.contains($0) }.map(Character.init)) }
        let words = normalized.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        switch algorithm {
        case .unigram:
            // SigLIP: NFKC (SentencePiece's nmt_nfkc), "▁" in front of every word.
            return viterbi(Array(("▁" + words.joined(separator: "▁")).precomposedStringWithCompatibilityMapping.unicodeScalars))
        case .bpe:
            // Gemma: no normalisation and no leading "▁"; spaces become "▁".
            return merge(Array(words.joined(separator: "▁").unicodeScalars))
        }
    }

    // MARK: Unigram

    /// The most likely split of `text` into pieces (sum of log probabilities), as SentencePiece's Viterbi.
    private func viterbi(_ text: [Unicode.Scalar]) -> [Int] {
        let n = text.count
        var best = [Float](repeating: -.infinity, count: n + 1)
        var from = [(start: Int, id: Int)](repeating: (0, 0), count: n + 1)
        best[0] = 0
        for start in 0..<n where best[start] > -.infinity {
            var piece = ""
            var singleFound = false
            for end in (start + 1)...min(n, start + longestPiece) {
                piece.unicodeScalars.append(text[end - 1])
                guard let match = pieces[piece] else { continue }
                if end == start + 1 { singleFound = true }
                let score = best[start] + match.score
                if score > best[end] { best[end] = score; from[end] = (start, match.id) }
            }
            // A character no piece starts with is unknown on its own.
            if !singleFound, best[start] + unknownScore > best[start + 1] {
                best[start + 1] = best[start] + unknownScore
                from[start + 1] = (start, unknownID)
            }
        }
        var ids: [Int] = []
        var end = n
        while end > 0 {
            let (start, id) = from[end]
            if id == unknownID {
                ids.append(contentsOf: String(String.UnicodeScalarView(text[start..<end])).utf8.reversed().map { byteIDs[Int($0)] })
            } else {
                ids.append(id)
            }
            end = start
        }
        return ids.reversed()
    }

    // MARK: BPE

    /// Gemma's byte-pair merges: characters (unknown ones as bytes), then repeatedly the adjacent pair whose
    /// joined text is the best-scoring piece, leftmost first.
    private func merge(_ text: [Unicode.Scalar]) -> [Int] {
        var symbols: [String] = []
        var fixed: [Int?] = []   // byte-fallback ids, which never merge
        for scalar in text {
            let character = String(scalar)
            if pieces[character] != nil {
                symbols.append(character); fixed.append(nil)
            } else {
                for byte in character.utf8 { symbols.append(""); fixed.append(byteIDs[Int(byte)]) }
            }
        }
        while symbols.count > 1 {
            var bestIndex = -1
            var bestRank = (score: -Float.infinity, id: Int.max)
            for i in 0..<(symbols.count - 1) where fixed[i] == nil && fixed[i + 1] == nil {
                guard let match = pieces[symbols[i] + symbols[i + 1]] else { continue }
                if match.score > bestRank.score || (match.score == bestRank.score && match.id < bestRank.id) {
                    bestRank = (match.score, match.id)
                    bestIndex = i
                }
            }
            guard bestIndex >= 0 else { break }
            let left = symbols[bestIndex], right = symbols[bestIndex + 1]
            var i = bestIndex
            // Every other occurrence of the same pair to the right merges in the same round.
            while i < symbols.count - 1 {
                if fixed[i] == nil, fixed[i + 1] == nil, symbols[i] == left, symbols[i + 1] == right {
                    symbols[i] = left + right
                    symbols.remove(at: i + 1)
                    fixed.remove(at: i + 1)
                }
                i += 1
            }
        }
        return symbols.indices.map { fixed[$0] ?? pieces[symbols[$0]]?.id ?? unknownID }
    }

    /// Python's string.punctuation.
    private static let asciiPunctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".unicodeScalars)
}
