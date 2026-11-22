# How the UGen300 works, and how this project talks to it

The ASUS UGen300 is a Hailo-10H chip with 8 GB of LPDDR4 and an ARM core running Linux, behind USB-C. Hailo's
runtime (HailoRT) on the host talks to a HailoRT server on the stick. This project reimplements the host side for
Apple platforms: Hailo ships HailoRT for Linux and Windows only.

The full investigation, with every measurement, is in [history/LOG.md](history/LOG.md) (Phases 0–2, Steps 1–36).

## Two USB personalities

| | Loader mode (after every power-up) | Runtime mode (after the upload) |
|---|---|---|
| Product string | `UGen300 USB Loader` | `UGen300 USB AI Accelerator (Hailo-10H)` |
| Configurations | 2 | 1 ("HailoRT USB"), 496 mA declared |
| Interfaces | 1 | 5, each class `0xFF/0xFF/0x01`; interface *i* has bulk OUT `0x01+i` and bulk IN `0x81+i` (1024-byte packets) |
| Vendor / product | `0x0B05` (2821, ASUS) / `0x1D6F` (7535) | same vendor |

- **Telling the modes apart:** the device class is `0xFF` in both, so use the number of configurations or the
  product string.
- **macOS:** it leaves the device unconfigured, so the host calls `SetConfiguration(1)` itself.

## 1. Loader mode: uploading the runtime

The stick keeps nothing between power-ups: the host sends it a 103 MB Linux image
(`core-image-hailo-hailo10-usb-dongle.ext4`, from ASUS's firmware package, see `tools/fetch_runtime_image.sh`).

- **Hailo's own loader:** `hailo_usb_loader` is closed-source and Linux-only. On Linux a udev rule runs it when the
  loader appears.
- **This project's loader:** the protocol was taken from third-party notes reconstructed from USB captures, then
  checked step by step on a real stick:
  1. `SET_CONFIGURATION 1`, claim interface 0.
  2. Vendor IN requests (`0xC0`):
     - `0x16` protocol version (must be 1);
     - `0x14` SKU;
     - `0x11` build string. The tested one is "Hailo Linux build v1.10.10", which pairs with the HailoRT 5.3.0
       image; the code refuses other builds.
  3. Vendor OUT `0x12` with the image size split across `wIndex:wValue`.
  4. Poll `0x15` until ready, send two 64-byte `0xAA` pings on bulk OUT, then check the byte counter.
  5. Send the image in 65,536-byte bulk transfers, then one zero-length transfer.
  6. About 5 s later, the stick appears again in runtime mode.
- **Where the loader code is:** `UGenKit/Sources/CUGenRT/ugenloader.c`, used by both apps, by `swift run ugen boot`
  and by `tools/ugenload.c` (a standalone Mac tool).

## 2. Runtime mode: the HailoRT 5.3.0 RPC protocol

`UGenKit/Sources/CUGenRT/ugenrt.c` is a dependency-free C client for HailoRT 5.3.0's RPC ("HRPC") over USB bulk
transfers.

- **What's in it:**
  - a small protobuf encoder and decoder;
  - the CONNECT/CLOSE handshake (5 bytes in 5.3.0; 9 in 5.5.0, so follow 5.3.0);
  - message framing;
  - calls for identify, temperature, create vdevice, create infer model (with the HEF upload), configure, and run.
- **The transport:** USB access is four functions the host supplies (control out, control in, bulk out, bulk in;
  `ugen_transport` in `include/ugenrt.h`). The same protocol code runs on:
  - **the Mac:** `ugen_mac_transport.c`, IOKit;
  - **the iPad:** `ugen_ios_transport.c`, through the DriverKit driver in `UGenProbe/Driver`, which is only a USB
    pipe.
- **No HEF parsing on the host:** the configure request carries no stream parameters, so the stick keeps the HEF's
  defaults: input UINT8 NHWC, output float32 (or NMS by class).
- **Pipelining:** `ugen_infer_submit` / `ugen_infer_collect` keep two frames in flight. That matches Hailo's own
  tool: yolov8m 59 FPS, yolov8s 127 FPS and yolov8n 198 FPS from a Mac.
- **What's checked:** every Hailo-10H vision model in the catalogue runs through this client. Outputs were compared
  with Hailo's own `hailortcli` built from the macOS port below.

## 3. GenAI: chat, picture questions, speech

HailoRT 5.3.0 runs its language models in servers on the stick (LLM, VLM, Speech2Text).

- **The client:** `UGenKit/Sources/UGenKit/GenAI.swift` and `GenAIProtocol.swift`, ported from HailoRT's
  `genai_scheme.proto` and `serializer.cpp`.
- **The wire format:** each request is a 4-byte little-endian action id plus a protobuf message.
- **Prompts:** HEFs are cut up for transfer as `Hef::parse_hef_for_transfer` does, and chat messages become a prompt
  through the model's own template (minja).
- **Models:** Qwen2.5-1.5B, Qwen2.5-Coder-1.5B, Qwen3-1.7B, Llama 3.2-1B, Qwen2-VL-2B and Whisper-Base, as published
  by Hailo for 5.3.0 (see `UGenProbe/App/DeviceView.swift`, `LanguageModelFile`).

## Hailo's own runtime on a Mac (optional)

A community port of HailoRT 5.3.0 to macOS over libusb exists: https://github.com/relaxcloud-cn/hailort-macos-usb
(MIT). It gives Hailo's `hailortcli`, its C++ API and, with this project's small patch, Hailo's Python package.

1. Clone the port at commit 13c3dbb into `vendor/ref-hailort-macos-usb`.
2. Apply `tools/patches/hailort-macos-usb-13c3dbb.patch`:
   - it finds libusb without pkg-config;
   - it adds a missing include;
   - it lets the Python bindings build on macOS.
3. Build it with the port's `scripts/macos/build_hailort_usb.sh`.
4. Run `tools/build_hailort_wheel.sh`, which gives `dist/hailort-5.3.0-cp312-…-arm64.whl`, a self-contained
   `hailo_platform` package. See [../notebooks/README.md](../notebooks/README.md).

Notes:
- **Loader mode:** the port boots the stick through a Linux VM. With this project you don't need one:
  `swift run ugen boot` (in `UGenKit/`) or opening Hailo Studio uploads the runtime, and the stick then stays in
  runtime mode until it's unplugged.
- **One program at a time:** only one program can hold the stick. Quit Hailo Studio before using `hailortcli` or a
  notebook, and the other way round.

## Firmware

- **Firmware vs runtime:** the runtime image above lives in RAM. The stick's *firmware* is in its flash.
- **A new stick:** it may come with factory firmware that HailoRT 5.3.0 rejects ("incompatible firmware"). ASUS's
  one-time update runs on a Linux PC:
  - the guide: https://github.com/Asus-UGen-Series/UGen300-USB-Firmware-Upgrade;
  - the package: `UGen300_USB_FW_Upgrade.zip`, the same one `tools/fetch_runtime_image.sh` downloads.
- **The two stages:**
  1. With the 5.2.2 packages installed, copy `provisionV3/hailo-update-image-hailo10-usb-dongle.swu` to
     `/usr/lib/firmware/hailo/hailo10h_usb/` and run `hailo_rfs_upload fw-update`.
     - It ends with "Update has completed with failure". That's expected.
  2. With the 5.3.0 packages installed, run `hailo_usb_loader fw-update`.
     - Then `hailortcli fw-control identify` should say `Firmware Version: 5.3.0 (release,app)`.
- **Precautions:** plug in only the stick being updated, and don't unplug it during either stage (2–3 minutes each).

This project never writes the stick's flash.

## Power

- **What to plug into:** Hailo recommends a USB-C source offering 3,000 mA. The apps read what the port offers
  (`ugen_device_current_limit`) and show it in "Device and models".
- **What was measured:** a Mac through a hub offered 1,500 mA, and everything still ran.
- **No power reading:** the stick has no power sensor, so power use can't be read.
