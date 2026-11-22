// Live: the camera (or a video) through a model, frame after frame.
import { el, modelSelect, taskOptions, sizeCanvas, fmtMs, store, SAMPLES, promptField } from "./common.js";
import { companionsFor } from "../core/pipeline.js";
import { Catalog } from "../core/catalog.js";
import { drawResult, summary } from "../core/render.js";
import { FrameRunner } from "./runner.js";
import { VIDEOS } from "./hailo-videos.js";
import { creditTag } from "./credits.js";

let runner = null;

export function mount(view, app) {
  const tasks = taskOptions(app).filter(([t]) => t !== "super_resolution");
  let task = store.get("live.task", "detection");
  if (!tasks.some(([t]) => t === task)) task = tasks[0]?.[0] ?? "detection";
  const canvas = el("canvas");
  const placeholder = el("div.placeholder", {}, "Choose a source and press Start.");
  const fps = el("b");
  const info = el("p");
  const timing = el("p.small.muted");
  const message = el("p.error");

  const prompts = promptField();
  const showPrompts = () => { prompts.style.display = runner.task === "clip" ? "" : "none"; };
  runner = new FrameRunner(app, {
    task, sources: ["front", "back", "video", "stream", "picture"],
    prompts: () => prompts.value,
    extras: () => companionsFor(runner.task, Catalog.model(models.value)),
    onFrame: (f) => {
      placeholder.hidden = true; canvas.hidden = false;
      const ctx = sizeCanvas(canvas, f.width, f.height, 1280);
      ctx.drawImage(f.image, 0, 0, canvas.width, canvas.height);
      drawResult(ctx, f.result, canvas.width, canvas.height);
      fps.textContent = `${runner.fps.toFixed(0)} FPS`;
      info.textContent = summary(f.result);
      timing.textContent = `model ${fmtMs(f.inferenceMs)} per frame`;
    },
    onStop: (text) => { startButton.textContent = "Start"; startButton.className = "button primary"; message.textContent = text ?? ""; fps.textContent = ""; },
  });

  const taskSelect = el("select", { "aria-label": "Task", onchange: () => { runner.task = taskSelect.value; store.set("live.task", runner.task); models.dataset.task = runner.task; models.refill(runner.task); showPrompts(); } },
    tasks.map(([t, i]) => el("option", { value: t, selected: t === task }, i.title)));
  const models = modelSelect(task, app, "live.model");
  models.dataset.task = task;
  const startButton = el("button.button.primary", { onclick: async () => {
    if (runner.running) { runner.stop(); return; }
    message.textContent = "";
    try {
      startButton.textContent = "Stop"; startButton.className = "button danger";
      await runner.start(models.value);
    } catch (error) {
      message.textContent = error.message ?? String(error);
      startButton.textContent = "Start"; startButton.className = "button primary";
      app.setStatus("Ready");
    }
  } }, "Start");
  const samples = el("select", { "aria-label": "Sample", onchange: async () => { if (samples.value) await runner.useSample(samples.value); samples.value = ""; } },
    el("option", { value: "" }, "Samples…"), [...SAMPLES, ...Object.values(VIDEOS)].map(([t, f]) => el("option", { value: f }, t)));

  const credit = creditTag();
  runner.onSourceShown = credit.show;
  view.append(
    el("h1", {}, "Live"),
    el("div.toolbar", {}, runner.controls(), samples, taskSelect, models, startButton, fps),
    el("div.toolbar", {}, prompts),
    el("div.layout", {}, el("div.stage", {}, placeholder, canvas, credit), el("div.panel", {}, el("h2", { style: { marginTop: 0 } }, "Now"), info, timing, message,
      el("p.small.muted", {}, "Camera pictures stay in this browser; nothing is uploaded.")))
  );
  canvas.hidden = true;
  showPrompts();
  if (new URLSearchParams(location.hash.split("?")[1]).has("autostart")) runner.useSample("bus.jpg").then(() => startButton.click());
}

export function unmount() { runner?.stop(); runner = null; }
