// Drawing faces and people described one at a time (attributes, re-identification) and dense face
// landmarks. Port of StudioCore/VisionRenderer+Described.swift.
import { colorFor, label } from "./render.js";

/** Attributes shown under each box (smaller tags, so neighbours overlap less); the result text has them all. */
const ATTRIBUTES_DRAWN = 3;

/** The box, the name (or the score) above it and the most certain attributes stacked under it. */
export function drawDescribed(ctx, items, W, H) {
  [...items.entries()].reverse().forEach(([index, item]) => {
    // The same person keeps the same colour across frames: colour by the number in the name.
    const number = Number(item.name?.split(" ").pop());
    const color = colorFor(Number.isFinite(number) ? number : index), b = item.boundingBox;
    const x = b.x * W, y = b.y * H, w = b.width * W, h = b.height * H;
    ctx.strokeStyle = color; ctx.lineWidth = 2;
    ctx.strokeRect(x, y, w, h);
    const title = item.name ? (item.similarity !== undefined ? `${item.name} ${item.similarity.toFixed(2)}` : item.name) : item.confidence.toFixed(2);
    label(ctx, title, x, y, color);
    item.attributes.slice(0, ATTRIBUTES_DRAWN).forEach((a, row) =>
      label(ctx, `${a.label} ${Math.round(a.probability * 100)}%`, x, y + h + 2 + row * 17, `${color}bf`, { below: true, scale: 0.85 }));
  });
}

/** The iBUG 300-W groups of 3DDFA's 68 points as lines: jaw, brows, nose bridge and base, eyes and lips (the last four closed). */
const LANDMARK_LINES = [[0, 16, false], [17, 21, false], [22, 26, false], [27, 30, false], [31, 35, false],
  [36, 41, true], [42, 47, true], [48, 59, true], [60, 67, true]];

/** 3DDFA's 68 points as lines and dots with the head pose; the face mesh's 468 as dots. */
export function drawFaceLandmarks(ctx, items, W, H) {
  [...items.entries()].reverse().forEach(([index, face]) => {
    const color = colorFor(index), b = face.boundingBox;
    const points = face.points.map((p) => [p.x * W, p.y * H]);
    // Dots scale with the face so a small face is not covered.
    const faceSize = Math.max(b.width * W, b.height * H), dense = points.length > 100;
    if (points.length === 68) {
      ctx.strokeStyle = color; ctx.lineWidth = Math.max(Math.min(faceSize * 0.012, 2), 1);
      for (const [from, to, closed] of LANDMARK_LINES) {
        ctx.beginPath();
        for (let i = from; i <= to; i++) (i === from ? ctx.moveTo : ctx.lineTo).call(ctx, ...points[i]);
        if (closed) ctx.closePath();
        ctx.stroke();
      }
    }
    const radius = dense ? Math.max(Math.min(faceSize * 0.006, 1.5), 0.6) : Math.max(Math.min(faceSize * 0.015, 2.5), 1);
    ctx.fillStyle = dense ? color : "#fff";
    for (const [x, y] of points) { ctx.beginPath(); ctx.arc(x, y, radius, 0, Math.PI * 2); ctx.fill(); }
    const p = face.headPose;
    label(ctx, p ? `yaw ${p.yaw.toFixed(0)}° pitch ${p.pitch.toFixed(0)}° roll ${p.roll.toFixed(0)}°` : face.confidence.toFixed(2), b.x * W, b.y * H, color);
  });
}

/** One line per face or person: name or number, then the attributes (all of them) or the head pose. */
export function describedSummary(result) {
  const v = result.value;
  if (!v.length) return result.kind === "described" ? "Nothing found" : "No faces";
  if (result.kind === "faceLandmarks") {
    return v.map((f, i) => `#${i + 1}: ${f.points.length} points` + (f.headPose ? `, yaw ${f.headPose.yaw.toFixed(0)}° pitch ${f.headPose.pitch.toFixed(0)}° roll ${f.headPose.roll.toFixed(0)}°` : `, face ${f.confidence.toFixed(2)}`)).join(" · ");
  }
  return v.map((item, i) => {
    const name = item.name ? `${item.name}${item.similarity !== undefined ? ` (${item.similarity.toFixed(2)})` : " (new)"}` : `#${i + 1}`;
    return item.attributes.length || !item.name ? `${name}: ${item.attributes.map((a) => `${a.label} ${Math.round(a.probability * 100)}%`).join(", ") || "nothing certain"}` : name;
  }).join(" · ");
}
