# Linux (e.g. Ubuntu) and Windows

The apps in this repository are Apple apps: SwiftUI, Core ML, AVFoundation, DriverKit. Much of the work is
portable, though, and Hailo supports the stick on Linux and Windows directly. This page covers:
- what works on those systems today;
- the realistic ways to bring the apps there, most promising first.

## Works today, with no porting

### 1. Artelico Web, in the browser

```sh
python3 web/serve.py          # then open http://localhost:8000 in Chrome or Edge
```

- **What runs:** every vision demo, chat (WebLLM), picture questions and speech to text (Transformers.js), in the
  browser. Models download from Hugging Face.
- **Speed:** WebGPU is used where the browser has it, otherwise WebAssembly (slower; no language models).
- **Without installing anything:** the same site is online at https://huggingface.co/spaces/helmo/artelico.
- **The stick:** the web edition doesn't use it (but see "Porting A" below).

### 2. The stick, with Hailo's own software

This is the supported path on these systems, so there's no reverse engineering to do.

- **Linux (x86-64 or arm64):** install ASUS's packages from `UGen300_USB_FW_Upgrade.zip`, `v5.3.0/`
  (`hailort_5.3.0_<arch>.deb` and `hailort-usb-driver_5.3.0_<arch>.deb`).
  - The USB driver package installs a udev rule and Hailo's `hailo_usb_loader`, which uploads the runtime image by
    itself each time the stick is plugged in (about 20 s).
  - Then `hailortcli fw-control identify` should show firmware 5.3.0.
  - A new stick may first need the firmware update: see [the-stick.md](the-stick.md#firmware).
- **Windows 11:** install HailoRT 5.3.0 for Windows from Hailo's Developer Zone (free account).
  - ASUS's UGen300 demos (https://github.com/erp0917-stack/ugen300-demos, MIT) show a working setup with Python 3.10;
    they're the demos Hailo Studio's demo screens are modelled on.
- **Python:** HailoRT includes Hailo's Python package, `hailo_platform` (a wheel for the Linux or Windows Python it
  was built for, not on PyPI).
  - It runs HEF inference with NumPy arrays, and LLM, VLM and Speech2Text on the Hailo-10H.
  - [notebooks/stick_quickstart.ipynb](../notebooks/stick_quickstart.ipynb) uses only that API, so it should run
    unchanged on Linux or Windows once the model paths point at your `.hef` files. That's untested here: it was
    tested on a Mac with the macOS build.
  - With Hailo's own build you can probably create the VLM with `optimize_memory_on_device=True` (the macOS build
    lacks the host-side tokenizer).
  - Hailo's tutorial notebooks are installed with the package, in `hailo_tutorials/notebooks/`.
- **Hailo's apps:** https://github.com/hailo-ai/hailo-apps (GStreamer pipelines for detection, pose, segmentation,
  CLIP, face recognition and more) runs on Linux.

### 3. The model tools

- **Most of `native/tools/` is plain Python:** ONNX, onnxruntime, numpy.
  - `export_web.py` (the browser models) and the comparisons with ONNX Runtime work on Linux.
  - coremltools can *convert* on Linux, but running a Core ML model needs macOS.
  - `ugen native-map` needs a Mac and the stick.
- **Compiling your own model to `.hef`** (PyTorch / TensorFlow → ONNX → HEF) needs Hailo's Dataflow Compiler, which
  runs on **Linux x86-64 only**, Ubuntu 22.04/24.04 (Developer Zone, free account). This applies on every system,
  Macs included.

## Porting the apps: the options

### A. The web edition + a small stick server (recommended)

Artelico Web already has the whole interface, every demo's rules and every decoder, in JavaScript (`web/js`). What
it lacks is a way to reach the stick. On Linux and Windows, Hailo's Python package can be that way.

1. **A local server** (Python, e.g. FastAPI or `http.server`) that opens the stick with `hailo_platform` and serves:
   - `POST /infer?model=<name>`: body = the input tensor (UINT8 NHWC, the HEF's input size). Reply = the raw output
     tensors, with names, shapes and float32 data, exactly as the stick returns them.
   - Optionally the Hailo Studio REST API, for compatibility:
     - `GET /v1/status`, `GET /v1/models`;
     - `POST /v1/vision/<task>?model=`;
     - `POST /v1/chat/completions` (OpenAI-style);
     - `POST /v1/audio/transcriptions`;
     - `POST /v1/vision/ask`.

     It's documented at the top of `UGenProbe/App/APIServer.swift`.
2. **A `StickEngine`** in `web/js/core/` with the same `infer(frames, name)` interface as `OnnxEngine`
   (`engine.js`), posting frames to that server.
   - The web decoders already take the stick's layout: the ONNX models' `.native.json` maps exist to convert *to* it.
   - So stick outputs can go straight into the existing decoders. Only `models.json`'s output descriptions are
     needed, and they're already in `web/data/models.json`.
3. **A switch in the web's "Models" page:** "Browser" or "Stick (local server)".

You'd get every Artelico Web screen running on the stick on Linux and Windows, with the GPU-free speed of the
Hailo-10H. The UI could later be packaged as a desktop app (Tauri or Electron) if a window is preferred over a
browser tab.

Watch out for:
- **Cross-origin access:** the page must be allowed to reach the server. Serve the page from the same server, or
  send CORS headers.
- **One process at a time:** only one process can hold the stick, so the server should own it and serialise
  requests. Keep two frames in flight for speed (see the pipelining notes in [the-stick.md](the-stick.md)).

### B. This project's C runtime on libusb (no HailoRT at all)

`UGenKit/Sources/CUGenRT/` is dependency-free C: the loader (`ugenloader.c`) and the HailoRT 5.3.0 RPC client
(`ugenrt.c`). Its only platform-specific part is the USB transport: four blocking functions in `include/ugenrt.h`
(`control_out`, `control_in`, `bulk_out`, `bulk_in`).

- **Write `ugen_libusb_transport.c`:**
  - open vendor `0x0B05`, product `0x1D6F`;
  - `libusb_set_configuration(1)`, claim the interface (detach a kernel driver if one is attached);
  - `libusb_control_transfer` and `libusb_bulk_transfer` for the four functions.

  `ugen_mac_transport.c` (IOKit, about 200 lines) is the model to follow.
- **Linux:** add a udev rule giving your user access to `0B05:*`. Don't install Hailo's USB driver package at the
  same time: its udev rule starts Hailo's loader, which would race yours.
- **Windows:** the stick needs the WinUSB driver bound (for example with Zadig). That replaces Hailo's driver for
  the device.
- **What you get:** loader upload, identify, temperature, HEF upload, configure and pipelined inference, from C, on
  any system with libusb. `tools/ugenload.c` and `tools/ugenrt_mac.c` show command-line front ends.
- **What you don't get:** the GenAI client (chat, VLM, Whisper) is in Swift (`UGenKit/Sources/UGenKit/GenAI*.swift`)
  and would need porting to C or another language. Its wire format is documented at the top of `GenAIProtocol.swift`.

Use this when you can't or don't want to install HailoRT (embedded boards, other operating systems, or languages
other than Python). Otherwise option A, with Hailo's own runtime, is less work.

### C. The Swift code on Linux or Windows

Swift runs on Linux and Windows, but the shared library depends on Apple frameworks. Across StudioCore's 62 files:
- 51 use CoreGraphics;
- a few use CoreImage, CoreText, CoreML, AVFoundation, VideoToolbox, Vision and Network.

The pure logic (decoders, tracker, smoothing, the demos' rules, RTSP parsing) could be split into a module that
uses only Foundation. But the JavaScript ports in `web/js` already are that portable version, so option A gets
further for less work. The SwiftUI apps themselves are Apple-only.

## Summary

| You want… | Do this |
|---|---|
| The demos on any computer, no stick | Artelico Web (`web/serve.py`) or the Space |
| Python / Jupyter with the stick | Linux or Windows: Hailo's HailoRT + `hailo_platform`. Mac: `tools/build_hailort_wheel.sh` |
| The Hailo Studio experience on Linux or Windows | Option A: web edition + a small Python stick server |
| The stick without HailoRT | Option B: `CUGenRT` + a libusb transport |
| Your own PyTorch / TensorFlow model on the stick | Hailo's Dataflow Compiler on Linux x86-64 → `.hef` |
