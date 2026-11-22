// The hand examples (UGen300 HandDemos: GestureCaption, FruitNinja, AirBand) and Photo restore.
import { el, store, loadImage, imageFromFile, SAMPLES as ALL_SAMPLES } from "../common.js";
import { exampleScreen, poseModels, poseAnalysis, Tone } from "./kit.js";
import { drawPoses } from "../../core/render.js";
import { HandCrop, HandSigns, SignSmoother, SIGNS, FruitGame, AirBand, HandReader } from "../../rules/hand-games.js";
import { STEPS, restore, blend, brightenStrength, meanBrightness } from "../../rules/photo-restore.js";
import { Catalog } from "../../core/catalog.js";
import { prepare, rgbToRGBA } from "../../core/prep.js";

const HAND_SAMPLES = [["Thumbs up", "thumbs_up.jpg"], ["Street with people", "bus.jpg"]];
const handExtras = () => [HandReader.modelName];

function drawHands(ctx, hands, W, H, color = () => "#34c759") {
  for (const h of hands) {
    ctx.strokeStyle = color(h); ctx.lineWidth = 3; ctx.lineCap = "round"; ctx.beginPath();
    for (const [a, b] of HandCrop.edges) { ctx.moveTo(h.points[a].x * W, h.points[a].y * H); ctx.lineTo(h.points[b].x * W, h.points[b].y * H); }
    ctx.stroke();
    ctx.fillStyle = "#fff";
    for (const p of h.points) { ctx.beginPath(); ctx.arc(p.x * W, p.y * H, 3, 0, 7); ctx.fill(); }
  }
}

// MARK: Hand signs (GestureCaption)

export function handSigns(view, app) {
  const smoothers = new Map(), seen = new Set();
  let signs = [];
  const big = el("div", { style: { fontSize: "40px", fontWeight: 800 } }, "…");
  const checklist = el("div", { style: { display: "grid", gridTemplateColumns: "1fr 1fr", gap: "4px 12px" } });
  const fill = () => checklist.replaceChildren(...Object.entries(SIGNS).filter(([k]) => k !== "unknown").map(([k, [caption, emoji]]) => el("div.small", {}, `${emoji} ${caption}${seen.has(k) ? " ✓" : ""}`)));
  exampleScreen(view, app, {
    title: "Hand signs", intro: "Show a sign: numbers 0-5, OK, thumbs up or down, rock, finger heart, pinky promise.", task: "pose", models: poseModels(app),
    samples: HAND_SAMPLES, modelKey: "signs", extras: handExtras, analyse: poseAnalysis({ hands: true }),
    onFrame: (f) => {
      signs = f.hands.map((h) => {
        const key = `${h.person}${h.side}`;
        if (!smoothers.has(key)) smoothers.set(key, new SignSmoother());
        return { hand: h, sign: smoothers.get(key).update(HandSigns.classify(h.points)) };
      });
      const shown = signs.find((s) => s.sign && s.sign !== "unknown");
      if (shown) { seen.add(shown.sign); big.textContent = `${SIGNS[shown.sign][1]} ${SIGNS[shown.sign][0]}`; }
      fill();
    },
    draw: (ctx, W, H, f) => {
      drawPoses(ctx, f.poses, W, H, "rgba(255,255,255,0.5)");
      drawHands(ctx, f.hands, W, H);
      ctx.font = "800 26px system-ui";
      for (const s of signs) if (s.sign && s.sign !== "unknown") {
        const p = s.hand.points[9], text = `${SIGNS[s.sign][1]} ${SIGNS[s.sign][0]}`, tw = ctx.measureText(text).width;
        const x = Math.min(Math.max(10, p.x * W - tw / 2), W - tw - 10), y = Math.max(36, s.hand.box.y * H - 8);
        ctx.fillStyle = "rgba(0,0,0,0.6)"; ctx.fillRect(x - 10, y - 30, ctx.measureText(text).width + 20, 38);
        ctx.fillStyle = "#fff"; ctx.fillText(text, x, y);
      }
    },
  }).panel.append(el("h2", { style: { marginTop: 0 } }, "Hand signs"), big, checklist, el("p.small.muted", {}, "A tick appears next to each sign the camera has seen. Hold a sign still for a moment."));
  fill();
}

// MARK: Fruit ninja

export function fruitNinja(view, app) {
  let game = new FruitGame(30, Number(store.get("fruit.best", 0))), lastTime = null, pops = [];
  const score = el("div.big-number"), info = el("p.muted");
  const show = (now) => { score.textContent = game.score; info.textContent = game.phase === "playing" ? `${Math.ceil(game.remaining(now))} s left · best ${game.best}` : game.phase === "over" ? `Time! Score ${game.score} · best ${game.best}` : `Best ${game.best}`; };
  const s = exampleScreen(view, app, {
    title: "Fruit ninja", intro: "Slice the fruit with a quick swipe of your index finger; avoid the bombs.", task: "pose", models: poseModels(app),
    sources: ["front", "back", "video", "picture"], samples: HAND_SAMPLES, modelKey: "fruit", extras: handExtras, analyse: poseAnalysis({ hands: true }),
    onFrame: (f) => {
      const dt = lastTime === null ? 0 : f.time - lastTime; lastTime = f.time;
      const tips = f.hands.map((h) => ({ key: `${h.person}${h.side}`, point: { x: h.points[8].x * FruitGame.width, y: h.points[8].y * FruitGame.height } }));
      for (const cut of game.update(tips, f.time, dt)) { pops.push({ x: cut.x, y: cut.y, t: f.time, bomb: cut.isBomb }); cut.isBomb ? Tone.drum("kick") : Tone.play(700 + Math.random() * 300, 0.1, { bright: true, volume: 0.2 }); }
      if (game.phase === "over") store.set("fruit.best", game.best);
      pops = pops.filter((p) => f.time - p.t < 0.6);
      show(f.time);
    },
    draw: (ctx, W, H, f) => {
      const sx = W / FruitGame.width, sy = H / FruitGame.height;
      ctx.font = "48px system-ui"; ctx.textAlign = "center"; ctx.textBaseline = "middle";
      for (const it of game.items) {
        const emoji = it.isBomb ? "💣" : FruitGame.kinds[it.kind][2];
        ctx.font = `${Math.round(it.radius * 2 * Math.min(sx, sy) * 1.1)}px system-ui`;   // as big as the fruit's hit area
        if (it.cutAt === null) ctx.fillText(emoji, it.x * sx, it.y * sy);
        else for (const h of it.halves) { ctx.globalAlpha = 0.6; ctx.fillText(emoji, h.x * sx, h.y * sy); ctx.globalAlpha = 1; }
      }
      ctx.font = "48px system-ui";
      for (const p of pops) ctx.fillText(p.bomb ? "💥" : "✨", p.x * sx, p.y * sy - 30);
      ctx.textAlign = "start"; ctx.textBaseline = "alphabetic";
      ctx.strokeStyle = "#64d2ff"; ctx.lineWidth = 6; ctx.lineCap = "round";
      for (const trail of game.trails.values()) { ctx.beginPath(); trail.forEach((e, i) => (i ? ctx.lineTo(e.point.x * sx, e.point.y * sy) : ctx.moveTo(e.point.x * sx, e.point.y * sy))); ctx.stroke(); }
      drawHands(ctx, f.hands, W, H, () => "rgba(255,255,255,0.6)");
    },
  });
  // Fruit size and game speed, remembered (big by default: the demo's size is small on tablets).
  const choice = (key, options, fallback) => {
    const select = el("select", { onchange: () => store.set(key, select.value) }, options.map(([label, v]) => el("option", { value: v }, label)));
    select.value = String(store.get(key, fallback));
    return select;
  };
  const sizeSelect = choice("fruit.size", [["Normal", 1], ["Big", 1.5], ["Huge", 2.2]], 1.5);
  const speedSelect = choice("fruit.speed", [["Slow", 0.6], ["Normal", 1], ["Fast", 1.4]], 1);
  s.panel.append(el("h2", { style: { marginTop: 0 } }, "Score"), score, info,
    el("button.button.primary", { onclick: () => {
      game = new FruitGame(30, game.best); game.size = Number(sizeSelect.value); game.speed = Number(speedSelect.value);
      game.start(s.last?.time ?? 0); lastTime = null;
    } }, "New game (30 s)"),
    el("div.toolbar", { style: { marginTop: "10px" } },
      el("label.small", {}, "Fruit size ", sizeSelect), el("label.small", {}, "Speed ", speedSelect)),
    el("p.small.muted", {}, "Start the camera first. A slow finger does not cut: it has to be a swipe."));
  show(0);
}

// MARK: Air band

export function airBand(view, app) {
  const band = new AirBand();
  let lastEvent = "", lit = new Map();
  const now = el("div", { style: { fontSize: "28px", fontWeight: 800 } }, "—");
  exampleScreen(view, app, {
    title: "Air band", intro: "Left third: drums (hit down). Middle: piano keys. Right: guitar (strum down; height picks the chord).", task: "pose", models: poseModels(app),
    sources: ["front", "back", "video", "picture"], samples: HAND_SAMPLES, modelKey: "band", extras: handExtras, analyse: poseAnalysis({ hands: true }),
    onFrame: (f) => {
      const hands = f.hands.map((h) => ({ id: `${h.person}${h.side}`, x: h.points[9].x * band.width, y: h.points[9].y * band.height }));
      for (const e of band.update(hands, f.time)) {
        if (e.drum) { Tone.drum(e.drum); lastEvent = `🥁 ${e.drum}`; lit.set(`d${e.drum}`, f.time); }
        else if (e.piano !== undefined) { Tone.piano(AirBand.noteFrequencies[e.piano] * (e.high ? 2 : 1)); lastEvent = `🎹 ${AirBand.noteNames[e.piano]}${e.high ? " (high)" : ""}`; lit.set(`p${e.piano}`, f.time); }
        else { const [name, notes] = AirBand.chords[e.chord]; notes.forEach((n, i) => setTimeout(() => Tone.pluck(n), i * 25)); lastEvent = `🎸 ${name}`; lit.set(`g${e.chord}`, f.time); }
      }
      now.textContent = lastEvent || "—";
    },
    draw: (ctx, W, H, f) => {
      const glow = (k) => f.time - (lit.get(k) ?? -9) < 0.25;
      ctx.fillStyle = "rgba(255,159,10,0.12)"; ctx.fillRect(0, 0, W / 3, H);
      ctx.fillStyle = "rgba(10,132,255,0.10)"; ctx.fillRect((2 * W) / 3, 0, W / 3, H);
      for (let k = 0; k < 8; k++) { ctx.fillStyle = glow(`p${k}`) ? "rgba(197,138,216,0.5)" : k % 2 ? "rgba(255,255,255,0.12)" : "rgba(255,255,255,0.04)"; ctx.fillRect(W / 3 + (k * W) / 24, 0, W / 24, H); }
      ctx.fillStyle = "#fff"; ctx.font = "700 18px system-ui";
      ctx.fillText("🥁 Drums", 12, 28); ctx.fillText("🎹 Piano", W / 3 + 12, 28); ctx.fillText("🎸 Guitar", (2 * W) / 3 + 12, 28);
      AirBand.chords.forEach(([name], i) => { ctx.fillStyle = glow(`g${i}`) ? "#ffd60a" : "rgba(255,255,255,0.7)"; ctx.fillText(name, W - 50, ((i + 0.5) * H) / 4); });
      drawHands(ctx, f.hands, W, H, () => "#ffd60a");
    },
  }).panel.append(el("h2", { style: { marginTop: 0 } }, "Now playing"), now, el("p.small.muted", {}, "Several people can play at once. Sounds are made in the browser."));
}

// MARK: Photo restore

export function photoRestore(view, app) {
  let original = null, restored = null, split = 0.5, working = false;
  const steps = new Set(["brighten", "denoise"]), strength = { brighten: Number(store.get("restore.brighten", 1)), denoise: Number(store.get("restore.denoise", 1)) };
  const canvas = el("canvas", { style: { cursor: "ew-resize", touchAction: "none" } }), status = el("p"), size = el("p.small.muted");
  const stage = el("div.stage", {}, canvas), panel = el("div.panel");
  const file = el("input", { type: "file", accept: "image/*", hidden: true, onchange: async () => { if (file.files[0]) setPicture(await imageFromFile(file.files[0])); } });
  const save = el("button.button", { disabled: true, onclick: () => canvasFor(restored).convertToBlob({ type: "image/png" }).then((b) => el("a", { href: URL.createObjectURL(b), download: "restored.png" }).click()) }, "Save");

  function canvasFor(img) { const c = new OffscreenCanvas(img.width, img.height); c.getContext("2d").putImageData(new ImageData(rgbToRGBA(img.rgb), img.width, img.height), 0, 0); return c; }
  function draw() {
    if (!original) return;
    const shown = restored ?? original, W = Math.min(1600, shown.width), H = Math.round((W * shown.height) / shown.width);
    canvas.width = W; canvas.height = H;
    const ctx = canvas.getContext("2d");
    ctx.drawImage(canvasFor(original), 0, 0, W, H);
    if (restored) {
      ctx.save(); ctx.beginPath(); ctx.rect(0, 0, W * split, H); ctx.clip(); ctx.drawImage(canvasFor(restored), 0, 0, W, H); ctx.restore();
      ctx.fillStyle = "#fff"; ctx.fillRect(W * split - 1.5, 0, 3, H);
      ctx.font = "700 14px system-ui"; ctx.fillText("After", 10, 22); ctx.fillText("Before", W - 60, 22);
    }
    size.textContent = `${original.width} × ${original.height}${restored ? ` → ${restored.width} × ${restored.height}` : ""}`;
  }
  function setPicture(img) {
    const longest = Math.max(img.width, img.height), scale = Math.min(1, 1024 / longest);
    const w = Math.round(img.width * scale), h = Math.round(img.height * scale);
    original = { rgb: prepare(img, w, h, "stretch").rgb, width: w, height: h };
    restored = null; split = 0.5; status.textContent = ""; save.disabled = true; draw();
  }
  async function go() {
    if (!original || working) return;
    working = true; run.disabled = true;
    const started = performance.now();
    try {
      let { rgb, width, height } = original;
      for (const step of STEPS) {
        if (!steps.has(step.id) || !app.canUse(step.model)) continue;
        status.textContent = `${step.title}: loading…`;
        await app.load(step.model);
        const model = Catalog.model(step.model);
        const out = await restore(rgb, width, height, model, app.engine, (d, t) => { status.textContent = `${step.title}: ${d}/${t} tiles`; });
        const k = step.id === "brighten" ? brightenStrength(meanBrightness(rgb), strength.brighten) : step.id === "denoise" ? strength.denoise : 1;
        rgb = blend(rgb, width, height, out.rgb, out.width, out.height, k);
        width = out.width; height = out.height;
      }
      restored = { rgb, width, height };
      status.textContent = `Done in ${((performance.now() - started) / 1000).toFixed(1)} s.`;
      save.disabled = false; draw();
    } catch (error) { status.textContent = `Stopped: ${error.message ?? error}`; }
    finally { working = false; run.disabled = false; app.setStatus("Ready"); }
  }
  canvas.onpointerdown = canvas.onpointermove = (e) => { if (e.type === "pointermove" && !e.buttons) return; const r = canvas.getBoundingClientRect(); split = Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)); draw(); };
  const run = el("button.button.primary", { onclick: go }, "Restore");
  for (const step of STEPS) {
    const here = app.canUse(step.model);
    const box = el("input", { type: "checkbox", checked: steps.has(step.id) && here, disabled: !here, onchange: (e) => (e.target.checked ? steps.add(step.id) : steps.delete(step.id)) });
    panel.append(el("div", { style: { margin: "8px 0" } }, el("label", {}, box, ` ${step.title}`), el("div.small.muted", {}, app.modelLabel(step.model)),
      strength[step.id] !== undefined && here ? el("input", { type: "range", min: 0.1, max: 1, step: 0.05, value: strength[step.id], oninput: (e) => { strength[step.id] = Number(e.target.value); store.set(`restore.${step.id}`, e.target.value); } }) : null));
  }
  panel.prepend(el("h2", { style: { marginTop: 0 } }, "Steps"));
  panel.append(run, status, size, el("p.small.muted", {}, "Drag across the picture to compare. Photos larger than 1024 pixels are reduced first. Nothing is uploaded."));
  const samples = el("select", { "aria-label": "Samples", onchange: async () => { if (samples.value) setPicture(await loadImage(`samples/${samples.value}`)); samples.value = ""; } },
    el("option", { value: "" }, "Samples…"), [["Dark room", "room.png"], ["Small picture", "input_image.png"], ["Street", "bus.jpg"]].map(([t, f]) => el("option", { value: f }, t)));
  view.append(el("h1", {}, "Photo restore"), el("p.muted", { style: { marginTop: "-6px" } }, "Brighten, remove noise and upscale ×2 an old or dark photo, then compare before and after."),
    el("div.toolbar", {}, el("button.button", { onclick: () => file.click() }, "Choose a photo…"), file, samples, save),
    el("div.layout", { style: { gridTemplateColumns: "minmax(0, 1fr) 300px" } }, stage, panel));
  loadImage("samples/room.png").then((img) => { setPicture(img); if (new URLSearchParams(location.hash.split("?")[1]).has("autostart")) go(); });
  void ALL_SAMPLES;
}
