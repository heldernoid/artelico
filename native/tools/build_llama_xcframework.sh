#!/bin/zsh
# Builds llama.xcframework for Artelico from the pinned llama.cpp source (vendor/llama.cpp-b12138,
# tag b12138 = commit f7b41cca4fecc8164c7ea45bfb55dfff7633842f) with three slices:
#   ios-arm64 (iPhone/iPad), ios-arm64_x86_64-simulator, ios-arm64-maccatalyst (Artelico on the Mac).
# The first two come from llama.cpp's own build-xcframework.sh (run it first:
#   ./build-xcframework.sh ios-sim ios-device); the official release has no Mac Catalyst slice, so
# this script builds one with the same options (no RPC backend, no server, no tools; Metal embedded).
#
# usage: native/tools/build_llama_xcframework.sh
set -e
ROOT=${0:A:h}/../..
SRC=$ROOT/vendor/llama.cpp-b12138
OUT=$SRC/build-maccatalyst
DEST=$ROOT/vendor/llama-b12138-artelico
SDK=$(xcrun --sdk macosx --show-sdk-path)
TARGET=arm64-apple-ios17.0-macabi
CATALYST_FLAGS="-target $TARGET -iframework $SDK/System/iOSSupport/System/Library/Frameworks -isystem $SDK/System/iOSSupport/usr/include -Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument"

[[ -d $SRC/build-ios-device/framework/llama.framework && -d $SRC/build-ios-sim/framework/llama.framework ]] || {
    echo "Run llama.cpp's ./build-xcframework.sh ios-sim ios-device first"; exit 1; }

echo "== Mac Catalyst static libraries"
rm -rf $OUT
cmake -S $SRC -B $OUT -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_SYSROOT=$SDK -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_C_FLAGS="$CATALYST_FLAGS" -DCMAKE_CXX_FLAGS="$CATALYST_FLAGS" -DCMAKE_OBJC_FLAGS="$CATALYST_FLAGS" \
    -DCMAKE_ASM_FLAGS="-target $TARGET" \
    -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_MTMD=ON -DMTMD_VIDEO=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS_DEFAULT=ON -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
    -DGGML_RPC=OFF > $OUT.cmake.log 2>&1 || { tail -30 $OUT.cmake.log; exit 1; }
cmake --build $OUT --config Release -j $(sysctl -n hw.logicalcpu) > $OUT.build.log 2>&1 || { grep -m20 -E "error" $OUT.build.log; exit 1; }

echo "== Mac Catalyst framework"
FW=$OUT/framework/llama.framework
mkdir -p $FW/Versions/A/Headers $FW/Versions/A/Modules $FW/Versions/A/Resources
ln -sfh A $FW/Versions/Current
ln -sfh Versions/Current/Headers $FW/Headers
ln -sfh Versions/Current/Modules $FW/Modules
ln -sfh Versions/Current/Resources $FW/Resources
ln -sfh Versions/Current/llama $FW/llama
# Same public headers and module map as the iOS slice built by llama.cpp's script.
cp $SRC/build-ios-device/framework/llama.framework/Headers/* $FW/Versions/A/Headers/
cp $SRC/build-ios-device/framework/llama.framework/Modules/* $FW/Versions/A/Modules/
sed -e 's/<string>iPhoneOS<\/string>/<string>MacOSX<\/string>/' $SRC/build-ios-device/framework/llama.framework/Info.plist > $FW/Versions/A/Resources/Info.plist
LIBS=($(find $OUT -name "*.a" | grep -E "libllama.a|libggml.a|libggml-base.a|libggml-cpu.a|libggml-metal.a|libggml-blas.a|libmtmd.a|libvendor-hash.a"))
echo "linking ${#LIBS} static libraries: ${LIBS:t}"
xcrun libtool -static -o $OUT/combined.a $LIBS 2>/dev/null
xcrun clang++ -dynamiclib -target $TARGET -isysroot $SDK \
    -iframework $SDK/System/iOSSupport/System/Library/Frameworks -L$SDK/System/iOSSupport/usr/lib \
    -Wl,-force_load,$OUT/combined.a -framework Foundation -framework Metal -framework Accelerate \
    -install_name @rpath/llama.framework/Versions/A/llama -o $FW/Versions/A/llama
xcrun strip -S $FW/Versions/A/llama

echo "== xcframework"
rm -rf $DEST && mkdir -p $DEST
xcodebuild -create-xcframework \
    -framework $SRC/build-ios-device/framework/llama.framework \
    -framework $SRC/build-ios-sim/framework/llama.framework \
    -framework $FW \
    -output $DEST/llama.xcframework
echo "wrote $DEST/llama.xcframework"
