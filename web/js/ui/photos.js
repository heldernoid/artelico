// Photos: one picture through a model, with the result drawn over it.
import { el, SAMPLES, loadImage, imageFromFile, modelSelect, taskOptions, sizeCanvas, fmtMs, store, promptField } from "./common.js";
import { run, companionsFor } from "../core/pipeline.js";
import { Catalog } from "../core/catalog.js";
import { ReIdentification } from "../core/crop-tasks.js";
import { drawResult, summary } from "../core/render.js";
import { sourceSize } from "../core/prep.js";
import { backendName } from "../app.js";
import { creditTag } from "./credits.js";

let picture = null;

export function mount(view, app) {
  const tasks = taskOptions(app);
  let task = store.get("photos.task", "detection");
  if (!tasks.some(([t]) => t === task)) task = tasks[0]?.[0] ?? "detection";

  const taskSelect = el("select", { "aria-label": "Task", onchange: () => { task = taskSelect.value; store.set("photos.task", task); models.dataset.task = task; models.refill(task); showTaskNote(); runIfHere(); } },
    tasks.map(([t, info]) => el("option", { value: t, selected: t === task }, info.title)));
  const models = modelSelect(task, app, "photos.model");
  models.addEventListener("change", () => runIfHere());
  models.dataset.task = task;
  const file = el("input", { type: "file", accept: "image/*", hidden: true, onchange: async () => { if (file.files[0]) { setPicture(await imageFromFile(file.files[0])); credit.show(null); } } });
  const credit = creditTag();
  const samples = el("select", { "aria-label": "Sample picture", onchange: async () => { const f = samples.value; if (f) { setPicture(await loadImage(`samples/${f}`)); credit.show(f); } samples.value = ""; } },
    el("option", { value: "" }, "Samples…"), SAMPLES.map(([title, f]) => el("option", { value: f }, title)));
  const runButton = el("button.button.primary", { onclick: () => go() }, "Run");
  const canvas = el("canvas");
  const placeholder = el("div.placeholder", {}, "Choose a picture, a sample, or drop one here.");
  const stage = el("div.stage", {}, placeholder, canvas, credit);
  const result = el("div");
  // Re-identification numbers people across pictures (and Live) until asked to start again.
  const recount = el("button.button", { onclick: () => { ReIdentification.reset(); go(); } }, "Count from 1 again");
  const taskNote = el("p.small.muted");
  const prompts = promptField(() => go());
  const showTaskNote = () => {
    recount.style.display = task === "person_re_id" ? "" : "none";   // .button sets display, so not `hidden`
    prompts.style.display = task === "clip" ? "" : "none";
    taskNote.textContent = task === "video_classification" ? "One photo is the same frame 16 times: no motion, so the action is a guess from the scene. Live gives the model real clips." : "";
  };
  const timing = el("p.small.muted");

  view.append(
    el("h1", {}, "Photos"),
    el("div.toolbar", {}, taskSelect, models, el("button.button", { onclick: () => file.click() }, "Choose a picture…"), file, samples, runButton),
    el("div.toolbar", {}, prompts),
    el("div.layout", {}, stage, el("div.panel", {}, el("h2", { style: { marginTop: 0 } }, "Result"), result, timing, taskNote, recount,
      el("p.small.muted", {}, "The picture never leaves this browser.")))
  );
  showTaskNote();

  stage.ondragover = (e) => { e.preventDefault(); stage.classList.add("drop"); };
  stage.ondragleave = () => stage.classList.remove("drop");
  stage.ondrop = async (e) => { e.preventDefault(); stage.classList.remove("drop"); const f = e.dataTransfer.files[0]; if (f) { setPicture(await imageFromFile(f)); credit.show(null); } };

  function draw(res) {
    if (!picture) { canvas.hidden = true; placeholder.hidden = false; return; }
    canvas.hidden = false; placeholder.hidden = true;
    const { width, height } = sourceSize(picture);
    if (res?.kind === "image" && res.value) {
      const ctx = sizeCanvas(canvas, res.value.width, res.value.height, 2400);
      const img = new ImageData(res.value.rgba, res.value.width, res.value.height);
      const c = new OffscreenCanvas(img.width, img.height); c.getContext("2d").putImageData(img, 0, 0);
      ctx.drawImage(c, 0, 0, canvas.width, canvas.height);
      return;
    }
    const ctx = sizeCanvas(canvas, width, height);
    ctx.drawImage(picture, 0, 0, canvas.width, canvas.height);
    if (res) drawResult(ctx, res, canvas.width, canvas.height);
  }

  // A new picture (or another model or task) runs at once only when the model is already here; otherwise it says
  // what Run would download, and waits.
  async function setPicture(p) {
    picture = p; result.textContent = ""; timing.textContent = ""; draw(null);
    await runIfHere();
  }
  async function runIfHere() {
    if (!picture || !models.value || app.busy) return;
    const chosen = models.value;
    const missing = await app.notDownloaded(chosen, companionsFor(task, Catalog.model(chosen)));
    if (chosen !== models.value) return;   // changed again meanwhile
    if (!missing.length) { go(); return; }
    draw(null); timing.textContent = "";
    result.textContent = app.pressToDownload("Run", missing);
  }

  async function go() {
    if (!picture) { result.textContent = "Choose a picture or a sample first."; return; }
    if (app.busy) return;
    app.busy = true; runButton.disabled = true;
    result.textContent = "Working…";
    try {
      await app.load(models.value, { extras: companionsFor(task, Catalog.model(models.value)) });
      const { result: res, timing: t } = await run(task, picture, app.engine, { gallery: task === "person_re_id" ? ReIdentification.session(app.engine.loadedModel) : undefined, prompts: prompts.value });
      draw(res);
      result.innerHTML = "";
      if (res.kind === "classifications") {
        result.append(el("ul.list", {}, res.value.map((c) => el("li", {}, el("span.grow", {}, c.label),
          el("span", { style: { width: "90px" } }, el("div.bar", {}, el("span", { style: { width: `${c.probability * 100}%` } }))),
          el("span.small", { style: { width: "52px", textAlign: "right" } }, `${(c.probability * 100).toFixed(1)}%`)))));
      } else {
        result.append(el("p", {}, summary(res)));
      }
      timing.textContent = `${models.value} on ${backendName()}: model ${fmtMs(t.inference)}, preparing ${fmtMs(t.prepare)}, decoding ${fmtMs(t.decode)}`;
    } catch (error) {
      result.innerHTML = "";
      result.append(el("p.error", {}, error.message ?? String(error)));
      app.setStatus("Ready");
    } finally {
      app.busy = false; runButton.disabled = false;
    }
  }

  draw(null);
  if (picture) go();
  else loadImage("samples/bus.jpg").then((img) => { setPicture(img); credit.show("bus.jpg"); });
}

export function unmount() {}
