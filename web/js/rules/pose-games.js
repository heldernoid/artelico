// Rules for the pose examples (raise hand to flip, hand-raise counter, air instrument, yoga coach, squat
// alarm, classroom). Port of StudioCore/PoseGames.swift: keypoints in "demo pixels" (640 wide for the Y
// demos, 1280 for Classroom), times passed in (seconds).

export const K = { nose: 0, leftEye: 1, rightEye: 2, leftEar: 3, rightEar: 4, leftShoulder: 5, rightShoulder: 6, leftElbow: 7, rightElbow: 8,
  leftWrist: 9, rightWrist: 10, leftHip: 11, rightHip: 12, leftKnee: 13, rightKnee: 14, leftAnkle: 15, rightAnkle: 16 };

/** 17 COCO keypoints { x, y, c } of one person, in a picture `width` x `height` pixels. */
export class BodyPose {
  constructor(points, width = 640, height = 480, id = null) { this.points = points; this.width = width; this.height = height; this.id = id; }
  /** From a decoded pose (positions as fractions) and the picture's aspect ratio. */
  static from(pose, aspect, width = 640) {
    const height = width / Math.max(aspect, 0.01);
    return new BodyPose(pose.keypoints.map((k) => ({ x: k.position.x * width, y: k.position.y * height, c: k.confidence })), width, height, pose.trackID ?? null);
  }
  at(i) { return this.points[i]; }
  /** The point when seen with at least `conf`, else null. */
  point(i, conf) { const p = this.points[i]; return p.c >= conf ? { x: p.x, y: p.y } : null; }
  seen(i, conf) { return this.points[i].c >= conf; }
}

/** Angle at b (degrees) of the corner a-b-c; null when a point is missing. */
export function jointAngle(a, b, c) {
  if (!a || !b || !c) return null;
  const bax = a.x - b.x, bay = a.y - b.y, bcx = c.x - b.x, bcy = c.y - b.y;
  const na = Math.hypot(bax, bay), nc = Math.hypot(bcx, bcy);
  if (!(na > 0 && nc > 0)) return null;
  return (Math.acos(Math.max(-1, Math.min(1, (bax * bcx + bay * bcy) / (na * nc)))) * 180) / Math.PI;
}

// MARK: Y2 raise a hand to flip slides

/** "none" | "right" | "left" | "both": a wrist more than `margin` px above the nose. */
export function raisedHands(b, conf = 0.5, margin = 40) {
  const nose = b.point(K.nose, conf);
  if (!nose) return "none";
  const limit = nose.y - margin;
  const left = (b.point(K.leftWrist, conf)?.y ?? Infinity) < limit, right = (b.point(K.rightWrist, conf)?.y ?? Infinity) < limit;
  return left && right ? "both" : right ? "right" : left ? "left" : "none";
}

/** Same gesture for `confirmFrames` frames, hands lowered between actions, a cooldown after each. */
export class GestureController {
  constructor(confirmFrames = 4, cooldown = 1.2) { Object.assign(this, { confirmFrames, cooldown, last: "none", stable: 0, armed: true, lastTrigger: -Infinity }); }
  /** Returns "next" | "previous" | "restart" | null. */
  update(gesture, now) {
    if (gesture === this.last) this.stable++; else { this.stable = 1; this.last = gesture; }
    if (gesture === "none") { this.armed = true; return null; }
    if (now - this.lastTrigger < this.cooldown || !this.armed || this.stable < this.confirmFrames) return null;
    this.armed = false; this.lastTrigger = now;
    return { right: "next", left: "previous", both: "restart" }[gesture];
  }
}

// MARK: Y4 hand-raise counter

export const HandRaiseCounter = {
  isRaised(b, conf = 0.5, margin = 20) {
    let base;
    const nose = b.point(K.nose, conf);
    if (nose) base = nose.y;
    else { const l = b.point(K.leftShoulder, conf), r = b.point(K.rightShoulder, conf); if (!l || !r) return false; base = (l.y + r.y) / 2; }
    return [K.leftWrist, K.rightWrist].some((w) => { const p = b.point(w, conf); return p && p.y < base - margin; });
  },
  count(bodies, conf = 0.5, margin = 20) { return { raised: bodies.filter((b) => this.isRaised(b, conf, margin)).length, total: bodies.length }; },
};

// MARK: Y3 air instrument

/** `zones` vertical strips, one note each; a wrist entering a strip plays it (cooldown per note). */
export class AirInstrument {
  constructor(zones = 5, cooldown = 0.15) { Object.assign(this, { zones, cooldown, lastZone: new Map(), lastFire: new Map() }); }
  zoneOf(x, width) { return Math.max(0, Math.min(this.zones - 1, Math.floor((x / width) * this.zones))); }
  update(bodies, conf = 0.5, now) {
    const fired = [], seen = new Set();
    bodies.forEach((b, index) => {
      const person = b.id != null ? `#${b.id}` : `${index}`;
      for (const [hand, joint] of [["L", K.leftWrist], ["R", K.rightWrist]]) {
        const key = person + hand;
        seen.add(key);
        const p = b.point(joint, conf), zone = p ? this.zoneOf(p.x, b.width) : null;
        if (zone !== null && zone !== this.lastZone.get(key) && now - (this.lastFire.get(zone) ?? -Infinity) >= this.cooldown) { fired.push(zone); this.lastFire.set(zone, now); }
        this.lastZone.set(key, zone);
      }
    });
    for (const key of [...this.lastZone.keys()]) if (!seen.has(key)) this.lastZone.delete(key);
    return fired;
  }
}

// MARK: Y5 yoga coach

const YC = 0.45;
const legsVisible = (b, c = 0.4) => (b.seen(K.leftKnee, c) && b.seen(K.leftAnkle, c)) || (b.seen(K.rightKnee, c) && b.seen(K.rightAnkle, c));
function torso(b) {
  const ls = b.point(K.leftShoulder, YC), rs = b.point(K.rightShoulder, YC), lh = b.point(K.leftHip, YC), rh = b.point(K.rightHip, YC);
  return ls && rs && lh && rh ? Math.abs((lh.y + rh.y) / 2 - (ls.y + rs.y) / 2) : null;
}
const kneeAngles = (b) => [jointAngle(b.point(K.leftHip, YC), b.point(K.leftKnee, YC), b.point(K.leftAnkle, YC)),
  jointAngle(b.point(K.rightHip, YC), b.point(K.rightKnee, YC), b.point(K.rightAnkle, YC))].filter((a) => a !== null);
function handsOverHead(b) {
  const n = b.point(K.nose, YC), l = b.point(K.leftWrist, YC), r = b.point(K.rightWrist, YC);
  return n && l && r ? l.y < n.y && r.y < n.y : null;
}
const ok = () => [true, ""], no = (hint) => [false, hint];

export const YOGA = [
  { id: "tree", title: "Tree", steps: ["Stand tall", "Raise both arms", "Hands above your head"], check(b) {
    if (!b.point(K.nose, YC)) return no("Show your head to the camera");
    if (!b.seen(K.leftWrist, YC) || !b.seen(K.rightWrist, YC)) return no("Raise both hands so the camera sees them");
    return handsOverHead(b) === true ? ok() : no("Raise both hands above your head");
  } },
  { id: "warrior", title: "Warrior II", steps: ["Feet apart", "Arms out to the sides", "Level with your shoulders"], check(b) {
    const ls = b.point(K.leftShoulder, YC), rs = b.point(K.rightShoulder, YC);
    if (!ls || !rs) return no("Show your shoulders to the camera");
    const lw = b.point(K.leftWrist, YC), rw = b.point(K.rightWrist, YC);
    if (!lw || !rw) return no("Raise both arms to the sides");
    const sy = (ls.y + rs.y) / 2, sw = Math.abs(ls.x - rs.x), tol = Math.max(40, sw * 0.4);
    if (!(Math.abs(lw.x - rw.x) > sw * 1.3)) return no("Spread your arms out wide");
    if (!(Math.abs(lw.y - sy) < tol && Math.abs(rw.y - sy) < tol)) return no("Keep your arms level with your shoulders");
    return ok();
  } },
  { id: "warrior1", title: "Warrior I", steps: ["Step one foot forward", "Bend the front knee", "Raise both arms up"], check(b) {
    const up = handsOverHead(b);
    if (up === null) return no("Raise both hands overhead");
    if (!up) return no("Raise both hands above your head");
    if (!legsVisible(b)) return no("Step back so the camera sees your legs");
    return kneeAngles(b).some((a) => a < 150) ? ok() : no("Bend your front knee (lunge)");
  } },
  { id: "triangle", title: "Triangle", steps: ["Feet wide apart", "Lean to one side", "One arm up, one down"], check(b) {
    const ls = b.point(K.leftShoulder, YC), rs = b.point(K.rightShoulder, YC), lw = b.point(K.leftWrist, YC), rw = b.point(K.rightWrist, YC);
    if (!ls || !rs || !lw || !rw) return no("Show your shoulders and both hands");
    const sw = Math.abs(ls.x - rs.x);
    if (sw < 1) return no("Face the camera");
    if (Math.abs(lw.x - rw.x) <= sw * 1.2) return no("Spread your arms apart");
    if (Math.abs(lw.y - rw.y) <= sw * 0.7) return no("Tilt: one hand up, one hand down");
    return ok();
  } },
  { id: "squat", title: "Squat", steps: ["Feet apart", "Bend your knees, squat down", "Palms together at your chest"], check(b) {
    if (!legsVisible(b)) return no("Step back so the camera sees your legs");
    const knees = kneeAngles(b);
    if (!knees.length || Math.min(...knees) >= 120) return no("Bend your knees and squat down");
    const ls = b.point(K.leftShoulder, YC), rs = b.point(K.rightShoulder, YC), lw = b.point(K.leftWrist, YC), rw = b.point(K.rightWrist, YC);
    if (!ls || !rs || !lw || !rw) return no("Bring your hands to your chest");
    return Math.hypot(lw.x - rw.x, lw.y - rw.y) < Math.max(60, Math.abs(ls.x - rs.x) * 0.5) ? ok() : no("Put your palms together at your chest");
  } },
  { id: "tree1", title: "Tree, one leg", steps: ["Stand on one leg", "Lift the other foot", "Raise both arms up"], check(b) {
    const up = handsOverHead(b);
    if (up === null) return no("Raise both hands overhead");
    if (!up) return no("Raise both hands above your head");
    if (!legsVisible(b)) return no("Step back so the camera sees your legs");
    const la = b.point(K.leftAnkle, YC), ra = b.point(K.rightAnkle, YC), t = torso(b);
    if (!la || !ra || t === null) return no("Show both feet to the camera");
    return Math.abs(la.y - ra.y) > t * 0.4 ? ok() : no("Lift one foot off the ground");
  } },
];

/** One pose: time held counts once the pose is right for `confirmFrames` frames; done after `holdTarget` s. */
export class YogaCoach {
  constructor(pose, holdTarget = 8, confirmFrames = 3) { Object.assign(this, { pose, holdTarget, confirmFrames, stable: 0, accumulated: 0, lastTick: null, done: false, hint: "" }); }
  update(body, now, active = true) {
    if (!active) { this.stable = 0; this.lastTick = null; return this.state(false); }
    const [good, hint] = body ? this.pose.check(body) : [false, "Step into the camera's view"];
    this.hint = hint;
    this.stable = good ? this.stable + 1 : 0;
    const confirmed = this.stable >= this.confirmFrames;
    if (confirmed) {
      if (this.lastTick !== null) this.accumulated += now - this.lastTick;
      this.lastTick = now;
      if (this.accumulated >= this.holdTarget) this.done = true;
    } else this.lastTick = null;
    return this.state(confirmed);
  }
  state(confirmed) {
    return { title: this.pose.title, inPose: confirmed, held: Math.min(this.accumulated, this.holdTarget), target: this.holdTarget, done: this.done,
      hint: confirmed || this.done ? "" : this.hint, steps: this.pose.steps };
  }
}

/** Every pose once in random order, a short celebration between them, finished after the last. */
export class YogaRound {
  constructor(pool = YOGA, holdTarget = 8, celebration = 2, shuffled = true) { Object.assign(this, { pool, holdTarget, celebration }); this.restart(shuffled); }
  restart(shuffled = true) {
    this.completed = 0; this.finished = false; this.celebratingSince = null;
    this.deck = shuffled ? [...this.pool].sort(() => Math.random() - 0.5) : [...this.pool].reverse();
    this.coach = this.nextCoach();
  }
  nextCoach() { return this.deck.length ? new YogaCoach(this.deck.pop(), this.holdTarget) : null; }
  get currentPose() { return this.coach?.pose ?? null; }
  skip() { if (!this.finished) this.advance(); }
  advance() { this.completed++; this.celebratingSince = null; this.coach = this.nextCoach(); if (!this.coach) this.finished = true; }
  update(body, now) {
    const total = this.pool.length;
    if (this.finished || !this.coach) return { coach: null, completed: this.completed, total, celebrating: false, finished: true, justCompletedPose: false };
    if (this.celebratingSince !== null) {
      if (now - this.celebratingSince >= this.celebration) { this.advance(); return this.update(body, now); }
      return { coach: this.coach.state(false), completed: this.completed, total, celebrating: true, finished: false, justCompletedPose: false };
    }
    const state = this.coach.update(body, now);
    let just = false;
    if (state.done) { this.celebratingSince = now; just = true; }
    return { coach: state, completed: this.completed, total, celebrating: state.done, finished: false, justCompletedPose: just };
  }
}

// MARK: WakeUp squat counter

/** Stand -> down -> stand counts one squat (mean knee angle; changes need `confirmFrames` frames). */
export class SquatCounter {
  constructor(target = 5, upAngle = 160, downAngle = 105, confirmFrames = 3, conf = 0.4) { Object.assign(this, { target, upAngle, downAngle, confirmFrames, conf }); this.reset(); }
  get done() { return this.count >= this.target; }
  reset() { this.count = 0; this.phase = "stand"; this.pending = null; this.pendingFrames = 0; }
  static kneeAngle(b, conf = 0.4) {
    const s = [jointAngle(b.point(K.leftHip, conf), b.point(K.leftKnee, conf), b.point(K.leftAnkle, conf)),
      jointAngle(b.point(K.rightHip, conf), b.point(K.rightKnee, conf), b.point(K.rightAnkle, conf))].filter((a) => a !== null);
    return s.length ? s.reduce((a, b2) => a + b2, 0) / s.length : null;
  }
  update(body) {
    const angle = body ? SquatCounter.kneeAngle(body, this.conf) : null;
    if (angle === null) { this.pending = null; this.pendingFrames = 0; return { count: this.count, phase: this.phase, angle: null, visible: false, done: this.done, justCounted: false }; }
    let just = false;
    const candidate = angle < this.downAngle ? "down" : angle > this.upAngle ? "stand" : null;
    if (candidate === null || candidate === this.phase) { this.pending = null; this.pendingFrames = 0; }
    else {
      if (candidate === this.pending) this.pendingFrames++; else { this.pending = candidate; this.pendingFrames = 1; }
      if (this.pendingFrames >= this.confirmFrames) {
        if (this.phase === "down" && candidate === "stand" && !this.done) { this.count++; just = true; }
        this.phase = candidate; this.pending = null; this.pendingFrames = 0;
      }
    }
    return { count: this.count, phase: this.phase, angle, visible: true, done: this.done, justCounted: just };
  }
}

// MARK: Classroom attention

export const Attention = {
  keypointConf: 0.3, raiseHold: 1.2, downHold: 2.0, phoneHold: 3.0, sleepHold: 3.0, turnHold: 2.5,
  raiseAboveEyes: 0.6, phoneNearWrist: 1.2, downEyeEar: 0.12, downNoseShoulder: 0.18, turnFarEye: 0.3, minShoulderWidthForFace: 60,
  STATES: { ok: "Paying attention", phone: "Phone", sleeping: "Head on desk", head_down: "Head down", turned: "Turned away" },
  priority: ["phone", "sleeping", "head_down", "turned"],

  ok(b, i) { return b.at(i).c >= this.keypointConf; },
  shoulderLine(b) {
    if (!this.ok(b, K.leftShoulder) || !this.ok(b, K.rightShoulder)) return null;
    return { y: (b.at(K.leftShoulder).y + b.at(K.rightShoulder).y) / 2, width: Math.abs(b.at(K.leftShoulder).x - b.at(K.rightShoulder).x) };
  },
  instantFlags(b) {
    const f = { raised: false, headDown: false, sleeping: false, turned: false };
    const s = this.shoulderLine(b);
    const eyes = [K.leftEye, K.rightEye].filter((i) => this.ok(b, i)).map((i) => b.at(i).y);
    const eyeLine = eyes.length ? eyes.reduce((a, c) => a + c, 0) / eyes.length : this.ok(b, K.nose) ? b.at(K.nose).y : null;
    if (s && s.width > 0 && s.width >= this.minShoulderWidthForFace * 0.5 && eyeLine !== null) {
      for (const [wrist, elbow] of [[K.leftWrist, K.leftElbow], [K.rightWrist, K.rightElbow]]) {
        const elbowUp = this.ok(b, elbow) && b.at(elbow).y < s.y;
        if (this.ok(b, wrist)) { if (elbowUp && b.at(wrist).y < eyeLine - this.raiseAboveEyes * s.width) f.raised = true; }
        else if (this.ok(b, elbow) && b.at(elbow).y < eyeLine) f.raised = true;
      }
    }
    if (s && s.width > 0) {
      const headSeen = this.ok(b, K.nose) || eyes.length > 0;
      if (headSeen && s.width >= this.minShoulderWidthForFace) {
        if (this.ok(b, K.nose)) {
          if (b.at(K.nose).y > s.y) f.sleeping = true;
          else if (b.at(K.nose).y > s.y - this.downNoseShoulder * s.width) f.headDown = true;
        }
        const ears = [K.leftEar, K.rightEar].filter((i) => this.ok(b, i)).map((i) => b.at(i).y);
        if (eyes.length && ears.length && eyes.reduce((a, c) => a + c, 0) / eyes.length > ears.reduce((a, c) => a + c, 0) / ears.length + this.downEyeEar * s.width) f.headDown = true;
      }
    }
    const le = b.at(K.leftEye).c, re = b.at(K.rightEye).c;
    if (s && s.width >= this.minShoulderWidthForFace && ((le >= 0.5 && re < this.turnFarEye) || (re >= 0.5 && le < this.turnFarEye))) f.turned = true;
    return f;
  },
  wrists(b) { return [K.leftWrist, K.rightWrist].filter((i) => this.ok(b, i)).map((i) => ({ x: b.at(i).x, y: b.at(i).y })); },
  box(b, pad = 0.25) {
    const pts = b.points.filter((p) => p.c >= this.keypointConf);
    if (pts.length < 2) return null;
    const xs = pts.map((p) => p.x), ys = pts.map((p) => p.y);
    const w = Math.max(Math.max(...xs) - Math.min(...xs), 20), h = Math.max(Math.max(...ys) - Math.min(...ys), 20);
    const x1 = Math.trunc(Math.min(...xs) - w * pad), y1 = Math.trunc(Math.min(...ys) - h * pad * 1.6);
    const x2 = Math.trunc(Math.max(...xs) + w * pad), y2 = Math.trunc(Math.max(...ys) + h * pad);
    return { x: x1, y: y1, width: x2 - x1, height: y2 - y1 };
  },
  /** Each phone to the person whose box holds its centre, below the shoulders, near a wrist. Returns Map id -> phones. */
  assignPhones(phones, people) {
    const out = new Map();
    for (const phone of phones) {
      const cx = phone.x + phone.width / 2, cy = phone.y + phone.height / 2;
      let best = null;
      for (const p of people) {
        const box = p.box;
        if (!box || cx < box.x || cx > box.x + box.width || cy < box.y || cy > box.y + box.height) continue;
        if (p.shoulderY != null && cy < p.shoulderY) continue;
        if (p.wrists.length) {
          const scale = p.shoulderWidth ?? box.width * 0.5;
          if (Math.min(...p.wrists.map((w) => Math.hypot(w.x - cx, w.y - cy))) > this.phoneNearWrist * scale) continue;
        }
        const d = (box.x + box.width / 2 - cx) ** 2 + (box.y + box.height / 2 - cy) ** 2;
        if (!best || d < best.d) best = { id: p.id, d };
      }
      if (best) { if (!out.has(best.id)) out.set(best.id, []); out.get(best.id).push(phone); }
    }
    return out;
  },
  /** 3 x 3 seats: row 0 = back of the room (top of the picture), column 0 = left. */
  gridCell(box, width, height) {
    return { row: Math.min(2, Math.max(0, Math.floor(((box.y + box.height / 2) * 3) / height))), column: Math.min(2, Math.max(0, Math.floor(((box.x + box.width / 2) * 3) / width))) };
  },
  summarize(people, width, height) {
    const out = { raised: 0, inattentive: 0, byState: {}, grid: [[0, 0, 0], [0, 0, 0], [0, 0, 0]] };
    for (const p of people) {
      if (p.raised) { out.raised++; if (p.box) { const c = this.gridCell(p.box, width, height); out.grid[c.row][c.column]++; } }
      if (p.state !== "ok") { out.inattentive++; out.byState[p.state] = (out.byState[p.state] ?? 0) + 1; }
    }
    return out;
  },
};

/** One tracked person in the classroom: a state counts once it has lasted its hold time. */
export class AttentionPerson {
  constructor() { this.state = "ok"; this.raised = false; this.box = null; this.since = {}; }
  hold(key, active, duration, now) {
    if (!active) { delete this.since[key]; return false; }
    this.since[key] ??= now;
    return now - this.since[key] >= duration;
  }
  shift(seconds) { for (const k of Object.keys(this.since)) this.since[k] += seconds; }
  update(b, phones, enabled, now, box = null) {
    const A = Attention;
    this.box = box ?? A.box(b);
    const f = A.instantFlags(b);
    this.raised = this.hold("raise", f.raised, A.raiseHold, now);
    const held = {
      phone: this.hold("phone", phones.length > 0, A.phoneHold, now),
      sleeping: this.hold("sleeping", f.sleeping, A.sleepHold, now),
      head_down: this.hold("head_down", f.headDown && !f.sleeping, A.downHold, now),
      turned: this.hold("turned", f.turned, A.turnHold, now),
    };
    this.state = A.priority.find((s) => enabled.has(s) && held[s]) ?? "ok";
    return this.state;
  }
}
