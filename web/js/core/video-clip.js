// Action recognition on video (r3d_18, Kinetics-400): the model takes 16 frames at once, as one 112 x 112
// input with 48 channels (frame after frame, red, green, blue in each). `VideoClip` keeps the latest frames
// of a live source; one picture alone is repeated 16 times, which shows the model no motion: it then
// guesses from the scene only (approximate). Port of StudioCore/VideoClip.swift.
import { Labels } from "./catalog.js";
import { PreparedFrame, pixelsOf, warp, sourceSize } from "./prep.js";
import { classifications } from "./decode.js";

const FRAME_COUNT = 16, SIDE = 112;
/** r3d_18_preprocessing: each frame stretched to 171 x 128, the middle 112 x 112 kept. */
const RESIZED = { width: 171, height: 128 };
/** Kinetics' channel means and deviations. */
const MEAN = [110.2008, 100.63983, 95.99475], STD = [58.14765, 56.46975, 55.332195];

export class VideoClip {
  /** The model's frame count (its input has 3 channels per frame). */
  static frameCount = FRAME_COUNT;
  /**
   * Frames are taken at most this often. torchvision trained r3d_18 on 16 consecutive frames at 15 per
   * second; on Hailo's demo videos 12 per second (1.3 s per clip) gave the steadiest answers.
   */
  static framesPerSecond = 12;
  /** A new answer every this many new frames (twice in 1.3 seconds). */
  static framesPerAnswer = 8;

  constructor() {
    this.frames = [];
    this.nextTime = null;
    this.sinceAnswer = 0;
    /** The latest answer, shown until the next one. */
    this.actions = [];
  }

  /** Adds a live frame taken at `time` (seconds). Returns the model input when a new answer is due, else null. */
  add(image, time, model) {
    const step = 1 / VideoClip.framesPerSecond;
    // Frames are taken on a steady beat (up to 10 ms early counts), so a 24 or 30 per second source averages
    // 12. After a pause the beat starts again; a clock that went back (a video starting over) restarts it.
    if (this.nextTime !== null && time >= this.nextTime - 2 * step && time < this.nextTime - 0.01) return null;
    const beat = (this.nextTime ?? time) + step;
    this.nextTime = beat < time || beat - time > 2 * step ? time + step : beat;
    this.frames.push(clipFrame(image));
    if (this.frames.length > FRAME_COUNT) this.frames.splice(0, this.frames.length - FRAME_COUNT);
    this.sinceAnswer++;
    if (this.frames.length < FRAME_COUNT || (this.actions.length && this.sinceAnswer < VideoClip.framesPerAnswer)) return null;
    this.sinceAnswer = 0;
    return clipFrameSet(this.frames, model, image);
  }

  /** One picture repeated as a whole clip. */
  static still(image, model) {
    return clipFrameSet(Array(FRAME_COUNT).fill(clipFrame(image)), model, image);
  }

  /** The five most likely actions. */
  static actions(tensor) { return classifications(tensor, 5, Labels.kinetics400); }
}

/** The frame as 112 x 112 RGB: stretched to 171 x 128 (bilinear, no smoothing) and the centre cut out (rows 8.., columns 29..), in one step. */
function clipFrame(image) {
  const pixels = pixelsOf(image), sx = pixels.width / RESIZED.width, sy = pixels.height / RESIZED.height;
  const left = Math.floor((RESIZED.width - SIDE) / 2), top = Math.floor((RESIZED.height - SIDE) / 2);
  return warp(pixels, SIDE, SIDE, [sx, (left + 0.5) * sx - 0.5], [sy, (top + 0.5) * sy - 0.5]);
}

/**
 * The clip in the stick's input format: normalized here (the model has no normalization layer) and quantized
 * with the input's zero point and scale (the engine turns them back into numbers); channel = frame x 3 + colour.
 */
function clipFrameSet(frames, model, image) {
  const stream = model.inputs[0], scale = stream.qpScale ?? 1, zero = stream.qpZp ?? 0;
  const pixels = SIDE * SIDE, channels = 3 * frames.length, rgb = new Uint8Array(pixels * channels);
  frames.forEach((frame, t) => {
    for (let i = 0; i < pixels; i++) for (let c = 0; c < 3; c++) {
      const value = (frame[i * 3 + c] - MEAN[c]) / STD[c];
      rgb[i * channels + t * 3 + c] = Math.min(255, Math.max(0, Math.round(value / scale + zero)));
    }
  });
  const { width, height } = sourceSize(image);
  return new PreparedFrame({ rgb, width: SIDE, height: SIDE, sourceWidth: width, sourceHeight: height, contentRect: { x: 0, y: 0, width: SIDE, height: SIDE } });
}
