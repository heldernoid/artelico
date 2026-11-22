# tools/

Setup scripts, catalogue builders, and small C tools from the reverse-engineering phase (Mac, IOKit).

## Setup (start here)

| Script | Does |
|---|---|
| `fetch_runtime_image.sh [zip]` | Gets the stick's runtime image from ASUS's firmware package → `images/`, checked by SHA-256. Needs `zstd` |
| `generate_projects.sh` | XcodeGen for both apps, with `DEVELOPMENT_TEAM` and `BUNDLE_ID_PREFIX` from the environment |
| `download_hefs.sh` / `fetch_hef.sh` | Every Hailo-10H HEF in `native/all-hefs.txt` → `models/` (4 at a time) |
| `build_hailort_wheel.sh [python]` | Hailo's `hailo_platform` for macOS, from the community port in `vendor/ref-hailort-macos-usb` (apply `patches/hailort-macos-usb-13c3dbb.patch` there first) → `dist/` |
| `make_dmg.sh` | Release Mac builds packed as disk images in `dist/`. They run only on Macs registered to the signing team, unless signed with a Developer ID and notarised |

## Catalogue and data builders

- **`build_catalog.py`:** writes `models/catalog.json`, listing every Hailo-10H model Hailo Studio can use. It reads
  hailo-apps' `resources_config.yaml` from a hailo-apps clone in `vendor/`.
- **`build_model_info.py`:** writes `UGenKit/Sources/StudioCore/Resources/models.json`, from `hefinfo` and
  `hailortcli parse-hef`. Copy the result to `web/data/models.json` as well.
- **`build_labels.py`:** label sets from hailo-apps → `labels.json`.
- **`hef_feature_quant.py`:** per-channel output quantisation of a HEF.
- **`decode_nms.py`:** prints a raw `HAILO_NMS_BY_CLASS` buffer.
- **`test_all_models.py`:** runs every model in the table on the stick through `ugenrt`.

## C tools (Mac, IOKit)

They were used to work out and check the stick's protocol (`docs/the-stick.md`). The apps use the same code through
`UGenKit/Sources/CUGenRT`.

| Tool | Does |
|---|---|
| `usbdump.c` | Read-only USB descriptor dump (never opens the device) |
| `loaderprobe.c` | Reads the loader's protocol version, SKU and build string |
| `ugenload.c` | Uploads the runtime image (loader mode → runtime mode) |
| `ugenrt_mac.c` | Command-line front end for `ugenrt.c`: identify, run, bench |
| `hefinfo.c` (`build_hefinfo.sh`) | Every stream of a HEF as JSON, using Hailo's own library from the macOS port |

Build a C tool like this (the header of each file has its own line):

```sh
clang -O2 -I ../UGenKit/Sources/CUGenRT/include -o ugenrt ugenrt_mac.c ../UGenKit/Sources/CUGenRT/ugenrt.c \
  -framework IOKit -framework CoreFoundation
```

## Other

- `make_icon.swift`: draws the app icons (original artwork, CoreGraphics).
- `patches/`: local changes to third-party sources this project builds against.
