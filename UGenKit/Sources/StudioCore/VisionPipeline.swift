import CoreGraphics
import Foundation

/// Runs one image through the model loaded on an engine (the stick or Core ML) and decodes the result for a task.
public enum VisionPipeline {
    /// True when UGenKit can decode this model's outputs for the task.
    public static func supports(_ task: VisionTask, model: ModelInfo) -> Bool {
        if task == .stereoDepth { return model.name == StereoDepth.modelName }
        // Two inputs: the picture and the typed prompts' embeddings (YOLO-World).
        if task == .findAnything { return model.tasks.contains(where: task.catalogTasks.contains) && OpenVocabulary.isOpenVocabulary(model) }
        guard model.tasks.contains(where: task.catalogTasks.contains), model.inputs.count == 1 else { return false }
        let outputs = model.outputs
        func has(_ features: Int) -> Bool { outputs.contains { $0.features == features } }
        switch task {
        case .detection: return model.hasDeviceNMS || isYOLO26Detection(model) || PostProcess.detectorHead(for: model) != nil
        case .pose:
            // YOLOv8 / YOLO26-pose (9 outputs), CenterPose, or a single-person model with a person detector.
            return (outputs.count == 9 && has(51)) || PostProcess.isCenterPose(model) || TopDownPose.isTopDown(model)
        case .classification:
            // One score vector: "NC", or 1x1xC in NHWC (DeiT, Swin and other transformers).
            guard outputs.count == 1 else { return false }
            let o = outputs[0]
            return o.order == "NC" || (o.order == "NHWC" && (o.height ?? 1) == 1 && (o.width ?? 1) == 1 && [1000, 1001].contains(o.features ?? 0))
        case .depth: return outputs.count == 1 && outputs[0].features == 1
        case .semanticSegmentation:
            // A class map (argmax on the device), or one score per class and pixel. The stick hands out
            // deeplab_v3_mobilenet_v2's scores as NHWC although its HEF calls them NCHW.
            guard outputs.count == 1 else { return false }
            let o = outputs[0]
            return o.order == "NHW" || ((o.features ?? 0) > 1 && (o.height ?? 0) > 1 && ["NHWC", "NCHW"].contains(o.order))
        case .instanceSegmentation:
            // YOLOv8-seg (DFL boxes, 64 channels) or YOLO26-seg (4 box channels), 10 outputs; YOLOv5-seg,
            // 4 outputs; YOLACT, 16 outputs; or the device's finished instances (YOLOv5-seg "hpp").
            if outputs.count == 1 { return outputs[0].isByteMaskNMS }
            return has(32) && ((outputs.count == 10 && (has(64) || has(4))) || outputs.count == 4 || isYOLACT(model))
        case .segmentEverything:
            // FastSAM: the YOLOv8-seg layout with one "object" score per cell.
            return outputs.count == 10 && has(64) && has(32) && has(1)
        case .orientedDetection: return outputs.count == 9 && has(15)
        case .superResolution: return (PictureModels.shape(model)?.scale ?? 0) > 1
        case .enhancement: return PictureModels.shape(model)?.scale == 1
        case .laneDetection: return outputs.count == 4
        case .face:
            // SCRFD: per stride 2 scores, 8 box distances, 20 landmark values; RetinaFace and LightFace:
            // SSD-style anchors (PostProcess.faceAnchors).
            return (outputs.count == 9 && has(20) && has(2) && has(8)) || PostProcess.faceAnchors(for: model) != nil
        case .textDetection: return outputs.count == 1 && outputs[0].features == 1 && (outputs[0].height ?? 0) > 100
        case .tagging, .describeObjects: return CLIPModels.pair(forImage: model.name) != nil
        case .stereoDepth: return model.name == StereoDepth.modelName
        // One face or person crop in, one vector out: CelebA's 40 attribute pairs, PETA's 35
        // attributes, or an appearance embedding.
        case .faceAttributes: return outputs.count == 1 && outputs[0].features == 2 * PostProcess.celebaAttributes.count
        case .personAttributes: return outputs.count == 1 && outputs[0].features == PostProcess.petaAttributes.count
        case .personReID: return outputs.count == 1 && outputs[0].order == "NC" && (outputs[0].features ?? 0) >= 128
        // 3DDFA's 62 face-model parameters, or MediaPipe's mesh (468 x 3 values and a face score).
        // 3DDFA (62 parameters) needs the Basel Face Model's landmark part, which a public checkout may not have.
        case .faceLandmarks: return (outputs.count == 1 && outputs[0].features == 62 && PostProcess.FaceModel3D.landmarks != nil)
            || (outputs.count == 2 && has(1404) && has(1))
        case .videoClassification:
            return model.inputs[0].features == 3 * VideoClip.frameCount && outputs.count == 1 && outputs[0].features == Labels.kinetics400.count
        case .findAnything: return false   // handled above
        }
    }

    /// YOLO26 detectors return three box tensors (4 channels) and three class tensors, with no NMS on the device.
    static func isYOLO26Detection(_ model: ModelInfo) -> Bool {
        model.outputs.count == 6 && model.outputs.filter { $0.features == 4 }.count == 3
    }

    /// YOLOv8-pose stores boxes as 64 distribution bins; YOLO26-pose stores 4 direct distances.
    static func isYOLO26Pose(_ model: ModelInfo) -> Bool {
        model.outputs.count == 9 && model.outputs.contains { $0.features == 4 }
    }

    /// YOLACT was trained on pictures stretched to its square input (the Model Zoo's mobilenet_ssd
    /// preprocessing), unlike the YOLO models' letterbox.
    static func isYOLACT(_ model: ModelInfo) -> Bool {
        model.outputs.count == 16 && model.outputs.contains { $0.features == 36 }
    }

    /// The model's input for the picture. A single-person pose model gets the whole picture as one
    /// person's crop (what the Model Zoo does without a box); `TopDownPose.run` crops each person instead.
    /// Face and person models likewise (`CropTasks.run` crops each one); the video model gets the picture
    /// repeated as a clip (`VideoClip` keeps a live source's frames).
    public static func prepare(_ image: CGImage, for model: ModelInfo, task: VisionTask) throws -> PreparedFrame {
        if CropTasks.tasks.contains(task) { return try CropTasks.wholePicture(image, model: model) }
        if task == .videoClassification { return try VideoClip.still(image, model: model) }
        if task == .pose, let style = PostProcess.heatmapStyle(for: model) {
            guard let pixels = RGBAPixels(image) else { throw StudioError.invalidInput("Could not read the picture.") }
            return TopDownPose.crop(pixels, box: CGRect(x: 0, y: 0, width: 1, height: 1), model: model, style: style)
        }
        // CenterPose was trained on pictures padded with black (the Zoo's centerpose preprocessing).
        return try ImagePrep.prepare(image, width: model.inputWidth, height: model.inputHeight, mode: isYOLACT(model) ? .stretch : task.resizeMode,
                                     region: task.sourceRegion, pad: PostProcess.isCenterPose(model) ? 0 : ImagePrep.padGrey)
    }

    public static func decode(_ tensors: [Tensor], task: VisionTask, model: ModelInfo, frame: PreparedFrame) -> VisionResult {
        switch task {
        case .detection:
            if model.hasDeviceNMS { return .detections(PostProcess.detections(tensors[0], frame: frame, labels: Labels.detection(for: model))) }
            if let head = PostProcess.detectorHead(for: model) { return .detections(PostProcess.rawDetections(tensors, head: head, frame: frame)) }
            return .detections(PostProcess.yolo26Detections(tensors, frame: frame))
        case .pose:
            if let style = PostProcess.heatmapStyle(for: model) { return .poses([PostProcess.heatmapPose(tensors[0], style: style, frame: frame)]) }
            if PostProcess.isCenterPose(model) { return .poses(PostProcess.centerPoses(tensors, frame: frame)) }
            return .poses(isYOLO26Pose(model) ? PostProcess.yolo26Poses(tensors, frame: frame) : PostProcess.yolov8Poses(tensors, frame: frame))
        case .classification: return .classifications(PostProcess.classifications(tensors[0]))
        case .depth: return .depth(PostProcess.depth(tensors[0]))
        case .semanticSegmentation: return .segmentation(PostProcess.segmentation(tensors[0], model: model))
        case .instanceSegmentation, .segmentEverything: return .instances(PostProcess.instances(tensors, model: model, frame: frame))
        case .orientedDetection: return .orientedDetections(PostProcess.orientedDetections(tensors, frame: frame))
        case .superResolution, .enhancement:
            guard let output = PostProcess.superResolved(tensors[0]) else { return .detections([]) }
            return .image(output)
        case .laneDetection: return .lanes(PostProcess.lanes(tensors, frame: frame))
        case .face: return .faces(PostProcess.faces(tensors, model: model, frame: frame))
        case .textDetection: return .text(PostProcess.textRegions(tensors[0], frame: frame))
        case .tagging: return .classifications([])  // needs prompts; see CLIPTagger
        case .describeObjects: return .described([])  // needs prompts and a detector; see ObjectCLIP
        case .findAnything: return .detections(OpenVocabulary.detections(tensors, frame: frame, labels: []))  // slots, not prompt names
        case .stereoDepth: return .depth(DepthMap(width: 0, height: 0, values: []))  // needs two pictures; see StereoDepth
        case .faceAttributes, .faceLandmarks, .personAttributes, .personReID:
            return CropTasks.decodeWhole(tensors, task: task, model: model, frame: frame)
        case .videoClassification: return .classifications(VideoClip.actions(tensors[0]))
        }
    }

    /// Prepares the image, runs the loaded model once, and decodes the output. The prompt tasks need `prompts`,
    /// embedded by the right text encoder: YOLO-World's bare names (`OpenVocabulary`), or the image encoder's
    /// own pair for tagging and describing objects.
    public static func run(_ task: VisionTask, on image: CGImage, device: any InferenceEngine,
                           prompts: CLIPTagger? = nil) async throws -> (result: VisionResult, timing: VisionTiming) {
        guard let model = await device.loadedModel else { throw StudioError.noModelLoaded }
        guard supports(task, model: model) else {
            throw StudioError.invalidInput("\(model.name) cannot be decoded for \(task.title) yet.")
        }
        let clock = ContinuousClock()
        var timing = VisionTiming()
        var mark = clock.now
        if task == .superResolution || task == .enhancement {
            // Whole photos go through tile by tile, not squeezed into one input frame.
            let picture = try await PictureModels.run(image, device: device)
            timing.inference = clock.now - mark
            return (.image(OutputImage(image: picture)), timing)
        }
        if task == .pose, TopDownPose.isTopDown(model) {
            // The person detector, then one pose run per person: all counted as inference.
            let poses = try await TopDownPose.run(image, model: model, device: device)
            timing.inference = clock.now - mark
            return (.poses(poses), timing)
        }
        if [.findAnything, .describeObjects, .tagging].contains(task) {
            guard let prompts else { throw StudioError.invalidInput("\(task.title) needs prompts.") }
            let result: VisionResult
            switch task {
            case .findAnything: result = .detections(try await OpenVocabulary.run(image, model: model, prompts: prompts, device: device))
            case .describeObjects: result = .described(try await ObjectCLIP.run(image, prompts: prompts, device: device))
            default: result = .classifications(prompts.classifications(try await prompts.tag(image, device: device)))
            }
            timing.inference = clock.now - mark
            return (result, timing)
        }
        if CropTasks.tasks.contains(task) {
            // The detector, then one run per face or person: all counted as inference.
            let result = try await CropTasks.run(task, on: image, model: model, device: device)
            timing.inference = clock.now - mark
            return (result, timing)
        }
        let frame = try prepare(image, for: model, task: task)
        timing.prepare = clock.now - mark

        mark = clock.now
        let tensors = try await device.infer(inputs: [frame.rgb])
        timing.inference = clock.now - mark

        mark = clock.now
        let result = decode(tensors, task: task, model: model, frame: frame)
        timing.decode = clock.now - mark
        return (result, timing)
    }
}
