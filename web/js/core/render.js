// Drawing results over a picture (port of StudioCore/VisionRenderer.swift). Coordinates in results are
// normalized to the picture; `ctx` draws at the canvas size.
import { SKELETON } from "./decode.js";
import { drawDescribed, drawFaceLandmarks, describedSummary } from "./render-people.js";

const PALETTE = ["#34c759", "#0a84ff", "#ff9f0a", "#ff375f", "#bf5af2", "#64d2ff", "#ffd60a", "#30d158", "#ff6482", "#5e5ce6"];
export const colorFor = (i) => PALETTE[Math.abs(i) % PALETTE.length];

/** A label in a coloured tag above (or, `below`, under) the point; `scale` makes it smaller. */
export function label(ctx, text, x, y, color, { below = false, scale = 1 } = {}) {
  ctx.font = `600 ${13 * scale}px system-ui, -apple-system, sans-serif`;
  const w = ctx.measureText(text).width + 10 * scale, h = 18 * scale;
  const ty = below ? y : Math.max(0, y - h - 2);
  ctx.fillStyle = color;
  ctx.beginPath(); ctx.roundRect(x, ty, w, h, 4 * scale); ctx.fill();
  ctx.fillStyle = "#000";
  ctx.fillText(text, x + 5 * scale, ty + 13 * scale);
}

export function drawBoxes(ctx, items, W, H) {
  for (const it of items) {
    const b = it.box, x = b.x * W, y = b.y * H, w = b.width * W, h = b.height * H;
    ctx.strokeStyle = it.color; ctx.lineWidth = it.width ?? 3;
    ctx.beginPath(); ctx.roundRect(x, y, w, h, 3); ctx.stroke();
    if (it.label) label(ctx, it.label, x, y, it.color);
  }
}

export function drawPoses(ctx, poses, W, H, color = "#ff9f0a", minimum = 0.5) {
  for (const pose of poses) {
    const k = pose.keypoints;
    ctx.strokeStyle = color; ctx.lineWidth = 3; ctx.lineCap = "round";
    ctx.beginPath();
    for (const [a, b] of SKELETON) {
      if (k[a].confidence < minimum || k[b].confidence < minimum) continue;
      ctx.moveTo(k[a].position.x * W, k[a].position.y * H); ctx.lineTo(k[b].position.x * W, k[b].position.y * H);
    }
    ctx.stroke();
    ctx.fillStyle = "#fff";
    for (const p of k) if (p.confidence >= minimum) { ctx.beginPath(); ctx.arc(p.position.x * W, p.position.y * H, 3.5, 0, Math.PI * 2); ctx.fill(); }
  }
}

export function drawFaces(ctx, faces, W, H) {
  drawBoxes(ctx, faces.map((f) => ({ box: f.boundingBox, label: f.name ?? `${Math.round(f.confidence * 100)}%`, color: f.name ? "#34c759" : "#64d2ff" })), W, H);
  ctx.fillStyle = "#ffd60a";
  for (const f of faces) for (const p of f.landmarks) { ctx.beginPath(); ctx.arc(p.x * W, p.y * H, 3, 0, Math.PI * 2); ctx.fill(); }
}

/** Depth as a colour map (near = warm), drawn over the whole canvas. */
export function drawDepth(ctx, map, W, H, alpha = 0.85) {
  let lo = Infinity, hi = -Infinity;
  for (const v of map.values) { if (v < lo) lo = v; if (v > hi) hi = v; }
  const img = new ImageData(map.width, map.height);
  for (let i = 0; i < map.values.length; i++) {
    const t = 1 - (map.values[i] - lo) / (hi - lo || 1);   // near = 1
    img.data.set(turbo(t), i * 4);
    img.data[i * 4 + 3] = 255 * alpha;
  }
  paint(ctx, img, W, H);
}

/** Each class in its colour; the set's background class stays untinted. */
export function drawSegmentation(ctx, seg, W, H, alpha = 0.55) {
  const img = new ImageData(seg.width, seg.height);
  for (let i = 0; i < seg.classes.length; i++) {
    if (seg.classes[i] === seg.background) continue;
    const c = seg.colors[seg.classes[i]] ?? [0, 0, 0];
    img.data[i * 4] = c[0]; img.data[i * 4 + 1] = c[1]; img.data[i * 4 + 2] = c[2]; img.data[i * 4 + 3] = 255 * alpha;
  }
  paint(ctx, img, W, H);
}

function paint(ctx, img, W, H) {
  const c = new OffscreenCanvas(img.width, img.height);
  c.getContext("2d").putImageData(img, 0, 0);
  ctx.imageSmoothingEnabled = true;
  ctx.drawImage(c, 0, 0, W, H);
}

/** Google's Turbo colour map, t in 0..1 -> [r, g, b]. */
function turbo(t) {
  t = Math.min(1, Math.max(0, t));
  const r = 34.61 + t * (1172.33 - t * (10793.56 - t * (33300.12 - t * (38394.49 - t * 14825.05))));
  const g = 23.31 + t * (557.33 + t * (1225.33 - t * (3574.96 - t * (1073.77 + t * 707.56))));
  const b = 27.2 + t * (3211.1 - t * (15327.97 - t * (27814 - t * (22569.18 - t * 6838.66))));
  return [r, g, b].map((v) => Math.max(0, Math.min(255, v)));
}

/** Draws any pipeline result over the canvas (which already shows the picture). */
export function drawResult(ctx, result, W, H, labels = {}) {
  switch (result.kind) {
    case "detections":
      drawBoxes(ctx, result.value.map((d) => ({ box: d.boundingBox, label: `${d.label} ${Math.round(d.confidence * 100)}%`, color: colorFor(d.classIndex) })), W, H);
      break;
    case "poses": drawPoses(ctx, result.value, W, H); break;
    case "faces": drawFaces(ctx, result.value, W, H); break;
    case "depth": drawDepth(ctx, result.value, W, H); break;
    case "segmentation": drawSegmentation(ctx, result.value, W, H); break;
    case "instances": drawInstances(ctx, result.value, W, H); break;
    case "oriented": drawPolygons(ctx, result.value.map((d) => ({ points: d.corners, label: `${d.label} ${Math.round(d.confidence * 100)}%`, color: colorFor(d.classIndex) })), W, H); break;
    case "lanes": drawLanes(ctx, result.value, W, H); break;
    case "text": drawPolygons(ctx, result.value.map((r) => ({ points: r.corners, label: r.text, color: r.text ? "#34c759" : "#ff9f0a" })), W, H); break;
    case "described": drawDescribed(ctx, result.value, W, H); break;
    case "faceLandmarks": drawFaceLandmarks(ctx, result.value, W, H); break;
  }
  void labels;
}

/**
 * A translucent mask per instance, then boxes and labels on top. Class-less segments (segment everything,
 * often dozens) are drawn as masks only, largest first so small parts stay visible on top of the regions around them.
 */
export function drawInstances(ctx, list, W, H) {
  const classless = list.length > 0 && list.every((it) => it.detection.classIndex < 0);
  const area = (it) => it.detection.boundingBox.width * it.detection.boundingBox.height;
  const order = classless ? list.map((it, i) => [it, i]).sort((a, b) => area(b[0]) - area(a[0])) : list.map((it, i) => [it, i]);
  for (const [it, index] of order) {
    const color = colorFor(classless ? index : it.detection.classIndex);
    // The mask covers the picture area (letterbox padding removed): one cell per mask pixel.
    const img = new ImageData(it.maskWidth, it.maskHeight);
    const [r, g, b] = [1, 3, 5].map((i) => parseInt(color.slice(i, i + 2), 16));
    for (let i = 0; i < it.mask.length; i++) if (it.mask[i]) { img.data[i * 4] = r; img.data[i * 4 + 1] = g; img.data[i * 4 + 2] = b; img.data[i * 4 + 3] = 120; }
    paint(ctx, img, W, H);
  }
  if (classless) return;
  drawBoxes(ctx, list.map((it) => ({ box: it.detection.boundingBox, label: `${it.detection.label} ${Math.round(it.detection.confidence * 100)}%`, color: colorFor(it.detection.classIndex), width: 2 })), W, H);
}

export function drawPolygons(ctx, items, W, H) {
  for (const it of items) {
    ctx.strokeStyle = it.color; ctx.lineWidth = 2.5;
    ctx.beginPath();
    it.points.forEach((p, i) => (i ? ctx.lineTo(p.x * W, p.y * H) : ctx.moveTo(p.x * W, p.y * H)));
    ctx.closePath(); ctx.stroke();
    if (it.label) label(ctx, it.label, Math.min(...it.points.map((p) => p.x)) * W, Math.min(...it.points.map((p) => p.y)) * H, it.color);
  }
}

export function drawLanes(ctx, lanes, W, H) {
  lanes.forEach((lane, i) => {
    ctx.strokeStyle = colorFor(i + 2); ctx.lineWidth = 5; ctx.lineCap = "round"; ctx.lineJoin = "round";
    ctx.beginPath();
    lane.points.forEach((p, k) => (k ? ctx.lineTo(p.x * W, p.y * H) : ctx.moveTo(p.x * W, p.y * H)));
    ctx.stroke();
  });
}

/** A short text summary of a result. */
export function summary(result) {
  const v = result.value;
  switch (result.kind) {
    case "detections": {
      const counts = {};
      for (const d of v) counts[d.label] = (counts[d.label] ?? 0) + 1;
      return Object.entries(counts).map(([k, n]) => `${n} ${k}`).join(", ") || "Nothing found";
    }
    case "poses": return `${v.length} ${v.length === 1 ? "person" : "people"}`;
    case "faces": return `${v.length} ${v.length === 1 ? "face" : "faces"}`;
    case "classifications": return v.map((c) => `${c.label} ${(c.probability * 100).toFixed(1)}%`).join(" · ");
    case "depth": return `Depth map ${v.width}×${v.height}`;
    case "segmentation": return [...new Set(v.classes)].sort((a, b) => a - b).map((c) => v.labels[c] ?? `class ${c}`).join(", ");
    case "image": return v ? `Image ${v.width}×${v.height}` : "";
    case "described": case "faceLandmarks": return describedSummary(result);
    case "instances": if (v.length && v[0].detection.classIndex < 0) return `${v.length} segments`;
      return v.length ? Object.entries(v.reduce((m, it) => ((m[it.detection.label] = (m[it.detection.label] ?? 0) + 1), m), {})).map(([k, n]) => `${n} ${k}`).join(", ") : "Nothing found";
    case "oriented": return `${v.length} objects`;
    case "lanes": return `${v.length} lane line${v.length === 1 ? "" : "s"}`;
    case "text": return v.filter((r) => r.text).map((r) => r.text).join(" · ") || `${v.length} text regions, none readable`;
    default: return "";
  }
}
