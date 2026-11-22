// Small helpers shared by the pages.
import { Catalog } from "../core/catalog.js";
import { supports, catalogTasks, TASKS } from "../core/pipeline.js";
import { DEFAULT_PROMPTS } from "../core/clip.js";

/** el("div.panel", { onclick }, child, "text", ...) */
export function el(spec, props = {}, ...children) {
  const [tag, ...classes] = spec.split(".");
  const node = document.createElement(tag || "div");
  if (classes.length) node.className = classes.join(" ");
  for (const [k, v] of Object.entries(props ?? {})) {
    if (v === undefined || v === null || v === false) continue;
    if (k.startsWith("on")) node[k] = v;
    else if (k === "html") node.innerHTML = v;
    else if (k === "style" && typeof v === "object") Object.assign(node.style, v);
    else if (k in node && typeof v !== "string") node[k] = v;
    else node.setAttribute(k, v === true ? "" : v);
  }
  for (const c of children.flat()) if (c !== null && c !== undefined && c !== false) node.append(c instanceof Node ? c : document.createTextNode(String(c)));
  return node;
}

export const SAMPLES = [
  ["Street with a bus", "bus.jpg"], ["Dog and bicycle", "dog_bicycle.jpg"], ["Apples", "apple.jpg"], ["Dark room", "room.png"],
  ["Car plate", "plate_sample.png"], ["Thumbs up", "thumbs_up.jpg"], ["Road lanes", "lane.png"], ["Aerial view", "dota_image.png"],
  ["Text", "ocr_img1.png"], ["Small picture", "input_image.png"],
];

export function loadImage(url) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    // CORS mode: hosts like Hugging Face Spaces redirect pictures to a file CDN, and the page's
    // cross-origin isolation only lets such a picture in when it is fetched with CORS.
    img.crossOrigin = "anonymous";
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error(`Cannot read ${url}`));
    img.src = url;
  });
}

/** A picture from a File (upright: createImageBitmap applies the photo's orientation). */
export async function imageFromFile(file) {
  return createImageBitmap(file, { imageOrientation: "from-image" });
}

/** Models for a task that can be decoded and are available here (the Hailo-only ones never show). */
export function modelsFor(task, app) {
  return Catalog.forTask(catalogTasks(task)).filter((m) => supports(task, m) && app.canUse(m.name));
}

export function taskOptions(app) {
  return Object.entries(TASKS).filter(([task]) => modelsFor(task, app).some((m) => app.canUse(m.name)));
}

/** A <select> of models for `task`, remembering the choice per task in localStorage. */
export function modelSelect(task, app, key = "model") {
  const select = el("select", { "aria-label": "Model" });
  const fill = (t) => {
    select.innerHTML = "";
    for (const m of modelsFor(t, app)) select.append(el("option", { value: m.name, disabled: !app.canUse(m.name) }, app.modelLabel(m.name)));
    const saved = store.get(`${key}.${t}`);
    if (saved && app.canUse(saved)) select.value = saved;
  };
  fill(task);
  select.refill = fill;
  select.addEventListener("change", () => store.set(`${key}.${select.dataset.task ?? task}`, select.value));
  return select;
}

/** The prompts box of tagging from text (shared by Photos and Live, remembered). */
export function promptField(onchange) {
  const input = el("input.prompts", { type: "text", value: store.get("clip.prompts", DEFAULT_PROMPTS), "aria-label": "Things to look for",
    placeholder: "Things to look for, separated by commas; start with - for “not this”",
    title: "Things to look for, separated by commas; start with - for “not this”",
    onchange: () => { store.set("clip.prompts", input.value); onchange?.(); } });
  input.style.minWidth = "260px";
  input.style.flex = "1 1 260px";
  return input;
}

/** localStorage that never throws (private windows, blocked storage). */
export const store = {
  get(k, fallback = null) { try { const v = localStorage.getItem(`artelico.${k}`); return v === null ? fallback : v; } catch { return fallback; } },
  set(k, v) { try { localStorage.setItem(`artelico.${k}`, v); } catch { /* not kept */ } },
  json(k, fallback) { try { return JSON.parse(this.get(k)) ?? fallback; } catch { return fallback; } },
  setJSON(k, v) { this.set(k, JSON.stringify(v)); },
};

/** Fits a canvas to a picture size, at most `maxWidth` wide (device pixels kept sharp). */
export function sizeCanvas(canvas, width, height, maxSide = 1600) {
  const scale = Math.min(1, maxSide / Math.max(width, height));
  canvas.width = Math.round(width * scale);
  canvas.height = Math.round(height * scale);
  return canvas.getContext("2d");
}

export const fmtMs = (ms) => `${ms < 10 ? ms.toFixed(1) : Math.round(ms)} ms`;
