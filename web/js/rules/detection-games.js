// Rules for the detection examples (head count, traffic count, missing check, plate gate, face check-in).
// Port of StudioCore/DetectionGames.swift. Boxes { x, y, width, height } in any consistent unit; times in s.
import { Rect } from "../core/prep.js";

export const boxIoU = Rect.iou;
const mid = (b) => ({ x: b.x + b.width / 2, y: b.y + b.height / 2 });

// MARK: Traffic

/** Follows boxes: pairs by overlap (or centres within `maxDistance`), best first; drops tracks missed > maxMissed. */
export class CentroidTracker {
  constructor(maxMissed = 10, iouThreshold = 0.2, maxDistance = 80) { Object.assign(this, { maxMissed, iouThreshold, maxDistance }); this.tracks = new Map(); this.nextID = 1; }
  /** detections: [{ label, box }]. Returns live tracks (oldest first): { id, box, label, missed, history }. */
  update(detections) {
    const pairs = [];
    for (const [id, t] of this.tracks) detections.forEach((d, j) => {
      let s = boxIoU(t.box, d.box);
      if (s < this.iouThreshold) {
        const a = mid(d.box), b = mid(t.box);
        if (Math.hypot(a.x - b.x, a.y - b.y) > this.maxDistance) return;
        s = 0.01;
      }
      pairs.push({ s, id, j });
    });
    pairs.sort((a, b) => b.s - a.s || b.id - a.id || b.j - a.j);
    const matched = new Set(), used = new Set();
    for (const p of pairs) {
      if (matched.has(p.id) || used.has(p.j)) continue;
      const t = this.tracks.get(p.id);
      t.box = detections[p.j].box; t.label = detections[p.j].label; t.missed = 0;
      t.history = [...t.history, mid(t.box)].slice(-30);
      matched.add(p.id); used.add(p.j);
    }
    const created = new Set();
    detections.forEach((d, j) => {
      if (used.has(j)) return;
      this.tracks.set(this.nextID, { id: this.nextID, box: d.box, label: d.label, missed: 0, history: [mid(d.box)] });
      created.add(this.nextID++);
    });
    for (const [id, t] of [...this.tracks]) {
      if (matched.has(id) || created.has(id)) continue;
      if (++t.missed > this.maxMissed) this.tracks.delete(id);
    }
    return [...this.tracks.keys()].sort((a, b) => a - b).map((id) => this.tracks.get(id));
  }
}

/** Counts each track once when its centre crosses the horizontal line `lineY`, by direction. */
export class LineCounter {
  constructor(lineY) { this.lineY = lineY; this.counted = new Map(); this.counts = {}; }
  /** Returns new crossings: [{ id, label, direction: "up" | "down" }]. */
  update(tracks) {
    const out = [];
    for (const t of tracks) {
      if (this.counted.has(t.id) || t.history.length < 2) continue;
      const y0 = t.history[t.history.length - 2].y, y1 = t.history[t.history.length - 1].y;
      if ((y0 < this.lineY && this.lineY <= y1) || (y1 < this.lineY && this.lineY <= y0)) {
        const d = y1 > y0 ? "down" : "up";
        this.counted.set(t.id, d);
        (this.counts[t.label] ??= { up: 0, down: 0 })[d]++;
        out.push({ id: t.id, label: t.label, direction: d });
      }
    }
    return out;
  }
  count(label, direction) { return this.counts[label]?.[direction] ?? 0; }
  get total() { return Object.values(this.counts).reduce((s, c) => s + c.up + c.down, 0); }
}

// MARK: Missing check

const norm = (s) => s.toLowerCase().replace(/\s/g, "");

/** Remembers the kinds of object on the table, then reports missing (unseen for `window` frames) and extra. */
export class MissingCheck {
  constructor(window = 8, ignored = new Set(["person"])) { this.window = window; this.ignored = ignored; this.baseline = []; this.history = new Map(); }
  setBaseline(labels) {
    const seen = new Set();
    this.baseline = labels.filter((l) => !this.ignored.has(l) && !seen.has(norm(l)) && seen.add(norm(l))).sort();
    this.history = new Map(this.baseline.map((b) => [b, []]));
  }
  clear() { this.baseline = []; this.history = new Map(); }
  update(labels) {
    const now = new Set(labels.filter((l) => !this.ignored.has(l)).map(norm));
    if (!this.baseline.length) return { armed: false, missing: [], extra: [], present: [...now].sort(), allOK: false };
    const missing = [], present = [];
    for (const item of this.baseline) {
      const h = [...(this.history.get(item) ?? []), now.has(norm(item))].slice(-this.window);
      this.history.set(item, h);
      (h.includes(true) ? present : missing).push(item);
    }
    const known = new Set(this.baseline.map(norm));
    const extra = [...new Set(labels.filter((l) => !this.ignored.has(l) && !known.has(norm(l))))].sort();
    return { armed: true, missing, extra, present, allOK: missing.length === 0 && extra.length === 0 };
  }
}

// MARK: Plate gate

const TAIWAN = /^(?:[A-Z]{2,3}-?\d{3,4}|\d{3,4}-?[A-Z]{2,3}|[A-Z]{3}-?\d{4}|\d{4}-?[A-Z]{2})$/;
const LETTER = /[A-Z]/, DIGIT = /[0-9]/;

export const PlateText = {
  /** The text as a plate in a standard form, or null. Taiwan (the demo's) and Portugal formats; O read as 0. */
  normalize(text) {
    const spaced = [...text.toUpperCase()].map((c) => (/\s/.test(c) || c === "·" || c === "." ? "-" : c)).join("");
    let t = spaced.replace(/[^A-Z0-9-]/g, "").replace(/O/g, "0").replace(/-+/g, "-").replace(/^-+|-+$/g, "");
    if (!t) return null;
    const plain = t.replace(/-/g, "");
    if ((t.match(/-/g) ?? []).length === 2) { const pt = this.portuguese(plain); if (pt) return pt; }
    if (TAIWAN.test(t) || TAIWAN.test(plain)) {
      const chars = [...plain];
      const letters = chars.findIndex((c) => !LETTER.test(c)), L = letters < 0 ? chars.length : letters;
      const digitsEnd = chars.findIndex((c) => !DIGIT.test(c)), D = digitsEnd < 0 ? chars.length : digitsEnd;
      if (L >= 2 && L <= 3 && chars.slice(L).every((c) => DIGIT.test(c)) && chars.length - L >= 3 && chars.length - L <= 4) return `${plain.slice(0, L)}-${plain.slice(L)}`;
      if (D >= 3 && D <= 4 && chars.slice(D).every((c) => LETTER.test(c)) && chars.length - D >= 2 && chars.length - D <= 3) return `${plain.slice(0, D)}-${plain.slice(D)}`;
      return plain;
    }
    return this.portuguese(plain);
  },
  /** Portugal: three pairs of letters or digits; O restored inside a pair that must be letters. */
  portuguese(plain) {
    if (plain.length !== 6) return null;
    const pairs = [plain.slice(0, 2), plain.slice(2, 4), plain.slice(4, 6)];
    const kinds = pairs.map((p) => ([...p].every((c) => DIGIT.test(c)) ? "9" : [...p].every((c) => LETTER.test(c) || c === "0") ? "A" : "?"));
    const valid = new Set(["A9A", "9A9", "99A", "A99"]);
    let shape = kinds.join("");
    if (!valid.has(shape)) {
      for (let i = 0; i < 3; i++) {
        if (pairs[i] !== "00") continue;
        const k = [...shape]; k[i] = k[i] === "9" ? "A" : "9";
        if (valid.has(k.join(""))) { shape = k.join(""); break; }
      }
    }
    if (!valid.has(shape)) return null;
    return pairs.map((p, i) => (shape[i] === "A" ? p.replace(/0/g, "O") : p)).join("-");
  },
};

/** The barrier: opens over 1 s, stays open 5 s; a refusal shows for 3 s. */
export class GateBarrier {
  constructor() { this.state = "closed"; this.since = 0; }
  open(now) { this.state = "opening"; this.since = now; }
  deny(now) { this.state = "denied"; this.since = now; }
  /** { angle (0 down .. 90 up), state } at `now`, without changing anything. */
  display(now) {
    const t = now - this.since;
    switch (this.state) {
      case "opening": case "open": {
        if (this.state === "opening" && t < 1) return { angle: t * 90, state: "opening" };
        const openFor = this.state === "opening" ? t - 1 : t;
        return openFor <= 5 ? { angle: 90, state: "open" } : { angle: 0, state: "closed" };
      }
      case "denied": return t <= 3 ? { angle: 0, state: "denied" } : { angle: 0, state: "closed" };
      default: return { angle: 0, state: "closed" };
    }
  }
}

// MARK: Face check-in

/** Best match, refused when the runner-up is within `margin` and also over the threshold (too alike). */
export function confidentMatch(gallery, embedding, margin = 0.08) {
  const scores = [];
  for (const [name, list] of Object.entries(gallery.people)) {
    let best = -Infinity;
    for (const known of list) if (known.length === embedding.length) { let d = 0; for (let i = 0; i < known.length; i++) d += known[i] * embedding[i]; best = Math.max(best, d); }
    if (best > -Infinity) scores.push({ name, similarity: best });
  }
  scores.sort((a, b) => b.similarity - a.similarity);
  const [first, second] = scores;
  if (!first || !Number.isFinite(first.similarity) || first.similarity < gallery.threshold) return null;
  if (second && first.similarity - second.similarity < margin && second.similarity >= gallery.threshold) return null;
  return first;
}

/** A name checks in after `confirm` s seen in a row; after a reset nobody checks in for `grace` s. */
export class CheckInBook {
  constructor(confirm = 0.6, grace = 3) { Object.assign(this, { confirm, grace }); this.checked = []; this.firstSeen = new Map(); this.quietUntil = -Infinity; }
  isChecked(name) { return this.checked.some((c) => c.name === name); }
  update(names, now, clock = new Date()) {
    const out = [];
    for (const name of names) {
      if (!this.firstSeen.has(name)) this.firstSeen.set(name, now);
      if (now - this.firstSeen.get(name) >= this.confirm && !this.isChecked(name) && now >= this.quietUntil) { this.checked.push({ name, time: clock }); out.push(name); }
    }
    for (const name of [...this.firstSeen.keys()]) if (!names.has(name)) this.firstSeen.delete(name);
    return out.sort();
  }
  reset(now) { this.checked = []; this.firstSeen = new Map(); this.quietUntil = now + this.grace; }
  remove(name) { this.checked = this.checked.filter((c) => c.name !== name); this.firstSeen.delete(name); }
}
