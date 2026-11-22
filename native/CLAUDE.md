# native/: model conversion and publishing

Turns Hailo Model Zoo models into the Core ML packages (Artelico) and ONNX files (Artelico Web) that are published at
https://huggingface.co/helmo/artelico-models. The whole flow is in `docs/models.md`; this is the quick reference.

## Environments (Python 3.12)

```sh
python3.12 -m venv .venv-convert && .venv-convert/bin/pip install -r native/requirements-convert.txt   # coremltools 9, onnx, onnxruntime
python3.12 -m venv .venv-tflite  && .venv-tflite/bin/pip install -r native/requirements-tflite.txt     # tf2onnx, for TFLite sources
```

- **Where the scripts expect them:** at the repository root (`convert_all.py` and `check_decoded.py` call
  `.venv-convert/bin/python` and `.venv-tflite/bin/python`).
- **Running them:** use `python -I`, so a file in the working folder can't shadow a module.

## Tools

| Tool | Does |
|---|---|
| `convert_all.py [name …]` | Download the Zoo source, cut the graph at Hailo's start/end nodes, bake in the normalisation, convert to Core ML, compare with ONNX Runtime. Settings: `../zoo-configs.json` |
| `convert_onnx.py` | One ONNX → Core ML conversion (used by convert_all) |
| `zoo_config.py` | Resolve a Zoo network config (its `base:` chain) and `.alls` script |
| `check_decoded.py` | ONNX Runtime vs Core ML on *decoded* results (what an app shows) |
| `compare.py` | Raw output comparison for one model |
| `compress.py` | 8-bit weight storage |
| `export_web.py [--maps] [name …]` | ONNX for the browser + `.native.json` → `native/web/` |
| `map_all.sh` | `ugen native-map` (stick vs Core ML → `.native.json`) for every model without a map. Needs the stick |
| `clip_assets.py` | Token tables, projections and norms for the CLIP / SigLIP text encoders |
| `convert_minilm.py` | Sentence embeddings for the assistant's tool choice |
| `export_ufld.py` | Ultra-Fast-Lane-Detection v2 rebuilt from its repository |
| `make_tddfa_bfm68.py <bfm_noneck_v3.pkl>` | The Basel Face Model landmark file (licence: accept it first) |
| `prefetch_zoo.sh`, `fetch_zoo_archive.sh` | Download Zoo archives ahead, 4 at a time |
| `package_hf.py` | Stage `native/hf/stage/` (packages, ONNX, maps, `manifest.json` with SHA-256, model card; licences from `hf/licences.json`) |
| `build_llama_xcframework.sh` | llama.cpp b12138 + Mac Catalyst slice for Artelico |
| `copy_to_device.sh <device> <list>` | Copy converted models into Artelico on a device (`ARTELICO_BUNDLE_ID` if yours differs) |

## Data in this folder

- **Model settings:** `zoo-configs.json` (per-model conversion settings) and `zoo-hailo10h-configs.json`.
- **Hailo's lists:** `zoo-hailo10h-inventory.json` (Hailo's Hailo-10H model list), `all-hefs.txt`.
- **Work lists:** `vision-models.txt`, `map-jobs.txt`, `todo-convert.txt`.
- **Not in git (generated):** `src/` (Zoo downloads), `coreml/`, `web/`, `hf/stage`, `hf/space`.

## Rules

- **Check every conversion against the stick:** use `ugen native-map`, or at least `check_decoded.py`, before
  publishing. A conversion that matches raw numbers can still decode differently.
- **Pin the revision:** after publishing, update the pinned revision in the apps and the web (see `docs/models.md`),
  and verify every manifest file on Hugging Face (size and LFS SHA-256).
- **Licences:** record each model's licence in `hf/licences.json`. Some are non-commercial; the model card must say
  so.
