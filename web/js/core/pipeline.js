// Runs one picture through a loaded model and decodes it for a task (port of StudioCore/VisionPipeline.swift
// and the task list of VisionTypes.swift).
import { Labels, hasDeviceNMS, inputWidth, inputHeight } from "./catalog.js";
import { prepare, Rect } from "./prep.js";
import * as D from "./decode.js";
import * as D2 from "./decode2.js";
import { TextReader, FaceRecognition } from "./pipelines.js";
import { faces, faceAnchors } from "./faces.js";
import { heatmapStyle, heatmapPose, isTopDown, isCenterPose, centerPoses, TopDownPose } from "./pose-models.js";
import { CROP_TASKS, CropTasks } from "./crop-tasks.js";
import { CELEBA_ATTRIBUTES, PETA_ATTRIBUTES } from "./decode-crops.js";
import { VideoClip } from "./video-clip.js";
import { pairForImage, tag } from "./clip.js";

export const TASKS = {
  detection: { title: "Object detection", resize: "letterbox" },
  pose: { title: "Pose estimation", resize: "letterbox", catalog: ["pose", "single_person_pose_estimation"] },
  classification: { title: "Image classification", resize: "stretch" },
  depth: { title: "Depth estimation", resize: "stretch" },
  semantic_segmentation: { title: "Semantic segmentation", resize: "stretch" },
  instance_segmentation: { title: "Instance segmentation", resize: "letterbox" },
  // FastSAM: every object and region as a mask, without class names.
  segment_everything: { title: "Segment everything", resize: "letterbox", catalog: ["zero_shot_instance_segmentation"] },
  oriented_detection: { title: "Oriented boxes (aerial)", resize: "letterbox" },
  lane_detection: { title: "Lane detection", resize: "stretch", region: { x: 0, y: 0.2, width: 1, height: 0.8 } },
  face: { title: "Face detection", resize: "letterbox" },
  ocr: { title: "Read text (OCR)", resize: "letterbox" },
  super_resolution: { title: "Super-resolution ×2", resize: "stretch" },
  // One face or person at a time, found first by a detector (crop-tasks.js).
  face_attribute: { title: "Face attributes", resize: "stretch" },
  face_landmarks: { title: "Face landmarks", resize: "stretch", catalog: ["facial_landmark_detection"] },
  person_attribute: { title: "Person attributes", resize: "stretch" },
  person_re_id: { title: "Person re-identification", resize: "stretch" },
  // A clip of 16 frames in, the action in it out (Kinetics-400).
  video_classification: { title: "Action in video", resize: "stretch" },
  // A CLIP / SigLIP image encoder scored against prompts with its own text encoder (clip.js).
  clip: { title: "Tagging from text (CLIP)", resize: "stretch" },
};

/** The catalog's task names a task covers (a model's `tasks`); usually just its own. */
export const catalogTasks = (task) => TASKS[task]?.catalog ?? [task];

/** Other models that must be loaded next to `model` for the task. */
export function companionsFor(task, model) {
  if (task === "ocr") return [TextReader.recognizerName];
  if (task === "face") return [FaceRecognition.embedderName];
  if (task === "pose") return model && isTopDown(model) ? [TopDownPose.detectorName] : [];
  if (CROP_TASKS.has(task)) return [CropTasks.detectorName(task)];
  if (task === "clip") { const pair = model && pairForImage(model.name); return pair ? [pair.text] : []; }
  return [];
}

const isYOLO26Detection = (m) => m.outputs.length === 6 && m.outputs.filter((o) => o.features === 4).length === 3;
const isYOLO26Pose = (m) => m.outputs.length === 9 && m.outputs.some((o) => o.features === 4);
/** YOLACT was trained on pictures stretched to its square input (the Zoo's mobilenet_ssd preprocessing), not letterboxed. */
const isYOLACT = (m) => m.outputs.length === 16 && m.outputs.some((o) => o.features === 36);

/** True when the outputs of `model` can be decoded for `task`. */
export function supports(task, model) {
  if (!model.tasks.some((t) => catalogTasks(task).includes(t)) || model.inputs.length !== 1) return false;
  const outs = model.outputs, has = (f) => outs.some((o) => o.features === f);
  switch (task) {
    case "detection": return hasDeviceNMS(model) || isYOLO26Detection(model);
    // YOLOv8 / YOLO26-pose, CenterPose, or a single-person model after a person detector.
    case "pose": return (outs.length === 9 && has(51)) || isCenterPose(model) || isTopDown(model);
    case "classification": {
      if (outs.length !== 1) return false;
      const o = outs[0];
      return o.order === "NC" || (o.order === "NHWC" && (o.height ?? 1) === 1 && (o.width ?? 1) === 1 && [1000, 1001].includes(o.features ?? 0));
    }
    case "depth": return outs.length === 1 && outs[0].features === 1;
    // A class map (argmax in the model), or one score per class and pixel.
    case "semantic_segmentation": return outs.length === 1 && (outs[0].order === "NHW" || ((outs[0].features ?? 0) > 1 && (outs[0].height ?? 0) > 1 && ["NHWC", "NCHW"].includes(outs[0].order)));
    case "super_resolution": return outs.length === 1 && outs[0].features === 3;
    // SCRFD, or SSD-style anchors (RetinaFace, LightFace).
    case "face": return (outs.length === 9 && has(20) && has(2) && has(8)) || faceAnchors(model) !== null;
    // YOLOv8-seg / YOLO26-seg (10 outputs), YOLOv5-seg (4), YOLACT (16), or the stick's finished instances
    // (YOLOv5-seg "hpp": its web graph is the plain YOLOv5-seg, described by its .native.json).
    case "instance_segmentation":
      if (outs.length === 1) return outs[0].order === "NMS_BYTE_MASK";
      return has(32) && ((outs.length === 10 && (has(64) || has(4))) || outs.length === 4 || isYOLACT(model));
    // FastSAM: the YOLOv8-seg layout with one "object" score per cell.
    case "segment_everything": return outs.length === 10 && has(64) && has(32) && has(1);
    case "oriented_detection": return outs.length === 9 && has(15);
    case "lane_detection": return outs.length === 4;
    case "ocr": return outs.length === 1 && outs[0].features === 1 && (outs[0].height ?? 0) > 100;
    // One crop in, one vector out: CelebA's 40 attribute pairs, PETA's 35 attributes, an appearance embedding.
    case "face_attribute": return outs.length === 1 && outs[0].features === 2 * CELEBA_ATTRIBUTES.length;
    case "person_attribute": return outs.length === 1 && outs[0].features === PETA_ATTRIBUTES.length;
    case "person_re_id": return outs.length === 1 && outs[0].order === "NC" && (outs[0].features ?? 0) >= 128;
    // 3DDFA's 62 face-model parameters, or MediaPipe's mesh (468 x 3 values and a face score).
    case "face_landmarks": return (outs.length === 1 && outs[0].features === 62) || (outs.length === 2 && has(1404) && has(1));
    // An image encoder with a text encoder (the text encoders are only helpers).
    case "clip": return pairForImage(model.name) !== null;
    case "video_classification": return model.inputs[0].features === 3 * VideoClip.frameCount && outs.length === 1 && outs[0].features === Labels.kinetics400.length;
    default: return false;
  }
}

/**
 * The model's input for the picture. Single-person pose and crop models get the whole picture as their one
 * crop (run() crops each person instead); the video model gets the picture repeated as a clip.
 */
export function prepareFor(source, model, task) {
  if (CROP_TASKS.has(task)) return CropTasks.wholePicture(source, model);
  if (task === "video_classification") return VideoClip.still(source, model);
  if (task === "pose" && isTopDown(model)) return TopDownPose.wholePicture(source, model);
  // CenterPose was trained on pictures padded with black (the Zoo's centerpose preprocessing).
  return prepare(source, inputWidth(model), inputHeight(model), isYOLACT(model) ? "stretch" : TASKS[task]?.resize ?? "stretch",
    TASKS[task]?.region ?? Rect.whole(), isCenterPose(model) ? 0 : 114);
}

/** Returns { kind, value }: detections, poses, classifications, depth, segmentation, faces, image, instances, oriented, lanes, described or faceLandmarks. */
export async function decode(tensors, task, model, frame, gallery) {
  switch (task) {
    case "detection":
      return { kind: "detections", value: hasDeviceNMS(model) ? D.detections(tensors[0], frame, Labels.detection(model)) : D.yolo26Detections(tensors, frame) };
    case "pose": {
      const style = heatmapStyle(model);
      if (style) return { kind: "poses", value: [heatmapPose(tensors[0], style, frame)] };
      if (isCenterPose(model)) return { kind: "poses", value: centerPoses(tensors, frame) };
      return { kind: "poses", value: isYOLO26Pose(model) ? D.yolo26Poses(tensors, frame) : D.yolov8Poses(tensors, frame) };
    }
    case "classification": return { kind: "classifications", value: D.classifications(tensors[0]) };
    case "depth": return { kind: "depth", value: D.depth(tensors[0]) };
    case "semantic_segmentation": return { kind: "segmentation", value: D.segmentation(tensors[0], model) };
    case "face": return { kind: "faces", value: faces(tensors, model, frame) };
    case "super_resolution": return { kind: "image", value: D.superResolved(tensors[0]) };
    case "instance_segmentation": case "segment_everything": return { kind: "instances", value: D2.instances(tensors, frame) };
    case "oriented_detection": return { kind: "oriented", value: D2.orientedDetections(tensors, frame) };
    case "lane_detection": return { kind: "lanes", value: D2.lanes(tensors) };
    case "video_classification": return { kind: "classifications", value: VideoClip.actions(tensors[0]) };
    default: return CROP_TASKS.has(task) ? CropTasks.decodeWhole(tensors, task, model, frame, gallery) : { kind: "none", value: null };
  }
}

/**
 * Prepares, runs the engine's main model and decodes. Returns { result, timing: { prepare, inference, decode } ms, frame }.
 * options: clip (a VideoClip of a live source; `time` in seconds: video answers come every few frames, in
 * between the last one is returned) and gallery (re-identification's people so far; otherwise each picture
 * numbers its people from 1) and prompts (tagging from text: "car, bus, -empty road").
 */
export async function run(task, source, engine, { clip, time = 0, gallery, prompts } = {}) {
  const model = engine.loadedModel;
  if (!model) throw new Error("No model loaded.");
  if (!supports(task, model)) throw new Error(`${model.name} cannot be decoded for ${TASKS[task]?.title ?? task} yet.`);
  let t = performance.now();
  if (task === "clip") {
    // Embedding new prompts counts as preparing.
    const timing = { prepare: 0, inference: 0, decode: 0 };
    const { result, frame } = await tag(source, engine, prompts, timing);
    return { result, timing: { prepare: timing.prepare + timing.prompts, inference: timing.inference, decode: timing.decode }, frame };
  }
  if (task === "ocr") {
    const regions = await TextReader.read(source, engine);
    return { result: { kind: "text", value: regions }, timing: { prepare: 0, inference: performance.now() - t, decode: 0 }, frame: null };
  }
  // A detector, then one run per person or face: all counted as inference.
  if ((task === "pose" && isTopDown(model)) || CROP_TASKS.has(task)) {
    const result = task === "pose" ? { kind: "poses", value: await TopDownPose.run(source, model, engine) } : await CropTasks.run(task, source, model, engine, gallery);
    return { result, timing: { prepare: 0, inference: performance.now() - t, decode: 0 }, frame: null };
  }
  const frame = task === "video_classification" && clip ? clip.add(source, time, model) : prepareFor(source, model, task);
  const timing = { prepare: performance.now() - t };
  if (!frame) return { result: { kind: "classifications", value: clip.actions }, timing: { ...timing, inference: 0, decode: 0 }, frame: null };
  t = performance.now();
  const tensors = await engine.infer([frame.rgb]);
  timing.inference = performance.now() - t;
  t = performance.now();
  const result = await decode(tensors, task, model, frame, gallery);
  if (clip) clip.actions = result.value;
  timing.decode = performance.now() - t;
  return { result, timing, frame };
}
