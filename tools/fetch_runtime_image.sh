#!/bin/sh
# Gets the UGen300's runtime image (images/core-image-hailo-hailo10-usb-dongle.ext4, 103 MB) from ASUS's
# official firmware package. The stick keeps no operating system of its own: at every power-up it starts as a
# "UGen300 USB Loader" and the host uploads this image (Hailo Studio bundles it; `tools/ugenload` and
# CUGenRT's loader send it). It is Hailo's/ASUS's file, so it is not in this repository.
#
#   tools/fetch_runtime_image.sh                 # downloads the 204 MB zip from ASUS
#   tools/fetch_runtime_image.sh path/to/UGen300_USB_FW_Upgrade.zip
#
# Needs: curl, unzip, ar (Xcode command line tools or binutils), tar and zstd
# (macOS: `brew install zstd`; Ubuntu: `sudo apt install zstd`). Works on macOS and Linux.
# Link from https://github.com/Asus-UGen-Series/UGen300-USB-Firmware-Upgrade.
set -eu

URL=https://dlcdnets.asus.com/pub/ASUS/AI_ACCELERATION_DEVICE/FW/UGen300_USB_FW_Upgrade.zip
ZIP_SHA=f8c8767a8efcd1bfc59d068a1663ee028d1e803e22c40277eae2495b3ccbaf5c
IMAGE_SHA=558c140089a4013f88e20d46a23b9279a968ed05b91b466a572a9b090882639f
INNER=lib/firmware/hailo/hailo10h_usb/core-image-hailo-hailo10-usb-dongle.ext4

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/images/core-image-hailo-hailo10-usb-dongle.ext4
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

sha256() { if command -v sha256sum > /dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
command -v zstd > /dev/null || { echo "zstd is needed (macOS: brew install zstd; Ubuntu: sudo apt install zstd)."; exit 1; }

if [ -f "$OUT" ] && [ "$(sha256 "$OUT")" = "$IMAGE_SHA" ]; then
  echo "Already there: $OUT"; exit 0
fi

if [ $# -ge 1 ]; then ZIP=$1; else
  ZIP=$WORK/fw.zip
  echo "Downloading ASUS's UGen300 firmware package (204 MB)…"
  curl -fL --progress-bar -o "$ZIP" "$URL"
fi
[ "$(sha256 "$ZIP")" = "$ZIP_SHA" ] || echo "Note: the zip's checksum differs from the tested one (ASUS may have updated it); the image is checked below."

unzip -q -j "$ZIP" 'UGen300_USB_FW_Upgrade/v5.3.0/hailort-usb-driver_5.3.0_arm64.deb' -d "$WORK"
(cd "$WORK" && ar x hailort-usb-driver_5.3.0_arm64.deb data.tar.zst && zstd -dq data.tar.zst -o data.tar && tar -xf data.tar "./$INNER" 2> /dev/null || tar -xf data.tar "$INNER")

mkdir -p "$ROOT/images"
mv "$WORK/$INNER" "$OUT"
if [ "$(sha256 "$OUT")" = "$IMAGE_SHA" ]; then
  echo "OK: $OUT (SHA-256 matches the image the apps were tested with)"
else
  echo "Written: $OUT, but its SHA-256 differs from the tested image ($IMAGE_SHA). The apps check the loader's build string before uploading."
fi
