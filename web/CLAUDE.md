# Artelico Web

Static site, plain ES modules, **no build step and no npm**. The third-party libraries are pinned copies in
`vendor/`:
- ONNX Runtime Web 1.30.0;
- Transformers.js 4.3.2 (Whisper);
- WebLLM 0.2.87 (chat, picture questions).

`README.md` in this folder describes the layout and the features in detail. Read it first.

## Run and test

```sh
python3 web/serve.py                           # http://localhost:8000, with the cross-origin isolation headers
python3 web/tools/selftest.py "test.html?checks=detection:yolov8m@bus.jpg"   # one model, headless Chrome
python3 web/tools/selftest.py "test.html?checks=all"                         # every model through its decoder
python3 web/tools/selftest.py "rules-test.html"                              # the Swift rule tests, ported
python3 web/tools/selftest.py "compare.html"                                 # WebGPU vs WebAssembly per model
python3 web/tools/shot.py out.png "index.html#privacy"                       # screenshot of a page
```

- **What the tools need:** `selftest.py` and `shot.py` drive Google Chrome headless with a throwaway profile.
  - The path is set at the top of each file (`CHROME`, macOS by default). Change it on Linux or Windows.
  - Start `serve.py` first.
- **Where models come from:** `models/` next to the site when it exists (local output of
  `native/tools/export_web.py`), otherwise the pinned revision on Hugging Face (`js/core/source.js`).
  - `?models=hf` forces Hugging Face.
  - Models stay in the browser's Cache Storage after the first download.
- **Sample videos:** from `samples/videos/` if present, otherwise from Hugging Face (`js/ui/hailo-videos.js`).

## Map

- `js/app.js`: routing (`#<page>`), editions (`data-edition="space"` hides the language pages).
- `js/core/`: the engine (`engine.js`, ONNX Runtime Web), picture preparation, the catalogue, decoders, the tracker,
  two-model pipelines, CLIP tokenizers and text tables, language and speech.
- `js/rules/`: the demos' rules.
- `js/ui/`: pages, the shared runner (`runner.js`, sources, paced video, recording), and `examples/` (the demo
  screens).
- `data/`: copies of StudioCore's `Resources` plus tokenizers.
  - `tddfa_bfm68.bin` is not in the repository (Basel Face Model licence). Without it, `tddfa_mobilenet_v1` is
    hidden (`js/app.js`); `native/tools/make_tddfa_bfm68.py` makes it.

## GitHub Pages

```sh
python3 web/tools/build_pages.py               # -> web/_site (whole edition, without the test pages)
```

- **Workflow:** the public repository's `.github/workflows/pages.yml` runs this on each push to `main` that changes
  `web/` and deploys `_site`. The workflow file lives in this project's `github/` folder (exported by
  `tools/export_github.py`).
- **Threads:** Pages can't send the cross-origin isolation headers, so the build adds `coi-sw.js`, a service worker
  that adds them to the site's own responses. The first visit reloads once. Other sites' responses (Hugging Face)
  pass through untouched, which works because they're fetched with CORS.

## The Hugging Face Space

```sh
python3 web/tools/build_space.py               # -> native/hf/space (vision pages only, no WebLLM / Transformers.js)
```

Then upload the folder to a static Space with `huggingface_hub` (`HfApi().upload_folder(..., repo_type="space")`).

## Rules

- **Swift is the source:** `js/core` and `js/rules` port `UGenKit/Sources/StudioCore`, and each file says which
  Swift file it ports. Keep behaviour identical; the rules tests in `rules-test.html` are the Swift tests, ported.
- **Model data copies:** `data/models.json` and `data/labels.json` are copies of StudioCore's. Update both.
- **Pinned revisions:** keep the model revision pinned (`js/core/source.js`) and the video revision pinned
  (`js/ui/hailo-videos.js`). A new upload to the model repository must not change what an old page loads.
- **Things that need a server:** language models need WebGPU, and threads need the cross-origin isolation headers,
  which `serve.py` sends. A static host without them still works, with one WebAssembly thread.

## Welcome page

`index.html` starts with a plain welcome page (`#welcome`), shown on a first visit that names no screen (no `#hash`)
until **Open Artelico** (`artelico.welcomed` in localStorage). "About Artelico" in the sidebar shows it again.
The Space build (`data-edition="space"`) never shows it. Keep its wording plain and factual.

## Downloads start from a click

No screen downloads a model on its own. A screen may run by itself (a new picture, a chosen sample) only when the
model is already here (`app.isDownloaded`, `Speech.isDownloaded`); otherwise it says "Press Run to download <model>
(N MB)" and waits. Keep it that way in new screens.
