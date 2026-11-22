// Tasks that need two models (port of StudioCore/Pipelines.swift): reading text (ocr_det + ocr) and
// describing faces (a face detector + an ArcFace embedder), plus the gallery of known faces.
import { Catalog, inputWidth, inputHeight } from "./catalog.js";
import { prepare, sourceSize } from "./prep.js";
import { faces } from "./faces.js";
import { supports } from "./pipeline.js";
import { textRegions, recognizedText, loadTextCharacters } from "./decode2.js";

const canvas = (w, h) => (typeof OffscreenCanvas !== "undefined" ? new OffscreenCanvas(w, h) : Object.assign(document.createElement("canvas"), { width: w, height: h }));

export const TextReader = {
  detectorName: "ocr_det",
  recognizerName: "ocr",

  /** Text regions with what they say (regions the recogniser is unsure of keep text ""). */
  async read(image, engine) {
    await loadTextCharacters();
    const detector = Catalog.model(this.detectorName), recognizer = Catalog.model(this.recognizerName);
    const frame = prepare(image, inputWidth(detector), inputHeight(detector), "letterbox");
    const regions = textRegions((await engine.infer([frame.rgb], this.detectorName))[0], frame);
    for (const region of regions) {
      const crop = cropQuad(image, region.corners);
      if (!crop || crop.width < crop.height) continue;
      const input = prepare(crop, inputWidth(recognizer), inputHeight(recognizer), "letterbox", undefined, 128);
      const { text, confidence } = recognizedText((await engine.infer([input.rgb], this.recognizerName))[0]);
      if (confidence >= 0.5) region.text = text;
    }
    return regions;
  },
};

/** A rotated rectangle (corners TL, TR, BR, BL, normalized) cut out of `image`, upright. */
export function cropQuad(image, quad) {
  const { width: W, height: H } = sourceSize(image);
  const p = quad.map((q) => ({ x: q.x * W, y: q.y * H }));
  const w = Math.round(Math.hypot(p[1].x - p[0].x, p[1].y - p[0].y)), h = Math.round(Math.hypot(p[3].x - p[0].x, p[3].y - p[0].y));
  if (w < 2 || h < 2) return null;
  const angle = Math.atan2(p[1].y - p[0].y, p[1].x - p[0].x);
  const c = canvas(w, h), ctx = c.getContext("2d");
  ctx.imageSmoothingQuality = "high";
  ctx.rotate(-angle);
  ctx.translate(-p[0].x, -p[0].y);
  ctx.drawImage(image, 0, 0);
  return c;
}

/** People with their face embeddings; a match needs cosine similarity >= threshold. */
export class FaceGallery {
  constructor(data = {}) { this.people = data.people ?? {}; this.threshold = data.threshold ?? 0.4; }
  enroll(name, embedding) { (this.people[name] ??= []).push(Array.from(embedding)); }
  /** Replaces earlier samples of `name` with one vector (check-in enrolment). */
  set(name, embedding) { this.people[name] = [Array.from(embedding)]; }
  remove(name) { delete this.people[name]; }
  get names() { return Object.keys(this.people); }
  match(embedding) {
    let best = null;
    for (const [name, list] of Object.entries(this.people)) for (const known of list) {
      if (known.length !== embedding.length) continue;
      let dot = 0;
      for (let i = 0; i < known.length; i++) dot += known[i] * embedding[i];
      if (!best || dot > best.similarity) best = { name, similarity: dot };
    }
    return best && best.similarity >= this.threshold ? best : null;
  }
  toJSON() { return { people: this.people, threshold: this.threshold }; }
}

/** Average of several unit vectors, normalized (null when there are none). */
export function averageEmbedding(samples) {
  if (!samples.length) return null;
  const out = new Float32Array(samples[0].length);
  for (const s of samples) for (let i = 0; i < out.length; i++) out[i] += s[i];
  const norm = Math.hypot(...out);
  return norm > 0 ? out.map((v) => v / norm) : null;
}

// Where the five landmarks sit in ArcFace's 112x112 input (hailo-apps face_align.cpp).
const TEMPLATE = [[38.2946, 51.6963], [73.5318, 51.5014], [56.0252, 71.7366], [41.5493, 92.3655], [70.7299, 92.2041]];

export const FaceRecognition = {
  detectorName: "scrfd_10g",
  /** The embedders to choose from (both 512 numbers per face): MobileFaceNet (fast) and ResNet-50 (more accurate). */
  embedderNames: ["arcface_mobilefacenet", "arcface_r50"],
  /** The embedder in use; each one has its own list of people (their vectors cannot be compared). */
  embedderName: "arcface_mobilefacenet",

  /**
   * Faces with their unit-length embeddings: [{ face, embedding }]. Uses the loaded face detector when there
   * is one, otherwise scrfd_10g. LightFace's faces (no landmarks) get no embedding: ArcFace only works on
   * faces aligned by their eyes, nose and mouth.
   */
  async describe(image, engine) {
    const loaded = engine.loadedModel;
    const detector = loaded && supports("face", loaded) ? loaded : Catalog.model(this.detectorName);
    const embedder = Catalog.model(this.embedderName);
    const frame = prepare(image, inputWidth(detector), inputHeight(detector), "letterbox");
    const found = faces(await engine.infer([frame.rgb], detector.name), detector, frame);
    const out = [];
    for (const face of found) {
      const k = inputWidth(embedder) / 112;
      const aligned = align(image, face.landmarks, TEMPLATE.map(([x, y]) => [x * k, y * k]), inputWidth(embedder), inputHeight(embedder));
      if (!aligned) { out.push({ face, embedding: null }); continue; }
      const input = prepare(aligned, inputWidth(embedder), inputHeight(embedder), "stretch");
      out.push({ face, embedding: unit(Float32Array.from((await engine.infer([input.rgb], this.embedderName))[0].values)) });
    }
    return out;
  },

  async recognize(image, engine, gallery) {
    return (await this.describe(image, engine)).map(({ face, embedding }) => ({ ...face, name: embedding ? gallery.match(embedding)?.name : undefined }));
  },
};

/** The vector scaled to length 1, so a dot product is the cosine similarity. */
export function unit(v) {
  const norm = Math.hypot(...v);
  if (norm > 1e-10) for (let i = 0; i < v.length; i++) v[i] /= norm;
  return v;
}

/**
 * The similarity transform (rotation, uniform scale, shift; least squares) that moves the five landmarks
 * (normalized to `image`) onto `template` (output pixels): ArcFace's positions, or CelebA's for face
 * attributes. Returns [cos, sin, tx, ty] (x' = cos x - sin y + tx, y' = sin x + cos y + ty), or null.
 */
export function alignment(image, landmarks, template) {
  if (landmarks.length !== template.length) return null;
  const { width: W, height: H } = sourceSize(image);
  const src = landmarks.map((p) => [p.x * W, p.y * H]), dst = template;
  const mean = (pts) => [pts.reduce((s, p) => s + p[0], 0) / pts.length, pts.reduce((s, p) => s + p[1], 0) / pts.length];
  const ms = mean(src), md = mean(dst);
  let a = 0, b = 0, spread = 0;
  for (let i = 0; i < src.length; i++) {
    const sx = src[i][0] - ms[0], sy = src[i][1] - ms[1], tx = dst[i][0] - md[0], ty = dst[i][1] - md[1];
    a += sx * tx + sy * ty; b += sx * ty - sy * tx; spread += sx * sx + sy * sy;
  }
  if (spread <= 0) return null;
  const cos = a / spread, sin = b / spread;
  return [cos, sin, md[0] - (cos * ms[0] - sin * ms[1]), md[1] - (sin * ms[0] + cos * ms[1])];
}

/** The face turned, scaled and shifted onto `template` as a width x height canvas (ArcFace's input). */
function align(image, landmarks, template, width, height) {
  const t = alignment(image, landmarks, template);
  if (!t) return null;
  const c = canvas(width, height), ctx = c.getContext("2d");
  ctx.imageSmoothingQuality = "high";
  ctx.setTransform(t[0], t[1], -t[1], t[0], t[2], t[3]);
  ctx.drawImage(image, 0, 0);
  return c;
}
