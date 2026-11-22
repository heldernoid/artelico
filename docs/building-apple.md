# Building for Mac, iPad and iPhone

Tested with:
- Xcode 27.2 on macOS 27.2 (Apple Silicon);
- an iPad Pro 12.9" (M1) and an iPhone.

The apps target iOS 17 / macOS 14 (Mac Catalyst), so older Xcode versions that support those may work too.

## 1. Tools

```sh
xcode-select --install          # command line tools (if Xcode is not installed yet, install it from the App Store)
brew install xcodegen zstd cmake
```

- **XcodeGen** makes the Xcode projects from `project.yml`. The `.xcodeproj` folders are generated, not stored.
- **zstd** unpacks ASUS's package in step 2.
- **cmake** builds llama.cpp in step 3.

## 2. The stick's runtime image (Hailo Studio only)

```sh
tools/fetch_runtime_image.sh            # ASUS's 204 MB package -> images/core-image-hailo-hailo10-usb-dongle.ext4
```

- The stick has no operating system of its own: at every power-up it appears as "UGen300 USB Loader", and the host
  uploads this 103 MB image into its memory. Hailo Studio bundles the file and does that by itself.
- Artelico doesn't need the image.
- The script checks the image's SHA-256 against the one the apps were tested with.

## 3. llama.cpp for Artelico

Artelico's chat and picture questions use llama.cpp **b12138** as an xcframework that also has a Mac Catalyst
slice. llama.cpp's own release has no Mac Catalyst slice, so it is built from source:

```sh
git clone --branch b12138 --depth 1 https://github.com/ggml-org/llama.cpp.git vendor/llama.cpp-b12138
(cd vendor/llama.cpp-b12138 && ./build-xcframework.sh ios-sim ios-device)    # llama.cpp's own script: iOS slices
native/tools/build_llama_xcframework.sh   # adds the Mac Catalyst slice -> vendor/llama-b12138-artelico/llama.xcframework
```

- This takes 10–20 minutes.
- Hailo Studio doesn't need it: its chat runs on the stick.

## 4. Generate the projects

```sh
DEVELOPMENT_TEAM=ABCDE12345 BUNDLE_ID_PREFIX=com.yourname tools/generate_projects.sh
```

- **`DEVELOPMENT_TEAM`:** your Apple team ID. Find it in Xcode > Settings > Accounts, or at developer.apple.com >
  Membership. A free Apple ID can sign apps for your own devices.
  - Hailo Studio's iPad driver (DriverKit) needs a paid membership.
  - The Mac build of Hailo Studio needs no driver.
- **`BUNDLE_ID_PREFIX`:** bundle identifiers are unique across all of Apple, so use your own. The apps become
  `<prefix>.Artelico`, `<prefix>.UGenProbe` (Hailo Studio) and `<prefix>.UGenProbe.driver`.

Run it again after changing a `project.yml`, or after adding or removing Swift files. The projects list files
explicitly, so new files are only built after regenerating.

## 5. Build

From each app's folder (`Artelico/` or `UGenProbe/`). The scheme names are `Artelico` and `UGenProbe`.

```sh
# Mac (Mac Catalyst)
xcodebuild -project Artelico.xcodeproj -scheme Artelico -configuration Release \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath build-mac -allowProvisioningUpdates build

# iPad or iPhone (find the device's identifier with: xcrun devicectl list devices)
xcodebuild -project UGenProbe.xcodeproj -scheme UGenProbe -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build-ios \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
xcrun devicectl device install app --device <device-id> build-ios/Build/Products/Release-iphoneos/"Hailo Studio.app"

# A compile check without any signing
xcodebuild ... CODE_SIGNING_ALLOWED=NO build
```

- **Xcode:** you can also open the generated project in Xcode and press Run.
- **Release vs Debug:** Release builds are much faster at the per-pixel decoding.
  - UGenKit forces `-O` on its own code in Debug for that reason.
  - Even so, measure speed with Release.
- **Mac apps from other people:** Mac apps built this way run on your Macs. To give one to other people you'd need a
  Developer ID certificate and notarisation, which this project doesn't set up.

## 6. Hailo Studio on the iPad: the driver

The iPad reaches the stick through a DriverKit extension (`UGenProbe/Driver`), embedded in the app.

1. **Register the iPad before the first build.** Pass `-allowProvisioningDeviceRegistration` with the iPad
   connected, or add it at developer.apple.com.
   - Xcode checks the app's profile against the device, but not the driver's "Mac-style" DriverKit profile.
   - A driver profile made before the iPad was registered fails to install with `0xe8008012 (This provisioning
     profile cannot be installed on this device)`.
   - The fix: delete that cached profile in `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` and build
     again.
2. **Development DriverKit entitlements need no request to Apple.** Xcode's automatic signing grants them:
   - `com.apple.developer.driverkit`;
   - `com.apple.developer.driverkit.transport.usb` (development wildcard; the release entitlement lists vendor 2821,
     0x0B05, ASUS);
   - `communicates-with-drivers` on the app.

   A request to Apple is only needed for App Store / distribution builds.
3. **Accept the latest Program License Agreement** at developer.apple.com first. If it's pending, Xcode can't make
   profiles and reports misleading errors about missing entitlements.
4. **On the iPad, turn the driver on:** Settings > Apps > Hailo Studio > Drivers > UGen300 Driver. Then plug in the
   stick.
5. **Testing without a cable:** the stick takes the iPad's only USB-C port. After pairing once by cable (Trust, and
   Developer Mode on), `xcrun devicectl` reaches the iPad over Wi-Fi:
   - `device install app`;
   - `device process launch --terminate-existing <bundle id>`;
   - `device capture screenshot` (it captures whatever is on screen, so tell the iPad's user);
   - `device copy to/from --domain-type appDataContainer`.

On the Mac, Hailo Studio opens the stick directly through IOKit (sandbox entitlement `com.apple.security.device.usb`),
without a driver.

## 7. Models

- **Downloads:** nothing needs to be copied in by hand.
  - Hailo Studio downloads each `.hef` from Hailo's servers the first time it's used.
  - Artelico downloads each Core ML package from https://huggingface.co/helmo/artelico-models, at a pinned
    revision, with a SHA-256 check.
- **The language and speech HEFs** (Qwen, Llama, Qwen2-VL, Whisper) come from `dev-public.hailo.ai`, which only
  serves web browsers. Hailo Studio's Device screen opens them in a browser view inside the app.
- **Folders:**
  - iPad and iPhone: the app's Documents folder, which you can reach in the Files app.
  - Mac: `~/.hailo/models` (Hailo Studio) and `~/.artelico/models` (Artelico), or any folder you choose in "Device
    and models".

See [models.md](models.md).

## 8. The library and its tests (no app needed)

```sh
cd UGenKit
swift build
swift test                                 # ~210 tests; the ones needing the stick or big files are skipped
UGEN_DEVICE_TESTS=1 swift test             # also the tests on a stick plugged into this Mac
swift run ugen boot && swift run ugen identify
swift run ugen detection yolov8s ../testdata/bus.jpg out.png
```

- **Files:** `ugen` looks for files under `$UGEN_ROOT` (default: the repository), in `models/<name>.hef` and
  `images/`.
- **Xcode:** if `swift test` can't find XCTest, point the tools at Xcode:
  `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## 9. Artelico Web

```sh
python3 web/serve.py         # http://localhost:8000
```

- **`serve.py`:** sends the cross-origin isolation headers that WebAssembly threads need.
- **Models:**
  - downloaded from Hugging Face, unless `web/models/` exists (a local conversion output, see
    [models.md](models.md));
  - kept in the browser after the first download.
- **The Space:** `python3 web/tools/build_space.py` writes the static Space into `native/hf/space`. See `web/CLAUDE.md`.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| "The runtime did not appear after the upload" | The stick stayed in loader mode, often after a killed session. Unplug it and plug it in again. |
| The Mac app can't find the stick | Only one program can use the stick at a time: quit the other app, notebook or `ugen` run. |
| The iPad shows the driver but nothing connects | The driver is off in Settings, or the stick was plugged in before it was turned on. Replug after turning the driver on. |
| Xcode: "No profiles for '...driver'" or missing DriverKit entitlements | Accept the Program License Agreement; register the device; delete the stale DriverKit profile (step 6). |
| New Swift file "not found" | Run `tools/generate_projects.sh` again. |
| Slow decoding in a Debug build | Use Release to judge speed. |
