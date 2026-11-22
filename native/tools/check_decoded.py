"""Check converted models on decoded results, not raw numbers: ONNX Runtime vs Core ML (16-bit weights,
ALL compute units, as in the apps) on the same picture, then compare what an app would show.

Raw outputs differ by up to a few units in cells that do not matter (background, very low scores), so
compare.py's max |diff| alone cannot say whether a conversion is good. Here:
  detection    pass = no missing/extra and 99% of matched scores within 0.06; candidates above 0.30 on either side, keyed by (output, anchor, class, y, x); counted as
               matched, or missing/extra when the other side is below 0.25 (between 0.25 and 0.30 is a
               borderline case, not an error); plus the largest score difference among matches
  segmentation per-pixel argmax agreement
  pose heatmap per-keypoint peak position distance (heatmap pixels)
  embedding    cosine similarity
  attributes   agreement of sigmoid > 0.5
  image        PSNR (dB) over the reference range
  other        cosine similarity of the flattened output

usage: check_decoded.py <model> [model ...]     (writes one JSON line per model to native/check-decoded.jsonl)
"""
import glob, json, os, subprocess, sys
import numpy as np

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
NATIVE = os.path.join(ROOT, "native")
PY = os.path.join(ROOT, ".venv-convert/bin/python")
TMP = os.path.join(NATIVE, "check-tmp")
CONFIGS = {c["name"]: c for c in json.load(open(os.path.join(NATIVE, "zoo-configs.json")))}
HI, LO = 0.30, 0.25


def sig(x): return 1 / (1 + np.exp(-x))


def as_prob(x): return x if x.min() >= -1e-3 and x.max() <= 1 + 1e-3 else sig(x)


def family(name, shapes):
    if "obb" in name: return "obb"
    if name.startswith("yolox"): return "yolox"
    if name.startswith("yolov6"): return "yolov6"
    if name.startswith("ssd"): return "ssd"
    if name.startswith("centerpose"): return "centerpose"
    if name.startswith("yolo26") and "seg" in name: return "yolo26seg"
    if name.startswith("efficientdet"): return "effdet"
    if len(shapes) == 1 and len(shapes[0]) == 2 and shapes[0][1] == 1000: return "classification"
    if len(shapes) == 1 and len(shapes[0]) == 3 and shapes[0][1] == 84: return "v8single"
    if all(len(s) == 4 and s[1] % 85 == 0 for s in shapes): return "anchor"
    if "text_encoder" in name or "reid" in name or "osnet" in name: return "embedding"
    if "attr" in name: return "attributes"
    if "deeplab" in name or "unet" in name: return "segmentation"
    if "pose" in name or "mspn" in name: return "heatmap"
    if "espcn" in name: return "image"
    return "other"


def image_for(fam, name):
    s = os.path.join(ROOT, "testdata/samples")
    if fam == "obb": return os.path.join(s, "dota_image.png")
    if fam == "image": return os.path.join(s, "input_image.png")
    if fam == "classification": return os.path.join(s, "apple.jpg")
    return os.path.join(ROOT, "testdata/bus.jpg")


def score_maps(fam, outs):
    """[(key prefix, probability array (anchors, classes, H, W) or (classes, N))] for detection families."""
    maps = []
    if fam == "anchor":
        for i, o in enumerate(outs):
            a = o[0].reshape(o.shape[1] // 85, 85, *o.shape[2:])
            p = as_prob(a)
            maps.append((i, p[:, 4:5] * p[:, 5:]))
    elif fam == "yolox":
        for i in range(0, len(outs), 3):   # (box 4, objectness 1, classes 80) per scale, probabilities
            maps.append((i, (outs[i + 1][0] * outs[i + 2][0])[None]))
    elif fam == "yolov6":
        for i, o in enumerate(outs):
            if o.shape[1] == 80: maps.append((i, as_prob(o[0])[None]))
    elif fam == "obb":
        for i, o in enumerate(outs):
            if o.shape[1] == 15: maps.append((i, sig(o[0])[None]))
    elif fam == "v8single":
        maps.append((0, outs[0][0][4:][None, :, None, :]))
    elif fam == "ssd":
        for i, o in enumerate(outs):
            if o.shape[1] % 91 == 0:
                a = o[0].reshape(o.shape[1] // 91, 91, *o.shape[2:])
                e = np.exp(a - a.max(1, keepdims=True)); p = e / e.sum(1, keepdims=True)
                maps.append((i, p[:, 1:]))   # class 0 is background
    elif fam == "yolo26seg":   # per scale: boxes 4, class logits 80, mask coefficients 32; then prototypes
        for i, o in enumerate(outs):
            if o.ndim == 4 and o.shape[1] == 80: maps.append((i, sig(o[0])[None]))
    elif fam == "effdet":      # per level: boxes (anchors x 4) and class logits (anchors x 90)
        for i, o in enumerate(outs):
            if o.shape[1] % 90 == 0:
                maps.append((i, sig(o[0].reshape(o.shape[1] // 90, 90, *o.shape[2:]))))
    elif fam == "centerpose":
        maps.append((0, sig(outs[0][0])[None]))
    return maps


def check_detection(fam, ref, ml):
    matched, missing, extra, border, diffs = 0, [], [], 0, []
    for (i, r), (_, c) in zip(score_maps(fam, ref), score_maps(fam, ml)):
        for idx in zip(*np.nonzero((r > HI) | (c > HI))):
            rv, cv = float(r[idx]), float(c[idx])
            key = (i,) + tuple(int(x) for x in idx)
            if rv > HI and cv > HI:
                matched += 1; diffs.append(abs(rv - cv))
            elif rv > HI and cv < LO: missing.append((key, round(rv, 3), round(cv, 3)))
            elif cv > HI and rv < LO: extra.append((key, round(rv, 3), round(cv, 3)))
            else: border += 1
    p99 = float(np.percentile(diffs, 99)) if diffs else 0.0
    ok = not missing and not extra and matched > 0 and p99 < 0.06   # single stray cells (Neural Engine) are merged by NMS
    return ok, {"matched": matched, "missing": missing[:5], "n_missing": len(missing), "extra": extra[:5],
                "n_extra": len(extra), "borderline": border, "p99_score_diff": round(p99, 4),
                "max_score_diff": round(max(diffs, default=0.0), 4)}


def cos(a, b):
    a, b = a.ravel().astype(np.float64), b.ravel().astype(np.float64)
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


def check_other(fam, ref, ml):
    r, c = ref[0][0], ml[0][0]
    if fam == "classification":
        top_r, top_c = list(np.argsort(-r)[:5]), list(np.argsort(-c)[:5])
        return top_r[0] == top_c[0] and set(top_r) == set(top_c), {"top5_same": top_r == top_c, "top1": int(top_r[0]),
                                                                  "max_logit_diff": round(float(np.abs(r - c).max()), 4)}
    if fam == "embedding":
        rows = [cos(x, y) for x, y in zip(r.reshape(-1, r.shape[-1]), c.reshape(-1, c.shape[-1]))]
        return min(rows) > 0.99, {"min_cosine": round(min(rows), 5), "mean_cosine": round(float(np.mean(rows)), 5)}
    if fam == "attributes":
        agree = float(((sig(r) > 0.5) == (sig(c) > 0.5)).mean())
        return agree == 1.0, {"agreement": agree}
    if fam == "segmentation":
        axis = 0 if r.shape[0] < r.shape[-1] else -1   # NCHW or NHWC
        agree = float((r.argmax(axis) == c.argmax(axis)).mean())
        return agree > 0.99, {"pixel_agreement": round(agree, 5)}
    if fam == "heatmap":
        d = []
        for k in range(r.shape[0]):
            a = np.array(np.unravel_index(r[k].argmax(), r[k].shape)); b = np.array(np.unravel_index(c[k].argmax(), c[k].shape))
            d.append(float(np.linalg.norm(a - b)))
        return max(d) <= 1.0, {"max_peak_distance": max(d), "keypoints_moved": sum(x > 0 for x in d)}
    if fam == "image":
        peak = float(r.max() - r.min()); mse = float(((r - c) ** 2).mean())
        psnr = 10 * np.log10(peak ** 2 / mse) if mse else 99.0
        return psnr > 40, {"psnr_db": round(psnr, 2)}
    v = cos(r, c)
    return v > 0.999, {"cosine": round(v, 6)}


def model_path(name):
    folder = os.path.join(NATIVE, "src", name)
    cut = os.path.join(folder, f"{name}.cut.onnx")
    if os.path.exists(cut): return cut
    found = [f for f in glob.glob(os.path.join(folder, "**/*.onnx"), recursive=True) if not f.endswith(".cut.onnx")]
    plain = [f for f in found if not f.endswith(".from_tflite.onnx")]
    return (plain or found)[0]


def run(name):
    cfg = CONFIGS[name]
    mean = ",".join(str(x) for x in (cfg["mean"] or [0, 0, 0]))
    std = ",".join(str(x) for x in (cfg["std"] or [1, 1, 1]))
    os.makedirs(TMP, exist_ok=True)
    npz = os.path.join(TMP, f"{name}.npz")
    onnx_path, ml = model_path(name), os.path.join(NATIVE, "coreml", f"{name}.mlpackage")
    import onnx
    shapes = [[d.dim_value for d in o.type.tensor_type.shape.dim] for o in onnx.load(onnx_path, load_external_data=False).graph.output]
    fam = family(name, shapes)
    p = subprocess.run([PY, "-I", os.path.join(NATIVE, "tools/compare.py"), onnx_path, ml, image_for(fam, name), mean, std],
                       capture_output=True, text=True, timeout=3600, env={**os.environ, "SAVE_NPZ": npz})
    if p.returncode != 0:
        return {"name": name, "family": fam, "ok": False, "error": (p.stderr.strip().splitlines() or ["?"])[-1]}
    d = np.load(npz)
    n = len([k for k in d.files if k.startswith("onnx")])
    ref = [d[f"onnx{i}"] for i in range(n)]; out = [d[f"coreml{i}"] for i in range(n)]
    os.remove(npz)
    ok, info = check_detection(fam, ref, out) if score_maps(fam, ref) else check_other(fam, ref, out)
    ms = [l for l in p.stdout.splitlines() if " ms" in l]
    return {"name": name, "family": fam, "ok": bool(ok), **info, "time": ms[0].split(": ")[-1] if ms else None}


if __name__ == "__main__":
    with open(os.path.join(NATIVE, "check-decoded.jsonl"), "a") as log:
        for name in sys.argv[1:]:
            try: row = run(name)
            except Exception as e: row = {"name": name, "ok": False, "error": f"{type(e).__name__}: {e}"}
            print(json.dumps(row, default=float), flush=True); log.write(json.dumps(row, default=float) + "\n")
