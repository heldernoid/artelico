import CoreGraphics
import Foundation
import UGenKit

/// `ugen reid [--coreml] <model> <image> [image ...]`: finds the people in each picture (yolov8s), prints
/// how similar every two are (cosine of the re-identification embeddings) and the names one shared
/// gallery gives them, as the apps do across pictures and frames.
func reidCheck(_ arguments: [String], stick: UGenDevice) async throws {
    var args = arguments
    let coreML = args.first == "--coreml"
    if coreML { args.removeFirst() }
    guard args.count >= 2, let model = ModelCatalog.model(named: args[0]), VisionPipeline.supports(.personReID, model: model),
          let detector = ModelCatalog.model(named: TopDownPose.detectorName) else {
        fail("usage: ugen reid [--coreml] <osnet_x1_0|repvgg_a0_person_reid_512> <image> [image ...]")
    }
    let engine: any InferenceEngine
    if coreML {
        let native = CoreMLEngine()
        try await native.load(model, from: root.appendingPathComponent("native/coreml/\(model.name).mlpackage"), computeUnits: .all)
        try await native.load(detector, from: root.appendingPathComponent("native/coreml/\(detector.name).mlpackage"), computeUnits: .all, primary: false)
        engine = native
    } else {
        try await connectRuntime(stick)
        _ = try await loadModel(model.name, on: stick)
        try await stick.addModel(hef: root.appendingPathComponent("models/\(detector.name).hef"), info: detector)
        engine = stick
    }
    var gallery = ReIdentification.gallery(for: model)
    var all: [(String, [Float])] = []
    for path in args.dropFirst() {
        guard case .described(var people) = try await CropTasks.run(.personReID, on: loadImage(path), model: model, device: engine) else { continue }
        ReIdentification.name(&people, gallery: &gallery)
        let file = URL(fileURLWithPath: path).lastPathComponent
        for (index, person) in people.enumerated() {
            let box = person.boundingBox
            print(String(format: "%@#%d at x %.2f y %.2f: %@%@", file, index, box.midX, box.midY, person.name ?? "-",
                         person.similarity.map { String(format: " (%.2f)", $0) } ?? " (new)"))
            all.append(("\(file)#\(index)", person.embedding))
        }
    }
    for i in all.indices {
        let row = all.indices.map { j in String(format: "%5.2f", zip(all[i].1, all[j].1).reduce(Float(0)) { $0 + $1.0 * $1.1 }) }.joined(separator: " ")
        print("\(all[i].0.padding(toLength: 22, withPad: " ", startingAt: 0)) \(row)")
    }
}
