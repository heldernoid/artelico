// Mac command-line tool for testing UGenKit with the stick plugged into the Mac.
//
//   swift run ugen boot                      upload the runtime if the stick is in loader mode
//   swift run ugen identify
//   swift run ugen models [task]             list known models
//   swift run ugen <task> <model> <image> [output.png | result.json]
//   swift run ugen bench <model> [frames-in-flight] [frames]
//   swift run ugen capture <task> <model> <image> <folder>     run once and save the raw outputs
//   swift run ugen replay <task> <folder> <image> [output.png] [masks.bin | result.json]
//        decode saved outputs without the stick (instance masks or the result, for reference checks)
//   swift run ugen native-map <task> <model> <image> <model.mlpackage>
//        run the stick and a Core ML conversion side by side; writes <model>.native.json
//   swift run ugen examples [vision|pose|language]   the UGen300 demo screens' steps on the stick (and Core ML)
//   swift run ugen tag [--coreml] <image encoder> <label,label,...> <image> [image ...]   tagging from text
//   swift run ugen find | describe ...       the prompt tasks (PromptChecks.swift)
//   swift run ugen native-map zero_shot_object_detection yolo_world_v2s <image> <package> [prompt,prompt,...]
//
// Files are looked up in $UGEN_ROOT (default: the parent of the package directory):
//   models/<name>.hef and images/core-image-hailo-hailo10-usb-dongle.ext4
import CoreGraphics
import Foundation
import ImageIO
import UGenKit
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["UGEN_ROOT"] ?? "..")
let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

func loadImage(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("Cannot read image \(path)") }
    return image
}

func savePNG(_ image: CGImage, to path: String) {
    guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("Cannot write \(path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

func connectRuntime(_ device: UGenDevice) async throws {
    let mode = try await device.connect()
    if mode == .loader {
        print("stick is in loader mode; uploading the runtime...")
        try await device.bootRuntime(image: root.appendingPathComponent("images/core-image-hailo-hailo10-usb-dongle.ext4"))
    }
}

func loadModel(_ name: String, on device: UGenDevice) async throws -> ModelInfo {
    guard let model = ModelCatalog.model(named: name) else { fail("Unknown model \(name). Try: ugen models") }
    try await device.loadModel(hef: root.appendingPathComponent("models/\(name).hef"), info: model)
    return model
}

let device = UGenDevice()
do {
    guard let command = arguments.first else { fail("usage: ugen boot | identify | health [model] | models [task] | <task> <model> <image> [out.png] | bench <model> [depth] [frames]") }
    switch command {
    case "models":
        let task = arguments.count > 1 ? arguments[1] : nil
        for model in ModelCatalog.all where task == nil || model.tasks.contains(task!) {
            let decodable = VisionTask.allCases.filter { VisionPipeline.supports($0, model: model) }.map(\.rawValue)
            print("\(model.name.padding(toLength: 38, withPad: " ", startingAt: 0)) \(model.tasks.joined(separator: ","))  \(model.inputWidth)x\(model.inputHeight)  decodes: \(decodable.isEmpty ? "-" : decodable.joined(separator: ","))")
        }
    case "boot":
        try await connectRuntime(device)
        print("mode: \(await device.mode.rawValue)")
    case "identify":
        try await connectRuntime(device)
        let identity = try await device.identify()
        print("firmware \(identity.firmwareVersion), architecture \(identity.architecture), chip \(identity.chipTemperatureCelsius.map { String(format: "%.1f C", $0) } ?? "?"), USB-C source \(identity.currentLimitMilliamps.map { "\($0) mA" } ?? "?")")
    case "health":
        // `ugen health [model]`: the chip's health, load and power; with a model, while it runs frames.
        try await connectRuntime(device)
        var load: Task<Void, Never>?
        if arguments.count > 1 {
            let model = try await loadModel(arguments[1], on: device)
            let input = [UInt8](repeating: 128, count: model.inputWidth * model.inputHeight * 3)
            load = Task { while !Task.isCancelled { _ = try? await device.infer(inputs: [input]) } }
            try await Task.sleep(for: .seconds(1))
        }
        for _ in 0..<3 {
            // Frames in flight make chipStats wait its turn: retry until the stick is between frames.
            var stats: UGenDevice.ChipStats?
            for _ in 0..<200 where stats == nil { stats = try await device.chipStats(samplingMilliseconds: 500) }
            guard let stats else { fail("the stick was never free to answer") }
            func show<T>(_ value: T?, _ format: (T) -> String) -> String { value.map(format) ?? "n/a" }
            print("temperature \(show(stats.temperatureCelsius) { String(format: "%.1f C", $0) }), core \(show(stats.coreMillivolts) { "\($0) mV" }), self-test \(show(stats.selfTestFailures) { String(format: "0x%X", $0) }), CPU \(show(stats.cpuPercent) { String(format: "%.0f%%", $0) }), neural core \(show(stats.neuralCorePercent) { String(format: "%.0f%%", $0) }), DSP \(show(stats.dspPercent) { "\($0)%" }), RAM \(show(stats.ramUsedBytes) { "\($0 / 1_048_576) MB" }) of \(show(stats.ramTotalBytes) { "\($0 / 1_048_576) MB" }), power \(show(stats.powerWatts) { String(format: "%.2f W", $0) })")
            if !stats.unsupported.isEmpty { print("  not answered: \(stats.unsupported.joined(separator: "; "))") }
        }
        load?.cancel()
    case "bench":
        guard arguments.count >= 2 else { fail("usage: ugen bench <model> [frames-in-flight] [frames]") }
        let depth = arguments.count > 2 ? Int(arguments[2]) ?? 2 : 2
        let frames = arguments.count > 3 ? Int(arguments[3]) ?? 300 : 300
        try await connectRuntime(device)
        let model = try await loadModel(arguments[1], on: device)
        let inputs = model.inputs.map { [UInt8](repeating: 114, count: $0.frameSize) }
        let clock = ContinuousClock()
        let start = clock.now
        var submitted = 0, collected = 0
        while collected < frames {
            while submitted < frames, submitted - collected < depth {
                try await device.submit(inputs: inputs)
                submitted += 1
            }
            _ = try await device.collect()
            collected += 1
        }
        let elapsed = milliseconds(clock.now - start)
        print(String(format: "%@: %d frames in flight, %d frames in %.0f ms = %.1f FPS", model.name, depth, frames, elapsed, Double(frames) * 1000 / elapsed))
    case "examples":
        // ugen examples [vision|language]: the demo screens' stick steps, compared with Core ML.
        try await connectRuntime(device)
        if arguments.count > 2, arguments[1] == "hands" {
            try await examplesHands(Array(arguments.dropFirst(2)), stick: device)
        } else if arguments.count > 3, arguments[1] == "raw" {
            try await examplesRaw(arguments[2], picture: arguments[3], stick: device)
        } else {
            try await examplesCheck(arguments.count > 1 ? arguments[1] : nil, stick: device)
        }
    case "read":
        // ugen read <image> [out.png]: find text and read it (two models).
        guard arguments.count >= 2 else { fail("usage: ugen read <image> [output.png]") }
        try await connectRuntime(device)
        _ = try await loadModel(TextReader.detectorName, on: device)
        try await device.addModel(hef: root.appendingPathComponent("models/\(TextReader.recognizerName).hef"), info: ModelCatalog.model(named: TextReader.recognizerName)!)
        let image = loadImage(arguments[1])
        let clock = ContinuousClock()
        let start = clock.now
        let regions = try await TextReader.read(image, device: device)
        print(String(format: "%d regions in %.0f ms", regions.count, milliseconds(clock.now - start)))
        for region in regions { print("  \(region.text.isEmpty ? "(unreadable)" : region.text)") }
        if arguments.count > 2, let rendered = VisionRenderer.render(.text(regions), over: image) { savePNG(rendered, to: arguments[2]) }
    case "faces":
        // ugen faces [--embedder <model>] <image> [image2 ...]: detect faces in each image and print how similar they are.
        var paths = Array(arguments.dropFirst())
        if paths.first == "--embedder", paths.count > 1 {
            FaceRecognition.embedderName = paths[1]
            paths.removeFirst(2)
        }
        guard !paths.isEmpty, let embedder = ModelCatalog.model(named: FaceRecognition.embedderName) else {
            fail("usage: ugen faces [--embedder \(FaceRecognition.embedderNames.joined(separator: "|"))] <image> [image ...]")
        }
        try await connectRuntime(device)
        _ = try await loadModel(FaceRecognition.detectorName, on: device)
        try await device.addModel(hef: root.appendingPathComponent("models/\(embedder.name).hef"), info: embedder)
        var all: [(String, [Float])] = []
        for path in paths {
            let found = try await FaceRecognition.describe(loadImage(path), device: device)
            for (index, item) in found.enumerated() { all.append(("\(URL(fileURLWithPath: path).lastPathComponent)#\(index)", item.embedding)) }
        }
        for i in all.indices {
            let row = all.indices.map { j in String(format: "%5.2f", zip(all[i].1, all[j].1).reduce(Float(0)) { $0 + $1.0 * $1.1 }) }.joined(separator: " ")
            print("\(all[i].0.padding(toLength: 22, withPad: " ", startingAt: 0)) \(row)")
        }
    case "reid":
        try await reidCheck(Array(arguments.dropFirst()), stick: device)
    case "clip":
        try await clipCheck(Array(arguments.dropFirst()), stick: device)
    case "tag":
        try await tagCheck(Array(arguments.dropFirst()), stick: device)
    case "find":
        try await findCheck(Array(arguments.dropFirst()), stick: device)
    case "describe":
        try await describeCheck(Array(arguments.dropFirst()), stick: device)
    case "stereo":
        // ugen stereo <left image> <right image> [out.png]
        guard arguments.count >= 3 else { fail("usage: ugen stereo <left> <right> [output.png]") }
        try await connectRuntime(device)
        _ = try await loadModel(StereoDepth.modelName, on: device)
        let left = loadImage(arguments[1])
        let clock = ContinuousClock()
        let start = clock.now
        let map = try await StereoDepth.run(left: left, right: loadImage(arguments[2]), device: device)
        print(String(format: "%@ in %.0f ms", VisionResult.depth(map).summary, milliseconds(clock.now - start)))
        if arguments.count > 3, let rendered = VisionRenderer.render(.depth(map), over: left) { savePNG(rendered, to: arguments[3]) }
    case "tiled":
        // ugen tiled <model> <image> <columns> <rows> [out.png]
        guard arguments.count >= 5 else { fail("usage: ugen tiled <model> <image> <columns> <rows> [output.png]") }
        try await connectRuntime(device)
        _ = try await loadModel(arguments[1], on: device)
        let image = loadImage(arguments[2])
        let clock = ContinuousClock()
        let start = clock.now
        let found = try await Tiling.detect(image, device: device, columns: Int(arguments[3]) ?? 2, rows: Int(arguments[4]) ?? 2)
        print(String(format: "%d objects in %.0f ms: %@", found.count, milliseconds(clock.now - start), VisionResult.detections(found).summary))
        if arguments.count > 5, let rendered = VisionRenderer.render(.detections(found), over: image) { savePNG(rendered, to: arguments[5]) }
    case "native-map":
        guard arguments.count >= 5, let task = VisionTask(rawValue: arguments[1]) else {
            fail("usage: ugen native-map <task> <model> <image> <model.mlpackage>")
        }
        try await connectRuntime(device)
        let model = try await loadModel(arguments[2], on: device)
        // YOLO-World's second input: prompts (the sixth argument, default bus.jpg's), not a second picture.
        let open = OpenVocabulary.isOpenVocabulary(model)
        let text = open ? try await openVocabularyFrame(arguments.count > 5 ? arguments[5] : "bus,person,handbag,sunglasses", model: model) : nil
        try await nativeMap(task: task, model: model, image: loadImage(arguments[3]), package: URL(fileURLWithPath: arguments[4]), device: device,
                            second: arguments.count > 5 && !open ? loadImage(arguments[5]) : nil, text: text)
        await device.disconnect()
        exit(0)
    case "native-bench":
        guard arguments.count >= 3 else { fail("usage: ugen native-bench <pose model> <picture> [frames]") }
        try await nativeBench(arguments[1], picture: arguments[2], frames: arguments.count > 3 ? Int(arguments[3]) ?? 30 : 30)
        exit(0)
    case "capture":
        guard arguments.count >= 5, let task = VisionTask(rawValue: arguments[1]) else { fail("usage: ugen capture <task> <model> <image> <folder>") }
        try await connectRuntime(device)
        let model = try await loadModel(arguments[2], on: device)
        let frame = try VisionPipeline.prepare(loadImage(arguments[3]), for: model, task: task)
        let tensors = try await device.infer(inputs: [frame.rgb])
        try CapturedRun(model: model, frame: frame, tensors: tensors).save(to: URL(fileURLWithPath: arguments[4]))
        print("captured \(model.name): \(tensors.count) outputs -> \(arguments[4])")
    case "replay":
        guard arguments.count >= 4, let task = VisionTask(rawValue: arguments[1]) else { fail("usage: ugen replay <task> <folder> <image> [output.png]") }
        let run = try CapturedRun.load(from: URL(fileURLWithPath: arguments[2]))
        let image = loadImage(arguments[3])
        let clock = ContinuousClock()
        let start = clock.now
        let result = VisionPipeline.decode(run.tensors, task: task, model: run.model, frame: run.frame)
        print("\(run.model.name) (replay): \(result.summary)")
        print(String(format: "decode %.1f ms", milliseconds(clock.now - start)))
        if arguments.count > 4, let rendered = VisionRenderer.render(result, over: image) {
            savePNG(rendered, to: arguments[4])
            print("wrote \(arguments[4])")
        }
        // The result as JSON (as the REST API gives it), for comparing with a Python reference.
        if arguments.count > 5, arguments[5].hasSuffix(".json") {
            try JSONSerialization.data(withJSONObject: result.jsonObject, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: arguments[5]))
            print("wrote \(arguments[5])")
        }
        // Instance masks at the input's picture area, for comparing with a Python reference.
        if arguments.count > 5, !arguments[5].hasSuffix(".json"), case .instances(let found) = result {
            try writeMasks(found, width: Int(run.frame.contentRect.width), height: Int(run.frame.contentRect.height), to: arguments[5])
            print("wrote \(found.count) masks to \(arguments[5])")
        }
        exit(0)
    default:
        guard let task = VisionTask(rawValue: command) else { fail("Unknown command or task: \(command)") }
        guard arguments.count >= 3 else { fail("usage: ugen \(command) <model> <image> [output.png]") }
        try await connectRuntime(device)
        let model = try await loadModel(arguments[1], on: device)
        for name in task.companionModels(for: model) {
            try await device.addModel(hef: root.appendingPathComponent("models/\(name).hef"), info: ModelCatalog.model(named: name)!)
        }
        let image = loadImage(arguments[2])
        let (result, timing) = try await VisionPipeline.run(task, on: image, device: device)
        print("\(model.name) on \(image.width)x\(image.height): \(result.summary)")
        print(String(format: "prepare %.1f ms, inference %.1f ms, decode %.1f ms", milliseconds(timing.prepare), milliseconds(timing.inference), milliseconds(timing.decode)))
        if arguments.count > 3, arguments[3].hasSuffix(".json") {
            try JSONSerialization.data(withJSONObject: result.jsonObject, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: arguments[3]))
            print("wrote \(arguments[3])")
        } else if arguments.count > 3, let rendered = VisionRenderer.render(result, over: image) {
            savePNG(rendered, to: arguments[3])
            print("wrote \(arguments[3])")
        }
    }
    await device.disconnect()
} catch {
    await device.disconnect()
    fail("error: \(error)")
}
