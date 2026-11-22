// Fitting a picture to a model's input (port of StudioCore/ImagePrep.swift). Rectangles are
// { x, y, width, height }; results are normalized to the source picture (0..1, origin top-left).

export const Rect = {
  make: (x, y, width, height) => ({ x, y, width, height }),
  whole: () => ({ x: 0, y: 0, width: 1, height: 1 }),
  isWhole: (r) => r.x === 0 && r.y === 0 && r.width === 1 && r.height === 1,
  maxX: (r) => r.x + r.width,
  maxY: (r) => r.y + r.height,
  intersection(a, b) {
    const x0 = Math.max(a.x, b.x), y0 = Math.max(a.y, b.y), x1 = Math.min(a.x + a.width, b.x + b.width), y1 = Math.min(a.y + a.height, b.y + b.height);
    return x1 > x0 && y1 > y0 ? { x: x0, y: y0, width: x1 - x0, height: y1 - y0 } : null;
  },
  iou(a, b) {
    const i = Rect.intersection(a, b);
    if (!i) return 0;
    const overlap = i.width * i.height, union = a.width * a.height + b.width * b.height - overlap;
    return union > 0 ? overlap / union : 0;
  },
};

/** The size of anything drawable (image, bitmap, video, canvas). */
export function sourceSize(source) {
  return {
    width: source.videoWidth || source.naturalWidth || source.displayWidth || source.width,
    height: source.videoHeight || source.naturalHeight || source.displayHeight || source.height,
  };
}

/** An image converted to a model's RGB888 input, with what is needed to map results back. */
export class PreparedFrame {
  constructor({ rgb, width, height, sourceWidth, sourceHeight, contentRect, sourceRegion }) {
    Object.assign(this, { rgb, width, height, sourceWidth, sourceHeight, contentRect, sourceRegion: sourceRegion ?? Rect.whole() });
  }

  /** A point in model-input pixels to normalized source coordinates. */
  toSource(x, y) {
    const c = this.contentRect, r = this.sourceRegion;
    return { x: r.x + ((x - c.x) / c.width) * r.width, y: r.y + ((y - c.y) / c.height) * r.height };
  }

  /** A rectangle in model-input pixels to normalized source coordinates, clamped to the picture. */
  toSourceRect(rect) {
    const a = this.toSource(rect.x, rect.y), b = this.toSource(rect.x + rect.width, rect.y + rect.height);
    const clamp = (v) => Math.min(Math.max(v, 0), 1);
    const x0 = clamp(a.x), y0 = clamp(a.y), x1 = clamp(b.x), y1 = clamp(b.y);
    return { x: x0, y: y0, width: Math.max(0, x1 - x0), height: Math.max(0, y1 - y0) };
  }
}

const canvases = new Map();
function scratch(width, height) {
  const key = `${width}x${height}`;
  let c = canvases.get(key);
  if (!c) {
    c = typeof OffscreenCanvas !== "undefined" ? new OffscreenCanvas(width, height) : Object.assign(document.createElement("canvas"), { width, height });
    canvases.set(key, c);
  }
  return c;
}

/**
 * Draws `source` (or the normalized `region` of it) into a width x height RGB888 buffer.
 * mode: "letterbox" (keep aspect, grey 114 padding: YOLO) or "stretch".
 */
export function prepare(source, width, height, mode = "letterbox", region = Rect.whole(), pad = 114) {
  const full = sourceSize(source);
  const crop = Rect.isWhole(region)
    ? { x: 0, y: 0, width: full.width, height: full.height }
    : { x: Math.round(region.x * full.width), y: Math.round(region.y * full.height), width: Math.round(region.width * full.width), height: Math.round(region.height * full.height) };
  let content = { x: 0, y: 0, width, height };
  if (mode === "letterbox") {
    const scale = Math.min(width / crop.width, height / crop.height);
    const w = Math.round(crop.width * scale), h = Math.round(crop.height * scale);
    content = { x: Math.floor((width - w) / 2), y: Math.floor((height - h) / 2), width: w, height: h };
  }
  const canvas = scratch(width, height);
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  ctx.fillStyle = `rgb(${pad},${pad},${pad})`;
  ctx.fillRect(0, 0, width, height);
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = "medium";
  ctx.drawImage(source, crop.x, crop.y, crop.width, crop.height, content.x, content.y, content.width, content.height);
  const rgba = ctx.getImageData(0, 0, width, height).data;
  const rgb = new Uint8Array(width * height * 3);
  for (let s = 0, d = 0; s < rgba.length; s += 4, d += 3) { rgb[d] = rgba[s]; rgb[d + 1] = rgba[s + 1]; rgb[d + 2] = rgba[s + 2]; }
  return new PreparedFrame({ rgb, width, height, sourceWidth: full.width, sourceHeight: full.height, contentRect: content, sourceRegion: region });
}

/** RGB888 bytes into an ImageData-ready RGBA array. */
export function rgbToRGBA(rgb) {
  const out = new Uint8ClampedArray((rgb.length / 3) * 4);
  for (let s = 0, d = 0; s < rgb.length; s += 3, d += 4) { out[d] = rgb[s]; out[d + 1] = rgb[s + 1]; out[d + 2] = rgb[s + 2]; out[d + 3] = 255; }
  return out;
}

/** A canvas (crop) of the normalized rectangle of `source`. */
export function cropToCanvas(source, rect) {
  const full = sourceSize(source);
  const w = Math.max(1, Math.round(rect.width * full.width)), h = Math.max(1, Math.round(rect.height * full.height));
  const c = typeof OffscreenCanvas !== "undefined" ? new OffscreenCanvas(w, h) : Object.assign(document.createElement("canvas"), { width: w, height: h });
  c.getContext("2d").drawImage(source, Math.round(rect.x * full.width), Math.round(rect.y * full.height), w, h, 0, 0, w, h);
  return c;
}

/** A point of the upright S x S crop of `square` ({cx, cy, size, angle}, picture pixels) in picture pixels. */
export function toPicture(square, u, v, S) {
  const k = square.size / S, x = (u - S / 2) * k, y = (v - S / 2) * k, c = Math.cos(-square.angle), s = Math.sin(-square.angle);
  return { x: square.cx + x * c - y * s, y: square.cy + x * s + y * c };
}

// MARK: Exact crops (port of RGBAPixels in HandSteadying.swift / TopDownPose.swift)
// The crop models were trained on crops cut with cv2 or tf.image (bilinear, no smoothing); a canvas
// scales with its own filter, so these sample the picture's pixels directly.

/** The picture's RGBA pixels: { width, height, data }. */
export function pixelsOf(source) {
  const { width, height } = sourceSize(source);
  const c = typeof OffscreenCanvas !== "undefined" ? new OffscreenCanvas(width, height) : Object.assign(document.createElement("canvas"), { width, height });
  const ctx = c.getContext("2d", { willReadFrequently: true });
  ctx.drawImage(source, 0, 0, width, height);
  return { width, height, data: ctx.getImageData(0, 0, width, height).data };
}

/**
 * RGB bytes of a width x height picture whose pixel (u, v) is the picture's point (x[0] u + x[1], y[0] v + y[1]),
 * in pixels with centres at whole numbers. Bilinear, black outside (cv2.warpAffine, INTER_LINEAR, constant border).
 */
export function warp(pixels, width, height, x, y) {
  return warpAffine(pixels, width, height, [x[0], 0, x[1], 0, y[0], y[1]]);
}

/** As warp, for any affine map: pixel (u, v) samples the picture at (m0 u + m1 v + m2, m3 u + m4 v + m5). */
export function warpAffine(pixels, width, height, m) {
  const out = new Uint8Array(width * height * 3), { width: sw, height: sh, data } = pixels;
  const at = (xi, yi, ch) => (xi >= 0 && yi >= 0 && xi < sw && yi < sh ? data[(yi * sw + xi) * 4 + ch] : 0);
  for (let v = 0; v < height; v++) for (let u = 0; u < width; u++) {
    const px = m[0] * u + m[1] * v + m[2], py = m[3] * u + m[4] * v + m[5], x0 = Math.floor(px), y0 = Math.floor(py);
    if (x0 < -1 || x0 >= sw || y0 < -1 || y0 >= sh) continue;
    const fx = px - x0, fy = py - y0, o = (v * width + u) * 3;
    for (let ch = 0; ch < 3; ch++) {
      const top = at(x0, y0, ch) * (1 - fx) + at(x0 + 1, y0, ch) * fx, bottom = at(x0, y0 + 1, ch) * (1 - fx) + at(x0 + 1, y0 + 1, ch) * fx;
      out[o + ch] = Math.round(top * (1 - fy) + bottom * fy);
    }
  }
  return out;
}

/** The turned square ({cx, cy, size, angle}, picture pixels) as upright side x side RGB (bilinear); outside is black. */
export function cropSquare(pixels, square, side) {
  const out = new Uint8Array(side * side * 3), { width, height, data } = pixels;
  const scale = square.size / side, c = Math.cos(-square.angle), s = Math.sin(-square.angle), half = side / 2;
  for (let v = 0; v < side; v++) for (let u = 0; u < side; u++) {
    const x = (u + 0.5 - half) * scale, y = (v + 0.5 - half) * scale;
    const px = square.cx + x * c - y * s - 0.5, py = square.cy + x * s + y * c - 0.5;
    const x0 = Math.floor(px), y0 = Math.floor(py);
    if (x0 < 0 || y0 < 0 || x0 + 1 >= width || y0 + 1 >= height) continue;
    const fx = px - x0, fy = py - y0, o = (v * side + u) * 3;
    const i00 = (y0 * width + x0) * 4, i10 = i00 + 4, i01 = i00 + width * 4, i11 = i01 + 4;
    for (let ch = 0; ch < 3; ch++) {
      const top = data[i00 + ch] * (1 - fx) + data[i10 + ch] * fx, bottom = data[i01 + ch] * (1 - fx) + data[i11 + ch] * fx;
      out[o + ch] = Math.round(top * (1 - fy) + bottom * fy);
    }
  }
  return out;
}

/** A crop's frame: input pixels map to `region` (picture pixels, may reach past the edges). */
export function cropFrame(rgb, width, height, pixels, region) {
  return new PreparedFrame({ rgb, width, height, sourceWidth: pixels.width, sourceHeight: pixels.height, contentRect: { x: 0, y: 0, width, height },
    sourceRegion: { x: region.x / pixels.width, y: region.y / pixels.height, width: region.width / pixels.width, height: region.height / pixels.height } });
}

/** `region` (picture pixels) stretched to width x height (bilinear, pixel centres as tf.image.resize). */
export function stretchedCrop(pixels, region, width, height) {
  const sx = region.width / width, sy = region.height / height;
  return cropFrame(warp(pixels, width, height, [sx, region.x + 0.5 * sx - 0.5], [sy, region.y + 0.5 * sy - 0.5]), width, height, pixels, region);
}

// MARK: Antialiased stretch (as PIL's Image.resize with BILINEAR)

/** For each output index along one axis: the first input index and the normalized triangle-filter weights. */
function resampleWeights(inSize, outSize) {
  const scale = inSize / outSize, support = Math.max(scale, 1), out = [];
  for (let i = 0; i < outSize; i++) {
    const centre = (i + 0.5) * scale;
    const first = Math.max(Math.trunc(centre - support + 0.5), 0), last = Math.min(Math.trunc(centre + support + 0.5), inSize);
    const weights = [];
    let total = 0;
    for (let j = first; j < last; j++) { const w = Math.max(0, 1 - Math.abs((j - centre + 0.5) / support)); weights.push(w); total += w; }
    out.push({ first, weights: weights.map((w) => (total ? w / total : 0)) });
  }
  return out;
}

/**
 * The whole picture stretched to width x height with a triangle filter as wide as the scale (PIL's
 * BILINEAR resize: horizontal pass, rounded to 8 bits, then vertical). A canvas's drawImage barely smooths
 * large reductions; CLIP-style encoders were checked against this resize (and Core ML's CoreGraphics one).
 */
export function prepareSmooth(source, width, height) {
  const pixels = pixelsOf(source), { width: sw, height: sh, data } = pixels;
  const xs = resampleWeights(sw, width), ys = resampleWeights(sh, height);
  const rows = new Uint8ClampedArray(sh * width * 3);
  for (let y = 0; y < sh; y++) for (let x = 0; x < width; x++) {
    const { first, weights } = xs[x];
    let r = 0, g = 0, b = 0;
    for (let k = 0; k < weights.length; k++) { const i = (y * sw + first + k) * 4, w = weights[k]; r += data[i] * w; g += data[i + 1] * w; b += data[i + 2] * w; }
    const o = (y * width + x) * 3;
    rows[o] = Math.round(r); rows[o + 1] = Math.round(g); rows[o + 2] = Math.round(b);
  }
  const rgb = new Uint8Array(width * height * 3);
  for (let y = 0; y < height; y++) {
    const { first, weights } = ys[y];
    for (let x = 0; x < width; x++) for (let ch = 0; ch < 3; ch++) {
      let v = 0;
      for (let k = 0; k < weights.length; k++) v += rows[((first + k) * width + x) * 3 + ch] * weights[k];
      rgb[(y * width + x) * 3 + ch] = Math.min(255, Math.max(0, Math.round(v)));
    }
  }
  return new PreparedFrame({ rgb, width, height, sourceWidth: sw, sourceHeight: sh, contentRect: { x: 0, y: 0, width, height } });
}
