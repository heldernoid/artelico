# Models: where they come from and how they're converted

Every model this project runs comes from **Hailo's Model Zoo** (v5.3.0, Hailo-10H), plus a few from hailo-apps and
the language models Hailo publishes for HailoRT 5.3.0. There are three forms of each model.

| Form | Used by | Where it comes from |
|---|---|---|
| `.hef` (compiled for the Hailo-10H, 8-bit) | Hailo Studio, `ugen`, notebooks | Hailo's servers. The apps download them on first use (URLs in `UGenKit/Sources/StudioCore/Resources/models.json`); `tools/download_hefs.sh` gets them all |
| Core ML `.mlpackage` + `.native.json` | Artelico | Converted here from the Zoo's ONNX/TFLite sources and published at https://huggingface.co/helmo/artelico-models (`coreml/`) |
| ONNX + `.native.json` | Artelico Web | The same graphs, exported for ONNX Runtime Web (`web/` in the same repository) |

## The model catalogue

- **The catalogue file:** `UGenKit/Sources/StudioCore/Resources/models.json`. It is built in two steps:
  1. `tools/build_catalog.py` lists every Hailo-10H model Hailo Studio can use, with its download address
     (`models/catalog.json`).
  2. `tools/build_model_info.py` adds each HEF's real inputs and outputs, read with Hailo's own library through
     `tools/hefinfo` (built by `tools/build_hefinfo.sh`) and `hailortcli parse-hef`.
- **What's in it:** each model's task, input size, outputs (names, shapes, quantisation), labels and download
  address.
- **Who reads it:** `ModelInfo.swift` (and `web/js/core/catalog.js`) read it. `VisionPipeline.supports(task, model:)`
  decides which screen can use which model.
- **Copies:** `web/data/models.json` is a copy, so keep the two in step.

## Decoding

- **What the stick returns:** raw tensors (or, for YOLO detectors, Hailo's on-chip NMS output).
- **The decoders:** `UGenKit/Sources/StudioCore/PostProcess*.swift` turn tensors into boxes, keypoints, masks,
  depth, text, lanes and so on. They are ports of the Model Zoo's and hailo-apps' Python post-processing, checked
  against it.
- **The web's copies:** `web/js/core/decode*.js` are line-by-line ports, so a fix in one place usually needs the
  same fix in the other.

## Converting to Core ML and ONNX (`native/tools/`)

You only need this to add or change a converted model. The published ones are on Hugging Face.

```sh
python3.12 -m venv .venv-convert && .venv-convert/bin/pip install -r native/requirements-convert.txt
python3.12 -m venv .venv-tflite  && .venv-tflite/bin/pip install -r native/requirements-tflite.txt   # TFLite sources only

.venv-convert/bin/python -I native/tools/convert_all.py yolov8s        # -> native/coreml/yolov8s.mlpackage
.venv-convert/bin/python -I native/tools/check_decoded.py yolov8s      # ONNX Runtime vs Core ML, decoded results
(cd UGenKit && swift run ugen native-map detection yolov8s ../testdata/bus.jpg ../native/coreml/yolov8s.mlpackage)
.venv-convert/bin/python -I native/tools/export_web.py yolov8s         # -> native/web/yolov8s.onnx (+ map)
```

What each step does:

1. **`convert_all.py`:**
   - downloads the Zoo source archive into `native/src/<name>/`;
   - cuts the ONNX graph at the start and end nodes Hailo uses, so its outputs are the HEF's outputs before any
     on-chip post-processing;
   - bakes in the model's normalisation (from the Zoo config and `.alls` script, read by `zoo_config.py`), so the
     input is 8-bit RGB as on the stick;
   - converts with coremltools 9 and compares with ONNX Runtime.

   Model settings are in `native/zoo-configs.json`.
2. **`check_decoded.py`:** compares what an app would *show* (boxes, classes, masks), not just raw numbers, with
   16-bit weights and all compute units, as in the apps.
3. **`ugen native-map`:**
   - runs the stick's HEF and the Core ML package on the same picture;
   - matches each Core ML output to the stick output it corresponds to;
   - writes `<name>.native.json`.

   Example: `{"outputs": [{"source": "var_435"}, {"activation": "sigmoid", "source": "var_433"}, …]}`. Hailo's model
   scripts sometimes add an activation on the chip that the original graph doesn't have, and the map says so.
   Thanks to the map, Core ML and web results go through **the same decoders** as the stick's. `map_all.sh` runs it
   for every model without a map.
4. **`export_web.py`:** writes the browser version of the same graph, with 8-bit RGB input and the normalisation
   inside.
5. **Optional:** `compress.py` stores weights as 8-bit, as the HEFs do.

Other notes:
- **CLIP-type models:** the text encoders need lookup tables next to them; `clip_assets.py` writes those.
- **Lane detection:** `export_ufld.py` rebuilds the lane model from its original repository.
- **Tool selection:** `convert_minilm.py` converts the sentence model that the assistant uses to pick tools.

## Publishing (`native/tools/package_hf.py`)

- **Staging:** it stages `native/hf/stage/` with:
  - `coreml/<name>.mlpackage/` as plain files, with no zips, because iOS can't unzip;
  - `web/<name>.onnx`;
  - `<name>.native.json`;
  - `manifest.json`, with every file's size and SHA-256 plus each model's licence and source;
  - a model card. Licences are in `native/hf/licences.json`.
- **Uploading:** upload with `huggingface_hub` (`HfApi().upload_folder`).
- **Pinned revisions:** the apps and the web download from a fixed revision, so a later upload can't change an
  installed build. When you publish a new revision, update the pin in:
  - `Artelico/App/ModelDownloads.swift` (`modelRevision`);
  - `UGenProbe/App/StudioModel.swift` (`clipFilesRevision`);
  - `web/js/core/source.js` (`HUGGING_FACE`).

If you fork the project with your own model repository, change `modelRepository` and those three pins.

## Licences

- **The models:** each model keeps its original licence: MIT, Apache, BSD, GPL/AGPL, and a few non-commercial ones
  (InsightFace, SegFormer).
- **Where they're listed:** the Hugging Face model card lists them per model, and `manifest.json`, which the apps
  read, carries each model's licence.
- **The one model kept out:** the Basel Face Model part (`tddfa_bfm68.bin`) has its own licence and is not
  published. See `native/tools/make_tddfa_bfm68.py`.
