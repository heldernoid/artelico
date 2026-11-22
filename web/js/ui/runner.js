// Frames from the camera, a video file, a stream or a still picture, run through a model one after another
// (the web counterpart of the apps' PoseRunner). Each analysed frame goes to `onFrame`.
// Video files are not played freely: the paused <video> is moved on by an even number of frames each time
// (FramePacer, js/rules/steady-video.js; port of StudioCore's PacedVideoReader). Cameras and streams are
// live and give their newest frame.
import { el, imageFromFile, loadImage, store } from "./common.js";
import { run } from "../core/pipeline.js";
import { VideoClip } from "../core/video-clip.js";
import { ReIdentification } from "../core/crop-tasks.js";
import { FramePacer } from "../rules/steady-video.js";
import { sampleVideoURL } from "./hailo-videos.js";

export const SOURCES = { camera: "Camera", video: "Video file", stream: "Stream address", picture: "Photo" };

/** The cameras the browser can see (names appear once the page may use the camera). */
export async function listCameras() {
  try { return (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === "videoinput"); } catch { return []; }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Whether `media` (its metadata loaded) has a sound track: true, false, or null when the browser does not
 * say. Firefox has mozHasAudio, Safari lists audioTracks, Chrome shows the tracks through captureStream().
 */
function hasSound(media) {
  if (typeof media.mozHasAudio === "boolean") return media.mozHasAudio;
  if (media.audioTracks) return media.audioTracks.length > 0;
  try { if (media.captureStream) return media.captureStream().getAudioTracks().length > 0; } catch { /* not allowed */ }
  return null;
}

/**
 * The sound of a video file while its frames are shown one by one (PacedVideo): a second element plays the
 * same file in real time and is moved back to the frame shown whenever they drift apart by more than a
 * quarter of a second (the pacer keeps the frames in real time, so this is rare).
 */
class VideoSound {
  constructor() {
    this.media = el("audio", { preload: "auto", loop: true });
    this.media.crossOrigin = "anonymous";
    this.on = store.get("video.sound", "1") === "1";
    this.present = null;   // whether the file has a sound track (null: not known yet)
    this.blocked = false;  // the browser would not start the sound without a click
  }

  open(url) {
    this.close();
    this.present = null;
    this.media.src = url;
    this.media.addEventListener("loadedmetadata", () => { this.present = hasSound(this.media); this.onChange?.(); }, { once: true });
    this.onChange?.();
  }

  close() { this.media.pause(); this.media.removeAttribute("src"); this.media.load(); }

  /** Keeps the sound at `seconds` into the file, playing while `playing`. */
  follow(seconds, playing) {
    const m = this.media;
    if (!m.src || !playing) { if (!m.paused) m.pause(); return; }
    m.muted = !this.on;   // off, it plays on silently, so turning it on needs no seek
    const duration = m.duration;
    if (Number.isFinite(duration) && duration > 0) {
      const target = seconds % duration;
      let drift = Math.abs(m.currentTime - target);
      drift = Math.min(drift, duration - drift);   // across the loop point
      if (drift > 0.25) m.currentTime = target;
    }
    if (m.paused) {
      const blocked = (value) => { if (this.blocked !== value) { this.blocked = value; this.onChange?.(); } };
      m.play().then(() => blocked(false)).catch((e) => { if (e.name === "NotAllowedError") blocked(true); });
    }
  }

  set(on) { this.on = on; store.set("video.sound", on ? "1" : "0"); this.media.muted = !on; }
}

/** The video's frame rate, from the times of a few frames while it plays (null when the browser cannot tell). */
function measureFrameRate(video) {
  if (!video.requestVideoFrameCallback) return Promise.resolve(null);
  return new Promise((resolve) => {
    const times = [];
    const finish = () => {
      clearTimeout(timer);
      let d = Infinity;   // the shortest gap: a frame the page skipped makes a gap of two
      for (let i = 1; i < times.length; i++) if (times[i] - times[i - 1] > 1 / 240) d = Math.min(d, times[i] - times[i - 1]);
      if (!Number.isFinite(d)) return resolve(null);
      const rate = 1 / d, whole = Math.round(rate);
      resolve(Math.abs(rate - whole) < whole * 0.01 ? whole : rate);
    };
    const timer = setTimeout(finish, 2000);
    const frame = (_, meta) => { times.push(meta.mediaTime); if (times.length >= 10) finish(); else video.requestVideoFrameCallback(frame); };
    video.requestVideoFrameCallback(frame);
  });
}

/**
 * A video file shown frame by frame: the <video> stays paused and is moved to exact frames, an even step
 * each time (FramePacer), looping at the end. The next frame is sought while the model works on this one,
 * so seeking (about 15 ms a frame in Chrome for 720p, 70 ms for 4K) does not slow the loop down.
 */
class PacedVideo {
  constructor(video, frameRate, offset) {
    Object.assign(this, { video, frameRate, offset, index: 0 });
    this.frames = Math.max(1, Math.round(video.duration * frameRate));
    this.pacer = new FramePacer(frameRate);
  }

  /** Paces `video` (just given its address), or null when it cannot be (no length or frame rate known): it then plays freely. */
  static async open(video, offset) {
    await video.play();   // playing a moment tells the frame rate
    const rate = await measureFrameRate(video);
    if (!rate || !Number.isFinite(video.duration) || video.duration <= 0) return null;
    video.pause();
    const paced = new PacedVideo(video, rate, offset);
    await paced.seek(0);
    return paced;
  }

  /** The time of the frame shown within the file, in seconds (loops back to 0 at the end). */
  get fileTime() { return (this.index % this.frames) / this.frameRate; }

  /** The time of the frame shown, in seconds from the start of the run (continuous over loops). */
  get time() { return this.offset + this.index / this.frameRate; }

  /** Moves the video to frame `index` (looping), the middle of the frame so rounding cannot pick its neighbour. */
  seek(index) {
    const v = this.video, t = Math.min(((index % this.frames) + 0.5) / this.frameRate, v.duration - 0.001);
    return new Promise((resolve) => {
      const done = () => { clearTimeout(timer); v.removeEventListener("seeked", done); v.removeEventListener("emptied", done); resolve(); };
      const timer = setTimeout(done, 2000);   // a seek that never finishes does not stop the loop
      v.addEventListener("seeked", done);
      v.addEventListener("emptied", done);   // another video was chosen
      v.currentTime = t;
    });
  }

  /** Waits until the next frame is due (the pacer says 0 while the model is faster than the video), then moves to it. */
  async next(going) {
    let steps;
    while (!(steps = this.pacer.advance(performance.now() / 1000))) { if (!going()) return; await sleep(4); }
    if (!going()) return;
    this.index += steps;
    await this.seek(this.index);
  }

  /** After a pause: the clock starts again from the frame shown, so the video does not jump to catch up. */
  restartClock() { this.pacer = new FramePacer(this.frameRate); }
}

export class FrameRunner {
  /**
   * @param app shared state
   * @param options { task, onFrame(frame), sources: [...], extras(): model names to load next to the main one,
   *   prompts(): what tagging from text looks for }
   * frame: { image (canvas), result, prepared, time (s), inferenceMs, width, height }
   */
  constructor(app, options) {
    this.app = app;
    Object.assign(this, { task: "detection", sources: ["front", "back", "video", "picture"], extras: () => [], prompts: () => undefined, onFrame: () => {}, onStop: () => {} }, options);
    // Screens say which way the camera should face ("front" first: at the user, "back": at the scene).
    // Both become one "Camera" source listing the real cameras (a computer's webcams, a phone's front
    // and back); the facing is only the default where the browser can choose (phones).
    const facing = this.sources.find((x) => x === "front" || x === "back");
    this.facing = facing === "back" ? "environment" : "user";
    this.sources = [...new Set(this.sources.map((x) => (x === "front" || x === "back" ? "camera" : x)))];
    this.cameraId = store.get("camera.device") ?? "";
    this.cameraMirrored = this.facing === "user";
    this.source = this.sources[0];
    this.running = false;
    this.paused = false;
    this.fps = 0;
    this.picture = null;
    this.videoURL = null;
    this.streamURL = "";
    this.canvas = document.createElement("canvas");   // the current frame, mirrored for the front camera
    this.video = el("video", { playsInline: true, muted: true, loop: true, autoplay: true });
    this.video.muted = true;
    this.paced = null;   // a PacedVideo while a video file is the source
    this.sound = new VideoSound();   // the video file's sound, following the frames shown
  }

  /** The picture is mirrored for a camera facing the user (as a mirror), not for one facing away. */
  get mirrored() { return this.source === "camera" && this.cameraMirrored; }

  async start(modelName) {
    if (this.running) return;
    this.running = true;
    this.message = "";
    try {
      await this.app.load(modelName, { extras: this.extras() });
      // Each start: a new clip of frames for the video model, people numbered from 1 again.
      this.clip = null;
      ReIdentification.reset();
      const started = performance.now();
      this.clock = () => (performance.now() - started) / 1000;   // frame times, from the start of the run
      await this.openSource();
      this.loop(modelName);
    } catch (error) {
      this.running = false;
      this.closeSource();
      throw error;
    }
  }

  stop() { this.running = false; }

  async openSource() {
    this.closeSource();
    if (this.source === "camera") {
      if (!navigator.mediaDevices?.getUserMedia) throw new Error("This browser cannot use the camera here (it needs https or localhost).");
      const size = { width: { ideal: 1280 }, height: { ideal: 720 } };
      const wanted = this.cameraId ? { deviceId: { exact: this.cameraId }, ...size } : { facingMode: { ideal: this.facing }, ...size };
      try {
        this.stream = await navigator.mediaDevices.getUserMedia({ video: wanted, audio: false });
      } catch (error) {
        if (!this.cameraId || error.name !== "OverconstrainedError" && error.name !== "NotFoundError") throw error;
        this.cameraId = "";   // the remembered camera is gone (unplugged): use any
        this.stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: this.facing }, ...size }, audio: false });
      }
      // Computers' webcams do not say which way they face; they face the user.
      const facingMode = this.stream.getVideoTracks()[0]?.getSettings().facingMode;
      this.cameraMirrored = facingMode ? facingMode === "user" : true;
      this.video.srcObject = this.stream;
      await this.video.play();
      this.onCameraOpened?.();   // names of the cameras are known now
    } else if (this.source === "video" || this.source === "stream") {
      const url = this.source === "video" ? this.videoURL : this.streamURL.trim();
      if (!url) throw new Error(this.source === "video" ? "Choose a video first." : "Enter a stream address (an http(s) video or .m3u8 address the site allows).");
      this.video.crossOrigin = "anonymous";
      this.video.src = url;
      if (this.source === "video") {
        const opening = (this.opening = {});
        const paced = await PacedVideo.open(this.video, this.clock());
        if (this.opening === opening) this.paced = paced;   // not when another source was chosen meanwhile
        if (this.paced) this.sound.open(url);
        else this.video.muted = !this.sound.on;   // not paced: the video plays freely, with its own sound
      } else {
        this.video.muted = !this.sound.on;   // a stream plays freely, with its own sound
        await this.video.play().catch(async (e) => { if (e.name !== "NotAllowedError") throw e; this.video.muted = true; await this.video.play(); });
      }
    } else if (!this.picture) {
      throw new Error("Choose a photo first.");
    }
  }

  closeSource() {
    this.paced = null;
    this.sound.close();
    this.video.muted = true;
    this.opening = null;
    this.stream?.getTracks().forEach((t) => t.stop());
    this.stream = null;
    this.video.pause();
    this.video.removeAttribute("src");
    this.video.srcObject = null;
  }

  /** Copies the current frame into `this.canvas` (mirrored for the front camera). Returns false when there is none yet. */
  grab() {
    const live = this.source !== "picture";
    const src = live ? this.video : this.picture;
    const w = live ? this.video.videoWidth : src.naturalWidth || src.width, h = live ? this.video.videoHeight : src.naturalHeight || src.height;
    if (!w || !h) return false;
    if (this.canvas.width !== w || this.canvas.height !== h) { this.canvas.width = w; this.canvas.height = h; }
    const ctx = this.canvas.getContext("2d", { willReadFrequently: true });
    ctx.save();
    if (this.mirrored) { ctx.translate(w, 0); ctx.scale(-1, 1); }
    ctx.drawImage(src, 0, 0, w, h);
    ctx.restore();
    return true;
  }

  async loop(modelName) {
    let windowStart = performance.now(), windowFrames = 0;
    try {
      while (this.running) {
        if (this.paused || !this.grab()) { this.paced?.restartClock(); this.sound.follow(0, false); await sleep(30); continue; }
        // A video file: its own time, and the next frame is sought while this one is analysed.
        const paced = this.paced;
        const time = paced ? paced.time : this.clock();
        const moving = paced?.next(() => this.running && !this.paused && this.paced === paced);
        let data;
        if (this.analyse) {
          // The example's own steps (several models, tracking...): returns what onFrame needs.
          const t0 = performance.now();
          data = await this.analyse(this.canvas, this.app.engine, time);
          data.inferenceMs ??= performance.now() - t0;
        } else {
          const clip = this.task === "video_classification" ? (this.clip ??= new VideoClip()) : undefined;
          const gallery = this.task === "person_re_id" ? ReIdentification.session(this.app.engine.loadedModel) : undefined;
          const { result, timing, frame } = await run(this.task, this.canvas, this.app.engine, { clip, time, gallery, prompts: this.prompts() });
          data = { result, prepared: frame, inferenceMs: timing.inference };
        }
        await this.onFrame({ image: this.canvas, time, width: this.canvas.width, height: this.canvas.height, ...data });
        await moving;
        if (paced && this.paced === paced) this.sound.follow(paced.fileTime, this.running && !this.paused);
        windowFrames++;
        const now = performance.now();
        if (now - windowStart >= 500) { this.fps = (windowFrames * 1000) / (now - windowStart); windowStart = now; windowFrames = 0; }
        await new Promise((r) => requestAnimationFrame(r));
      }
    } catch (error) {
      this.message = `Stopped: ${error.message ?? error}`;
    }
    this.running = false;
    this.closeSource();
    void modelName;
    this.onStop(this.message);
  }

  /** Source controls: a select plus the file, address or photo inputs it needs. */
  controls(onChange = () => {}) {
    // A different camera, video or address while running: switch to it without stopping.
    const changed = onChange;
    onChange = () => {
      changed();
      if (this.running && this.source !== "picture") this.openSource().catch((e) => { this.message = e.message; this.running = false; });
    };
    const select = el("select", { "aria-label": "Source" }, this.sources.map((s) => el("option", { value: s, selected: s === this.source }, SOURCES[s])));
    const videoInput = el("input", { type: "file", accept: "video/*", hidden: true, onchange: () => { const f = videoInput.files[0]; if (f) { this.videoURL = URL.createObjectURL(f); this.sampleFile = null; refresh(); onChange(); } } });
    const photoInput = el("input", { type: "file", accept: "image/*", hidden: true, onchange: async () => { const f = photoInput.files[0]; if (f) { this.picture = await imageFromFile(f); this.sampleFile = null; refresh(); onChange(); } } });
    const extra = el("span");
    // Sound of a video file or stream: on by default, remembered; hidden once the file is known to have none.
    const soundButton = el("button.button", { onclick: () => {
      this.sound.set(!this.sound.on || this.sound.blocked);
      if (this.sound.on && this.paced) this.sound.follow(this.paced.fileTime, this.running && !this.paused);   // a click may start it
      if (!this.paced && this.source !== "picture" && this.source !== "camera") this.video.muted = !this.sound.on;
      showSound();
    } });
    const showSound = () => {
      const blocked = this.sound.on && this.sound.blocked;
      soundButton.textContent = blocked ? "🔇 Click for sound" : this.sound.on ? "🔊 Sound" : "🔇 Muted";
      soundButton.title = this.sound.on ? "Turn the video's sound off" : "Play the video's sound";
      soundButton.hidden = !(this.source === "video" || this.source === "stream") || this.sound.present === false;
    };
    this.sound.onChange = showSound;
    const refresh = () => {
      extra.replaceChildren();
      if (this.source === "video") extra.append(el("button.button", { onclick: () => videoInput.click() }, this.videoURL ? "Other video…" : "Choose a video…"));
      if (this.source === "picture") extra.append(el("button.button", { onclick: () => photoInput.click() }, this.picture ? "Other photo…" : "Choose a photo…"));
      if (this.source === "stream") extra.append(el("input", { type: "url", placeholder: "https://…/video.mp4 or .m3u8", value: this.streamURL, style: { width: "260px" }, oninput: (e) => { this.streamURL = e.target.value; } }));
      if (this.source === "camera") extra.append(cameraSelect);
      if (this.source === "video" || this.source === "stream") extra.append(soundButton);
      showSound();
      // The credit tag shows only while a bundled sample is the source.
      const sampleShown = (this.source === "picture" && this.sampleFile && !this.sampleFile.endsWith(".mp4"))
        || (this.source === "video" && this.sampleFile?.endsWith(".mp4"));
      this.onSourceShown?.(sampleShown ? this.sampleFile : null);
    };
    // Which camera: the ones this computer or phone has, by name.
    const cameraSelect = el("select", { "aria-label": "Camera", style: { maxWidth: "240px" } });
    const fillCameras = async () => {
      const cameras = await listCameras();
      cameraSelect.replaceChildren(
        el("option", { value: "" }, "Default camera"),
        ...cameras.map((c, i) => el("option", { value: c.deviceId }, c.label || `Camera ${i + 1}`)));
      cameraSelect.hidden = cameras.length < 2;   // one camera: nothing to choose
      cameraSelect.value = cameras.some((c) => c.deviceId === this.cameraId) ? this.cameraId : "";
    };
    cameraSelect.onchange = () => { this.cameraId = cameraSelect.value; store.set("camera.device", this.cameraId); onChange(); };
    this.onCameraOpened = fillCameras;
    fillCameras();
    navigator.mediaDevices?.addEventListener?.("devicechange", fillCameras);
    select.onchange = () => { this.source = select.value; refresh(); onChange(); };
    this.showSource = () => { select.value = this.source; refresh(); };   // after useSample()
    refresh();
    return el("span.toolbar", { style: { margin: 0 } }, select, extra, videoInput, photoInput);
  }

  /** Uses a bundled sample (a picture, or one of Hailo's demo videos) as the source. */
  async useSample(file) {
    this.sampleFile = file;
    if (file.endsWith(".mp4")) {
      this.videoURL = await sampleVideoURL(file);
      this.source = "video";
    } else {
      this.picture = await loadImage(`samples/${file}`);
      this.source = "picture";
    }
    this.showSource?.();
    // While running, switch to it at once (as a chosen file does); a picture is read on each frame anyway.
    if (this.running && this.source !== "picture") await this.openSource().catch((e) => { this.message = e.message; this.running = false; });
  }
}
