import Foundation

// Text rules for the language examples (Calories, OfflineCode, Meeting notes, Outfit advisor, Fridge chef,
// Face report), ported from the UGen300 demos. Pure text in and out; the models run in the app.

// MARK: - Calories

public enum Nutrition {
    public struct Item: Codable, Equatable, Sendable {
        public var item: String
        public var portion: String
        public var kcal: Int
        public var proteinGrams: Int

        public init(item: String, portion: String = "", kcal: Int = 0, proteinGrams: Int = 0) {
            self.item = item; self.portion = portion; self.kcal = kcal; self.proteinGrams = proteinGrams
        }
    }

    /// The demo's prompt, in English.
    public static let prompt = """
    You are a nutritionist. Identify every food or drink in the photo and estimate the portion, the calories (kcal) and the protein (grams). \
    Output only a JSON array with the keys item, portion, kcal, protein_g, all in double quotes, and no other text. \
    Example: [{"item":"chicken rice","portion":"1 bowl","kcal":550,"protein_g":18},{"item":"bubble tea","portion":"700 ml","kcal":480,"protein_g":6}]. \
    If there is no food in the photo, output [].
    """

    static let aliases: [String: String] = {
        let table: [String: [String]] = [
            "item": ["item", "name", "food", "品名", "名稱", "食物", "品項", "菜名", "dish"],
            "portion": ["portion", "serving", "amount", "份量", "分量", "量", "數量", "size"],
            "kcal": ["kcal", "calories", "calorie", "energy", "熱量", "卡路里", "大卡"],
            "protein_g": ["protein_g", "protein", "蛋白質", "蛋白质"],
        ]
        var out: [String: String] = [:]
        for (key, names) in table { for name in names { out[name] = key } }
        return out
    }()

    /// The first number in the value, rounded half to even like Python's round(); `default` when there is none.
    static func integer(_ value: Any?, default fallback: Int = 0) -> Int {
        switch value {
        case let n as NSNumber:
            // JSON true/false are NSNumbers too; like the demo, they are not amounts.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return fallback }
            return Int(n.doubleValue.rounded(.toNearestOrEven))
        case let s as String:
            guard let r = s.range(of: "-?\\d+(?:\\.\\d+)?", options: .regularExpression), let d = Double(s[r]) else { return fallback }
            return Int(d.rounded(.toNearestOrEven))
        default: return fallback
        }
    }

    static func normalizeJSONText(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "```(?:json)?", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "'", with: "\"")
        // Unquoted keys:  {portion:"x"  or  , kcal:12
        t = t.replacingOccurrences(of: "([{,]\\s*)([A-Za-z_][\\w]*|[\\u4e00-\\u9fff]+)\\s*:", with: "$1\"$2\":", options: .regularExpression)
        // Stray plus signs:  "kcal": +14
        t = t.replacingOccurrences(of: ":\\s*\\+(\\d)", with: ": $1", options: .regularExpression)
        return t
    }

    static func item(from dictionary: [String: Any]) -> Item? {
        var out = Item(item: "")
        for (key, value) in dictionary {
            let k = key.trimmingCharacters(in: .whitespaces)
            switch aliases[k.lowercased()] ?? aliases[k] {
            case "item": out.item = "\(value)".trimmingCharacters(in: .whitespaces)
            case "portion": out.portion = "\(value)".trimmingCharacters(in: .whitespaces)
            case "kcal": out.kcal = max(0, integer(value))
            case "protein_g": out.proteinGrams = max(0, integer(value))
            default: break
            }
        }
        return out.item.isEmpty ? nil : out
    }

    /// Food items from a model's answer, as forgiving as the demo: fences, single quotes, unquoted keys,
    /// trailing commas, other key names, and a cut-off array (the complete objects are kept).
    public static func parseItems(_ text: String) -> [Item] {
        guard !text.isEmpty else { return [] }
        let s = normalizeJSONText(text)
        guard let objects = try? NSRegularExpression(pattern: "\\{[^{}]*\\}") else { return [] }
        var items: [Item] = []
        for match in objects.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let range = Range(match.range, in: s) else { continue }
            let chunk = String(s[range]).replacingOccurrences(of: ",\\s*\\}", with: "}", options: .regularExpression)
            var dictionary = (try? JSONSerialization.jsonObject(with: Data(chunk.utf8))) as? [String: Any]
            if dictionary == nil, let pairs = try? NSRegularExpression(pattern: "\"([^\"]+)\"\\s*:\\s*\"?([^\",}]*)\"?") {
                var found: [String: Any] = [:]
                for m in pairs.matches(in: chunk, range: NSRange(chunk.startIndex..., in: chunk)) {
                    if let k = Range(m.range(at: 1), in: chunk), let v = Range(m.range(at: 2), in: chunk) { found[String(chunk[k])] = String(chunk[v]) }
                }
                dictionary = found
            }
            if let dictionary, let item = item(from: dictionary) { items.append(item) }
        }
        return items
    }

    public static func totals(_ items: [Item]) -> (kcal: Int, proteinGrams: Int) {
        (items.reduce(0) { $0 + $1.kcal }, items.reduce(0) { $0 + $1.proteinGrams })
    }

    /// Today's meals, kept in a file; a new day starts empty.
    public struct DailyLog: Codable, Sendable {
        public struct Meal: Codable, Sendable {
            public var items: [Item]
            public var kcal: Int
            public var proteinGrams: Int
            public var time: Date
        }

        public var date: String
        public var meals: [Meal] = []

        static func today(_ now: Date = Date()) -> String {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: now)
        }

        public static func load(_ url: URL, now: Date = Date()) -> DailyLog {
            if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(DailyLog.self, from: data), saved.date == today(now) {
                return saved
            }
            return DailyLog(date: today(now))
        }

        public mutating func add(_ items: [Item], at time: Date = Date(), saveTo url: URL?) {
            let t = Nutrition.totals(items)
            meals.append(Meal(items: items, kcal: t.kcal, proteinGrams: t.proteinGrams, time: time))
            if let url { save(url) }
        }

        public mutating func clear(saveTo url: URL?) { meals = []; if let url { save(url) } }

        public var kcal: Int { meals.reduce(0) { $0 + $1.kcal } }
        public var proteinGrams: Int { meals.reduce(0) { $0 + $1.proteinGrams } }

        public func save(_ url: URL) {
            if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
        }
    }
}

// MARK: - OfflineCode

public enum CodeBlocks {
    public enum Segment: Equatable, Sendable {
        case text(String)
        case code(language: String, code: String)
    }

    static let aliases = ["py": "python", "python3": "python", "js": "javascript", "node": "javascript", "sh": "bash", "shell": "bash", "": "text"]

    /// Text and fenced code blocks of a Markdown answer. A fence that is not closed yet (still streaming)
    /// is returned as code too.
    public static func split(_ answer: String) -> [Segment] {
        let text = answer.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard let fence = try? NSRegularExpression(pattern: "```[ \\t]*([A-Za-z0-9_+#.-]*)[ \\t]*\\n") else { return [.text(text)] }
        var out: [Segment] = []
        var position = text.startIndex
        while true {
            let searchRange = NSRange(position..., in: text)
            guard let m = fence.firstMatch(in: text, range: searchRange), let whole = Range(m.range, in: text), let langRange = Range(m.range(at: 1), in: text) else {
                let rest = String(text[position...])
                if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(rest)) }
                break
            }
            let before = String(text[position..<whole.lowerBound])
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(before)) }
            let raw = text[langRange].lowercased()
            let language = aliases[raw] ?? raw
            guard let end = text.range(of: "```", range: whole.upperBound..<text.endIndex) else {
                out.append(.code(language: language, code: String(text[whole.upperBound...])))
                break
            }
            var code = String(text[whole.upperBound..<end.lowerBound])
            while code.hasSuffix("\n") { code.removeLast() }
            out.append(.code(language: language, code: code))
            position = end.upperBound
        }
        return out
    }

    public static func blocks(_ answer: String) -> [(language: String, code: String)] {
        split(answer).compactMap { if case .code(let l, let c) = $0 { return (l, c) } else { return nil } }
    }

    /// The last code block, preferring the given languages; nil when there is none.
    public static func last(_ answer: String, prefer: [String] = ["javascript"]) -> (language: String, code: String)? {
        let all = blocks(answer)
        for language in prefer {
            if let found = all.last(where: { $0.language == language && !$0.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { return found }
        }
        return all.last
    }

    /// The answer's text with each code block replaced by a short note (the code is shown on its own).
    /// A fence still arriving at the very end is hidden instead of flashing.
    public static func textOnly(_ answer: String) -> String {
        var t = answer
        if let r = t.range(of: "\n```[A-Za-z0-9_+#.-]*$", options: .regularExpression) { t.removeSubrange(r) }
        return split(t).map { segment -> String in
            switch segment {
            case .text(let s): return s
            case .code(let language, _): return "[\(language) code → shown on the right]"
            }
        }.joined(separator: "\n").replacingOccurrences(of: "\n\n+", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Meeting notes

public enum MeetingNotes {
    public static let system = """
    You are a professional meeting-notes assistant.

    Strict rules:
    (1) Write in the same language as the transcript. Use clear, correct words.
    (2) Always follow the example's fixed format. Section order must be "Key Points -> Action Items -> Decisions". Do not change the section names.
    (3) If a field has no information, write "Not mentioned". Never invent facts or names.
    (4) No greetings, no closing remarks, no self-comments. Output the three sections directly.
    """

    public static let exampleTranscript = """
    Okay, today we mainly discuss the Q4 marketing budget. First, please have John submit the KPI report by the end of October. \
    Second, for social, we decided to pause LinkedIn ads and focus on Instagram. Third, keep the total budget under five hundred \
    thousand this quarter. OK, meeting adjourned.
    """

    public static let exampleOutput = """
    Key Points:
    - Discussed Q4 marketing budget allocation.
    - Confirmed KPI report delivery schedule.
    - Decided social ad platform strategy.

    Action Items:
    - Owner: John  Task: Submit KPI report  Deadline: end of October

    Decisions:
    - Pause LinkedIn ads, focus social budget on Instagram.
    - Total Q4 budget capped at five hundred thousand.
    """

    public static func userMessage(_ transcript: String) -> String {
        """
        Example:
        ----- Example transcript -----
        \(exampleTranscript)
        ----- Example output -----
        \(exampleOutput)

        Now summarize the following transcript using the EXACT same format (Key Points, Action Items, Decisions):
        ----- Transcript -----
        \(transcript)
        """
    }

    /// A usable summary has some length and the three section headings (the demo reruns otherwise).
    public static func looksValid(_ summary: String) -> Bool {
        let s = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 20 else { return false }
        return ["key points", "action items", "decisions"].allSatisfy { s.lowercased().contains($0) }
    }
}

// MARK: - Shared

public enum ModelText {
    /// Removes Qwen3's <think>…</think> part (also an unfinished one at the end).
    public static func withoutThinking(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
        if let open = t.range(of: "<think>") { t = String(t[..<open.lowerBound]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
