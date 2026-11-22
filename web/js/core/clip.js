// Tagging from text: a picture scored against text prompts with a CLIP, TinyCLIP, SigLIP or SigLIP 2 image
// encoder and the text encoder trained with it (port of StudioCore/CLIPModels.swift and CLIP.swift).
//
// The web text encoders start after the token lookup, as the stick's: their input is the prompt's rows of
// the token embedding table ([1, tokens, width], float). The tables come from the model repository's
// coreml/ folder (native/tools/clip_assets.py): <text>.tokens.npy (float16; only the rows a prompt uses
// are downloaded, with range requests), <text>.projection.npy (CLIP) and <text>.final_norm.npy (TinyCLIP).
// CLIP ones give the last hidden state: the first end token's row (TinyCLIP: through the final layer norm)
// times the text projection. SigLIP ones give the pooled embedding. Image encoders give the embedding.
// Scores: softmax over the prompts of the model's logit scale x cosine similarity.
import { ClipTokenizer, SentencePieceTokenizer } from "./tokenizers.js";
import { prepareSmooth } from "./prep.js";
import { Catalog, inputWidth, inputHeight } from "./catalog.js";

const pair = (image, text, family, logitScale) => ({ image: `${image}_image_encoder`, text: `${text}_text_encoder`, family, logitScale });

/**
 * Every image encoder with its text encoder. The Model Zoo has no text encoder for ViT-L/14 at 336 pixels:
 * it takes ViT-L/14's, from which OpenAI fine-tuned it. Scales: OpenAI / LAION 100, TinyCLIP 50 (its
 * checkpoints keep ln 50), exp(logit_scale) of google/siglip-base-patch16-224, siglip-large-patch16-256 and
 * siglip2-base-patch32-256.
 */
export const PAIRS = [
  pair("clip_vit_b_32", "clip_vit_b_32", "clip", 100),
  pair("clip_vit_b_16", "clip_vit_b_16", "clip", 100),
  pair("clip_resnet_50", "clip_resnet_50", "clip", 100),
  pair("clip_resnet_50x4", "clip_resnet_50x4", "clip", 100),
  pair("clip_vit_l_14_336", "clip_vit_l_14", "clip", 100),
  pair("clip_vit_l_14_laion2B", "clip_vit_l_14_laion2B", "clip", 100),
  pair("tinyclip_vit_8m_16_text_3m_yfcc15m", "tinyclip_vit_8m_16_text_3m_yfcc15m", "clip", 50),
  pair("tinyclip_vit_39m_16_text_19m_yfcc15m", "tinyclip_vit_39m_16_text_19m_yfcc15m", "clip", 50),
  pair("tinyclip_vit_40m_32_text_19m_laion400m", "tinyclip_vit_40m_32_text_19m_laion400m", "clip", 50),
  pair("tinyclip_vit_61m_32_text_29m_laion400m", "tinyclip_vit_61m_32_text_29m_laion400m", "clip", 50),
  pair("siglip_b_16", "siglip_b_16", "siglip", 117.3),
  pair("siglip_l_16_256", "siglip_l_16_256", "siglip", 110.0),
  pair("siglip2_b_32_256", "siglip2_b_32_256", "siglip2", 111.8),
];

export const pairForImage = (name) => PAIRS.find((p) => p.image === name) ?? null;
export const pairForText = (name) => PAIRS.find((p) => p.text === name) ?? null;

/** The reference app and the apps put this in front of every prompt. */
export const PROMPT_PREFIX = "A photo of a ";
/** Artelico's default prompts. */
export const DEFAULT_PROMPTS = "car, truck, bus, person, bicycle, -empty road";

/** "a, b, -c" -> [{ text, negative }]: a prompt starting with "-" is a background ("not this") prompt. */
export function parsePrompts(text) {
  return text.split(",").map((raw) => raw.trim()).filter(Boolean).map((raw) => {
    const negative = raw.startsWith("-");
    return { text: (negative ? raw.slice(1) : raw).trim(), negative };
  }).filter((p) => p.text);
}

// MARK: Tokenizers (web/data)

const tokenizerFiles = { clip: "clip_tokenizer.json", siglip: "siglip_tokenizer.json", siglip2: "siglip2_tokenizer.json" };
const tokenizers = new Map();

export function tokenizer(family, base = "data") {
  if (!tokenizers.has(family)) {
    tokenizers.set(family, fetch(`${base}/${tokenizerFiles[family]}`).then((r) => {
      if (!r.ok) throw new Error(`${tokenizerFiles[family]}: HTTP ${r.status}`);
      return r.json();
    }).then((json) => (family === "clip" ? new ClipTokenizer(json) : new SentencePieceTokenizer(json))).catch((error) => { tokenizers.delete(family); throw error; }));
  }
  return tokenizers.get(family);
}

/** Token ids as the encoder takes them (CLIP: start, tokens, end, at most 77; SigLIP: tokens, end, padding). */
export async function tokenIds(p, text, length) {
  const t = await tokenizer(p.family);
  return p.family === "clip" ? t.encode(text) : t.encode(text, length);
}

// MARK: .npy tables

function float16(bits) {
  const sign = bits & 0x8000 ? -1 : 1, exponent = (bits >> 10) & 0x1f, fraction = bits & 0x3ff;
  if (exponent === 0) return sign * fraction * 2 ** -24;
  if (exponent === 31) return fraction ? NaN : sign * Infinity;
  return sign * (1 + fraction / 1024) * 2 ** (exponent - 15);
}

/** The header of a little-endian float16 / float32 C-order .npy file: { shape, offset, width }. */
function npyHeader(bytes, name) {
  if (bytes[0] !== 0x93 || String.fromCharCode(...bytes.slice(1, 6)) !== "NUMPY") throw new Error(`${name} is not a .npy file.`);
  const major = bytes[6];
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const [start, length] = major === 1 ? [10, view.getUint16(8, true)] : [12, view.getUint32(8, true)];
  if (bytes.length < start + length) return { needed: start + length };
  const header = new TextDecoder().decode(bytes.slice(start, start + length));
  const descr = /'descr':\s*'([<=|])f([24])'/.exec(header);
  if (!descr || !/'fortran_order':\s*False/.test(header)) throw new Error(`${name}: only little-endian float16 / float32 C-order arrays are read.`);
  const shape = /'shape':\s*\(([^)]*)\)/.exec(header)[1].split(",").map((s) => s.trim()).filter(Boolean).map(Number);
  return { shape, offset: start + length, width: Number(descr[2]) };
}

function toFloats(bytes, width) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const n = bytes.byteLength / width, out = new Float32Array(n);
  for (let i = 0; i < n; i++) out[i] = width === 2 ? float16(view.getUint16(2 * i, true)) : view.getFloat32(4 * i, true);
  return out;
}

/** A whole small table ([rows, columns] float32 values). */
async function readTable(source, path) {
  const bytes = await source.readFile(path);
  if (!bytes) throw new Error(`${path} is not in the model repository.`);
  const all = new Uint8Array(bytes), header = npyHeader(all, path);
  return { shape: header.shape, values: toFloats(all.subarray(header.offset), header.width) };
}

/** A large token table read a few rows at a time. */
class RowTable {
  constructor(source, path) { this.source = source; this.path = path; this.rows = new Map(); }

  async header() {
    this.headerPromise ??= (async () => {
      let header = npyHeader(await this.source.readRange(this.path, 0, 128), this.path);
      if (header.needed) header = npyHeader(await this.source.readRange(this.path, 0, header.needed), this.path);
      return header;
    })().catch((error) => { this.headerPromise = null; throw error; });
    return this.headerPromise;
  }

  async row(id) {
    if (!this.rows.has(id)) {
      this.rows.set(id, this.header().then(({ shape, offset, width }) => {
        if (id < 0 || id >= shape[0]) throw new Error("The tokenizer produced an id outside the embedding table.");
        const size = shape[1] * width;
        return this.source.readRange(this.path, offset + id * size, offset + (id + 1) * size).then((bytes) => toFloats(bytes, width));
      }).catch((error) => { this.rows.delete(id); throw error; }));
    }
    return this.rows.get(id);
  }
}

// MARK: Embeddings

function normalized(vector) {
  let sum = 0;
  for (const v of vector) sum += v * v;
  const norm = Math.sqrt(sum) + 1e-8;
  return Float32Array.from(vector, (v) => v / norm);
}

/** PyTorch's LayerNorm (epsilon 1e-5) over one vector. */
function layerNorm(x, weight, bias) {
  let mean = 0;
  for (const v of x) mean += v;
  mean /= x.length;
  let variance = 0;
  for (const v of x) variance += (v - mean) ** 2;
  const scale = 1 / Math.sqrt(variance / x.length + 1e-5);
  return Float32Array.from(x, (v, i) => (v - mean) * scale * weight[i] + bias[i]);
}

/** A pair's text encoder: its tables (loaded once) and the prompts it has embedded. */
class PromptEncoder {
  constructor(p, source) {
    this.pair = p;
    this.source = source;
    this.model = Catalog.model(p.text);
    this.tokens = new RowTable(source, `coreml/${p.text}.tokens.npy`);
    this.hasProjection = p.family === "clip";
    this.hasFinalNorm = p.text.startsWith("tinyclip_");
    this.tables = new Map();
    this.embeddings = new Map();
  }

  /** A small table next to the encoder (read once; tried again after a failure). */
  table(suffix) {
    if (!this.tables.has(suffix)) {
      this.tables.set(suffix, readTable(this.source, `coreml/${this.pair.text}.${suffix}`).catch((error) => { this.tables.delete(suffix); throw error; }));
    }
    return this.tables.get(suffix);
  }

  get length() { return this.model.inputs[0].width; }
  get width() { return this.model.inputs[0].features; }

  /** The prompt's unit-length embedding (cached). */
  embed(text, engine) {
    if (!this.embeddings.has(text)) this.embeddings.set(text, this.compute(text, engine).catch((error) => { this.embeddings.delete(text); throw error; }));
    return this.embeddings.get(text);
  }

  async compute(text, engine) {
    const { length, width } = this;
    const ids = (await tokenIds(this.pair, PROMPT_PREFIX + text, length)).slice(0, length);
    while (ids.length < length) ids.push(0);   // after CLIP's end token padding changes nothing (causal attention)
    const rows = await Promise.all(ids.map((id) => this.tokens.row(id)));
    const input = new Float32Array(length * width);
    rows.forEach((row, position) => {
      if (row.length !== width) throw new Error(`Token embedding rows of ${row.length} values do not fit ${this.pair.text} (${width}).`);
      input.set(row, position * width);
    });
    const [output] = await engine.infer([input], this.pair.text);
    if (!this.hasProjection) return normalized(output.values);
    // CLIP: the first end token's row (the last one when a long prompt lost it).
    const end = ids.indexOf(ClipTokenizer.endToken) >= 0 ? ids.indexOf(ClipTokenizer.endToken) : length - 1;
    const size = output.values.length / length;
    let state = output.values.slice(end * size, (end + 1) * size);
    if (this.hasFinalNorm) {
      const norm = await this.table("final_norm.npy");
      state = layerNorm(state, norm.values.subarray(0, size), norm.values.subarray(size, 2 * size));
    }
    const projection = await this.table("projection.npy");
    const [rowsP, columns] = projection.shape;
    if (rowsP !== size) throw new Error(`Text projection ${projection.shape} does not fit an encoder output of ${size} values.`);
    const projected = new Float32Array(columns);
    for (let i = 0; i < size; i++) {
      const w = state[i], row = i * columns;
      for (let j = 0; j < columns; j++) projected[j] += w * projection.values[row + j];
    }
    return normalized(projected);
  }
}

const encoders = new Map();

/** The text encoder of `p` (tables shared while the page is open). */
export function textEncoder(p, source) {
  const key = `${p.text}|${source.base ?? source.kind}`;
  if (!encoders.has(key) || encoders.get(key).source !== source) encoders.set(key, new PromptEncoder(p, source));
  return encoders.get(key);
}

/**
 * Tags a picture with the loaded image encoder: { kind: "classifications", value } (every prompt, best
 * first; background prompts as "not: ..."). The pair's text encoder must be loaded next to it.
 */
export async function tag(source, engine, prompts, timing = {}) {
  const model = engine.loadedModel;
  const p = pairForImage(model.name);
  if (!p) throw new Error("Tagging needs one of the CLIP or SigLIP image encoders.");
  const list = parsePrompts(prompts ?? DEFAULT_PROMPTS);
  if (!list.length) throw new Error("Type what to look for, separated by commas.");
  let t = performance.now();
  const encoder = textEncoder(p, engine.source);
  const texts = [];
  for (const prompt of list) texts.push(await encoder.embed(prompt.text, engine));
  timing.prompts = performance.now() - t;
  t = performance.now();
  // Stretched to the encoder's input (antialiased), as the reference.
  const frame = prepareSmooth(source, inputWidth(model), inputHeight(model));
  timing.prepare = performance.now() - t;
  t = performance.now();
  const [output] = await engine.infer([frame.rgb], p.image);
  timing.inference = performance.now() - t;
  t = performance.now();
  const image = normalized(output.values);
  const similarities = texts.map((text) => { let s = 0; for (let i = 0; i < Math.min(image.length, text.length); i++) s += image[i] * text[i]; return s; });
  const top = Math.max(...similarities);
  const weights = similarities.map((s) => Math.exp(p.logitScale * (s - top)));
  const total = weights.reduce((a, b) => a + b, 0);
  const value = list.map((prompt, i) => ({ label: (prompt.negative ? "not: " : "") + prompt.text, classIndex: i, probability: weights[i] / total, similarity: similarities[i], negative: prompt.negative }))
    .sort((a, b) => b.probability - a.probability);
  timing.decode = performance.now() - t;
  return { result: { kind: "classifications", value }, frame };
}
