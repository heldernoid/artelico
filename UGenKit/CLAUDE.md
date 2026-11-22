# UGenKit

A Swift package (iOS 17 / macOS 14) shared by both apps, with the `ugen` command-line tool.

| Target | What | Uses the stick |
|---|---|---|
| `CUGenRT` (C) | Loader upload (`ugenloader.c`), HailoRT 5.3.0 RPC client (`ugenrt.c`), USB transports: `ugen_mac_transport.c` (IOKit) and `ugen_ios_transport.c` (through the DriverKit driver's user client) | Yes |
| `StudioCore` | Everything else that doesn't need the stick, so Artelico can link it alone | No |
| `UGenKit` | `UGenDevice.swift` (open, boot, load a HEF, run, pipelining, chip stats) and `GenAI.swift` / `GenAIProtocol.swift` (LLM, VLM, Speech2Text services) | Yes |
| `ugen` | Mac CLI. See the header of `Sources/ugen/main.swift` for every command | Yes |

## StudioCore by area

- **Models:**
  - `ModelInfo.swift` + `Resources/models.json`: the catalogue;
  - `VisionPipeline.swift`: task ↔ model, running one picture;
  - `Pipelines.swift`, `CropTasks.swift`, `TopDownPose.swift`: two-model chains (detect, then crop);
  - `InferenceEngine.swift`: the protocol both engines implement;
  - `CoreMLEngine.swift`: the Core ML engine plus `.native.json` maps.
- **Input:** `ImagePrep.swift` (letterbox, crop, 8-bit RGB), `Tiling.swift`, `VideoClip.swift`, `PacedVideo.swift`
  (video files shown in even steps), `RTSPClient.swift` (RTSP over TCP, Basic/Digest, H.264 only, through
  VideoToolbox), `LiveSources.swift`.
- **Decoding:** `PostProcess.swift` and `PostProcess+*.swift`, one file per model family: YOLO / YOLO26, SCRFD and
  other face detectors, landmarks, attributes, YOLACT, segmentation, lanes, oriented boxes, text, super-resolution,
  CenterPose, heatmaps.
  - Each names the Model Zoo or hailo-apps file it ports.
  - `SegmentationLabels.swift` holds the label sets.
- **Drawing:** `VisionRenderer*.swift`.
- **Tracking:** `Tracker.swift` (ByteTrack-style IDs; steadies boxes and poses through `TrackSmoothing.swift`'s
  One-Euro filters) and `HandSteadying.swift`.
- **Text-to-image matching:** `CLIP.swift`, `CLIPModels.swift`, `SentencePiece.swift` (tokenizers in `Resources/`),
  `OpenVocabulary.swift` (YOLO-World, "Find anything") and `ObjectCLIP.swift` (CLIP on each detected object).
- **Demo rules:** pure logic, tested without pictures:
  - `PoseGames`, `HandGames`, `DetectionGames`, `LanguageGames`;
  - `RepCounter`, `EggGame`, `Privacy`, `PhotoRestore`, `EdgeCloud`;
  - `FaceEnrolment`, `FaceReport`, `SightingLog`.
- **Other:** `HTTPServer.swift` (the small server behind the apps' REST API) and `CapturedRun.swift` (raw outputs
  saved by `ugen capture`, decoded later by `ugen replay`).

## Tests

```sh
swift test                                  # ~210 tests; stick tests skipped
UGEN_DEVICE_TESTS=1 swift test              # with the stick on this Mac (boots it if needed)
swift test --filter PrivacyTests
```

- **Test data:** tests find the repository through `#filePath` (`root` in `CLIPTests` / `GenAITests`). They read
  `testdata/bus.jpg`, `models/*.hef` and `images/*.ext4`, and **skip** when a file is missing. Don't turn a skip into
  a failure.
- **Synthetic data:** decoder and rule tests build their inputs by hand (synthetic tensors or poses), so they need no
  model.
- **XCTest missing:** if `swift test` can't find XCTest, set
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## The CLI on the stick

```sh
swift run ugen boot                                           # upload the runtime (loader mode → runtime mode)
swift run ugen detection yolov8s ../testdata/bus.jpg out.png
swift run ugen bench yolov8s 2 200                            # 2 frames in flight
swift run ugen examples vision                                # the demo screens' steps, stick and Core ML
swift run ugen native-map <task> <model> <image> <model.mlpackage>   # writes <model>.native.json
```

- **Where files are looked up:** under `$UGEN_ROOT`, which defaults to the repository: `models/<name>.hef` and
  `images/core-image-hailo-hailo10-usb-dongle.ext4`.
- **Getting the HEFs:** `tools/download_hefs.sh` fetches them.

## Rules

- **Optimised in Debug:** `StudioCore` and `UGenKit` are compiled with `-O` even in Debug (`Package.swift`). Keep it
  that way.
- **Ports to keep in step:** `web/js/core` and `web/js/rules` port this target, so change both sides together.
- **No stick in StudioCore:** keep stick code out of `StudioCore`. Artelico links it without `CUGenRT`.
- **C rules:** C changes must stay dependency-free and portable. `ugenrt.c` is meant to build on any system with a
  libusb transport (see docs/porting.md).
