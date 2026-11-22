# Artelico

An iPhone, iPad and Mac (Mac Catalyst) app with the same demos as Hailo Studio, but without the stick:
- **vision:** the Hailo Model Zoo models converted to **Core ML**;
- **chat and picture questions:** **llama.cpp** (GGUF models);
- **speech to text:** **WhisperKit**.

Licence: AGPL-3.0 (`LICENSE`).

## Build

See `docs/building-apple.md`. In short:
1. Build `../vendor/llama-b12138-artelico/llama.xcframework` (llama.cpp b12138 plus a Mac Catalyst slice:
   `native/tools/build_llama_xcframework.sh`).
2. Run `tools/generate_projects.sh`.
3. Build the `Artelico` scheme.

Dependencies:
- UGenKit's `StudioCore` product only (no stick code);
- WhisperKit (`argmax-oss-swift` 1.1.1, Swift Package Manager);
- llama.xcframework.

## Files

- **App structure:** `ArtelicoApp.swift`, `ContentView.swift` (the sidebar; `Section` lists every screen) and
  `Components.swift`.
- **`StudioModel.swift`:**
  - the app state, with `CoreMLEngine` as its engine. The property is still called `device` for symmetry with
    Hailo Studio;
  - the models folder: the app's Documents on iOS, `~/.artelico/models` on the Mac, or a folder the user picks;
  - the compute-unit choice (Automatic / Neural Engine / GPU / CPU).
- **`ModelDownloads.swift`:**
  - downloads a model's Core ML package and `.native.json` from https://huggingface.co/helmo/artelico-models at
    the pinned `modelRevision`, checked against that revision's `manifest.json` (size + SHA-256);
  - re-downloads stale packages.
- **Screens:**
  - `VisionView.swift` (photos);
  - `LiveView.swift` + `StreamSource.swift` + `CameraSource.swift` (camera, files, streams, up to 4 at once);
  - `StreamCatalog.swift` + `streams.json` (road cameras, see `docs/road-cameras.md`);
  - `Recorder.swift`.
- **Language:**
  - `LanguageModels.swift`: GGUF models from Hugging Face (Qwen3, Gemma 3, Llama 3.2 and others);
  - `LlamaEngine.swift`: the llama.cpp C API, with Metal;
  - `ChatView.swift`, `AskImageView.swift`;
  - `SpeechEngine.swift` + `SpeechView.swift`: WhisperKit; Whisper models from `argmaxinc/whisperkit-coreml`.
- **`Assistant/`:** a voice assistant.
  - Tools (`AssistantTools.swift`):
    - weather (Open-Meteo forecast and geocoding);
    - travel time (Apple Maps `MKDirections`, from the device's location);
    - web search (DuckDuckGo, or a SearXNG server set in the app);
    - torch, timer, time and date, a device check, remembering facts, and "what I can do".
  - Tool choice (`ToolSelector.swift`): sentence embeddings from all-MiniLM-L6-v2 (Core ML, made by
    `native/tools/convert_minilm.py`), with `WordPieceTokenizer.swift`.
- **`APIServer.swift`:** the REST API (vision endpoints, OpenAI-style chat, transcription) on `StudioCore`'s
  `HTTPServer`.
- **`NativeBench.swift`:** Debug benchmarks.
- **`Examples/`: the UGen300 demo screens, compiled into both this app and Hailo Studio.**
  - The two apps differ in `ExampleSupport.swift` (one per app): how a model is loaded and run, and the extra models
    a screen needs.
  - Shared building blocks:
    - `PoseKit.swift`: the runner, frames, the model loop and its `filter` hook (used by the Privacy camera);
    - `HandKit.swift`, `ExampleHost.swift`, `LiveSourceViews.swift`;
    - `SampleMedia.swift`: the sample pictures and Hailo's demo videos, downloaded on first use and checked by
      SHA-256;
    - `SpeechSamples.swift`: the spoken samples (six languages, public domain, in `Samples/`), the speech screens'
      player (`AudioClip`, `AudioClipView`) and Samples menu;
    - `VideoSoundButton.swift`: the sound on/off button of every screen that runs video (`VideoSound.isOn` in
      StudioCore), shown when the chosen file has a sound track.
- **`Samples/`:** pictures and a spoken sample, bundled. Credits are in `SampleMedia.swift`.

## Launch arguments (Debug testing)

Passed with `xcrun devicectl device process launch … --` on a device, or as the Mac app's arguments.

- **Choosing a screen:**
  - `-section <live|chat|ask|speech|device|privacy|…>` opens a screen;
  - `-sample <file>` / `-samplevideo <file>` picks a sample;
  - `-autostart` / `-autorun` starts it.
- **Language and speech:** `-chat <text>`, `-ask <question>`, `-autospeech` (with `-speechsample <file>`, e.g.
  `assis_pt.mp3`), `-chatmodel`, `-askmodel`, `-speechmodel`.
- **Settings for one run:** any setting can be given as `-<key> <value>`, e.g. `-video.sound NO` or
  `-audio.muted YES` (silent tests on the Mac).
- **Models:** `-modelsfolder <path>` uses another models folder; in the Mac Debug build it may point under
  `~/.artelico/`. `-redownload <model>` deletes a model, downloads it again and runs it.
- **Server and benchmarks:** `-api` starts the REST API, and `-nativebench` runs the benchmarks.
- **Self-tests:** `-videochecktest <file>`, `-jstest`, `-livelog`, `-replog`, `-sightings`, `-facereport`,
  `-enrolfolder`, `-posesample`. Each is defined next to the feature it tests; search for the argument.

Results are written to the app's Documents folder, so they can be read back with `devicectl device copy from` or
from the Mac container.

## Rules

- **Shared screens:** changes in `Examples/` affect Hailo Studio too. Build both apps.
- **The web edition:** `web/` mirrors this app's screens. Port behaviour changes there.
- **Duplicated files:** `StreamCatalog.swift`, `streams.json`, `CameraSource.swift` and `Recorder.swift` are
  identical copies of Hailo Studio's. Change both.
- **The Mac sandbox:** the Mac build is sandboxed (`App/Artelico-Mac.entitlements`). Files outside the container
  are reached only through the user's folder choice or `~/.artelico/`.
