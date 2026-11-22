// Artelico Web: the shell (sidebar, pages, status) and the shared state every page uses.
import { loadCatalog, Catalog } from "./core/catalog.js";
import { OnnxEngine, backend, settings } from "./core/engine.js";
import { ServerSource, FolderSource, defaultSource } from "./core/source.js";
import { store } from "./ui/common.js";

/** Shared state: the engine, where models come from, and which models are available. */
export const app = {
  engine: null,
  source: new ServerSource("models"),   // replaced in start() by defaultSource()
  available: new Set(),
  sizes: {},
  status: "Starting…",
  loadedModel: null,
  busy: false,
  listeners: new Set(),

  setStatus(text) { this.status = text; renderStatus(); },
  changed() { renderStatus(); for (const f of this.listeners) f(); },

  /** Every model that runs here. */
  canUse(name) { return this.available.has(name); },
  modelLabel(name) { return this.canUse(name) ? name : `${name} (not available)`; },

  async refreshAvailable() {
    const [names, wasmOnly] = await Promise.all([this.source.list(), this.source.wasmOnly()]);
    settings.wasmOnly = new Set(wasmOnly);
    this.available = new Set(names);
    // data/tddfa_bfm68.bin (Basel Face Model licence) is left out of the public Space and the public repository:
    // without it, the model that needs it is hidden.
    let haveBFM = document.documentElement.dataset.edition !== "space";
    if (haveBFM) { try { haveBFM = (await fetch("data/tddfa_bfm68.bin", { method: "HEAD" })).ok; } catch { haveBFM = false; } }
    if (!haveBFM) this.available.delete("tddfa_mobilenet_v1");
    if (this.source.kind === "server") {
      try { this.sizes = (await (await fetch(`${this.source.base}/index.json`)).json()).sizes ?? {}; } catch { this.sizes = {}; }
    }
    this.changed();
  },

  /**
   * True when `name` and its `extras` can run without downloading anything: loaded already, or in the browser's
   * cache (or the chosen models folder). Screens run on their own only then; otherwise they wait for Run, so a
   * download always starts from the user's click.
   */
  async isDownloaded(name, extras = []) { return (await this.notDownloaded(name, extras)).length === 0; },

  /** Which of `name` and its `extras` would have to be downloaded first. */
  async notDownloaded(name, extras = []) {
    const missing = [];
    for (const n of [name, ...extras]) {
      if (this.engine.loadedModelNames.includes(n)) continue;
      let here = false;
      try { here = !!(await this.source.cached?.(n)); } catch { /* not here */ }
      if (!here) missing.push(n);
    }
    return missing;
  },

  /** "Press Run to download yolov8s (45 MB)": what a screen shows instead of starting a download itself. */
  pressToDownload(button, names) {
    const total = names.reduce((sum, n) => sum + (this.sizes[n] ?? 0), 0);
    return `Press ${button} to download ${names.join(" + ")}${total ? ` (${mb(total)} MB)` : ""}. It is kept in this browser for next time.`;
  },

  /** Loads `name` (and `extras` next to it), with download progress in the status box. */
  async load(name, { extras = [], keep = false } = {}) {
    if (!keep) {
      const wanted = new Set([name, ...extras]);
      for (const loaded of this.engine.loadedModelNames) if (!wanted.has(loaded)) this.engine.unload(loaded);
    }
    for (const [index, n] of [name, ...extras].entries()) {
      const info = Catalog.model(n);
      if (!info) throw new Error(`Unknown model ${n}.`);
      if (!this.canUse(n)) throw new Error(`${n} is not in the models folder.`);
      if (this.engine.loadedModelNames.includes(n)) { if (index === 0) await this.engine.load(info); continue; }
      const size = this.sizes[n];
      this.setStatus(`Loading ${n}…`);
      await this.engine.load(info, {
        primary: index === 0,
        onProgress: (got, total) => this.setStatus(`Downloading ${n}: ${mb(got)} of ${mb(total || size || 0)} MB`),
      });
    }
    this.loadedModel = name;
    this.setStatus("Ready");
    this.changed();
  },

  async useFolder() {
    const handle = await window.showDirectoryPicker({ id: "artelico-models", mode: "read" });
    this.source = new FolderSource(handle);
    this.engine = new OnnxEngine(this.source);
    this.loadedModel = null;
    await this.refreshAvailable();
    this.setStatus(`Models from the folder “${handle.name}”`);
  },

  async useServer() {
    this.source = await defaultSource();
    this.engine = new OnnxEngine(this.source);
    this.loadedModel = null;
    await this.refreshAvailable();
    this.setStatus("Ready");
  },
};

export const mb = (bytes) => (bytes / 1e6).toFixed(0);
export const backendName = () => ({ webgpu: "WebGPU", wasm: "WebAssembly" })[backend.name] ?? (navigator.gpu ? "WebGPU" : "WebAssembly");

// MARK: Pages

const PAGES = [
  { group: "Vision", items: [
    { id: "photos", title: "Photos", icon: "🖼️", load: () => import("./ui/photos.js") },
    { id: "live", title: "Live", icon: "🎥", load: () => import("./ui/live.js") },
  ] },
  { group: "System", items: [
    { id: "models", title: "Models", icon: "🧩", load: () => import("./ui/models.js") },
  ] },
];

/** Pages added by other modules (examples, language) register here. */
export function addPages(group, items, before = "System") {
  const index = PAGES.findIndex((g) => g.group === before);
  const existing = PAGES.find((g) => g.group === group);
  if (existing) existing.items.push(...items); else PAGES.splice(index < 0 ? PAGES.length : index, 0, { group, items });
}

let current = null;

function renderNav() {
  const nav = document.getElementById("nav");
  nav.innerHTML = "";
  for (const g of PAGES) {
    const section = document.createElement("div");
    section.className = "nav-group";
    section.innerHTML = `<h3>${g.group}</h3>`;
    for (const item of g.items) {
      const b = document.createElement("button");
      b.className = "nav-item";
      b.dataset.page = item.id;
      b.innerHTML = `<span class="icon" aria-hidden="true">${item.icon}</span><span>${item.title}</span>`;
      b.onclick = () => { location.hash = item.id; document.getElementById("sidebar").classList.remove("open"); };
      section.append(b);
    }
    nav.append(section);
  }
}

function renderStatus() {
  const el = document.getElementById("status");
  if (!el) return;
  const where = app.source.kind === "folder" ? "models from a folder" : app.source.where;
  el.innerHTML = `<div><span class="dot"></span><b>In this browser</b> <span class="muted">· ${backendName()}</span></div>
    ${app.loadedModel ? `<div class="muted">📦 ${app.loadedModel}</div>` : ""}
    <div class="muted">${app.status === "Ready" ? `${app.available.size} ${where}` : app.status}</div>`;
}

async function show() {
  const id = location.hash.slice(1).split("?")[0] || "photos";
  const item = PAGES.flatMap((g) => g.items).find((i) => i.id === id) ?? PAGES[0].items[0];
  for (const b of document.querySelectorAll(".nav-item")) {
    if (b.dataset.page === item.id) b.setAttribute("aria-current", "page"); else b.removeAttribute("aria-current");
  }
  current?.unmount?.();
  const view = document.getElementById("view");
  view.innerHTML = "";
  document.getElementById("topbar-title").textContent = item.title;
  document.title = `${item.title} · Artelico Web`;
  const module = await item.load();
  current = module;
  module.mount(view, app);
}

async function start() {
  await loadCatalog();
  app.source = await defaultSource();
  app.engine = new OnnxEngine(app.source);
  // Pages from the examples and language modules, when present.
  await import("./ui/examples/index.js").catch((e) => console.error(e));
  // The Hugging Face Space build has no language pages (<html data-language="off">).
  if (document.documentElement.dataset.language !== "off") await import("./ui/language/index.js").catch((e) => console.error(e));
  renderNav();
  await app.refreshAvailable();
  app.setStatus("Ready");
  window.addEventListener("hashchange", show);
  document.getElementById("open-nav").onclick = () => document.getElementById("sidebar").classList.add("open");
  document.getElementById("close-nav").onclick = () => document.getElementById("sidebar").classList.remove("open");
  await show();
}

// The welcome page (index.html): "Open Artelico" leaves it for good; "About Artelico" in the sidebar brings it back.
for (const b of document.querySelectorAll("[data-enter]")) {
  b.onclick = () => {
    store.set("welcomed", "1");
    delete document.documentElement.dataset.welcome;
    scrollTo(0, 0);
  };
}
document.querySelector("[data-welcome-again]")?.addEventListener("click", (e) => {
  e.preventDefault();
  document.documentElement.dataset.welcome = "";
  document.getElementById("sidebar").classList.remove("open");
  scrollTo(0, 0);
});

start().catch((error) => {
  document.getElementById("view").innerHTML = `<h1>Artelico Web</h1><p class="error">Could not start: ${error.message ?? error}</p>`;
});

export { Catalog };
