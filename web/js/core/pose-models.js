// Pose models other than YOLO: single-person heatmap models after a person detector (ViTPose, MSPN,
// "top-down") and CenterPose. Port of StudioCore/TopDownPose.swift, PostProcess+Heatmaps.swift and
// PostProcess+CenterPose.swift.
import { Catalog, inputWidth, inputHeight } from "./catalog.js";
import { prepare, pixelsOf, warp, cropFrame, Rect } from "./prep.js";
import { detections } from "./decode.js";

// MARK: Heatmap models

/**
 * The heatmap style of a single-person pose model (17 heatmaps of a 256 x 192 crop): "unbiased" (ViTPose:
 * crop pixels 0 and the last on the crop's edges, DARK refinement) or "classic" (MSPN: the crop's centre at
 * width / 2, a quarter-cell step after a 5 x 5 blur). Both have one layout, so the name decides.
 */
export function heatmapStyle(model) {
  const o = model.outputs[0];
  if (model.outputs.length !== 1 || o.features !== 17 || !((o.height ?? 0) > 1) || !((o.width ?? 0) > 1) || !model.tasks.includes("single_person_pose_estimation")) return null;
  return model.name.startsWith("mspn") ? "classic" : "unbiased";
}

export const isTopDown = (model) => heatmapStyle(model) !== null;

/**
 * One person from the 17 heatmaps of a crop; `frame` maps crop pixels to the picture. Box = the crop's part
 * of the picture, confidence = mean keypoint score (TopDownPose replaces both with the detector's).
 */
export function heatmapPose(tensor, style, frame) {
  const w = tensor.width, h = tensor.height, k = tensor.features, values = tensor.values;
  const keypoints = [];
  for (let j = 0; j < k; j++) {
    const map = new Float32Array(w * h);
    for (let i = 0; i < w * h; i++) map[i] = values[i * k + j];
    const [x, y, score] = style === "unbiased" ? darkPeak(map, w, h) : classicPeak(map, w, h);
    // Heatmap cells to crop pixels: unbiased crops put the first and last cell on the crop's edges.
    const sx = style === "unbiased" ? frame.width / (w - 1) : frame.width / w, sy = style === "unbiased" ? frame.height / (h - 1) : frame.height / h;
    keypoints.push({ position: frame.toSource(x * sx, y * sy), confidence: score });
  }
  const mean = keypoints.reduce((s, p) => s + p.confidence, 0) / Math.max(keypoints.length, 1);
  return { confidence: mean, boundingBox: frame.toSourceRect(frame.contentRect), keypoints };
}

/** The highest cell (the first on ties, like numpy's argmax). */
function argmax(map) {
  let best = 0;
  for (let i = 1; i < map.length; i++) if (map[i] > map[best]) best = i;
  return best;
}

/**
 * ViTPose (post_dark_udp): log of the heatmap clipped to 0.001..50, edge-padded, one Newton step from the
 * peak. The Zoo's Gaussian blur before it has no effect (cv2's result is thrown away), so it is left out.
 */
function darkPeak(map, w, h) {
  const index = argmax(map), peak = map[index], px = index % w, py = Math.floor(index / w);
  if (!(peak > 0)) return [-1, -1, peak];
  const at = (x, y) => Math.log(Math.min(Math.max(map[Math.min(Math.max(y, 0), h - 1) * w + Math.min(Math.max(x, 0), w - 1)], 0.001), 50));
  const i = at(px, py);
  const dx = 0.5 * (at(px + 1, py) - at(px - 1, py)), dy = 0.5 * (at(px, py + 1) - at(px, py - 1));
  const dxx = at(px + 1, py) - 2 * i + at(px - 1, py), dyy = at(px, py + 1) - 2 * i + at(px, py - 1);
  const dxy = 0.5 * (at(px + 1, py + 1) - at(px + 1, py) - at(px, py + 1) + 2 * i - at(px - 1, py) - at(px, py - 1) + at(px - 1, py - 1));
  // Inverse Hessian (+ 1e-6 on the diagonal, as in the Zoo) times the gradient.
  const a = dxx + 1e-6, d = dyy + 1e-6, det = a * d - dxy * dxy;
  if (det === 0) return [px, py, peak];
  return [px - (d * dx - dxy * dy) / det, py - (a * dy - dxy * dx) / det, peak];
}

/**
 * MSPN: its heatmap peaks are not probabilities (about 220 where sure; the Zoo's peak / 255 + 0.5 is a COCO
 * rescoring that makes every keypoint look certain). Score = peak / 170, which follows ViTPose's scores on
 * the same crop (thumbs_up.jpg: ViTPose 0.5 is near an MSPN peak of 85).
 */
const MSPN_PEAK_FOR_CERTAIN = 170;

function classicPeak(map, w, h) {
  const blurred = gaussianBlur5(map, w, h), index = argmax(blurred);
  let peak = -Infinity;
  for (const v of map) peak = Math.max(peak, v);   // the Zoo rescales the blurred map to the original maximum
  const px = index % w, py = Math.floor(index / w);
  let x = px, y = py;
  if (px > 1 && px < w - 1 && py > 1 && py < h - 1) {
    const diffX = blurred[py * w + px + 1] - blurred[py * w + px - 1], diffY = blurred[(py + 1) * w + px] - blurred[(py - 1) * w + px];
    x += Math.sign(diffX) * 0.25 + 0.5;
    y += Math.sign(diffY) * 0.25 + 0.5;
  }
  return [x, y, Math.min(Math.max(peak / MSPN_PEAK_FOR_CERTAIN, 0), 1)];
}

/** cv2.GaussianBlur with a 5 x 5 kernel and sigma 0 (so 1.1), zeros outside. */
function gaussianBlur5(map, w, h) {
  const sigma = 0.3 * ((5 - 1) * 0.5 - 1) + 0.8;
  let kernel = [-2, -1, 0, 1, 2].map((t) => Math.exp(-(t * t) / (2 * sigma * sigma)));
  const total = kernel.reduce((a, b) => a + b, 0);
  kernel = kernel.map((k) => k / total);
  const rows = new Float32Array(w * h), out = new Float32Array(w * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    let sum = 0;
    for (let t = -2; t <= 2; t++) if (x + t >= 0 && x + t < w) sum += kernel[t + 2] * map[y * w + x + t];
    rows[y * w + x] = sum;
  }
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    let sum = 0;
    for (let t = -2; t <= 2; t++) if (y + t >= 0 && y + t < h) sum += kernel[t + 2] * rows[(y + t) * w + x];
    out[y * w + x] = sum;
  }
  return out;
}

// MARK: Top-down: a person detector, then one crop per person

export const TopDownPose = {
  /** Finds the people (small and fast). */
  detectorName: "yolov8s",
  personThreshold: 0.4,
  /** Each person costs one more pose run; more than this many (best scores first) are left out. */
  maxPeople: 6,
  /** Room added around the person's box (the Zoo's `padding`). */
  padding: 1.25,

  /** People and their keypoints in `image`; both models must be loaded. */
  async run(image, model, engine) {
    const style = heatmapStyle(model), detector = Catalog.model(this.detectorName);
    const frame = prepare(image, inputWidth(detector), inputHeight(detector), "letterbox");
    const found = detections((await engine.infer([frame.rgb], this.detectorName))[0], frame, []);
    const people = found.filter((d) => d.classIndex === 0 && d.confidence >= this.personThreshold).slice(0, this.maxPeople);
    if (!people.length) return [];
    const pixels = pixelsOf(image), poses = [];
    for (const person of people) {
      const crop = this.crop(pixels, person.boundingBox, model, style);
      const pose = heatmapPose((await engine.infer([crop.rgb], model.name))[0], style, crop);
      poses.push({ confidence: person.confidence, boundingBox: person.boundingBox, keypoints: pose.keypoints });
    }
    return poses;
  },

  /**
   * The model's input for the person in `box` (normalized), cut as the Zoo does (_bbox_xywh2cs): the box's
   * short side grown to the crop's 3:4 shape, then the padding; outside the picture black. The frame's
   * source region is the crop's rectangle in the picture (it may reach past the edges).
   */
  crop(pixels, box, model, style) {
    const inW = inputWidth(model), inH = inputHeight(model), aspect = inW / inH;
    let w = box.width * pixels.width, h = box.height * pixels.height;
    const cx = (box.x + box.width / 2) * pixels.width, cy = (box.y + box.height / 2) * pixels.height;
    if (w > aspect * h) h = w / aspect; else if (w < aspect * h) w = h * aspect;
    w *= this.padding; h *= this.padding;
    // Crop pixel u samples cx - w / 2 + u * step (cv2's pixel centres, hence - 0.5). Unbiased crops
    // (get_warp_matrix) put pixels 0 and inW - 1 on the edges; classic ones (get_affine_transform) the centre at inW / 2.
    const stepX = style === "unbiased" ? w / (inW - 1) : w / inW, stepY = style === "unbiased" ? h / (inH - 1) : h / inH;
    const rgb = warp(pixels, inW, inH, [stepX, cx - w / 2 - 0.5], [stepY, cy - h / 2 - 0.5]);
    return cropFrame(rgb, inW, inH, pixels, { x: cx - w / 2, y: cy - h / 2, width: w, height: h });
  },

  /** Without a detector the whole picture is one person's crop (what the Zoo does without a box). */
  wholePicture(image, model) {
    return this.crop(pixelsOf(image), Rect.whole(), model, heatmapStyle(model));
  },
};

// MARK: CenterPose

/** Six 128 x 128 maps: centres (1, sigmoid applied), box size (2), keypoints from the centre (34), centre offset (2), keypoint heatmaps (17, sigmoid applied), keypoint offset (2). */
export const isCenterPose = (model) => model.outputs.map((o) => o.features ?? 0).join() === "1,2,34,2,17,2";

/**
 * People from CenterPose, as the Zoo's centerpose_postprocessing.py: 3 x 3 local maxima of the centre map
 * give the people; each keypoint is the centre cell plus its regression, moved to the nearest keypoint-heatmap
 * peak (>= 0.1, inside the box, within 0.3 of its longer side). People below `scoreThreshold` are left out,
 * and so is one overlapping a better one by IoU > 0.7 (two neighbouring cells with the same score both pass).
 */
export function centerPoses(tensors, frame, scoreThreshold = 0.3, iouThreshold = 0.7, maxPeople = 20) {
  if (tensors.length !== 6) return [];
  const w = tensors[0].width, h = tensors[0].height, joints = 17;
  const [centers, size, fromCenter, centerOffset, jointMaps, jointOffset] = tensors.map((t) => t.values);
  const stride = frame.width / w;   // output cells to input pixels

  /** Cells that are the highest of their 3 x 3 neighbourhood (the Zoo's max-pool "NMS"), best first. */
  const peaks = (values, channels, channel, minimum, limit) => {
    const found = [];
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const v = values[(y * w + x) * channels + channel];
      if (!(v >= minimum)) continue;
      let isPeak = true;
      for (let dy = -1; dy <= 1 && isPeak; dy++) for (let dx = -1; dx <= 1; dx++) {
        const nx = x + dx, ny = y + dy;
        if ((dx || dy) && nx >= 0 && ny >= 0 && nx < w && ny < h && values[(ny * w + nx) * channels + channel] > v) { isPeak = false; break; }
      }
      if (isPeak) found.push({ cell: y * w + x, score: v });
    }
    return found.sort((a, b) => b.score - a.score).slice(0, limit);
  };

  const jointPeaks = Array.from({ length: joints }, (_, j) => peaks(jointMaps, joints, j, 0.1, 100)
    .map((p) => ({ x: (p.cell % w) + jointOffset[p.cell * 2], y: Math.floor(p.cell / w) + jointOffset[p.cell * 2 + 1], score: p.score })));

  const poses = [];
  for (const center of peaks(centers, 1, 0, scoreThreshold, maxPeople)) {
    const cell = center.cell, cx = cell % w, cy = Math.floor(cell / w);
    const bx = cx + centerOffset[cell * 2], by = cy + centerOffset[cell * 2 + 1], bw = size[cell * 2], bh = size[cell * 2 + 1];
    const left = bx - bw / 2, right = bx + bw / 2, top = by - bh / 2, bottom = by + bh / 2;
    const reach = Math.max(bottom - top, right - left) * 0.3;
    const keypoints = [];
    for (let j = 0; j < joints; j++) {
      // The regressed point starts from the centre cell itself (not the offset centre), as in the Zoo.
      let x = cx + fromCenter[cell * 34 + 2 * j], y = cy + fromCenter[cell * 34 + 2 * j + 1], score = 0;
      let nearest = null;
      for (const p of jointPeaks[j]) if (!nearest || Math.hypot(p.x - x, p.y - y) < Math.hypot(nearest.x - x, nearest.y - y)) nearest = p;
      if (nearest) {
        score = nearest.score;
        const inside = nearest.x >= left && nearest.x <= right && nearest.y >= top && nearest.y <= bottom;
        if (inside && Math.hypot(nearest.x - x, nearest.y - y) <= reach) { x = nearest.x; y = nearest.y; }
      }
      keypoints.push({ position: frame.toSource(x * stride, y * stride), confidence: score });
    }
    const box = frame.toSourceRect({ x: left * stride, y: top * stride, width: bw * stride, height: bh * stride });
    if (poses.some((p) => Rect.iou(p.boundingBox, box) > iouThreshold)) continue;
    poses.push({ confidence: center.score, boundingBox: box, keypoints });
  }
  return poses;
}
