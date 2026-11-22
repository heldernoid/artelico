// Privacy camera rules (port of StudioCore/Privacy.swift): what to hide (faces, licence plates, any text,
// whole people), how long a region stays hidden after it was last found, and the filter that hides it.
// Every frame is cleaned before it is shown or recorded; the filter throws rather than return the original.
import { Rect } from "../core/prep.js";

/** How hidden parts look. */
export const PRIVACY_STYLES = ["Blur", "Pixelate", "Solid"];

/** The kinds of region, with the screen's titles and outline colours. */
export const PRIVACY_KINDS = ["face", "plate", "text", "person"];
export const KIND_TITLES = { face: "faces", plate: "plates", text: "texts", person: "people" };
export const KIND_COLORS = { face: "#ffd60a", plate: "#64d2ff", text: "#ff9f0a", person: "#ff375f" };

/**
 * A part of the picture to hide: { kind, box (normalized, top-left origin, the frame as shown), mask? }.
 * People carry their instance (`{ maskWidth, maskHeight, mask }` over the whole picture) so the background
 * around them stays visible.
 */
export const region = (kind, box, mask = null) => ({ kind, box, mask });

/**
 * Keeps a region hidden for a while after its detector last saw it: a face missed for a frame or two
 * (head turning, motion blur) would otherwise flash into view.
 */
export class RegionHold {
  constructor(seconds = 0.6) { this.seconds = seconds; this.held = []; }

  /**
   * The regions to hide at `time` (s): everything found now, plus earlier ones not found again (same kind,
   * IoU > 0.2) that were last seen at most `seconds` ago.
   */
  update(found, time) {
    const next = found.map((r) => ({ region: r, seen: time }));
    for (const old of this.held) {
      if (time - old.seen > this.seconds) continue;
      const foundAgain = found.some((r) => r.kind === old.region.kind && Rect.iou(r.box, old.region.box) > 0.2);
      if (!foundAgain) next.push(old);
    }
    this.held = next;
    return next.map((h) => h.region);
  }

  reset() { this.held = []; }
}

export const PrivacyScan = {
  /** Face detectors in order of preference: scrfd_10g finds small, turned and partly covered faces best. */
  faceDetectorNames: ["scrfd_10g", "scrfd_2.5g", "retinaface_mobilenet_v1", "scrfd_500m"],
  /** Vehicles whose plates are looked for. */
  vehicleLabels: new Set(["car", "truck", "bus", "motorcycle"]),
  /** Plates are looked for on at most this many vehicles per frame (the largest), to keep the frame rate. */
  maxVehicles: 4,
  /** The instance model the screen starts with (the apps' default). */
  defaultInstanceModel: "yolov8s_seg",

  /** `box` grown by fractions of its own size (left and right by `x`), kept inside the picture (null if outside). */
  grow(box, x, top, bottom) {
    return Rect.intersection({ x: box.x - box.width * x, y: box.y - box.height * top, width: box.width * (1 + 2 * x), height: box.height * (1 + top + bottom) }, Rect.whole());
  },

  /** A face's region: its box grown so hair, ears and chin are covered too. */
  face(box) { return region("face", this.grow(box, 0.2, 0.35, 0.15)); },

  /** A text region (corners normalized to the picture) as a box, grown a little; kind "plate" or "text". */
  text(corners, kind = "text") {
    const xs = corners.map((p) => p.x), ys = corners.map((p) => p.y);
    if (!xs.length) return null;
    const box = { x: Math.min(...xs), y: Math.min(...ys), width: Math.max(...xs) - Math.min(...xs), height: Math.max(...ys) - Math.min(...ys) };
    const grown = this.grow(box, 0.15, 0.3, 0.3);
    return grown ? region(kind, grown) : null;
  },

  /**
   * The part of a W x H picture to look for text in: `area` (normalized) in whole pixels (outwards), as a
   * normalized rectangle again; null when smaller than 16 x 16 pixels (too small for the text detector).
   */
  searchArea(area, W, H) {
    const a = Rect.intersection(area, Rect.whole());
    if (!a) return null;
    const x0 = Math.floor(a.x * W), y0 = Math.floor(a.y * H), x1 = Math.ceil((a.x + a.width) * W), y1 = Math.ceil((a.y + a.height) * H);
    if (x1 - x0 < 16 || y1 - y0 < 16) return null;
    return { x: x0 / W, y: y0 / H, width: (x1 - x0) / W, height: (y1 - y0) / H };
  },

  /** People from an instance-segmentation result, with their masks. */
  people(instances) { return instances.filter((i) => i.detection.label === "person").map((i) => region("person", i.detection.boundingBox, i)); },

  /** The boxes of the largest `maxVehicles` vehicles of an instance-segmentation result. */
  vehicles(instances) {
    return instances.filter((i) => this.vehicleLabels.has(i.detection.label)).map((i) => i.detection.boundingBox)
      .sort((a, b) => b.width * b.height - a.width * a.height).slice(0, this.maxVehicles);
  },
};

const newCanvas = (w, h) => (typeof OffscreenCanvas !== "undefined" ? new OffscreenCanvas(w, h) : Object.assign(document.createElement("canvas"), { width: w, height: h }));

/** Whether this browser's 2D canvas applies `filter` (Safari before 18 ignores it). */
let filterWorks = null;
function canvasFilterWorks() {
  if (filterWorks !== null) return filterWorks;
  try {
    const c = newCanvas(8, 1), ctx = c.getContext("2d");
    ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, 4, 1);
    const plain = newCanvas(8, 1); plain.getContext("2d").drawImage(c, 0, 0);
    ctx.clearRect(0, 0, 8, 1);
    ctx.filter = "blur(2px)";
    ctx.drawImage(plain, 0, 0);
    ctx.filter = "none";
    filterWorks = ctx.getImageData(5, 0, 1, 1).data[3] > 0;   // the white spread past its edge
  } catch { filterWorks = false; }
  return filterWorks;
}

export const PrivacyFilter = {
  /** Blur sigma and pixel size: a fortieth of the picture's longer side, as the apps. */
  unit: (W, H) => Math.max(W, H) / 40,
  /** How far person masks are widened (pixels of the picture), so a moving person's edges are covered. */
  widen: (W, H) => Math.max(W, H) / 90,
  fill: "rgb(31, 31, 36)",

  /**
   * A new canvas: `image` (any drawable, W x H) with `regions` hidden in `style`. With no regions it is a
   * plain copy. Throws when the picture cannot be cleaned (callers then show nothing, not the original).
   */
  apply(image, regions, style = "Blur", W = image.width, H = image.height) {
    if (!(W > 0 && H > 0)) throw new Error("The picture has no size.");
    const out = newCanvas(W, H), ctx = out.getContext("2d");
    if (!ctx) throw new Error("No canvas to clean the picture in.");
    ctx.drawImage(image, 0, 0, W, H);
    if (!regions.length) return out;
    const hidden = this.hiddenLayer(image, W, H, style);
    const h = hidden.getContext("2d");
    h.globalCompositeOperation = "destination-in";
    h.drawImage(this.mask(regions, W, H), 0, 0);
    ctx.drawImage(hidden, 0, 0);
    return out;
  },

  /** The whole picture blurred, pixelated or filled (edges clamped, so the border blurs into itself, not into black). */
  hiddenLayer(image, W, H, style) {
    const layer = newCanvas(W, H), ctx = layer.getContext("2d");
    const unit = this.unit(W, H);
    if (style === "Solid") { ctx.fillStyle = this.fill; ctx.fillRect(0, 0, W, H); return layer; }
    if (style === "Pixelate") {
      // Blocks of about `unit` pixels from the top-left corner (CIPixellate centred at 0, 0), each the
      // colour of its part of the picture; whole blocks only, so the edges are covered too.
      const cw = Math.max(1, Math.round(W / unit)), ch = Math.max(1, Math.round(H / unit));
      const small = newCanvas(cw, ch), s = small.getContext("2d");
      s.imageSmoothingEnabled = true; s.imageSmoothingQuality = "high";
      s.drawImage(image, 0, 0, W, H, 0, 0, cw, ch);
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(small, 0, 0, W, H);
      return layer;
    }
    // Blur: a Gaussian of sigma `unit` over the picture with its edges repeated outwards (clamp). It is
    // worked out at a lower resolution (sigma 6 there; the same look, a fraction of the work) and scaled up.
    const f = Math.min(1, 6 / unit), w = Math.max(1, Math.round(W * f)), hh = Math.max(1, Math.round(H * f)), sigma = unit * f;
    const pad = Math.ceil(3 * sigma), padded = newCanvas(w + 2 * pad, hh + 2 * pad), p = padded.getContext("2d");
    p.imageSmoothingQuality = "high";
    p.drawImage(image, 0, 0, W, H, pad, pad, w, hh);
    p.drawImage(padded, pad, pad, w, 1, pad, 0, w, pad);                       // top
    p.drawImage(padded, pad, pad + hh - 1, w, 1, pad, pad + hh, w, pad);       // bottom
    p.drawImage(padded, pad, 0, 1, hh + 2 * pad, 0, 0, pad, hh + 2 * pad);     // left (with the corners)
    p.drawImage(padded, pad + w - 1, 0, 1, hh + 2 * pad, pad + w, 0, pad, hh + 2 * pad);   // right
    const blurred = newCanvas(w + 2 * pad, hh + 2 * pad), b = blurred.getContext("2d");
    if (canvasFilterWorks()) {
      b.filter = `blur(${sigma}px)`;
      b.drawImage(padded, 0, 0);
      b.filter = "none";
    } else {
      // No canvas filters: down to a quarter and smoothly up again (a softer but still strong blur).
      const tiny = newCanvas(Math.max(1, Math.round(blurred.width / sigma)), Math.max(1, Math.round(blurred.height / sigma)));
      const t = tiny.getContext("2d"); t.imageSmoothingQuality = "high";
      t.drawImage(padded, 0, 0, tiny.width, tiny.height);
      b.imageSmoothingQuality = "high";
      b.drawImage(tiny, 0, 0, blurred.width, blurred.height);
    }
    ctx.imageSmoothingQuality = "high";
    ctx.drawImage(blurred, pad, pad, w, hh, 0, 0, W, H);
    return layer;
  },

  /** Opaque where the picture is hidden: boxes, and people's masks scaled to the picture and widened. */
  mask(regions, W, H) {
    const mask = newCanvas(W, H), ctx = mask.getContext("2d");
    ctx.fillStyle = "#fff";
    for (const r of regions) {
      const m = r.mask;
      if (m && m.maskWidth > 0 && m.maskHeight > 0 && m.mask?.length === m.maskWidth * m.maskHeight) {
        const radius = this.widen(W, H) * Math.max(m.maskWidth / W, m.maskHeight / H);   // in mask cells
        const bits = dilate(m.mask, m.maskWidth, m.maskHeight, radius);
        const cells = newCanvas(m.maskWidth, m.maskHeight), c = cells.getContext("2d"), img = c.createImageData(m.maskWidth, m.maskHeight);
        for (let i = 0; i < bits.length; i++) if (bits[i]) { img.data[i * 4] = img.data[i * 4 + 1] = img.data[i * 4 + 2] = 255; img.data[i * 4 + 3] = 255; }
        c.putImageData(img, 0, 0);
        ctx.imageSmoothingEnabled = true;
        ctx.drawImage(cells, 0, 0, W, H);
      } else if (r.box) {
        const b = r.box;
        ctx.fillRect(b.x * W, b.y * H, b.width * W, b.height * H);
      }
    }
    return mask;
  },
};

/** The mask widened by a disc of `radius` cells (morphological maximum; at least one cell). */
export function dilate(mask, w, h, radius) {
  const r = Math.max(1, radius), R = Math.ceil(r), offsets = [];
  for (let dy = -R; dy <= R; dy++) for (let dx = -R; dx <= R; dx++) if (dx * dx + dy * dy <= r * r) offsets.push([dx, dy]);
  const out = new Uint8Array(w * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    if (!mask[y * w + x]) continue;
    for (const [dx, dy] of offsets) {
      const X = x + dx, Y = y + dy;
      if (X >= 0 && X < w && Y >= 0 && Y < h) out[Y * w + X] = 255;
    }
  }
  return out;
}
