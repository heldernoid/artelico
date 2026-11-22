# Artelico Web

Artelico as a static website: the same vision models, demo screens and language features as the
Artelico app, running in the browser. Nothing is uploaded; pictures, sound and text stay in the page.

## Run it

    python3 web/serve.py            # http://localhost:8000/

`serve.py` sends the cross-origin isolation headers (several WebAssembly threads) and the right file
types. Any static host works; without those headers ONNX Runtime uses one thread.

Needs a recent Chrome or Edge (WebGPU). Without WebGPU the vision models run on WebAssembly (slower)
and the language models are not available.

## Where the models come from

- Vision models: `web/models/` (a link to `native/web/`), written by
  `.venv-convert/bin/python -I native/tools/export_web.py [names]`. Each is the same ONNX graph the Core ML
  package was made from, with 8-bit RGB input (as the stick takes it) and the Model Zoo normalization
  inside; `<name>.native.json` maps its outputs to the stick's layout, so the decoders are shared logic.
  A model downloads the first time it is used and stays in the browser (Cache Storage); "Models" can
  keep models offline or use a folder on this computer instead (Chrome/Edge).
- `native/web/backends.json`: models whose WebGPU results differ from WebAssembly's (measured with
  `compare.html`); they run on WebAssembly.
- Tagging from text (13 CLIP / TinyCLIP / SigLIP / SigLIP 2 image encoders, each with its own text
  encoder, `js/core/clip.js`): the web text encoders take token embeddings, so the page also reads the
  tables `native/tools/clip_assets.py` made from the repository's `coreml/` folder: `<text>.tokens.npy`
  (float16; only the rows of the prompt's tokens, with HTTP range requests, so siglip2's 393 MB table costs
  a few KB per prompt), `<text>.projection.npy` (CLIP, 1-2.4 MB) and `<text>.final_norm.npy` (TinyCLIP).
  From this site's `models/`, `serve.py` serves them at `/coreml/` (from `native/coreml`); a folder chosen
  in "Models" must hold them next to the ONNX files.
- Language models (WebLLM: Qwen2.5, Qwen3, Llama 3.2, Qwen2.5 Coder, Phi-3.5 vision) and Whisper
  (Transformers.js) download from Hugging Face the first time and stay in the browser.

## Layout

- `js/core/`: catalog, engine (ONNX Runtime Web), picture preparation, decoders, tracker, two-model
  pipelines (text, faces, pose after a person detector, face and person crops, video clips), language and
  speech. Ports of `UGenKit/Sources/StudioCore`.
- `data/`: copies of StudioCore's Resources (models.json, labels.json, ppocrv5_characters.json,
  tddfa_bfm68.bin: the 68-point part of the Basel Face Model for 3DDFA, under the BFM's own licence) and
  the tokenizers of tagging from text: `clip_tokenizer.json` (openai/clip-vit-base-patch32's
  tokenizer.json, MIT), `siglip_tokenizer.json` (google/siglip-base-patch16-224's spiece.model, Apache-2.0)
  and `siglip2_tokenizer.json` (google/siglip2-base-patch32-256's tokenizer.model, Apache-2.0); the two
  SentencePiece ones as written by `native/tools/clip_assets.py`.
- `js/rules/`: the demos' rules (pose, detection, hands, photo restore, privacy, language), ports of the Swift ones.
- `js/ui/`: pages. `examples/` = the UGen300 demo screens, `language/` = chat, pictures, speech, demos.
- Privacy camera (`examples/privacy-screen.js`, rules in `js/rules/privacy.js`, port of StudioCore's
  Privacy.swift): faces (scrfd_10g, else scrfd_2.5g / retinaface_mobilenet_v1 / scrfd_500m), licence plates
  (ocr_det inside the 4 largest vehicles of the instance model, yolov8s_seg by default), all text, whole people
  (instance masks, widened) hidden by blur, pixelate or a solid fill; a region stays hidden 0.6 s after it was
  last found. Each frame is grabbed into an offscreen canvas and cleaned into a new one; only that copy is
  shown and recorded (MediaRecorder: MP4 where the browser writes it, else WebM). If cleaning fails the
  camera stops and the picture is taken off the screen.
- Steady video (port of StudioCore's PacedVideo.swift and TrackSmoothing.swift; rules in `js/rules/steady-video.js`):
  - video files are not played freely: `js/ui/runner.js` keeps the `<video>` paused and seeks it to exact frames, an
    even step each time (`FramePacer`: the step changes only when the video drifts more than 0.4 s from the clock;
    a model faster than the video gets every frame at the video's own speed), looping at the end. The next frame is
    sought while the model works on this one. Cameras and streams still give their newest frame;
  - `ObjectTracker.track(result, time)` (`js/core/tracker.js`) steadies numbered boxes and body points per track
    number with One-Euro filters (`TrackSmoother`, `steadies`, on by default), which reaches every example screen
    that tracks (pose screens, Head count, Missing check...). Masks are not tracked or steadied.
- `vendor/`: pinned copies of ONNX Runtime Web 1.30.0, WebLLM 0.2.87, Transformers.js 4.3.2.

## Checks

    python3 web/tools/selftest.py "test.html?checks=all"     # every model through its decoder
    python3 web/tools/selftest.py "compare.html"             # WebGPU against WebAssembly, every model
    python3 web/tools/selftest.py "rules-test.html"          # the Swift rule tests, ported (86)
    python3 web/tools/selftest.py "test.html?tokens"         # the tokenizers against Hugging Face (424 phrases)
    python3 web/tools/selftest.py "test.html?checks=clip:all@bus.jpg+dog_bicycle.jpg+apple.jpg"   # tagging, 13 pairs
    python3 web/tools/shot.py out.png "index.html#plates?autostart" --wait "…"   # screenshot of a page

All run in headless Chrome with a throwaway profile (`--profile` keeps one, so downloads are cached).

## Licence

AGPL-3.0 (see `LICENSE`). Several of the models it uses (Ultralytics YOLO) are AGPL-3.0 as well; each
model's licence is listed in the model repository's README.
