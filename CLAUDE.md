# CLAUDE.md: guide for coding agents

This repository runs Hailo-10H models on Apple devices, with and without the ASUS UGen300 USB stick, and in the
browser. Read [README.md](README.md) for what it is. This file is the working map. Each part has its own
`CLAUDE.md` with details: `UGenKit/`, `Artelico/`, `UGenProbe/`, `web/`, `native/`, `tools/`.

## Layout

| Path | What | Language |
|---|---|---|
| `UGenKit/` | Swift package. **CUGenRT**: C runtime for the stick (loader + HailoRT 5.3.0 RPC). **StudioCore**: everything that does not need the stick (model catalogue, decoders, renderers, tracker, smoothing, demo rules, Core ML engine, RTSP, HTTP server). **UGenKit**: the stick device and the GenAI client. **ugen**: Mac CLI for testing on the stick | Swift, C |
| `UGenProbe/` | **Hailo Studio** (the folder and Xcode project keep the old name `UGenProbe`). iPad app + DriverKit driver (`Driver/`, `Shared/`), Mac Catalyst build | Swift, C++ (driver) |
| `Artelico/` | **Artelico**: the same demos on Core ML, llama.cpp and WhisperKit, no stick. `App/Examples/` holds the demo screens **shared by both apps** | Swift |
| `web/` | **Artelico Web**: static site, ES modules, no build step. `js/core` and `js/rules` are ports of StudioCore | JavaScript |
| `native/` | Model conversion (Zoo → Core ML / ONNX), checking against the stick, publishing to Hugging Face | Python, shell |
| `tools/` | Small C tools for the stick on a Mac, catalogue builders, setup scripts (runtime image, Xcode projects, Python wheel) | C, Python, shell |
| `notebooks/` | Jupyter with Hailo's `hailo_platform` on a Mac | Python |
| `docs/` | Building, the stick's protocol, models, porting, road cameras, open questions, and the full development log | |
| `testdata/` | `bus.jpg` and a tokenizer reference used by tests | |
| `images/`, `models/`, `vendor/`, `dist/` | **Not in git**: the runtime image, downloaded HEFs, third-party clones, built wheels | |

## Commands

```sh
# Library: build, test (stick tests are skipped unless UGEN_DEVICE_TESTS=1), CLI
cd UGenKit && swift build && swift test
swift run ugen boot | identify | health | models [task] | <task> <model> <image> [out.png|out.json] | bench <model>

# Apps: once per checkout, then after any project.yml change or added/removed Swift file
tools/fetch_runtime_image.sh                              # Hailo Studio needs images/…ext4
DEVELOPMENT_TEAM=<team> BUNDLE_ID_PREFIX=<prefix> tools/generate_projects.sh
cd Artelico  && xcodebuild -project Artelico.xcodeproj  -scheme Artelico  -destination 'platform=macOS,variant=Mac Catalyst' build
cd UGenProbe && xcodebuild -project UGenProbe.xcodeproj -scheme UGenProbe -destination 'platform=macOS,variant=Mac Catalyst' build
# compile check without signing: add CODE_SIGNING_ALLOWED=NO

# Web
python3 web/serve.py                                      # http://localhost:8000
python3 web/tools/build_pages.py                          # -> web/_site, what the Pages workflow publishes
python3 web/tools/selftest.py "test.html?checks=detection:yolov8m@bus.jpg"   # headless Chrome checks (web/CLAUDE.md)
```

Full steps, including llama.cpp for Artelico and the iPad driver: [docs/building-apple.md](docs/building-apple.md).
- **XCTest missing:** if `swift test` reports "no such module XCTest", run
  `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Things that must stay in step (the usual source of bugs)

1. **Swift ↔ JavaScript.** `web/js/core/*` and `web/js/rules/*` are ports of `UGenKit/Sources/StudioCore/*`:
   - decoders, the tracker, steady video, privacy, and the pose, hand, detection and language games.
   - A behaviour change on one side needs the same change on the other.
   - Each JS file names the Swift file it ports.
2. **Shared screens.** `Artelico/App/Examples/*.swift` is compiled into **both** apps (see `UGenProbe/project.yml`).
   - The app differences go through `ExampleSupport.swift`, which exists once in each app.
   - Build both apps after touching `Examples/`.
3. **Same-named app files.** Many files exist in both `Artelico/App` and `UGenProbe/App`.
   - **Identical copies:** `CameraSource.swift`, `Recorder.swift`, `StreamCatalog.swift` and `streams.json`. Change
     both.
   - **Different on purpose:** the rest (`StudioModel`, `LiveView`, `StreamSource`, `DeviceView`, `ContentView`,
     `APIServer`, the chat / picture / speech views…). Artelico runs Core ML / llama.cpp, Hailo Studio runs the
     stick. Diff them before porting a change across.
4. **Model catalogue.** `UGenKit/Sources/StudioCore/Resources/models.json` and `labels.json` have copies in
   `web/data/`.
5. **Pinned Hugging Face revisions.** Converted models and sample videos download from fixed commits of
   https://huggingface.co/helmo/artelico-models. The pins are in:
   - `Artelico/App/ModelDownloads.swift` (`modelRevision`);
   - `UGenProbe/App/StudioModel.swift` (`clipFilesRevision`);
   - `web/js/core/source.js` (`HUGGING_FACE`);
   - `Artelico/App/Examples/SampleMedia.swift` and `web/js/ui/hailo-videos.js` (videos, with SHA-256 checks).
6. **Generated projects.** Never edit `*.xcodeproj`; edit `project.yml` and regenerate.

## Conventions

- **Decoders follow the reference.** They port Hailo's Model Zoo / hailo-apps post-processing; the comments name the
  source file. When a result looks wrong, compare with the reference implementation before tuning numbers.
- **Measure, then write it down.** `docs/history/LOG.md` records each change with numbers (FPS, differences against
  references, which pictures were checked). Keep doing that for non-trivial changes.
- **Privacy fails closed.** In the Privacy camera, if cleaning a frame fails, nothing is shown or recorded
  (`Privacy.swift`, `privacy.js`).
- **Video files are paced, not played.** See `PacedVideo.swift` / `steady-video.js`. Detections are steadied with
  One-Euro filters (`TrackSmoothing.swift`), so drawn boxes don't shake.
- **One stick, one user.** Only one process can hold the stick: an app, `ugen`, `hailortcli` or a notebook.
  - Tests and tools must release it.
  - A stick left in loader mode after a killed session needs a replug.
- **Speed.** Judge it in Release builds. StudioCore forces `-O` even in Debug, because the per-pixel loops are
  about 50× slower unoptimised.
- **Interface text.** Plain, short sentences, saying what happens.

## Pitfalls

- **Runtime image:** Hailo Studio's project references `../images/core-image-hailo-hailo10-usb-dongle.ext4`. Without
  it the build fails. Run `tools/fetch_runtime_image.sh`.
- **llama.cpp:** Artelico links `../vendor/llama-b12138-artelico/llama.xcframework`. Build it first
  (docs/building-apple.md §3).
- **The 3D face model:** `tddfa_bfm68.bin` is absent on purpose (Basel Face Model licence). The code handles it
  missing, so keep it that way.
- **iPad DriverKit profiles:** register the device before the first build. See docs/building-apple.md §6.
- **Web models:** `web/models/` is optional (local conversion output). Without it the web uses Hugging Face, so
  don't make it required.
- **Model files stay out of the repository:** HEF, Core ML and ONNX files are large and each has its own licence.
