import CoreGraphics
import Foundation

/// An image encoder and the text encoder trained with it, for tagging from text.
public struct CLIPPair: Sendable, Hashable {
    public enum Family: Sendable, Hashable {
        /// OpenAI CLIP, OpenCLIP (LAION) and TinyCLIP: CLIP's BPE tokenizer, 77 tokens, the end token's output
        /// row through the text projection.
        case clip
        /// SigLIP: SentencePiece (unigram), 64 tokens; the encoder's head gives the embedding.
        case siglip
        /// SigLIP 2: Gemma's SentencePiece (BPE), 64 tokens; the encoder's head gives the embedding.
        case siglip2
    }

    public let image: String
    public let text: String
    public let family: Family
    /// The model's trained logit scale (exp), which sharpens the softmax over prompts.
    public let logitScale: Float
    /// Hailo's compiled encoder stops before the final layer norm, which then runs here (TinyCLIP).
    public var textNeedsFinalNorm: Bool { text.hasPrefix("tinyclip_") }
    /// False when the UGen300 stick cannot configure both encoders together (clip_vit_l_14_laion2B: hailo_status
    /// 81, either order; each alone works): the stick then runs the text encoder for the prompts first and
    /// keeps only the image encoder loaded.
    public var stickLoadsBoth: Bool { image != "clip_vit_l_14_laion2B_image_encoder" }

    /// Files next to the text encoder that the prompts need (native/tools/clip_assets.py makes them; the apps
    /// download them with the model). The CLIP and SigLIP tokenizers are bundled (StudioCore Resources).
    public var textFiles: [String] {
        var files = ["\(text).tokens.npy"]
        switch family {
        case .clip: files.append("\(text).projection.npy")
        case .siglip: break
        case .siglip2: files.append("\(text).tokenizer.json")
        }
        if textNeedsFinalNorm { files.append("\(text).final_norm.npy") }
        return files
    }
}

public enum CLIPModels {
    /// Every image encoder with its text encoder. The Model Zoo has no text encoder for CLIP ViT-L/14 at
    /// 336 pixels: it takes ViT-L/14's (224 pixels), from which OpenAI fine-tuned it; their text towers differ
    /// slightly. siglip2_b_16_text_encoder and siglip2_l_16_256_text_encoder have no image encoder in the Zoo.
    public static let pairs: [CLIPPair] = [
        CLIPPair(image: "clip_vit_b_32_image_encoder", text: "clip_vit_b_32_text_encoder", family: .clip, logitScale: 100),
        CLIPPair(image: "clip_vit_b_16_image_encoder", text: "clip_vit_b_16_text_encoder", family: .clip, logitScale: 100),
        CLIPPair(image: "clip_resnet_50_image_encoder", text: "clip_resnet_50_text_encoder", family: .clip, logitScale: 100),
        CLIPPair(image: "clip_resnet_50x4_image_encoder", text: "clip_resnet_50x4_text_encoder", family: .clip, logitScale: 100),
        CLIPPair(image: "clip_vit_l_14_336_image_encoder", text: "clip_vit_l_14_text_encoder", family: .clip, logitScale: 100),
        CLIPPair(image: "clip_vit_l_14_laion2B_image_encoder", text: "clip_vit_l_14_laion2B_text_encoder", family: .clip, logitScale: 100),
        // TinyCLIP's checkpoints keep logit_scale = ln 50.
        CLIPPair(image: "tinyclip_vit_8m_16_text_3m_yfcc15m_image_encoder", text: "tinyclip_vit_8m_16_text_3m_yfcc15m_text_encoder", family: .clip, logitScale: 50),
        CLIPPair(image: "tinyclip_vit_39m_16_text_19m_yfcc15m_image_encoder", text: "tinyclip_vit_39m_16_text_19m_yfcc15m_text_encoder", family: .clip, logitScale: 50),
        CLIPPair(image: "tinyclip_vit_40m_32_text_19m_laion400m_image_encoder", text: "tinyclip_vit_40m_32_text_19m_laion400m_text_encoder", family: .clip, logitScale: 50),
        CLIPPair(image: "tinyclip_vit_61m_32_text_29m_laion400m_image_encoder", text: "tinyclip_vit_61m_32_text_29m_laion400m_text_encoder", family: .clip, logitScale: 50),
        // exp(logit_scale) of google/siglip-base-patch16-224, siglip-large-patch16-256, siglip2-base-patch32-256.
        CLIPPair(image: "siglip_b_16_image_encoder", text: "siglip_b_16_text_encoder", family: .siglip, logitScale: 117.3),
        CLIPPair(image: "siglip_l_16_256_image_encoder", text: "siglip_l_16_256_text_encoder", family: .siglip, logitScale: 110.0),
        CLIPPair(image: "siglip2_b_32_256_image_encoder", text: "siglip2_b_32_256_text_encoder", family: .siglip2, logitScale: 111.8),
    ]

    public static func pair(forImage name: String) -> CLIPPair? { pairs.first { $0.image == name } }
    public static func pair(forText name: String) -> CLIPPair? { pairs.first { $0.text == name } }

    /// Hailo's own copies of clip_vit_b_32's tables (float32), which apps fall back to when a file is not
    /// in the model repository.
    public static func fallbackAddress(for file: String) -> URL? {
        switch file {
        case "clip_vit_b_32_text_encoder.tokens.npy": return URL(string: "https://hailo-csdata.s3.eu-west-2.amazonaws.com/resources/npy/token_embedding_lut.npy")
        case "clip_vit_b_32_text_encoder.projection.npy": return URL(string: "https://hailo-csdata.s3.eu-west-2.amazonaws.com/resources/npy/text_projection.npy")
        default: return nil
        }
    }

    /// The pair's text files not in `folder` yet.
    public static func missingFiles(for pair: CLIPPair, in folder: URL) -> [String] {
        pair.textFiles.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    static func bundledTokenizer(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw StudioError.invalidInput("\(name).json is missing from StudioCore's resources.")
        }
        return url
    }
}

/// A text encoder's tokenizer and tables, loaded once: turns prompts into input frames and the encoder's
/// output into unit-length embeddings.
public struct CLIPTextEncoder: Sendable {
    enum Tokenizer: Sendable {
        case clip(CLIPTokenizer)
        case sentencePiece(SentencePieceTokenizer)
    }

    public let pair: CLIPPair
    public let model: ModelInfo
    let tokenizer: Tokenizer
    let tokenEmbeddings: NPYFloatArray
    let projection: NPYFloatArray?
    let finalNorm: NPYFloatArray?

    /// `folder` holds the pair's `textFiles`.
    public init(pair: CLIPPair, folder: URL) throws {
        guard let model = ModelCatalog.model(named: pair.text) else { throw StudioError.invalidInput("\(pair.text) is missing from the model table.") }
        let missing = CLIPModels.missingFiles(for: pair, in: folder)
        guard missing.isEmpty else { throw StudioError.invalidInput("Tagging with \(pair.image) needs \(missing.joined(separator: ", ")).") }
        func file(_ suffix: String) -> URL { folder.appendingPathComponent("\(pair.text).\(suffix)") }
        self.pair = pair
        self.model = model
        switch pair.family {
        case .clip: tokenizer = .clip(try CLIPTokenizer(contentsOf: CLIPModels.bundledTokenizer("clip_tokenizer")))
        case .siglip: tokenizer = .sentencePiece(try SentencePieceTokenizer(contentsOf: CLIPModels.bundledTokenizer("siglip_tokenizer")))
        case .siglip2: tokenizer = .sentencePiece(try SentencePieceTokenizer(contentsOf: file("tokenizer.json")))
        }
        tokenEmbeddings = try NPYFloatArray(contentsOf: file("tokens.npy"))
        projection = pair.family == .clip ? try NPYFloatArray(contentsOf: file("projection.npy")) : nil
        finalNorm = pair.textNeedsFinalNorm ? try NPYFloatArray(contentsOf: file("final_norm.npy")) : nil
    }

    /// Token ids for a prompt as the encoder takes them (CLIP: start, tokens, end, at most 77; SigLIP: tokens,
    /// end, padding to 64).
    public func ids(for prompt: String) -> [Int] {
        switch tokenizer {
        case .clip(let clip): return clip.encode(prompt)
        case .sentencePiece(let sentencePiece): return sentencePiece.encode(prompt, length: model.inputs.first?.width ?? 64)
        }
    }

    /// The encoder's input frame for a prompt, and where its embedding is read from the output (CLIP: the
    /// first end token, or the last position when a long prompt lost it; SigLIP: unused).
    public func input(for prompt: String) throws -> (frame: [UInt8], endPosition: Int) {
        let ids = ids(for: prompt)
        let length = model.inputs.first?.width ?? CLIPTokenizer.maxLength
        let end = ids.firstIndex(of: CLIPTokenizer.endToken) ?? (length - 1)
        return (try CLIP.textFrame(ids: ids, tokenEmbeddings: tokenEmbeddings, model: model), end)
    }

    public func embedding(from output: Tensor, endPosition: Int) throws -> [Float] {
        guard let projection else { return CLIP.imageEmbedding(from: output) }
        return try CLIP.textEmbedding(from: output, endPosition: endPosition, projection: projection, finalNorm: finalNorm)
    }
}

/// Scores a picture against text prompts with one image / text encoder pair. Prompts are embedded once with
/// the text encoder; each picture then needs one run of the image encoder. Both must be loaded on the device.
public struct CLIPTagger: Sendable {
    public let encoder: CLIPTextEncoder
    public private(set) var prompts: [(text: String, embedding: [Float], negative: Bool)] = []
    public var pair: CLIPPair { encoder.pair }

    public init(encoder: CLIPTextEncoder) {
        self.encoder = encoder
    }

    /// Embeds the prompts with the text encoder. A prompt starting with "-" is a negative: it can win,
    /// which means "none of the wanted things". `prefix` goes in front of each prompt ("A photo of a ", as
    /// the reference app; YOLO-World's class embeddings are the bare names).
    public mutating func setPrompts(_ texts: [String], device: any InferenceEngine, prefix: String = CLIP.promptPrefix) async throws {
        var result: [(String, [Float], Bool)] = []
        for raw in texts {
            guard let (text, negative) = CLIP.parsePrompt(raw) else { continue }
            let (frame, endPosition) = try encoder.input(for: prefix + text)
            let output = try await device.infer(inputs: [frame], model: pair.text)
            result.append((text, try encoder.embedding(from: output[0], endPosition: endPosition), negative))
        }
        prompts = result
    }

    /// The picture's unit-length embedding from the image encoder (stretched to its input, as the reference).
    public func imageEmbedding(_ image: CGImage, device: any InferenceEngine) async throws -> [Float] {
        guard let model = ModelCatalog.model(named: pair.image) else { throw StudioError.invalidInput("\(pair.image) is missing from the model table.") }
        let frame = try ImagePrep.prepare(image, width: model.inputWidth, height: model.inputHeight, mode: .stretch)
        return CLIP.imageEmbedding(from: try await device.infer(inputs: [frame.rgb], model: pair.image)[0])
    }

    /// Scores as a result list: background prompts as "not: <prompt>", the index being the prompt's.
    public func classifications(_ scores: [CLIPScore]) -> [Classification] {
        CLIP.classifications(scores, prompts: prompts.map(\.text))
    }

    /// Probability of each prompt for this picture, best first.
    public func tag(_ image: CGImage, device: any InferenceEngine) async throws -> [CLIPScore] {
        CLIP.scores(image: try await imageEmbedding(image, device: device), prompts: prompts, scale: pair.logitScale)
            .sorted { $0.probability > $1.probability }
    }
}
