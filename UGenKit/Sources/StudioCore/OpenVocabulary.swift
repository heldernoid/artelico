import CoreGraphics
import Foundation

/// Open-vocabulary detection with YOLO-World (yolo_world_v2s): boxes for whatever the typed prompts name.
///
/// The model has two inputs: the picture (640 x 640, letterboxed, centred, grey 114) and 80 text embeddings
/// (1 x 80 x 512), one per class it can look for. Hailo made those with CLIP ViT-B/32's text model and its
/// projection, L2-normalised, from the bare class names (create_coco_tfrecord_with_text_embeddings.py:
/// CLIPTextModelWithProjection on "person", "bicycle", ...); the network normalises them again itself. Here they
/// come from clip_vit_b_32_text_encoder on the same device, as for tagging. Fewer prompts than slots are repeated
/// to fill them: the network's text-guided attention takes a maximum over the classes and each class score uses
/// only its own embedding, so copies change nothing and the extra slots are ignored.
///
/// Outputs per stride (8, 16, 32): 4 x 16 distance bins (DFL) and one score per slot, through a sigmoid on the
/// chip (the .alls' change_output_activation). Decoding follows the Model Zoo's YoloWorldPostProc: box centre
/// (column + 0.5) x stride, clipped to the input, class-wise NMS at IoU 0.7.
public enum OpenVocabulary {
    /// The text encoder whose embeddings the model was calibrated with.
    public static let textEncoderName = "clip_vit_b_32_text_encoder"
    /// Below this, boxes are dropped. The Zoo's 0.001 is for mAP; open-vocabulary scores run lower than
    /// COCO detectors' (bus.jpg: people 0.92, sunglasses 0.28), so this is lower than the other decoders' 0.3.
    public static let scoreThreshold: Float = 0.25
    static let iouThreshold: Float = 0.7
    static let bins = 16

    /// A picture input and a 1 x N x 512 text input, with a DFL box and a class output per stride.
    public static func isOpenVocabulary(_ model: ModelInfo) -> Bool {
        guard model.inputs.count == 2, model.inputs[0].features == 3 else { return false }
        let text = model.inputs[1]
        return (text.height ?? 0) == 1 && slots(of: model) > 1 && text.features == 512
            && model.outputs.count == 6 && model.outputs.filter { $0.features == 4 * bins }.count == 3
            && model.outputs.filter { $0.features == slots(of: model) }.count == 3
    }

    /// How many classes the model looks for at once (80 for yolo_world_v2s).
    public static func slots(of model: ModelInfo) -> Int { model.inputs.count == 2 ? model.inputs[1].width ?? 0 : 0 }

    /// The text input: one unit-length embedding per slot, the prompts repeated to fill all of them,
    /// quantized as the stick takes it (the Core ML engine turns it back into values).
    public static func textFrame(_ embeddings: [[Float]], model: ModelInfo) throws -> [UInt8] {
        let count = slots(of: model)
        guard count > 0, let first = embeddings.first, let stream = model.inputs.last, first.count == stream.features else {
            throw StudioError.invalidInput("\(model.name) needs 1 to \(count) prompt embeddings of \(model.inputs.last?.features ?? 0) values.")
        }
        let values = (0..<count).flatMap { embeddings[$0 % embeddings.count] }
        return quantized(values, stream: stream)
    }

    /// raw = round(value / scale + zero point), clamped to the input type's range (HailoRT's quantization).
    static func quantized(_ values: [Float], stream: StreamInfo) -> [UInt8] {
        let zero = stream.qpZp ?? 0, scale = stream.qpScale ?? 1
        if stream.type == "UINT16" {
            return values.flatMap { value -> [UInt8] in
                let raw = UInt16(min(max((value / scale + zero).rounded(.toNearestOrEven), 0), 65535))
                return [UInt8(raw & 0xFF), UInt8(raw >> 8)]
            }
        }
        return values.map { UInt8(min(max(($0 / scale + zero).rounded(.toNearestOrEven), 0), 255)) }
    }

    /// The prompts' boxes in `image`. `prompts` holds the bare names embedded by clip_vit_b_32_text_encoder
    /// (`CLIPTagger.setPrompts(_:device:prefix: "")`); a box whose best prompt is a negative ("-tree") is dropped.
    public static func run(_ image: CGImage, model: ModelInfo, prompts: CLIPTagger, device: any InferenceEngine) async throws -> [Detection] {
        let used = Array(prompts.prompts.prefix(slots(of: model)))
        guard !used.isEmpty else { throw StudioError.invalidInput("Type what to find, for example: red backpack, dog, bicycle.") }
        let frame = try VisionPipeline.prepare(image, for: model, task: .findAnything)
        let text = try textFrame(used.map(\.embedding), model: model)
        let tensors = try await device.infer(inputs: [frame.rgb, text], model: model.name)
        return detections(tensors, frame: frame, labels: used.map(\.text)).filter { !used[$0.classIndex].negative }
    }

    /// Decodes the six outputs. Only the first `labels.count` slots are read (the rest repeat them); without
    /// labels (replays, native-map) every slot is a class named "prompt N".
    public static func detections(_ tensors: [Tensor], frame: PreparedFrame, labels: [String], threshold: Float = scoreThreshold) -> [Detection] {
        var candidates: [PostProcess.DetectorCandidate] = []
        let inputW = Float(frame.width), inputH = Float(frame.height)
        for (grid, group) in Dictionary(grouping: tensors, by: { $0.height }) {
            guard let boxes = group.first(where: { $0.features == 4 * bins }), let scores = group.first(where: { $0.features != 4 * bins }) else { continue }
            let classes = labels.isEmpty ? scores.features : min(labels.count, scores.features)
            let stride = inputH / Float(grid)
            let score = ValueReader(scores), box = ValueReader(boxes)
            for cell in 0..<(grid * scores.width) {
                // Every prompt over the threshold counts (combined_non_max_suppression is per class).
                let passed = (0..<classes).compactMap { c -> (Int, Float)? in
                    let s = score[cell * scores.features + c]
                    return s >= threshold ? (c, s) : nil
                }
                guard !passed.isEmpty else { continue }
                // Each side's distance is the expectation of a softmax over its 16 bins.
                var distances = [Float](repeating: 0, count: 4)
                for side in 0..<4 {
                    let base = cell * 4 * bins + side * bins
                    var logits = [Float](repeating: 0, count: bins)
                    for b in 0..<bins { logits[b] = box[base + b] }
                    let peak = logits.max() ?? 0
                    var total: Float = 0, expectation: Float = 0
                    for b in 0..<bins {
                        let weight = exp(logits[b] - peak)
                        total += weight
                        expectation += weight * Float(b)
                    }
                    distances[side] = expectation / total * stride
                }
                let cx = (Float(cell % scores.width) + 0.5) * stride, cy = (Float(cell / scores.width) + 0.5) * stride
                let x0 = max(cx - distances[0], 0), y0 = max(cy - distances[1], 0)
                let x1 = min(cx + distances[2], inputW), y1 = min(cy + distances[3], inputH)
                let rect = CGRect(x: CGFloat(x0), y: CGFloat(y0), width: CGFloat(x1 - x0), height: CGFloat(y1 - y0))
                candidates += passed.map { .init(box: rect, score: $0.1, classIndex: $0.0) }
            }
        }
        let names = labels.isEmpty ? (0..<(tensors.first { $0.features != 4 * bins }?.features ?? 0)).map { "prompt \($0 + 1)" } : labels
        return PostProcess.finish(candidates, labels: names, frame: frame, iou: iouThreshold)
    }
}
