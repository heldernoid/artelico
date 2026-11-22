// Steady video (port of StudioCore's PacedVideo.swift FramePacer and TrackSmoothing.swift TrackSmoother).
// Video files move on by an even number of frames each time, and tracked boxes and body points are
// One-Euro filtered per track number, so neither the picture nor the drawing over it shakes.
import { OneEuroFilter } from "./hand-games.js";

/**
 * Decides how far a video file moves on each frame shown.
 *
 * Showing "whatever frame is newest when the model is ready" jumps 2, then 4, then 3 frames, as the
 * model's time varies: motion looks jerky. Instead the video always moves on by the same `step`, chosen so
 * it keeps up with real time on average. The step only changes when the video has drifted more than
 * `tolerance` seconds from the clock, so it stays the same for seconds at a time.
 */
export class FramePacer {
  constructor(frameRate, tolerance = 0.4) {
    this.frameRate = Math.max(frameRate, 1);
    this.tolerance = tolerance;
    this.step = 1;
    this.shown = 0;      // video time of the frame last shown, from the first one (seconds)
    this.start = null;
  }

  /**
   * How many frames to move on when a frame is asked for at `now` (seconds): 0 means "not yet" (the model
   * is faster than the video, which then plays at its own speed).
   */
  advance(now) {
    if (this.start === null) { this.start = now; return 1; }
    const elapsed = now - this.start, next = this.shown + this.step / this.frameRate;
    if (this.step === 1 && next > elapsed) return 0;
    if (elapsed - next > this.tolerance) this.step++;                        // falling behind the clock
    else if (next - elapsed > this.tolerance && this.step > 1) this.step--;   // running ahead of it
    this.shown += this.step / this.frameRate;
    return this.step;
  }
}

/** Positions are filtered as if the picture were this many pixels wide and high (the filter's speed is in pixels per second). */
const SCALE = 1000;

/**
 * Steadies tracked boxes and body points from frame to frame. Each frame is detected from scratch, so a box
 * or a knee moves a few pixels even when nothing moves; drawn over video that reads as shaking. One-Euro
 * filters smooth a lot while something stands still and hardly at all while it moves fast.
 * Boxes are { x, y, width, height } and points { x, y }, normalized; times in seconds.
 */
export class TrackSmoother {
  constructor() { this.tracks = new Map(); }

  filters(id, time) {
    let f = this.tracks.get(id);
    if (!f) {
      // Boxes move as a whole: the centre follows a little faster than the size, which flickers most.
      f = { box: [new OneEuroFilter(1.0, 0.02), new OneEuroFilter(1.0, 0.02), new OneEuroFilter(0.6, 0.01), new OneEuroFilter(0.6, 0.01)], points: [], seen: time };
      this.tracks.set(id, f);
    }
    f.seen = time;
    return f;
  }

  /** `box` of track `id` at `time`, steadied. */
  box(box, id, time) {
    const f = this.filters(id, time).box, s = SCALE;
    const cx = f[0].filter((box.x + box.width / 2) * s, time) / s, cy = f[1].filter((box.y + box.height / 2) * s, time) / s;
    const w = f[2].filter(box.width * s, time) / s, h = f[3].filter(box.height * s, time) / s;
    return { x: cx - w / 2, y: cy - h / 2, width: w, height: h };
  }

  /** `points` of track `id` at `time`, steadied (x and y each filtered). */
  points(points, id, time) {
    const f = this.filters(id, time), s = SCALE;
    if (f.points.length !== points.length * 2) f.points = Array.from({ length: points.length * 2 }, () => new OneEuroFilter(1.0, 0.02));
    return points.map((p, i) => ({ x: f.points[2 * i].filter(p.x * s, time) / s, y: f.points[2 * i + 1].filter(p.y * s, time) / s }));
  }

  /** Forgets tracks not seen since `time`, so a number given again later starts fresh. */
  forget(time) { for (const [id, f] of this.tracks) if (f.seen < time) this.tracks.delete(id); }

  reset() { this.tracks.clear(); }
}
