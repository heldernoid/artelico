// The pose examples (UGen300 demos Y2, Y4, Y3, Y5, WakeUp, Classroom). Rules in js/rules/pose-games.js.
import { el, store } from "../common.js";
import { exampleScreen, poseModels, poseAnalysis, Tone } from "./kit.js";
import { drawPoses, drawBoxes } from "../../core/render.js";
import { VIDEOS } from "../hailo-videos.js";
import { BodyPose, raisedHands, GestureController, HandRaiseCounter, AirInstrument, YogaRound, SquatCounter, Attention, AttentionPerson, K } from "../../rules/pose-games.js";

const SAMPLES = [["Street with people", "bus.jpg"], VIDEOS.office, VIDEOS.street];
const bodies = (f, width = 640) => f.poses.map((p) => BodyPose.from(p, f.width / f.height, width));

// MARK: Raise hand to flip (Y2)

const SLIDES = [
  ["Raise hand to flip", "Right hand up: next slide. Left hand up: previous.", "#29144d", "#6b2a7a"],
  ["Hold it a moment", "The hand must stay up for a few frames, then come down before the next flip.", "#0b3d5c", "#1e6f9f"],
  ["Start over", "Both hands up brings you back to the first slide.", "#5a2108", "#d9732a"],
  ["Nothing leaves this browser", "The pose model runs right here. The camera picture is not sent anywhere.", "#4d0f33", "#992659"],
  ["Your own slides", "Open a PDF or pictures to present them the same way.", "#232326", "#5a5a66"],
];

export function slides(view, app) {
  let index = 0, flash = "", own = null;
  const control = new GestureController();
  const slide = el("div", { style: { borderRadius: "14px", padding: "28px", color: "#fff", minHeight: "260px", display: "flex", flexDirection: "column", justifyContent: "center" } });
  const counter = el("p.small.muted");
  const files = el("input", { type: "file", accept: "image/*,application/pdf", multiple: true, hidden: true, onchange: async () => { own = await loadSlides([...files.files]); index = 0; show(); } });
  function show() {
    const list = own ?? SLIDES;
    index = Math.max(0, Math.min(list.length - 1, index));
    slide.replaceChildren();
    if (own) {
      slide.style.background = "#000"; slide.style.padding = "0";
      slide.append(el("img", { src: own[index], style: { width: "100%", borderRadius: "14px" } }));
    } else {
      const [title, text, a, b] = list[index];
      slide.style.background = `linear-gradient(135deg, ${a}, ${b})`; slide.style.padding = "28px";
      slide.append(el("h2", { style: { fontSize: "30px", margin: 0 } }, title), el("p", { style: { fontSize: "18px" } }, text));
    }
    counter.textContent = `Slide ${index + 1} of ${list.length}${flash ? ` · ${flash}` : ""}`;
  }
  const s = exampleScreen(view, app, {
    title: "Raise hand to flip", intro: "Raise your right hand for the next slide, your left for the previous one, both to start over.",
    task: "pose", models: poseModels(app), sources: ["front", "back", "video", "picture"], samples: SAMPLES, modelKey: "slides",
    analyse: poseAnalysis(),
    onFrame: (f) => {
      const big = f.poses.reduce((a, p) => (!a || p.boundingBox.width * p.boundingBox.height > a.boundingBox.width * a.boundingBox.height ? p : a), null);
      const gesture = big ? raisedHands(BodyPose.from(big, f.width / f.height)) : "none";
      const action = control.update(swapSides(gesture, s.runner.mirrored), f.time);
      if (action) {
        index = action === "next" ? index + 1 : action === "previous" ? index - 1 : 0;
        flash = { next: "→ next", previous: "← previous", restart: "↺ first slide" }[action];
        Tone.play(action === "restart" ? 520 : 880, 0.12, { bright: true, volume: 0.2 });
        show();
      }
    },
    draw: (ctx, W, H, f) => drawPoses(ctx, f.poses, W, H),
  });
  s.panel.append(slide, counter, el("div.toolbar", { style: { marginTop: "10px" } },
    el("button.button", { onclick: () => { index--; show(); } }, "←"), el("button.button", { onclick: () => { index++; show(); } }, "→"),
    el("button.button", { onclick: () => files.click() }, "Open slides…"), files));
  show();
}

/** The model sees the front camera's mirrored picture, where a right hand looks like a left one: swap back. */
const swapSides = (g, mirrored) => (mirrored ? { left: "right", right: "left" }[g] ?? g : g);

async function loadSlides(files) {
  const urls = [];
  for (const f of files) {
    if (f.type === "application/pdf") {
      // PDF pages rendered with pdf.js (loaded on first use).
      const pdfjs = await import("https://cdn.jsdelivr.net/npm/pdfjs-dist@4.10.38/build/pdf.min.mjs");
      pdfjs.GlobalWorkerOptions.workerSrc = "https://cdn.jsdelivr.net/npm/pdfjs-dist@4.10.38/build/pdf.worker.min.mjs";
      const doc = await pdfjs.getDocument({ data: await f.arrayBuffer() }).promise;
      for (let p = 1; p <= doc.numPages; p++) {
        const page = await doc.getPage(p), vp = page.getViewport({ scale: 1.5 });
        const c = Object.assign(document.createElement("canvas"), { width: vp.width, height: vp.height });
        await page.render({ canvasContext: c.getContext("2d"), viewport: vp }).promise;
        urls.push(c.toDataURL("image/jpeg", 0.85));
      }
    } else urls.push(URL.createObjectURL(f));
  }
  return urls.length ? urls : null;
}

// MARK: Hand-raise counter (Y4)

export function handCounter(view, app) {
  const big = el("div.big-number", {}, "0"), sub = el("p.muted");
  let best = 0;
  const s = exampleScreen(view, app, {
    title: "Hand-raise counter", intro: "Counts the people with a hand up: votes, quizzes, questions.", task: "pose", models: poseModels(app),
    samples: SAMPLES, modelKey: "handcount", analyse: poseAnalysis(),
    onFrame: (f) => {
      const { raised, total } = HandRaiseCounter.count(bodies(f));
      big.textContent = raised; sub.textContent = `of ${total} ${total === 1 ? "person" : "people"} · most so far ${(best = Math.max(best, raised))}`;
    },
    draw: (ctx, W, H, f) => {
      const b = bodies(f);
      drawPoses(ctx, f.poses.filter((_, i) => HandRaiseCounter.isRaised(b[i])), W, H, "#34c759");
      drawPoses(ctx, f.poses.filter((_, i) => !HandRaiseCounter.isRaised(b[i])), W, H, "#8e8e93");
    },
  });
  s.panel.append(el("h2", { style: { marginTop: 0 } }, "Hands up"), big, sub, el("button.button", { onclick: () => { best = 0; } }, "Reset"));
}

// MARK: Air instrument (Y3)

const SCALE = [["Do", 261.63], ["Re", 293.66], ["Mi", 329.63], ["Sol", 392.0], ["La", 440.0]];

export function airInstrument(view, app) {
  const instrument = new AirInstrument(SCALE.length);
  const lit = new Map();
  const keys = el("div", { style: { display: "grid", gridTemplateColumns: `repeat(${SCALE.length}, 1fr)`, gap: "6px" } },
    SCALE.map(([n]) => el("div.panel", { style: { textAlign: "center", padding: "16px 0", background: "var(--panel-2)" } }, n)));
  exampleScreen(view, app, {
    title: "Air instrument", intro: "Move a hand across the picture: each of the five strips plays a note.", task: "pose", models: poseModels(app),
    samples: SAMPLES, modelKey: "air", analyse: poseAnalysis(),
    onFrame: (f) => {
      for (const zone of instrument.update(bodies(f), 0.5, f.time)) { Tone.piano(SCALE[zone][1]); lit.set(zone, f.time); }
      [...keys.children].forEach((k, i) => { k.style.background = f.time - (lit.get(i) ?? -9) < 0.3 ? "var(--accent)" : "var(--panel-2)"; k.style.color = f.time - (lit.get(i) ?? -9) < 0.3 ? "var(--accent-text)" : ""; });
    },
    draw: (ctx, W, H, f) => {
      for (let i = 0; i < SCALE.length; i++) {
        ctx.fillStyle = f.time - (lit.get(i) ?? -9) < 0.3 ? "rgba(197,138,216,0.35)" : i % 2 ? "rgba(255,255,255,0.06)" : "rgba(0,0,0,0.06)";
        ctx.fillRect((i * W) / SCALE.length, 0, W / SCALE.length, H);
        ctx.fillStyle = "#fff"; ctx.font = "700 20px system-ui"; ctx.fillText(SCALE[i][0], (i * W) / SCALE.length + 12, 30);
      }
      drawPoses(ctx, f.poses, W, H);
      ctx.fillStyle = "#ffd60a";
      for (const p of f.poses) for (const k of [K.leftWrist, K.rightWrist]) if (p.keypoints[k].confidence >= 0.5) { ctx.beginPath(); ctx.arc(p.keypoints[k].position.x * W, p.keypoints[k].position.y * H, 10, 0, 7); ctx.fill(); }
    },
  }).panel.append(el("h2", { style: { marginTop: 0 } }, "Notes"), keys, el("p.small.muted", {}, "Several people can play together; each wrist plays when it enters a new strip."));
}

// MARK: Yoga coach (Y5)

export function yoga(view, app) {
  let hold = Number(store.get("yoga.hold", 8));
  let round = new YogaRound(undefined, hold);
  const title = el("h2", { style: { marginTop: 0 } }), steps = el("ol"), ring = el("div.big-number"), hint = el("p", { style: { fontWeight: 600 } }), progress = el("p.muted");
  const holdLabel = el("span");
  const setHold = (v) => { hold = Math.max(3, Math.min(30, v)); store.set("yoga.hold", hold); holdLabel.textContent = `Hold for ${hold} s`; round = new YogaRound(undefined, hold); };
  setHold(hold);
  exampleScreen(view, app, {
    title: "Yoga coach", intro: "Six poses in random order; hold each one to move on.", task: "pose", models: poseModels(app),
    samples: SAMPLES, modelKey: "yoga", analyse: poseAnalysis(),
    onFrame: (f) => {
      const big = f.poses.reduce((a, p) => (!a || p.boundingBox.width * p.boundingBox.height > a.boundingBox.width * a.boundingBox.height ? p : a), null);
      const st = round.update(big ? BodyPose.from(big, f.width / f.height) : null, f.time);
      if (st.justCompletedPose) Tone.chime();
      progress.textContent = `${st.completed} / ${st.total} done`;
      if (st.finished) { title.textContent = "All done! 🎉"; steps.replaceChildren(); ring.textContent = "✓"; hint.textContent = ""; return; }
      const c = st.coach;
      title.textContent = c.title;
      steps.replaceChildren(...c.steps.map((x) => el("li", {}, x)));
      ring.textContent = st.celebrating ? "✓" : `${Math.ceil(c.target - c.held)} s`;
      ring.style.color = c.inPose || st.celebrating ? "var(--ok)" : "";
      hint.textContent = st.celebrating ? "Well done!" : c.inPose ? "Hold it…" : c.hint;
    },
    draw: (ctx, W, H, f) => drawPoses(ctx, f.poses, W, H),
  }).panel.append(title, steps, ring, hint, progress,
    el("div.toolbar", {}, el("button.button", { onclick: () => round.skip() }, "Skip"), el("button.button", { onclick: () => round.restart() }, "Restart")),
    el("div.toolbar", {}, holdLabel, el("button.button", { onclick: () => setHold(hold - 1) }, "−"), el("button.button", { onclick: () => setHold(hold + 1) }, "+")));
}

// MARK: Squat alarm (WakeUp)

export function squatAlarm(view, app) {
  let target = Number(store.get("squat.target", 5));
  let counter = new SquatCounter(target), ringing = false, ringTimer = null, alarmAt = null;
  const big = el("div.big-number"), phase = el("p.muted"), state = el("p", { style: { fontWeight: 600 } });
  const time = el("input", { type: "time", value: store.get("squat.time", "07:00"), onchange: () => store.set("squat.time", time.value) });
  const update = () => { big.textContent = `${counter.count} / ${target}`; };
  const ring = () => { if (ringing) return; ringing = true; counter.reset(); state.textContent = `⏰ Do ${target} squats to stop the alarm!`; ringTimer = setInterval(() => Tone.alarm(), 1200); };
  const stopRing = () => { ringing = false; clearInterval(ringTimer); state.textContent = "Alarm stopped. Good morning!"; Tone.chime(); };
  const armTimer = setInterval(() => {
    if (!alarmAt) return;
    const now = new Date(), hh = String(now.getHours()).padStart(2, "0"), mm = String(now.getMinutes()).padStart(2, "0");
    if (`${hh}:${mm}` === alarmAt && !ringing) { alarmAt = null; ring(); }
  }, 1000);
  const s = exampleScreen(view, app, {
    title: "Squat alarm", intro: "The alarm only stops after your squats. Keep this page open: browsers cannot ring from a closed tab.", task: "pose",
    models: poseModels(app), samples: [VIDEOS.squats, ...SAMPLES], modelKey: "squat", analyse: poseAnalysis(),
    onFrame: (f) => {
      const big2 = f.poses.reduce((a, p) => (!a || p.boundingBox.width * p.boundingBox.height > a.boundingBox.width * a.boundingBox.height ? p : a), null);
      const st = counter.update(big2 ? BodyPose.from(big2, f.width / f.height) : null);
      if (st.justCounted) Tone.play(660 + 80 * st.count, 0.15, { bright: true });
      phase.textContent = st.visible ? `${st.phase === "down" ? "Down" : "Up"} · knees ${Math.round(st.angle)}°` : "Show your whole body to the camera";
      update();
      if (ringing && st.done) stopRing();
    },
    onStop: () => {},
    draw: (ctx, W, H, f) => drawPoses(ctx, f.poses, W, H),
  });
  s.panel.append(el("h2", { style: { marginTop: 0 } }, "Squats"), big, phase, state,
    el("div.toolbar", {}, el("label", {}, "Wake at ", time), el("button.button.primary", { onclick: () => { alarmAt = time.value; state.textContent = `Alarm set for ${time.value}.`; } }, "Set alarm")),
    el("div.toolbar", {}, el("button.button", { onclick: () => ring() }, "Ring now"), el("button.button", { onclick: () => { if (ringing) stopRing(); counter.reset(); update(); } }, "Reset"),
      el("label", {}, "Squats ", el("input", { type: "number", min: 1, max: 30, value: target, style: { width: "64px" }, onchange: (e) => { target = Math.max(1, Number(e.target.value)); store.set("squat.target", target); counter = new SquatCounter(target); update(); } }))));
  update();
  view.addEventListener("detach", () => { clearInterval(armTimer); clearInterval(ringTimer); });
}

// MARK: Classroom

const PHONE_MODELS = ["yolov8s", "yolov11m", "yolov8m", "yolov11s"];

export function classroom(view, app) {
  const people = new Map();
  const enabled = new Set(Attention.priority);
  let usePhones = store.get("classroom.phones", "1") === "1";
  let history = [];
  const stats = el("div", { style: { display: "flex", gap: "18px" } });
  const grid = el("div", { style: { display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: "4px" } });
  const states = el("ul.list");
  const chart = el("canvas", { width: 300, height: 80, style: { width: "100%" } });
  const detector = () => (usePhones ? PHONE_MODELS.find((m) => app.canUse(m)) : null);
  exampleScreen(view, app, {
    title: "Classroom", intro: "Raised hands by seat and attention over time. Nobody is identified and nothing is recorded.", task: "pose",
    models: poseModels(app), samples: SAMPLES, modelKey: "classroom", extras: () => [detector()].filter(Boolean),
    analyse: poseAnalysis({ detector }),
    onFrame: (f) => {
      const W = 1280, H = (1280 * f.height) / f.width, list = bodies(f, W);
      const infos = list.map((b, i) => ({ id: f.poses[i].trackID ?? i, box: Attention.box(b), shoulderY: Attention.shoulderLine(b)?.y, shoulderWidth: Attention.shoulderLine(b)?.width, wrists: Attention.wrists(b) }));
      const phones = f.objects.filter((d) => d.label === "cell phone" && d.confidence >= 0.3).map((d) => ({ x: d.boundingBox.x * W, y: d.boundingBox.y * H, width: d.boundingBox.width * W, height: d.boundingBox.height * H }));
      const assigned = Attention.assignPhones(phones, infos), seen = new Set();
      list.forEach((b, i) => {
        const id = infos[i].id; seen.add(id);
        if (!people.has(id)) people.set(id, new AttentionPerson());
        people.get(id).update(b, assigned.get(id) ?? [], enabled, f.time, infos[i].box);
      });
      for (const id of [...people.keys()]) if (!seen.has(id)) people.delete(id);
      const sum = Attention.summarize([...people.values()], W, H), total = people.size;
      const attention = total ? Math.round(((total - sum.inattentive) / total) * 100) : 100;
      history = [...history, { t: f.time, v: attention }].filter((p) => f.time - p.t <= 60);
      stats.replaceChildren(...[[total, "people"], [sum.raised, "hands up"], [`${attention}%`, "attention"]].map(([v, l]) => el("div", {}, el("div", { style: { fontSize: "34px", fontWeight: 800 } }, String(v)), el("div.small.muted", {}, l))));
      grid.replaceChildren(...sum.grid.flat().map((n) => el("div", { style: { textAlign: "center", padding: "10px 0", borderRadius: "8px", background: n ? "var(--ok)" : "var(--panel-2)", color: n ? "#fff" : "" } }, n ? `✋ ${n}` : "")));
      states.replaceChildren(...Attention.priority.map((st) => el("li", {}, el("span.grow", {}, Attention.STATES[st]), el("b", {}, String(sum.byState[st] ?? 0)),
        el("input", { type: "checkbox", checked: enabled.has(st), onchange: (e) => (e.target.checked ? enabled.add(st) : enabled.delete(st)) }))));
      const c = chart.getContext("2d");
      c.clearRect(0, 0, 300, 80); c.strokeStyle = "#34c759"; c.lineWidth = 2; c.beginPath();
      history.forEach((p, i) => { const x = ((p.t - history[0].t) / 60) * 300, y = 78 - (p.v / 100) * 76; i ? c.lineTo(x, y) : c.moveTo(x, y); });
      c.stroke();
    },
    draw: (ctx, W, H, f) => {
      const colors = { ok: "#34c759", phone: "#ff375f", sleeping: "#8e8e93", head_down: "#64d2ff", turned: "#bf5af2" };
      for (const p of f.poses) {
        const person = people.get(p.trackID);
        drawPoses(ctx, [p], W, H, person?.raised ? "#ffd60a" : colors[person?.state ?? "ok"]);
      }
      drawBoxes(ctx, f.objects.filter((d) => d.label === "cell phone" && d.confidence >= 0.3).map((d) => ({ box: d.boundingBox, label: "phone", color: "#ff375f", width: 2 })), W, H);
    },
  }).panel.append(stats, el("h2", {}, "Raised hands by seat"), grid, el("p.small.muted", {}, "Back of the room at the top, as the camera sees it."),
    el("h2", {}, "Not paying attention"), states,
    el("label.small", {}, el("input", { type: "checkbox", checked: usePhones, onchange: (e) => { usePhones = e.target.checked; store.set("classroom.phones", usePhones ? "1" : "0"); } }), ` Look for phones (${PHONE_MODELS.find((m) => app.canUse(m)) ?? "needs a detection model"}; applies at the next Start)`),
    el("h2", {}, "Attention, last 60 seconds"), chart);
}

export { swapSides };
