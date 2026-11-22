#!/bin/zsh
# Builds Hailo's own Python package (hailo_platform, "pyHailoRT" 5.3.0) for macOS on Apple Silicon, from the
# community macOS USB port in vendor/ref-hailort-macos-usb. Hailo ships it for Linux and Windows only.
#
# The wheel is self-contained: libhailort and libusb are copied inside it, so `pip install` is all a Mac needs.
#
#   tools/build_hailort_wheel.sh [python]      (default: .venv-hailort/bin/python)
#   -> dist/hailort-5.3.0-cp312-cp312-macosx_<ver>_arm64.whl
#
# Needs: the port at commit 13c3dbb with tools/patches/hailort-macos-usb-13c3dbb.patch applied (it lets the Python
# bindings build on macOS), its libhailort already built (scripts/macos/build_hailort_usb.sh -> build-macos-usb),
# cmake, the Xcode command line tools and Homebrew's libusb. The wheel targets the macOS version it is built on.
set -euo pipefail

ROOT=${0:A:h:h}
PORT=$ROOT/vendor/ref-hailort-macos-usb
PY=${1:-$ROOT/.venv-hailort/bin/python}
PYVER=$($PY -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')
BIND=$PORT/hailort/libhailort/bindings/python
BUILD=$BIND/platform/build.arm64.Release
LIB=$PORT/build-macos-usb/hailort/libhailort/src/libhailort.5.3.0.dylib
USB=$(otool -L $LIB | awk '/libusb/ {print $1}')
STAGE=$(mktemp -d)/hailort
trap 'rm -rf ${STAGE:h}' EXIT

[[ -f $LIB ]] || { echo "Build the port's libhailort first (build-macos-usb)."; exit 1; }

# 1. The C++ extension, linked against the port's libhailort.
cmake -S $BIND/src -B $BUILD -DCMAKE_BUILD_TYPE=Release -DCMAKE_LIBRARY_OUTPUT_DIRECTORY=$BUILD \
      -DPYBIND11_PYTHON_VERSION=$PYVER -DPYTHON_EXECUTABLE=$PY \
      -DLIBHAILORT_PATH=$LIB -DHAILORT_INCLUDE_DIR=$PORT/hailort/libhailort/include \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 > /dev/null 2>&1
cmake --build $BUILD --parallel 8 --target _pyhailort > /dev/null
EXT=$(ls $BUILD/_pyhailort.cpython-${PYVER/./}-darwin.so)

# 2. Stage the Python sources and the libraries side by side, linked by @loader_path.
mkdir -p $STAGE
cp -R $BIND/platform/hailo_platform $BIND/platform/hailo_tutorials $STAGE/
find $STAGE -name '__pycache__' -prune -exec rm -rf {} +
DST=$STAGE/hailo_platform/pyhailort
cp $EXT $LIB $USB $DST/
chmod u+w $DST/*.dylib
USBNAME=${USB:t}
install_name_tool -id @loader_path/$USBNAME $DST/$USBNAME
install_name_tool -id @rpath/libhailort.5.3.0.dylib -change $USB @loader_path/$USBNAME $DST/libhailort.5.3.0.dylib
for rp in $(otool -l $DST/${EXT:t} | awk '/LC_RPATH/ {getline; getline; print $2}'); do
  install_name_tool -delete_rpath $rp $DST/${EXT:t}
done
install_name_tool -add_rpath @loader_path $DST/${EXT:t}
codesign -f -s - $DST/*.dylib $DST/${EXT:t} 2> /dev/null

# 3. The wheel (a platform wheel holding the prebuilt extension).
cat > $STAGE/setup.py <<'EOF'
from setuptools import setup, find_packages
from setuptools.dist import Distribution

class BinaryDistribution(Distribution):
    def has_ext_modules(self):
        return True

setup(
    name="hailort", version="5.3.0", description="HailoRT (macOS USB port build)",
    url="https://hailo.ai/", packages=find_packages(), install_requires=["numpy"],
    package_data={"hailo_platform": ["pyhailort/*.so", "pyhailort/*.dylib",
                                     "../hailo_tutorials/notebooks/*"]},
    include_package_data=True, distclass=BinaryDistribution, zip_safe=False,
)
EOF
mkdir -p $ROOT/dist
(cd $STAGE && $PY -m pip --version > /dev/null 2>&1 || true
 MACOSX_DEPLOYMENT_TARGET=14.0 $PY setup.py -q bdist_wheel --dist-dir $ROOT/dist > /dev/null 2>&1)
ls -1 $ROOT/dist/hailort-5.3.0-*.whl
