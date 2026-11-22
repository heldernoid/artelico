// Privacy camera (port of the apps' PrivacyCameraExample.swift): faces, licence plates, any text and/or whole
// people are hidden in every frame before it is shown or recorded. The frame is grabbed into the runner's
// offscreen canvas, cleaned into a new canvas, and only that copy reaches the screen and the recorder; when
// cleaning fails the camera stops and nothing is shown. Rules in js/rules/privacy.js.
import { el, store, modelsFor } from "../common.js";
import { exampleScreen } from "./kit.js";
import { drawBoxes } from "../../core/render.js";
import { run } from "../../core/pipeline.js";
import { Catalog, inputWidth, inputHeight } from "../../core/catalog.js";
import { prepare, sourceSize, Rect } from "../../core/prep.js";
import { faces } from "../../core/faces.js";
import { textRegions } from "../../core/decode2.js";
import { TextReader } from "../../core/pipelines.js";
import { PrivacyScan, PrivacyFilter, RegionHold, PRIVACY_STYLES, PRIVACY_KINDS, KIND_TITLES, KIND_COLORS } from "../../rules/privacy.js";
import { VIDEOS } from "../hailo-videos.js";
import { backendName } from "../../app.js";

/** Faces, each box grown for hair and chin. */
async function scanFaces(image, engine, name) {
  const detector = Catalog.model(name);
  const frame = prepare(image, inputWidth(detector), inputHeight(detector), "letterbox");
  return faces(await engine.infer([frame.rgb], name), detector, frame).map((f) => PrivacyScan.face(f.boundingBox)).filter((r) => r.box);
}

/** Text found by ocr_det in `area` of the picture (normalized), as regions of `kind` ("plate" or "text"). */
async function scanText(image, engine, area, kind) {
  const { width, height } = sourceSize(image);
  const region = PrivacyScan.searchArea(area, width, height);
  if (!region) return [];
  const detector = Catalog.model(TextReader.detectorName);
  const frame = prepare(image, inputWidth(detector), inputHeight(detector), "letterbox", region);
  const found = textRegions((await engine.infer([frame.rgb], TextReader.detectorName))[0], frame);
  return found.map((t) => PrivacyScan.text(t.corners, kind)).filter(Boolean);
}

/** The recording format: MP4 (H.264) where the browser writes it, otherwise WebM. */
function recordingType() {
  const types = ["video/mp4;codecs=avc1", "video/mp4", "video/webm;codecs=vp9", "video/webm;codecs=vp8", "video/webm"];
  return types.find((t) => window.MediaRecorder?.isTypeSupported?.(t)) ?? "";
}

export function privacyCamera(view, app) {
  const flag = (key, fallback) => store.get(`privacy.${key}`, fallback ? "1" : "0") === "1";
  const opts = { faces: flag("faces", true), plates: flag("plates", true), text: flag("text", false), people: flag("people", false), outlines: flag("outlines", false) };
  let style = PRIVACY_STYLES.includes(store.get("privacy.style")) ? store.get("privacy.style") : "Blur";
  let hidden = [], failed = false;
  const hold = new RegionHold(0.6);

  // The face detector: the chosen one, else the best one here (scrfd_10g first).
  const faceNames = PrivacyScan.faceDetectorNames.filter((n) => Catalog.model(n));
  const faceSelect = el("select", { "aria-label": "Face model", onchange: () => store.set("privacy.faceModel", faceSelect.value) },
    faceNames.map((n) => el("option", { value: n, disabled: !app.canUse(n) }, app.modelLabel(n))));
  const savedFace = store.get("privacy.faceModel");
  faceSelect.value = savedFace && app.canUse(savedFace) ? savedFace : faceNames.find((n) => app.canUse(n)) ?? faceNames[0];
  const faceDetector = () => (app.canUse(faceSelect.value) ? faceSelect.value : null);
  const textHere = () => app.canUse(TextReader.detectorName);

  // Instance models, the apps' default (yolov8s_seg) first.
  const instanceModels = [...modelsFor("instance_segmentation", app)].sort((a, b) => (b.name === PrivacyScan.defaultInstanceModel) - (a.name === PrivacyScan.defaultInstanceModel));

  const s = exampleScreen(view, app, {
    title: "Privacy camera", modelKey: "privacy", panelWidth: 320,
    intro: "Faces, licence plates, text or whole people are hidden before the picture is shown.",
    placeholder: "Press Start: faces, plates or whole people are hidden before the picture is shown.",
    task: "instance_segmentation", models: instanceModels,
    sources: ["back", "front", "video", "stream", "picture"],
    samples: [["Street with a bus", "bus.jpg"], ["Plate and signs (All text)", "plate_sample.png"], VIDEOS.street, VIDEOS.office, VIDEOS.face, VIDEOS.drive],
    extras: () => [faceDetector(), textHere() ? TextReader.detectorName : null].filter(Boolean),
    beforeStart: () => { hold.reset(); hidden = []; failed = false; counts(); },
    analyse: async (image, engine, time) => {
      const t0 = performance.now();
      // The instance model only runs when people or vehicles are needed.
      const instances = opts.people || (opts.plates && !opts.text) ? (await run("instance_segmentation", image, engine)).result.value : [];
      const found = [];
      const detector = faceDetector();
      if (opts.faces && detector && engine.loadedModelNames.includes(detector)) found.push(...await scanFaces(image, engine, detector));
      if (textHere() && engine.loadedModelNames.includes(TextReader.detectorName)) {
        if (opts.text) found.push(...await scanText(image, engine, Rect.whole(), "text"));   // plates included
        else if (opts.plates) for (const vehicle of PrivacyScan.vehicles(instances)) found.push(...await scanText(image, engine, vehicle, "plate"));
      }
      if (opts.people) found.push(...PrivacyScan.people(instances));
      const regions = hold.update(found, time);
      const inferenceMs = performance.now() - t0;
      // Fails closed: when the picture cannot be cleaned the camera stops instead of showing it.
      let clean;
      try { clean = PrivacyFilter.apply(image, regions, style); } catch (error) {
        throw new Error(`The picture could not be cleaned, so it is not shown (${error.message ?? error}).`);
      }
      return { regions, clean, inferenceMs };
    },
    shown: (f) => (failed ? null : f.clean),
    onFrame: (f) => {
      hidden = f.regions;
      counts();
      if (recorder) record(f.clean);
    },
    draw: (ctx, W, H) => {
      if (opts.outlines) drawBoxes(ctx, hidden.map((r) => ({ box: r.box, label: r.kind, color: KIND_COLORS[r.kind], width: 2 })), W, H);
    },
    onStop: (message) => {
      stopRecording();
      // Stopped by a failure: take the last picture off the screen too.
      if (message) { failed = true; s.redraw(); }
    },
  });

  // MARK: Counts

  const numbers = Object.fromEntries(PRIVACY_KINDS.map((k) => [k, el("div", { style: { fontSize: "40px", fontWeight: 800, lineHeight: 1 } }, "0")]));
  const countRow = el("div", { style: { display: "flex", gap: "18px", margin: "6px 0 12px" } },
    PRIVACY_KINDS.map((k) => el("div", { style: { textAlign: "center" } }, numbers[k], el("div.small.muted", {}, KIND_TITLES[k]))));
  function counts() {
    const n = Object.fromEntries(PRIVACY_KINDS.map((k) => [k, hidden.filter((r) => r.kind === k).length]));
    for (const k of PRIVACY_KINDS) numbers[k].textContent = n[k];
    countRow.dataset.counts = JSON.stringify(n);   // read by the headless checks
  }

  // MARK: Recording (only the cleaned frames: a canvas of its own that nothing else draws into)

  let recorder = null, recordCanvas = null, track = null, chunks = [];
  const recordButton = el("button.button.primary", { onclick: () => (recorder ? stopRecording() : startRecording()) }, "⏺ Record");
  const saved = el("p.small.muted");
  function startRecording() {
    const first = s.last?.clean;
    if (!s.runner.running || !first || failed) { saved.textContent = "Start the camera first."; return; }
    if (!window.MediaRecorder) { saved.textContent = "This browser cannot record video."; return; }
    const scale = Math.min(1, 1280 / Math.max(first.width, first.height));
    recordCanvas = el("canvas", { width: Math.round(first.width * scale / 2) * 2, height: Math.round(first.height * scale / 2) * 2 });
    record(first);
    const stream = recordCanvas.captureStream(0);
    track = stream.getVideoTracks()[0];
    const type = recordingType();
    recorder = new MediaRecorder(stream, { ...(type ? { mimeType: type } : {}), videoBitsPerSecond: 6_000_000 });
    chunks = [];
    recorder.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
    recorder.onstop = () => {
      const kind = recorder?.mimeType || type || "video/webm", ext = kind.includes("mp4") ? "mp4" : "webm";
      const blob = new Blob(chunks, { type: kind.split(";")[0] }), name = `privacy-${new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-")}.${ext}`;
      saved.replaceChildren(`Saved ${name} (${(blob.size / 1e6).toFixed(1)} MB; only the hidden version is recorded). `,
        el("a", { href: URL.createObjectURL(blob), download: name }, "Download"));
      recorder = null; recordCanvas = null; track = null;
      recordButton.textContent = "⏺ Record"; recordButton.className = "button primary";
    };
    recorder.start(1000);
    recordButton.textContent = "⏹ Stop recording"; recordButton.className = "button danger";
    saved.textContent = "Recording…";
  }
  function record(clean) {
    if (!recordCanvas || !clean) return;
    recordCanvas.getContext("2d").drawImage(clean, 0, 0, recordCanvas.width, recordCanvas.height);
    track?.requestFrame?.();
  }
  function stopRecording() { if (recorder?.state === "recording") recorder.stop(); }
  view.addEventListener("detach", stopRecording);

  // MARK: Panel

  const toggle = (key, title) => el("label", { style: { display: "block", margin: "4px 0" } },
    el("input", { type: "checkbox", checked: opts[key], onchange: (e) => { opts[key] = e.target.checked; store.set(`privacy.${key}`, opts[key] ? "1" : "0"); if (key === "outlines") s.redraw(); } }), ` ${title}`);
  const styleBox = el("div.toolbar", { role: "radiogroup", "aria-label": "Look", style: { margin: "8px 0" } });
  const fillStyles = () => styleBox.replaceChildren(...PRIVACY_STYLES.map((name) => el(`button.button${name === style ? ".primary" : ""}`,
    { role: "radio", "aria-checked": String(name === style), onclick: () => { style = name; store.set("privacy.style", name); fillStyles(); } }, name)));
  fillStyles();
  const models = () => `Faces: ${faceDetector() ?? "no face model here"} · plates: text found on vehicles, and all text, by ${textHere() ? TextReader.detectorName : "(ocr_det not here)"} · people: masks from ${app.loadedModel ?? instanceModels[0]?.name ?? "an instance model"}.`;
  const modelNote = el("p.small.muted", {}, models());
  const noteModels = () => { modelNote.textContent = models(); };
  app.listeners.add(noteModels);
  view.addEventListener("detach", () => app.listeners.delete(noteModels));
  s.panel.append(
    el("h2", { style: { marginTop: 0 } }, "Hidden now"), countRow,
    toggle("faces", "Faces"), toggle("plates", "Licence plates"), toggle("text", "All text (signs, papers, screens)"), toggle("people", "Whole people"),
    styleBox, toggle("outlines", "Show outlines"),
    el("label.small", { style: { display: "block", margin: "8px 0" } }, "Face model ", faceSelect, " (next Start)"),
    el("hr"), el("div.toolbar", {}, recordButton), saved, el("hr"),
    el("p.small.muted", {}, `Every frame is cleaned before it is shown or recorded: the original never appears on screen and nothing else is kept. A face the detector misses for a moment stays hidden at its last place for ${hold.seconds.toFixed(1)} s.`),
    modelNote,
    el("p.small.muted", {}, `Far-away or side-on faces can be missed; turn on Whole people for the strictest setting. Runs in this browser (${backendName()}); nothing is uploaded.`),
  );
  counts();
}
