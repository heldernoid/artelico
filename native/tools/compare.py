"""Run an ONNX model (ONNX Runtime) and its Core ML conversion on the same input and compare outputs.

Image inputs get the letterboxed picture (stereo models get it twice); other inputs get the same random
values on both sides.

usage: compare.py <model.onnx> <model.mlpackage> <image> [mean] [std]
COMPUTE_UNITS=CPU_ONLY (or CPU_AND_GPU, ALL) picks the Core ML compute units; default ALL.
SAVE_NPZ=<file.npz> also saves both sides' outputs (onnx0.., coreml0..) for check_decoded.py.
"""
import os
import sys
import time

import coremltools as ct
import numpy as np
import onnxruntime as ort
from PIL import Image

onnx_path, ml_path, image_path = sys.argv[1:4]
mean = np.array([float(x) for x in (sys.argv[4] if len(sys.argv) > 4 else "0,0,0").split(",")], np.float32)
std = np.array([float(x) for x in (sys.argv[5] if len(sys.argv) > 5 else "255,255,255").split(",")], np.float32)
sess = ort.InferenceSession(onnx_path)
ml = ct.models.MLModel(ml_path, compute_units=ct.ComputeUnit[os.environ.get("COMPUTE_UNITS", "ALL")])
ml_inputs = [i.name for i in ml.get_spec().description.input]
ml_names = [o.name for o in ml.get_spec().description.output]   # same order as the ONNX outputs

onnx_feed, ml_feed = {}, {}
rng = np.random.default_rng(0)
for graph_input, ml_name in zip(sess.get_inputs(), ml_inputs):
    shape = [d if isinstance(d, int) else 1 for d in graph_input.shape]
    if len(shape) == 4 and shape[1] == 3:
        _, _, h, w = shape
        img = Image.open(image_path).convert("RGB")
        scale = min(w / img.width, h / img.height)
        resized = img.resize((round(img.width * scale), round(img.height * scale)), Image.BILINEAR)
        canvas = Image.new("RGB", (w, h), (114, 114, 114))
        canvas.paste(resized, ((w - resized.width) // 2, (h - resized.height) // 2))
        onnx_feed[graph_input.name] = ((np.asarray(canvas, np.float32) - mean) / std).transpose(2, 0, 1)[None]
        ml_feed[ml_name] = canvas
    else:
        values = rng.standard_normal(shape).astype(np.float32) * 0.1
        onnx_feed[graph_input.name] = values
        ml_feed[ml_name] = values

ref = sess.run(None, onnx_feed)
ml.predict(ml_feed)
t = time.time(); out = ml.predict(ml_feed); t = (time.time() - t) * 1000
for o, mlname, r in zip(sess.get_outputs(), ml_names, ref):
    c = np.asarray(out[mlname]).reshape(r.shape)
    err = np.abs(c.astype(np.float64) - r.astype(np.float64))
    print(f"{o.name} {r.shape}: max |diff| {err.max():.4f}, mean {err.mean():.5f}, ref range {r.min():.2f}..{r.max():.2f}")
print(f"Core ML on this Mac ({os.environ.get('COMPUTE_UNITS', 'ALL')} compute units): {t:.1f} ms")
if os.environ.get("SAVE_NPZ"):   # both sides' outputs, for decoded-result checks (check_decoded.py)
    np.savez(os.environ["SAVE_NPZ"], **{f"onnx{i}": r for i, r in enumerate(ref)},
             **{f"coreml{i}": np.asarray(out[n]).reshape(r.shape) for i, (n, r) in enumerate(zip(ml_names, ref))})
if ref[0].ndim == 3 and ref[0].shape[1] == 84:
    for name, arr in (("onnx", ref[0][0]), ("coreml", np.asarray(out[ml_names[0]]).reshape(ref[0].shape)[0])):
        scores = arr[4:].max(0); keep = np.argsort(-scores)[:6]
        print(name, [(int(arr[4:, i].argmax()), round(float(scores[i]), 3)) for i in keep])
