// Face detectors with SSD-style anchors (RetinaFace, LightFace) and the choice between them and SCRFD.
// Port of StudioCore/PostProcess+AnchorFaces.swift.
import { Rect } from "./prep.js";
import { scrfdFaces } from "./decode.js";

/**
 * Prior boxes per stride: the square anchor sizes of each cell, in input pixels (Model Zoo configs
 * cfg/base/retinaface.yaml, lightface_slim_base.yaml). Hailo evaluates with scores 0.02 / 0.1 to measure
 * mAP; for showing faces the originals' demo thresholds are used.
 */
const RETINAFACE = { levels: [[8, [16, 32]], [16, [64, 128]], [32, [256, 512]]], scoreThreshold: 0.5, iouThreshold: 0.4, landmarks: true };
const LIGHTFACE = { levels: [[8, [10, 16, 24]], [16, [32, 48]], [32, [64, 96]], [64, [128, 192, 256]]], scoreThreshold: 0.6, iouThreshold: 0.3, landmarks: false };

/**
 * The anchor layout of a RetinaFace or LightFace model, recognised by its outputs: RetinaFace has 3 strides
 * x (8 box, 4 class, 20 landmark channels); LightFace 4 strides x (4 x anchors box, 2 x anchors class) with
 * 3, 2, 2 and 3 anchors.
 */
export function faceAnchors(model) {
  const f = model.outputs.map((o) => o.features ?? 0), count = (n) => f.filter((x) => x === n).length;
  if (f.length === 9 && count(20) === 3 && count(4) === 3 && count(8) === 3) return RETINAFACE;
  if (f.length === 8 && [...f].sort((a, b) => a - b).join() === "4,4,6,6,8,8,12,12") return LIGHTFACE;
  return null;
}

/** Whether `detector` gives the five landmarks face recognition aligns with (LightFace gives boxes only). */
export const findsLandmarks = (detector) => faceAnchors(detector)?.landmarks ?? true;

/**
 * Faces from an SSD-style detector, as the Model Zoo's FaceDetectionPostProc: per stride a box tensor
 * (anchors x dx, dy, dw, dh), a class tensor (anchors x background, face logits) and for RetinaFace
 * landmarks (anchors x 5 x (x, y)). Anchor centres (column + 0.5) x stride; centre = anchor + d / 10 x size,
 * size = anchor size x exp(d / 5); score = softmax face probability.
 */
export function anchorFaces(tensors, frame, anchors) {
  const L = 5, candidates = [];
  // softmax(l)[1] > t  <=>  l1 - l0 > log(t / (1 - t))
  const logitThreshold = Math.log(anchors.scoreThreshold / (1 - anchors.scoreThreshold));
  for (const [stride, sizes] of anchors.levels) {
    // The grid of this stride (LightFace's 240-pixel input rounds 3.75 rows up to 4).
    const grid = Math.ceil(frame.height / stride), k = sizes.length;
    const classes = tensors.find((t) => t.height === grid && t.features === 2 * k), boxes = tensors.find((t) => t.height === grid && t.features === 4 * k);
    if (!classes || !boxes) continue;
    const points = tensors.find((t) => t.height === grid && t.features === 2 * L * k);
    const width = classes.width, score = classes.values, delta = boxes.values, offset = points?.values;
    for (let cell = 0; cell < grid * width; cell++) {
      const cx = ((cell % width) + 0.5) * stride, cy = (Math.floor(cell / width) + 0.5) * stride;
      sizes.forEach((size, j) => {
        const anchor = cell * k + j, logit = score[2 * anchor + 1] - score[2 * anchor];
        if (!(logit > logitThreshold)) return;
        const b = 4 * anchor;
        const x = cx + (delta[b] / 10) * size, y = cy + (delta[b + 1] / 10) * size;
        const w = size * Math.exp(delta[b + 2] / 5), h = size * Math.exp(delta[b + 3] / 5);
        const landmarks = [];
        if (offset) for (let p = 0; p < L; p++) {
          const i = (anchor * L + p) * 2;
          landmarks.push(frame.toSource(cx + (offset[i] / 10) * size, cy + (offset[i + 1] / 10) * size));
        }
        candidates.push({ box: { x: x - w / 2, y: y - h / 2, width: w, height: h }, score: 1 / (1 + Math.exp(-logit)), landmarks });
      });
    }
  }
  candidates.sort((a, b) => b.score - a.score);
  const kept = [];
  for (const c of candidates) if (!kept.some((k) => Rect.iou(k.box, c.box) > anchors.iouThreshold)) kept.push(c);
  return kept.map((c) => ({ boundingBox: frame.toSourceRect(c.box), confidence: c.score, landmarks: c.landmarks }));
}

/** Faces from any face detector read here: SCRFD, RetinaFace or LightFace. */
export function faces(tensors, model, frame) {
  const anchors = faceAnchors(model);
  return anchors ? anchorFaces(tensors, frame, anchors) : scrfdFaces(tensors, frame);
}
