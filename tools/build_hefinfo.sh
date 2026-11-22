#!/bin/bash
# Builds tools/hefinfo against the reference HailoRT 5.3.0 build for macOS.
set -e
cd "$(dirname "$0")"
REF=../vendor/ref-hailort-macos-usb
LIB="$REF/build-macos-usb/hailort/libhailort/src"
clang -O2 -Wall -I "$REF/hailort/libhailort/include" -o hefinfo hefinfo.c -L "$LIB" -lhailort -Wl,-rpath,"$(cd "$LIB" && pwd)"
