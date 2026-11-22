// The detection and face examples (UGen300 demos HeadCount, TrafficCount, MissingCheck, PlateGate,
// EdgeVsCloud, FaceCheckIn). Rules in js/rules/detection-games.js.
import { el, store, modelsFor } from "../common.js";
import { exampleScreen, faceAnalysis, Tone } from "./kit.js";
import { drawBoxes, drawFaces } from "../../core/render.js";
import { run } from "../../core/pipeline.js";
import { TextReader, FaceGallery, FaceRecognition, averageEmbedding } from "../../core/pipelines.js";
import { findsLandmarks } from "../../core/faces.js";
import { cropToCanvas } from "../../core/prep.js";
import { ObjectTracker } from "../../core/tracker.js";
import { CentroidTracker, LineCounter, MissingCheck, PlateText, GateBarrier, confidentMatch, CheckInBook } from "../../rules/detection-games.js";
import { EdgeCloud } from "../../rules/photo-restore.js";
import { VIDEOS } from "../hailo-videos.js";
import { backendName } from "../../app.js";

const detectionModels = (app) => modelsFor("detection", app);
const STREET = [["Street with people", "bus.jpg"], VIDEOS.street, VIDEOS.office];

/** Small line chart on a canvas. */
function sparkline(canvas, points, max, color = "#34c759") {
  const c = canvas.getContext("2d"), W = canvas.width, H = canvas.height;
  c.clearRect(0, 0, W, H);
  if (points.length < 2) return;
  const t0 = points[0].t, span = Math.max(1, points[points.length - 1].t - t0);
  c.strokeStyle = color; c.lineWidth = 2; c.beginPath();
  points.forEach((p, i) => { const x = ((p.t - t0) / span) * W, y = H - 2 - (p.v / Math.max(1, max)) * (H - 4); i ? c.lineTo(x, y) : c.moveTo(x, y); });
  c.stroke();
}

// MARK: Head count

export function headCount(view, app) {
  let threshold = Number(store.get("headcount.conf", 0.3)), recent = [], peak = 0, history = [], people = [];
  const big = el("div.big-number", { style: { color: "var(--ok)" } }, "0"), peakLabel = el("p"), chart = el("canvas", { width: 300, height: 90, style: { width: "100%" } });
  const s = exampleScreen(view, app, {
    title: "Head count", intro: "People in view, numbered, with the peak and the last minute.", task: "detection", models: detectionModels(app),
    sources: ["back", "front", "video", "stream", "picture"], samples: STREET, modelKey: "headcount",
    onFrame: (f) => {
      people = f.result.value.filter((d) => d.label.startsWith("person") && d.confidence >= threshold);
      recent = [...recent, people.length].slice(-3);
      const count = [...recent].sort((a, b) => a - b)[Math.floor(recent.length / 2)];
      peak = Math.max(peak, count);
      history = [...history, { t: f.time, v: count }].filter((p) => f.time - p.t <= 60);
      big.textContent = count; peakLabel.textContent = `Peak ${peak}`;
      sparkline(chart, history, Math.max(peak, 1));
    },
    draw: (ctx, W, H) => drawBoxes(ctx, people.map((d, i) => ({ box: d.boundingBox, label: String(i + 1), color: "#34c759" })), W, H),
  });
  const slider = el("input", { type: "range", min: 0.15, max: 0.7, step: 0.05, value: threshold, oninput: () => { threshold = Number(slider.value); store.set("headcount.conf", threshold); note.textContent = text(); } });
  const text = () => `Counts people found with at least ${Math.round(threshold * 100)}% confidence. No pictures are kept and nobody is identified.`;
  const note = el("p.small.muted", {}, text());
  s.panel.append(el("h2", { style: { marginTop: 0 } }, "People now"), big, peakLabel, chart, el("p.small.muted", {}, "Last 60 seconds"),
    el("div.toolbar", {}, el("button.button", { onclick: () => { s.runner.paused = !s.runner.paused; } }, "Freeze / unfreeze"), el("button.button", { onclick: () => { peak = 0; } }, "Reset peak")),
    el("label.small", {}, "Confidence ", slider), note);
}

// MARK: Traffic count

const VEHICLES = { person: ["People", "#34c759"], bicycle: ["Bicycles", "#ffd60a"], motorcycle: ["Motorbikes", "#ff9f0a"], car: ["Cars", "#0a84ff"], bus: ["Buses", "#bf5af2"], truck: ["Trucks", "#ff375f"] };

export function traffic(view, app) {
  let line = Number(store.get("traffic.line", 0.6)), tracker = new CentroidTracker(10, 0.2, 0.08), counter = new LineCounter(line), tracks = [], minute = [], log = [];
  const total = el("div.big-number", { style: { color: "#ff9f0a" } }, "0"), sub = el("p.muted"), table = el("table");
  const fill = () => {
    table.replaceChildren(el("tr", {}, el("th", {}, ""), el("th", {}, "↓ down"), el("th", {}, "↑ up")),
      ...Object.entries(VEHICLES).map(([k, [name, color]]) => el("tr", {}, el("td", {}, el("span", { style: { color } }, "● "), name), el("td", {}, String(counter.count(k, "down"))), el("td", {}, String(counter.count(k, "up"))))));
  };
  const s = exampleScreen(view, app, {
    title: "Traffic count", intro: "Each object counts once, the first time its centre crosses the line.", task: "detection", models: detectionModels(app),
    sources: ["back", "front", "video", "stream", "picture"], samples: [["Street with people", "bus.jpg"], VIDEOS.drive, VIDEOS.aerial, VIDEOS.street], modelKey: "traffic", track: false,
    onFrame: (f) => {
      const dets = f.result.value.filter((d) => VEHICLES[d.label] && d.confidence >= 0.35).map((d) => ({ label: d.label, box: d.boundingBox }));
      tracks = tracker.update(dets);
      for (const c of counter.update(tracks)) { minute.push(f.time); log.push(`${new Date().toISOString()},${c.label},${c.direction}`); Tone.play(c.direction === "down" ? 740 : 880, 0.08, { volume: 0.15 }); }
      minute = minute.filter((t) => f.time - t <= 60);
      total.textContent = counter.total; sub.textContent = `crossed the line · ${minute.length} in the last minute`;
      fill();
    },
    draw: (ctx, W, H) => {
      drawBoxes(ctx, tracks.filter((t) => t.missed === 0).map((t) => ({ box: t.box, label: `${VEHICLES[t.label][0].replace(/s$/, "")} #${t.id}`, color: VEHICLES[t.label][1], width: 2 })), W, H);
      ctx.setLineDash([12, 8]); ctx.strokeStyle = "#ff9f0a"; ctx.lineWidth = 3; ctx.beginPath(); ctx.moveTo(0, line * H); ctx.lineTo(W, line * H); ctx.stroke(); ctx.setLineDash([]);
    },
  });
  const slider = el("input", { type: "range", min: 0.1, max: 0.9, step: 0.05, value: line, oninput: () => { line = Number(slider.value); counter.lineY = line; store.set("traffic.line", line); s.redraw(); } });
  s.panel.append(total, sub, table, el("label.small", {}, "Counting line ", slider),
    el("div.toolbar", {}, el("button.button", { onclick: () => { counter = new LineCounter(line); tracker = new CentroidTracker(10, 0.2, 0.08); minute = []; log = []; fill(); total.textContent = "0"; } }, "Reset"),
      el("button.button", { onclick: () => { const blob = new Blob([`time,kind,direction\n${log.join("\n")}\n`], { type: "text/csv" }); const a = el("a", { href: URL.createObjectURL(blob), download: "traffic.csv" }); a.click(); } }, "Download log")));
  fill();
}

// MARK: Missing check

export function missingCheck(view, app) {
  const check = new MissingCheck();
  let labels = [], status = null, lastBeep = 0, sound = store.get("missing.sound", "1") === "1";
  const seen = el("p"), banner = el("div", { style: { padding: "12px", borderRadius: "10px", fontWeight: 700, marginTop: "10px" } });
  const s = exampleScreen(view, app, {
    title: "Missing check", intro: "Lay out the things to watch, tap Remember, then it tells you what goes missing or appears.", task: "detection", models: detectionModels(app),
    sources: ["back", "front", "video", "picture"], samples: [["Street with a bus", "bus.jpg"], VIDEOS.office, VIDEOS.parcels], modelKey: "missing",
    onFrame: (f) => {
      labels = f.result.value.filter((d) => d.confidence >= 0.4).map((d) => d.label.replace(/ #\d+$/, ""));
      status = check.update(labels);
      seen.textContent = `Seen now: ${[...new Set(labels.filter((l) => !check.ignored.has(l)))].join(", ") || "nothing"}`;
      if (!status.armed) { banner.textContent = "Not watching yet"; banner.style.background = "var(--panel-2)"; banner.style.color = ""; return; }
      if (status.missing.length) { banner.textContent = `Missing: ${status.missing.join(", ")}`; banner.style.background = "var(--bad)"; banner.style.color = "#fff"; }
      else if (status.extra.length) { banner.textContent = `Extra: ${status.extra.join(", ")}`; banner.style.background = "#ffd60a"; banner.style.color = "#000"; }
      else { banner.textContent = `All ${check.baseline.length} things are here`; banner.style.background = "var(--ok)"; banner.style.color = "#fff"; }
      if (sound && f.time - lastBeep > 2 && (status.missing.length || status.extra.length)) {
        lastBeep = f.time;
        if (status.missing.length) Tone.play(330, 0.35, { volume: 0.3 }); else { Tone.play(988, 0.1); setTimeout(() => Tone.play(988, 0.1), 160); }
      }
    },
    draw: (ctx, W, H, f) => drawBoxes(ctx, f.result.value.filter((d) => d.confidence >= 0.4 && !check.ignored.has(d.label.replace(/ #\d+$/, ""))).map((d) => ({ box: d.boundingBox, label: d.label.replace(/ #\d+$/, ""), color: "#fff", width: 2 })), W, H),
  });
  s.panel.append(
    el("button.button.primary", { onclick: () => check.setBaseline(labels) }, "Remember what is here"), " ",
    el("button.button", { onclick: () => check.clear() }, "Forget"), seen, banner,
    el("p", {}, el("label", {}, el("input", { type: "checkbox", checked: true, onchange: (e) => { check.ignored = e.target.checked ? new Set(["person"]) : new Set(); } }), " Ignore people")),
    el("p", {}, el("label", {}, el("input", { type: "checkbox", checked: sound, onchange: (e) => { sound = e.target.checked; store.set("missing.sound", sound ? "1" : "0"); } }), " Sound alerts")),
    el("p.small.muted", {}, "Low beep: something is missing. Two high beeps: something extra."));
}

// MARK: Plate gate

const CARS = new Set(["car", "truck", "bus", "motorcycle"]);

export function plateGate(view, app) {
  const gate = new GateBarrier();
  let allowed = JSON.parse(store.get("plates.allowed", '["ABC-1234"]')), automatic = true, reading = false, lastRead = -9, vehicles = [], plateBox = null, lastPlate = null, latest = null, log = [];
  const canvas = el("canvas", { width: 300, height: 150, style: { width: "100%", background: "#222", borderRadius: "12px" } });
  const plate = el("div", { style: { fontSize: "30px", fontWeight: 800, border: "3px solid currentColor", borderRadius: "8px", display: "inline-block", padding: "2px 10px", margin: "8px 0" } }, "—");
  const verdict = el("p", { style: { fontWeight: 700 } }, "No plate read yet"), list = el("ul.list"), logList = el("ul.list"), input = el("input", { type: "text", placeholder: "AA-00-AA" });
  const textHere = () => app.canUse(TextReader.detectorName) && app.canUse(TextReader.recognizerName);
  const fillAllowed = () => list.replaceChildren(...allowed.map((p) => el("li", {}, el("span.grow", {}, p), el("button.button", { onclick: () => { allowed = allowed.filter((x) => x !== p); store.set("plates.allowed", JSON.stringify(allowed)); fillAllowed(); } }, "Remove"))));
  const drawGate = () => {
    const c = canvas.getContext("2d"), st = gate.display(performance.now() / 1000), a = (st.angle * Math.PI) / 180;
    c.clearRect(0, 0, 300, 150); c.fillStyle = "#888"; c.fillRect(30, 70, 18, 70);
    c.save(); c.translate(39, 80); c.rotate(-a); c.fillStyle = "#fff"; c.fillRect(0, -6, 230, 12); c.fillStyle = "#ff3b30";
    for (let x = 25; x < 230; x += 45) c.fillRect(x, -6, 20, 12);
    c.restore();
    c.fillStyle = st.state === "denied" ? "#ff3b30" : st.state === "open" || st.state === "opening" ? "#34c759" : "#8e8e93";
    c.beginPath(); c.arc(270, 30, 10, 0, 7); c.fill();
  };
  const gateTimer = setInterval(drawGate, 50);
  async function readNow() {
    if (!latest || reading) return;
    reading = true; lastRead = performance.now() / 1000;
    const regions = vehicles.length ? vehicles.map((v) => v.boundingBox) : [{ x: 0, y: 0, width: 1, height: 1 }];
    let best = null;
    try {
      for (const r of regions) {
        const crop = cropToCanvas(latest, r);
        for (const t of await TextReader.read(crop, app.engine)) {
          const p = PlateText.normalize(t.text);
          if (!p || (best && t.confidence <= best.confidence)) continue;
          const xs = t.corners.map((c) => c.x), ys = t.corners.map((c) => c.y);
          best = { text: p, confidence: t.confidence, box: { x: r.x + Math.min(...xs) * r.width, y: r.y + Math.min(...ys) * r.height, width: (Math.max(...xs) - Math.min(...xs)) * r.width, height: (Math.max(...ys) - Math.min(...ys)) * r.height } };
        }
      }
    } finally { reading = false; }
    if (!best) return;
    const ok = allowed.includes(best.text), now = performance.now() / 1000, changed = lastPlate?.text !== best.text;
    lastPlate = { text: best.text, ok }; plateBox = best.box;
    plate.textContent = best.text; plate.style.color = ok ? "var(--ok)" : "var(--bad)";
    verdict.textContent = ok ? "✓ Allowed: barrier opens" : "✕ Not on the list";
    if (changed || gate.display(now).state === "closed") {
      if (ok) { gate.open(now); Tone.chime(); } else { gate.deny(now); Tone.play(220, 0.4, { bright: true, volume: 0.4 }); }
      // The barrier reopens for a car that stays (as the demo), but the log notes it once per 30 s.
      const lastLog = log[log.length - 1];
      if (!(lastLog && lastLog.plate === best.text && Date.now() - lastLog.time < 30000)) {
        log.push({ time: Date.now(), plate: best.text, ok });
        logList.replaceChildren(...log.slice(-8).reverse().map((e) => el("li", {}, el("span.small.muted", {}, new Date(e.time).toLocaleTimeString()), el("span.grow", {}, e.plate), e.ok ? "✓" : "✕")));
      }
    }
  }
  const s = exampleScreen(view, app, {
    title: "Plate gate", intro: "Reads number plates and opens the barrier for the allowed ones.", task: "detection", models: detectionModels(app),
    sources: ["picture", "back", "front", "video", "stream"], samples: [["Car plate ABC-1234", "plate_sample.png"], ["Street with a bus", "bus.jpg"]], modelKey: "plates",
    extras: () => (textHere() ? [TextReader.detectorName, TextReader.recognizerName] : []),
    onFrame: (f) => {
      latest = f.image;
      vehicles = f.result.value.filter((d) => CARS.has(d.label.replace(/ #\d+$/, "")) && d.confidence >= 0.4);
      if (automatic && textHere() && performance.now() / 1000 - lastRead > 2 && (vehicles.length || s.runner.source === "picture")) readNow();
    },
    draw: (ctx, W, H) => drawBoxes(ctx, [...vehicles.map((v) => ({ box: v.boundingBox, label: v.label, color: "#64d2ff", width: 2 })),
      ...(plateBox ? [{ box: plateBox, label: lastPlate?.text ?? "", color: lastPlate?.ok ? "#34c759" : "#ff3b30" }] : [])], W, H),
  });
  s.panel.append(canvas, plate, verdict,
    el("div.toolbar", {}, el("button.button.primary", { onclick: () => readNow() }, "Read plate"), el("label", {}, el("input", { type: "checkbox", checked: true, onchange: (e) => { automatic = e.target.checked; } }), " Automatic")),
    textHere() ? "" : el("p.error.small", {}, "Reading plates needs the text models ocr_det and ocr."),
    el("h2", {}, "Allowed plates"), list,
    el("div.toolbar", {}, input, el("button.button", { onclick: () => { const p = PlateText.normalize(input.value); if (p && !allowed.includes(p)) { allowed.push(p); store.set("plates.allowed", JSON.stringify(allowed)); fillAllowed(); input.value = ""; } } }, "Add")),
    el("h2", {}, "Log"), logList);
  fillAllowed();
  view.addEventListener("detach", () => clearInterval(gateTimer));
}

// MARK: Edge vs cloud

export function edgeCloud(view, app) {
  let recent = [], frames = 0, connect = null, online = false;
  const body = el("div");
  // The network time: how long a connection to 1.1.1.1 takes, every 2 s. A browser cannot open raw
  // connections, so it times a tiny HTTPS request (no data from this page is sent).
  // The page is cross-origin isolated, so the browser refuses the (opaque) answer, but only after it has
  // arrived: the time to settle is still the round trip.
  const probe = async () => {
    online = navigator.onLine;
    if (!online) { connect = null; return; }
    const t = performance.now();
    await fetch(`https://1.1.1.1/cdn-cgi/trace?${Date.now()}`, { mode: "no-cors", cache: "no-store" }).catch(() => null);
    connect = (performance.now() - t) / 2;
  };
  probe();
  const probeTimer = setInterval(probe, 2000);
  const s = exampleScreen(view, app, {
    title: "Edge vs cloud", intro: "Every frame detected here, measured, next to an estimate of sending it to a cloud vision API.", task: "detection",
    models: detectionModels(app), sources: ["back", "front", "video", "stream", "picture"], samples: STREET, modelKey: "edgecloud", track: false,
    onFrame: (f) => {
      recent = [...recent, f.inferenceMs].slice(-30); frames++;
      const c = EdgeCloud.compare({ edgeMilliseconds: recent.reduce((a, b) => a + b, 0) / recent.length, framesPerSecond: s.runner.fps, frames, connectMilliseconds: connect });
      const usd = (v, d = 2) => `US$${v.toFixed(d)}`;
      const row = (title, here, cloud, hb, cb) => el("tr", {}, el("td.small.muted", {}, title),
        el("td", {}, el("b", {}, here), hb != null ? el("div.bar", {}, el("span", { style: { width: `${Math.min(100, hb * 100)}%`, background: "var(--ok)" } })) : null),
        el("td", {}, el("b", {}, cloud), cb != null ? el("div.bar", {}, el("span", { style: { width: `${Math.min(100, cb * 100)}%`, background: "#ff9f0a" } })) : null));
      body.replaceChildren(el("table", {},
        el("tr", {}, el("th", {}, ""), el("th", { style: { color: "var(--ok)" } }, `Here (${backendName()})`), el("th", { style: { color: "#ff9f0a" } }, "Cloud API")),
        row("Time per picture", `${c.edgeMilliseconds.toFixed(0)} ms`, c.cloud ? `${c.cloud.toFixed(0)} ms (estimate)` : "offline: not available", c.edgeMilliseconds / 1000, (c.cloud ?? 1000) / 1000),
        row("of which network", "0 ms (no network)", c.network != null ? `${c.network.toFixed(0)} ms (measured)` : "—", 0, (c.network ?? 0) / 1000),
        row("Speed", `${c.framesPerSecond.toFixed(0)} pictures/s`, c.cloudFramesPerSecond ? `${c.cloudFramesPerSecond.toFixed(1)} pictures/s` : "—", c.framesPerSecond / 60, (c.cloudFramesPerSecond ?? 0) / 60),
        row("Pictures so far", c.frames.toLocaleString(), c.frames.toLocaleString()),
        row("Cost so far", "0 (nothing to pay)", usd(c.dollarsSoFar), 0, c.dollarsSoFar / 5),
        row("A month at this speed", "0", usd(c.dollarsPerMonth, 0)),
        row("Where the picture goes", "stays in this browser", "uploaded to someone else's server")),
        c.speedup ? el("p", { style: { fontSize: "20px", fontWeight: 800, color: "var(--ok)" } }, `${c.speedup.toFixed(0)}× faster per picture here`) : "",
        el("p.small.muted", {}, `Network: ${online ? "online" : "offline"}. The cloud's server time (${EdgeCloud.cloudServerMilliseconds} ms) and price (US$${EdgeCloud.cloudDollarsPerThousand} per 1000 pictures) are typical reference values; the network time is measured every 2 s with a small request to 1.1.1.1. A month = 8 h a day, 22 days.`));
    },
    draw: (ctx, W, H, f) => drawBoxes(ctx, f.result.value.filter((d) => d.confidence >= 0.4).map((d) => ({ box: d.boundingBox, label: d.label, color: "#34c759", width: 2 })), W, H),
  });
  s.panel.append(body, el("button.button", { onclick: () => { frames = 0; } }, "Reset counters"));
  view.addEventListener("detach", () => clearInterval(probeTimer));
}

// MARK: Face check-in

export function faceCheckIn(view, app) {
  // Each recognition model keeps its own list of people: their vectors cannot be compared.
  const embedders = FaceRecognition.embedderNames.filter((n) => app.canUse(n));
  FaceRecognition.embedderName = embedders.includes(store.get("checkin.embedder")) ? store.get("checkin.embedder") : embedders[0] ?? FaceRecognition.embedderName;
  const galleryKey = () => (FaceRecognition.embedderName === FaceRecognition.embedderNames[0] ? "faces.gallery" : `faces.gallery-${FaceRecognition.embedderName}`);
  const openGallery = () => {
    const g = new FaceGallery(JSON.parse(store.get(galleryKey(), "{}")));
    g.threshold = Number(store.get("faces.threshold", 0.45));
    return g;
  };
  let gallery = openGallery();
  const book = new CheckInBook();
  let enrolling = null, people = [], showScore = false;
  const count = el("div.big-number", { style: { color: "var(--ok)" } }, "0"), checked = el("ul.list"), enrolled = el("ul.list"), info = el("p.small");
  const save = () => store.set(galleryKey(), JSON.stringify(gallery));
  const fill = () => {
    count.textContent = book.checked.length;
    checked.replaceChildren(...book.checked.map((c) => el("li", {}, el("span.small.muted", {}, c.time.toLocaleTimeString()), el("span.grow", {}, c.name), "✓")));
    enrolled.replaceChildren(...(gallery.names.length ? gallery.names.map((n) => el("li", {}, el("span.grow", {}, n), el("button.button", { onclick: () => { gallery.remove(n); save(); fill(); } }, "Remove"))) : [el("li.muted", {}, "Nobody yet.")]));
  };
  const s = exampleScreen(view, app, {
    title: "Face check-in", intro: "Enrol people once; then they are checked in when the camera sees them.", task: "face",
    // Recognition aligns faces by their landmarks, which LightFace does not give.
    models: modelsFor("face", app).filter(findsLandmarks),
    // The list in use cannot change under a running camera.
    beforeStart: () => { embedder.disabled = true; }, onStop: () => { embedder.disabled = false; },
    sources: ["front", "back", "video", "picture"], samples: [VIDEOS.face, ["Street with people", "bus.jpg"]], modelKey: "checkin", analyse: faceAnalysis(),
    onFrame: (f) => {
      people = f.people.map((p) => { const m = confidentMatch(gallery, p.embedding); return { ...p, match: m }; });
      if (enrolling) {
        const biggest = people.reduce((a, p) => (!a || p.face.boundingBox.width > a.face.boundingBox.width ? p : a), null);
        if (biggest) enrolling.samples.push(biggest.embedding);
        info.textContent = `Enrolling ${enrolling.name}: ${enrolling.samples.length} / 8 — look at the camera`;
        if (enrolling.samples.length >= 8 || f.time - enrolling.started > 6) {
          const v = averageEmbedding(enrolling.samples);
          if (v) { gallery.set(enrolling.name, v); save(); info.textContent = `${enrolling.name} enrolled.`; Tone.chime(); } else info.textContent = "No face seen; try again.";
          enrolling = null; fill();
        }
        return;
      }
      for (const name of book.update(new Set(people.filter((p) => p.match).map((p) => p.match.name)), f.time)) { info.textContent = `Welcome, ${name}!`; Tone.chime(); }
      fill();
    },
    draw: (ctx, W, H) => drawFaces(ctx, people.map((p) => ({ ...p.face, name: p.match ? `${p.match.name}${showScore ? ` ${p.match.similarity.toFixed(2)}` : ""}` : undefined })), W, H),
  });
  const embedder = el("select", { "aria-label": "Recognition model", onchange: () => {
    FaceRecognition.embedderName = embedder.value; store.set("checkin.embedder", embedder.value);
    gallery = openGallery(); slider.value = gallery.threshold; fill();
  } }, embedders.map((n) => el("option", { value: n, selected: n === FaceRecognition.embedderName }, n)));
  const name = el("input", { type: "text", placeholder: "Name" });
  const slider = el("input", { type: "range", min: 0.3, max: 0.7, step: 0.01, value: gallery.threshold, oninput: () => { gallery.threshold = Number(slider.value); store.set("faces.threshold", slider.value); label.textContent = `Match at ${gallery.threshold.toFixed(2)} similarity or more`; } });
  const label = el("span", {}, `Match at ${gallery.threshold.toFixed(2)} similarity or more`);
  s.panel.append(count, el("span.muted", {}, " checked in"), checked,
    el("div.toolbar", {}, el("button.button", { onclick: () => { book.reset(performance.now() / 1000); fill(); } }, "Clear the list"),
      el("button.button", { onclick: () => { const csv = "name,time\n" + book.checked.map((c) => `${c.name},${c.time.toISOString()}`).join("\n"); el("a", { href: URL.createObjectURL(new Blob([csv], { type: "text/csv" })), download: "check-in.csv" }).click(); } }, "Export")),
    el("h2", {}, "Enrol a face"), el("div.toolbar", {}, name, el("button.button.primary", { onclick: () => { if (!name.value.trim() || !s.runner.running) { info.textContent = "Start the camera and type a name first."; return; } enrolling = { name: name.value.trim(), samples: [], started: s.last?.time ?? 0 }; name.value = ""; } }, "Enrol")),
    info, el("h2", {}, "Enrolled"), el("label.small", {}, "Recognition model ", embedder), enrolled, label, slider,
    el("label.small", {}, el("input", { type: "checkbox", onchange: (e) => { showScore = e.target.checked; } }), " Show similarity"),
    el("p.small.muted", {}, "Only a 512-number identity vector is kept per person, in this browser; never a photo."));
  fill();
}

export { ObjectTracker, run };
