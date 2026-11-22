// Picture-in, picture-out models on whole photos, tile by tile (port of StudioCore/PhotoRestore.swift):
// brighten (zero_dce), remove noise (dncnn_color_blind), upscale x2 (real_esrgan_x2). Plus EdgeVsCloud's figures.

export const STEPS = [
  { id: "brighten", model: "zero_dce", title: "Brighten" },
  { id: "denoise", model: "dncnn_color_blind", title: "Remove noise" },
  { id: "upscale", model: "real_esrgan_x2", title: "Upscale ×2" },
];

/** Zero-DCE brightens even bright pictures: cap the strength by mean brightness (as the demo). */
export const brightenStrength = (meanBrightness, user = 1) => Math.min(user, Math.max(0.15, Math.min(0.9, (150 - meanBrightness) / 125)));

export function meanBrightness(rgb) {
  let sum = 0;
  for (let i = 0; i + 2 < rgb.length; i += 3) sum += 0.299 * rgb[i] + 0.587 * rgb[i + 1] + 0.114 * rgb[i + 2];
  return rgb.length >= 3 ? sum / Math.floor(rgb.length / 3) : 0;
}

/** Runs `model` over the whole picture in overlapping tiles. Returns { rgb, width, height }. */
export async function restore(rgb, width, height, model, engine, progress) {
  const input = model.inputs[0], tileW = input.width, tileH = input.height, outW = model.outputs[0]?.width;
  if (!tileW || !tileH || !outW || outW % tileW) throw new Error(`${model.name} is not a picture-to-picture model.`);
  const scale = outW / tileW, margin = 16;
  const stepX = Math.max(1, tileW - 2 * margin), stepY = Math.max(1, tileH - 2 * margin);
  const columns = Math.max(1, Math.ceil(width / stepX)), rows = Math.max(1, Math.ceil(height / stepY));
  const outWidth = width * scale, outHeight = height * scale, output = new Uint8Array(outWidth * outHeight * 3);
  let done = 0;
  for (let row = 0; row < rows; row++) for (let column = 0; column < columns; column++) {
    const coreX = column * stepX, coreY = row * stepY, tile = new Uint8Array(tileW * tileH * 3);
    for (let y = 0; y < tileH; y++) {
      const sy = Math.min(Math.max(coreY - margin + y, 0), height - 1);
      for (let x = 0; x < tileW; x++) {
        const sx = Math.min(Math.max(coreX - margin + x, 0), width - 1), s = (sy * width + sx) * 3, d = (y * tileW + x) * 3;
        tile[d] = rgb[s]; tile[d + 1] = rgb[s + 1]; tile[d + 2] = rgb[s + 2];
      }
    }
    const v = (await engine.infer([tile], model.name))[0].values;
    const coreW = Math.min(stepX, width - coreX), coreH = Math.min(stepY, height - coreY), outTileW = tileW * scale;
    for (let y = 0; y < coreH * scale; y++) {
      const ty = y + margin * scale, oy = coreY * scale + y;
      for (let x = 0; x < coreW * scale; x++) {
        const s = (ty * outTileW + x + margin * scale) * 3, d = (oy * outWidth + coreX * scale + x) * 3;
        if (s + 2 >= v.length) continue;
        for (let c = 0; c < 3; c++) output[d + c] = Math.min(Math.max(v[s + c], 0), 1) * 255 + 0.5;
      }
    }
    progress?.(++done, rows * columns);
  }
  return { rgb: output, width: outWidth, height: outHeight };
}

/** strength 0 = original, 1 = processed (the original is scaled when sizes differ). */
export function blend(original, width, height, processed, outWidth, outHeight, strength) {
  if (strength >= 1) return processed;
  const out = new Uint8Array(processed.length);
  for (let y = 0; y < outHeight; y++) {
    const sy = Math.min(height - 1, Math.floor((y * height) / outHeight));
    for (let x = 0; x < outWidth; x++) {
      const sx = Math.min(width - 1, Math.floor((x * width) / outWidth)), s = (sy * width + sx) * 3, d = (y * outWidth + x) * 3;
      for (let c = 0; c < 3; c++) out[d + c] = Math.round(processed[d + c] * strength + original[s + c] * (1 - strength));
    }
  }
  return out;
}

/** EdgeVsCloud's figures (the demo's reference values; the network time is measured). */
export const EdgeCloud = {
  cloudServerMilliseconds: 250, cloudDollarsPerThousand: 1.5, cloudWatts: 300, secondsPerWorkMonth: 3600 * 8 * 22,
  compare({ edgeMilliseconds, framesPerSecond, frames, connectMilliseconds }) {
    const network = connectMilliseconds == null ? null : connectMilliseconds * 2;
    const cloud = network == null ? null : network + this.cloudServerMilliseconds;
    return {
      edgeMilliseconds, framesPerSecond, frames, network, cloud,
      cloudFramesPerSecond: cloud ? 1000 / cloud : null,
      dollarsSoFar: (frames * this.cloudDollarsPerThousand) / 1000,
      dollarsPerMonth: (framesPerSecond * this.secondsPerWorkMonth * this.cloudDollarsPerThousand) / 1000,
      speedup: cloud && edgeMilliseconds > 0 ? cloud / edgeMilliseconds : null,
    };
  },
};
