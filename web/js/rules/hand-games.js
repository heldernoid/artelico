// Rules for the hand examples (hand signs, fruit ninja, air band) and the hand reader (pose wrists ->
// hand_landmark_lite). Port of StudioCore/HandGames.swift.
import { BodyPose, K } from "./pose-games.js";
import { toPicture } from "../core/prep.js";

const d = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);

export const HandCrop = {
  /** Square around a hand along the forearm past the wrist (1.1 x forearm, at least 60 px), or above the wrist. */
  box(body, wrist, elbow, conf = 0.35) {
    const w = body.at(wrist);
    if (w.c < conf) return null;
    const e = body.at(elbow);
    let size, cx, cy;
    if (e.c >= conf) {
      const forearm = Math.hypot(w.x - e.x, w.y - e.y);
      size = Math.max(60, forearm * 1.1);
      const dx = (w.x - e.x) / Math.max(forearm, 1e-6), dy = (w.y - e.y) / Math.max(forearm, 1e-6);
      cx = w.x + dx * size * 0.35; cy = w.y + dy * size * 0.35;
    } else { size = body.height * 0.28; cx = w.x; cy = w.y - size * 0.2; }
    return { x: cx - size / 2, y: cy - size / 2, size };
  },
  edges: [[0, 1], [1, 2], [2, 3], [3, 4], [0, 5], [5, 6], [6, 7], [7, 8], [5, 9], [9, 10], [10, 11], [11, 12],
    [9, 13], [13, 14], [14, 15], [15, 16], [13, 17], [17, 18], [18, 19], [19, 20], [0, 17]],
};

/** How far to turn the picture (radians) so the hand, past the wrist along the forearm, points up; 0 without an elbow. */
export function uprightAngle(body, wrist, elbow, conf = 0.35) {
  const w = body.at(wrist), e = body.at(elbow);
  if (w.c < conf || e.c < conf || Math.hypot(w.x - e.x, w.y - e.y) <= 1) return 0;
  return -Math.PI / 2 - Math.atan2(w.y - e.y, w.x - e.x);
}

/** One-Euro filter (as MediaPipe smooths landmarks): steady when still, little lag when moving. */
export class OneEuroFilter {
  constructor(minCutoff = 1.0, beta = 0.02, dCutoff = 1.0) { Object.assign(this, { minCutoff, beta, dCutoff, value: null, speed: 0, time: null }); }
  static alpha(dt, cutoff) { return 1 / (1 + 1 / (2 * Math.PI * cutoff * dt)); }
  filter(x, t) {
    if (this.value === null || !(t > this.time)) { this.value = x; this.time = t; return x; }
    const dt = t - this.time, a = OneEuroFilter.alpha(dt, this.dCutoff);
    this.speed = a * (x - this.value) / dt + (1 - a) * this.speed;
    this.value += OneEuroFilter.alpha(dt, this.minCutoff + this.beta * Math.abs(this.speed)) * (x - this.value);
    this.time = t;
    return this.value;
  }
}

/** Keeps each hand (person + side) steady: the crop square follows with damping (jumps on big moves), points are One-Euro filtered. */
export class HandSmoother {
  constructor(follow = 0.35) { this.follow = follow; this.states = new Map(); }
  steady(box, key, time) {
    const st = this.states.get(key);
    if (!st) { this.states.set(key, { box, filters: Array.from({ length: 42 }, () => new OneEuroFilter()), seen: time }); return box; }
    const o = st.box, k = this.follow;
    let next = box;
    if (Math.hypot(box.cx - o.cx, box.cy - o.cy) < o.size * 0.5) {
      next = { cx: o.cx + (box.cx - o.cx) * k, cy: o.cy + (box.cy - o.cy) * k, size: o.size + (box.size - o.size) * k,
        angle: Math.atan2(Math.sin(o.angle) * (1 - k) + Math.sin(box.angle) * k, Math.cos(o.angle) * (1 - k) + Math.cos(box.angle) * k) };
    }
    st.box = next; st.seen = time;
    return next;
  }
  filter(points, key, time, W, H) {
    const st = this.states.get(key);
    if (!st) return points;
    return points.map((p, i) => ({ x: st.filters[i * 2].filter(p.x * W, time) / W, y: st.filters[i * 2 + 1].filter(p.y * H, time) / H }));
  }
  forget(key) { this.states.delete(key); }
  dropUnseen(before) { for (const [k, v] of this.states) if (v.seen < before) this.states.delete(k); }
}

export const HandReader = {
  modelName: "hand_landmark_lite",
  side: 224,
  /** Below this "a hand is present" score the square holds no hand (an arm, a sleeve, the background). */
  presenceThreshold: 0.5,
  /**
   * Hands of each person: [{ side: "L"|"R", person, points (21, fractions), box (fractions) }]. Like MediaPipe the square
   * is turned so the hand points up (the model reads upright hands far better), squares without a hand are dropped,
   * and with a `smoother` (HandSmoother) the square and points are steadied; `time` in seconds.
   */
  async read(image, poses, engine, maxHands = 4, smoother = null, time = performance.now() / 1000) {
    const W = image.width, H = image.height, hands = [];
    for (const [index, pose] of poses.entries()) {
      const body = BodyPose.from(pose, W / H, W);
      for (const [name, wrist, elbow] of [["R", K.rightWrist, K.rightElbow], ["L", K.leftWrist, K.leftElbow]]) {
        if (hands.length >= maxHands) break;
        const sq = HandCrop.box(body, wrist, elbow);
        if (!sq) continue;
        const person = pose.trackID ?? index, key = `${person}${name}`;
        let box = { cx: sq.x + sq.size / 2, cy: sq.y + sq.size / 2, size: sq.size, angle: uprightAngle(body, wrist, elbow) };
        if (smoother) box = smoother.steady(box, key, time);
        const rgb = this.crop(image, box);
        if (!rgb) continue;
        const tensors = await engine.infer([rgb], this.modelName);
        // Outputs: hand present (1 value, first), landmarks in input pixels (63), handedness (1), world coordinates (63, small).
        const presence = tensors.map((t) => t.values).find((v) => v.length === 1)?.[0];
        if (presence !== undefined && presence < this.presenceThreshold) { smoother?.forget(key); continue; }
        const candidates = tensors.map((t) => t.values).filter((v) => v.length === 63);
        if (!candidates.length) continue;
        const lm = candidates.reduce((a, b) => (Math.max(...b.map(Math.abs)) > Math.max(...a.map(Math.abs)) ? b : a));
        let points = Array.from({ length: 21 }, (_, i) => { const p = toPicture(box, lm[i * 3], lm[i * 3 + 1], this.side); return { x: p.x / W, y: p.y / H }; });
        if (smoother) points = smoother.filter(points, key, time, W, H);
        hands.push({ side: name, person, points, box: { x: (box.cx - box.size / 2) / W, y: (box.cy - box.size / 2) / H, width: box.size / W, height: box.size / H } });
      }
    }
    smoother?.dropUnseen(time - 1);
    return hands;
  },
  /** The turned square ({cx, cy, size, angle}) as upright 224 x 224 RGB; outside the picture is black. */
  crop(image, box) {
    if (box.size < 8) return null;
    const S = this.side, c = new OffscreenCanvas(S, S), ctx = c.getContext("2d", { willReadFrequently: true });
    ctx.fillStyle = "#000"; ctx.fillRect(0, 0, S, S);
    ctx.imageSmoothingQuality = "medium";
    // crop = R(angle) * (picture - centre) * S / size + S / 2
    ctx.translate(S / 2, S / 2); ctx.rotate(box.angle); ctx.scale(S / box.size, S / box.size); ctx.translate(-box.cx, -box.cy);
    ctx.drawImage(image, 0, 0);
    const rgba = ctx.getImageData(0, 0, S, S).data, rgb = new Uint8Array(S * S * 3);
    for (let s = 0, o = 0; s < rgba.length; s += 4, o += 3) { rgb[o] = rgba[s]; rgb[o + 1] = rgba[s + 1]; rgb[o + 2] = rgba[s + 2]; }
    return rgb;
  },
};

// MARK: Hand signs

export const SIGNS = {
  ok: ["OK", "👌"], heart: ["Finger heart", "🫰"], thumbsUp: ["Thumbs up", "👍"], thumbsDown: ["Thumbs down", "👎"], rock: ["Rock on", "🤘"],
  fist: ["0 · Fist", "✊"], one: ["1", "☝️"], two: ["2 · Peace", "✌️"], three: ["3", "3️⃣"], four: ["4", "4️⃣"], five: ["5 · Open hand", "🖐️"],
  pinky: ["Pinky promise", "🤙"], unknown: ["…", "❔"],
};

const TIP = { thumb: 4, index: 8, middle: 12, ring: 16, pinky: 20 }, PIP = { index: 6, middle: 10, ring: 14, pinky: 18 };

export const HandSigns = {
  /** Straight fingers: tip farther from the wrist than the middle joint x 1.15; thumb: from the pinky base x 1.25. */
  fingers(p) {
    const s = {};
    for (const f of ["index", "middle", "ring", "pinky"]) s[f] = d(p[TIP[f]], p[0]) > d(p[PIP[f]], p[0]) * 1.15;
    s.thumb = d(p[4], p[17]) > d(p[2], p[17]) * 1.25;
    return s;
  },
  classify(p) {
    if (p.length !== 21) return "unknown";
    const s = this.fingers(p), ext = ["index", "middle", "ring", "pinky"].map((f) => s[f]), n = ext.filter(Boolean).length;
    const size = Math.max(d(p[0], p[9]), 1e-6), touch = d(p[4], p[8]) < size * 0.4, is = (a) => a.every((v, i) => v === ext[i]);
    if (touch && s.middle && s.ring && s.pinky) return "ok";
    if (touch && n === 0) return "heart";
    if (s.thumb && n === 0) return p[4].y < p[2].y ? "thumbsUp" : "thumbsDown";
    if (s.index && s.pinky && !s.middle && !s.ring) return "rock";
    if (n === 0) return "fist";
    if (is([true, false, false, false])) return "one";
    if (is([true, true, false, false])) return "two";
    if (is([true, true, true, false])) return "three";
    if (n === 4) return s.thumb ? "five" : "four";
    if (is([false, false, false, true])) return "pinky";
    return "unknown";
  },
};

/** A sign shows only after `frames` frames in a row. */
export class SignSmoother {
  constructor(frames = 4) { this.frames = frames; this.last = null; this.count = 0; this.stable = null; }
  update(sign) { if (sign === this.last) this.count++; else { this.last = sign; this.count = 1; } if (this.count >= this.frames) this.stable = sign; return this.stable; }
}

// MARK: Fruit ninja

export function segmentHitsCircle(p0, p1, c, r) {
  const dx = p1.x - p0.x, dy = p1.y - p0.y, l2 = dx * dx + dy * dy;
  const t = l2 === 0 ? 0 : Math.max(0, Math.min(1, ((c.x - p0.x) * dx + (c.y - p0.y) * dy) / l2));
  return Math.hypot(p0.x + t * dx - c.x, p0.y + t * dy - c.y) <= r;
}

export class FruitGame {
  static width = 1280; static height = 720; static gravity = 1400;
  static kinds = [["apple", 34, "🍎"], ["watermelon", 46, "🍉"], ["orange", 32, "🍊"], ["grapes", 28, "🍇"], ["lemon", 30, "🍋"]];
  constructor(seconds = 30, best = 0, random = Math.random) { Object.assign(this, { seconds, best, random }); this.phase = "ready"; this.score = 0; this.items = []; this.startedAt = 0; this.trails = new Map(); this.lastSpawn = 0; this.nextGap = 0.7; this.nextID = 0; this.speed = 1; this.size = 1; }
  remaining(now) { return this.phase === "playing" ? Math.max(0, this.seconds - (now - this.startedAt)) : 0; }
  start(now) { this.phase = "playing"; this.score = 0; this.items = []; this.startedAt = now; this.lastSpawn = now; this.trails = new Map(); }
  spawn() {
    const bomb = this.random() < 0.18, kind = bomb ? -1 : Math.min(FruitGame.kinds.length - 1, Math.floor(this.random() * FruitGame.kinds.length));
    this.items.push({ id: this.nextID++, kind, isBomb: bomb, x: 200 + this.random() * (FruitGame.width - 400), y: FruitGame.height + 40,
      vx: -160 + this.random() * 320, vy: -(900 + this.random() * 250), radius: (bomb ? 34 : FruitGame.kinds[kind][1]) * this.size, cutAt: null, halves: [] });
  }
  /** tips: [{ key, point }] in the 1280 x 720 field. Returns the items cut this frame. */
  update(tips, now, dt) {
    dt = Math.min(0.1, Math.max(0, dt));
    for (const t of tips) { if (!this.trails.has(t.key)) this.trails.set(t.key, []); this.trails.get(t.key).push({ point: t.point, time: now }); }
    for (const [k, v] of this.trails) this.trails.set(k, v.filter((e) => now - e.time < 0.35));
    const cut = [];
    if (this.phase !== "playing") return cut;
    if (now - this.startedAt >= this.seconds) { this.phase = "over"; this.best = Math.max(this.best, this.score); return cut; }
    if (now - this.lastSpawn > this.nextGap / this.speed) { this.spawn(); this.lastSpawn = now; this.nextGap = 0.5 + this.random() * 0.4; }
    for (const it of this.items) {
      const step = dt * this.speed;   // game time: the same arcs, faster or slower
      it.vy += FruitGame.gravity * step; it.x += it.vx * step; it.y += it.vy * step;
      for (const h of it.halves) { h.vy += FruitGame.gravity * step; h.x += h.vx * step; h.y += h.vy * step; }
      if (it.cutAt !== null) continue;
      for (const trail of this.trails.values()) {
        if (trail.length < 2) continue;
        const a = trail[trail.length - 2].point, b = trail[trail.length - 1].point;
        if (!segmentHitsCircle(a, b, it, it.radius + 6)) continue;
        if (Math.hypot(b.x - a.x, b.y - a.y) / Math.max(dt, 1e-3) <= 250) continue;
        const dir = b.x >= a.x ? 1 : -1;
        it.cutAt = now;
        it.halves = [{ x: it.x, y: it.y, vx: it.vx - 150 * dir, vy: it.vy * 0.5 }, { x: it.x, y: it.y, vx: it.vx + 150 * dir, vy: it.vy * 0.5 }];
        this.score += it.isBomb ? -5 : 1;
        cut.push(it);
        break;
      }
    }
    this.items = this.items.filter((it) => !(it.y > FruitGame.height + 80 || (it.cutAt !== null && now - it.cutAt > 0.8)));
    return cut;
  }
}

// MARK: Air band

export class AirBand {
  static noteNames = ["Do", "Re", "Mi", "Fa", "Sol", "La", "Si", "Do'"];
  static noteFrequencies = [261.6, 293.7, 329.6, 349.2, 392.0, 440.0, 493.9, 523.3];
  static chords = [["C", [261.6, 329.6, 392.0]], ["G", [196.0, 246.9, 392.0]], ["Am", [220.0, 261.6, 329.6]], ["F", [174.6, 220.0, 349.2]]];
  constructor(width = 1280, height = 720) { Object.assign(this, { width, height }); this.previous = new Map(); this.lastFire = new Map(); this.lastKey = new Map(); }
  zone(x) { return x < this.width / 3 ? "drums" : x < (2 * this.width) / 3 ? "piano" : "guitar"; }
  /** hands: [{ id, x, y }]. Events: { drum } | { piano: key, high } | { chord }. */
  update(hands, now) {
    const events = [];
    for (const h of hands) {
      const p = this.previous.get(h.id) ?? { x: h.x, y: h.y, t: now };
      const vy = (h.y - p.y) / Math.max(1e-3, now - p.t), fired = this.lastFire.get(h.id) ?? -Infinity;
      switch (this.zone(h.x)) {
        case "drums":
          if (vy > 900 && now - fired > 0.18) { events.push({ drum: h.y < this.height * 0.4 ? "hihat" : h.y < this.height * 0.7 ? "snare" : "kick" }); this.lastFire.set(h.id, now); }
          this.lastKey.set(h.id, null);
          break;
        case "piano": {
          const key = Math.max(0, Math.min(7, Math.floor(((h.x - this.width / 3) / (this.width / 3)) * 8)));
          if ((this.lastKey.get(h.id) ?? null) !== key && now - fired > 0.08) { events.push({ piano: key, high: h.y < this.height * 0.45 }); this.lastFire.set(h.id, now); }
          this.lastKey.set(h.id, key);
          break;
        }
        default:
          if (vy > 700 && now - fired > 0.3) { events.push({ chord: Math.max(0, Math.min(3, Math.floor((h.y / this.height) * 4))) }); this.lastFire.set(h.id, now); }
          this.lastKey.set(h.id, null);
      }
      this.previous.set(h.id, { x: h.x, y: h.y, t: now });
    }
    return events;
  }
}
