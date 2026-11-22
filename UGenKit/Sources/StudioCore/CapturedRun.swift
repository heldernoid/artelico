import CoreGraphics
import Foundation

/// The raw outputs of one inference saved to a folder, so decoders can be developed and tested
/// without the stick. Written by `ugen capture`, read by `ugen replay`.
public struct CapturedRun: Sendable {
    public let model: ModelInfo
    public let frame: PreparedFrame
    public let tensors: [Tensor]

    private struct Meta: Codable {
        let model: String
        let width: Int
        let height: Int
        let sourceWidth: Int
        let sourceHeight: Int
        let content: [Double]
        /// The source region (normalized); missing in older captures, which used the whole picture.
        let region: [Double]?
    }

    public init(model: ModelInfo, frame: PreparedFrame, tensors: [Tensor]) {
        self.model = model
        self.frame = frame
        self.tensors = tensors
    }

    /// Writes meta.json, input.rgb, and one out<N>.bin per output (in the model's own data type).
    public func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let meta = Meta(model: model.name, width: frame.width, height: frame.height, sourceWidth: frame.sourceWidth,
                        sourceHeight: frame.sourceHeight,
                        content: [frame.contentRect.minX, frame.contentRect.minY, frame.contentRect.width, frame.contentRect.height],
                        region: [frame.sourceRegion.minX, frame.sourceRegion.minY, frame.sourceRegion.width, frame.sourceRegion.height])
        try JSONEncoder().encode(meta).write(to: directory.appendingPathComponent("meta.json"))
        try Data(frame.rgb).write(to: directory.appendingPathComponent("input.rgb"))
        for (index, tensor) in tensors.enumerated() {
            try Data(tensor.bytes).write(to: directory.appendingPathComponent("out\(index).bin"))
        }
    }

    public static func load(from directory: URL) throws -> CapturedRun {
        let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: directory.appendingPathComponent("meta.json")))
        guard let model = ModelCatalog.model(named: meta.model) else {
            throw StudioError.invalidInput("Captured run uses unknown model \(meta.model).")
        }
        let rgb = [UInt8](try Data(contentsOf: directory.appendingPathComponent("input.rgb")))
        let region = meta.region ?? [0, 0, 1, 1]
        let frame = PreparedFrame(rgb: rgb, width: meta.width, height: meta.height, sourceWidth: meta.sourceWidth, sourceHeight: meta.sourceHeight,
                                  contentRect: CGRect(x: meta.content[0], y: meta.content[1], width: meta.content[2], height: meta.content[3]),
                                  sourceRegion: CGRect(x: region[0], y: region[1], width: region[2], height: region[3]))
        let tensors = try model.outputs.enumerated().map { index, stream in
            let bytes = [UInt8](try Data(contentsOf: directory.appendingPathComponent("out\(index).bin")))
            // Per-channel quantized outputs are saved as the float32 the device hands out.
            if stream.qpScales != nil, bytes.count != stream.frameSize { return Tensor(stream: stream.asFloat32, bytes: bytes) }
            return Tensor(stream: stream, bytes: bytes).withPerChannelDequantized
        }
        return CapturedRun(model: model, frame: frame, tensors: tensors)
    }
}
