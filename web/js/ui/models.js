// Models: where they come from, which are kept in this browser, and what this computer runs them on.
import { el } from "./common.js";
import { Catalog } from "../core/catalog.js";
import { backendName, mb } from "../app.js";
import { HAILO_CREDIT } from "./credits.js";
import { PAIRS, pairForText } from "../core/clip.js";

let stop = false;

export function mount(view, app) {
  stop = false;
  const filter = el("input", { type: "text", placeholder: "Filter by name or task", "aria-label": "Filter", oninput: () => fill() });
  const body = el("tbody");
  const where = el("p.small");
  const gpu = el("p.small.muted");
  const usage = el("p.small.muted");

  view.append(
    el("h1", {}, "Models"),
    el("div.panel", {},
      el("h2", { style: { marginTop: 0 } }, "Where the models come from"), where,
      // The Hugging Face Space (<html data-edition="space">) always uses the model repository.
      document.documentElement.dataset.edition === "space" ? null : el("div.toolbar", {},
        el("button.button", { onclick: () => app.useServer().then(fill) }, "Online models (this site or Hugging Face)"),
        "showDirectoryPicker" in window
          ? el("button.button", { onclick: () => app.useFolder().then(fill).catch((e) => { if (e.name !== "AbortError") alert(e.message); }) }, "A folder on this computer…")
          : el("span.small.muted", {}, "Choosing a folder needs Chrome or Edge.")),
      gpu, usage,
      el("p.small.muted", {}, "The models are the networks of the ", el("a", { href: "https://github.com/hailo-ai/hailo_model_zoo", target: "_blank", rel: "noopener" }, "Hailo Model Zoo"),
        ", each under its own licence (", el("a", { href: "https://huggingface.co/helmo/artelico-models", target: "_blank", rel: "noopener" }, "model list"), "). ", HAILO_CREDIT)),
    el("div.toolbar", { style: { marginTop: "16px" } }, filter),
    el("div.panel", {}, el("table.model-table", {}, el("thead", {}, el("tr", {}, el("th", {}, "Model"), el("th", {}, "Tasks"), el("th", {}, ""))), body))
  );

  async function describe() {
    where.textContent = app.source.kind === "folder"
      ? `A folder on this computer: ${app.available.size} models. Nothing is downloaded.`
      : `This site’s models folder: ${app.available.size} models. A model downloads the first time it is used and is then kept in this browser.`;
    let adapter = "";
    try { const a = await navigator.gpu?.requestAdapter(); adapter = a?.info ? [a.info.vendor, a.info.architecture, a.info.description].filter(Boolean).join(" ") : ""; } catch { /* no WebGPU */ }
    gpu.textContent = navigator.gpu ? `Runs on the graphics chip with WebGPU${adapter ? ` (${adapter})` : ""}; models WebGPU cannot run use WebAssembly.` : "This browser has no WebGPU: models run on the processor with WebAssembly (slower).";
    if (navigator.storage?.estimate) {
      const { usage: u = 0, quota = 0 } = await navigator.storage.estimate();
      usage.textContent = `This site uses ${mb(u)} MB of the ${mb(quota)} MB the browser allows it.`;
    }
    void backendName;
  }

  async function fill() {
    describe();
    const q = filter.value.trim().toLowerCase();
    body.innerHTML = "";
    const rows = Catalog.all.filter((m) => app.canUse(m.name) && (!q || m.name.includes(q) || m.tasks.some((t) => t.includes(q)) || (m.taskPage ?? "").includes(q)));
    for (const m of rows) {
      const size = app.sizes[m.name];
      const state = el("span.pill", {}, "…");
      const action = el("span");
      body.append(el("tr", {}, el("td", {}, el("b", {}, m.name), size ? el("div.small.muted", {}, `${mb(size)} MB`) : null),
        el("td.small", {}, pairForText(m.name) ? `helper: used by tagging from text with ${PAIRS.filter((p) => p.text === m.name).map((p) => p.image).join(", ")}`
          : (m.tasks.length ? m.tasks : [m.taskPage ?? ""]).join(", ")), el("td", {}, state, " ", action)));
      if (stop) return;
      app.source.cached(m.name).then((kept) => {
        if (app.source.kind === "folder") { state.textContent = "on this computer"; state.classList.add("ok"); return; }
        state.textContent = kept ? "kept in this browser" : "downloads when used";
        if (kept) state.classList.add("ok");
        action.replaceChildren(kept
          ? el("button.button", { onclick: async () => { await app.source.forget(m.name); fill(); } }, "Remove")
          : el("button.button", { onclick: async (e) => {
              e.target.disabled = true;
              await app.source.fetch(m.name, "onnx", (got, total) => { e.target.textContent = `${mb(got)} / ${mb(total || size || 0)} MB`; });
              fill();
            } }, "Keep offline"));
      });
    }
    if (!rows.length) body.append(el("tr", {}, el("td", { colspan: 3 }, el("span.muted", {}, "No models."))));
  }

  fill();
}

export function unmount() { stop = true; }
