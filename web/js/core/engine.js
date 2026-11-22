// Runs models in the browser with ONNX Runtime Web (WebGPU, or WebAssembly where WebGPU is missing).
// Port of StudioCore/CoreMLEngine.swift: it takes the same 8-bit RGB frames as the stick and returns
// outputs in the stick's layout (through <name>.native.json), so the decoders work unchanged. Every
// output here is plain float values (no quantization).
import * as ort from "../../vendor/ort-1.30.0/ort.webgpu.min.mjs";
import { hasDeviceNMS } from "./catalog.js";

ort.env.wasm.wasmPaths = new URL("../../vendor/ort-1.30.0/", import.meta.url).href;
ort.env.logLevel = "error";

/** An output in the stick's layout: values in NHWC order (or the NMS_BY_CLASS list). */
export class Tensor {
  constructor(stream, values) { this.stream = stream; this.values = values; }
  get height() { return this.stream.height ?? 1; }
  get width() { return this.stream.width ?? 1; }
  get features() { return this.stream.features ?? 1; }
  floats() { return this.values; }
}

export const backend = { name: "" };
/** "auto" (WebGPU when there is one) or "wasm". `?backend=wasm` in the address chooses WebAssembly. */
export const settings = {
  backend: new URLSearchParams(self.location?.search ?? "").get("backend") ?? "auto",
  /** Models whose WebGPU results differ from WebAssembly's (measured with compare.html): WebAssembly only. */
  wasmOnly: new Set(),
};

async function createSession(bytes, providers = navigator.gpu && settings.backend !== "wasm" ? ["webgpu", "wasm"] : ["wasm"]) {
  let lastError;
  for (const provider of providers) {
    try {
      const session = await ort.InferenceSession.create(bytes, { executionProviders: [provider], graphOptimizationLevel: "all", logSeverityLevel: 3 });
      session.provider = provider;
      backend.name = provider;
      return session;
    } catch (error) { lastError = error; }
  }
  throw lastError;
}

/** Core ML conversion renamed graph names ("/model.22/cv2.0/Conv_output_0" -> "_model_22_cv2_0_Conv_output_0"). */
const sanitized = (name) => name.replace(/[^A-Za-z0-9_]/g, "_");

export class OnnxEngine {
  constructor(source) {
    /** Where models come from: { fetch(name, ext, onProgress) -> ArrayBuffer | null }. */
    this.source = source;
    this.loaded = new Map();
    this.primary = null;
  }

  get loadedModel() { return this.primary ? this.loaded.get(this.primary)?.info : undefined; }
  get loadedModelNames() { return [...this.loaded.keys()]; }

  /** Loads `info` (and its .native.json map when there is one). `primary` false adds it next to the main one. */
  async load(info, { primary = true, onProgress } = {}) {
    if (!this.loaded.has(info.name)) {
      const [bytes, mapBytes] = await Promise.all([
        this.source.fetch(info.name, "onnx", onProgress),
        this.source.fetch(info.name, "native.json").catch(() => null),
      ]);
      if (!bytes) throw new Error(`${info.name} is not in the models folder.`);
      const map = mapBytes ? JSON.parse(new TextDecoder().decode(mapBytes)) : null;
      const data = new Uint8Array(bytes);
      const session = await createSession(data, settings.wasmOnly.has(info.name) ? ["wasm"] : undefined);
      // A native model can differ from the stick's (input size, output shape); its own description wins.
      this.loaded.set(info.name, { info: map?.model ?? info, session, map, bytes: data });
    }
    if (primary || !this.primary) this.primary = info.name;
  }

  unload(name) {
    const entry = this.loaded.get(name);
    entry?.session.release?.();
    this.loaded.delete(name);
    if (this.primary === name) this.primary = this.loaded.keys().next().value ?? null;
  }

  unloadAll() { for (const name of [...this.loaded.keys()]) this.unload(name); }

  /**
   * Runs a loaded model once. `frames` are 8-bit RGB (NHWC) pictures in the order of the model's inputs
   * (other inputs: the stick's quantized values, or a Float32Array of real values).
   * Runs are queued: ONNX Runtime Web must not run two models at the same time (an example reading a plate
   * while its frame loop detects would otherwise corrupt the runtime's memory).
   */
  infer(frames, name = null) {
    const result = (this.queue ?? Promise.resolve()).then(() => this.inferNow(frames, name));
    this.queue = result.catch(() => {});
    return result;
  }

  async inferNow(frames, name) {
    const entry = this.loaded.get(name ?? this.primary);
    if (!entry) throw new Error("No model loaded.");
    const { session, info, map } = entry;
    const feeds = {};
    const order = map?.inputs ?? defaultInputOrder(session.inputNames);
    frames.forEach((frame, index) => {
      const inputName = order[index];
      if (!inputName) return;
      const stream = info.inputs[index];
      if (inputName.startsWith("image")) {
        // Models trained on BGR (map "bgr": the stick swaps the colours on the chip, the ONNX does not).
        feeds[inputName] = new ort.Tensor("uint8", map?.bgr ? swapRedBlue(frame) : frame, [1, stream.height, stream.width, stream.features ?? 3]);
      } else if (frame instanceof Float32Array) {
        // Already real values (a text encoder's token embeddings, [1, tokens, width]).
        feeds[inputName] = new ort.Tensor("float32", frame, [1, stream.width ?? 1, stream.features ?? 1]);
      } else {
        const values = Float32Array.from(frame, (v) => (v - (stream.qpZp ?? 0)) * (stream.qpScale ?? 1));
        const shape = session.inputMetadata?.find((m) => m.name === inputName)?.shape;
        feeds[inputName] = shape?.length === 5 ? clipTensor(values, stream, shape) : new ort.Tensor("float32", values, [1, stream.height ?? 1, stream.width ?? 1, stream.features ?? 1]);
      }
    });
    let result;
    try {
      result = await entry.session.run(feeds);
    } catch (error) {
      // WebGPU lacks a few operators' variants (e.g. AveragePool with ceil in scrfd): this model runs on
      // WebAssembly from now on.
      if (entry.session.provider !== "webgpu") throw error;
      console.warn(`${info.name}: WebGPU failed (${error.message ?? error}); using WebAssembly`);
      entry.session.release?.();
      entry.session = await createSession(entry.bytes, ["wasm"]);
      result = await entry.session.run(feeds);
    }
    // Look outputs up by their graph name or by the name the Core ML conversion gave them.
    const byName = {};
    for (const [name, value] of Object.entries(result)) { byName[name] = value; byName[sanitized(name)] ??= value; }
    return outputs(byName, info, map, entry.session.outputNames);
  }
}

function swapRedBlue(rgb) {
  const out = Uint8Array.from(rgb);
  for (let i = 0; i < out.length; i += 3) { out[i] = rgb[i + 2]; out[i + 2] = rgb[i]; }
  return out;
}

/** A clip [1, colours, frames, H, W] (r3d_18) from the stick's NHWC input, whose channels are frame x colours + colour. */
function clipTensor(values, stream, shape) {
  const [, colours, frames] = shape, h = stream.height, w = stream.width, c = stream.features;
  const out = new Float32Array(colours * frames * h * w);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) for (let t = 0; t < frames; t++) for (let ch = 0; ch < colours; ch++) {
    out[((ch * frames + t) * h + y) * w + x] = values[(y * w + x) * c + t * colours + ch];
  }
  return new ort.Tensor("float32", out, [1, colours, frames, h, w]);
}

/** Converted models name picture inputs "image", "image_2", ...; other inputs keep their graph names. */
function defaultInputOrder(names) {
  const rank = (n) => (n === "image" ? [0, ""] : n.startsWith("image_") ? [1, n] : [2, n]);
  return [...names].sort((a, b) => { const x = rank(a), y = rank(b); return x[0] - y[0] || x[1].localeCompare(y[1]); });
}

function floatData(t) {
  const d = t.data;
  return d instanceof Float32Array ? d : Float32Array.from(d, Number);
}

function outputs(result, info, map, outputNames) {
  if (map?.detection && hasDeviceNMS(info)) {
    return [nmsTensor(map.outputs.map((o) => result[o.source]), map, info)];
  }
  const mapping = map?.outputs ?? [...outputNames].sort().map((source) => ({ source }));
  return info.outputs.slice(0, mapping.length).map((stream, index) => {
    const out = result[mapping[index].source];
    if (!out) throw new Error(`Missing output ${mapping[index].source}.`);
    const values = nhwc(floatData(out), out.dims, stream);
    switch (mapping[index].activation) {
      case "sigmoid": for (let i = 0; i < values.length; i++) values[i] = 1 / (1 + Math.exp(-values[i])); break;
      case "tanh": for (let i = 0; i < values.length; i++) values[i] = Math.tanh(values[i]); break;
      case "softmax": {
        let peak = -Infinity, total = 0;
        for (const v of values) peak = Math.max(peak, v);
        for (let i = 0; i < values.length; i++) { values[i] = Math.exp(values[i] - peak); total += values[i]; }
        for (let i = 0; i < values.length; i++) values[i] /= total;
        break;
      }
    }
    return new Tensor(stream, values);
  });
}

/** Reorders an NCHW (or [1, C, N]) output into the stick's NHWC layout for `stream`. Returns a copy. */
export function nhwc(values, dims, stream) {
  const h = stream.height ?? 1, w = stream.width ?? 1, c = stream.features ?? 1;
  if (dims.length === 4 && dims[1] === c && dims[2] === h && dims[3] === w && (c > 1 || h > 1)) {
    const out = new Float32Array(h * w * c);
    for (let ch = 0; ch < c; ch++) for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) out[(y * w + x) * c + ch] = values[(ch * h + y) * w + x];
    return out;
  }
  if (dims.length === 3 && dims[1] === c && dims[2] === w * h && c > 1) {
    const n = w * h, out = new Float32Array(n * c);
    for (let ch = 0; ch < c; ch++) for (let i = 0; i < n; i++) out[i * c + ch] = values[ch * n + i];
    return out;
  }
  return Float32Array.from(values);
}

// MARK: Detection decoding and NMS (models whose stick version runs NMS on the chip)

const sigmoid = (x) => 1 / (1 + Math.exp(-x));

/** Decodes raw YOLO outputs, runs class-wise NMS and writes Hailo's NMS_BY_CLASS layout. */
export function nmsTensor(arrays, map, model) {
  const classes = model.outputs[0].classes ?? 80;
  const threshold = model.nmsScore ?? 0.2;
  const inputW = model.inputs[0].width, inputH = model.inputs[0].height;
  const perClass = Array.from({ length: classes }, () => []);
  const add = (c, cx, cy, w, h, score) =>
    perClass[c].push({ box: [(cy - h / 2) / inputH, (cx - w / 2) / inputW, (cy + h / 2) / inputH, (cx + w / 2) / inputW], score });

  switch (map.detection) {
    case "boxesThenScores": {
      const a = arrays[0]; if (!a) break;
      const v = floatData(a), n = a.dims[a.dims.length - 1];
      for (let i = 0; i < n; i++) for (let c = 0; c < classes; c++) {
        const s = v[(4 + c) * n + i];
        if (s >= threshold) add(c, v[i], v[n + i], v[2 * n + i], v[3 * n + i], s);
      }
      break;
    }
    case "boxesObjectnessScores": {
      const a = arrays[0]; if (!a) break;
      const v = floatData(a), stride = a.dims[a.dims.length - 1] ?? 5 + classes;
      for (let row = 0; row + stride <= v.length; row += stride) {
        const objectness = v[row + 4];
        if (objectness < threshold) continue;
        for (let c = 0; c < classes; c++) {
          const s = objectness * v[row + 5 + c];
          if (s >= threshold) add(c, v[row], v[row + 1], v[row + 2], v[row + 3], s);
        }
      }
      break;
    }
    case "dflHeads": {
      const logit = Math.log(threshold / (1 - threshold));
      for (let index = 0; index + 1 < arrays.length; index += 2) {
        const boxA = arrays[index], clsA = arrays[index + 1];
        const h = boxA.dims[2], w = boxA.dims[3], bins = boxA.dims[1] / 4, stride = inputW / w;
        const box = floatData(boxA), cls = floatData(clsA), plane = h * w;
        for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
          const cell = y * w + x;
          let best = -Infinity;
          for (let c = 0; c < classes; c++) best = Math.max(best, cls[c * plane + cell]);
          if (best < logit) continue;
          const d = [0, 0, 0, 0];
          for (let side = 0; side < 4; side++) {
            let peak = -Infinity;
            for (let b = 0; b < bins; b++) peak = Math.max(peak, box[(side * bins + b) * plane + cell]);
            let total = 0, weighted = 0;
            for (let b = 0; b < bins; b++) { const e = Math.exp(box[(side * bins + b) * plane + cell] - peak); total += e; weighted += e * b; }
            d[side] = (weighted / total) * stride;
          }
          const px = (x + 0.5) * stride, py = (y + 0.5) * stride;
          const x0 = px - d[0], y0 = py - d[1], x1 = px + d[2], y1 = py + d[3];
          for (let c = 0; c < classes; c++) {
            const raw = cls[c * plane + cell];
            if (raw >= logit) add(c, (x0 + x1) / 2, (y0 + y1) / 2, x1 - x0, y1 - y0, sigmoid(raw));
          }
        }
      }
      break;
    }
    case "anchorHeads": {
      const logit = Math.log(threshold / (1 - threshold));
      arrays.forEach((a, level) => {
        const dims = a.dims, sizes = map.anchors?.[level];
        if (!sizes) return;
        const anchorCount = sizes.length / 2, depth = 5 + classes, channelsFirst = dims.length === 4;
        if (channelsFirst ? dims[1] !== anchorCount * depth : dims.length !== 5) return;
        const h = dims[2], w = dims[3], stride = inputW / w, values = floatData(a);
        for (let k = 0; k < anchorCount; k++) {
          const aw = sizes[2 * k], ah = sizes[2 * k + 1];
          for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
            const v = (j) => channelsFirst ? values[((k * depth + j) * h + y) * w + x] : values[((k * h + y) * w + x) * depth + j];
            if (v(4) < logit) continue;
            const objectness = sigmoid(v(4));
            const cx = (sigmoid(v(0)) * 2 - 0.5 + x) * stride, cy = (sigmoid(v(1)) * 2 - 0.5 + y) * stride;
            const bw = (sigmoid(v(2)) * 2) ** 2 * aw, bh = (sigmoid(v(3)) * 2) ** 2 * ah;
            for (let c = 0; c < classes; c++) {
              const s = objectness * sigmoid(v(5 + c));
              if (s >= threshold) add(c, cx, cy, bw, bh, s);
            }
          }
        }
      });
      break;
    }
  }
  return nmsList(perClass, model);
}

/** Class-wise NMS as Hailo's NMS_BY_CLASS: per class a count, then (y_min, x_min, y_max, x_max, score) per box. */
function nmsList(perClass, model) {
  const stream = model.outputs[0];
  const maxBoxes = stream.maxBoxes ?? 100, iouThreshold = model.nmsIoU ?? 0.7;
  const iou = (a, b) => {
    const y0 = Math.max(a[0], b[0]), x0 = Math.max(a[1], b[1]), y1 = Math.min(a[2], b[2]), x1 = Math.min(a[3], b[3]);
    const inter = Math.max(0, y1 - y0) * Math.max(0, x1 - x0);
    const union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter;
    return union > 0 ? inter / union : 0;
  };
  const out = [];
  for (const candidates of perClass) {
    const kept = [];
    for (const c of candidates.sort((a, b) => b.score - a.score)) {
      if (kept.length >= maxBoxes) break;
      if (kept.every((k) => iou(k.box, c.box) <= iouThreshold)) kept.push(c);
    }
    out.push(kept.length);
    for (const k of kept) out.push(Math.max(0, k.box[0]), Math.max(0, k.box[1]), Math.min(1, k.box[2]), Math.min(1, k.box[3]), k.score);
  }
  return new Tensor(stream, Float32Array.from(out));
}
