# Notebooks for the Hailo stick

Jupyter with Hailo's own Python package, `hailo_platform` (HailoRT 5.3.0).

- **Linux and Windows:** Hailo ships the package with HailoRT.
- **macOS:** Hailo doesn't make it, so this project builds it from a community port (below).

## `stick_quickstart.ipynb`

Four sections, each opening the stick and releasing it again:
1. **Find objects:** YOLOv8s on `testdata/bus.jpg`.
2. **Chat:** Qwen2.5-1.5B, word by word.
3. **Ask about a picture:** Qwen2-VL-2B.
4. **Speech to text:** Whisper-Base on `web/samples/speech_sample.wav`.

The notebook uses only Hailo's public API, so it should also run on Linux or Windows with Hailo's own package. That
hasn't been tested; it was tested on a Mac.

Results from the run saved in the notebook (an Apple Silicon Mac, stick on USB):

| Section | Result |
|---|---|
| YOLOv8s | bus 0.89 and 3 people (0.92, 0.90, 0.88); 47 pictures a second, one at a time |
| Qwen2.5-1.5B | streams at about 5.7 tokens a second; loads in about 6 s |
| Qwen2-VL-2B | "A man in a beige coat and sunglasses stands next to a blue bus with the text "CERO EMISIONES" on it…" in 8 s |
| Whisper-Base | 4 s of speech transcribed correctly in 0.7 s |

The notebook expects:
- the HEFs in `../models/`: `yolov8s.hef` (`tools/download_hefs.sh`), and the language and speech models from
  `dev-public.hailo.ai/v5.3.0/blob/<name>.hef`, downloaded in a browser;
- the stick in runtime mode (see below).

Hailo's own tutorials are installed with the package, in `<site-packages>/hailo_tutorials/notebooks/` (HRT_0 to
HRT_5):
- set each one's `MODEL_PATH` to a file in `models/`;
- on macOS, in the VLM tutorial, set `OPTIMIZE_MEMORY_ON_DEVICE = False`;
- the power-measurement one (HRT_2) needs a power sensor, which the UGen300 doesn't have.

## On a Mac

1. **Build HailoRT for macOS** from the community USB port:

   ```sh
   git clone https://github.com/relaxcloud-cn/hailort-macos-usb.git vendor/ref-hailort-macos-usb
   (cd vendor/ref-hailort-macos-usb && git checkout 13c3dbb && git apply ../../tools/patches/hailort-macos-usb-13c3dbb.patch \
     && brew install cmake libusb && scripts/macos/build_hailort_usb.sh)
   ```

2. **Build and install the Python package.** It's a self-contained wheel, with libhailort and libusb inside:

   ```sh
   uv venv --python 3.12 .venv-hailort         # or: python3.12 -m venv .venv-hailort
   uv pip install --python .venv-hailort/bin/python numpy setuptools wheel pybind11 jupyterlab ipykernel pillow
   tools/build_hailort_wheel.sh                # -> dist/hailort-5.3.0-cp312-cp312-macosx_<version>_arm64.whl
   uv pip install --python .venv-hailort/bin/python dist/hailort-5.3.0-*.whl
   .venv-hailort/bin/python -m ipykernel install --user --name hailo-stick --display-name "Python 3.12 (Hailo stick)"
   ```

   - **Which Macs it runs on:** the wheel targets the macOS version it was built on, so build it on the oldest macOS
     you want to use it on.
   - **Which Python:** it is tied to the Python version used to build it (3.12 above).
3. **Put the stick in runtime mode.** After every plug-in the stick is a "USB Loader" until the runtime is uploaded.
   - Run `cd UGenKit && swift run ugen boot` (with `images/` filled by `tools/fetch_runtime_image.sh`), or open Hailo
     Studio once and quit it.
   - The port's own instructions use a Linux VM for this step; you don't need one.
4. **Run Jupyter:**

   ```sh
   .venv-hailort/bin/jupyter lab notebooks/    # pick the kernel "Python 3.12 (Hailo stick)"
   ```

## Limits on macOS

- **VLM setting:** the port is built without the host-side tokenizer (`HAILO_BUILD_CLIENT_TOKENIZER=OFF`). Create the
  VLM with `optimize_memory_on_device=False`; `True` fails with `HailoRTStatusException: 7` (not implemented).
- **One program at a time:** quit Hailo Studio, or stop `ugen`, before running a notebook, and the other way round.
- **Models must be HEFs** compiled for the Hailo-10H. A PyTorch or TensorFlow model has to be compiled with Hailo's
  Dataflow Compiler first, which runs on Linux x86-64 only.
