// Shared pieces of the example screens: sound, the screen frame (source, model, start, picture, panel)
// and the pose runner (port of the apps' PoseKit.swift).
import { el, modelsFor, store, sizeCanvas } from "../common.js";
import { FrameRunner } from "../runner.js";
import { creditTag } from "../credits.js";
import { run, companionsFor } from "../../core/pipeline.js";
import { Catalog } from "../../core/catalog.js";
import { ObjectTracker } from "../../core/tracker.js";
import { drawPoses } from "../../core/render.js";
import { FaceRecognition } from "../../core/pipelines.js";
import { HandReader, HandSmoother } from "../../rules/hand-games.js";

// MARK: Sound (Web Audio)

export const Tone = {
  ctx: null,
  get audio() { this.ctx ??= new (window.AudioContext || window.webkitAudioContext)(); if (this.ctx.state === "suspended") this.ctx.resume(); return this.ctx; },
  /** A short tone; `bright` adds harmonics. */
  play(freq, seconds = 0.25, { bright = false, volume = 0.3, type = "sine" } = {}) {
    try {
      const a = this.audio, t = a.currentTime, gain = a.createGain();
      gain.gain.setValueAtTime(0, t); gain.gain.linearRampToValueAtTime(volume, t + 0.01); gain.gain.exponentialRampToValueAtTime(0.001, t + seconds);
      gain.connect(a.destination);
      for (const [mult, level] of bright ? [[1, 1], [2, 0.4], [3, 0.2]] : [[1, 1]]) {
        const o = a.createOscillator(), g = a.createGain();
        o.type = type; o.frequency.value = freq * mult; g.gain.value = level;
        o.connect(g).connect(gain); o.start(t); o.stop(t + seconds + 0.05);
      }
    } catch { /* no audio */ }
  },
  chime() { [880, 1320, 1760].forEach((f, i) => setTimeout(() => this.play(f, 0.35, { bright: true, volume: 0.2 }), i * 110)); },
  piano(freq) { this.play(freq, 0.9, { bright: true, volume: 0.25, type: "triangle" }); },
  pluck(freq) {
    // Karplus-Strong string.
    try {
      const a = this.audio, n = Math.round(a.sampleRate / freq), len = Math.round(a.sampleRate * 1.2), buf = a.createBuffer(1, len, a.sampleRate), d = buf.getChannelData(0);
      const ring = Float32Array.from({ length: n }, () => Math.random() * 2 - 1);
      for (let i = 0; i < len; i++) { const j = i % n, next = (j + 1) % n; d[i] = ring[j]; ring[j] = 0.996 * 0.5 * (ring[j] + ring[next]); }
      const s = a.createBufferSource(), g = a.createGain(); g.gain.value = 0.35; s.buffer = buf; s.connect(g).connect(a.destination); s.start();
    } catch { /* no audio */ }
  },
  drum(kind) {
    try {
      const a = this.audio, t = a.currentTime;
      if (kind === "kick") { const o = a.createOscillator(), g = a.createGain(); o.frequency.setValueAtTime(150, t); o.frequency.exponentialRampToValueAtTime(40, t + 0.25); g.gain.setValueAtTime(0.8, t); g.gain.exponentialRampToValueAtTime(0.001, t + 0.3); o.connect(g).connect(a.destination); o.start(t); o.stop(t + 0.3); return; }
      const len = Math.round(a.sampleRate * (kind === "hihat" ? 0.06 : 0.18)), buf = a.createBuffer(1, len, a.sampleRate), d = buf.getChannelData(0);
      for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * (1 - i / len);
      const s = a.createBufferSource(), f = a.createBiquadFilter(), g = a.createGain();
      f.type = kind === "hihat" ? "highpass" : "bandpass"; f.frequency.value = kind === "hihat" ? 7000 : 1800; g.gain.value = 0.5;
      s.buffer = buf; s.connect(f).connect(g).connect(a.destination); s.start(t);
    } catch { /* no audio */ }
  },
  alarm() { [0, 0.25, 0.5].forEach((d) => setTimeout(() => this.play(1046, 0.18, { bright: true, volume: 0.35, type: "square" }), d * 1000)); },
};

// MARK: The screen frame

/**
 * Builds an example screen and its runner.
 *  options: title, intro, task ("pose" | "detection" | "face"), sources, samples [[title, file]], panelWidth,
 *  extras(): models loaded next to the main one, analyse(canvas, engine, time) (default: the task + tracking),
 *  onFrame(frame), draw(ctx, W, H, frame), placeholder, modelKey, onStop(message),
 *  shown(frame): the picture to show (default frame.image; the privacy camera shows only its cleaned copy,
 *  and nothing when there is none).
 * Returns { runner, panel, stage, start(), redraw() }.
 */
export function exampleScreen(view, app, o) {
  const task = o.task ?? "pose";
  const tracker = new ObjectTracker();
  const models = el("select", { "aria-label": "Model", onchange: () => store.set(`${o.modelKey ?? o.title}.model`, models.value) });
  for (const m of o.models ?? modelsFor(task, app)) models.append(el("option", { value: m.name, disabled: !app.canUse(m.name) }, app.modelLabel(m.name)));
  const saved = store.get(`${o.modelKey ?? o.title}.model`);
  if (saved && app.canUse(saved)) models.value = saved;
  const fps = el("b.small");
  const message = el("span.error.small");
  const canvas = el("canvas");
  const placeholder = el("div.placeholder", {}, o.placeholder ?? "Choose a source and press Start.");
  const credit = creditTag();
  const stage = el("div.stage", {}, placeholder, canvas, credit);
  const panel = el("div.panel");
  let last = null;

  const runner = new FrameRunner(app, {
    task, sources: o.sources ?? ["front", "back", "video", "picture"],
    extras: () => [...companionsFor(task, Catalog.model(models.value)), ...(o.extras?.() ?? [])],
    analyse: o.analyse ?? (async (image, engine, time) => {
      const { result, timing, frame } = await run(task, image, engine);
      return { result: o.track === false ? result : tracker.track(result, time), prepared: frame, inferenceMs: timing.inference };
    }),
    onFrame: async (f) => {
      last = f;
      placeholder.hidden = true; canvas.hidden = false;
      await o.onFrame?.(f);
      redraw();
      fps.textContent = `${runner.fps.toFixed(0)} FPS`;
    },
    onStop: (text) => { button.textContent = "Start"; button.className = "button primary"; message.textContent = text ?? ""; fps.textContent = ""; o.onStop?.(text); },
  });

  function redraw() {
    if (!last) return;
    const picture = o.shown ? o.shown(last) : last.image;
    if (!picture) { canvas.hidden = true; return; }
    const ctx = sizeCanvas(canvas, last.width, last.height, 1280);
    ctx.drawImage(picture, 0, 0, canvas.width, canvas.height);
    o.draw?.(ctx, canvas.width, canvas.height, last);
  }

  const button = el("button.button.primary", { onclick: () => (runner.running ? runner.stop() : start()) }, "Start");
  async function start() {
    message.className = "error small"; message.textContent = "";
    tracker.reset();
    try {
      button.textContent = "Stop"; button.className = "button danger";
      await o.beforeStart?.();
      await runner.start(models.value);
    } catch (error) {
      message.textContent = error.message ?? String(error);
      button.textContent = "Start"; button.className = "button primary";
      app.setStatus("Ready");
    }
  }
  const samples = o.samples?.length
    ? el("select", { "aria-label": "Samples", onchange: async () => {
        if (!samples.value) return;
        const wasRunning = runner.running;
        await runner.useSample(samples.value);
        samples.value = "";
        if (wasRunning) { runner.stop(); while (runner.running) await new Promise((r) => setTimeout(r, 20)); start(); return; }
        // Starts by itself only when the models are already here; a download waits for Start.
        const missing = await app.notDownloaded(models.value, runner.extras());
        if (!missing.length) start(); else { message.className = "small muted"; message.textContent = app.pressToDownload("Start", missing); }
      } }, el("option", { value: "" }, "Samples…"), o.samples.map(([t, f]) => el("option", { value: f }, t)))
    : null;
  runner.onSourceShown = credit.show;
  const sourceBox = runner.controls();
  if (o.sources?.[0] === "picture") runner.source = "picture";

  view.append(...[
    el("h1", {}, o.title),
    o.intro ? el("p.muted", { style: { marginTop: "-6px" } }, o.intro) : null,
    el("div.toolbar", {}, sourceBox, samples, models, button, fps, message),
    el("div.layout", { style: o.panelWidth ? { gridTemplateColumns: `minmax(0, 1fr) ${o.panelWidth}px` } : undefined }, stage, panel),
  ].filter(Boolean));
  canvas.hidden = true;
  view.addEventListener("detach", () => runner.stop());
  if (new URLSearchParams(location.hash.split("?")[1]).has("autostart") && o.samples?.length) {
    runner.useSample(o.samples[0][1]).then(() => start());
  }
  return { runner, panel, stage, canvas, start, redraw, get last() { return last; }, tracker };
}

/** Pose models first (the examples are built on yolov8 pose). */
// The small models first: the screens run every frame (and hands add a model per hand), so a medium model
// on a phone or without WebGPU drops them to a few frames a second. yolov8s_pose is the native apps' default.
const FAST_POSE = ["yolov8s_pose", "yolo26n_pose", "yolo26s_pose"];
export const poseModels = (app) => {
  const all = modelsFor("pose", app), rank = (m) => (FAST_POSE.includes(m.name) ? FAST_POSE.indexOf(m.name) : FAST_POSE.length);
  return [...all].sort((a, b) => rank(a) - rank(b));
};

/** Analysis for pose screens: poses (tracked and steadied), plus optionally objects from `detector` and hands. */
export function poseAnalysis(o = {}) {
  const tracker = new ObjectTracker(), handSmoother = new HandSmoother();
  return async (image, engine, time) => {
    const t0 = performance.now();
    const { result } = await run("pose", image, engine);
    const poses = tracker.track(result, time).value;   // numbered and steadied (masks are not tracked here)
    const ms = performance.now() - t0;
    let objects = [];
    const detector = o.detector?.();
    if (detector && engine.loadedModelNames.includes(detector)) {
      const primary = engine.primary;
      engine.primary = detector;
      try { objects = (await run("detection", image, engine)).result.value; } finally { engine.primary = primary; }
    }
    const hands = o.hands ? await HandReader.read(image, poses, engine, 4, handSmoother, performance.now() / 1000) : [];
    return { poses, objects, hands, inferenceMs: ms };
  };
}

/** Analysis for face screens: faces with embeddings. */
export function faceAnalysis() {
  return async (image, engine) => ({ people: await FaceRecognition.describe(image, engine) });
}

export { drawPoses };
