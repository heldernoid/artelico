// Language pages (Chat, Ask an image, Speech to text) and the "Ask the models" demos (UGen300 V2 Outfit
// advisor, V3 Fridge chef, Calories, Face report, OfflineCode, WQ1 Meeting notes). Models from core/language.js.
import { el, store, loadImage, imageFromFile } from "../common.js";
import { Language, LANGUAGE_MODELS, modelsFor, Speech, WHISPER_MODELS, audioSamples, recordMicrophone, languageName } from "../../core/language.js";
import { SPEECH_SAMPLES } from "../credits.js";
import { Nutrition, DailyLog, CodeBlocks, MeetingNotes } from "../../rules/language-games.js";

// MARK: Shared parts

/** A model <select> for one use, remembering the choice; marks the ones already downloaded. */
function modelPicker(use, key) {
  const list = modelsFor(use), select = el("select", { "aria-label": "Model", onchange: () => store.set(`lm.${key}`, select.value) });
  for (const m of list) select.append(el("option", { value: m.id }, `${m.title} (${m.mb} MB to download)`));
  const saved = store.get(`lm.${key}`);
  if (saved && list.some((m) => m.id === saved)) select.value = saved;
  list.forEach((m, i) => Language.isDownloaded(m.id).then((d) => { if (d) select.options[i].textContent = m.title; }));
  return select;
}

/** Light Markdown: **bold**, `code`, line breaks (text is escaped first). */
function markdown(text) {
  const esc = text.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]);
  return esc.replace(/\*\*(.+?)\*\*/g, "<b>$1</b>").replace(/`([^`\n]+)`/g, "<code>$1</code>").replace(/\n/g, "<br>");
}

function answerBox(placeholder = "The answer appears here.") {
  const body = el("div", { style: { minHeight: "160px", whiteSpace: "normal" } }, el("span.muted", {}, placeholder));
  const copy = el("button.button", { hidden: true, onclick: () => navigator.clipboard?.writeText(box.text) }, "Copy");
  const box = el("div.panel", { style: { background: "var(--panel-2)" } }, body, el("div", { style: { textAlign: "right" } }, copy));
  box.text = "";
  box.set = (text, working = false) => { box.text = text; body.innerHTML = text ? markdown(text) : `<span class="muted">${working ? "Working… (the first answer also downloads and loads the model)" : placeholder}</span>`; copy.hidden = !text || working; };
  return box;
}

const progressLine = () => el("p.small.muted");
const SAMPLES = [["Apples", "apple.jpg"], ["Street", "bus.jpg"], ["Dog and bicycle", "dog_bicycle.jpg"], ["Thumbs up", "thumbs_up.jpg"]];

/** Camera with a self-timer, a photo, or a sample. `onPicture(canvas)`. */
function pictureSource({ front = true, timer = 3, onPicture }) {
  const video = el("video", { playsInline: true, muted: true, style: { width: "100%", borderRadius: "14px", display: "none" } });
  const preview = el("canvas", { style: { width: "100%", borderRadius: "14px", display: "none" } });
  const count = el("div", { style: { position: "absolute", inset: 0, display: "grid", placeItems: "center", fontSize: "110px", fontWeight: 900, color: "#fff", textShadow: "0 0 20px #000", pointerEvents: "none" } });
  const empty = el("div.placeholder", {}, "Use the camera or choose a photo.");
  const stage = el("div.stage", { style: { minHeight: "280px" } }, empty, video, preview, count);
  let stream = null, facing = front;
  const show = (img) => {
    preview.width = img.width; preview.height = img.height; preview.getContext("2d").drawImage(img, 0, 0);
    preview.style.display = "block"; video.style.display = "none"; empty.hidden = true; onPicture(preview);
  };
  const stopCamera = () => { stream?.getTracks().forEach((t) => t.stop()); stream = null; video.style.display = "none"; camera.textContent = "Camera"; shoot.hidden = true; };
  const camera = el("button.button", { onclick: async () => {
    if (stream) { stopCamera(); return; }
    try {
      stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: facing ? "user" : "environment" } });
      video.srcObject = stream; await video.play();
      video.style.display = "block"; preview.style.display = "none"; empty.hidden = true; camera.textContent = "Cancel"; shoot.hidden = false;
    } catch (error) { empty.textContent = `Camera: ${error.message}`; }
  } }, "Camera");
  const shoot = el("button.button.primary", { hidden: true, onclick: async () => {
    for (let n = timer; n > 0; n--) { count.textContent = n; await new Promise((r) => setTimeout(r, 1000)); }
    count.textContent = "";
    const c = Object.assign(document.createElement("canvas"), { width: video.videoWidth, height: video.videoHeight }), ctx = c.getContext("2d");
    if (facing) { ctx.translate(c.width, 0); ctx.scale(-1, 1); }
    ctx.drawImage(video, 0, 0);
    stopCamera(); show(c);
  } }, `Take picture (${timer} s)`);
  const flip = el("button.button", { onclick: () => { facing = !facing; if (stream) { stopCamera(); camera.click(); } } }, "⟲");
  const file = el("input", { type: "file", accept: "image/*", hidden: true, onchange: async () => { if (file.files[0]) show(await imageFromFile(file.files[0])); } });
  const samples = el("select", { "aria-label": "Samples", onchange: async () => { if (samples.value) show(await loadImage(`samples/${samples.value}`)); samples.value = ""; } },
    el("option", { value: "" }, "Samples…"), SAMPLES.map(([t, f]) => el("option", { value: f }, t)));
  const node = el("div", {}, stage, el("div.toolbar", { style: { marginTop: "8px" } }, camera, shoot, flip, el("button.button", { onclick: () => file.click() }, "Photo…"), file, samples));
  node.addEventListener("detach", stopCamera);
  node.stop = stopCamera;
  return node;
}

/** Runs a streamed question with Stop. Returns a controller { ask(options), stop() }. */
function asker(box, note, button) {
  let controller = null;
  return {
    get working() { return !!controller; },
    stop() { controller?.abort(); },
    async ask(options) {
      if (controller) return null;
      controller = new AbortController();
      button && (button.disabled = true);
      box.set("", true); note.textContent = "";
      try {
        const r = await Language.stream({ ...options, signal: controller.signal, onText: (t) => box.set(t, true), onProgress: (text) => { note.textContent = text; } });
        box.set(r.text);
        note.textContent = `${r.model} · ${r.tokens} tokens at ${r.tokensPerSecond.toFixed(1)} per second, in this browser`;
        return r;
      } catch (error) { note.textContent = error.message ?? String(error); box.set(box.text); return null; }
      finally { controller = null; button && (button.disabled = false); }
    },
  };
}

const twoColumns = (left, right, width = 420) => el("div.layout", { style: { gridTemplateColumns: `minmax(0, 1fr) ${width}px` } }, left, right);
const header = (view, title, intro) => view.append(el("h1", {}, title), el("p.muted", { style: { marginTop: "-6px" } }, intro));
const webgpuNote = () => (navigator.gpu ? "" : el("p.error", {}, "This browser has no WebGPU: the language models cannot run here. Use a recent Chrome or Edge."));

// MARK: Chat

export function chat(view) {
  header(view, "Chat", "A small language model running in this browser. The conversation stays here.");
  const picker = modelPicker("chat", "chat");
  const system = el("input", { type: "text", placeholder: "Instructions (optional), e.g. Answer briefly.", style: { flex: 1 }, value: store.get("chat.system", ""), onchange: () => store.set("chat.system", system.value) });
  const log = el("div", { style: { display: "flex", flexDirection: "column", gap: "10px", marginBottom: "12px" } });
  const input = el("textarea", { rows: 2, placeholder: "Message" });
  const note = progressLine();
  let history = [], controller = null;
  const send = async () => {
    const text = input.value.trim();
    if (!text || controller) return;
    input.value = "";
    log.append(el("div.panel", { style: { alignSelf: "flex-end", background: "var(--accent)", color: "var(--accent-text)", maxWidth: "80%" } }, text));
    const reply = el("div.panel", { style: { maxWidth: "90%" } }, el("span.muted", {}, "…"));
    log.append(reply);
    controller = new AbortController();
    const prior = history.map((h) => `${h.role === "user" ? "User" : "Assistant"}: ${h.text}`).join("\n");
    try {
      const r = await Language.stream({ model: picker.value, system: system.value || undefined, user: prior ? `${prior}\nUser: ${text}` : text, maxTokens: 700, temperature: 0.6,
        onText: (t) => { reply.innerHTML = markdown(t); }, onProgress: (t) => { note.textContent = t; }, signal: controller.signal });
      history.push({ role: "user", text }, { role: "assistant", text: r.text });
      history = history.slice(-12);
      note.textContent = `${r.model} · ${r.tokensPerSecond.toFixed(1)} tokens per second`;
    } catch (error) { reply.textContent = error.message ?? String(error); }
    finally { controller = null; }
  };
  input.onkeydown = (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); } };
  view.append(webgpuNote(), el("div.toolbar", {}, picker, system, el("button.button", { onclick: () => { history = []; log.replaceChildren(); } }, "New chat")),
    log, el("div.toolbar", {}, input, el("button.button.primary", { onclick: send }, "Send"), el("button.button", { onclick: () => controller?.abort() }, "Stop")), note);
}

// MARK: Picture questions (Ask an image, Outfit, Fridge, Face report)

function pictureQuestions(view, { title, intro, presets, front = true, timer = 3, allowCustom = true, maxTokens = 400 }) {
  header(view, title, intro);
  let picture = null;
  const picker = modelPicker("pictures", "pictures"), box = answerBox(), note = progressLine();
  const source = pictureSource({ front, timer, onPicture: (c) => { picture = c; } });
  const ask = asker(box, note);
  const go = (system, question) => { if (!picture) { note.textContent = "Take or choose a picture first."; return; } ask.ask({ model: picker.value, system, user: question, picture, maxTokens }); };
  const custom = el("input", { type: "text", placeholder: "Or ask your own question", style: { flex: 1 } });
  view.append(webgpuNote(), twoColumns(source, el("div", {}, el("div.toolbar", {}, picker),
    ...presets.map((p) => el("button.button", { style: { width: "100%", justifyContent: "flex-start", marginBottom: "6px" }, onclick: () => go(p.system, p.question) }, `✨ ${p.title}`)),
    allowCustom ? el("div.toolbar", {}, custom, el("button.button", { onclick: () => go(undefined, custom.value.trim()) }, "Ask")) : "",
    el("button.button", { onclick: () => ask.stop() }, "Stop"), box, note)));
  view.addEventListener("detach", () => { source.stop(); ask.stop(); });
}

export const askImage = (view) => pictureQuestions(view, { title: "Ask an image", intro: "Ask anything about a picture. It is not uploaded: the model runs here.",
  presets: [{ title: "Describe this picture", question: "Describe this picture in a few sentences." }, { title: "What text is in it?", question: "Read out any text you can see in the picture." }], front: false });

export const outfit = (view) => pictureQuestions(view, { title: "Outfit advisor", intro: "Stand back so your whole outfit is in the picture, then take it with the self-timer (or choose a photo).", front: true, timer: 5, maxTokens: 300,
  presets: [
    { title: "Rate my outfit", question: "Comment on this person's outfit in the three sections: Current outfit, Suggestions, Summary.",
      system: "You are a professional stylist. Comment on the whole outfit of the person in the picture in three sections, each starting with its title in bold on its own line, in a friendly tone that gives confidence:\n**Current outfit**: 1-2 sentences on what they are wearing (pieces, colours, overall style).\n**Suggestions**: 2-3 specific, practical improvements.\n**Summary**: one encouraging sentence.\nNo small talk." },
    { title: "What to wear with it", question: "Suggest shoes, accessories and a jacket that would go with this outfit, and say why." }] });

export const fridge = (view) => pictureQuestions(view, { title: "Fridge chef", intro: "Show your ingredients (the real thing or a photo of your fridge), then ask for ideas.", front: false, maxTokens: 450,
  presets: [
    { title: "Ingredients and recipes", question: "You are a cooking assistant. First list the ingredients you see, then suggest one or two home dishes that use them, each with short steps." },
    { title: "Just the ingredients", question: "List all the ingredients you can see." },
    { title: "Two recipes with steps", question: "Suggest two home dishes made with the ingredients in the picture, each with 3-4 simple steps." }] });

export const faceReport = (view) => pictureQuestions(view, { title: "Face style report", intro: "Look at the camera in good light. Only the picture you take is used, and nothing is saved.", front: true, allowCustom: false, maxTokens: 450,
  presets: [{ title: "Make my style report", question: "Write the style report for the face in this picture.",
    system: "You describe faces for a friendly style report. Describe only what can be seen, kindly and without judging attractiveness. Never give scores or ratings of looks. Use these sections, each title in bold on its own line:\n**Face shape**: one sentence.\n**Features**: eyes, brows, nose, lips and skin, one short phrase each.\n**Strengths**: three things that work well.\n**Style and care tips**: hair, brows, glasses or make-up if any, skincare, clothing colours - one practical tip each.\nEnd with: \"For fun only, not professional advice.\"" }] });

// MARK: Calories

export function calories(view) {
  header(view, "Calories", "Point the camera at a meal (or choose a photo). Estimates only.");
  let picture = null, items = [], log = DailyLog.load();
  const picker = modelPicker("pictures", "pictures"), note = progressLine(), table = el("div"), today = el("div");
  const source = pictureSource({ front: false, timer: 2, onPicture: (c) => { picture = c; } });
  const box = answerBox("The model's answer appears here.");
  const ask = asker(box, note);
  const fillToday = () => today.replaceChildren(
    el("div", {}, el("span", { style: { fontSize: "40px", fontWeight: 800, color: "#ff9f0a" } }, String(log.kcal)), ` kcal today · ${log.proteinGrams} g protein · ${log.meals.length} meal${log.meals.length === 1 ? "" : "s"}`),
    el("ul.list", {}, log.meals.slice().reverse().map((m) => el("li", {}, el("span.small.muted", {}, new Date(m.time).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })), el("span.grow", {}, m.items.map((i) => i.item).join(", ")), `${m.kcal} kcal`))),
    log.meals.length ? el("button.button", { onclick: () => { log.clear(); fillToday(); } }, "Clear today") : "");
  const estimate = async () => {
    if (!picture) { note.textContent = "Take or choose a picture first."; return; }
    items = []; table.replaceChildren();
    const r = await ask.ask({ model: picker.value, user: Nutrition.prompt, picture, maxTokens: 260, temperature: 0.15 });
    if (!r) return;
    items = Nutrition.parseItems(r.text);
    if (!items.length) { table.replaceChildren(el("p.small", {}, "No food recognised.")); return; }
    const t = Nutrition.totals(items);
    table.replaceChildren(el("table", {}, el("tr", {}, ...["Food", "Portion", "kcal", "Protein"].map((h) => el("th", {}, h))),
      ...items.map((i) => el("tr", {}, el("td", {}, i.item), el("td.muted", {}, i.portion), el("td", {}, String(i.kcal)), el("td", {}, `${i.proteinGrams} g`))),
      el("tr", {}, el("th", {}, "Total"), el("td", {}, ""), el("th", {}, String(t.kcal)), el("th", {}, `${t.proteinGrams} g`))),
      el("button.button", { onclick: () => { log.add(items); items = []; table.replaceChildren(); fillToday(); } }, "Add to today"));
  };
  view.append(webgpuNote(), twoColumns(source, el("div", {}, el("div.toolbar", {}, picker, el("button.button.primary", { onclick: estimate }, "Estimate calories")),
    table, today, note, el("details", {}, el("summary.small.muted", {}, "What the model said"), box),
    el("p.small.muted", {}, "Small models guess; treat the numbers as rough estimates. Today's list starts empty each day."))));
  fillToday();
  view.addEventListener("detach", () => source.stop());
}

// MARK: Offline code

/** Runs JavaScript in a throwaway sandboxed frame: no network (CSP), no access to this page, 10 s limit. */
export function runJavaScript(code, timeout = 10) {
  return new Promise((resolve) => {
    const frame = el("iframe", { sandbox: "allow-scripts", style: { display: "none" } });
    const started = performance.now();
    const done = (out) => { window.removeEventListener("message", listen); clearTimeout(timer); frame.remove(); resolve({ ...out, seconds: (performance.now() - started) / 1000 }); };
    const listen = (e) => { if (e.source === frame.contentWindow) done(e.data); };
    const timer = setTimeout(() => done({ output: "", error: `Stopped after ${timeout} seconds.`, timedOut: true }), timeout * 1000);
    window.addEventListener("message", listen);
    frame.srcdoc = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'"><script>
      const lines = [], show = (...a) => lines.push(a.map((x) => typeof x === "string" ? x : JSON.stringify(x)).join(" "));
      console.log = console.info = console.warn = console.error = show;
      (async () => { try { const r = await (new Function("return (async () => {\\n" + ${JSON.stringify(code)} + "\\n})()"))(); if (r !== undefined) show(r); parent.postMessage({ output: lines.join("\\n"), error: null }, "*"); }
        catch (e) { parent.postMessage({ output: lines.join("\\n"), error: String(e) }, "*"); } })();<\/script>`;
    document.body.append(frame);
  });
}

export function offlineCode(view) {
  header(view, "Offline code", "Ask for a small program. The model writes JavaScript, which runs here in a sealed-off frame.");
  const SYSTEM = "You are a coding assistant in a web page. Write programs in JavaScript: they run in this page, print with console.log, and have no network, no files and no browser page. Give one complete code block in ```javascript, then at most three short sentences of explanation. If the user asks for another language, show it, but also give a JavaScript version that runs.";
  const picker = modelPicker("code", "code"), request = el("input", { type: "text", placeholder: "What should the program do? e.g. the first 20 prime numbers", style: { flex: 1 } });
  const box = answerBox("Ask for a small program."), note = progressLine();
  const codeView = el("pre", { style: { background: "var(--panel-2)", padding: "10px", borderRadius: "10px", minHeight: "160px", overflow: "auto", whiteSpace: "pre" } });
  const output = el("pre", { style: { background: "#111", color: "#30d158", padding: "10px", borderRadius: "10px", minHeight: "90px", whiteSpace: "pre-wrap" } });
  const info = el("p.small.muted");
  let answer = "";
  const ask = asker({ set: (t, w) => { answer = t; box.set(CodeBlocks.textOnly(t), w); codeView.textContent = CodeBlocks.last(t)?.code ?? ""; }, get text() { return answer; } }, note);
  const runButton = el("button.button.primary", { onclick: async () => {
    const block = CodeBlocks.last(answer);
    if (!block || block.language !== "javascript") { info.textContent = "Only JavaScript runs here; other code can be copied."; return; }
    runButton.disabled = true; output.textContent = "Running…";
    const r = await runJavaScript(block.code);
    output.textContent = (r.output || "") + (r.error ? `${r.output ? "\n" : ""}Error: ${r.error}` : "");
    info.textContent = r.timedOut ? "Stopped: took longer than 10 s." : `Finished in ${r.seconds.toFixed(2)} s.`;
    runButton.disabled = false;
  } }, "▶ Run");
  request.onkeydown = (e) => { if (e.key === "Enter") go(); };
  const go = () => { if (request.value.trim()) ask.ask({ model: picker.value, system: SYSTEM, user: request.value.trim(), maxTokens: 700, temperature: 0.2 }); };
  view.append(webgpuNote(), el("div.toolbar", {}, picker, request, el("button.button.primary", { onclick: go }, "Ask"), el("button.button", { onclick: () => ask.stop() }, "Stop")),
    twoColumns(el("div", {}, box, note), el("div", {}, el("div.toolbar", {}, el("b", {}, "Code"), el("button.button", { onclick: () => navigator.clipboard?.writeText(codeView.textContent) }, "Copy"), runButton), codeView,
      el("b", {}, "Output"), output, info, el("p.small.muted", {}, "The code runs in a sealed-off frame: no internet, no access to this page, stopped after 10 seconds.")), 460));
}

// MARK: Speech to text and Meeting notes

function whisperPicker() {
  const s = el("select", { "aria-label": "Speech model", onchange: () => store.set("whisper", s.value) }, WHISPER_MODELS.map((m) => el("option", { value: m.id }, `${m.title} (${m.mb} MB)`)));
  s.value = store.get("whisper", WHISPER_MODELS[0].id);
  return s;
}

/**
 * The audio to work on: record, an audio (or video) file, or a sample; and a player for it.
 * `onAudio(blob, sample)` runs for each new audio (sample: the SPEECH_SAMPLES entry, or null).
 * Returns { controls, player, current() }. The player remembers whether it was muted.
 */
function audioInput(onAudio, status) {
  let recording = null, since = 0, tick = null, current = null, url = null;
  const audio = el("audio", { controls: true, preload: "auto", style: { width: "100%", display: "block" } });
  try { audio.muted = store.get("audio.muted") === "1"; } catch { /* not kept */ }
  audio.addEventListener("volumechange", () => store.set("audio.muted", audio.muted ? "1" : "0"));
  const caption = el("p.small.muted", { style: { margin: "6px 2px 0" } });
  const player = el("div.panel", { hidden: true, style: { padding: "10px 12px" } }, audio, caption);
  const use = (blob, sample = null, label = "") => {
    current = blob;
    if (url) URL.revokeObjectURL(url);
    url = URL.createObjectURL(blob);
    audio.src = url;
    caption.replaceChildren(...(sample
      ? [el("b", {}, sample.title), " · ", sample.href ? el("a", { href: sample.href, target: "_blank", rel: "noopener" }, sample.credit) : sample.credit]
      : [label]));
    player.hidden = false;
    if (sample || blob instanceof File) audio.play().catch(() => {});   // not a recording: the user just heard it
    onAudio(blob, sample);
  };
  const record = el("button.button.primary", { onclick: async () => {
    if (recording) { clearInterval(tick); const blob = await recording.stop(); recording = null; record.textContent = "🎙 Record"; use(blob, null, `Your recording (${Math.round((Date.now() - since) / 1000)} s)`); return; }
    try { audio.pause(); recording = await recordMicrophone(); since = Date.now(); record.textContent = "■ Stop"; tick = setInterval(() => { status.textContent = `Recording… ${Math.round((Date.now() - since) / 1000)} s`; }, 500); }
    catch (error) { status.textContent = `Microphone: ${error.message}`; }
  } }, "🎙 Record");
  const file = el("input", { type: "file", accept: "audio/*,video/*", hidden: true, onchange: () => { const f = file.files[0]; if (f) use(f, null, f.name); file.value = ""; } });
  const samples = el("select", { "aria-label": "Speech samples", style: { maxWidth: "220px" }, onchange: async () => {
    const sample = SPEECH_SAMPLES[Number(samples.value)];
    samples.value = "";
    if (!sample) return;
    try { use(await (await fetch(`samples/${sample.file}`)).blob(), sample); } catch (error) { status.textContent = `Sample: ${error.message}`; }
  } }, el("option", { value: "" }, "Samples…"), SPEECH_SAMPLES.map((x, i) => el("option", { value: i }, x.title)));
  const controls = el("span.toolbar", { style: { margin: 0 } }, record, el("button.button", { onclick: () => file.click() }, "Audio file…"), file, samples);
  return { controls, player, current: () => current };
}

export function speech(view) {
  header(view, "Speech to text", "Whisper turns speech into text in this browser. Nothing is uploaded.");
  const model = whisperPicker(), language = el("input", { type: "text", placeholder: "Language, e.g. pt (empty: detect)", style: { width: "190px" } });
  const translate = el("input", { type: "checkbox" }), status = progressLine(), box = answerBox("The text appears here.");
  let working = false;
  const transcribe = async (blob) => {
    if (!blob || working) return;
    working = true; again.disabled = true;
    try {
      status.textContent = "Reading the audio…";
      const samples = await audioSamples(blob), started = performance.now();
      box.set("", true);
      let detected = null;
      const text = await Speech.transcribe(samples, { model: model.value, language: language.value.trim().toLowerCase() || null, translate: translate.checked,
        onProgress: (t) => { status.textContent = t; }, onLanguage: (code) => { detected = code; } });
      box.set(text || "(no speech found)");
      const said = detected ? `${languageName(detected)} (detected)` : languageName(language.value.trim().toLowerCase());
      status.textContent = `${said} · ${(samples.length / 16000).toFixed(1)} s of audio in ${((performance.now() - started) / 1000).toFixed(1)} s`;
    } catch (error) { status.textContent = error.message ?? String(error); box.set(""); }
    working = false; again.disabled = !input.current();
  };
  // A sample says its language; a file or a recording is detected unless a language is typed.
  const input = audioInput((blob, sample) => { if (sample) language.value = sample.lang; transcribe(blob); }, status);
  const again = el("button.button", { disabled: true, onclick: () => transcribe(input.current()) }, "Transcribe again");
  view.append(el("div.toolbar", {}, input.controls, model, language, el("label", {}, translate, " Translate to English"), again), input.player, status, box);
}

export function meetingNotes(view) {
  header(view, "Meeting notes", "Record a meeting (or choose an audio file): Whisper writes it down, then a language model writes the notes.");
  const model = modelPicker("chat", "notes"), whisper = whisperPicker(), status = progressLine();
  const transcript = answerBox("Record a meeting or choose an audio file."), notes = answerBox("Key points, action items and decisions appear here.");
  const process = async (blob, sample) => {
    try {
      status.textContent = "Turning speech into text…";
      const samples = await audioSamples(blob);
      if (samples.length < 8000) throw new Error("The recording is too short.");
      transcript.set("", true);
      const text = await Speech.transcribe(samples, { model: whisper.value, language: sample?.lang ?? null, onProgress: (t) => { status.textContent = t; } });
      if (!text) throw new Error("No speech was found in the recording.");
      transcript.set(text);
      for (let attempt = 1; attempt <= 2; attempt++) {
        status.textContent = attempt === 1 ? "Writing the notes…" : "The first notes were not in the right format; trying again…";
        const r = await Language.stream({ model: model.value, system: MeetingNotes.system, user: MeetingNotes.userMessage(text), maxTokens: 500, temperature: attempt === 1 ? 0.2 : 0.5,
          onText: (t) => notes.set(t, true), onProgress: (t) => { status.textContent = t; } });
        notes.set(r.text);
        status.textContent = `${(samples.length / 16000).toFixed(0)} s of audio · notes by ${r.model}`;
        if (MeetingNotes.looksValid(r.text)) break;
      }
    } catch (error) { status.textContent = error.message ?? String(error); }
  };
  const input = audioInput(process, status);
  view.append(webgpuNote(), el("div.toolbar", {}, input.controls, whisper, model), input.player, status,
    twoColumns(el("div", {}, el("h2", {}, "Transcript"), transcript), el("div", {}, el("h2", {}, "Notes"), notes,
      el("p.small.muted", {}, "Nothing leaves this browser. Names and facts not said in the meeting are not invented (“Not mentioned”).")), 460));
}

export { LANGUAGE_MODELS };
