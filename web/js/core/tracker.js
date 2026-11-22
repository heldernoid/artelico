// Keeps the same number on an object from frame to frame (port of StudioCore/Tracker.swift: a ByteTrack-
// style two-pass matcher with a constant-velocity guess and the Hungarian assignment). Numbered boxes and
// body points are steadied per track number (TrackSmoother, js/rules/steady-video.js).
import { TrackSmoother } from "../rules/steady-video.js";

class TrackBox {
  constructor(r) { this.cx = r.x + r.width / 2; this.cy = r.y + r.height / 2; this.w = r.width; this.h = r.height; }
  get usable() { return [this.cx, this.cy, this.w, this.h].every(Number.isFinite) && this.w > 0 && this.h > 0; }
  iou(o) {
    const ow = Math.min(this.cx + this.w / 2, o.cx + o.w / 2) - Math.max(this.cx - this.w / 2, o.cx - o.w / 2);
    const oh = Math.min(this.cy + this.h / 2, o.cy + o.h / 2) - Math.max(this.cy - this.h / 2, o.cy - o.h / 2);
    if (ow <= 0 || oh <= 0) return 0;
    const inter = ow * oh, union = this.w * this.h + o.w * o.h - inter;
    return union > 0 ? inter / union : 0;
  }
}

class Track {
  constructor(classIndex, box) { this.id = null; this.classIndex = classIndex; this.box = box; this.v = { x: 0, y: 0, w: 0, h: 0 }; this.hits = 1; this.lost = 0; }
  predict() {
    this.box.cx += this.v.x; this.box.cy += this.v.y;
    if (this.lost === 0) { this.box.w = Math.max(this.box.w + this.v.w, 1e-4); this.box.h = Math.max(this.box.h + this.v.h, 1e-4); }
    else { this.v.x *= 0.95; this.v.y *= 0.95; this.v.w = 0; this.v.h = 0; }
  }
  correct(m) {
    const gain = (this.hits === 1 ? 1 : 0.3) / (this.lost + 1);
    this.v.x += gain * (m.cx - this.box.cx); this.v.y += gain * (m.cy - this.box.cy);
    this.v.w += gain * (m.w - this.box.w); this.v.h += gain * (m.h - this.box.h);
    this.box = m; this.hits++; this.lost = 0;
  }
}

/** Minimum-cost assignment (Hungarian, Jonker-Volgenant form). Returns for each row its column or null. */
export function assign(cost) {
  const R = cost.length, C = cost[0]?.length ?? 0;
  if (!R || !C) return Array(R).fill(null);
  if (R > C) {
    const t = Array.from({ length: C }, (_, c) => cost.map((row) => row[c]));
    const result = Array(R).fill(null);
    assign(t).forEach((row, column) => { if (row !== null) result[row] = column; });
    return result;
  }
  const u = new Float64Array(R + 1), v = new Float64Array(C + 1), p = new Int32Array(C + 1), way = new Int32Array(C + 1);
  for (let i = 1; i <= R; i++) {
    p[0] = i;
    let j0 = 0;
    const minv = new Float64Array(C + 1).fill(Infinity), used = new Uint8Array(C + 1);
    do {
      used[j0] = 1;
      const i0 = p[j0];
      let delta = Infinity, j1 = 0;
      for (let j = 1; j <= C; j++) if (!used[j]) {
        const cur = cost[i0 - 1][j - 1] - u[i0] - v[j];
        if (cur < minv[j]) { minv[j] = cur; way[j] = j0; }
        if (minv[j] < delta) { delta = minv[j]; j1 = j; }
      }
      for (let j = 0; j <= C; j++) { if (used[j]) { u[p[j]] += delta; v[j] -= delta; } else minv[j] -= delta; }
      j0 = j1;
    } while (p[j0] !== 0);
    do { const j1 = way[j0]; p[j0] = p[j1]; j0 = j1; } while (j0);
  }
  const result = Array(R).fill(null);
  for (let j = 1; j <= C; j++) if (p[j]) result[p[j] - 1] = j - 1;
  return result;
}

export class ObjectTracker {
  constructor({ high = 0.5, low = 0.1, matchIoU = 0.2, maxLost = 30, minHits = 2, sameClassOnly = true } = {}) {
    Object.assign(this, { high, low: Math.min(low, high), matchIoU, maxLost, minHits, sameClassOnly });
    /** Whether `track()` steadies numbered boxes and body points (One-Euro filters); off gives the raw positions. */
    this.steadies = true;
    this.smoother = new TrackSmoother();
    this.reset();
  }

  reset() { this.tracks = []; this.nextID = 1; this.frames = 0; this.smoother.reset(); }

  /** Detections in, [{ detection, trackID }] out (only confirmed tracks). */
  update(detections) {
    this.frames++;
    const boxes = detections.map((d) => new TrackBox(d.boundingBox));
    const high = [], low = [];
    detections.forEach((d, i) => { if (!boxes[i].usable) return; if (d.confidence >= this.high) high.push(i); else if (d.confidence >= this.low) low.push(i); });
    for (const t of this.tracks) t.predict();
    const confirmed = this.tracks.map((_, i) => i).filter((i) => this.tracks[i].id !== null);
    const tentative = this.tracks.map((_, i) => i).filter((i) => this.tracks[i].id === null);
    const trackFor = Array(detections.length).fill(null);
    const first = this.associate(confirmed, high, detections, boxes);
    for (const [t, d] of first.pairs) trackFor[d] = t;
    const second = this.associate(first.unmatchedTracks.filter((t) => this.tracks[t].lost === 0), low, detections, boxes);
    for (const [t, d] of second.pairs) trackFor[d] = t;
    const third = this.associate(tentative, first.unmatchedDetections, detections, boxes);
    for (const [t, d] of third.pairs) trackFor[d] = t;
    const matched = new Set(), fresh = [], results = [], unmatchedHigh = new Set(third.unmatchedDetections);
    detections.forEach((d, i) => {
      let track;
      if (trackFor[i] !== null) { matched.add(trackFor[i]); track = this.tracks[trackFor[i]]; track.correct(boxes[i]); }
      else if (unmatchedHigh.has(i)) { track = new Track(d.classIndex, boxes[i]); fresh.push(track); }
      else return;
      if (track.id === null && (track.hits >= this.minHits || this.frames === 1)) track.id = this.nextID++;
      if (track.id !== null) results.push({ detection: d, trackID: track.id });
    });
    const kept = [];
    this.tracks.forEach((t, i) => {
      if (!matched.has(i)) { if (t.id === null || t.lost >= this.maxLost) return; t.lost++; }
      kept.push(t);
    });
    this.tracks = [...kept, ...fresh];
    return results;
  }

  associate(trackIdx, detIdx, detections, boxes) {
    if (!trackIdx.length || !detIdx.length) return { pairs: [], unmatchedTracks: trackIdx, unmatchedDetections: detIdx };
    const overlap = trackIdx.map((t) => detIdx.map((d) => {
      const track = this.tracks[t];
      if (this.sameClassOnly && detections[d].classIndex !== track.classIndex) return 0;
      const iou = track.box.iou(boxes[d]);
      return iou >= this.matchIoU ? iou : 0;
    }));
    const columns = assign(overlap.map((row) => row.map((x) => 1 - x)));
    const pairs = [], unmatchedTracks = [], taken = new Array(detIdx.length).fill(false);
    columns.forEach((c, r) => {
      if (c !== null && overlap[r][c] > 0) { pairs.push([trackIdx[r], detIdx[c]]); taken[c] = true; } else unmatchedTracks.push(trackIdx[r]);
    });
    return { pairs, unmatchedTracks, unmatchedDetections: detIdx.filter((_, k) => !taken[k]) };
  }

  /**
   * Numbers a pipeline result: detections get "label #n" and trackID, poses get trackID. Numbered boxes and
   * body points are steadied (`steadies`), timed by `time` (seconds; the clock by default). Other kinds of
   * result (masks among them) are returned unchanged.
   */
  track(result, time = performance.now() / 1000) {
    const ids = (dets) => {
      const tracked = this.update(dets), out = Array(dets.length).fill(null);
      for (const t of tracked) { const i = dets.indexOf(t.detection); if (i >= 0) out[i] = t.trackID; }
      return out;
    };
    const steady = this.steadies, smoother = this.smoother;
    if (time < this.lastTime) smoother.reset();   // a new run's clock starts again from 0
    this.lastTime = time;
    try {
      switch (result.kind) {
        case "detections": {
          const n = ids(result.value);
          return { kind: "detections", value: result.value.map((d, i) => (n[i] === null ? d
            : { ...d, label: `${d.label} #${n[i]}`, trackID: n[i], boundingBox: steady ? smoother.box(d.boundingBox, n[i], time) : d.boundingBox })) };
        }
        case "poses": {
          const n = ids(result.value.map((p) => ({ label: "person", classIndex: 0, confidence: p.confidence, boundingBox: p.boundingBox })));
          return { kind: "poses", value: result.value.map((p, i) => {
            if (n[i] === null || !steady) return { ...p, trackID: n[i] ?? undefined };
            const points = smoother.points(p.keypoints.map((k) => k.position), n[i], time);
            return { ...p, trackID: n[i], boundingBox: smoother.box(p.boundingBox, n[i], time), keypoints: p.keypoints.map((k, j) => ({ ...k, position: points[j] })) };
          }) };
        }
        default: return result;
      }
    } finally {
      smoother.forget(time - 2);
    }
  }
}
