import Foundation

/// BERT's WordPiece tokenizer (uncased), as used by all-MiniLM-L6-v2: lower-case, strip accents, split
/// on whitespace and punctuation, then break each word into the longest pieces found in the vocabulary
/// ("##" marks a piece inside a word). Matches Hugging Face's BertTokenizer for plain text.
struct WordPieceTokenizer {
    let vocabulary: [String: Int32]
    let unknown: Int32
    let start: Int32   // [CLS]
    let end: Int32     // [SEP]
    let padding: Int32 // [PAD]

    init(vocabularyFile: URL) throws {
        let lines = try String(contentsOf: vocabularyFile, encoding: .utf8).components(separatedBy: "\n")
        var map: [String: Int32] = [:]
        for (index, token) in lines.enumerated() where !token.isEmpty { map[token] = Int32(index) }
        vocabulary = map
        unknown = map["[UNK]"] ?? 100
        start = map["[CLS]"] ?? 101
        end = map["[SEP]"] ?? 102
        padding = map["[PAD]"] ?? 0
    }

    /// Token ids with [CLS] ... [SEP], cut or padded to `length`, and the matching attention mask.
    func encode(_ text: String, length: Int) -> (ids: [Int32], mask: [Int32]) {
        var ids: [Int32] = [start]
        for word in basicTokens(text) {
            ids += pieces(word)
            if ids.count >= length - 1 { break }
        }
        ids = Array(ids.prefix(length - 1)) + [end]
        let mask = [Int32](repeating: 1, count: ids.count) + [Int32](repeating: 0, count: length - ids.count)
        ids += [Int32](repeating: padding, count: length - ids.count)
        return (ids, mask)
    }

    /// Lower-cased, accent-free words with punctuation as separate tokens.
    private func basicTokens(_ text: String) -> [String] {
        let folded = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        var tokens: [String] = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else if CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar) {
                if !current.isEmpty { tokens.append(current); current = "" }
                tokens.append(String(scalar))
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Greedy longest-match WordPiece; a word that cannot be split becomes [UNK].
    private func pieces(_ word: String) -> [Int32] {
        let characters = Array(word)
        if characters.count > 100 { return [unknown] }
        var result: [Int32] = []
        var startIndex = 0
        while startIndex < characters.count {
            var endIndex = characters.count
            var found: Int32?
            while startIndex < endIndex {
                var piece = String(characters[startIndex..<endIndex])
                if startIndex > 0 { piece = "##" + piece }
                if let id = vocabulary[piece] { found = id; break }
                endIndex -= 1
            }
            guard let id = found else { return [unknown] }
            result.append(id)
            startIndex = endIndex
        }
        return result
    }
}
