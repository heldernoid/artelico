import Foundation

/// Something that runs vision models: the UGen300 stick (`UGenDevice`, in UGenKit) or Apple's own
/// chips (`CoreMLEngine`). Both return outputs in the stick's layout (see `Tensor`), so the decoders,
/// renderers and pipelines in UGenKit work the same on either.
public protocol InferenceEngine: Sendable {
    /// The main model (the one `infer(inputs:model: nil)` uses).
    var loadedModel: ModelInfo? { get async }
    /// Frames worth keeping in flight at once with `submit`/`collect`.
    var queueSize: Int { get async }
    /// Runs a loaded model once. `inputs` are frames in the order and format of `ModelInfo.inputs`.
    func infer(inputs: [[UInt8]], model: String?) async throws -> [Tensor]
    /// Starts one run without waiting; call `collect()` once per submission, in order.
    func submit(inputs: [[UInt8]], model: String?) async throws
    func collect() async throws -> [Tensor]
}


public extension InferenceEngine {
    /// Runs the main model.
    func infer(inputs: [[UInt8]]) async throws -> [Tensor] { try await infer(inputs: inputs, model: nil) }
    func submit(inputs: [[UInt8]]) async throws { try await submit(inputs: inputs, model: nil) }

    /// Runs `model` once per frame (crops of people or faces), keeping up to two runs in flight so the
    /// device is never idle between them. The outputs come back in the frames' order.
    func inferEach(_ frames: [[UInt8]], model: String) async throws -> [[Tensor]] {
        let window = max(1, min(await queueSize, 2))
        var outputs: [[Tensor]] = []
        var submitted = 0
        while outputs.count < frames.count {
            while submitted < frames.count, submitted - outputs.count < window {
                try await submit(inputs: [frames[submitted]], model: model)
                submitted += 1
            }
            outputs.append(try await collect())
        }
        return outputs
    }
}

/// Errors from the shared vision code (StudioCore). The stick has its own, `UGenError`, in UGenKit.
public enum StudioError: Error, CustomStringConvertible, Sendable {
    case noModelLoaded
    case invalidInput(String)

    public var description: String {
        switch self {
        case .noModelLoaded: return "No model is loaded."
        case .invalidInput(let message): return message
        }
    }
}
