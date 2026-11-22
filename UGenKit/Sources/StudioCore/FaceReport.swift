import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Face report in two steps, like the UGen300 FACE1 demo: a picture model looks at the face and writes what it
/// sees as JSON; a text model turns those notes into scores and advice; the card adds a pencil sketch of the face.
/// Unlike FACE1, the scores are about the photo and the styling (light, sharpness, framing, expression, how
/// hair, glasses and clothes go together), never about how attractive the face is.
public enum FaceReport {
    // MARK: Step 1: the picture model observes

    public static var observationKeys: [String] { observationHints.map(\.0) }

    /// What each field should say. The template holds hints, not sample values: small picture models copy a
    /// filled-in example word for word (SmolVLM2 returned "navy crew-neck jumper" for a striped top).
    static let observationHints: [(String, String)] = [
        ("face_shape", "round, oval, square, heart or long"), ("eyes", "colour and shape"), ("brows", "thickness and shape"),
        ("nose", "shape"), ("mouth", "lips and whether smiling"), ("skin", "tone and texture"), ("hair", "colour, length, style"),
        ("glasses", "kind, or none"), ("expression", "mood and where the person looks"), ("clothing", "colour and kind of top"),
        ("lighting", "direction and softness"), ("framing", "how much of the person, position"), ("sharpness", "sharp or blurred, where"),
    ]

    public static let observerSystem = """
    You describe a face photo objectively for a style report. Describe only what is visible in THIS photo, in a few \
    neutral words per field. Never judge attractiveness. Output exactly one flat JSON object with these keys and \
    string values, replacing each <hint> with your own words, nothing before or after it:
    {\(observationHints.map { "\"\($0.0)\":\"<\($0.1)>\"" }.joined(separator: ","))}
    """
    public static let observerQuestion = "Describe the face in this photo. Output only the JSON object."

    // MARK: Step 2: the text model scores and writes

    public static let scoreKeys = ["lighting", "sharpness", "framing", "expression", "style"]
    public static let scoreTitles = ["lighting": "Lighting", "sharpness": "Sharpness", "framing": "Framing",
                                     "expression": "Expression", "style": "Style harmony"]
    public static let tipKeys = ["tip_hair", "tip_skincare", "tip_clothing", "tip_photo"]
    public static let tipTitles = ["tip_hair": "Hair", "tip_skincare": "Skin care", "tip_clothing": "Clothing", "tip_photo": "Photo"]

    public static let writerSystem = """
    You are a friendly style and portrait-photo adviser. You get notes about one photo of a person. Score the PHOTO \
    and the STYLING from 0 to 100, never the person's looks: lighting (even, flattering light), sharpness (focus on \
    the eyes), framing (composition, head room), expression (natural, engaged), style (hair, glasses and clothes \
    working together). 50 is ordinary, 90 is excellent; give each its own value from the notes. Then write a short, \
    kind summary, three strengths and four practical tips that fit the notes. Output exactly one flat JSON object \
    with these keys, replacing each <hint>, nothing before or after it:
    {"lighting":<score>,"sharpness":<score>,"framing":<score>,"expression":<score>,"style":<score>,\
    "summary":"<20-30 words>","strength_1":"<...>","strength_2":"<...>","strength_3":"<...>",\
    "tip_hair":"<...>","tip_skincare":"<...>","tip_clothing":"<...>","tip_photo":"<...>"}
    """

    /// The text model's message: the observations, one per line.
    public static func writerMessage(_ observations: [String: String]) -> String {
        let lines = observationKeys.compactMap { key in observations[key].map { "- \(key.replacingOccurrences(of: "_", with: " ")): \($0)" } }
        return "Notes about the photo:\n" + lines.joined(separator: "\n") + "\n\nOutput only the JSON object."
    }

    // MARK: Parsing (forgiving: small models add fences, prose, cut off the end or drop quotes)

    /// The observations found in the picture model's answer (empty when it wrote no JSON fields at all).
    /// Fields the model left as the template's hint are dropped; when most are, nothing is returned.
    public static func parseObservations(_ text: String) -> [String: String] {
        var found: [String: String] = [:]
        var copied = 0
        for (key, hint) in observationHints {
            guard let value = string(key, in: text), !value.isEmpty else { continue }
            if value.hasPrefix("<") || value.lowercased() == hint.lowercased() { copied += 1; continue }
            found[key] = value
        }
        return copied > observationHints.count / 2 ? [:] : found
    }

    public struct Report: Equatable, Sendable {
        /// Scores 0-100 by `scoreKeys`; a score the model did not give is missing (not made up).
        public var scores: [String: Int] = [:]
        public var summary = ""
        public var strengths: [String] = []
        /// (title, tip) in `tipKeys` order.
        public var tips: [(String, String)] = []

        public init() {}

        public static func == (a: Report, b: Report) -> Bool {
            a.scores == b.scores && a.summary == b.summary && a.strengths == b.strengths
                && a.tips.map { $0.0 + "|" + $0.1 } == b.tips.map { $0.0 + "|" + $0.1 }
        }

        /// The mean of the scores given, nil when there are none.
        public var overall: Int? {
            scores.isEmpty ? nil : Int((Double(scores.values.reduce(0, +)) / Double(scores.count)).rounded())
        }

        /// True when the text model gave something usable.
        public var isUsable: Bool { !scores.isEmpty || !summary.isEmpty }

        /// Every score the same (FACE1's check for a model that did not really score): worth another try.
        public var scoresLookCopied: Bool { scores.count >= 3 && Set(scores.values).count == 1 }
    }

    public static func parseReport(_ text: String) -> Report {
        var report = Report()
        for key in scoreKeys {
            if let value = number(key, in: text) { report.scores[key] = min(100, max(0, value)) }
        }
        // A field left as the template's <hint> counts as missing.
        func filled(_ key: String) -> String? { string(key, in: text).flatMap { $0.isEmpty || $0.hasPrefix("<") ? nil : $0 } }
        report.summary = filled("summary") ?? ""
        report.strengths = (1...3).compactMap { filled("strength_\($0)") }
        report.tips = tipKeys.compactMap { key in
            guard let tip = filled(key) else { return nil }
            return (tipTitles[key] ?? key, tip)
        }
        return report
    }

    /// `"key": "value"` (escaped quotes allowed); also an unfinished value at the end of a cut-off answer.
    static func string(_ key: String, in text: String) -> String? {
        let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)(\"|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return text[range].replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `"key": 72`, `"key": "72"`, `"key": <72>` or `"key": 72.5`.
    static func number(_ key: String, in text: String) -> Int? {
        let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*:\\s*[\"<]?(\\d{1,3}(?:\\.\\d+)?)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text), let value = Double(text[range]) else { return nil }
        return Int(value.rounded())
    }

    // MARK: Pictures

    /// The largest face with a margin of a fifth around it (Apple's face detector, on the CPU, so the stick or
    /// engine stays free for the language models). The whole picture when no face is found.
    public static func faceCrop(_ image: CGImage) -> (image: CGImage, found: Bool) {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let face = request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else {
            return (image, false)
        }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        // Vision's boxes are fractions with a bottom-left origin.
        let box = CGRect(x: face.boundingBox.minX * width, y: (1 - face.boundingBox.maxY) * height,
                         width: face.boundingBox.width * width, height: face.boundingBox.height * height)
        let padded = box.insetBy(dx: -box.width * 0.2, dy: -box.height * 0.2)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard let crop = image.cropping(to: padded) else { return (image, false) }
        return (crop, true)
    }

    /// A pencil sketch: grey, inverted, blurred and colour-dodged onto the grey picture (FACE1's sketch.py,
    /// which uses OpenCV's divide; the colour dodge is the same operation).
    public static func pencilSketch(_ image: CGImage, context: CIContext = CIContext()) -> CGImage? {
        let input = CIImage(cgImage: image)
        let grey = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        // FACE1 blurs with a 21-pixel kernel on ~300-pixel crops: about 1.2 % of the side as the blur radius.
        let radius = max(2, Double(max(image.width, image.height)) * 0.012)
        let blurred = grey.applyingFilter("CIColorInvert").clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: input.extent)
        let sketch = blurred.applyingFilter("CIColorDodgeBlendMode", parameters: [kCIInputBackgroundImageKey: grey])
        return context.createCGImage(sketch, from: input.extent)
    }
}
