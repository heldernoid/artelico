// Decoders that turn model outputs (in the stick's layout, as plain floats) into results.
// Port of StudioCore/PostProcess*.swift; each function documents the layout it expects.
import { Labels } from "./catalog.js";
import { Rect } from "./prep.js";

const sigmoid = (x) => 1 / (1 + Math.exp(-x));
const iou = Rect.iou;

/** Groups tensors by grid height. */
function byGrid(tensors) {
  const groups = new Map();
  for (const t of tensors) { if (!groups.has(t.height)) groups.set(t.height, []); groups.get(t.height).push(t); }
  return groups;
}

/** Greedy NMS, best score first. `same(a, b)` limits suppression (e.g. to one class). */
function suppress(candidates, threshold, max = Infinity, same = () => true) {
  candidates.sort((a, b) => b.score - a.score);
  const kept = [];
  for (const c of candidates) {
    if (kept.length >= max) break;
    if (!kept.some((k) => same(k, c) && iou(k.box, c.box) > threshold)) kept.push(c);
  }
  return kept;
}

// MARK: Detection

/** NMS_BY_CLASS: per class a count, then (y_min, x_min, y_max, x_max, score) normalized to the input. */
export function detections(tensor, frame, labels, minimumConfidence = 0) {
  const v = tensor.values, classCount = tensor.stream.classes ?? 0, maxBoxes = tensor.stream.maxBoxes ?? 0;
  const found = [];
  let o = 0;
  for (let c = 0; c < classCount; c++) {
    if (o >= v.length) break;
    const count = v[o++];
    if (count < 0 || count > maxBoxes) break;
    for (let k = 0; k < count; k++) {
      const [y0, x0, y1, x1, score] = v.subarray(o, o + 5);
      o += 5;
      if (score < minimumConfidence) continue;
      const box = { x: x0 * frame.width, y: y0 * frame.height, width: (x1 - x0) * frame.width, height: (y1 - y0) * frame.height };
      found.push({ label: labels[c] ?? `class ${c}`, classIndex: c, confidence: score, boundingBox: frame.toSourceRect(box) });
    }
  }
  return found.sort((a, b) => b.confidence - a.confidence);
}

/** YOLO26: per stride 4 box distances (in cells) and class logits; one box per object, light NMS. */
export function yolo26Detections(tensors, frame, scoreThreshold = 0.25, iouThreshold = 0.7, maxDetections = 300) {
  const logit = Math.log(scoreThreshold / (1 - scoreThreshold));
  const candidates = [];
  for (const [grid, group] of byGrid(tensors)) {
    const boxes = group.find((t) => t.features === 4), scores = group.find((t) => t.features !== 4 && t.features > 1);
    if (!boxes || !scores || boxes.width !== scores.width) continue;
    const classes = scores.features, width = scores.width;
    const sx = frame.width / width, sy = frame.height / grid;
    const s = scores.values, b = boxes.values;
    for (let i = 0; i < s.length; i++) {
      if (s[i] < logit) continue;
      const cell = Math.floor(i / classes);
      const col = (cell % width) + 0.5, row = Math.floor(cell / width) + 0.5;
      const [l, t, r, bt] = b.subarray(cell * 4, cell * 4 + 4);
      const box = { x: (col - l) * sx, y: (row - t) * sy, width: (l + r) * sx, height: (t + bt) * sy };
      if (box.width > 0 && box.height > 0) candidates.push({ box, score: sigmoid(s[i]), classIndex: i % classes });
    }
  }
  const classCount = Math.max(0, ...tensors.map((t) => t.features));
  const labels = classCount === Labels.coco.length ? Labels.coco : [];
  return suppress(candidates, iouThreshold, maxDetections, (a, b) => a.classIndex === b.classIndex).map((c) => ({
    label: labels[c.classIndex] ?? `class ${c.classIndex}`, classIndex: c.classIndex, confidence: c.score, boundingBox: frame.toSourceRect(c.box),
  }));
}

// MARK: Classification

/** One vector of scores; softmax unless they already are probabilities. Top `top`, ImageNet labels by default. */
export function classifications(tensor, top = 5, names = Labels.imagenet) {
  const scores = Float32Array.from(tensor.values);
  const sum = scores.reduce((a, b) => a + b, 0);
  const probabilities = scores.every((v) => v >= 0 && v <= 1.0001) && sum > 0.7 && sum < 1.3;
  if (!probabilities) {
    const peak = Math.max(...scores);
    let total = 0;
    for (let i = 0; i < scores.length; i++) { scores[i] = Math.exp(scores[i] - peak); total += scores[i]; }
    for (let i = 0; i < scores.length; i++) scores[i] /= total;
  } else if (Math.abs(sum - 1) > 0.001) {
    for (let i = 0; i < scores.length; i++) scores[i] /= sum;
  }
  const offset = scores.length === names.length + 1 ? 1 : 0;
  return [...scores].map((p, i) => ({ p, i })).sort((a, b) => b.p - a.p).slice(0, top)
    .map(({ p, i }) => ({ label: names[i - offset] ?? `class ${i}`, classIndex: i, probability: p }));
}

// MARK: Depth and segmentation

/** scdepthv3: logits; depth = 1 / (sigmoid(x) * 10 + 0.009), as hailo-apps. */
export function depth(tensor) {
  const values = Float32Array.from(tensor.values, (x) => 1 / (sigmoid(x) * 10 + 0.009));
  return { width: tensor.width, height: tensor.height, values };
}

/**
 * One class index per pixel: the model already took the argmax (one channel), or it gives one score per
 * class (deeplab_v3_mobilenet_v2: 21 Pascal VOC classes; unet_mobilenet_v2: 3 pet trimap classes) and the
 * best class is taken here. The map carries its class set: labels, colours and the class left untinted.
 */
export function segmentation(tensor, model) {
  const set = Labels.segmentation(model), C = tensor.features, v = tensor.values, n = tensor.width * tensor.height;
  let classes;
  if (C <= 1) classes = Uint8Array.from(v, (x) => Math.round(x));
  else {
    classes = new Uint8Array(n);
    for (let p = 0; p < n; p++) {
      let best = 0;
      for (let c = 1; c < C; c++) if (v[p * C + c] > v[p * C + best]) best = c;
      classes[p] = best;
    }
  }
  return { width: tensor.width, height: tensor.height, classes, ...set };
}

// MARK: Pose

/** YOLOv8-pose: per stride 64 box bins (DFL), 1 score (sigmoid applied), 17 x (x, y, conf logit). */
export function yolov8Poses(tensors, frame, scoreThreshold = 0.3, iouThreshold = 0.7) {
  const K = 17, bins = 16, candidates = [];
  for (const [grid, group] of byGrid(tensors)) {
    const boxes = group.find((t) => t.features === 4 * bins), scores = group.find((t) => t.features === 1), points = group.find((t) => t.features === K * 3);
    if (!boxes || !scores || !points) continue;
    const stride = frame.height / grid, width = scores.width;
    const s = scores.values, b = boxes.values, p = points.values;
    for (let cell = 0; cell < s.length; cell++) {
      if (s[cell] < scoreThreshold) continue;
      const col = cell % width, row = Math.floor(cell / width);
      const d = [0, 0, 0, 0];
      for (let side = 0; side < 4; side++) {
        const base = (cell * 4 + side) * bins;
        let peak = -Infinity;
        for (let k = 0; k < bins; k++) peak = Math.max(peak, b[base + k]);
        let total = 0, expectation = 0;
        for (let k = 0; k < bins; k++) { const w = Math.exp(b[base + k] - peak); total += w; expectation += w * k; }
        d[side] = expectation / total;
      }
      const cx = col + 0.5, cy = row + 0.5;
      const box = { x: (cx - d[0]) * stride, y: (cy - d[1]) * stride, width: (d[0] + d[2]) * stride, height: (d[1] + d[3]) * stride };
      const keypoints = [];
      for (let k = 0; k < K; k++) {
        const i = cell * K * 3 + k * 3;
        keypoints.push({ position: frame.toSource((p[i] * 2 + col) * stride, (p[i + 1] * 2 + row) * stride), confidence: sigmoid(p[i + 2]) });
      }
      candidates.push({ box, score: s[cell], keypoints });
    }
  }
  return suppress(candidates, iouThreshold).map((c) => ({ confidence: c.score, boundingBox: frame.toSourceRect(c.box), keypoints: c.keypoints }));
}

/** YOLO26-pose: per stride 4 box distances, 1 person logit, 17 x (dx, dy, conf logit) from the cell centre. */
export function yolo26Poses(tensors, frame, scoreThreshold = 0.25, iouThreshold = 0.7, maxDetections = 300) {
  const K = 17, logit = Math.log(scoreThreshold / (1 - scoreThreshold)), candidates = [];
  for (const [grid, group] of byGrid(tensors)) {
    const boxes = group.find((t) => t.features === 4), scores = group.find((t) => t.features === 1), points = group.find((t) => t.features === K * 3);
    if (!boxes || !scores || !points || boxes.width !== scores.width || points.width !== scores.width) continue;
    const width = scores.width, sx = frame.width / width, sy = frame.height / grid;
    const s = scores.values, b = boxes.values, p = points.values;
    for (let cell = 0; cell < s.length; cell++) {
      if (s[cell] < logit) continue;
      const col = (cell % width) + 0.5, row = Math.floor(cell / width) + 0.5;
      const [l, t, r, bt] = b.subarray(cell * 4, cell * 4 + 4);
      const box = { x: (col - l) * sx, y: (row - t) * sy, width: (l + r) * sx, height: (t + bt) * sy };
      if (box.width <= 0 || box.height <= 0) continue;
      const keypoints = [];
      for (let k = 0; k < K; k++) {
        const i = (cell * K + k) * 3;
        keypoints.push({ position: frame.toSource((col + p[i]) * sx, (row + p[i + 1]) * sy), confidence: sigmoid(p[i + 2]) });
      }
      candidates.push({ box, score: sigmoid(s[cell]), keypoints });
    }
  }
  return suppress(candidates, iouThreshold, maxDetections).map((c) => ({ confidence: c.score, boundingBox: frame.toSourceRect(c.box), keypoints: c.keypoints }));
}

/** COCO skeleton (pairs of keypoint indices). */
export const SKELETON = [[15, 13], [13, 11], [16, 14], [14, 12], [11, 12], [5, 11], [6, 12], [5, 6], [5, 7], [6, 8],
  [7, 9], [8, 10], [1, 2], [0, 1], [0, 2], [1, 3], [2, 4], [3, 5], [4, 6]];

// MARK: Faces

/** scrfd_10g: per stride 2 anchors: scores (sigmoid applied), 2 x 4 distances, 2 x 5 x (x, y) landmarks. */
export function scrfdFaces(tensors, frame, scoreThreshold = 0.4, iouThreshold = 0.4) {
  const L = 5, candidates = [];
  for (const [grid, group] of byGrid(tensors)) {
    if (grid <= 0) continue;
    const scores = group.reduce((a, b) => (b.features < a.features ? b : a));
    const anchors = scores.features;
    const boxes = group.find((t) => t.features === anchors * 4), points = group.find((t) => t.features === anchors * L * 2);
    if (!anchors || !boxes || !points) continue;
    const stride = frame.height / grid, width = scores.width;
    const s = scores.values, d = boxes.values, o = points.values;
    for (let index = 0; index < scores.height * width * anchors; index++) {
      const confidence = s[index];
      if (!(confidence > scoreThreshold)) continue;
      const cell = Math.floor(index / anchors);
      const cx = (cell % width) * stride, cy = Math.floor(cell / width) * stride;
      const left = cx - d[index * 4] * stride, top = cy - d[index * 4 + 1] * stride;
      const right = cx + d[index * 4 + 2] * stride, bottom = cy + d[index * 4 + 3] * stride;
      if (right <= left || bottom <= top) continue;
      const landmarks = [];
      for (let k = 0; k < L; k++) {
        const base = index * L * 2 + k * 2;
        landmarks.push(frame.toSource(cx + o[base] * stride, cy + o[base + 1] * stride));
      }
      candidates.push({ box: { x: left, y: top, width: right - left, height: bottom - top }, score: confidence, landmarks });
    }
  }
  return suppress(candidates, iouThreshold).map((c) => ({ boundingBox: frame.toSourceRect(c.box), confidence: c.score, landmarks: c.landmarks }));
}

// MARK: Super-resolution

/** real_esrgan_x2: RGB at twice the input size, values 0..1. Returns { width, height, rgba }. */
export function superResolved(tensor) {
  if (tensor.features !== 3) return null;
  const n = tensor.width * tensor.height, v = tensor.values, rgba = new Uint8ClampedArray(n * 4);
  for (let i = 0; i < n; i++) {
    rgba[4 * i] = v[3 * i] * 255 + 0.5; rgba[4 * i + 1] = v[3 * i + 1] * 255 + 0.5; rgba[4 * i + 2] = v[3 * i + 2] * 255 + 0.5; rgba[4 * i + 3] = 255;
  }
  return { width: tensor.width, height: tensor.height, rgba };
}
