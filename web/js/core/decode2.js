// More decoders (port of StudioCore/PostProcess+Segmentation/+Oriented/+Lanes/+Text.swift). Outputs are
// plain floats in the stick's NHWC layout.
import { Labels } from "./catalog.js";
import { Rect } from "./prep.js";

const sigmoid = (x) => 1 / (1 + Math.exp(-x));

function groupByHeight(tensors) {
  const m = new Map();
  for (const t of tensors) { if (!m.has(t.height)) m.set(t.height, []); m.get(t.height).push(t); }
  return m;
}

/** Softmax expectation over `bins` values starting at `base` (DFL). */
function dfl(v, base, bins) {
  let peak = -Infinity;
  for (let k = 0; k < bins; k++) peak = Math.max(peak, v[base + k]);
  let total = 0, e = 0;
  for (let k = 0; k < bins; k++) { const w = Math.exp(v[base + k] - peak); total += w; e += w * k; }
  return e / total;
}

// MARK: Instance segmentation

const V5_ANCHORS = { 8: [[10, 13], [16, 30], [33, 23]], 16: [[30, 61], [62, 45], [59, 119]], 32: [[116, 90], [156, 198], [373, 326]] };

/**
 * Instance segmentation, recognised by the outputs' layout (prototypes = the largest grid):
 * YOLOv5-seg (3 anchor heads; also the "hpp" models, whose web graphs are plain YOLOv5-seg), YOLACT (5 grids),
 * YOLO26-seg (4 box distances per stride), YOLOv8-seg (64 DFL bins). FastSAM has the YOLOv8-seg layout with
 * one "object" score: its instances are "object 1, 2, ..." with class -1.
 * Each instance: { detection, maskWidth, maskHeight, mask }.
 */
export function instances(tensors, frame) {
  const prototypes = tensors.reduce((a, b) => (b.height * b.width > a.height * a.width ? b : a));
  const heads = tensors.filter((t) => t !== prototypes);
  const M = prototypes.features, threshold = 0.3;
  let candidates, iouThreshold;
  if (heads.length === 3 && heads.every((t) => t.features % 3 === 0 && t.features / 3 > 5 + M)) {
    candidates = v5Candidates(heads, frame, M, threshold); iouThreshold = 0.6;
  } else if (new Set(heads.map((t) => t.height)).size === 5) {
    candidates = yolactCandidates(heads, frame, M, threshold); iouThreshold = 0.5;
  } else if (heads.some((t) => t.features === 4)) {
    candidates = yolo26Candidates(heads, frame, M, threshold); iouThreshold = 0.7;
  } else {
    candidates = v8Candidates(heads, frame, M, threshold); iouThreshold = 0.7;
  }
  const numbered = heads.some((t) => t.features === 1);
  candidates.sort((a, b) => b.score - a.score);
  const kept = [];
  for (const c of candidates) {
    if (kept.some((k) => k.classIndex === c.classIndex && Rect.iou(k.box, c.box) > iouThreshold)) continue;
    kept.push(c);
    if (kept.length >= 100) break;
  }
  const pw = prototypes.width, ph = prototypes.height, sx = pw / frame.width, sy = ph / frame.height;
  const cropX = Math.min(Math.max(Math.round(frame.contentRect.x * sx), 0), pw - 1);
  const cropY = Math.min(Math.max(Math.round(frame.contentRect.y * sy), 0), ph - 1);
  const mw = Math.min(Math.max(Math.round(frame.contentRect.width * sx), 1), pw - cropX);
  const mh = Math.min(Math.max(Math.round(frame.contentRect.height * sy), 1), ph - cropY);
  const proto = prototypes.values;
  return kept.map((c, rank) => {
    const mask = new Uint8Array(mw * mh);
    const x0 = Math.max(Math.ceil(c.box.x * sx), cropX), x1 = Math.min(Math.ceil((c.box.x + c.box.width) * sx), cropX + mw);
    const y0 = Math.max(Math.ceil(c.box.y * sy), cropY), y1 = Math.min(Math.ceil((c.box.y + c.box.height) * sy), cropY + mh);
    for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
      const base = (y * pw + x) * M;
      let sum = 0;
      for (let k = 0; k < M; k++) sum += c.coefficients[k] * proto[base + k];
      if (sum > 0) mask[(y - cropY) * mw + (x - cropX)] = 255;
    }
    const label = numbered ? `object ${rank + 1}` : Labels.coco[c.classIndex] ?? `class ${c.classIndex}`;
    return { detection: { label, classIndex: numbered ? -1 : c.classIndex, confidence: c.score, boundingBox: frame.toSourceRect(c.box) }, maskWidth: mw, maskHeight: mh, mask };
  });
}

function v8Candidates(heads, frame, M, threshold) {
  const out = [], bins = 16;
  for (const [grid, group] of groupByHeight(heads)) {
    const boxes = group.find((t) => t.features === 4 * bins);
    const masks = group.find((t) => t.features === M && t !== boxes);
    const scores = group.find((t) => t !== boxes && t !== masks);
    if (!boxes || !masks || !scores) continue;
    const stride = frame.height / grid, width = scores.width, C = scores.features;
    const s = scores.values, b = boxes.values, m = masks.values;
    for (let cell = 0; cell < scores.height * width; cell++) {
      let best = -Infinity, bestClass = 0;
      for (let c = 0; c < C; c++) if (s[cell * C + c] > best) { best = s[cell * C + c]; bestClass = c; }
      if (best < threshold) continue;
      const d = [0, 1, 2, 3].map((side) => dfl(b, (cell * 4 + side) * bins, bins));
      const cx = (cell % width) + 0.5, cy = Math.floor(cell / width) + 0.5;
      out.push({ box: { x: (cx - d[0]) * stride, y: (cy - d[1]) * stride, width: (d[0] + d[2]) * stride, height: (d[1] + d[3]) * stride },
        score: best, classIndex: bestClass, coefficients: m.slice(cell * M, cell * M + M) });
    }
  }
  return out;
}

/** YOLO26-seg: per stride 4 box distances (cells), class logits and mask coefficients. */
function yolo26Candidates(heads, frame, M, threshold) {
  const out = [], logit = Math.log(threshold / (1 - threshold));
  for (const [grid, group] of groupByHeight(heads)) {
    const boxes = group.find((t) => t.features === 4), masks = group.find((t) => t.features === M);
    const scores = group.find((t) => t.features !== 4 && t.features !== M);
    if (!boxes || !masks || !scores || boxes.width !== scores.width || masks.width !== scores.width) continue;
    const C = scores.features, width = scores.width, sx = frame.width / width, sy = frame.height / grid;
    const s = scores.values, b = boxes.values, m = masks.values;
    for (let i = 0; i < s.length; i++) {
      if (s[i] < logit) continue;
      const cell = Math.floor(i / C), col = (cell % width) + 0.5, row = Math.floor(cell / width) + 0.5;
      const [l, t, r, bt] = b.subarray(cell * 4, cell * 4 + 4);
      const box = { x: (col - l) * sx, y: (row - t) * sy, width: (l + r) * sx, height: (t + bt) * sy };
      if (box.width > 0 && box.height > 0) out.push({ box, score: sigmoid(s[i]), classIndex: i % C, coefficients: m.slice(cell * M, cell * M + M) });
    }
  }
  return out;
}

/** YOLACT anchor sizes (input pixels, 512 input) per grid from the finest: 24 x 2^level x (1, 2^(1/3), 2^(2/3)) (cfg/base/yolact.yaml). */
const YOLACT_SCALES = [0, 1, 2, 3, 4].map((level) => [0, 1, 2].map((step) => 24 * 2 ** (level + step / 3)));
const YOLACT_RATIOS = [1, 0.5, 2];

/**
 * YOLACT: per grid 9 anchors per cell (3 scales x 3 ratios): 9 x 4 box offsets (SSD-style, variances 0.1 /
 * 0.2), 9 x 81 class logits (0 = background, softmax), 9 x 32 mask coefficients (tanh applied). Each anchor
 * keeps its best non-background class.
 */
function yolactCandidates(heads, frame, M, threshold) {
  const A = 9, out = [];
  // softmax p(best) <= e^best / (e^best + e^background): a cell must clear this logit gap first.
  const gap = Math.log(threshold / (1 - threshold));
  [...groupByHeight(heads)].sort((a, b) => b[0] - a[0]).slice(0, YOLACT_SCALES.length).forEach(([grid, group], level) => {
    const boxes = group.find((t) => t.features === A * 4), coefficients = group.find((t) => t.features === A * M);
    const scores = group.find((t) => t !== boxes && t !== coefficients);
    if (!boxes || !coefficients || !scores || scores.features % A !== 0) return;
    const C = scores.features / A, width = scores.width, s = scores.values, b = boxes.values, m = coefficients.values;
    for (let cell = 0; cell < grid * width; cell++) {
      const cx = ((cell % width) + 0.5) / width, cy = (Math.floor(cell / width) + 0.5) / grid;
      for (let a = 0; a < A; a++) {
        const base = (cell * A + a) * C, background = s[base];
        let best = -Infinity, bestClass = 0;
        for (let c = 1; c < C; c++) if (s[base + c] > best) { best = s[base + c]; bestClass = c; }
        if (best - background < gap) continue;
        let total = 0;
        for (let c = 0; c < C; c++) total += Math.exp(s[base + c] - best);
        const probability = 1 / total;
        if (probability < threshold) continue;
        const scale = YOLACT_SCALES[level][Math.floor(a / 3)], ratio = Math.sqrt(YOLACT_RATIOS[a % 3]);
        const pw = (scale * ratio) / frame.width, ph = scale / ratio / frame.height, o = (cell * A + a) * 4;
        const x = cx + b[o] * 0.1 * pw, y = cy + b[o + 1] * 0.1 * ph, w = pw * Math.exp(b[o + 2] * 0.2), h = ph * Math.exp(b[o + 3] * 0.2);
        out.push({ box: { x: (x - w / 2) * frame.width, y: (y - h / 2) * frame.height, width: w * frame.width, height: h * frame.height },
          score: probability, classIndex: bestClass - 1, coefficients: m.slice((cell * A + a) * M, (cell * A + a + 1) * M) });
      }
    }
  });
  return out;
}

function v5Candidates(heads, frame, M, threshold) {
  const out = [], A = 3, logit = Math.log(threshold / (1 - threshold));
  for (const head of heads) {
    const stride = frame.height / head.height, anchors = V5_ANCHORS[Math.round(stride)];
    if (!anchors) continue;
    const fields = head.features / A, C = fields - 5 - M, width = head.width, v = head.values;
    for (let cell = 0; cell < head.height * width; cell++) for (let a = 0; a < A; a++) {
      const base = cell * head.features + a * fields;
      if (v[base + 4] < logit) continue;
      const objectness = sigmoid(v[base + 4]);
      let best = -Infinity, bestClass = 0;
      for (let c = 0; c < C; c++) if (v[base + 5 + c] > best) { best = v[base + 5 + c]; bestClass = c; }
      const score = objectness * sigmoid(best);
      if (score < threshold) continue;
      const f = (k) => sigmoid(v[base + k]);
      const cx = (f(0) * 2 + (cell % width) - 0.5) * stride, cy = (f(1) * 2 + Math.floor(cell / width) - 0.5) * stride;
      const w = (f(2) * 2) ** 2 * anchors[a][0], h = (f(3) * 2) ** 2 * anchors[a][1];
      out.push({ box: { x: cx - w / 2, y: cy - h / 2, width: w, height: h }, score, classIndex: bestClass, coefficients: v.slice(base + 5 + C, base + 5 + C + M) });
    }
  }
  return out;
}

// MARK: Oriented boxes (yolo11s_obb, DOTA)

export function orientedDetections(tensors, frame) {
  const scoreThreshold = 0.35, iouThreshold = 0.25, bins = 16, candidates = [];
  for (const [grid, group] of groupByHeight(tensors)) {
    const boxes = group.find((t) => t.features === 4 * bins), angles = group.find((t) => t.features === 1);
    const classes = group.find((t) => t.features !== 4 * bins && t.features !== 1);
    if (!boxes || !angles || !classes) continue;
    const stride = frame.height / grid, width = boxes.width, C = classes.features;
    const b = boxes.values, c = classes.values, an = angles.values;
    for (let cell = 0; cell < boxes.height * width; cell++) {
      let best = -Infinity, bestClass = 0;
      for (let k = 0; k < C; k++) if (c[cell * C + k] > best) { best = c[cell * C + k]; bestClass = k; }
      const score = sigmoid(best);
      if (!(score > scoreThreshold)) continue;
      const d = [0, 1, 2, 3].map((side) => dfl(b, (cell * 4 + side) * bins, bins));
      const angle = (sigmoid(an[cell]) - 0.25) * Math.PI, sin = Math.sin(angle), cos = Math.cos(angle);
      const ox = (d[2] - d[0]) / 2, oy = (d[3] - d[1]) / 2;
      const col = (cell % width) + 0.5, row = Math.floor(cell / width) + 0.5;
      const cx = (ox * cos - oy * sin + col) * stride, cy = (ox * sin + oy * cos + row) * stride;
      const w = Math.max((d[0] + d[2]) * stride, 1), h = Math.max((d[1] + d[3]) * stride, 1), hw = w / 2, hh = h / 2;
      const corners = [[-hw, -hh], [hw, -hh], [hw, hh], [-hw, hh]].map(([dx, dy]) => ({ x: cx + dx * cos - dy * sin, y: cy + dx * sin + dy * cos }));
      candidates.push({ cx, cy, w, h, score, classIndex: bestClass, corners, radius: Math.hypot(hw, hh) });
    }
  }
  candidates.sort((a, b) => b.score - a.score);
  const kept = [];
  for (const c of candidates) {
    const suppressed = kept.some((o) => {
      const reach = o.radius + c.radius;
      if ((o.cx - c.cx) ** 2 + (o.cy - c.cy) ** 2 >= reach * reach) return false;
      return rotatedIoU(o.corners, o.w * o.h, c.corners, c.w * c.h) > iouThreshold;
    });
    if (!suppressed) kept.push(c);
  }
  return kept.map((c) => ({ label: Labels.dota[c.classIndex] ?? `class ${c.classIndex}`, classIndex: c.classIndex, confidence: c.score,
    corners: c.corners.map((p) => frame.toSource(p.x, p.y)) }));
}

function polygonArea(p) {
  if (p.length < 3) return 0;
  let twice = 0;
  for (let i = 0; i < p.length; i++) { const a = p[i], b = p[(i + 1) % p.length]; twice += a.x * b.y - b.x * a.y; }
  return Math.abs(twice) / 2;
}

function clip(subject, clipper) {
  let signed = 0;
  for (let i = 0; i < clipper.length; i++) { const p = clipper[i], q = clipper[(i + 1) % clipper.length]; signed += p.x * q.y - q.x * p.y; }
  const o = signed >= 0 ? 1 : -1;
  let output = subject;
  for (let i = 0; i < clipper.length && output.length; i++) {
    const a = clipper[i], b = clipper[(i + 1) % clipper.length];
    const side = (p) => o * ((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x));
    const input = output; output = [];
    for (let j = 0; j < input.length; j++) {
      const cur = input[j], prev = input[(j + input.length - 1) % input.length], sc = side(cur), sp = side(prev);
      if ((sc >= 0) !== (sp >= 0)) { const t = sp / (sp - sc); output.push({ x: prev.x + t * (cur.x - prev.x), y: prev.y + t * (cur.y - prev.y) }); }
      if (sc >= 0) output.push(cur);
    }
  }
  return output;
}

function rotatedIoU(a, areaA, b, areaB) {
  const overlap = polygonArea(clip(a, b)), union = areaA + areaB - overlap;
  return union > 0 ? overlap / (union + 1e-9) : 0;
}

// MARK: Lanes (ufld_v2_tu)

export function lanes(tensors) {
  const cells = 100, rowCount = 56, colCount = 41, L = 4;
  const find = (n) => tensors.find((t) => t.features === n)?.values;
  const rows = find(cells * rowCount * L), cols = find(cells * colCount * L), rowEx = find(2 * rowCount * L), colEx = find(2 * colCount * L);
  if (!rows || !cols || !rowEx || !colEx) return [];
  const positions = (values, exists, anchors, lane, minimum) => {
    const value = (cell, anchor) => values[(cell * anchors + anchor) * L + lane];
    const present = [];
    for (let a = 0; a < anchors; a++) if (exists[(anchors + a) * L + lane] > exists[a * L + lane]) present.push(a);
    if (present.length <= minimum) return [];
    return present.map((anchor) => {
      let best = 0;
      for (let cell = 1; cell < cells; cell++) if (value(cell, anchor) > value(best, anchor)) best = cell;
      const lo = Math.max(0, best - 1), hi = Math.min(cells - 1, best + 1), peak = value(best, anchor);
      let total = 0, e = 0;
      for (let cell = lo; cell <= hi; cell++) { const w = Math.exp(value(cell, anchor) - peak); total += w; e += w * cell; }
      return [anchor, (e / total + 0.5) / (cells - 1)];
    });
  };
  const found = [];
  for (let lane = 0; lane < L; lane++) {
    let points = lane === 1 || lane === 2
      ? positions(rows, rowEx, rowCount, lane, rowCount / 2).map(([a, p]) => ({ x: p, y: (160 + (a * (710 - 160)) / (rowCount - 1)) / 720 }))
      : positions(cols, colEx, colCount, lane, colCount / 4).map(([a, p]) => ({ x: a / (colCount - 1), y: p }));
    if (points.length < 2) continue;
    if (points[0].y > points[points.length - 1].y) points = points.reverse();
    found.push({ points });
  }
  return found;
}

// MARK: Text

const ASCII = Array.from("0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~!\"#$%&'()*+,-./  ");
let multilingual = null;

export async function loadTextCharacters() {
  if (multilingual) return;
  const data = await (await fetch("data/ppocrv5_characters.json")).json();
  multilingual = [...data.characters.map((c) => Array.from(c)[0]), " "];
}

/** CTC greedy decoding of the recogniser's per-step class scores. Returns { text, confidence }. */
export function recognizedText(tensor) {
  const C = tensor.features, v = tensor.values;
  if (C <= 1) return { text: "", confidence: 0 };
  const multi = multilingual && C === multilingual.length + 2;
  const chars = multi ? multilingual : ASCII, first = multi ? 2 : 1;
  let text = "", total = 0, kept = 0, previous = -1;
  for (let step = 0; step < v.length / C; step++) {
    const base = step * C;
    let best = 0, bestValue = v[base];
    for (let i = 1; i < C; i++) if (v[base + i] > bestValue) { best = i; bestValue = v[base + i]; }
    if (best !== previous && best !== 0 && best >= first && best - first < chars.length) { text += chars[best - first]; total += bestValue; kept++; }
    previous = best;
  }
  return { text, confidence: kept ? total / kept : 0 };
}

/** Text regions from the detector's probability map (PaddleOCR DB post-process). Corners TL, TR, BR, BL. */
export function textRegions(tensor, frame, threshold = 0.3, boxThreshold = 0.6, unclipRatio = 1.5, maxCandidates = 1000) {
  const W = tensor.width, H = tensor.height, prob = tensor.values;
  if (!W || !H || prob.length < W * H) return [];
  const visited = new Uint8Array(W * H), rowMin = new Int32Array(H), rowMax = new Int32Array(H), stack = [], found = [];
  let candidates = 0;
  for (let start = 0; start < W * H; start++) {
    if (visited[start] || !(prob[start] > threshold)) continue;
    visited[start] = 1; stack.push(start);
    let top = Math.floor(start / W), bottom = top;
    rowMin[top] = rowMax[top] = start % W;
    while (stack.length) {
      const px = stack.pop(), x = px % W, y = (px - x) / W;
      for (let ny = Math.max(y - 1, 0); ny <= Math.min(y + 1, H - 1); ny++) for (let nx = Math.max(x - 1, 0); nx <= Math.min(x + 1, W - 1); nx++) {
        const n = ny * W + nx;
        if (visited[n] || !(prob[n] > threshold)) continue;
        visited[n] = 1; stack.push(n);
        if (ny < top) { top = ny; rowMin[ny] = rowMax[ny] = nx; } else if (ny > bottom) { bottom = ny; rowMin[ny] = rowMax[ny] = nx; } else { rowMin[ny] = Math.min(rowMin[ny], nx); rowMax[ny] = Math.max(rowMax[ny], nx); }
      }
    }
    if (++candidates > maxCandidates) break;
    const outline = [];
    for (let y = top; y <= bottom; y++) { outline.push([rowMin[y], y]); if (rowMax[y] !== rowMin[y]) outline.push([rowMax[y], y]); }
    const box = minimumAreaRectangle(outline);
    if (!box || Math.min(box.hw, box.hh) * 2 < 3) continue;
    const ex = Math.abs(box.ax) * box.hw + Math.abs(box.ay) * box.hh, ey = Math.abs(box.ay) * box.hw + Math.abs(box.ax) * box.hh;
    const x0 = clampI(Math.floor(box.cx - ex), 0, W - 1), x1 = clampI(Math.ceil(box.cx + ex), 0, W - 1);
    const y0 = clampI(Math.floor(box.cy - ey), 0, H - 1), y1 = clampI(Math.ceil(box.cy + ey), 0, H - 1);
    let sum = 0, count = 0;
    for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) {
      const dx = x - box.cx, dy = y - box.cy;
      if (Math.abs(dx * box.ax + dy * box.ay) > box.hw + 0.5 || Math.abs(dy * box.ax - dx * box.ay) > box.hh + 0.5) continue;
      sum += prob[y * W + x]; count++;
    }
    const score = count ? sum / count : 0;
    if (score < boxThreshold) continue;
    const bw = 2 * box.hw, bh = 2 * box.hh, grow = (bw * bh * unclipRatio) / (2 * (bw + bh));
    const hw = box.hw + grow, hh = box.hh + grow;
    if (Math.min(hw, hh) * 2 < 5) continue;
    const corners = [[-1, -1], [1, -1], [1, 1], [-1, 1]].map(([sx, sy]) => [
      Math.min(Math.max(box.cx + sx * hw * box.ax - sy * hh * box.ay, 0), W), Math.min(Math.max(box.cy + sx * hw * box.ay + sy * hh * box.ax, 0), H)]);
    corners.sort((a, b) => a[0] - b[0]);
    const lu = corners[0][1] <= corners[1][1] ? 0 : 1, ru = corners[2][1] <= corners[3][1] ? 2 : 3;
    const mapped = [corners[lu], corners[ru], corners[5 - ru], corners[1 - lu]].map(([x, y]) => frame.toSource(x, y));
    const center = { x: mapped.reduce((s, p) => s + p.x, 0) / 4, y: mapped.reduce((s, p) => s + p.y, 0) / 4 };
    const height = Math.max(0, ((mapped[3].y - mapped[0].y) + (mapped[2].y - mapped[1].y)) / 2);
    found.push({ corners: mapped, score, center, height });
  }
  found.sort((a, b) => a.center.y - b.center.y);
  const regions = [];
  let line = [], lineY = 0;
  const flush = () => { for (const it of line.sort((a, b) => a.center.x - b.center.x)) regions.push({ corners: it.corners, confidence: it.score, text: "" }); line = []; };
  for (const it of found) {
    if (line.length && it.center.y - lineY > 0.5 * Math.min(it.height, line[0].height)) flush();
    if (!line.length) lineY = it.center.y;
    line.push(it);
  }
  flush();
  return regions;
}

const clampI = (v, lo, hi) => Math.min(Math.max(v, lo), hi);

function minimumAreaRectangle(points) {
  const sorted = [...points].sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  if (sorted.length < 3) return null;
  const cross = (o, a, b) => (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
  const hull = [];
  for (const p of sorted) { while (hull.length >= 2 && cross(hull[hull.length - 2], hull[hull.length - 1], p) <= 0) hull.pop(); hull.push(p); }
  const lower = hull.length + 1;
  for (let i = sorted.length - 2; i >= 0; i--) { const p = sorted[i]; while (hull.length >= lower && cross(hull[hull.length - 2], hull[hull.length - 1], p) <= 0) hull.pop(); hull.push(p); }
  hull.pop();
  if (hull.length < 3) return null;
  let best = null;
  for (let i = 0; i < hull.length; i++) {
    const a = hull[i], b = hull[(i + 1) % hull.length], len = Math.hypot(b[0] - a[0], b[1] - a[1]);
    if (!len) continue;
    const ux = (b[0] - a[0]) / len, uy = (b[1] - a[1]) / len;
    let lu = Infinity, hu = -Infinity, lv = Infinity, hv = -Infinity;
    for (const p of hull) { const u = p[0] * ux + p[1] * uy, v = p[1] * ux - p[0] * uy; lu = Math.min(lu, u); hu = Math.max(hu, u); lv = Math.min(lv, v); hv = Math.max(hv, v); }
    const area = (hu - lu) * (hv - lv);
    if (!best || area < best.area) best = { area, ux, uy, lu, hu, lv, hv };
  }
  if (!best) return null;
  const mu = (best.lu + best.hu) / 2, mv = (best.lv + best.hv) / 2;
  let ax = best.ux, ay = best.uy, hw = (best.hu - best.lu) / 2, hh = (best.hv - best.lv) / 2;
  if (Math.abs(ax) < Math.abs(ay)) { [ax, ay] = [-ay, ax]; [hw, hh] = [hh, hw]; }
  if (ax < 0) { ax = -ax; ay = -ay; }
  return { cx: mu * best.ux - mv * best.uy, cy: mu * best.uy + mv * best.ux, ax, ay, hw, hh };
}
