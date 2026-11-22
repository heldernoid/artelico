"""Stages the models for the Hugging Face model repo the apps download from.

    python3 native/tools/package_hf.py            # -> native/hf/stage/

Layout of the repo:
    coreml/<name>.mlpackage/...  (+ <name>.native.json, extra files)   iPhone, iPad, Mac (Artelico)
    web/<name>.onnx              (+ <name>.native.json)                 Artelico Web
    manifest.json   per model: licence, source, and every file with size and sha256
    README.md       the model card, with the licence of every model

Every model is staged, each with its licence from native/hf/licences.json (shown in the README). Stage files are hard links or zips, so
the stage folder costs no extra disk. Core ML packages stay folders (each file listed in the manifest), so
the apps download plain files and need no unzipping.
"""
import hashlib, json, os, shutil, subprocess, sys

NATIVE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
STAGE = os.path.join(NATIVE, "hf", "stage")
ALLOWED = {"permissive", "copyleft", "non-commercial", "no licence"}   # every model, each labelled
EXTRA = {"all_minilm_l6_v2": ["all_minilm_l6_v2.vocab.txt"]}
# CLIP / SigLIP text encoders' tables (native/tools/clip_assets.py; StudioCore's CLIPPair.textFiles lists which
# each one needs): staged with the model when they exist in native/coreml.
TEXT_TABLES = (".tokens.npy", ".projection.npy", ".final_norm.npy", ".tokenizer.json")


def extra_files(name):
    return EXTRA.get(name, []) + [name + suffix for suffix in TEXT_TABLES if name.endswith("_text_encoder")]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 22), b""):
            h.update(chunk)
    return h.hexdigest()


def link(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.exists(dst):
        os.remove(dst)
    os.link(src, dst)


def link_package(src, dst):
    """Hard-links every file of <name>.mlpackage; returns their paths relative to the stage."""
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    out = []
    for root, _, files in os.walk(src):
        for f in sorted(files):
            if f == ".DS_Store":
                continue
            target = os.path.join(dst, os.path.relpath(os.path.join(root, f), src))
            link(os.path.join(root, f), target)
            out.append(os.path.relpath(target, STAGE))
    return sorted(out)


def entry(relative):
    path = os.path.join(STAGE, relative)
    return {"path": relative, "bytes": os.path.getsize(path), "sha256": sha256(path)}


def main():
    licences = json.load(open(os.path.join(NATIVE, "hf", "licences.json")))
    names = sys.argv[1:] or sorted(licences)
    manifest = {"models": {}}
    skipped = []
    for i, name in enumerate(names, 1):
        info = licences[name]
        if info["group"] not in ALLOWED:
            skipped.append(f"{name} ({info['licence']})")
            continue
        files = {"coreml": [], "web": []}
        package = os.path.join(NATIVE, "coreml", f"{name}.mlpackage")
        if os.path.isdir(package):
            stale = os.path.join(STAGE, "coreml", f"{name}.mlpackage.zip")
            if os.path.exists(stale):
                os.remove(stale)
            files["coreml"] += link_package(package, os.path.join(STAGE, "coreml", f"{name}.mlpackage"))
            for extra in [f"{name}.native.json"] + extra_files(name):
                src = os.path.join(NATIVE, "coreml", extra)
                if os.path.exists(src):
                    link(src, os.path.join(STAGE, "coreml", extra))
                    files["coreml"].append(f"coreml/{extra}")
        for extra in (f"{name}.onnx", f"{name}.native.json"):
            src = os.path.join(NATIVE, "web", extra)
            if os.path.exists(src) and (extra.endswith(".onnx") or os.path.exists(os.path.join(NATIVE, "web", f"{name}.onnx"))):
                link(src, os.path.join(STAGE, "web", extra))
                files["web"].append(f"web/{extra}")
        manifest["models"][name] = {
            "licence": info["licence"], "source": info["source"],
            "coreml": [entry(f) for f in files["coreml"]], "web": [entry(f) for f in files["web"]],
        }
        print(f"[{i}/{len(names)}] {name}: {len(files['coreml'])} Core ML, {len(files['web'])} web files", flush=True)
    for shared in ("index.json", "backends.json"):
        src = os.path.join(NATIVE, "web", shared)
        if os.path.exists(src):
            shutil.copyfile(src, os.path.join(STAGE, "web", shared))
    manifest["version"] = 1
    json.dump(manifest, open(os.path.join(STAGE, "manifest.json"), "w"), indent=1, sort_keys=True)
    write_readme(manifest["models"])
    # The models Artelico offers (only these appear in its lists; Hailo Studio keeps the whole table).
    app_list = os.path.join(NATIVE, "..", "Artelico", "App", "artelico-models.json")
    json.dump(sorted(n for n, m in manifest["models"].items() if m["coreml"]), open(app_list, "w"), indent=0)
    total = sum(f["bytes"] for m in manifest["models"].values() for f in m["coreml"] + m["web"])
    print(f"staged {len(manifest['models'])} models, {total / 1e9:.1f} GB; left out: {', '.join(skipped) or 'none'}")


def catalog():
    """Tasks and input size of every model (the apps' model table)."""
    path = os.path.join(NATIVE, "..", "UGenKit", "Sources", "StudioCore", "Resources", "models.json")
    out = {}
    for m in json.load(open(path)):
        image = next((i for i in m.get("inputs", []) if i.get("features") in (1, 3)), (m.get("inputs") or [{}])[0])
        size = f"{image.get('width')}x{image.get('height')}" if image.get("width") else ""
        out[m["name"]] = {"tasks": ", ".join(t.replace("_", " ") for t in m.get("tasks", [])), "input": size}
    return out


def write_readme(models):
    table = catalog()
    mb = lambda files: sum(f["bytes"] for f in files) / 1e6
    rows = "\n".join(
        f"| {n} | {table.get(n, {}).get('tasks', '')} | {table.get(n, {}).get('input', '')} | "
        f"{mb(m['coreml']):.0f} | {mb(m['web']):.0f} | {m['licence']} | [source]({m['source']}) |"
        for n, m in sorted(models.items()))
    count = len(models)
    open(os.path.join(STAGE, "README.md"), "w").write(f"""---
license: other
license_name: per-model
license_link: https://huggingface.co/helmo/artelico-models/blob/main/README.md
library_name: coreml
pipeline_tag: object-detection
tags: [coreml, onnx, onnxruntime-web, computer-vision, on-device, apple-neural-engine, hailo-model-zoo,
       object-detection, image-classification, pose-estimation, image-segmentation, depth-estimation]
---

# Artelico models

{count} computer-vision models ready to run **on the device**: Core ML for iPhone, iPad and Mac, and ONNX for
the browser (ONNX Runtime Web, WebGPU or WebAssembly). They are what the open-source Artelico apps download
the first time a model is used. Nothing is sent to a server: pictures stay on the device.

**Try them in your browser:** [Artelico Web on Spaces](https://huggingface.co/spaces/helmo/artelico)
(direct link: https://helmo-artelico.static.hf.space).

The models are the networks of the [Hailo Model Zoo](https://github.com/hailo-ai/hailo_model_zoo) v5.3.0
(MIT): detection (YOLOv5 to YOLO26, YOLOX, DAMO-YOLO, NanoDet, SSD, EfficientDet, DETR), classification
(ResNet, EfficientNet, MobileNet, ViT, DeiT, Swin, LeViT, FastViT, ...), pose, instance and semantic
segmentation, oriented boxes (DOTA), depth (Depth Anything, FastDepth, SC-Depth), faces (SCRFD, ArcFace),
lanes, OCR (PaddleOCR), super-resolution, denoising, low-light enhancement, CLIP / SigLIP / TinyCLIP
encoders and more.

## Files

| Path | What |
|---|---|
| `coreml/<name>.mlpackage/` | Core ML package (ML Program). The device compiles it on first use; Neural Engine where it can. |
| `coreml/<name>.native.json` | How the outputs map to the layout the decoders read (see below). |
| `coreml/<text encoder>.tokens.npy` | CLIP / SigLIP text encoders: token embedding table (float16), the encoder's input is one row per token. From the source ONNX, the Model Zoo's .npz or (CLIP ResNet-50, ResNet-50x4, ViT-L/14) OpenAI's weights via timm's open_clip files; same licence as the model. |
| `coreml/<text encoder>.projection.npy`, `.final_norm.npy` | CLIP text projection (float32, width x embedding); TinyCLIP's final layer norm (weight, bias), which Hailo's cut leaves out. |
| `coreml/siglip2_b_32_256_text_encoder.tokenizer.json` | Gemma's SentencePiece vocabulary (256k pieces) from google/siglip2-base-patch32-256 (Apache-2.0). |
| `web/<name>.onnx` | The same network for the browser. Input: 8-bit RGB, NHWC, normalization inside the graph. |
| `web/<name>.native.json` | The same output map, with the ONNX output names. |
| `web/index.json`, `web/backends.json` | Model list and sizes; models that must run on WebAssembly. |
| `manifest.json` | Every model: licence, source, and each file with its size and SHA-256. |

## How they were made

1. The Model Zoo's original ONNX (or TFLite) file for each network, the one Hailo compiles for its chips.
2. Cut where Hailo's compiler cuts it (the zoo's end nodes), so the post-processing is done by the app,
   as on Hailo hardware, with the same decoders for every runtime.
3. Converted with coremltools (Core ML), or wrapped for the browser: a uint8 NHWC input with the zoo's
   mean and standard deviation, ceil-mode pooling rewritten as padding, constants folded.
4. Checked: each converted model's decoded result on sample pictures against the Hailo stick's
   (`native.json` maps are made by matching the outputs to the stick's output streams).

`native.json` lists, for each output, the stick output it corresponds to, its layout and an optional
activation, so one set of decoders (NMS, anchors, DFL boxes, keypoints, masks, ...) serves the Hailo
stick, Core ML and the browser.

## Using them

**Swift (Core ML)**: download the files listed for a model in `manifest.json` (keep the folder layout),
check their SHA-256, then:

```swift
let url = modelsFolder.appendingPathComponent("yolov8s.mlpackage")
let compiled = try await MLModel.compileModel(at: url)
let model = try MLModel(contentsOf: compiled, configuration: MLModelConfiguration())
```

**Browser (ONNX Runtime Web)**:

```js
const url = "https://huggingface.co/helmo/artelico-models/resolve/main/web/yolov8s.onnx";
const session = await ort.InferenceSession.create(url, {{ executionProviders: ["webgpu", "wasm"] }});
// input: Uint8Array of height x width x 3 RGB pixels, shape [1, H, W, 3]
```

The Artelico apps (iOS / iPadOS / macOS and the web version) do this, and decode the outputs.

## Limitations

- Accuracy is the original networks' (see each source); the conversion is checked against the Hailo
  stick on sample pictures, not re-evaluated on the full benchmarks.
- A few detectors have no `native.json` map yet (some EfficientDet, NanoDet, SSD, YOLOX and YOLOv5/v7
  variants): they load and run, but the apps' decoders do not read their outputs yet.
- The first load of a large transformer on a Mac can take minutes while macOS compiles it for the
  Neural Engine; it is cached afterwards.

## Licences

Each model keeps the licence of its original project, listed per model below and in `manifest.json`.

- Apache-2.0, MIT, BSD-3-Clause, public domain and Apple's sample-code licence: free use with attribution.
- GPL-3.0 / AGPL-3.0 (Ultralytics YOLOv5, v8, 11, 26, YOLOv10, v12, FastSAM; YOLOv6, v7, v9; YOLO-World; SC-Depth):
  only in software under a compatible open-source licence (Artelico is AGPL-3.0).
- **Non-commercial research only**: the InsightFace models (arcface_*, scrfd_*) and SegFormer.
- **No licence published** (all rights stay with their authors): person_attr_resnet_v1_18 and stereonet.
  Check with them before using these two beyond research.

## Models

Sizes in MB (Core ML / web).

| Model | Task | Input | Core ML | Web | Licence | Source |
|---|---|---|---:|---:|---|---|
{rows}

## Credits

The Hailo Model Zoo, and the authors of every network listed above.
""")


if __name__ == "__main__":
    main()
