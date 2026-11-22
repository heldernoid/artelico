// `ugen examples [vision|language]`: runs the stick side of the UGen300 demo screens (the code Hailo Studio
// uses) on sample pictures, and the same steps with the Core ML conversions on this Mac (what Artelico
// uses), and says whether they agree. Language and speech run on the stick only.
//
// Pictures come from $UGEN_ROOT/testdata and Artelico/Samples; Core ML packages from native/coreml.
import AVFoundation
import CoreGraphics
import CoreML
import Foundation
import UGenKit

private struct Engines {
    let stick: UGenDevice
    let native = CoreMLEngine()

    /// The first model is the stick's main one (replacing what was there); the others go next to it.
    func load(_ names: [String]) async throws -> [ModelInfo] {
        await native.unloadAll()
        var infos: [ModelInfo] = []
        for (index, name) in names.enumerated() {
            guard let info = ModelCatalog.model(named: name) else { fail("Unknown model \(name)") }
            let hef = root.appendingPathComponent("models/\(name).hef")
            if index == 0 { try await stick.loadModel(hef: hef, info: info) } else { try await stick.addModel(hef: hef, info: info) }
            try await native.load(info, from: root.appendingPathComponent("native/coreml/\(name).mlpackage"), computeUnits: .all, primary: index == 0)
            infos.append(info)
        }
        return infos
    }
}

private var failures: [String] = []

private func check(_ ok: Bool, _ label: String, _ detail: String) {
    print("\(ok ? "PASS" : "FAIL")  \(label): \(detail)")
    if !ok { failures.append(label) }
}

private func sample(_ name: String) -> CGImage {
    for folder in ["testdata", "testdata/samples", "Artelico/Samples"] {
        let path = root.appendingPathComponent("\(folder)/\(name)").path
        if FileManager.default.fileExists(atPath: path) { return loadImage(path) }
    }
    fail("Sample \(name) not found")
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

private func iou(_ a: CGRect, _ b: CGRect) -> Double {
    let i = a.intersection(b)
    guard !i.isNull else { return 0 }
    let inter = i.width * i.height
    return inter / (a.width * a.height + b.width * b.height - inter)
}

private func poses(_ image: CGImage, model: ModelInfo, on engine: any InferenceEngine) async throws -> [Pose] {
    let frame = try VisionPipeline.prepare(image, for: model, task: .pose)
    let tensors = try await engine.infer(inputs: [frame.rgb], model: model.name)
    if case .poses(let list) = VisionPipeline.decode(tensors, task: .pose, model: model, frame: frame) { return list }
    return []
}

private func detections(_ image: CGImage, model: ModelInfo, on engine: any InferenceEngine) async throws -> [Detection] {
    let frame = try VisionPipeline.prepare(image, for: model, task: .detection)
    let tensors = try await engine.infer(inputs: [frame.rgb], model: model.name)
    if case .detections(let list) = VisionPipeline.decode(tensors, task: .detection, model: model, frame: frame) { return list }
    return []
}

/// As the plate gate: read text in each vehicle box (or the whole picture) and keep plate-shaped results.
private func plates(_ image: CGImage, vehicles: [Detection], on engine: any InferenceEngine) async throws -> [String] {
    let regions = vehicles.isEmpty ? [CGRect(x: 0, y: 0, width: 1, height: 1)] : vehicles.map(\.boundingBox)
    var found: [String] = []
    for r in regions {
        let pixels = CGRect(x: r.minX * CGFloat(image.width), y: r.minY * CGFloat(image.height),
                            width: r.width * CGFloat(image.width), height: r.height * CGFloat(image.height)).integral
        guard let crop = image.cropping(to: pixels) else { continue }
        for text in try await TextReader.read(crop, device: engine) { if let plate = PlateText.normalize(text.text) { found.append(plate) } }
    }
    return found
}

func examplesVision(stick: UGenDevice) async throws {
    let engines = Engines(stick: stick)
    let bus = sample("bus.jpg")

    // Body and pose (slides, counters, air instrument, yoga, squats, classroom) + hands (hand signs,
    // fruit ninja, air band): the pose model with hand_landmark_lite next to it.
    let poseModels = try await engines.load(["yolov8m_pose", HandReader.modelName])
    let stickPoses = try await poses(bus, model: poseModels[0], on: stick)
    let nativePoses = try await poses(bus, model: poseModels[0], on: engines.native)
    var keypointError = 0.0, matched = 0
    for p in stickPoses {
        guard let q = nativePoses.max(by: { iou(p.boundingBox, $0.boundingBox) < iou(p.boundingBox, $1.boundingBox) }), iou(p.boundingBox, q.boundingBox) > 0.5 else { continue }
        for (a, b) in zip(p.keypoints, q.keypoints) where a.confidence > 0.5 && b.confidence > 0.5 { keypointError += distance(a.position, b.position); matched += 1 }
    }
    let poseError = matched > 0 ? keypointError / Double(matched) : 1
    check(stickPoses.count == nativePoses.count && poseError < 0.01, "pose (yolov8m_pose)",
          String(format: "stick %d people, Core ML %d; keypoints differ by %.4f of the picture on average", stickPoses.count, nativePoses.count, poseError))

    // Hands: a thumbs-up picture (MediaPipe's gesture sample); the hand is read past the wrist as in the app.
    let thumb = sample("thumbs_up.jpg")
    let thumbPoses = try await poses(thumb, model: poseModels[0], on: stick)
    let stickHands = try await HandReader.read(thumb, poses: thumbPoses, device: stick)
    let nativeHands = try await HandReader.read(thumb, poses: thumbPoses, device: engines.native)   // same squares
    var best: (error: Double, stick: HandSign, native: HandSign)?
    for (a, b) in zip(stickHands, nativeHands) {
        let error = zip(a.points, b.points).map { distance($0, $1) }.reduce(0, +) / 21 / max(a.box.width, 1e-6)
        if best == nil || error < best!.error { best = (error, HandSigns.classify(a.points), HandSigns.classify(b.points)) }
    }
    check(best.map { $0.error < 0.05 && $0.stick == .thumbsUp && $0.native == .thumbsUp } ?? false, "hands (hand_landmark_lite)",
          best.map { String(format: "%d hand squares; the best one: points differ by %.3f of the square, stick reads %@, Core ML %@", stickHands.count, $0.error, "\($0.stick)", "\($0.native)") } ?? "no hands found")

    // Objects (head count, traffic, missing check) and the plate gate: yolov8m with the text models.
    let objectModels = try await engines.load(["yolov8m", TextReader.detectorName, TextReader.recognizerName])
    let stickObjects = try await detections(bus, model: objectModels[0], on: stick)
    let nativeObjects = try await detections(bus, model: objectModels[0], on: engines.native)
    let summary: ([Detection]) -> String = { list in
        Dictionary(grouping: list.filter { $0.confidence >= 0.4 }, by: \.label).map { "\($0.value.count) \($0.key)" }.sorted().joined(separator: ", ")
    }
    check(summary(stickObjects) == summary(nativeObjects), "objects (yolov8m)", "stick: \(summary(stickObjects)); Core ML: \(summary(nativeObjects))")

    let car = sample("plate_sample.png")
    let vehicleLabels: Set<String> = ["car", "truck", "bus", "motorcycle"]
    let stickVehicles = try await detections(car, model: objectModels[0], on: stick).filter { vehicleLabels.contains($0.label) && $0.confidence >= 0.4 }
    let nativeVehicles = try await detections(car, model: objectModels[0], on: engines.native).filter { vehicleLabels.contains($0.label) && $0.confidence >= 0.4 }
    let stickPlates = try await plates(car, vehicles: stickVehicles, on: stick)
    let nativePlates = try await plates(car, vehicles: nativeVehicles, on: engines.native)
    check(stickPlates.contains("ABC-1234") && nativePlates.contains("ABC-1234"), "plate gate (yolov8m + ocr_det + ocr)",
          "stick read \(stickPlates), Core ML read \(nativePlates) (\(stickVehicles.count) / \(nativeVehicles.count) vehicles)")

    // Faces (check-in): each face detector with landmarks, each embedder. Same face on stick and Core ML
    // must agree; the two different people on bus.jpg must stay apart.
    for (detector, embedder) in [(FaceRecognition.detectorName, "arcface_mobilefacenet"), (FaceRecognition.detectorName, "arcface_r50"),
                                 ("retinaface_mobilenet_v1", "arcface_mobilefacenet")] {
        FaceRecognition.embedderName = embedder
        defer { FaceRecognition.embedderName = FaceRecognition.defaultEmbedderName }
        _ = try await engines.load([detector, embedder])
        let stickFaces = try await FaceRecognition.describe(bus, device: stick)
        let nativeFaces = try await FaceRecognition.describe(bus, device: engines.native)
        var similarities: [Float] = []
        for (face, embedding) in stickFaces {
            guard let other = nativeFaces.max(by: { iou(face.boundingBox, $0.face.boundingBox) < iou(face.boundingBox, $1.face.boundingBox) }),
                  iou(face.boundingBox, other.face.boundingBox) > 0.5 else { continue }
            similarities.append(zip(embedding, other.embedding).reduce(Float(0)) { $0 + $1.0 * $1.1 })
        }
        var different: [Float] = []
        for i in stickFaces.indices { for j in stickFaces.indices where j > i {
            different.append(zip(stickFaces[i].embedding, stickFaces[j].embedding).reduce(Float(0)) { $0 + $1.0 * $1.1 })
        } }
        var gallery = FaceGallery(embedder: embedder)
        for (index, item) in stickFaces.enumerated() { gallery.enroll("Person \(index + 1)", embedding: item.embedding) }
        let recognised = nativeFaces.filter { gallery.match($0.embedding) != nil }.count
        check(stickFaces.count == nativeFaces.count && !stickFaces.isEmpty && (similarities.min() ?? 0) > 0.9 && (different.max() ?? 0) < gallery.threshold,
              "faces (\(detector) + \(embedder))",
              String(format: "stick %d faces, Core ML %d; same face on both: similarity %.3f at least; different people: %.3f at most; %d of %d Core ML faces recognised from the stick's enrolment",
                     stickFaces.count, nativeFaces.count, similarities.min() ?? 0, different.max() ?? 0, recognised, nativeFaces.count))
    }

    // Photo restore: brighten (zero_dce) and remove noise (dncnn_color_blind), tile by tile.
    for (name, picture) in [("zero_dce", "room.png"), ("dncnn_color_blind", "input_image.png")] {
        let model = try await engines.load([name])[0]
        let source = try ImagePrep.prepare(sample(picture), width: sample(picture).width, height: sample(picture).height, mode: .stretch)
        let a = try await PhotoRestore.run(source.rgb, width: source.width, height: source.height, model: model, device: stick)
        let b = try await PhotoRestore.run(source.rgb, width: source.width, height: source.height, model: model, device: engines.native)
        let difference = zip(a.rgb, b.rgb).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(max(1, a.rgb.count))
        let before = PhotoRestore.meanBrightness(source.rgb), after = PhotoRestore.meanBrightness(a.rgb)
        let changed = zip(source.rgb, a.rgb).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(max(1, a.rgb.count))
        check(difference < 4 && changed > 1, "photo restore (\(name))",
              String(format: "%@ %dx%d: stick and Core ML differ by %.2f of 255 per value; the picture changed by %.1f; brightness %.0f -> %.0f",
                     picture, source.width, source.height, difference, changed, before, after))
    }
}

/// Mono 16 kHz samples from an audio file (as the apps' AudioLoader).
private func audioSamples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SpeechToText.sampleRate), channels: 1, interleaved: false)!
    let converter = AVAudioConverter(from: file.processingFormat, to: target)!
    let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * target.sampleRate / file.processingFormat.sampleRate) + 4096)!
    let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: input)
    var fed = false
    converter.convert(to: output, error: nil) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true; status.pointee = .haveData; return input
    }
    return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
}

/// As Hailo Studio's exampleStream: a fresh conversation, the answer collected piece by piece.
private func answer(_ stream: AsyncThrowingStream<String, Error>) async throws -> (text: String, perSecond: Double) {
    let clock = ContinuousClock()
    let start = clock.now
    var text = "", pieces = 0
    for try await piece in stream { text += piece; pieces += 1 }
    return (ModelText.withoutThinking(text), Double(pieces) / max(0.001, milliseconds(clock.now - start) / 1000))
}

private func parameters(_ defaults: GenerationParameters, maxTokens: Int, temperature: Float) -> GenerationParameters {
    var p = defaults
    p.maxGeneratedTokens = UInt32(maxTokens)
    p.temperature = temperature
    p.doSample = temperature > 0
    if let penalty = ProcessInfo.processInfo.environment["PENALTY"].flatMap(Float.init) { p.frequencyPenalty = penalty }
    return p
}

func examplesLanguage(stick: UGenDevice) async throws {
    let models = root.appendingPathComponent("models")
    if ProcessInfo.processInfo.environment["ONLY_PICTURES"] != nil { try await examplesPictures(stick: stick, models: models); return }

    // Meeting notes: Whisper on the stick, then the notes from a chat model.
    let speech = try await SpeechToText(hef: models.appendingPathComponent("Whisper-Base.hef"), device: stick)
    let samples = try audioSamples(root.appendingPathComponent("Artelico/Samples/speech_sample.wav"))
    let transcript = try await speech.transcribe(samples: samples).text.trimmingCharacters(in: .whitespacesAndNewlines)
    await speech.release()
    check(transcript.count > 10, "speech (Whisper-Base)", String(format: "%.1f s of audio -> \"%@\"", Double(samples.count) / 16_000, transcript))

    let chat = try await ChatModel(hef: models.appendingPathComponent("Qwen2.5-1.5B-Instruct.hef"), device: stick)
    try await chat.clearContext()
    let notes = try await answer(chat.generate(messages: [.system(MeetingNotes.system), .user(MeetingNotes.userMessage(MeetingNotes.exampleTranscript))],
                                               parameters: parameters(chat.defaultParameters, maxTokens: 500, temperature: 0.2)))
    await chat.release()
    check(MeetingNotes.looksValid(notes.text), "meeting notes (Qwen2.5-1.5B-Instruct)",
          String(format: "%.1f tokens/s, sections %@:\n%@", notes.perSecond, MeetingNotes.looksValid(notes.text) ? "present" : "MISSING", notes.text))

    // Offline code: the coding model writes JavaScript.
    let coder = try await ChatModel(hef: models.appendingPathComponent("Qwen2.5-Coder-1.5B-Instruct.hef"), device: stick)
    try await coder.clearContext()
    let system = """
    You are a coding assistant on a phone. Write programs in JavaScript: they run in this app, print with console.log, \
    and have no network, no files and no browser page. Give one complete code block in ```javascript, then at most \
    three short sentences of explanation. If the user asks for another language, show it, but also give a JavaScript version that runs.
    """
    let code = try await answer(coder.generate(messages: [.system(system), .user("Print the first 20 prime numbers.")],
                                               parameters: parameters(coder.defaultParameters, maxTokens: 700, temperature: 0.2)))
    await coder.release()
    let block = CodeBlocks.last(code.text)
    check(block?.language == "javascript" && block?.code.contains("console.log") == true, "offline code (Qwen2.5-Coder-1.5B-Instruct)",
          String(format: "%.1f tokens/s, %@ block:\n%@", code.perSecond, block?.language ?? "no", block?.code ?? code.text))

    try await examplesPictures(stick: stick, models: models)
}

func examplesPictures(stick: UGenDevice, models: URL) async throws {
    // Picture questions (outfit, fridge, face report, calories): the image model.
    let vision = try await VisionChatModel(hef: models.appendingPathComponent("Qwen2-VL-2B-Instruct.hef"), device: stick)
    try await vision.clearContext()
    let food = sample("apple.jpg")
    let calories = try await answer(vision.generate(messages: [.user(Nutrition.prompt, images: 1)], frames: [try vision.prepareFrame(food)],
                                                    parameters: parameters(vision.defaultParameters, maxTokens: 260, temperature: 0.15)))
    let items = Nutrition.parseItems(calories.text)
    check(!items.isEmpty, "calories (Qwen2-VL-2B-Instruct)",
          String(format: "%.1f tokens/s, %d items: %@\n%@", calories.perSecond, items.count, items.map { "\($0.item) \($0.kcal) kcal" }.joined(separator: ", "), calories.text))
    try await vision.clearContext()
    let fridge = try await answer(vision.generate(messages: [.user("Describe this picture in one sentence.", images: 1)], frames: [try vision.prepareFrame(sample("dog_bicycle.jpg"))],
                                                  parameters: parameters(vision.defaultParameters, maxTokens: 200, temperature: 0.3)))
    await vision.release()
    check(fridge.text.count > 5, "picture question (Qwen2-VL-2B-Instruct)", String(format: "%.1f tokens/s: %@", fridge.perSecond, fridge.text))
}

/// The other pose models (single-person ViTPose / MSPN with the person detector, and CenterPose): the
/// same people and keypoints on the stick and with Core ML on bus.jpg, and how long a frame takes with each
/// (the demo screens run one frame after another, so this is their frame time).
func examplesPoseModels(stick: UGenDevice, frames: Int = 10) async throws {
    let engines = Engines(stick: stick)
    let bus = sample("bus.jpg")
    for name in ["vit_pose_small", "vit_pose_small_bn", "mspn_regnetx_800mf", "centerpose_regnetx_800mf", "yolov8s_pose"] {
        guard let info = ModelCatalog.model(named: name) else { fail("Unknown model \(name)") }
        let model = try await engines.load([name] + VisionTask.pose.companionModels(for: info))[0]
        var results: [[Pose]] = [], times: [Double] = []
        for engine in [stick as any InferenceEngine, engines.native] {
            func run() async throws -> [Pose] {
                if TopDownPose.isTopDown(model) { return try await TopDownPose.run(bus, model: model, device: engine) }
                return try await poses(bus, model: model, on: engine)
            }
            results.append(try await run())   // also warms the engine up
            let clock = ContinuousClock(), start = clock.now
            for _ in 0..<frames { _ = try await run() }
            times.append(milliseconds(clock.now - start) / Double(frames))
        }
        var keypointError = 0.0, matched = 0, people = 0
        for p in results[0] {
            guard let q = results[1].max(by: { iou(p.boundingBox, $0.boundingBox) < iou(p.boundingBox, $1.boundingBox) }), iou(p.boundingBox, q.boundingBox) > 0.5 else { continue }
            people += 1
            for (a, b) in zip(p.keypoints, q.keypoints) where a.confidence > 0.5 && b.confidence > 0.5 { keypointError += distance(a.position, b.position); matched += 1 }
        }
        let error = matched > 0 ? keypointError / Double(matched) : 1
        check(results[0].count == results[1].count && people == results[0].count && error < 0.01, "pose (\(name))",
              String(format: "stick %d people, Core ML %d, %d matched; keypoints differ by %.4f of the picture; %.0f ms per frame on the stick, %.0f ms with Core ML",
                     results[0].count, results[1].count, people, error, times[0], times[1]))
    }
}

func examplesCheck(_ part: String?, stick: UGenDevice) async throws {
    if part == nil || part == "vision" { try await examplesVision(stick: stick) }
    if part == nil || part == "vision" || part == "pose" { try await examplesPoseModels(stick: stick) }
    if part == nil || part == "language" { try await examplesLanguage(stick: stick) }
    print(failures.isEmpty ? "\nall passed" : "\n\(failures.count) failed: \(failures.joined(separator: "; "))")
    if !failures.isEmpty { exit(2) }
}

/// `ugen examples raw <model> <picture>`: each output's size and range on the stick and with Core ML.
func examplesRaw(_ name: String, picture: String, stick: UGenDevice) async throws {
    let engines = Engines(stick: stick)
    let model = try await engines.load([name])[0]
    guard let input = model.inputs.first, let w = input.width, let h = input.height else { fail("no input size") }
    let frame = try ImagePrep.prepare(sample(picture), width: w, height: h, mode: .stretch)
    print("input \(w)x\(h), format \(input)")
    // REQUANT=1: give the stick pixels in its input quantization, q = p / scale + zero point.
    var stickInput = frame.rgb
    if ProcessInfo.processInfo.environment["REQUANT"] != nil, let zp = input.qpZp, let scale = input.qpScale {
        stickInput = frame.rgb.map { UInt8(min(255, max(0, (Float($0) / scale + zp).rounded()))) }
        print("requantized for the stick: zp \(zp), scale \(scale)")
    }
    var collected: [String: [[Float]]] = [:]
    for (label, engine) in [("stick", stick as any InferenceEngine), ("coreml", engines.native)] {
        for (index, tensor) in try await engine.infer(inputs: [label == "stick" ? stickInput : frame.rgb], model: name).enumerated() {
            collected[label, default: []].append(tensor.floats())
            let v = tensor.floats()
            let mean = v.reduce(0, +) / Float(max(1, v.count))
            print(String(format: "%@ out %d: %d values, min %.3f max %.3f mean %.3f first %@", label, index, v.count, v.min() ?? 0, v.max() ?? 0, mean,
                         v.prefix(6).map { String(format: "%.3f", $0) }.joined(separator: " ")))
        }
    }
    if let a = collected["stick"], let b = collected["coreml"] {
        for (index, (x, y)) in zip(a, b).enumerated() where x.count == y.count {
            let mx = x.reduce(0, +) / Float(x.count), my = y.reduce(0, +) / Float(y.count)
            var sxy: Float = 0, sxx: Float = 0, syy: Float = 0
            for (p, q) in zip(x, y) { sxy += (p - mx) * (q - my); sxx += (p - mx) * (p - mx); syy += (q - my) * (q - my) }
            let top = { (v: [Float]) in v.enumerated().sorted { $0.element > $1.element }.prefix(5).map(\.offset) }
            print(String(format: "out %d: correlation %.4f, top-5 stick %@ / Core ML %@", index, sxy / max(1e-9, (sxx * syy).squareRoot()), "\(top(x))", "\(top(y))"))
        }
    }
    let first = Array(frame.rgb.prefix(6)).map { String(format: "%.3f", Double($0) / 255) }.joined(separator: " ")
    print("input first values /255: \(first)")
}

/// `ugen examples hands <picture> ...`: the hand model on each picture (whole picture as one square, and
/// through the pose model as the app does), stick against Core ML, with the hand sign it reads.
func examplesHands(_ paths: [String], stick: UGenDevice) async throws {
    let engines = Engines(stick: stick)
    let models = try await engines.load(["yolov8m_pose", HandReader.modelName])
    for path in paths {
        let image = loadImage(path)
        let side = Double(min(image.width, image.height))
        var lines: [String] = []
        // Whole picture: one centred square.
        let x = (Double(image.width) - side) / 2, y = (Double(image.height) - side) / 2
        guard let rgb = HandReader.crop(image, x: x, y: y, size: side) else { continue }
        var points: [String: [CGPoint]] = [:]
        for (label, engine) in [("stick", stick as any InferenceEngine), ("coreml", engines.native)] {
            let tensors = try await engine.infer(inputs: [rgb], model: HandReader.modelName)
            let candidates = tensors.map { $0.floats() }.filter { $0.count == 63 }
            guard let lm = candidates.max(by: { ($0.map(abs).max() ?? 0) < ($1.map(abs).max() ?? 0) }) else { continue }
            points[label] = (0..<21).map { CGPoint(x: Double(lm[$0 * 3]) / 224, y: Double(lm[$0 * 3 + 1]) / 224) }
        }
        if let out = ProcessInfo.processInfo.environment["HANDS_OUT"], let a = points["stick"], let b = points["coreml"] {
            // The square with the stick's points (red) and Core ML's (green).
            let size = 448
            if let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
               let square = image.cropping(to: CGRect(x: x, y: y, width: side, height: side)) {
                context.draw(square, in: CGRect(x: 0, y: 0, width: size, height: size))
                for (list, color) in [(a, CGColor(red: 1, green: 0, blue: 0, alpha: 1)), (b, CGColor(red: 0, green: 1, blue: 0, alpha: 1))] {
                    context.setStrokeColor(color); context.setFillColor(color); context.setLineWidth(2)
                    for (i, j) in HandCrop.edges {
                        context.move(to: CGPoint(x: list[i].x * Double(size), y: Double(size) - list[i].y * Double(size)))
                        context.addLine(to: CGPoint(x: list[j].x * Double(size), y: Double(size) - list[j].y * Double(size)))
                    }
                    context.strokePath()
                    for (n, q) in list.enumerated() where n % 4 == 0 { context.fillEllipse(in: CGRect(x: q.x * Double(size) - 4, y: Double(size) - q.y * Double(size) - 4, width: 8, height: 8)) }
                }
                if let rendered = context.makeImage() { savePNG(rendered, to: out + "/" + URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent + "-points.png") }
            }
        }
        if let a = points["stick"], let b = points["coreml"] {
            let error = zip(a, b).map { distance($0, $1) }.reduce(0, +) / 21
            lines.append(String(format: "whole: stick %@, Core ML %@, points differ by %.3f of the square", "\(HandSigns.classify(a))", "\(HandSigns.classify(b))", error))
        }
        // As the app: pose, then a square past each wrist.
        let found = try await poses(image, model: models[0], on: stick)
        let a = try await HandReader.read(image, poses: found, device: stick)
        let b = try await HandReader.read(image, poses: found, device: engines.native)
        for (h, k) in zip(a, b) {
            let error = zip(h.points, k.points).map { distance($0, $1) }.reduce(0, +) / 21 / max(h.box.width, 1e-6)
            lines.append(String(format: "pose %@ hand: stick %@, Core ML %@, points differ by %.3f of the square", h.side, "\(HandSigns.classify(h.points))", "\(HandSigns.classify(k.points))", error))
        }
        if a.isEmpty { lines.append("pose: \(found.count) people, no hand square") }
        if let out = ProcessInfo.processInfo.environment["HANDS_OUT"],
           let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            let w = Double(image.width), h = Double(image.height)
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            for (list, color) in [(a, CGColor(red: 1, green: 0, blue: 0, alpha: 1)), (b, CGColor(red: 0, green: 1, blue: 0, alpha: 1))] {
                context.setStrokeColor(color); context.setLineWidth(2)
                for hand in list {
                    context.stroke(CGRect(x: hand.box.minX * w, y: h - hand.box.maxY * h, width: hand.box.width * w, height: hand.box.height * h))
                    for (i, j) in HandCrop.edges {
                        context.move(to: CGPoint(x: hand.points[i].x * w, y: h - hand.points[i].y * h))
                        context.addLine(to: CGPoint(x: hand.points[j].x * w, y: h - hand.points[j].y * h))
                    }
                    context.strokePath()
                }
            }
            if let rendered = context.makeImage() { savePNG(rendered, to: out + "/" + URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent + "-pose.png") }
        }
        print("\(URL(fileURLWithPath: path).lastPathComponent):\n  " + lines.joined(separator: "\n  "))
    }
}

/// `ugen native-bench <pose model> <picture> [frames]`: the hand screens' per-frame steps with Core ML only
/// (no stick): prepare, pose model, decode, hand crops and hand model, each timed.
func nativeBench(_ poseName: String, picture: String, frames: Int) async throws {
    let engine = CoreMLEngine()
    guard let pose = ModelCatalog.model(named: poseName), let hand = ModelCatalog.model(named: HandReader.modelName) else { fail("unknown model") }
    let clock = ContinuousClock()
    var t = clock.now
    try await engine.load(pose, from: root.appendingPathComponent("native/coreml/\(poseName).mlpackage"), computeUnits: .all, primary: true)
    try await engine.load(hand, from: root.appendingPathComponent("native/coreml/\(hand.name).mlpackage"), computeUnits: .all, primary: false)
    print("load \(clock.now - t)")
    let image = loadImage(picture)
    var sums = [String: Double](), handsSeen = 0
    func add(_ k: String, _ since: ContinuousClock.Instant) { sums[k, default: 0] += milliseconds(clock.now - since) }
    for i in 0..<frames {
        t = clock.now
        let prepared = try VisionPipeline.prepare(image, for: pose, task: .pose); add("prepare", t); t = clock.now
        let tensors = try await engine.infer(inputs: [prepared.rgb], model: pose.name); add("pose model", t); t = clock.now
        guard case .poses(let found) = VisionPipeline.decode(tensors, task: .pose, model: pose, frame: prepared) else { continue }
        add("pose decode", t); t = clock.now
        let hands = try await HandReader.read(image, poses: found, device: engine); add("hands (crop + model)", t)
        if i == 0 { handsSeen = hands.count; print("people \(found.count), hands \(hands.count)") }
    }
    for (k, v) in sums.sorted(by: { $0.key < $1.key }) { print(String(format: "%-22@ %7.1f ms/frame", k as NSString, v / Double(frames))) }
    print(String(format: "total %.1f ms/frame (%.1f FPS), %d hands", sums.values.reduce(0, +) / Double(frames), 1000 / (sums.values.reduce(0, +) / Double(frames)), handsSeen))
}
