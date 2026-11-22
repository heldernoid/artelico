import CoreML
import Foundation
import UIKit
import Vision

/// `-nativebench <name>` times `Documents/native/<name>.mlpackage` (a Core ML conversion of a Hailo
/// Model Zoo model) on this device, on each set of compute units, and writes the result to
/// `Documents/nativebench.txt`. Used from the Mac to compare running a model natively with the stick.
enum NativeBench {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-nativebench"), index + 1 < arguments.count else { return }
        let name = arguments[index + 1]
        Task.detached(priority: .userInitiated) { await run(name: name) }
    }

    private static func run(name: String) async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let report = documents.appendingPathComponent("nativebench.txt")
        var lines = ["\(name) on \(UIDevice.current.model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"]
        func write() { try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8) }
        write()
        do {
            let package = documents.appendingPathComponent("native/\(name).mlpackage")
            var started = Date()
            let compiled = try await MLModel.compileModel(at: package)
            lines.append(String(format: "compile: %.0f ms", Date().timeIntervalSince(started) * 1000)); write()

            guard let sample = Bundle.main.url(forResource: "bus", withExtension: "jpg"),
                  let picture = UIImage(contentsOfFile: sample.path)?.cgImage else { throw CocoaError(.fileNoSuchFile) }

            let units: [(String, MLComputeUnits)] = [("all", .all), ("neural engine", .cpuAndNeuralEngine), ("gpu", .cpuAndGPU), ("cpu", .cpuOnly)]
            for (label, unit) in units {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = unit
                started = Date()
                let model = try await MLModel.load(contentsOf: compiled, configuration: configuration)
                let loadMs = Date().timeIntervalSince(started) * 1000
                guard let (inputName, description) = model.modelDescription.inputDescriptionsByName.first,
                      let constraint = description.imageConstraint else { throw CocoaError(.featureUnsupported) }
                let value = try MLFeatureValue(cgImage: picture, constraint: constraint,
                                               options: [.cropAndScale: VNImageCropAndScaleOption.scaleFit.rawValue])
                let input = try MLDictionaryFeatureProvider(dictionary: [inputName: value])
                for _ in 0..<3 { _ = try await model.prediction(from: input) }
                var times: [Double] = []
                var output: MLFeatureProvider?
                for _ in 0..<30 {
                    let t = Date()
                    output = try await model.prediction(from: input)
                    times.append(Date().timeIntervalSince(t) * 1000)
                }
                times.sort()
                var check = ""
                if let output, let first = output.featureNames.sorted().first,
                   let array = output.featureValue(for: first)?.multiArrayValue, array.shape.count == 3, array.shape[1].intValue == 84 {
                    // yolov8 layout [1, 84, N]: best class score over all candidates, as a sanity check.
                    // Neural Engine outputs can have padded rows, so index with the array's strides.
                    let count = array.shape[2].intValue
                    let rowStride = array.strides[1].intValue, columnStride = array.strides[2].intValue
                    var best: Float = 0
                    let pointer = array.dataPointer
                    for row in 4..<84 {
                        for column in 0..<count {
                            let index = row * rowStride + column * columnStride
                            let score: Float = array.dataType == .float16
                                ? Float(pointer.assumingMemoryBound(to: Float16.self)[index])
                                : pointer.assumingMemoryBound(to: Float.self)[index]
                            best = max(best, score)
                        }
                    }
                    check = String(format: ", best score %.3f", best)
                }
                lines.append(String(format: "%@: median %.1f ms, min %.1f ms (load %.0f ms%@)",
                                    label, times[times.count / 2], times[0], loadMs, check))
                write()
            }
        } catch {
            lines.append("error: \(error)")
        }
        lines.append("done")
        write()
    }
}
