import CoreGraphics
import Foundation
import UGenKit

/// `ugen clip [--coreml] <frames per second> <frame> [frame ...]`: feeds the frames of a video (in order,
/// `frames per second` as in the video) through `VideoClip` as Live does and prints each answer of r3d_18.
func clipCheck(_ arguments: [String], stick: UGenDevice) async throws {
    var args = arguments
    let coreML = args.first == "--coreml"
    if coreML { args.removeFirst() }
    guard args.count >= 2, let rate = Double(args[0]), let model = ModelCatalog.model(named: "r3d_18") else {
        fail("usage: ugen clip [--coreml] <frames per second> <frame> [frame ...]")
    }
    let engine: any InferenceEngine
    if coreML {
        let native = CoreMLEngine()
        try await native.load(model, from: root.appendingPathComponent("native/coreml/r3d_18.mlpackage"), computeUnits: .all)
        engine = native
    } else {
        try await connectRuntime(stick)
        _ = try await loadModel(model.name, on: stick)
        engine = stick
    }
    var clip = VideoClip()
    let clock = ContinuousClock()
    for (index, path) in args.dropFirst().enumerated() {
        let time = Double(index) / rate
        guard let input = clip.add(loadImage(path), at: time, model: model) else { continue }
        let start = clock.now
        clip.actions = VideoClip.actions(try await engine.infer(inputs: [input])[0])
        let ms = Double((clock.now - start).components.attoseconds) / 1e15 + Double((clock.now - start).components.seconds) * 1000
        print(String(format: "%5.2f s (%.0f ms): ", time, ms) + clip.actions.prefix(3).map { String(format: "%@ %.2f", $0.label, $0.probability) }.joined(separator: ", "))
    }
}
