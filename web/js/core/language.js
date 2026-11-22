// Language models and speech in the browser: WebLLM (MLC, WebGPU) for chat, code and picture questions,
// Whisper through Transformers.js for speech to text. Both download their models once from Hugging Face
// and keep them in the browser's storage.
import { withoutThinking } from "../rules/language-games.js";

/** The models offered (WebLLM's prebuilt builds of the families the apps use). `vision` takes pictures. */
export const LANGUAGE_MODELS = [
  { id: "Qwen2.5-1.5B-Instruct-q4f16_1-MLC", title: "Qwen2.5 1.5B", use: ["chat"], mb: 1630 },
  { id: "Qwen3-1.7B-q4f16_1-MLC", title: "Qwen3 1.7B", use: ["chat"], mb: 2040, think: true },
  { id: "Llama-3.2-1B-Instruct-q4f16_1-MLC", title: "Llama 3.2 1B", use: ["chat"], mb: 880 },
  { id: "Qwen2.5-Coder-1.5B-Instruct-q4f16_1-MLC", title: "Qwen2.5 Coder 1.5B", use: ["code", "chat"], mb: 1630 },
  { id: "Qwen2.5-0.5B-Instruct-q4f16_1-MLC", title: "Qwen2.5 0.5B (small, fast)", use: ["chat"], mb: 950 },
  { id: "Phi-3.5-vision-instruct-q4f16_1-MLC", title: "Phi-3.5 vision", use: ["pictures"], mb: 3950, vision: true },
];

export const modelsFor = (use) => LANGUAGE_MODELS.filter((m) => m.use.includes(use));

let webllm = null, engine = null, loadedId = null, loading = null;

async function library() {
  webllm ??= await import("../../vendor/web-llm-0.2.87/index.js");
  return webllm;
}

export const Language = {
  get loaded() { return loadedId; },

  async isDownloaded(id) { try { return await (await library()).hasModelInCache(id); } catch { return false; } },

  async forget(id) { await (await library()).deleteModelAllInfoInCache(id); },

  /** Loads `id` (downloading it the first time); `onProgress(text, fraction)`. */
  async load(id, onProgress) {
    if (!navigator.gpu) throw new Error("Language models need WebGPU (Chrome or Edge on a recent computer).");
    // WebLLM's compiled models use 10 storage buffers in a shader; some browsers' WebGPU allows fewer
    // (one browser reported 9; Chrome 158 on this Mac reports 10). Say so before anything is downloaded.
    const adapter = await navigator.gpu.requestAdapter();
    const limit = adapter?.limits?.maxStorageBuffersPerShaderStage ?? 0;
    if (limit < 10) throw new Error(`This browser's WebGPU allows ${limit} storage buffers per shader; the language models need 10. Open this page in Chrome or Edge to use them. (The vision pages work here.)`);
    if (loadedId === id && engine) return engine;
    if (loading) await loading.catch(() => {});
    loading = (async () => {
      const lib = await library();
      const progress = (r) => onProgress?.(r.text, r.progress);
      if (!engine) engine = await lib.CreateMLCEngine(id, { initProgressCallback: progress });
      else { engine.setInitProgressCallback?.(progress); await engine.reload(id); }
      loadedId = id;
      return engine;
    })();
    try { return await loading; } finally { loading = null; }
  },

  /**
   * Streams an answer. `picture` (canvas/bitmap) needs a vision model. Qwen3 is asked not to think and
   * any thinking is removed. Returns { text, tokens, tokensPerSecond }. `signal` (AbortSignal) stops it.
   */
  async stream({ model, system, user, picture, maxTokens = 400, temperature = 0.3, onText, onProgress, signal }) {
    const info = LANGUAGE_MODELS.find((m) => m.id === model);
    const e = await this.load(model, onProgress);
    const messages = [];
    if (system) messages.push({ role: "system", content: system });
    const text = user + (info?.think ? " /no_think" : "");
    messages.push(picture ? { role: "user", content: [{ type: "image_url", image_url: { url: dataURL(picture) } }, { type: "text", text }] } : { role: "user", content: text });
    const started = performance.now();
    let answer = "", tokens = 0;
    const abort = () => e.interruptGenerate();
    signal?.addEventListener("abort", abort);
    try {
      const chunks = await e.chat.completions.create({ messages, stream: true, temperature, max_tokens: maxTokens, stream_options: { include_usage: true } });
      for await (const chunk of chunks) {
        const piece = chunk.choices?.[0]?.delta?.content ?? "";
        if (piece) { answer += piece; tokens++; onText?.(withoutThinking(answer)); }
        if (chunk.usage?.completion_tokens) tokens = chunk.usage.completion_tokens;
      }
    } finally { signal?.removeEventListener("abort", abort); }
    const seconds = (performance.now() - started) / 1000;
    return { text: withoutThinking(answer), tokens, tokensPerSecond: tokens / Math.max(seconds, 0.001), model: info?.title ?? model };
  },
};

/** A picture as a JPEG data URL, at most `side` pixels on its longest side. */
export function dataURL(picture, side = 1024) {
  const w = picture.width, h = picture.height, k = Math.min(1, side / Math.max(w, h));
  const c = Object.assign(document.createElement("canvas"), { width: Math.round(w * k), height: Math.round(h * k) });
  c.getContext("2d").drawImage(picture, 0, 0, c.width, c.height);
  return c.toDataURL("image/jpeg", 0.9);
}

// MARK: Speech (Whisper)

export const WHISPER_MODELS = [
  { id: "onnx-community/whisper-base", title: "Whisper base (multilingual)", mb: 200 },
  { id: "onnx-community/whisper-tiny", title: "Whisper tiny (fastest)", mb: 120 },
  { id: "onnx-community/whisper-small", title: "Whisper small (more accurate)", mb: 600 },
];

let transformers = null, whisper = null, whisperId = null;

export const Speech = {
  async load(id, onProgress) {
    if (whisper && whisperId === id) return whisper;
    transformers ??= await import("../../vendor/transformers-4.3.2/transformers.min.js");
    transformers.env.backends.onnx.wasm.wasmPaths = new URL("../../vendor/transformers-4.3.2/", import.meta.url).href;
    transformers.env.allowLocalModels = false;
    const files = new Map();
    whisper = await transformers.pipeline("automatic-speech-recognition", id, {
      device: navigator.gpu ? "webgpu" : "wasm",
      dtype: navigator.gpu ? { encoder_model: "fp32", decoder_model_merged: "q4" } : "q8",
      progress_callback: (p) => {
        if (p.status !== "progress" || !p.total) return;
        files.set(p.file, [p.loaded, p.total]);
        const [got, total] = [...files.values()].reduce((a, [l, t]) => [a[0] + l, a[1] + t], [0, 0]);
        onProgress?.(`Downloading Whisper: ${(got / 1e6).toFixed(0)} of ${(total / 1e6).toFixed(0)} MB`, got / total);
      },
    });
    whisperId = id;
    return whisper;
  },

  /** Mono 16 kHz samples -> text. `language` (e.g. "en", "pt") or null to detect; `translate` gives English. */
  async transcribe(samples, { model = WHISPER_MODELS[0].id, language = null, translate = false, onProgress } = {}) {
    const asr = await this.load(model, onProgress);
    const out = await asr(samples, { chunk_length_s: 30, stride_length_s: 5, language: language || undefined, task: translate ? "translate" : "transcribe", return_timestamps: false });
    return (Array.isArray(out) ? out.map((o) => o.text).join(" ") : out.text).trim();
  },
};

/** Any audio file or recording (Blob) as mono 16 kHz float samples. */
export async function audioSamples(blob) {
  const data = await blob.arrayBuffer();
  const decoded = await new AudioContext().decodeAudioData(data);
  const length = Math.ceil(decoded.duration * 16000);
  const offline = new OfflineAudioContext(1, length, 16000);
  const source = offline.createBufferSource();
  source.buffer = decoded; source.connect(offline.destination); source.start();
  return (await offline.startRendering()).getChannelData(0);
}

/** Records the microphone; returns { stop(): Promise<Blob> }. */
export async function recordMicrophone() {
  const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  const recorder = new MediaRecorder(stream), chunks = [];
  recorder.ondataavailable = (e) => chunks.push(e.data);
  recorder.start();
  return {
    stop: () => new Promise((resolve) => {
      recorder.onstop = () => { stream.getTracks().forEach((t) => t.stop()); resolve(new Blob(chunks, { type: recorder.mimeType })); };
      recorder.stop();
    }),
  };
}
