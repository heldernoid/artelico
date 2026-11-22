# Development log

> The project's working log, step by step, as written during development (one Mac, one iPad, one
> iPhone, one stick). It records what was tried, measured and decided, and why. Device IDs, network
> addresses, home folders and road-camera sites are replaced by placeholders such as `<device-id>`;
> "the owner" is the project's author. Paths are relative to the repository unless they start with `~`.


Goal: find out whether an iPad Pro 12.9" (A2461, M1) can drive an ASUS UGen300 (Hailo-10H) over USB
through DriverKit, and if so build a minimal SDK.

Every step is logged here in order: what was done, what was seen, what went wrong, how it was
diagnosed, and what fixed it. Newest entries are at the bottom. All times are local, 2026-11-17.

## Folder layout

| Path | What it is |
|---|---|
| `LOG.md` | This log |
| `tools/usbdump.c` | Mac tool: read-only dump of the stick's USB descriptors |
| `tools/loaderprobe.c` | Mac tool: reads the loader's version, SKU and build string |
| `UGenProbe/` | Phase 1 iPad app plus DriverKit extension (generated with XcodeGen from `project.yml`) |
| `vendor/hailort/` | HailoRT source, shallow clone of v5.5.0 with tags v5.2.0 to v5.4.0 fetched |
| `vendor/ref-ugen300-loader/PROTOCOL.md` | Third-party write-up of the loader protocol |

## How to reach the iPad over Wi-Fi and take screenshots (important)

The iPad Pro has one USB-C port, and the stick needs it. So during tests the iPad cannot be cabled
to the Mac. It does not need to be: once paired, Xcode's command-line tool `devicectl` reaches it over
the local network.

**One-time setup (needs the cable once):**

1. Connect the iPad to the Mac by USB-C and tap **Trust** on the iPad.
2. Turn on Developer Mode: Settings > Privacy & Security > Developer Mode > on > Restart, then
   **Turn On** after the restart.
3. Check that the Mac sees it: `xcrun devicectl list devices`. Note the identifier (UDID).
   This iPad is `<device-id>` (`<device-name>`).

After that, unplug the cable. Nothing else was configured: the wireless link came up by itself.
It needs the iPad and the Mac on the same Wi-Fi network and the iPad awake and unlocked.

**Check that the wireless link is up:**

```sh
xcrun devicectl list devices
# State column: "connected" = usable. "available (paired)" = paired but not reachable right now.
# "connected (no DDI)" = Developer Mode is off (seen before step 2).

xcrun devicectl device info details --device <device-id> | grep -i transport
# "Transport Type: localNetwork" means it is going over Wi-Fi, not the cable.
```

**Take a screenshot of the iPad from the Mac:**

```sh
xcrun devicectl device capture screenshot \
  --device <device-id> \
  --destination /path/to/shot.png
# Prints "Screenshot saved to: ..." and the size (2048x2732 for this iPad).

sips -Z 1400 /path/to/shot.png --out /path/to/shot-small.png   # optional: shrink for viewing
```

It captures whatever is on screen at that moment (any app, including Settings), so the owner is told
whenever a screenshot is taken. `devicectl device capture screen-record` also exists; not used yet.

**Other things that work over the same link:**

```sh
# Install a build
xcrun devicectl device install app --device <device-id> path/to/UGenProbe.app

# List running processes (used to see whether the driver process started)
xcrun devicectl device info processes --device <device-id> | grep -i ugen

# List installed apps
xcrun devicectl device info apps --device <device-id> | grep -i ugen
```

**What does not work this way (so far):**

- Reading the iPad's system log. `idevicesyslog` and `pymobiledevice3` are not installed, and
  `log collect --device-udid` needs root. This is why the app shows the driver's result on screen and
  screenshots are used to read it.

---

## Phase 0: recon on the Mac

### Step 1. Look at the USB bus before plugging in

- Ran `system_profiler SPUSBDataType` and `ioreg -p IOUSB -w0`.
- Nothing with ASUS's vendor ID (`0x0b05`) was present, so the stick was not attached yet.
- Note: on this macOS version `SPUSBDataType` prints nothing; the working type is `SPUSBHostDataType`.

### Step 2. Get the HailoRT source and find the USB transport

- `git clone --depth 1 https://github.com/hailo-ai/hailort.git vendor/hailort` (v5.5.0, commit `e7727f7`).
- Searched for files mentioning USB. The transport lives in:
  - `hailort/hrpc/session_internal/usb/` (host and device sides of the session)
  - `hailort/libhailort/src/device_common/usb/` (device scan and open, via libusb)
  - `hailort/hailort_server/usb/` (the gadget descriptors the device publishes)
  - `hailort/hrpc/rpc_connection.{hpp,cpp}` (message framing)

What the source shows about the running device ("runtime mode"):

- Vendor ID `0x0B05`, product ID `0x1D6F`, product string "UGen300 USB AI Accelerator (Hailo-10H)".
  HailoRT rejects the device as "incompatible firmware" if the product string differs.
- 5 vendor-class interfaces (class `0xFF`, subclass `0xFF`, protocol `0x01`). Interface *i* has bulk OUT
  `0x01+i` and bulk IN `0x81+i`. Max packet 1024 at SuperSpeed, burst 15.
- Connect handshake on endpoint 0: vendor request to the interface recipient (`0x41` out, `0xC1` in),
  `bRequest` 1 = CONNECT, 2 = CLOSE, 3 = reboot, `wValue` 0, `wIndex` 0. The host writes the request
  struct, then reads a 4-byte status with the same `bRequest`.
- RPC framing on the bulk pair: 20-byte header (`magic 0x8A554432`, size, message id, action id, status)
  plus a body of at most 2048 bytes. Server port is 12133. Bulk chunks are capped at 1 MB.
- Large payloads (HEF, input frames, outputs) travel as raw bulk data after the message.
- Calls for one inference: `VDEVICE__CREATE`, `VDEVICE__CREATE_INFER_MODEL` (HEF follows),
  `INFER_MODEL__CREATE_CONFIGURED_INFER_MODEL`, `CONFIGURED_INFER_MODEL__RUN_ASYNC`.
  `DEVICE__IDENTIFY` also exists.
- Not done yet: decoding each call's body format (Phase 2).

### Step 3. Problem: the loader that boots the stick is not in the source

- How it showed up: `scripts/install_usb.sh` and `load_usb_image.sh` call a binary named
  `hailo_usb_loader` in `rfs-upload` mode and install `core-image-hailo-hailo10-usb-dongle.ext4`.
  Only the loader's name, modes and output strings are in the repo (`common/usb_loader_protocol.h.in`).
- Checked older releases: fetched tags v5.2.0, v5.3.0, v5.4.0 and branch `master-v5.3.0`. None contains
  the loader source.
- Meaning: the stick does not boot on its own. The host must upload a Linux root filesystem every time
  it is powered, and the protocol for that is undocumented by Hailo.

### Step 4. Plug the stick in and record what it reports

- `ioreg` showed a new device named "UGen300 USB Loader" (not the runtime name), confirming step 3.
- `ioreg -l` gave the device-level fields but no interfaces, because macOS leaves a vendor-class
  device unconfigured.
- Fix: wrote `tools/usbdump.c`, which uses IOKit to issue only `GET_DESCRIPTOR` requests (no open, no
  configuration change), and ran it.

Result:

| Field | Value |
|---|---|
| Vendor / product | `0x0B05` / `0x1D6F` |
| Product / manufacturer | "UGen300 USB Loader" / "Hailo Technologies Ltd." |
| Serial | `H10-DEV-001` |
| Device class | `0xFF`, bcdDevice `0x0515` |
| Link | 10 Gb/s, declares 896 mA (112 units of 8 mA) |
| Configurations | 2, current configuration 0 |

- Configuration 1 "Hailo RFS Loading Mode": interface 0, class `0xFF/0x00/0x01`, bulk OUT `0x01`,
  interrupt IN `0x81`, both 1024-byte max packet.
- Configuration 2 "Hailo Software Update Mode": same layout.
- The stick was plugged in through a VIA Labs USB hub during these tests.

### Step 5. Find the loader protocol

- Web search for `hailo_usb_loader` found:
  - A Hailo forum thread confirming the loader source was removed from the HailoRT repo and only
    binaries ship.
  - `github.com/DavidAlpha89/ugen300-loader`: a third-party macOS reimplementation, with
    `docs/PROTOCOL.md` reconstructed from USB captures of the official tool.
  - `github.com/DavidAlpha89/hailort-macos-usb`: an experimental macOS port of HailoRT 5.3.0 over libusb.
  - `github.com/Asus-UGen-Series/UGen300-USB-Firmware-Upgrade`: ASUS's firmware package and guide.
- Saved the protocol document to `vendor/ref-ugen300-loader/PROTOCOL.md`. It is third-party and
  was treated as unverified until checked against this unit.
- Its description of the loader (two configurations, endpoints, names, bcdDevice 5.15) matched
  step 4 exactly.

Boot sequence according to that document (upload itself not yet tested here):

1. `SET_CONFIGURATION 1`, claim interface 0.
2. Vendor IN requests to the device (`0xC0`): `0x16` protocol version, `0x14` SKU, `0x11` build string.
3. Vendor OUT `0x12` with the image size split across `wIndex:wValue`.
4. Poll `0x15` until ready, send two 64-byte pings of `0xAA` on bulk OUT, check the byte counter.
5. Send the image in 65,536-byte bulk transfers, then one zero-length transfer.
6. The stick re-enumerates about 5 s later in runtime mode.

The image is about 103 MB, comes from ASUS's `UGen300_USB_FW_Upgrade.zip`, and lives in RAM only.

### Step 6. Verify the protocol on this unit from the Mac

- Wrote `tools/loaderprobe.c` to send the three read requests from step 5.2.
- Problem: all three failed with `0xe000404f`.
- Diagnosis: that code is `kIOUSBPipeStalled`. The device stalls vendor requests while unconfigured,
  which fits the document's note that macOS does not select a configuration.
- Fix: added a `--configure` flag that opens the device and calls `SetConfiguration(1)` first. This is
  what Linux does automatically, and a replug undoes it.
- Result: protocol version `1`, SKU `NA`, build `Hailo Linux build v1.10.10`.
- Meaning: the Mac exchanged data with the stick; the third-party document is right about this part;
  and the stick already has ASUS's first-use firmware update. Build v1.10.10 pairs with the
  HailoRT 5.3.0 runtime image.

### Step 7. Version check between HailoRT releases

- `git diff v5.3.0 v5.5.0` on the USB protocol files.
- Finding: the CONNECT request is 5 bytes in v5.3.0 (interface, port) and 9 bytes in v5.5.0, which
  added `session_group_id`. v5.5.0 also added the reboot opcode.
- Consequence: Phase 2 must follow the v5.3.0 definitions, because that is the runtime this stick's
  loader accepts.

### Phase 0 conclusions

- Firmware is never touched by this plan. The runtime goes to RAM; the only flash-writing operation is
  `fw-update` (configuration 2), which is not needed and will not be run.
- A standalone iPad app would have to bundle the 103 MB image and implement the upload itself.
- Power is an open question: HailoRT warns of reduced performance below 3.0 A.

---

## Phase 1: go/no-go on the iPad

Design: the smallest test that proves data exchange. The driver matches the stick in loader mode,
opens it, selects configuration 1, and reads the protocol version, SKU and build string, the same
exchange that worked from the Mac in step 6. No runtime image is needed. The app reads the result from
the driver and shows GO or NO-GO with the status of every step.

### Step 8. Check the toolchain

- `xcodebuild -version`: Xcode 27.2. `xcrun --sdk driverkit --show-sdk-version`: 27.2.
- `security find-identity -v -p codesigning`: one Apple Development and one Apple Distribution identity.
- `security find-certificate ... | openssl x509 -noout -subject`: the certificates' `OU` field gave team
  ID `<team-id>`, later confirmed by the owner.
- `xcrun devicectl list devices`: at first only an iPhone and a Watch; the iPad was not paired.
- XcodeGen is installed (`/opt/homebrew/bin/xcodegen`), so the project is generated from `project.yml`.

### Step 9. Write the driver and app

Files in `UGenProbe/`:

- `Shared/UGenShared.h`: the result struct and selectors shared by driver and app.
- `Driver/UGenDriver.iig` and `.cpp`: the driver. `Start` runs the probe and always registers the
  service, so a failed probe can still be read by the app.
- `Driver/UGenUserClient.iig` and `.cpp`: user client with two calls, "get last result" and
  "run probe again".
- `App/`: SwiftUI app that opens the user client and shows the verdict.
- `project.yml`: two targets, the app and a `driver-extension` target embedded under
  `SystemExtensions/`.

Driver matching (in the driver's `Info.plist`): `IOProviderClass` `IOUSBHostDevice`, `idVendor` 2821,
`idProduct` 7535, `IOClass` `IOUserService`.

Entitlements:

- Driver: `com.apple.developer.driverkit`, `com.apple.developer.driverkit.transport.usb` with
  `idVendor` 2821.
- App: `com.apple.developer.driverkit.communicates-with-drivers`.
- Correction to an earlier note: `com.apple.developer.system-extension.install` is macOS-only and is
  not used. On iPadOS the driver ships inside the app and is switched on in Settings.

### Step 10. Compile unsigned, fix build errors

Command: `xcodebuild ... -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`.

| Error | Cause | Fix |
|---|---|---|
| `use of undeclared identifier 'IOUSBHostFreeDescriptor'` | Declared in a header that was not included | Added `#include <USBDriverKit/USBDriverKitDefs.h>` |
| `cannot initialize a parameter of type 'uintptr_t' with ... nullptr_t` | `IOUSBHostDevice::Open`'s third argument is an integer, not a pointer | Changed `Open(this, 0, nullptr)` to `Open(this, 0, 0)` |
| `Unable to resolve module dependency: 'IOKit'` | The iOS SDK ships IOKit headers but no Swift module | Removed `import IOKit`, included `<IOKit/IOKitLib.h>` from the bridging header, linked `IOKit.framework` |

Result: build succeeded; the app bundle contains `SystemExtensions/UGenDriver.dext` with the expected
matching dictionary.

### Step 11. Pair the iPad

- After the owner connected the iPad and tapped Trust, `devicectl list devices` showed
  `<device-name>`, iPad Pro 12.9" 5th generation (`iPad13,11`), state `connected (no DDI)`.
- "no DDI" means the developer disk image is not mounted, which is the state before Developer Mode is on.
- Owner enabled Developer Mode: Settings > Privacy & Security > Developer Mode > on > Restart > Turn On.

### Step 12. First signed build: blocked by the Program License Agreement

- Set `DEVELOPMENT_TEAM: <team-id>` in `project.yml`, regenerated, built with
  `-allowProvisioningUpdates` for the iPad.
- Errors:
  - `Unable to process request - PLA Update available: You currently don't have access to this
    membership resource. To resolve this issue, agree to the latest Program License Agreement in your
    developer account.`
  - `No profiles for 'io.ugenkit.UGenProbe.driver' were found: Xcode couldn't find any DriverKit App
    Development provisioning profiles`
  - `Provisioning profile "iOS Team Provisioning Profile: *" doesn't include the
    com.apple.developer.driverkit.communicates-with-drivers entitlement` and does not include the iPad.
- Diagnosis: the first error is the root cause. With the agreement pending, Xcode cannot register
  devices or identifiers or create profiles, which produces the others.
- Fix: the owner accepted the updated agreement at developer.apple.com/account.

### Step 13. Second signed build: succeeds, entitlements granted

- Rebuilt with `-allowProvisioningUpdates -allowProvisioningDeviceRegistration`: build succeeded.
- `codesign -d --entitlements -` on the driver shows `com.apple.developer.driverkit` and
  `com.apple.developer.driverkit.transport.usb` with `idVendor` 2821.
- Finding: Xcode's automatic signing granted the development DriverKit entitlements without any
  request to Apple. A request is only needed for distribution.
- Side effects on the developer account: the iPad was registered as a device, and two app identifiers
  were created, `io.ugenkit.UGenProbe` and `io.ugenkit.UGenProbe.driver`.

### Step 14. Install fails: the driver's profile does not include the iPad

- Command: `xcrun devicectl device install app --device <iPad> UGenProbe.app`.
- Error: `Failed to install Mac-style embedded profile for io.ugenkit.UGenProbe.driver : 0xe8008012
  (This provisioning profile cannot be installed on this device.)`
- Diagnosis: decoded both embedded profiles with `security cms -D -i <profile>`.
  - App profile "iOS Team Provisioning Profile: io.ugenkit.UGenProbe": contains the iPad, created 15:13:44Z.
  - Driver profile "DriverKit Team Provisioning Profile: io.ugenkit.UGenProbe.driver": lists 2 devices,
    not the iPad, created 15:13:41Z.
  - The driver profile was generated 3 seconds before the iPad was registered, so it missed it.
- First attempt at a fix: `clean build` with provisioning updates. Did not help; Xcode reused the same
  profile (same creation time) from its cache in
  `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`.
- Fix (with the owner's approval, since the file is outside the project folder): moved the stale cached
  profile `884e87c7-b545-4549-a853-d70a347c8184.provisionprofile` from Xcode's cache into `backup/` in
  the project, then ran `clean build` again.
- Result: Xcode fetched a new driver profile (`a50e2a7a-...`, created 15:16:08Z) that includes the iPad.
- Lesson: register the device before the first DriverKit build, or clear the cached DriverKit profile
  after registering it. Xcode checks the iOS app profile against the destination device but not the
  "Mac-style" DriverKit profile.

### Step 15. Install on the iPad

- `xcrun devicectl device install app --device <device-id> UGenProbe.app`
- Result: `App installed: bundleID: io.ugenkit.UGenProbe`.
- Next: enable the driver in Settings on the iPad, plug the stick into the iPad, open the app and read
  the verdict.

### Step 16. First run on the iPad: driver service not found

- Owner reported that "Read last result" showed nothing new.
- How it was checked from the Mac (the iPad stays reachable over Wi-Fi after pairing, so its single
  USB-C port is free for the stick):
  - `xcrun devicectl device info details`: transport `localNetwork`.
  - `xcrun devicectl device capture screenshot`: the app shows "NO-GO: Driver service not found".
  - `xcrun devicectl device info processes`: the app is running, but there is no process for
    `io.ugenkit.UGenProbe.driver`. `driverkitd` is running.
  - `ioreg -p IOUSB` on the Mac: the stick is no longer on the Mac's bus.
- Meaning: the driver was never started. Either it is not enabled in Settings, the stick is not
  enumerating on the iPad, or matching failed. Not yet known which.

### Step 17. Narrow it down: is the driver enabled, and does the iPad see the stick?

- Screenshot of Settings > Apps > UGen Probe: a "Drivers" section exists and "UGen300 Driver" is on.
  So iPadOS accepted the embedded driver and the owner had enabled it.
- To see whether the stick enumerates, added a diagnostics section to the app (`RegistryScan` in
  `App/DriverClient.swift`) that lists `IOUSBHostDevice`, `IOUSBHostInterface` and `IOUserService`
  entries in the I/O Registry.
- Rebuilt, installed over Wi-Fi, and launched remotely with
  `xcrun devicectl device process launch --device <UDID> --terminate-existing io.ugenkit.UGenProbe`.
- Screenshot result:
  - `IOUSBHostDevice`: 1 found, named "UGen300 USB Loader". **The iPad powers and enumerates the stick.**
  - `IOUSBHostInterface`: 0 found (expected: the device is unconfigured until a driver configures it).
  - `IOUserService`: 3 found, all Apple Wi-Fi drivers. Ours is not among them.
  - The app can read entry names but no properties (sandbox), so vendor and product IDs are not shown.
- Meaning: enumeration and power are fine, the driver is enabled, but it has not attached to the device.
- Not yet ruled out: the stick was already plugged in when the driver was enabled or when the app was
  reinstalled, and matching only happens when a device attaches. A replug tests this.
- Log access attempt: `/usr/bin/log collect --device-udid <UDID>` fails with "Must be root to collect
  logs from attached device". Note that in zsh `log` is a shell builtin, so the full path is required.
- Status: open, waiting for a replug.

### Step 18. Still not attached after tapping the button again

- Screenshot: "Last checked" time updated, so the app's buttons work; the verdict is unchanged because
  the driver is still not running. The stick is still listed as "UGen300 USB Loader".
- Checked the installed build:
  - `lipo -info` on the driver binary: `x86_64 arm64`.
  - Driver profile entitlements: `com.apple.developer.driverkit` true and
    `com.apple.developer.driverkit.transport.usb` = `[{idVendor: "*"}]` (the development wildcard).
  - App profile includes `com.apple.developer.driverkit.communicates-with-drivers`.
  - iPadOS version: 27.0.1.
- Tried to pull system logs with `xcrun devicectl device sysdiagnose --device <UDID> --destination logs/`.
  It failed straight away with `CoreDeviceCLISupport.DiagnoseError error 0` and gathered nothing.
- Found one defect in the driver's `Info.plist`: `CFBundlePackageType` was missing (XcodeGen does not add
  it for driver extensions; Xcode's own template sets it to `DEXT`). Added
  `CFBundlePackageType: DEXT` in `project.yml`, rebuilt, reinstalled and relaunched over Wi-Fi.
  Whether this was the cause is not known yet.
- Status: resolved in step 19.

### Step 19. Phase 1 result: GO

- Right after the build with `CFBundlePackageType: DEXT` was installed, the driver attached by itself.
  The owner did not replug the stick or touch the iPad.
- Evidence (screenshot saved as `logs/phase1-go-screenshot.png`, taken 16:26):

| Item | Value read by the driver on the iPad |
|---|---|
| Verdict | GO, stage 5 of 5 |
| Vendor / product | `0x0b05` / `0x1d6f` |
| bcdDevice, class, configurations | `0x0515`, `0xff`, 2 |
| Open, descriptor, SetConfiguration(1) | ok, ok, ok |
| Protocol version (request `0x16`) | 1 |
| SKU (request `0x14`) | NA |
| Build (request `0x11`) | Hailo Linux build v1.10.10 |

- These are the same three values the Mac read in step 6.
- `devicectl device info processes` now shows the driver running from
  `/private/var/db/driverkitd/SystemExtensions/<UUID>/UGenDriver.dext/UGenDriver`.
- Cause of steps 16 to 18: almost certainly the missing `CFBundlePackageType`. It was the only change
  between the build that never attached and the one that did, and the earlier reinstall with the stick
  attached had not triggered a match. Not confirmed from system logs, since none could be collected.
- Side finding: installing a new build re-registers the driver and matches an already-attached stick,
  so a replug is not needed after an install.
- Lesson: when generating a DriverKit target with XcodeGen, set `CFBundlePackageType: DEXT` explicitly.
  Without it the driver still installs and still appears under Settings > Apps > (app) > Drivers, but
  never starts.

### Phase 1 conclusions

- An iPad Pro M1 on iPadOS 27.0.1 can attach a third-party DriverKit driver to the UGen300, open it,
  set its configuration, and complete vendor control transfers.
- Development signing was enough. No entitlement request to Apple was needed.
- The iPad powers the stick in loader mode with no power warning reported.
- Not yet tested on the iPad: bulk transfers, the 103 MB runtime upload, power draw under inference
  load, and the runtime-mode interfaces. These are Phase 2.
- Stopped here to report, as agreed.

---

## Phase 2: runtime, inference, SDK

Owner approved going ahead after the Phase 1 report.

### Step 20. Get the runtime image

- Downloaded ASUS's official package (204 MB) with `curl` into `vendor/asus-fw/`:
  `https://dlcdnets.asus.com/pub/ASUS/AI_ACCELERATION_DEVICE/FW/UGen300_USB_FW_Upgrade.zip`
  (link taken from `github.com/Asus-UGen-Series/UGen300-USB-Firmware-Upgrade`).
- Contents: HailoRT and USB driver `.deb` packages for 5.2.2 and 5.3.0 (amd64 and arm64), plus a
  `provisionV3` firmware update image.
- A `.deb` is an `ar` archive: `ar x hailort-usb-driver_5.3.0_arm64.deb` gives `data.tar.zst`;
  `tar -xf data.tar.zst <path>` extracts single files. No Linux machine needed.
- Extracted `core-image-hailo-hailo10-usb-dongle.ext4` to `images/`:
  103,057,408 bytes, SHA-256 `558c1400...2639f`. The size matches the third-party protocol notes.
- The package also holds Hailo's closed `hailo_usb_loader` binary (Linux only, 18 KB), the `-swu.ext4`
  update rootfs and a `.swu` firmware update. None of those are used.
- How Linux triggers the upload (from the package's udev rule): when a USB device with product string
  "UGen300 USB Loader" appears, it runs `hailo_usb_loader rfs-upload`.

### Step 21. Write the Mac uploader and boot the runtime

- Wrote `tools/ugenload.c` (IOKit only, no libusb) implementing the upload sequence from step 5. It
  refuses to run unless the product string is "UGen300 USB Loader", the protocol version is 1 and the
  build string is "Hailo Linux build v1.10.10".
- Owner moved the stick from the iPad to the Mac.
- `./tools/ugenload images/core-image-hailo-hailo10-usb-dongle.ext4` output:

```
found "UGen300 USB Loader"
bulk OUT endpoint 0x01, max packet 1024
loader protocol 1, SKU "NA", build "Hailo Linux build v1.10.10"
upload start sent for 103057408 bytes
ping byte counter: 64 (expected 64)
sent 103057408 bytes in 0.48 s (216.2 MB/s); end marker kr=0x00000000
runtime is up after 4.3 s: "UGen300 USB AI Accelerator (Hailo-10H)"
```

- Result: the upload protocol from the third-party notes works on this unit, first try. Total boot
  time from the Mac is about 5 seconds.

### Step 22. Record the runtime-mode descriptors

`./tools/usbdump` with the runtime booted:

| Field | Value |
|---|---|
| Product / serial | "UGen300 USB AI Accelerator (Hailo-10H)" / `HRT-USB-001` |
| Device class | `0xFF`, bcdDevice `0x0100` |
| Configurations | 1 ("HailoRT USB"), declares 496 mA (62 units of 8 mA) |
| Interfaces | 5, each class `0xFF/0xFF/0x01` |
| Endpoints | interface *i*: bulk OUT `0x01+i`, bulk IN `0x81+i`, 1024-byte packets, burst 15 |

- This matches what the HailoRT source predicted in step 2, with one difference: the device class is
  `0xFF` here, not `0xEF` as in the v5.5.0 gadget script.
- Consequence for the iPad driver: it currently tells loader mode from runtime mode by device class,
  which is `0xFF` in both. It must use the number of configurations (2 vs 1) or bcdDevice instead.
- macOS again leaves the device unconfigured, so the host must call `SetConfiguration(1)`.

### Step 23. Get the model

- `yolov8m.hef` for Hailo-10H from the Hailo Model Zoo, compiled for 5.3.0 (26.7 MB):
  `https://hailo-model-zoo.s3.eu-west-2.amazonaws.com/ModelZoo/Compiled/v5.3.0/hailo10h/yolov8m.hef`
  SHA-256 `c0906911...b75d54`. Versions v5.0.0 to v5.3.0 exist at the same path pattern.
- `shortcut_net.hef` (22 KB test model) from
  `https://hailo-hailort.s3.eu-west-2.amazonaws.com/Hailo10H/5.3.0/HEFS/shortcut_net.hef`.
- Both saved in `models/`.

### Step 24. Reference HailoRT on the Mac (in progress)

- Purpose: an independent reference for the inference output, and ground truth for buffer sizes.
- Hailo does not support macOS. Cloned the third-party port
  `github.com/relaxcloud-cn/hailort-macos-usb` (HailoRT 5.3.0 over libusb) to
  `vendor/ref-hailort-macos-usb`.
- Before building, diffed it against official v5.3.0 (`git diff --stat v5.3.0 HEAD`): 36 files, about
  1,000 added lines, mostly docs and scripts. The source changes are `#if defined(__APPLE__)` portability
  edits plus selecting USB configuration 1 on macOS. Nothing suspicious.
- Problem: its build needs `pkg-config`, which is not installed. To avoid installing anything outside
  the project, replaced `hailort/cmake/external/libusb.cmake` in the clone with a version that points
  directly at Homebrew's existing libusb (`/opt/homebrew/opt/libusb`). `cmake` and `libusb` were
  already installed.
- Build running: `cmake -S . -B build-macos-usb ... && cmake --build build-macos-usb --target hailortcli`.

### RPC details confirmed from the v5.3.0 source (for the port)

- Checked out v5.3.0 next to the v5.5.0 clone: `git worktree add ../hailort-5.3.0 v5.3.0`.
- Message bodies are protobuf (`hailort/hrpc_protocol/rpc.proto`).
- Every message is sent as a fixed 2,068-byte transfer (20-byte header + 2,048-byte body area), with the
  real body length in the header's `size` field.
- CONNECT request in v5.3.0 is 5 bytes: interface (u8), port (u32). CLOSE is port (u32), interface (u8).
- `VDevice_CreateInferModel_Request` carries `hef_size`; the HEF bytes follow as raw bulk data.
- `ConfiguredInferModel_AsyncInfer_Request` carries a list of buffer sizes for inputs then outputs; the
  input frames follow as raw bulk data, and the outputs follow the reply.

### Step 25. Write a portable RPC client and run it from the Mac

- Wrote `UGenKit/Sources/CUGenRT/ugenrt.c` and `include/ugenrt.h`: a dependency-free C client for the
  HailoRT 5.3.0 RPC protocol. It contains a small protobuf encoder/decoder, the CONNECT/CLOSE handshake,
  message framing, and calls for device identify, chip temperature, create vdevice, create infer model
  (HEF upload), configure, and run inference. USB access is behind a 4-function transport interface
  (control out, control in, bulk out, bulk in) so the same code runs on the Mac and the iPad.
- Wrote `tools/ugenrt_mac.c`: a Mac command-line front end with an IOKit transport.
- Build: `clang -O2 -I ../UGenKit/Sources/CUGenRT/include -o ugenrt ugenrt_mac.c
  ../UGenKit/Sources/CUGenRT/ugenrt.c -framework IOKit -framework CoreFoundation`
- `./tools/ugenrt identify`, first run:

```
Firmware Version: 5.3.0 (release)
Protocol Version: 2, Logger Version: 0
Device Architecture: 6 (6 = HAILO10H)
Chip temperature: 32.0 C / 31.4 C
```

- Board name, product name, serial and part number came back empty. Not yet checked whether the device
  really leaves them empty or the decoder misses them.
- Design shortcut that worked: the configure request is sent with no stream parameters, so the device
  keeps the HEF's own defaults (input UINT8 NHWC, output float32 NMS-by-class). The server only
  overrides what the client sends (`hailort_server.cpp`, `handle_infer_model_create_configured_infer_model`).
  This avoids parsing the HEF on the host.

### Step 26. First inference, from the Mac

- Test image: `bus.jpg` from `github.com/ultralytics/assets` (810x1080), resized to 640x640 with
  `sips -s format bmp -z 640 640` (plain stretch, no letterbox), then converted to raw RGB with a
  short Python script. Result: `testdata/bus640.rgb`, 1,228,800 bytes.
- Output size assumed 160,320 bytes: 80 classes x (1 count + 100 boxes x 5 floats) x 4 bytes. The
  device accepted it.
- `./tools/ugenrt infer models/yolov8m.hef testdata/bus640.rgb 160320 testdata/bus640.mac.out 200`:

| Step | Time on the Mac |
|---|---|
| Create vdevice | 2.1 ms |
| Upload HEF (26.7 MB) and create infer model | 116 ms |
| Configure | 304 ms |
| First inference | 31.4 ms |
| Next 199 inferences | mean 29.73 ms, min 29.11, max 31.62 |
| Throughput, one frame at a time | 33.6 FPS |

- Detections (`python3 tools/decode_nms.py testdata/bus640.mac.out`): bus 0.928; persons 0.940, 0.932,
  0.905, 0.814, 0.345; tie 0.414. That is the expected content of this photo.
- The output is byte-identical across runs (`cmp`), so the iPad result can be compared byte for byte.
- These Mac numbers were measured through a USB hub at 10 Gb/s.
- Reference build status: the third-party HailoRT port fails to compile with Xcode 27's C++ library
  (`file_utils.hpp:58: implicit instantiation of undefined template 'std::fpos<__mbstate_t>'`).
  Not fixed yet, so there is no comparison against Hailo's own client so far; the Mac numbers above
  come from this project's client.

### Step 27. Port to the iPad: driver becomes a USB pipe, protocol moves into UGenKit

Design decision: keep the driver as small as possible and put all protocol logic in the app-side
library, so the same C code that was validated on the Mac runs unchanged on the iPad.

- **Driver** (`UGenProbe/Driver/`), rewritten:
  - On attach: opens the device, reads the descriptor, calls `SetConfiguration(1, false)`, takes the
    first interface from `CreateInterfaceIterator`/`CopyInterface`, opens it, and allocates two 1 MB
    I/O buffers.
  - Mode detection now uses the number of configurations (2 = loader, 1 = runtime), fixing the issue
    noted in step 22.
  - User-client selectors: get info, control in, control out, bulk out, bulk in.
  - Data up to 4,096 bytes arrives inline; larger data arrives as a memory descriptor, which the user
    client maps (`CreateMapping`) and copies into the driver's buffer.
  - Bulk transfers use the synchronous `IOUSBHostPipe::IO`, at most 1 MB per call.
- **C core additions** (`UGenKit/Sources/CUGenRT/`):
  - `ugenloader.c`: the runtime upload sequence from `tools/ugenload.c`, rewritten against the
    transport interface so it also runs on the iPad.
  - `ugen_ios_transport.c`: transport that forwards to the driver with `IOConnectCallMethod`.
  - `ugen_session_open` now sends CLOSE and retries once if CONNECT is refused, in case an earlier
    client exited without closing.
- **Swift package `UGenKit`** (`UGenKit/Package.swift`, targets `CUGenRT` and `UGenKit`):
  - `UGenDevice` actor: `connect()`, `loaderInfo()`, `bootRuntime(image:)`, `identify()`,
    `loadModel(hef:description:)`, `detect(image:) async throws -> [Detection]`, `infer(rgb:)`.
  - `ModelDescription.yolov8m` and the NMS-by-class decoder.
  - `detect(image:)` stretches the image to 640x640 (no letterbox), the same as the Mac test frame.
- **App** (`UGenProbe/App/ContentView.swift`): buttons for each step and a "Run full test" that connects,
  boots the runtime if needed, loads yolov8m, runs the reference frame 200 times, and compares the
  output's SHA-256 with the Mac run (`25460785...8d3a1`). It also saves `bus640.ipad.out` and
  `ugen-log.txt` to its Documents folder. Launching with `-autorun` starts the full test.
- The app bundles the runtime image, `yolov8m.hef`, `bus640.rgb` and `bus.jpg`; the bundle is 126 MB.
- Swift detail: anonymous C enums such as `UGEN_OK` import into Swift as `Int` constants, not as an
  enum type, so they are compared with `Int32(UGEN_OK)`.
- Built and installed over Wi-Fi. Not yet run on the iPad: the stick was still on the Mac.

### Step 28. First iPad run of the new build: driver crash during the upload

- Owner moved the stick to the iPad. The Mac launched the app in auto-run mode over Wi-Fi:
  `xcrun devicectl device process launch --device <UDID> --terminate-existing -- io.ugenkit.UGenProbe -autorun`
  (the `--` before the bundle ID is needed, otherwise `-autorun` is parsed as a devicectl option).
- Screenshot: connected in loader mode and read "protocol 1, SKU NA, build v1.10.10" through the new
  driver, then `FAILED full test: runtime upload: USB transfer failed (0xfffffecc)`.
- Diagnosis:
  - `0xfffffecc` is -308, `MIG_SERVER_DIED`: the driver process died during the call.
  - `devicectl device info processes` showed the driver with a new process ID, confirming a restart.
  - Crash reports can be read over Wi-Fi:
    `xcrun devicectl device info files --device <UDID> --domain-type systemCrashLogs` lists them, and
    `xcrun devicectl device copy from --device <UDID> --domain-type systemCrashLogs --source <name>.ips
    --destination <file>` downloads one. Saved in `logs/crash/`.
  - The report shows `EXC_BAD_ACCESS`, `KERN_PROTECTION_FAILURE`, in `memmove` called from
    `UGenDriver::BulkOut`: the copy into the driver's own output buffer faulted.
- Cause: a buffer created with `CreateIOBuffer(kIOMemoryDirectionOut, ...)` is mapped read-only inside
  the driver. Phase 1 never hit this because it only used device-to-host buffers.
- Fix: create the buffers the driver writes into with `kIOMemoryDirectionInOut` (the 1 MB bulk OUT
  buffer and the control OUT data buffer). Rebuilt, reinstalled, relaunched.

### Step 29. Phase 2 result on the iPad: PASS

Full test on the iPad, with the stick plugged directly into it and no Mac involved in the data path
(`logs/ugen-log.txt`, screenshot `logs/phase2-pass-screenshot.png`):

```
connected: loader mode
loader protocol 1, SKU NA, build Hailo Linux build v1.10.10
runtime booted in 6.21 s
firmware 5.3.0, architecture 6, chip 32.4 C
yolov8m loaded and configured in 438.86 ms
first inference: 32.28 ms
200 inferences: mean 31.50 ms, min 29.89 ms, max 33.52 ms
throughput: 31.7 FPS (one frame at a time)
output SHA-256 25460785175f0fae... MATCHES the Mac run
detect(image:) on bus.jpg: 8 objects, preprocess 64.71 ms, inference 29.79 ms
```

- The output file was copied back with
  `xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer
  --domain-identifier io.ugenkit.UGenProbe --source Documents/bus640.ipad.out --destination logs/...`
  and `cmp` confirms it is byte-identical to `testdata/bus640.mac.out`.

| Measure | Mac (via hub) | iPad Pro M1 (direct) |
|---|---|---|
| Boot runtime (upload 103 MB + restart) | about 5 s | 6.21 s |
| Load and configure yolov8m | 420 ms | 439 ms |
| Mean latency per frame, 200 runs | 29.73 ms | 31.50 ms |
| Throughput, one frame at a time | 33.6 FPS | 31.7 FPS |

- `detect(image:)` on the original 810x1080 JPEG found 8 objects (the same bus and people, plus a
  low-confidence frisbee). Its scores differ slightly from the reference frame because CoreGraphics
  resamples differently from `sips`. Preprocessing took 64.7 ms, which is the slowest part of that path
  and has not been optimized.
- Not done: comparison against Hailo's own client (the reference HailoRT build for macOS still fails to
  compile), pipelining several frames at once (the device reports an async queue of 27), and power
  measurements.

---

## Phase 3: Hailo Studio on the iPad

Owner's goal: bring the features of their Ubuntu web app, Hailo Studio (`repo/hailo_studio`), to the iPad,
with support for all the models Studio uses. Where Studio depends on hailo-apps, GStreamer/TAPPAS or
Hailo's GenAI client (none of which exist on iPadOS), native replacements are to be built on UGenKit.

What Studio offers (from its README and `core.py`): vision tasks on photos and clips (detection, pose,
instance segmentation, oriented boxes, super-resolution, classification, depth, semantic segmentation,
OCR, lane detection); live video pipelines (detect and track, pose, segmentation, depth, tiling, CLIP
tagging, face recognition, multi-camera, re-identification, live OCR, lanes); chat, image questions and
speech to text (Qwen2.5-1.5B, Qwen2-VL-2B, Whisper); and a device page with a model store.

### Step 30. Hailo's own command-line tool now builds on the Mac

- Delegated to a sub-agent with instructions to make minimal source edits only.
- Fix: one file, `vendor/ref-hailort-macos-usb/hailort/common/file_utils.hpp`: added
  `#include <fstream>` and `#include <string>`. Xcode 27's C++ library no longer pulls these in
  indirectly. No other errors.
- Result: `vendor/ref-hailort-macos-usb/build-macos-usb/hailort/hailortcli/hailortcli`.
- `hailortcli parse-hef models/yolov8m.hef` confirms what step 26 assumed: input
  `yolov8m/input_layer1` UINT8 NHWC 640x640x3; output `yolov8m/yolov8_nms_postprocess` FLOAT32
  NMS-by-class, 80 classes, 100 boxes per class, frame size 160,320; score threshold 0.2, IoU 0.7.

### Step 31. Validation against Hailo's client, and the pipelining gap

With the stick booted on the Mac (through the hub):

- `hailortcli fw-control identify`: firmware 5.3.0 (release, app), HAILO10H. Same as this project's client.
- It also prints: "USB-C source electrical current advertised: 1.5A. The module may run in
  reduced-performance mode. For full performance, use a USB-C port that advertises 3.0A."
- `hailortcli run2 -t 8 set-net models/yolov8m.hef`: **59 FPS**.
- This project's client on the same setup: 29.6 ms per frame, **33.7 FPS**.
- Why: Hailo's tool keeps several frames in flight (the device reported an async queue of 27), while
  this client sends one frame and waits. Pipelining is needed to close the gap. Not done yet.

### Step 32. Model catalog: every Hailo-10H model Studio can use

- Studio gets its model lists from hailo-apps, so cloned `github.com/hailo-ai/hailo-apps` (commit
  `c61f843`) to `vendor/hailo-apps` and read `hailo_apps/config/resources_config.yaml`.
- URL rules, from `hailo_apps/installation/download_resources.py`:
  - source `mz`: `https://hailo-model-zoo.s3.eu-west-2.amazonaws.com/ModelZoo/Compiled/<version>/hailo10h/<name>.hef`
  - source `s3`: `https://hailo-csdata.s3.eu-west-2.amazonaws.com/resources/hefs/h10/<name>.hef`
  - source `gen-ai-mz`: `https://dev-public.hailo.ai/<version>/blob/<name>.hef`
- `tools/build_catalog.py --check` writes `models/catalog.json` and checks each URL with a HEAD request.
  Model Zoo version pinned to v5.3.0 to match the stick's runtime (hailo-apps defaults to v5.4.0).
- Result: 65 models. All 61 vision models resolve. The 4 GenAI models (Qwen2.5-1.5B-Instruct,
  Qwen2-VL-2B-Instruct, Qwen2.5-Coder-1.5B-Instruct, Whisper-Base) return **HTTP 403** at the v5.3.0
  path; their correct location is still to be found.
- Downloaded all 61 vision models to `models/` (1.2 GB).

### Step 33. Ground truth for every model's inputs and outputs

Rather than writing a HEF parser first, the model table is generated on the Mac with Hailo's own library:

- `tools/hefinfo.c` (built by `tools/build_hefinfo.sh` against the reference library) prints each
  model's streams as JSON: name, type, order, shape, and the quantization zero point and scale.
- `tools/build_model_info.py` joins that with the catalog and the NMS thresholds from `parse-hef`, checks
  that frame sizes agree between the two sources, and writes
  `UGenKit/Sources/UGenKit/Resources/models.json`.
- 61 models, no mismatches. By task: detection 27, instance segmentation 7, classification 6, pose 5,
  semantic segmentation 4, CLIP 3, face 2, OCR 2, and one each for depth, stereo depth, oriented
  detection, super-resolution, lane detection and text embedding.
- Two models take two inputs: `stereonet` and `all_minilm_l6_v2`.
- Limitation: a model that is not in this table cannot be used on the iPad until a HEF parser exists
  there.

### Step 34. All 61 models run through this project's client

- Added a generic `run` command to `tools/ugenrt_mac.c` (any number of inputs and outputs, optional
  float32 output request) and `tools/test_all_models.py` to loop over the model table with a grey frame.
- `python3 tools/test_all_models.py native`: **61/61 ran** with the HEF's own output types.
- `python3 tools/test_all_models.py float`: **61/61 ran** with tensor outputs requested as float32 (the
  device converts). Results in `logs/all-models-native.json` and `logs/all-models-float.json`.
- Float output is slower for models with many outputs, up to 2.2x (for example yolov8n_seg 27.4 ms to
  59.2 ms, yolov8s_pose 23.9 ms to 36.7 ms), because the stick converts and sends four times the bytes.
- Decision: use the native types and convert on the iPad with the scale and zero point from step 33
  (`value = (raw - zeroPoint) * scale`).
- Sample sequential timings from the native run (Mac, hub, one frame at a time): yolov8n 16.2 ms,
  yolov8s 20.4 ms, yolov8m 29.6 ms, yolov8x 63.8 ms, yolov11x 59.1 ms, fastvit_sa12 6.2 ms, scdepthv3
  9.2 ms, yolov8m_pose 30.2 ms, yolov8m_seg 38.8 ms, real_esrgan_x2 423 ms.
- This proves the protocol handles every model. It does not yet prove the outputs are decoded
  correctly: post-processing for each task still has to be written and checked.

### Step 35. Pipelined inference closes the gap to Hailo's client

- Split the C client's request/reply into `ugen_infer_submit` (send request and input frames) and
  `ugen_infer_collect` (wait for the oldest reply and its outputs). Replies arrive in request order.
- `./tools/ugenrt bench <hef> <input> <output_size> <frames-in-flight> <frames>` on the Mac:

| Model | 1 in flight | 2 in flight | 4 in flight | Hailo's `run2` |
|---|---|---|---|---|
| yolov8m | 33.6 FPS | 59.1 FPS | 59.1 FPS | 59.0 FPS |
| yolov8s | 48.9 FPS | | 127.5 FPS | not measured |
| yolov8n | 61.7 FPS | | 197.8 FPS | not measured |

- Two frames in flight is enough to match Hailo's tool on yolov8m; more does not help.
- Also added `ugen_device_current_limit` (reads what the USB-C source advertises; 1500 mA on the Mac
  through the hub).

### Step 36. UGenKit becomes generic and testable on the Mac

- `ugen_mac_transport.c`: implements the same driver API as the iPad transport, directly over IOKit, so
  `UGenDevice` runs unchanged on macOS with the stick plugged into the Mac. The iPad file is now
  compiled for iOS only.
- `ModelInfo.swift`: `ModelCatalog` (the 61-model table from step 33, bundled as a resource), `Labels`
  (COCO, ImageNet, Cityscapes, DOTA; extracted from hailo-apps by `tools/build_labels.py`), and `Tensor`
  with `floats()` for de-quantization.
- `UGenDevice`: `loadModel(hef:info:)`, `infer(inputs:)`, and pipelined `submit(inputs:)` / `collect()`.
- `ImagePrep.swift`: letterbox (grey padding, aspect ratio kept) or stretch, and mapping results back to
  the source image. Detection and pose now use letterbox, which is what YOLO models expect.
- `PostProcess.swift` decoders, each written from the model's output layout:
  - detection: the device's NMS-by-class buffer;
  - classification: softmax unless the output already sums to 1 (some models output probabilities);
  - depth (scdepthv3): `1 / (sigmoid(x) * 10 + 0.009)`, the formula in hailo-apps' C++ app;
  - semantic segmentation: the device already returns one class index per pixel;
  - pose (yolov8-pose): 9 outputs, three per stride; boxes as 4 x 16 distribution bins, one person score,
    17 keypoints x (x, y, confidence); then NMS on the host.
- `VisionRenderer.swift`: draws boxes, skeletons, class lists, a depth colour map, and a segmentation
  overlay with CoreGraphics and CoreText, so it works on both platforms.
- `Sources/ugen/main.swift`: Mac command-line tool. `swift build -c release`, then for example
  `.build/release/ugen pose yolov8m_pose ../testdata/bus.jpg out.png`.

Problems found while testing:

- **Swift exclusivity crash** in `collect()`: a nested function read the output array's count while the
  array was being mutated ("Simultaneous accesses ... modification requires exclusive access").
  Fix: allocate raw buffers for the C call and copy them into arrays afterwards.
- **First connection after a crashed client fails once**: after a client is killed mid-transfer, the
  next client's first request fails with `0xe0004051` and the attempt after that works. Sending CLOSE
  before CONNECT did not help. Fix: `UGenDevice` probes a new session with a harmless call and, on a
  USB error, reopens the device and tries once more. Verified on the Mac by killing a running
  benchmark with `pkill -9` and connecting again. Not yet verified on the iPad, where reopening goes
  through the driver.

Results on `testdata/bus.jpg` (810x1080), Mac, one frame at a time; rendered images saved in `logs/`:

| Task | Model | Result | Inference |
|---|---|---|---|
| Detection | yolov8m | bus 0.94, persons 0.94, 0.91, 0.91, 0.75 | 31.2 ms |
| Pose | yolov8m_pose | 4 people with correct skeletons | 31.6 ms |
| Classification | fastvit_sa12 | minibus 90.8% | 7.4 ms |
| Classification | resnet_v1_50 | minibus 46.3%, police van 39.6% | not recorded |
| Depth | scdepthv3 | plausible map: people near, building far | 10.8 ms |
| Semantic segmentation | fcn8_resnet_v1_18 | road, people, bus and trees coloured plausibly | 82.9 ms |

- The images were checked by eye, not against a reference implementation.
- Models in the table whose outputs UGenKit cannot decode yet: instance segmentation (7), yolo26
  detection and pose (6), oriented boxes, super-resolution, OCR (2), lane detection, face (2), CLIP (3),
  stereo depth, text embedding, and the two SSD detectors' label set.

### Step 37. First version of Hailo Studio for the iPad

- The app (still the `UGenProbe` Xcode project, display name "Hailo Studio") was rewritten around UGenKit:
  - `App/StudioModel.swift`: shared state. Connects, boots the stick from the bundled runtime image when it
    is in loader mode, downloads models from Hailo's servers into the app's Documents/models folder on
    first use (size checked against the catalog), and loads them.
  - `App/VisionView.swift` ("Photos"): task and model pickers, photo picker or bundled sample, Run; shows
    the rendered result, a text summary, and prepare/inference/decode times.
  - `App/LiveView.swift` + `App/CameraSource.swift` ("Live camera"): back camera at 1280x720, newest frame
    only, two frames in flight on the stick, boxes and skeletons drawn with a SwiftUI Canvas, depth and
    segmentation shown as an overlay image, FPS readout.
  - `App/DeviceView.swift` ("Device and models"): firmware, chip, temperature, the current the USB-C port
    offers, the loaded model, and all 61 models grouped by task with download and delete buttons.
    Models UGenKit cannot decode yet are marked "not decoded yet".
- The app no longer bundles a model; it bundles only the runtime image and the sample photo.
- Built in Release configuration for the iPad, because the Swift decoders are much slower in Debug.
- iPadOS upgrade: the owner updated the iPad from 27.0.1 to **27.2.1** during this step. The app installed
  and launched on 27.2.1 from Xcode 27.2 without changes. Whether the driver still attaches after the
  upgrade is not verified yet, because the stick was on the Mac.
- Layout problem found by screenshot: in portrait the task picker wrapped its label one syllable per
  line. Fix: `.fixedSize()` on the pickers and moving the action buttons into the navigation bar.
- State at the end of this step: the app launches and shows the sample photo; it reports "Driver not
  found" as expected with the stick on the Mac. Nothing in this version has run against the stick on
  the iPad yet.

### Step 38. Live sources, recording, and sturdier downloads

Owner's requests after trying the first version: front camera, recording of the live view, stream
addresses (as in Hailo Studio), and everything in the "not done yet" list.

- `App/CameraSource.swift`: a `FrameSource` protocol (start, stop, newest frame, failure text) and
  `CameraSource(position:)` for the back or front camera.
- `App/StreamSource.swift`: network streams and video files. The kind is chosen from the server's
  answer to one request:
  - `multipart/x-mixed-replace` -> MJPEG: JPEG frames (FF D8 ... FF D9) are cut out of the byte stream;
  - `image/*` -> a still image that the camera replaces: fetched again every second;
  - anything else -> AVPlayer with an `AVPlayerItemVideoOutput` (HLS `.m3u8`, video addresses, files).
  - `rtsp://` is refused with an explanation: iPadOS has no built-in RTSP player, and supporting it
    would mean bundling a third-party library.
- `App/Recorder.swift`: H.264 `.mp4` through `AVAssetWriter` into Documents/recordings. Each recorded
  frame is the camera picture with the result drawn in by `VisionRenderer`, time-stamped with the time
  since recording started.
- `App/LiveView.swift`: source menu (back camera, front camera, stream address, video file), address
  field with a recent list, video picker, Record toggle, and a Recordings sheet with share,
  save-to-Photos and delete.
- `Info.plist`: `NSPhotoLibraryAddUsageDescription`, and `NSAllowsArbitraryLoads` because many public
  traffic cameras are served over plain http.
- Downloads: the first version read the response one byte at a time and failed once on the iPad with
  `NSURLErrorDomain -1005` ("The network connection was lost"). Now `URLSession.download` with a progress
  delegate, the size checked against the catalog, and up to three attempts.
- None of the live sources or recording had run on the iPad at the end of this step.

### Step 39. Reconnecting after the app is killed: the hard one

Symptom: after installing a new build (which kills the running app), the next launch sat at
"Connecting…" and then failed with USB timeouts.

What was tried, in order, and what each showed:

1. **Reset in the driver.** Added a `RESET` selector that drops the pipes, calls `SetConfiguration(1)`
   again and reopens the interface, mirroring what the Mac transport does when it reopens the device.
   Result: `0xe00002c7` (unsupported). `devicectl device info processes` showed the driver's process ID
   unchanged across installs. **Finding: iPadOS keeps the running driver until the stick is unplugged.
   Installing the app does not replace a driver that is attached.** (Step 19's "a new build re-matches an
   attached stick" only applied because no driver was running then.)
2. After a replug, the first launch failed with `runtime upload: USB transfer failed (0xe00002eb)`
   (aborted). Cause: two connection attempts at once, one from the app's start-up task and one from the
   auto-run photo test. Fix: `StudioModel.connect()` now shares one in-flight attempt.
3. With that fixed, a kill-and-relaunch reached "Ready" once, but after the next install the probe timed
   out after 60 s (`0xe00002d6`). Added a per-transfer timeout argument to the driver's bulk calls
   (`ugen_driver_set_bulk_timeout`) so the probe waits 2 s, not 60 s, and retried six times with a reset
   before each. Result: still failing, just faster. So resetting the configuration does not free the
   session.
4. **Root cause, from the HailoRT source:** v5.5.0 added `session_group_id` to the CONNECT request,
   documented as "used by the device to group and clean up stale interfaces from a dead client". The
   5.3.0 runtime on this stick has no such cleanup: an interface whose client died stays unusable until
   the stick restarts. Hailo Studio's own README lists the same symptom with the fix "unplug it, wait 3 s".

Fix that worked:

- The runtime exposes five interfaces. The driver's `RESET` now takes an interface number, and
  `UGenDevice` tries interfaces 0 to 4 in turn with a 2-second probe.
- If interface 0 answers, it is used. If only a later one answers, earlier ones are stuck, so the client
  sends `SYSTEM__RESET` (RPC action 39, which runs `reboot` on the stick) and throws
  `UGenError.restarting`. The app waits for the stick to come back in loader mode, uploads the runtime
  again, and continues. If no interface answers, it asks for a replug.
- The app also closes its session properly when it goes to the background, so ordinary use does not
  leave sessions behind.

Verification on the iPad (iPadOS 27.2.1, new driver loaded by a replug):

- Clean start with the auto-run photo test: yolov8m found the bus (0.93) and four people; prepare
  22.9 ms, inference 31.9 ms. Screenshot: `logs/studio-photos-ipad.png`.
- Kill and relaunch with `devicectl device process launch --terminate-existing`: 6 seconds later the app
  was loading the model again, and by 28 seconds it showed "Ready" with the same detections. The
  driver's process ID had changed, which confirms the stick rebooted and re-attached by itself.

Lessons for anyone continuing this:

- A driver change needs a replug to take effect; an app-only change does not.
- When testing from the Mac, every `--terminate-existing` launch leaves a dead session, so the app's
  first seconds after such a launch include a stick reboot (about 10 s).

### Step 40. Library videos appeared rotated 90 degrees counter-clockwise

- Reported by the owner after trying a video from the photo library in the Live view.
- Cause: a video file stores its frames in the camera sensor's orientation together with a rotation to
  apply when showing it (the track's `preferredTransform`). `AVPlayerItemVideoOutput` hands out the raw
  frames and ignores that rotation, so portrait videos came out sideways.
- Fix in `App/StreamSource.swift`: read the video track's `preferredTransform` when the player starts,
  convert its angle to an image orientation (90 -> `.right`, 180 -> `.down`, 270 -> `.left`), and apply it
  to each frame with Core Image before the frame is used. Frames that need no rotation take the old path.
- Built and installed. Not yet confirmed by the owner.

### Step 41. Built-in list of public highway cameras

Owner's request: keep the paste field, and add a predefined list of 50 or more highway streams to pick from.

How the sources were found (all probed with `curl` from the Mac):

- Keyed APIs do not work without registration: `https://<road-camera-site>` and Alberta's
  equivalent return `Invalid Key`.
- The same 511 sites expose a keyless list their own web pages use:
  `https://<host>/List/GetData/Cameras?query=<DataTables JSON>&lang=en`. It returns each camera's
  roadway, location, still-image path (`/map/Cctv/<id>`) and, for some agencies, a `videoUrl`.
- Scanned 19 sites on that platform for open video (`tools` scratch script, results in this session):
  - **Open HLS video:** Nevada (`<road-camera-site>`, 649 cameras) and Louisiana (`<road-camera-site>`, 336).
  - **Still images only:** Ontario (936), Alberta (351), Manitoba (46), Saskatchewan (56), Nova Scotia
    (57), New Brunswick (57), Newfoundland and Labrador (48), plus Arizona, Idaho, Alaska, Pennsylvania
    and New England.
  - **Blocked or different format:** Georgia and Florida (HTTP 500), Utah, Wisconsin and New Jersey (403),
    Quebec (Cloudflare 403), New York, Virginia and Kansas (not JSON).
- <road-camera-site>: `https://<road-camera-site>` lists 1,042 British Columbia cameras; the image is
  `https://<road-camera-site>`.
- Caltrans' JSON feeds (`cwwp2.dot.ca.gov`) timed out from here and were left out.
- So the Canadian cameras the owner mentioned are refreshing still pictures, not video. Live video in the
  list comes from the two US states.

What was built:

- `tools/build_streams.py` gathers candidates from those catalogues, prefers named highways, and fetches
  every address before keeping it: an HLS playlist must start with `#EXTM3U`, an image must come back as
  `image/*`. Output: `UGenProbe/App/streams.json`, bundled in the app.
- Result of the run: **124 cameras, 44 live video (Nevada 24, Louisiana 20) and 80 refreshing images**
  (Ontario 24, British Columbia 16, Alberta 14, Manitoba 6, Saskatchewan 6, Nova Scotia 5, New Brunswick
  5, Newfoundland and Labrador 4).
- `App/StreamCatalog.swift`: the built-in list; "Fetch the full lists from the web", which reads the same
  catalogues on the iPad (several thousand cameras, not checked one by one) and saves them; and
  `CameraListView`, a searchable sheet grouped by region with a "Live video only" switch.
- `App/LiveView.swift`: a "Road cameras" button next to the address field; choosing a camera fills the
  field. Pasting an address still works.
- Still-image cameras are now fetched every 3 seconds instead of every second.
- Test hook: launching with `-stream <address>` opens Live and starts that stream, so a live run can be
  started and screenshotted from the Mac.

Verification on the iPad:

- `devicectl device process launch ... -- io.ugenkit.UGenProbe -stream <Nevada HLS address>`
  ("Gibson Rd & South I-215 WB Ramp"): the stream played, yolov8s drew boxes on cars and trucks, and the
  readout showed **29.9 FPS**, which is the stream's own frame rate. Screenshot:
  `logs/studio-live-highway-stream.png`.
- This is also the first confirmed run of the stream source and of the live loop on the iPad.
- Not tested: the Louisiana streams, the still-image cameras, the in-app "fetch full lists", MJPEG
  addresses, the front camera, and recording.

### Step 42. The remaining decoders, developed against captured output

Owner asked for everything in the "not done" list, and reported that some pose models did not work.

- Pose report: `yolov8s_pose` and `yolov8m_pose` both find 4 people on the Mac, and `yolov8m_pose` was
  seen working on the iPad. The models that could not work were the three YOLO26 pose models, which had no
  decoder; they are covered below.
- Method: with the stick on the Mac, the raw outputs of each undecoded model were saved once
  (`ugen capture <task> <model> <image> <folder>`, 20 captures in `testdata/captures/`), using hailo-apps'
  sample images (`testdata/samples/`, downloaded from
  `https://hailo-csdata.s3.eu-west-2.amazonaws.com/resources/images/<name>`). Decoders were then written
  and checked offline with `ugen replay <task> <folder> <image> out.png`, which needs no stick.
- Scaffolding added first so the work could be split: new `VisionTask` cases and result types
  (`Instance`, `OrientedDetection`, `Lane`, `Face`, `TextRegion`, `OutputImage`), one stub file per decoder
  and per drawing routine, `CapturedRun` (save/load), and a test target.
- Five helper agents then worked in parallel, each on its own files and its own build folder
  (`swift build --scratch-path .build-<name>`), with instructions to check the rendered pictures by eye
  and to report what they could not verify. A sixth did CLIP with exclusive use of the stick.

Results (helper reports, plus spot checks of the renders by the main session):

| Decoder | Models | Result on the captures |
|---|---|---|
| Instance segmentation | yolov8 n/s/m-seg, yolov5 n/s/m/l-seg | All 9 captures correct: masks on the right objects (`logs/instance-seg.png`). yolov5 anchors from hailo-apps' `instance_segmentation/config.json`. Decode under 1 ms. |
| YOLO26 detection | yolo26 n/s/m | Correct on the bus photo (bus and four people). |
| YOLO26 pose | yolo26 n/s/m-pose | n finds 4 people; s and m find 3 (the cut-off person scores 0.06 to 0.09 in the raw output, so this is the model, not the decoder). |
| Oriented boxes | yolo11s_obb | 39 vehicles found, right size and class, but boxes are tilted about 7 to 10 degrees from the trucks. Not resolved (see below). |
| Lanes | ufld_v2_tu | Correct after a fix (see below). |
| Faces | scrfd_10g | 2 faces on the bus photo, landmarks on eyes, nose and mouth. |
| Text regions | ocr_det | 10 regions on one sample, 6 on the other (one of them a barcode). |
| Tracker | none | ByteTrack-style, Hungarian assignment; 18 unit tests pass. Not yet seen on real video. |

- The YOLO26 formulas are not in hailo-apps (it runs a separate ONNX file that is not in the repo), so
  they were fitted to the captures: boxes are four distances in grid cells from the cell centre, scores
  are logits, keypoints are `(column + 0.5 + dx) * stride`.

Two problems found in the helpers' output and handled in the main session:

- **Lanes wobbled near the horizon.** The helper fed the model the whole frame. hailo-apps resizes the
  frame to 800x400 and keeps the lower 320 rows, so the model expects the bottom 80% of the picture.
  Fix: `ImagePrep.prepare` gained a `region` argument, `VisionTask.sourceRegion` gives the lane task
  `(0, 0.2, 1, 0.8)`, and the lane decoder returns fractions of the whole frame as the reference does.
  Re-run on the stick: three smooth lines lying on the markings (`logs/lanes.png`).
- **Oriented boxes are tilted.** The decode matches the reference formula
  (`angle = (sigmoid(x) - 0.25) * pi`) and the reference also letterboxes with grey 114. Hailo's example
  picture uses a different photo, so there is nothing to compare against. Left as a known inaccuracy.

### Step 43. Pieces that need the stick live

- **Label sets** (`Labels.detection(for:)`): the SSD detectors use COCO's 90 paper ids, the 4-class
  detector uses person, vehicle, face, license plate, and the VisDrone detector its 11 classes. The last
  two lists come from hailo-apps' `hailo_4_classes.json` and `visdrone.json` at
  `.../resources/configs/<name>`. On the bus photo: ssd_mobilenet_v1 gives bus 0.98 and persons;
  the 4-class model gives persons, faces and a vehicle.
- **Super-resolution** (`SuperResolution.swift`): real_esrgan_x2 only takes 512x512, so a photo is cut into
  overlapping tiles (16-pixel margin), each upscaled, and the centres stitched. 512x256 sample -> 1024x512
  in 0.87 s (2 tiles). Longest side limited to 2048 pixels.
- **Several models at once** (`UGenDevice.addModel`, `infer(inputs:model:)`): the stick's scheduler switches
  between loaded models, which two-stage tasks need.
- **Reading text** (`TextReader`): ocr_det finds regions, each is cut out upright (`ImagePrep.crop`), padded
  to 320x48 with grey 128 as in the reference, and read by `ocr` with CTC decoding. Sample 1: "GTIN:",
  "00366582505839", "SN:", "102259613742", "LOT", "MFG", "18FEB2022" and others in 149 ms. Sample 2:
  "SolifenacinSuccinate", "10mg", with small errors ("Urilaxo", "Otabuk"). This was also the first run of
  the recognition decoder, which the helper could not test.
- **Face matching** (`FaceRecognition`, `FaceGallery`): each face is aligned to ArcFace's five-point
  template with a least-squares similarity transform, embedded by arcface_mobilefacenet, and compared by
  cosine similarity. Same man in the full photo and in a crop: 0.81 and 0.88. Different people: -0.21 to
  0.02. Match threshold set to 0.4.
- **CLIP tagging** (`CLIP.swift`, `CLIPTagger`): a Swift port of CLIP's BPE tokenizer (13 cases checked
  against the HuggingFace library), the 101 MB token table memory-mapped, text encoder then projection,
  image encoder, softmax over 100 x cosine. On the stick: bus photo -> "bus" 0.996, apple -> 0.999, room ->
  "living room" 0.978, dog and bicycle photo -> "bicycle" 0.919. Text encoder 27 to 30 ms per prompt, image
  encoder 17 to 19 ms. Data files: `.../resources/configs/clip_tokenizer.json`,
  `.../resources/npy/token_embedding_lut.npy`, `.../resources/npy/text_projection.npy`.
- **Tiling** (`Tiling.swift`): the whole picture plus an overlapping grid of tiles in flight together, boxes
  mapped back and merged. Runs (3x3 on an aerial photo in 178 ms) but its benefit has not been judged on a
  suitable scene.
- Regression after these changes: yolov8m still gives the same detections and 59.1 FPS pipelined;
  `swift test`: 28 tests, 0 failures, 1 skipped (the CLIP test that needs the stick is opt-in with
  `UGEN_DEVICE_TESTS=1`).

### Step 44. The new tasks in the app

- Task menu now also offers: instance segmentation, oriented boxes, super-resolution, lane detection, face
  detection (with names), read text, and tagging from text.
- `StudioModel.prepare(_:task:)` downloads and loads a task's companion model as well. Multi-step tasks go
  through `runPipeline`; in Live they handle one frame at a time instead of two in flight.
- Options: a Tiles menu for detection (whole picture, 2x2, 3x3); a prompt field for tagging; "Remember this
  face" with a name field for face detection, stored in Documents/faces.json; a Track toggle in Live that
  adds a number to each detection; a Share button for the result picture in Photos.
- CLIP's word tables (about 105 MB) download on first use of tagging.
- Built in Release and installed on the iPad. **None of the new tasks has run on the iPad yet**; all
  checks above were on the Mac.

Still not done: tracking for pose and segmentation, multi-camera, re-identification, stereo depth, RTSP,
and chat / image questions / speech (GenAI).

### Step 45. Items that needed the Mac, and their app-side counterparts

Owner asked which remaining items need the stick on the Mac, then asked for those to be done first.

- **Stereo depth** (`StereoDepth` in `Pipelines.swift`): stereonet takes two pictures. Its inputs are listed
  right view first (`input_layer2`), then left (`input_layer1`). Tested with `ugen stereo left.jpg right.jpg`
  on hailo-apps' sample pair (`vendor/hailo-apps/hailo_apps/cpp/depth_estimation_stereo/`): 105 ms, a
  plausible street-scene map. Values are relative (largest disparity minus disparity), not metres. In the
  app it is a Photos task with a second picker for the right view.
- **Which services the stick runs:** `tools/ugenrt ports` tries the CONNECT handshake on interface 1 for each
  port. Accepted: 12133 (vision), 12145 (LLM), 12147 (VLM), 12149 (speech to text). An unused port (12345)
  is refused with status 89. So the GenAI servers are part of the 5.3.0 runtime image.
- **GenAI protocol, from the source:** each buffer is an 8-byte size followed by the bytes; a request is one
  or more buffers and the reply is one. The client uploads the HEF itself as the second buffer of the
  create request, so the model files are needed on the host.
- **GenAI model files are behind a browser check.** Every command-line request to
  `https://dev-public.hailo.ai/<version>/blob/<name>.hef` returns HTTP 403 with
  `cf-mitigated: challenge` and a "Just a moment..." page, whatever client name is sent (curl, wget,
  python-requests, Chrome, Firefox were tried). No mirror exists on Hailo's S3 buckets (11 guesses, all
  403). This was not worked around. The owner downloaded the files in Firefox into `models/`:
  Whisper-Base.hef (130,206,034 bytes) first, the Qwen and Llama files after it.
- C core: `ugen_session_open_port` (any service port), `ugen_session_write` / `ugen_session_read` (raw
  bytes on an open session).
- A helper agent is implementing the speech, chat and image-question clients with the stick; results in
  the next step.

App-side work done in the meantime (no stick needed to write it):

- **Tracking for poses and masks:** `ObjectTracker.track(_:)` numbers detections, masks and poses in one
  place. Items the tracker has not confirmed yet are still shown, without a number (the first version
  hid them).
- **Two sources at once** (Studio's "Multi-camera"): a "Second source" switch and address field in Live.
  Both sources go through the one loaded model, taking turns for the two in-flight slots, each with its
  own tracker, shown side by side. Recording joins the two pictures into one video. The second source is
  a stream address; two built-in cameras at once is not supported.
- **Re-identification:** with face detection, "Number unknown people" remembers each unnamed face for the
  run as "Person N", so the same person keeps the label across frames and across both sources. It uses
  the same face matching that was checked in step 43.
- **RTSP** (`RTSPClient.swift`, written by a helper agent, no third-party code): RTSP 1.0 over TCP with
  Network.framework, Basic and Digest login, H.264 depacketization (single NAL, STAP-A, FU-A), decoding
  with VideoToolbox. Tests: 24 pass, including an in-process RTSP server that streams a clip encoded on
  the fly, with and without login, and a thread-sanitizer run. One public stream worked
  (`rtsp://stream.strba.sk:1935/strba/VYHLAD_JAZERO.stream`, 1280x720). Not supported: UDP transport,
  H.265, audio, redirects. Not tested: real IP cameras, `rtsps://`. The app's stream source now uses it
  for `rtsp://` addresses instead of refusing them.
- Launch arguments for testing from the Mac: `-stream <address> [-stream2 <address>] [-task <task> <model>]`.
- The app builds with all of this. None of it has run on the iPad yet.

### Demos repository

The owner pointed at `github.com/erp0917-stack/ugen300-demos` (24 demos, cloned to
`vendor/ref-ugen300-demos`). Assessment:

- Buildable on what exists: real-time detection, HeadCount, TrafficCount, Missing Check, the pose demos
  (raise hand, hand counter, yoga coach, squat alarm, air instrument), FaceCheckIn, Classroom, PlateGate,
  EdgeVsCloud.
- Need models not yet brought in (from the v5.4.0 zoo, to be checked on the 5.3.0 runtime):
  hand_landmark_lite (GestureCaption, FruitNinja, AirBand), zero_dce and dncnn_color_blind (PhotoRestore).
- Need the GenAI models: Ask About Image, Outfit Advisor, Fridge Chef, Calories, OfflineChat, OfflineCode,
  Face Report, Meeting Notes.
- Its README links the GenAI models at `dev-public.hailo.ai/v5.2.0/blob/...` and says they work on the 5.3
  runtime.

### Step 46. Getting the language and speech models onto the iPad

- All six files finished downloading in Firefox on the Mac, each with a valid HEF header:
  Whisper-Base 130 MB, Llama3.2-1B-Instruct 1.40 GB, Qwen2.5-Coder-1.5B-Instruct 1.68 GB,
  Qwen2.5-1.5B-Instruct 2.46 GB, Qwen3-1.7B-Instruct 2.88 GB, Qwen2-VL-2B-Instruct 3.26 GB.
- Copied to the app on the iPad over Wi-Fi with
  `xcrun devicectl device copy to --device <UDID> --domain-type appDataContainer
  --domain-identifier io.ugenkit.UGenProbe --source models/<name>.hef --destination Documents/models/<name>.hef`.
  Times: 3 s for Whisper, 32 to 69 s for the others, about 4 minutes for all 11.8 GB (roughly 50 MB/s).
- Device page: a "Chat, image questions and speech" section lists the six files and whether each is on
  the iPad.
- Owner asked to be able to download them on the iPad from the dev-public addresses. A plain `URLSession`
  download would get the same Cloudflare page as `curl`, so `App/WebDownload.swift` opens the address in a
  `WKWebView` (a real browser engine, with the owner present to answer the check if it asks) and turns the
  response into a `WKDownload` saved into Documents/models. Built and installed; not yet tried.
- `LSSupportsOpeningDocumentsInPlace` was added so the Files app shows the app's folder for manual copies.
- The install was held back until the copy had finished, so that replacing the app could not interrupt it.
  The files were still present after the install.

### Step 47. REST API served from the iPad

Owner asked whether REST APIs can run on the iPad and would not take "no" without an attempt.

- Answer: yes. An app can open a listening TCP socket with Network.framework and speak HTTP itself.
- `UGenKit/Sources/UGenKit/HTTPServer.swift`: a small HTTP/1.1 server (`NWListener`, one request per
  connection, bodies by Content-Length up to 64 MB, JSON helpers, CORS header), plus
  `VisionResult.jsonObject` (boxes and points normalized to the picture).
- `UGenProbe/App/APIServer.swift` (an extension of `StudioModel`), port 8080:
  - `GET /v1` lists endpoints and tasks.
  - `GET /v1/status`: stick state, firmware, temperature, USB current, loaded model, busy flag.
  - `GET /v1/models`: the 61 vision models, which tasks each can do, and whether it is on the iPad.
  - `POST /v1/vision/<task>?model=<name>`: the body is an image (JPEG, PNG, HEIC). Returns JSON with the
    result, a text summary and the time taken. Options: `tiles=2|3`, `prompts=a,b,-c` (tagging),
    `render=1` (returns a PNG with the result drawn in).
  - Returns 409 while the live view is using the stick, and a readable 4xx/5xx message otherwise.
- Device page: a "Serve the REST API" switch showing the address and a ready-made `curl` line. Launching
  with `-api` turns it on (for testing from the Mac).
- `Info.plist`: `NSLocalNetworkUsageDescription`.
- Limits, stated in the app: iPadOS suspends apps that are not on screen, so the API answers only while
  Hailo Studio is open (the idle timer is disabled while serving so the iPad stays awake); there is no
  password or TLS.
- Test from the Mac over Wi-Fi, with the app launched by `devicectl ... -- io.ugenkit.UGenProbe -api`:
  - `curl http://<device-name>.local:8080/v1/status` -> JSON (stick "unknown", since the stick was on the Mac).
  - `curl .../v1/models` -> 61 models, all 61 marked as on the iPad.
  - `curl -X POST --data-binary @bus.jpg ".../v1/vision/detection?model=yolov8s"` -> HTTP 500 with
    `{"error": "Driver not found. Plug in the UGen300 ..."}`, which is the correct answer without the stick.
- Not yet tested: an actual inference through the API (needs the stick on the iPad), concurrent requests,
  and large bodies.
- Not built yet: chat and speech endpoints (waiting for the GenAI client).

### Step 48. Speech, chat and image questions

Done by a helper agent with exclusive use of the stick on the Mac, from Hailo's v5.3.0 client and server
source. Files: `UGenKit/Sources/UGenKit/GenAI.swift`, `GenAIProtocol.swift`, tests in
`Tests/UGenKitTests/GenAITests.swift`, and additions to `UGenDevice.swift`.

Wire protocol as implemented:

- Ports: 12145 (LLM), 12147 (VLM), 12149 (speech). Each buffer is an 8-byte little-endian size followed
  by the bytes; a request is one or more buffers and the reply is one.
- A message is a 4-byte action id (the order of `HailoGenAIActionID`, not the .proto field numbers)
  followed by a protobuf message. Replies repeat the id and carry a `hailo_status`.
- Speech: create = request + the whole HEF as a second buffer; generate = request + the audio buffer.
- LLM and VLM create: the request lists the HEF's chunks; each chunk is then sent as bare bytes and the
  server answers each with one byte. HEFs are memory-mapped and sent in pieces of at most 64 MB.
- Generation is a read loop, one token per reply, until `generation_status` is non-zero.
- Chat templates are rendered on the client. Hailo uses the minja library, which is not in the source
  tree, so a small Jinja interpreter was written; it reproduces the prompts for the five model files but
  not minja's tool-calling support.
- One finding on the device: a session that follows another one on the same interface accepts writes
  but never gets replies unless the interface is reset first (`ugen_driver_reset`). `openGenAISession`
  does that.
- A vision session and a GenAI session cannot be open together through this client; opening one closes
  the other, and the stick drops the previous model.

Verified end to end on the stick (Mac, through the hub), 85 tests with 0 failures:

| Model | Size | Load | First token | Rate |
|---|---|---|---|---|
| Whisper-Base | 130 MB | 1.4 s | n/a | 0.2 s per second of audio |
| Llama3.2-1B-Instruct | 1.40 GB | 5.0 s | 0.45 s | 7.9 tokens/s |
| Qwen2.5-Coder-1.5B-Instruct | 1.68 GB | 5.3 s | 0.41 s | 6.9 tokens/s |
| Qwen2.5-1.5B-Instruct | 2.46 GB | 6.1 s | 0.48 s | 5.9 tokens/s |
| Qwen3-1.7B-Instruct | 2.88 GB | 7.2 s | 0.82 s | 3.8 tokens/s |
| Qwen2-VL-2B-Instruct | 3.26 GB | 8.4 s | 1.31 s | 5.8 tokens/s |

- Speech: a sentence spoken by macOS `say` ("The quick brown fox jumps over the lazy dog.") came back
  word for word in 0.56 s. Audio must be mono, 16 kHz, 32-bit float.
- Chat: "What is the capital of France?" -> "The capital of France is Paris."; the follow-up "And of
  Italy?" alone -> "The capital of Italy is Rome.", so the stick keeps the conversation. Clear-context
  resets it. Stopping mid-answer works.
- Image question on the bus photo: "The picture shows a person standing next to a bus. The bus has a blue
  color scheme and is labeled with text in Spanish…". The image is stretched to 336x336.
- Rates are from one 64-token generation per model.
- Not verified: iPadOS (everything ran through the Mac transport), memory use while uploading multi-GB
  files, files over 4 GB, a client killed mid-generation.

App:

- `App/LanguageModels.swift`: loads one language model at a time, drops them when a vision model is
  loaded, and `AudioLoader` converts any audio file to 16 kHz mono float.
- `App/ChatView.swift`: model menu, instructions field, temperature and token limit, streamed answer,
  Stop, New chat, tokens-per-second readout. After a reload it replays the earlier turns so the model sees
  the whole conversation.
- `App/AskImageView.swift`: photo or sample, question with a menu of ideas (including the demos'
  calorie, recipe and outfit prompts), streamed answer.
- `App/SpeechView.swift`: record with the microphone or open an audio file, optional translation and
  language code, segments with times, share the text. `NSMicrophoneUsageDescription` added.
- REST API additions: `POST /v1/chat/completions` (OpenAI-style request and response, not streamed),
  `POST /v1/audio/transcriptions` (raw audio body or OpenAI-style multipart), `POST /v1/vision/ask`.
- Built in Release and installed. **None of the three tabs or the new endpoints has run on the iPad.**
- After the GenAI changes, vision still works (`ugen detection yolov8m`: same five detections).

### Step 49. Interface redesign and app icon

Owner's feedback: the interface was poor; Ask an image should offer the sample pictures to choose from
as well as the owner's own; Chat should look more serious; and the app needed an icon, "a chip with h.".

- **Icon:** `tools/make_icon.swift` draws it with CoreGraphics (a dark chip with pins, a white "h" and a
  teal full stop on a navy-to-teal background) and writes
  `UGenProbe/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png`. It is original artwork, not Hailo's
  or ASUS's logo. `LogoMark` in `ContentView.swift` is the same mark as a SwiftUI view, used in the sidebar
  and in chat. An accent colour (teal) was added to the asset catalogue.
- **Samples:** 12 pictures in `UGenProbe/Samples/`, bundled as resources: the hailo-apps samples (bus, dog
  and bicycle, apple, room, two OCR pictures, aerial view, small photo for upscaling, a highway frame from
  the lane video, the stereo pair) and the licence-plate sample from the demos repository. The demos
  repository contains no other pictures.
- `App/Components.swift`: `PictureChooser` (a strip with "Your photos", "Take photo" and the samples,
  the ones that suit the current task first), `Panel`, `Chip`, `ScoreRow`, `ResultList` (a readable list
  for every result type), `FormattedText` (Markdown paragraphs and fenced code blocks with a copy button),
  and a camera capture wrapper.
- **Photos:** picture on the left, a side panel with the result list and timing chips, the chooser strip
  along the bottom, "Show original" toggle, share button. Changing task switches to a sample that suits it.
- **Ask an image:** picture on the left, a question-and-answer thread on the right with one-tap prompts
  (describe, read text, count, calories, recipe ideas, outfit advice, safety check), streamed answers with
  time and speed. Follow-up questions about the same picture keep their context on the stick; choosing
  another picture starts over.
- **Chat:** a centred message column with sender labels, formatted answers, speed and copy on each answer;
  a rounded composer with send and stop; suggested first messages; a settings popover (instructions,
  temperature, token limit); a memory-used chip; and saved conversations (Documents/chats.json) with a
  History menu. Reopening a saved chat replays it to the model on the next message.
- **Sidebar:** grouped into Vision, Language and System, with the mark at the top and a status card at the
  bottom (stick state, temperature, loaded model, REST API state).
- Launch argument `-section photos|live|chat|ask|speech|device` opens a given screen, so layouts can be
  checked by screenshot from the Mac. Screenshots: `logs/ui-photos.png`, `logs/ui-chat.png`,
  `logs/ui-ask.png`.
- Checked by screenshot on the iPad: the three screens lay out as intended in landscape. Not checked:
  portrait, the Live and Device screens (not restyled in this step), dark mode, and any of it with the
  stick attached.

### Step 50. Whisper hung at "Loading" on the iPad: the driver's reset was too weak

- Symptom (owner's report, confirmed by screenshot): Speech to text sat at "Loading Whisper-Base" for
  minutes. Stick running, no crash logs, driver process alive.
- Reasoning: on the Mac, a GenAI session that follows a vision session on the same interface gets no
  replies unless the device is reopened first (step 48). The Mac's reopen calls `SetConfiguration(1)` and
  `ClearPipeStallBothEnds` on every pipe. The iPad driver's `RESET` only called `SetConfiguration(1)`
  again and made new pipes, without clearing them; asking for the configuration that is already selected
  may also not reach the device. This also fits step 39, where the iPad's reset could not free a stale
  session although the Mac's reopen could.
- Fix in `Driver/UGenDriver.cpp`:
  - `Reset` now calls `SetConfiguration(0)` before `SetConfiguration(1)`, so the device sees its
    configuration change.
  - Every pipe gets `ClearStall(true)` when it is first opened, which clears a halt and resets the data
    sequence on both ends.
- Needed a replug to load the new driver (new driver path UUID confirmed in the process list).
- Verification on the iPad:
  - Vision still works with the stronger reset (the Device page showed yolov8s loaded after the owner's use).
  - Added a bundled spoken sample (`Samples/speech_sample.wav`, made with macOS `say`), a "Try the sample"
    button, and a `-autospeech` launch argument. Launched from the Mac with
    `-section speech -autospeech`: the screen showed "Hello from the iPad, the quick brown fox jumps over
    the lazy dog." and "4.1 s of audio transcribed in 0.7 s". Screenshot: `logs/speech-ipad.png`.
  - That launch also killed the previous app instance, so the path "stale session -> recover -> load a
    language model" worked too.
- Which of the two changes fixed it is not known; they were made together.
- Not yet verified on the iPad: the chat models and the image-question model (multi-gigabyte uploads).

### Step 51. Can it run on an iPhone? App installs and runs; driver not yet tested (2026-11-18)

- Question from the user: "can this work on iphone?"
- The paired iPhone (hm17, iPhone 17 Pro Max, iOS 27.2, UDID `<device-id>`) is reachable
  over Wi-Fi with the same `devicectl` commands as the iPad.
- Changed `UGenProbe/project.yml`: `TARGETED_DEVICE_FAMILY` from `"2"` to `"1,2"` (iPhone and iPad).
- Built with `-destination id=<iPhone UDID> -derivedDataPath build-iphone -allowProvisioningUpdates
  -allowProvisioningDeviceRegistration`: BUILD SUCCEEDED. Side effect: this registers the iPhone on the
  developer account (uses one device slot).
- `devicectl device install app` accepted the app with the embedded `SystemExtensions/UGenDriver.dext`.
- Launched with `-section device`; screenshot `logs/iphone-device.png`. The app runs, state "Unknown"
  (no stick attached). `driverkitd` and Apple's own dexts are running on the iPhone, so DriverKit exists
  there, but that does not show that iOS loads a third-party driver. Apple documents third-party
  DriverKit for iPad only.
- Open: plug the stick into the iPhone and check Settings > Apps > Hailo Studio for a "Drivers" row.
- Seen in the screenshot: texts say "this iPad" on the iPhone; the layout is the iPad one squeezed.
- Result (user, same day): with the stick plugged into the iPhone, Settings > Apps > Hailo Studio has
  no "Drivers" row. iOS on iPhone does not offer third-party DriverKit drivers, so the stick cannot be
  used from an iPhone. Answer: iPad only.
- Reverted `TARGETED_DEVICE_FAMILY` to `"2"` (iPad only) and regenerated the Xcode project.
  `build-iphone/` is a leftover build folder inside the project. The app is still installed on the
  iPhone, and the iPhone is still registered on the developer account.

### Step 52. Mac build of the same app (Mac Catalyst), no driver needed (2026-11-18)

- Idea: on macOS the stick can be opened from user space through IOKit (`ugen_mac_transport.c`, already
  used by the `ugen` CLI), so the Mac build needs no driver extension.
- `CUGenRT`: `ugen_mac_transport.c` now compiles for `TARGET_OS_OSX || TARGET_OS_MACCATALYST`,
  `ugen_ios_transport.c` for `TARGET_OS_IOS && !TARGET_OS_MACCATALYST`. The macOS SDK's
  `IOKit/usb/IOUSBLib.h` has no Catalyst restriction, so it builds as is.
- `project.yml`: `SUPPORTS_MACCATALYST: YES`, `DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER: NO`,
  `MACOSX_DEPLOYMENT_TARGET: 14.0`, `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]: App/UGenProbe-Mac.entitlements`.
- Problem: the driver was still copied into the Mac app (`Contents/Library/SystemExtensions`).
  `platformFilter: ios` and `platformFilters: [iOS]` on the dependency had no effect in XcodeGen 2.45.4;
  `platformFilter: iOS` (capital) writes `platformFilter = ios` on the embed build file. Fixed.
- Problem: the first Mac build was not sandboxed, so the app's "Documents" was the real `~/Documents`;
  the self-test downloaded `~/Documents/models/yolov8m.hef` (outside the project). Seen with
  `ls -lt ~/Documents`. Fix: quit the app, moved the file (identical to `models/yolov8m.hef`) to
  `backup/mac-documents-models/`, removed the empty folder, and turned on the App Sandbox
  (`app-sandbox`, `device.usb`, `device.camera`, `device.audio-input`, `network.client`,
  `network.server`, `files.user-selected.read-write`, `personal-information.photos-library`).
  App files now live in `~/Library/Containers/io.ugenkit.UGenProbe/Data/Documents/`.
- Screenshots of a Mac window from the terminal fail ("could not create image from window"; the
  terminal has no Screen Recording permission), so the Mac app was tested through its REST API:
  `open -n <app> --args -api`, then `curl localhost:8080/...`.
- Results (stick on the Mac, sandboxed build):
  - USB access works inside the sandbox; the app found the stale session left by the killed instance,
    reset the stick and re-uploaded the runtime by itself.
  - `POST /v1/vision/detection?model=yolov8m` on `testdata/bus.jpg`: first call 26 s (boot + model
    download + load), then 38.5–40 ms per request (includes JPEG decode and HTTP), 5 objects, bus 0.94,
    same as on the iPad. Output: `testdata/out/mac-app-bus.json`.
  - `POST /v1/vision/pose?model=yolov8m_pose`: works (29 s first call including download).
- Build: `xcodebuild -scheme UGenProbe -configuration Release -destination "platform=macOS,variant=Mac
  Catalyst" -derivedDataPath build-mac -allowProvisioningUpdates build`.

### Step 53. App renamed to "Hailo Studio" (2026-11-18)

- On the Mac the app was `UGenProbe.app` and the menu bar said "UGenProbe" (the iPad home screen
  already used `CFBundleDisplayName` "Hailo Studio").
- `project.yml`: `PRODUCT_NAME: Hailo Studio`, `PRODUCT_MODULE_NAME: HailoStudio` (a module name cannot
  contain a space). The bundle identifiers stay `io.ugenkit.UGenProbe` and `io.ugenkit.UGenProbe.driver`,
  so the installed iPad app keeps its enabled driver and downloaded models, and the Mac container path
  stays `~/Library/Containers/io.ugenkit.UGenProbe/`. The Xcode project and folder are still named
  UGenProbe (internal only).
- Built product paths changed: `build/Build/Products/Release-iphoneos/Hailo Studio.app` (iPad; still
  embeds `SystemExtensions/UGenDriver.dext`) and
  `build-mac/Build/Products/Release-maccatalyst/Hailo Studio.app` (Mac; no driver). Quote the path in
  `devicectl device install app`. `devicectl process launch` still uses `io.ugenkit.UGenProbe`.
- Checked: renamed Mac app boots the stick and detects on `bus.jpg` (38.5 ms per request after loading);
  the iPad build succeeds with the driver embedded. Not yet installed on the iPad.
- Leftover build folders `UGenProbe/build-iphone` (iPhone test) and the earlier `UGenProbe.app` products
  are unused.

### Step 54. Mac: hide the window title (2026-11-18)

- User screenshot: on the Mac the title bar showed "Hailo Studio" above the content column, repeating
  the sidebar's name and looking misplaced.
- `UGenProbeApp.swift`: under `#if targetEnvironment(macCatalyst)`, on appear each `UIWindowScene` gets
  `titlebar.titleVisibility = .hidden`, `titlebar.toolbar = nil`, and a minimum size of 980 x 680 so the
  two-column layout does not get squeezed. iPad unaffected.

### Step 55. Choose a models folder (Mac and iPad); "this Mac" wording (2026-11-18)

- User: "would be nice to point a folder to it". The sandboxed Mac app cannot read the project's
  `models/` (68 files, 12 GB) on its own.
- `StudioModel.swift`: `modelsDirectory` returns the chosen folder if there is one, otherwise the app's
  own `Documents/models`. `useModelsFolder(_:)` stores a bookmark in UserDefaults
  (`modelsFolderBookmark`; `.withSecurityScope` on Mac Catalyst, plain on iPadOS);
  `resolveChosenModelsFolder()` restores it at launch and keeps the security scope open; if the folder is
  gone (moved, external disk unplugged) the app falls back to its own folder. `useDefaultModelsFolder()`
  forgets the choice and leaves the files alone. Downloads go to the chosen folder.
- `DeviceView.swift`: Models section shows the folder path, "Use a models folder…" (`fileImporter` with
  `.folder`) and "Use this app's own folder again". Works on the iPad too (any folder in Files).
- Mac entitlements: added `com.apple.security.files.bookmarks.app-scope` (needed for security-scoped
  bookmarks in a sandboxed app).
- Wording: `StudioModel.deviceKind` is "Mac" or "iPad"; on-screen texts and API errors that said "this
  iPad" now use it.
- Builds: Mac and iPad both succeed. Needs a person to pick the folder (the picker cannot be driven from
  the terminal); check afterwards with `curl localhost:8080/v1/models` (`onDevice` count).

### Step 56. Distribution and GitHub: planned, parked by the user (2026-11-18)

- Mac app needs no restricted entitlement (no DriverKit), so it can be shared ad-hoc signed, or with a
  Developer ID certificate + notarization (not created yet; keychain has only Apple Development and
  Apple Distribution). The iPad app depends on the paid account (profiles, DriverKit approval).
- Before any GitHub push: exclude `images/`, `models/`, `vendor/`, `backup/`, `logs/`, `repo/`, all
  build folders (`UGenProbe/build*`, `UGenKit/.build`; they contain copies of the runtime image) and
  redact personal details from `LOG.md`.
- Planned (not started): stop bundling the runtime image. Do what `repo/hailo_studio/setup.sh` does:
  download ASUS's `UGen300_USB_5.3.0_driver_Linux_amd64.zip` (SHA-256 `b27802b8…a1031`) on first launch,
  extract the image from the `hailort-usb-driver` .deb (zip -> ar -> tar.zst; needs a zstd decoder),
  check it matches `558c1400…2639f`. Then a CI release workflow builds, signs, notarizes and attaches
  the .dmg.
- User: "not a priority right now"; parked.
- Licence decision (user): project code will be MIT; models keep their own licences and are downloaded
  by the user from Hailo, not shipped in the repo or the .dmg. README should list the model licences
  (e.g. Ultralytics YOLO: AGPL-3.0).

### Step 57. Native vision without the stick: Core ML pilot with yolov8m (2026-11-18)

- Goal (user): every vision model the stick supports, plus Whisper, also running natively on macOS,
  iPadOS and iOS without the stick; LLMs via llama.cpp + GGUF. The stick becomes one backend.
- Source models: Hailo Model Zoo v5.3.0 configs, cloned to `vendor/hailo_model_zoo-5.3.0`
  (`hailo_model_zoo/cfg/networks/<model>.yaml`: ONNX zip URL on hailo-model-zoo S3, normalization
  under `parser.normalization_params`, inherited through `base:`). The yolov8m ONNX is the plain
  Ultralytics export: input `images` [1,3,640,640] (0..1), output `output0` [1,84,8400] (xywh in
  pixels + 80 class scores), no NMS. The HEF instead ends in Hailo's NMS.
- Tools: `.venv-convert` (uv, Python 3.12: torch 2.15, coremltools 9.0, onnx 1.23, onnx2torch,
  onnxruntime). `native/tools/convert_onnx.py`: ONNX -> onnx2torch -> wrap with (x-mean)/std -> trace ->
  Core ML ML Program, image input (RGB 0..255), float16, iOS 17 target.
- Error: `NotImplementedError: PyTorch convert function for op 'resolve_conj' not implemented`
  (onnx2torch emits `resolve_conj`/`resolve_neg` no-ops). Fix: register both as identity ops.
- Check (`native/tools/compare.py`, bus.jpg, letterbox 114): top scores match ONNX Runtime within 0.001;
  max box difference 13.5 px on low-score candidates (float16), mean 0.017. Warning seen: torch 2.15
  "not tested with coremltools" (tested up to 2.7); results still match.
- On-device timing: `App/NativeBench.swift`, launch with `-nativebench <name>`; reads
  `Documents/native/<name>.mlpackage` (copied with `devicectl device copy to --domain-type
  appDataContainer`), compiles on device, writes `Documents/nativebench.txt`.
- Bug found: Neural Engine outputs reported "best score 378". Cause: ANE output arrays have padded
  rows; the check assumed contiguous memory. Fixed by indexing with `MLMultiArray.strides`.
- Results, yolov8m on bus.jpg (median of 30):
  - iPad Pro 12.9 M1: Neural Engine 9.8 ms, GPU 47.9 ms, CPU 67.5 ms.
  - iPhone 17 Pro Max: Neural Engine 5.4 ms, GPU 15.9 ms, CPU 48.6 ms.
  - Mac, Core ML ALL: 11.4 ms.
  - For comparison, the stick: 31.5 ms sequential, ~17 ms per frame pipelined.
- iPad install failed once with `kAMDRemoteConnectError` / `0xE8000112` (iPad asleep); worked after the
  user woke it.
- `TARGETED_DEVICE_FAMILY` back to "1,2": the app is useful on iPhone again (native models, no stick).

### Step 58. Native engine in UGenKit, Artelico app, batch conversion started (2026-11-18)

- User decisions: Hailo Studio stays iPad + Mac (iPhone build turned off again); the native app is a
  separate app called **Artelico** (iPhone, iPad, Mac), copied from Hailo Studio.
- UGenKit:
  - `InferenceEngine.swift`: protocol with `loadedModel`, `queueSize`, `infer`, `submit`, `collect`;
    `UGenDevice` conforms unchanged. Pipelines (`VisionPipeline`, `Tiling`, `SuperResolution`,
    `Pipelines.swift`) now take `device: any InferenceEngine`.
  - `CoreMLEngine.swift`: actor that loads `.mlpackage` (compiles once to `.mlmodelc` next to it), feeds
    the stick's RGB frames as BGRA pixel buffers (or dequantized float arrays for non-image inputs),
    returns `Tensor`s in the stick's layout (FLOAT32 NHWC, honoring Neural Engine strides). Optional
    `<name>.native.json` (`NativeModelMap`) maps outputs and adds activations Hailo's scripts put on the
    chip; for detectors whose HEF ends in Hailo's NMS it decodes YOLO candidates, runs class-wise NMS
    and writes the NMS_BY_CLASS layout so `PostProcess.detections` is reused.
- Model sources: `native/tools/zoo_config.py` resolves Model Zoo configs (URL, cut nodes, normalization
  from the `.alls` script). 51 of the app's vision models have a config (`native/zoo-configs.json`);
  14 do not (`native/no-config.txt`: GenAI models, MiniLM, and hailo-apps' own ocr, ocr_det, ufld_v2_tu,
  yolo11s_obb, yolo26*_pose, hailo_yolov8n_4_classes_vga, ssd_mobilenet_v1_visdrone). Three configs
  point to TFLite, not ONNX (resnet_v1_34, resnet_v1_50, ssd_mobilenet_v1).
- `native/tools/convert_all.py`: download -> cut at Hailo's nodes -> convert -> compare with ONNX Runtime,
  report in `native/convert-report.jsonl`. `compare.py` now matches outputs by position (Core ML renames
  numeric output names: `KeyError: '452'` for arcface).
- Done so far: yolov8m, arcface_mobilefacenet (compare to re-run), clip_vit_b_32_image_encoder
  (max diff 0.011, 7.5 ms on the Mac).
- Paused at the user's request ("internet is slow"): killed the batch while downloading
  `clip_vit_b_32_text_encoder` (partial `.part` file left; the script re-downloads files without a
  finished archive). Resume: `.venv-convert/bin/python -I native/tools/convert_all.py [names]`
  (it re-processes models already done unless names are given; report lines are appended).
- Artelico (`Artelico/`): `project.yml` (bundle `io.ugenkit.Artelico`, iPhone + iPad + Mac Catalyst,
  sandboxed Mac entitlements without USB), placeholder "a." chip icon (`Artelico/tools/make_icon.swift`),
  `StudioModel` uses `CoreMLEngine` (property still named `device`), compute-unit picker (Automatic,
  Neural Engine, GPU, CPU), models are `<name>.mlpackage` in the models folder or a chosen folder (no
  hosting yet), REST API vision endpoints only. Chat/Ask/Speech screens moved to `Artelico/Later/`
  until Whisper and llama.cpp run natively. iOS build succeeds; not yet installed or run.
- Next: finish conversions; a stick-vs-Core ML mapping tool (`ugen native-map`) that writes each
  model's `.native.json` and checks decoded results match the stick; then Whisper (native) and
  llama.cpp + GGUF.

### Step 59. Library split, converter fixes, and stick-vs-Core ML checks for 45 models (2026-11-18)

- User decisions: Hailo Studio is exclusively for the stick (I had quit its Mac window to free the stick
  for checks; it is no longer touched). Verification may use the stick from the command line only.
  Library: shared stick-free core, stick code apart.
- Library split (UGenKit package): new target/product **StudioCore** (everything stick-free: models,
  decoders, renderers, tracker, pipelines, CLIP, RTSP, HTTP server, `InferenceEngine`, `CoreMLEngine`,
  `StudioError`); **UGenKit** keeps `UGenDevice`, GenAI and `CUGenRT`, re-exports StudioCore
  (`@_exported import`) and adds `extension UGenDevice: InferenceEngine`. Hailo Studio code unchanged
  and builds; Artelico links only StudioCore (its binary has 0 stick symbols). 85 tests pass.
- Converter fixes (`native/tools/convert_onnx.py`):
  - `Split` v18 -> registered with onnx2torch's Split-13 module; `Upsample` v7/v9 -> Resize-10 module.
  - `auto_pad=SAME_UPPER/LOWER` -> explicit pads computed with ONNX shape inference (deeplab).
  - Opset 18-21 graphs (YOLO11, YOLO26): `onnx.version_converter` fails ("No Adapter From Version $18
    for Split"); instead, for graphs using only ops unchanged since 17, Split's `num_outputs` becomes
    explicit sizes, Resize's new default attributes are dropped, and the opset is relabelled 17.
  - Several image inputs ("image", "image_2") and non-image tensor inputs; normalization only on images.
  - fastvit_sa12 needs `--fp32` (float16 changed its logits; fp32 matches ONNX exactly, 0.0000).
- zsh pitfall: `rm -f dir/*.part && ...` aborts the chain when nothing matches ("no matches found").
- `ugen native-map` (Sources/ugen/NativeMap.swift) + `native/tools/map_all.sh`: runs the HEF on the stick
  and the Core ML model (CPU, float32) on the same prepared frame; pairs outputs by size and picks an
  activation only if it fits >2x better (Hailo adds sigmoids on score outputs on the chip); for
  detectors with on-chip NMS detects one of four layouts (full export v8/v5, DFL heads, anchor heads;
  anchors from `native/src/<m>/<m>_nms_config.json`, else Model Zoo config); writes
  `native/coreml/<m>.native.json`; compares decoded results. Logs in `native/map-logs/`.
- Engine fixes found by these checks:
  - Argmax outputs are `int32` in Core ML; reading them as float gave garbage classes. Now read as int.
  - The segmentation decoder reads class maps as one byte per pixel -> class maps stay bytes.
  - Pose, instance segmentation, oriented boxes and faces decoders read raw UINT8/UINT16 bytes directly
    (fast paths) and ignored FLOAT32 ("37 persons", "nothing detected"). Instead of changing shared
    decoders, the engine hands such outputs over as UINT16 over the stick's value range (65,536 steps).
  - New engine decoders for DFL heads (YOLOv8/10/11 cut) and anchor heads (YOLOv5/7 cut) + shared NMS.
- Results against the stick (bus.jpg unless noted): all YOLO detectors (v5, v6, v7, v8, v9, v10, v11,
  YOLO26; 24 models) find the same objects (5/5 or 6/6; yolov10s 4/5, missed a 0.48 person), box IoU
  0.945-0.993, score difference 0.005-0.048. Pose 4/4 (IoU 0.986). Instance segmentation (v5/v8 seg):
  same objects. Classification, CLIP, arcface: same top classes (stick is 8-bit quantized, Core ML
  close to float). Depth, faces (scrfd), super-resolution (real_esrgan), Cityscapes segmentation
  (fcn8, stdc1, segformer): same results.
- Open: yolov7x (converted file has an empty [0,1] output), stereonet (tool feeds one picture),
  deeplab (VOC model, needs a fitting picture), CLIP text encoder (conversion error), TFLite-only
  models (resnet_v1_34, resnet_v1_50, ssd_mobilenet_v1), and 9 vision models without a Model Zoo
  config (ocr, ocr_det, ufld_v2_tu, yolo11s_obb, yolo26n/s/m_pose, hailo_yolov8n_4_classes_vga,
  ssd_mobilenet_v1_visdrone).

### Step 60. Artelico runs on the iPhone; layout for phones (2026-11-18)

- More fixes: yolov7x's ONNX ends in NMS (output [0, 7]) and its config names no cut point; convert_all
  now cuts anchor YOLOs at the 3 head convs with anchors x (5 + classes) channels, and the engine
  decodes channels-first anchor heads [1, 255, H, W]. yolov7x has no nms_config.json and fell back to
  YOLOv5's default anchors (IoU 0.668); with YOLOv7's anchors (same family) IoU 0.957, 6/6.
  stereonet: the stick lists its inputs as input_layer2, input_layer1 (reversed vs the ONNX graph);
  `NativeModelMap.inputs` records the Core ML input order, chosen by the checker (error 39.9 vs 4.9).
  CLIP text encoder converts (normalization skipped for non-image inputs; diff 0.02).
- Status: 47 of 61 vision models converted; 46 checked against the stick (text encoder via the app).
- Artelico installed on the iPhone 17 Pro Max with a starter set copied by `devicectl device copy to
  --domain-identifier io.ugenkit.Artelico` into `Documents/models/` (yolov8m, yolov8m_pose, yolov8m_seg,
  scrfd_10g, arcface_mobilefacenet, resnet_v1_18, scdepthv3, stdc1, real_esrgan_x2 + .native.json).
  User tried it: bus 94%, inference 14.0 ms (includes pixel-buffer creation), decode 0.0 ms.
- User: "just a bit strange how tiny this is" (screenshots, portrait and landscape). Photos screen now
  adapts: compact width (iPhone portrait) = one column, picture full width at its own aspect ratio,
  results below in a scroll view; compact height (iPhone landscape) = narrower results column (250),
  sample strip moved to a "Pictures" sheet; task/model pickers scroll sideways. iPad/Mac unchanged.
  Screenshot after the change: `logs/artelico-iphone-photos.png`.
- A second, later screenshot captured another app the user was using; deleted immediately. Rule now:
  screenshot only right after launching our app.

### Step 61. Artelico on the iPad (2026-11-18)

- First install failed: `0xe8008012 (This provisioning profile cannot be installed on this device.)`.
  Cause: Artelico's automatic profile was created while building for the iPhone only. Fix: build once
  with `-destination id=<iPad UDID> -allowProvisioningDeviceRegistration`; Xcode regenerated the profile
  with the iPad. (Same pattern as step 15.)
- The failed launch meant a screenshot would show another app: deleted unviewed. Launch + screenshot
  are now chained on "Launched application" in the launch output.
- Same 9 models copied. `-autorun`: bus 94%, person 94/91/90/66% (same as iPhone and stick);
  model load 1352 ms (first compile on device), prepare 4.7 ms, inference 21.6 ms, decode 0.0 ms.
  Screenshot: `logs/artelico-ipad-photos.png`.
- Note: app-side inference (21.6 ms iPad, 14.0 ms iPhone) is about twice the bare Core ML time from
  NativeBench (9.8 / 5.4 ms): it includes building the pixel buffer from RGB bytes and the
  stride-aware output copy (84 x 8400 values element by element) plus NMS. Room to optimize.

### Step 62. Live screen on iPhone portrait; simulator for layout checks (2026-11-18)

- User screenshot: Live screen clipped on both sides in iPhone portrait (wide iPad control rows), and it
  defaulted to yolov8s, which is not on the phone ("yolov8s is not on this iPhone yet").
- `LiveView.swift`: pickers row scrolls sideways; on compact width the stream field gets its own line
  with Road cameras / Recent under it, second-source controls stack, two sources stack vertically;
  FPS and recorded-frame count moved onto the video as a small capsule; toolbar "Recordings" became an
  icon. Left-aligned the stacked controls.
- `TaskModelPicker` (ContentView.swift): models on this device listed first, others marked "(not on this
  iPhone)"; when the current choice is not installed it switches to the first installed model.
- Screenshots of the real iPhone captured another app twice (deleted at once, contents not used). No
  more iPhone screenshots unless the user says it is free. Layouts are checked in the iOS simulator
  instead: `xcrun simctl boot <iPhone 17 Pro Max sim>`, build with `-destination id=<sim>`
  (`-derivedDataPath build-sim`), `simctl install`, copy models into
  `$(simctl get_app_container <sim> io.ugenkit.Artelico data)/Documents/models`, `simctl launch
  --terminate-running-process ... -section live`, `simctl io <sim> screenshot`. Result:
  `logs/sim-iphone-live.png` (fits, yolov8m picked). Installed on the iPhone.

### Step 63. Model sizes; weight compression tried, 16-bit kept (2026-11-18)

- Converted Core ML packages (float16 weights): 1.83 GB for the 47 models that also exist as HEF, vs
  972 MB of HEFs (8-bit weights): x1.9 overall; nano models about equal, large ones x2-2.8,
  fastvit (float32) x4.1.
- Tried on yolov8m (`native/tools/compress.py`):
  - 8-bit linear (per channel, symmetric): 25 MB (HEF 26 MB), 5/5 objects but box IoU vs stick fell
    0.988 -> 0.894 and the Neural Engine run added an extra person.
  - 6-bit k-means palettization (per tensor; per-group tables need an iOS 18 deployment target; needs
    scikit-learn in .venv-convert): 19 MB, 5/5, IoU 0.985 - nearly as good as float16.
- User: "16 bit is ok". Kept float16; test copies deleted. 6-bit palettization noted as the option if
  download size matters later.

### Step 64. Speech and language plan; dependency scan and pinning (2026-11-18)

- Plan agreed: speech = WhisperKit (Core ML on the Neural Engine); chat / ask-an-image = llama.cpp + GGUF
  (Metal); also Apple's built-in Foundation Models (no download). Test order: iPad first, then iPhone.
- User rule (now standing): scan third-party code for vulnerabilities before use, then pin versions.
- WhisperKit: now in `github.com/argmaxinc/argmax-oss-swift` (old WhisperKit repo redirects there).
  Added to Artelico `project.yml` with `exactVersion: 1.1.1`; Package.resolved pins argmax-oss-swift
  1.1.1 @ 1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4 and swift-argument-parser 1.8.2 @ 6a52f325.
  (Vapor/OpenAPI dependencies belong to the CLI targets and are not fetched for the WhisperKit product.)
  - OSV.dev (`api.osv.dev/v1/query`, ecosystem SwiftURL): no vulnerabilities for any of the three.
  - GitHub advisories (`api.github.com/repos/<r>/security-advisories`, `/advisories?ecosystem=swift`):
    none. (`gh` CLI is not installed; used curl.)
  - Code review: WhisperKit + ArgmaxCore contact only huggingface.co (model downloads; redirects limited
    to relative ones); no process spawning, dlopen, analytics/telemetry, or unarchiving. HF token is
    read only from env vars HF_TOKEN / HUGGING_FACE_HUB_TOKEN (unset in apps), never from files.
    Downloads go to `downloadBase` (default Documents/huggingface).
- Python conversion environment pinned: `native/requirements-convert.txt` (32 packages, `uv pip freeze`;
  torch 2.15.0, coremltools 9.0, onnx 1.23.2, onnx2torch 1.5.15, onnxruntime 1.32.0, numpy 2.5.5,
  pillow 13.0.0, pyyaml 6.0.3, scikit-learn 1.9.1). `pip-audit==2.9.0 -r ... --no-deps --disable-pip`:
  "No known vulnerabilities found". (Without --disable-pip it crashed creating a temp venv: ensurepip
  SIGABRT.) Model files are ONNX protobuf, loaded with onnx.load (no pickle); configs with yaml.safe_load.

### Step 65. Native speech to text in Artelico (WhisperKit) (2026-11-18)

- `Artelico/App/SpeechEngine.swift`: downloads a Whisper variant once (`WhisperKit.download(variant:
  downloadBase: <models>/whisper)` with progress), remembers its folder, loads it with
  `WhisperKitConfig(modelFolder:, prewarm: true, load: true, download: false)` and keeps it loaded.
  `AudioLoader` (16 kHz mono floats) moved here from the stick app.
- `Artelico/App/SpeechView.swift`: ported from Hailo Studio; Whisper model picker (WhisperKit's
  supported list for the device, recommended and downloaded ones marked), download progress, record /
  open file / sample, translate, language; phone-friendly layout; writes the last result to
  `Documents/speech-result.txt` (read with `devicectl device copy from`, no screenshot needed).
  Launch args: `-section speech -autospeech [-speechmodel <variant>]`. Sidebar: "Language > Speech to text".
- Build error: `'ModelInfo' is ambiguous` - WhisperKit also defines `ModelInfo`. WhisperKit is now only
  imported in the speech files; `StudioModel` holds the model in a small `LoadedWhisper` box.
- New files need `xcodegen generate` ("cannot find 'SpeechView' in scope" otherwise).
- WhisperKit's recommended model for a Mac/simulator is `openai_whisper-large-v3-v20240930` (large,
  ~1 MB/s download here). Default changed to `openai_whisper-base` (143 MB, same size Hailo Studio runs
  on the stick); variants listed at huggingface.co/api/models/argmaxinc/whisperkit-coreml/tree/main
  (tiny ... large-v3 turbo, compressed _216MB/_632MB versions).
- Simulator (iPhone 17 Pro Max): sample -> "Hello from the iPad, the quick brown fox jumps over the lazy
  dog." 4.1 s of audio in 0.70 s (language detected: en); first run 243 s for download + preparation.
- iPad: installed, but launch refused: "Unable to launch ... because the device was not, or could not
  be, unlocked" (BSErrorCodeDescription = Locked). Waiting for the user to unlock it.
- iPad (unlocked): sample -> correct text. First run: model ready in 161.6 s (download + compile),
  0.80 s to transcribe. Second launch: model ready 0.7 s, transcription 0.19 s (stick: ~2 s load,
  0.7 s). Results read from `Documents/speech-result.txt` (no screenshot).
- iPhone 17 Pro Max: correct text, model ready 22.1 s on first run (download + compile), 0.12 s to
  transcribe. No screenshot taken.

### Step 66. llama.cpp: advisories, pin, own build with a Mac Catalyst slice (2026-11-18)

- Advisories (`api.github.com/repos/ggml-org/llama.cpp/security-advisories`): 13, mostly GGUF parsing
  and RPC server bugs; newest fix is b8146 (2026-03). GHSA-j8rj-fmpv-wcxw (critical RCE) has no fixed
  version but is in the RPC backend (network feature), which is not built here. OSV: none listed.
- Pinned build: **b12138** (published 2026-11-05, ~2 weeks old, chosen over today's builds; every llama.cpp
  build is labelled "pre-release"), tag commit f7b41cca4fecc8164c7ea45bfb55dfff7633842f.
  Official `llama-b12138-xcframework.zip` downloaded to `vendor/llama-b12138/`; SHA-256
  41ab70e0f496e84e5d89b286a5ed07f248192daca034cd0458670281383da573 matches GitHub's asset digest.
  Contents: no RPC backend (only `llama_supports_rpc`), mtmd (image input) included, Metal, links only
  system frameworks + libc++, unsigned. But slices are only ios-arm64 and macos (no simulator, no Mac
  Catalyst), so it cannot be used for Artelico on the Mac.
- Own build from the pinned source (`vendor/llama.cpp-b12138`, shallow clone of the tag): llama.cpp's
  `./build-xcframework.sh ios-sim ios-device` (unchanged), plus `native/tools/build_llama_xcframework.sh`
  which builds a Mac Catalyst slice (`-target arm64-apple-ios17.0-macabi`, macOS SDK + iOSSupport, same
  CMake options: no RPC/server/tools, Metal embedded, MTMD on, video off) and assembles
  `vendor/llama-b12138-artelico/llama.xcframework` (51 MB): ios-arm64, ios-arm64_x86_64-simulator,
  ios-arm64-maccatalyst; checked with vtool (IOS / IOSSIMULATOR / MACCATALYST) and nm (llama_decode,
  354 mtmd symbols, Metal backend, no RPC).
- GGUF models chosen from official publishers (ggml-org, Qwen) and bartowski (Meta publishes no GGUF):
  Gemma 3 1B 0.8 GB, Qwen3 1.7B 1.3 GB, Llama 3.2 3B 2.0 GB, Qwen3 4B 2.5 GB (chat); SmolVLM2 2.2B
  1.1+0.6 GB, Qwen2.5-VL 3B 1.9+0.85 GB, Gemma 3 4B 2.5+0.85 GB (image questions; second file =
  mmproj image encoder). All Q4_K_M.

### Step 67. Chat and Ask an image with llama.cpp in Artelico (2026-11-18)

- `App/LlamaEngine.swift` (actor over llama.cpp's C API, b12138): loads a GGUF fully on the GPU (Metal;
  CPU in the simulator), optional mmproj image encoder via mtmd; prompt from the model's built-in chat
  template (`llama_chat_apply_template`, no Jinja) with ChatML fallback; stateless (clears memory and
  evaluates the whole conversation each call; 4096-token context); sampling top-k 40 / top-p / min-p /
  temperature (greedy at 0); streams text holding back incomplete UTF-8 sequences; cancel() between tokens.
  Pictures: `mtmd_bitmap_init` + `mtmd_tokenize` + `mtmd_helper_eval_chunks`, marker `mtmd_default_marker()`.
- `App/LanguageModels.swift`: GGUF catalog (step 66), custom models from a pasted huggingface.co link,
  downloads to `<models>/gguf/<repo>__<file>` with progress, each file checked against the SHA-256
  Hugging Face publishes (`/api/models/<repo>/tree/main`, `lfs.oid`) before it is kept; loading a
  language model first unloads Core ML vision models and Whisper (memory).
- `App/ChatView.swift`, `App/AskImageView.swift`: ported from Hailo Studio (history, starters, settings,
  formatted answers, tokens/s). Qwen3 thinking off by default ("/no_think" appended; a setting turns it
  on); `<think>` blocks hidden. Phone layout for Ask an image. Test hooks: `-chat "<q>" [-chatmodel
  <file>]` -> `Documents/chat-result.txt`; `-ask "<q>" [-askmodel <file>]` -> `Documents/ask-result.txt`.
- Project: `framework: ../vendor/llama-b12138-artelico/llama.xcframework`, embedded (signed by Xcode).
- Bug avoided: the first streaming loop only finished the stream after the loop (would never end); the
  stream is now finished inside the generating task.

### Step 68. Download progress fix; OCR and oriented boxes from the Model Zoo; re-check of all models (2026-11-18)

- iPad chat test: first try ended with `NSURLErrorDomain -999 cancelled` - the user had cancelled it
  because the bar did not move. The download was in fact running (~1.1 MB/s, the CFNetworkDownload_*.tmp
  file grew 258 -> 280 MB in 20 s; checked with `devicectl device info files --subdirectory tmp`).
  Cause of the stuck bar: `URLSession.download(from:delegate:)` (async) does not deliver download
  progress to its delegate. New `App/FileDownloader.swift` (download task + session delegate: bytes,
  total, speed); Chat/Ask show "<file>: x of y MB, z MB/s"; screen kept awake while downloading,
  loading and answering; 3 retries; leftover temp files of interrupted downloads removed at launch.
- Three of the 13 missing models are in the Model Zoo under other names (same input sizes):
  ocr_det = paddle_ocr_v5_mobile_detection (544x960), ocr = paddle_ocr_v5_mobile_recognition (48x320),
  yolo11s_obb = yolov11s_obb. `convert_all.py` accepts `app_name=zoo_name`.
- Checker fix: it had applied a softmax across ocr_det's whole 544x960 map ("0 text regions"). New rule:
  softmax only for flat class-score vectors; sigmoid only when the stick's values are in 0..1 and the
  Core ML values are not. Re-check of all 48 models: same results as before (log
  `native/map-all-rerun.log`).
- Native models that differ from the stick's: `NativeModelMap.model` (the native ModelInfo) is used by
  CoreMLEngine instead of the stick's; the checker writes it when the Core ML input size or a single
  output's size differs, keeping the stick's element types (the engine hands quantized outputs over as
  UINT16, which the byte-level decoders read; declaring FLOAT32 there broke the oriented-box decoder:
  1087 objects instead of 39).
  - yolo11s_obb: the zoo has it only at 1024x1024 (hailo-apps compiled 640x640). Same 39 vehicles as the
    stick on dota_image.png.
  - ocr: the zoo's recogniser is PP-OCRv5 multilingual (18,385 classes) vs hailo-apps' 97-character
    English one. Dictionary bundled in StudioCore (`Resources/ppocrv5_characters.json`, 18,382 chars from
    the zoo's ppocrv5_char_dict.npz, Apache-2.0); class layout from the zoo's
    text_recognition_postprocessing.py: 0 blank, 1 ignored, 2.. characters, last = space.
    Rendered test lines (testdata/samples/textline_en.png, textline_pt.png):
    stick "Artelico reads text 2026" / "Acao na Estacao de Sao"; Core ML "Artelico reads text 2026" /
    "Agāo na Estagāo de Sāo" (keeps accents, sometimes the wrong one).
  - ocr_det: 4 text regions vs the stick's 3.
- Converted now: 51 of the app's 61 vision models. Still missing: resnet_v1_34, resnet_v1_50,
  ssd_mobilenet_v1 (TFLite only, also in the newer 2025 packages), ufld_v2_tu, yolo26n/s/m_pose,
  hailo_yolov8n_4_classes_vga, ssd_mobilenet_v1_visdrone, all_minilm_l6_v2.
- 85 UGenKit/StudioCore tests pass after the shared decoder change.

### Step 69. Chat works on the iPad; full Model Zoo inventory; downloads for both apps (2026-11-18)

- iPad chat (Qwen3 1.7B, llama.cpp b12138, Metal): "The capital of Portugal is Lisbon, and the river that
  runs through it is the Tagus." Prompt 41 tokens in 0.28 s, answer 23 tokens at 34.7 tokens/s.
  The 1.3 GB download broke off several times (partial files of 590/790 MB left in tmp); retries
  restarted from zero. `FileDownloader` now resumes from `URLError.downloadTaskResumeData` (6 attempts).
- More models found and converted:
  - yolo26n/s/m_pose: Ultralytics publishes ONNX in its GitHub release v8.4.0 with SHA-256 digests
    (verified); cut at the 9 `one2one` head convs; vs stick 4/4, 3/3, 3/3 people, IoU 0.915-0.963.
  - resnet_v1_34 / resnet_v1_50: ONNX Model Zoo (onnxmodelzoo/resnet34-v1-7, resnet50-v1-7 on HF,
    Apache-2.0), SHA-256 verified against HF's LFS ids. (Conversion pending.)
  - ufld_v2_tu: PINTO's archive is 2.9 GB for all variants; using the original project instead
    (github.com/cfzd/Ultra-Fast-Lane-Detection-v2 @ c903880, MIT; TuSimple ResNet-18 weights on Google
    Drive; output sizes 22400/16400/448/328 = TuSimple config, 56 row / 41 col anchors, 4 lanes).
  - all_minilm_l6_v2: only used by hailo-apps' Voice-to-Action demo (wake word -> Whisper -> MiniLM
    picks a tool by embedding similarity -> Qwen2.5-Coder fills parameters -> Piper TTS). Becomes an
    Artelico app example (voice assistant) instead of a vision model.
  - hailo_yolov8n_4_classes_vga, ssd_mobilenet_v1_visdrone: Hailo-trained (Hailo forum: "custom-trained
    model created by us"), no originals; ignored per user.
- Full inventory (user's request): Model Zoo v5.3.0 HAILO10H tables = 206 models, 27 task pages
  (`native/zoo-hailo10h-inventory.json`), none Hailo-trained; 174 ONNX + 32 TFLite. User: all of them
  in both apps (HEF in Hailo Studio, Core ML in Artelico); HF repo organised by task page.
  - Background: `tools/download_hefs.sh` (all 206 compiled HEFs from
    hailo-model-zoo.s3.../ModelZoo/Compiled/v5.3.0/hailo10h/<name>.hef into models/, kept only on HTTP 200
    + HEF magic "\x01HEF") and `convert_all.py` over the 155 not yet converted (19.5 GB of ONNX zips,
    smallest first). Disk: 1.5 TB free.
  - TFLite (32 models: EfficientNet/-Lite, MobileNets, Inception, SSD, EfficientDet, CenterNet,
    tiny-YOLOv4, YOLOv3, U-Net, RetinaFace, MediaPipe face/hand landmarks): tf2onnx 1.17.0 +
    TensorFlow 2.21.0 (both 0 OSV advisories) in a separate `.venv-tflite`.
- Answered: the vision models could also run in a browser with ONNX Runtime Web + WebGPU from a static
  site (GitHub Pages), using the ONNX originals and decoders rewritten in JS - possible later
  ("Artelico Web").
- Slow downloads explained (user asked "why is it slow"): 35 curl processes were running - stopping a
  batch script with pkill left its curl children running, and new batches added more. With all
  downloads stopped the line measured ~0.8 MB/s (Cloudflare 10 MB test: 780 KB/s; Hailo S3 single
  stream 500 KB/s; the iPad was also downloading SmolVLM2). Parallel downloads cannot beat the line;
  they only slowed each other and the iPad. Remaining ~10 GB HEFs + up to 19.5 GB archives = ~10 h at
  this rate. Restarted with 2 + 2 parallel downloads; per-file helper scripts (tools/fetch_hef.sh,
  native/tools/fetch_zoo_archive.sh) because `xargs -I` refused the long inline script ("command line
  cannot be assembled, too long"). To stop a batch fully, also kill its curl/helper processes.
- TFLite route works for classifiers (mobilenet_v1 via tf2onnx + `--inputs-as-nchw`: max diff 0.0023).
  TFLite detectors with TF preprocessing (ssd_mobilenet_v1: `TensorArrayV3`) fail in
  `onnx.utils.extract_model` (validates the whole graph); needs cutting before validation.
- Shared decoder fix: classifiers ending in a softmax (resnet_v1_34/50 HEFs) got a second softmax
  because their quantized sum was not within 0.05 of 1 ("fig 0.2%"); now treated as probabilities when
  all values are in 0..1 and the sum is 0.7..1.3 (renormalised). Stick now "fig 63.2%". Helps Hailo Studio.
- Real cause of the slow line (user: "speed test on my phone is 100x faster"): the Mac's default route
  is `utun16`, a Surfshark VPN tunnel ("Surfshark. Dausos" profile connected; `scutil --nc list`).
  Wi-Fi itself is fine (802.11n, 2.4 GHz ch 12, -29 dBm, 144 Mbit/s link). Left to the user: disconnect
  the VPN during downloads, or use the WireGuard profile / a nearer server, or split tunnelling.
  (Downloads were paused with SIGSTOP for the check and resumed with SIGCONT.)
- Stopped everything for a restart of the Mac (user). State: 96 HEFs in models/ (of 206 + originals),
  62 Core ML packages in native/coreml/, 137 source archives in native/src/. Partial files removed.
  To resume (all skip what is already done):
    tools/download_hefs.sh > native/download-hefs.log 2>&1            # HEFs, 2 at a time
    native/tools/prefetch_zoo.sh > native/prefetch-zoo.log 2>&1       # source archives, 2 at a time
    .venv-convert/bin/python -I native/tools/convert_all.py $(cat native/todo-convert.txt)
      (re-converts models already done; better: filter todo-convert.txt to names without a package)
    UFLD v2 weights: Google Drive id 1Clnj9-dLz81S3wXiYtlkc4HVusCb978t -> native/src/ufld_v2_tu/
  Then: TFLite models (32) with the TFLite route, stick checks (native/tools/map_all.sh), catalog
  rebuild for all HEFs, new decoders. iPad: SmolVLM2 download for "Ask an image" was still running in
  Artelico (it resumes or restarts when Artelico is next opened on that screen).

### Step 70. VPN on WireGuard: speed back; resumed (2026-11-18)

- User switched Surfshark to WireGuard: Cloudflare 38 MB/s, Hailo S3 single stream 55 MB/s (~70x).
- User tested "Ask an image" on the iPad (SmolVLM2): works.
- Resumed downloads 4 + 4 parallel; converter on the models without a package yet.
- ufld_v2_tu converted from the original project: weights tusimple_res18.pth (Google Drive id
  1Clnj9-dLz81S3wXiYtlkc4HVusCb978t, 385 MB, legacy torch pickle, SHA-256 490d8f81...3f710a4c) loaded with
  `torch.load(weights_only=True)`; model code vendor/ufld-v2 @ c903880 (utils.common stubbed: only a
  weight initialiser); torchvision 0.29.2 added to .venv-convert (pip-audit clean, requirements
  re-pinned). `native/tools/export_ufld.py` -> ONNX with four flat outputs 22400/16400/448/328 (no
  missing/unexpected keys). Core ML vs ONNX max diff 0.007; vs stick on lane.png: 3 lanes = 3 lanes.
- All of Hailo Studio's original vision models now run natively except the two Hailo-trained detectors
  (dropped) and MiniLM (moved to the voice-assistant example).

### Step 71. Artelico voice assistant (Whisper + MiniLM + GGUF LLM + speech) (2026-11-18)

- After hailo-apps' Voice-to-Action demo (v2a_demo): speech (WhisperKit) -> tool choice (all-MiniLM-L6-v2
  sentence embeddings, cosine, per-tool thresholds as in tool_selector.py) -> parameters (the chosen GGUF
  chat model, JSON, prompts adapted from v2a_demo/tools/*.py) -> tool -> spoken answer (AVSpeechSynthesizer).
  Push-to-talk or typed. `Artelico/App/Assistant/`: WordPieceTokenizer.swift (BERT uncased WordPiece),
  ToolSelector.swift, AssistantTools.swift, AssistantView.swift. Sidebar "Examples > Assistant".
- Tools: none (short LLM answer), explain_tools, get_weather (Open-Meteo, no account), get_travel_time
  (Apple Maps / MapKit; home/work addresses in settings; current location when in use), control_torch
  (camera flash, the counterpart of the LED tool), system_check (battery, storage, thermal, models),
  data_storage (Documents/assistant-memory.json), set_timer (local notification), get_time, web_search.
- web_search (user asked for a SearXNG-like meta-search): uses the user's SearXNG server (JSON API) if
  set, else DuckDuckGo's HTML page + Wikipedia's API merged (user: "ddg seems ok", "and wikipedia"); the
  LLM answers from the top 5 results and names the site.
- MiniLM: sentence-transformers/all-MiniLM-L6-v2 onnx/model.onnx (Apache-2.0, SHA-256 6fd5d72f...046452
  verified) -> `native/tools/convert_minilm.py`: token ids + mask (int32, 64) in, mean pooling and L2
  normalisation built in, float32; cosine with the ONNX model 1.0. `native/coreml/all_minilm_l6_v2.mlpackage`
  + `all_minilm_l6_v2.vocab.txt`.
- `languageModel(_:keepSpeech:)` keeps Whisper loaded next to the language model for the assistant.
  Location permission text added (iOS Info.plist, Mac sandbox entitlement).
- Built (iOS). Device test blocked: iPad and iPhone "unavailable" to devicectl after the Mac restart
  (asleep, or the VPN blocking the local network).
- iPad not reachable after the Mac restart: Mac was on Ethernet (<lan-address>), then Wi-Fi on too,
  then Surfshark paused/quit - devicectl still "unavailable" (JSON: transport None, tunnel unavailable;
  the Apple Watch was seen over localNetwork). Fixed by connecting the iPad by USB cable once.
- Assistant on the iPad (typed requests via `-assistant`, Qwen3 1.7B, results from
  Documents/assistant-result.txt):
  - weather <city> tomorrow -> get_weather 0.58, {"date":"tomorrow","location":"<city>"}, Open-Meteo answer;
    choice 0.58 s, parameters 1.98 s, weather 0.50 s.
  - "Remember Ana's phone is 912 345 678" -> data_storage, stored; "What can you do?" -> explain_tools 1.00.
  - First misses: "Search the web for the Hailo-10H accelerator" -> none (0.25), "What is Ana's phone
    number?" -> none (0.34). The original ONNX MiniLM gives the same scores (0.21 / 0.34): the embeddings
    follow the topic, not the command. Fix: request-shaped memory samples (threshold 0.48) and explicit
    `trigger` regexes before MiniLM for web_search ("search", "look up", "google", "online", "news about")
    and data_storage ("remember", "save", "recall", "<name>'s phone/email/birthday/address/id").
  - After: web_search {"query":"Hailo-10H"} answered from Wikipedia (AI HAT+ 2, 40 TOPS); memory
    retrieve "Ana's phone is 912 345 678"; "Who invented the telephone?" -> none (0.46) -> correct;
    "Look up the opening hours of the Louvre" -> web_search, but the 1.7B model said "open daily except
    Mondays" (wrong: Tuesdays). Small models can misread snippets.
- Slow network solved (2026-11-18 evening): not the VPN in the end, not the cable or the switch (3 ports
  tried; Ethernet link 1000baseT full duplex, 0 errors, 0 retransmissions, 1.5 ms to the router). Ethernet
  download was capped at ~1 MB/s while upload did 5.5 MB/s and Wi-Fi did 35 MB/s. Cause: Wi-Fi (en1,
  <lan-address>) and Ethernet (en0, <lan-address>) on the same subnet at once. With Wi-Fi off: Ethernet
  44 MB/s down. Rule: only one of the two on at a time. I changed no network settings (read-only checks;
  the user removed Surfshark and toggled Wi-Fi). Surfshark's two network extensions are still installed
  (idle). No proxies, pf rules, odd routes, DNS changes or MTU changes were found.

## STATUS (2026-11-18, evening) - what is done and what is missing

### Network (blocking downloads)
- Mac on Ethernet via a switch; intermittently ~10 Mbit/s with 130-900 ms ping to the router while a
  device on the switch's extender Wi-Fi did 230 Mbit/s at the same moment. Ruled out: VPN (removed),
  Wi-Fi+Ethernet together (Wi-Fi now off), 3 switch ports, VPN leftovers (none active), link errors
  (0 errors, no link drops in the log, 1000baseT full duplex). Not yet tried: another Mac cable, the Mac
  cable straight into the router. User is restarting the Mac to test; if it continues: the Mac's port.
- No downloads until this is solved (user). Nothing of mine is running.

### Hailo Studio (stick, iPad + Mac) - done
- iPad app with DriverKit driver; Mac app (Mac Catalyst, IOKit, sandboxed); renamed "Hailo Studio".
- Vision: 61 hailo-apps models with decoders; detection, pose, segmentation, depth, faces, OCR, CLIP,
  lanes, oriented boxes, super-resolution, stereo; live camera/streams, tracking, recording, REST API.
- Language on the stick: Whisper (verified on iPad), chat, VLM (verified on Mac).
- New: shared library split (StudioCore stick-free / UGenKit stick); model list now 216 models
  (all 206 Hailo Model Zoo Hailo-10H HEFs downloaded to models/ + hailo-apps ones), grouped by the zoo's
  task pages (`taskPage`); classification double-softmax fix; models-folder chooser.
### Hailo Studio - missing
- Device screen still groups by the old fixed task list (needs grouping by task page for the 216).
- Decoders for the new task pages (see "Decoders" below); not rebuilt/installed with the 216-model list yet.
- Distribution (signing, notarization, .dmg, GitHub) - parked.

### Artelico (native, iPhone + iPad + Mac) - done
- Separate app (bundle io.ugenkit.Artelico), placeholder "a." icon; Core ML engine (CoreMLEngine) using
  the same decoders as the stick through NativeModelMap; phone layouts (Photos, Live).
- Vision verified on iPhone and iPad (yolov8m: same detections as the stick, 14 ms / 21.6 ms in app).
- Speech: WhisperKit 1.1.1 (pinned, scanned) - verified on iPad and iPhone.
- Chat + Ask an image: llama.cpp b12138 (pinned, own build with Mac Catalyst slice, no RPC), 7 curated
  GGUF models + any HF link, SHA-256-checked resumable downloads - chat verified on iPad (34.7 tok/s),
  Ask an image verified by the user on iPad.
- Voice assistant (Examples): Whisper -> MiniLM (Core ML) tool choice + trigger phrases -> GGUF LLM
  parameters -> 10 tools (weather, travel, web search DDG+Wikipedia/SearXNG, torch, device check,
  memory, timer, time, explain, general) -> spoken answer. Verified on iPad with typed requests.
### Artelico - missing
- Microphone path of the assistant not yet tried by me on a device (typed requests only).
- Core ML model download source (Hugging Face repo, organised by task page) - after the set is complete.
- Device/model screens for 216 models; Live/Device restyle; Mac app not re-tested since the native work.
- App examples still to build: yoga/pose coaching, hand counting, and others from Hailo's demos.

### Models for Artelico (Core ML) - status
- 133 Core ML packages in native/coreml/; 56 have a stick-checked `.native.json` (all of Hailo Studio's
  original models except the 2 Hailo-trained ones, which are ignored).
- Hailo Model Zoo (206): 128 converted, 78 not yet:
  - conversion failures to fix: nextvit_base/small, vit_small_bn, efficientdet_lite0 (TFLite),
    yolo26n/s/m/l_seg;
  - not reached before the network problem (batch stopped; 7 need large downloads): many YOLO/YOLOX
    variants, tiny_yolov3/4, yolov3*, yolov4, yolov11 n/m/x obb, person/face attributes, re-ID, pose
    (centerpose, mspn, vit_pose), deeplab, unet, espcn x2-4, r3d_18, all CLIP/TinyCLIP/SigLIP encoders,
    depth_anything v1/v2, fast_sam_s, yolo_world_v2s.
  - converted models still to check against the stick: the 77 new zoo conversions (needs their
    decoders first for the new task pages).
- Resume: `.venv-convert/bin/python -I native/tools/convert_all.py $(cat native/todo-convert.txt)`
  after trimming todo-convert.txt to names without a package; then `native/tools/map_all.sh <names>`.

### Decoders (StudioCore, shared by both apps) - missing
- Detection raw heads: DAMO-YOLO, CenterNet, tiny-YOLOv3/v4 (stick); YOLOX, SSD natively (engine).
- Segmentation: YOLACT, YOLO26-seg, YOLOv5-seg byte-mask NMS (`NMS_BYTE_MASK`), FastSAM, U-Net, DeepLab
  NCHW.
- Faces/people: RetinaFace, LightFace, MediaPipe face landmarks (468), 3DDFA, face attributes (CelebA
  40), person attributes (PA-100k 35), re-ID embeddings (OSNet/RepVGG), MediaPipe hand landmarks (21).
- Pose: CenterPose, single-person heatmap pose (ViTPose, MSPN).
- Image-to-image: ESPCN (Y channel), DnCNN, Zero-DCE.
- CLIP family: tokenizers/embedding tables for CLIP ViT-B/16, L/14, RN50(x4), TinyCLIP, SigLIP/SigLIP2.
- YOLO-World (text prompts + detection), R3D-18 video classification (16-frame clips).

### Step 72. Conversions resumed (2026-11-19)
- Network fixed (user). Ethernet ~11 MB/s download, Wi-Fi off.
- `native/todo-convert.txt` trimmed to the 78 models without a package (full old list kept as
  `native/todo-convert.full.txt`). Batch running: `convert_all.py $(cat native/todo-convert.txt)`,
  output in `native/convert-run-2026-11-19.log`, results in `native/convert-report.jsonl`.
- First start failed (exit 127): the user reset the Mac and the home folder is now `~`
  (was `~`). Both venvs linked to a uv Python under `~/.local/share/uv/python`.
- Fix: base Python 3.12.13 now inside the project (`UV_PYTHON_INSTALL_DIR=$PWD/.python`), both venvs
  rebuilt with the same package versions, read from the old dist-info folders and saved as
  `native/requirements-convert.txt` / `native/requirements-tflite.txt`. Old venvs kept as
  `.venv-convert.old` / `.venv-tflite.old` (delete once the new ones are proven).
- Old `~` paths also remain in Xcode build folders (`UGenProbe/build-mac/...`, caches; clean
  build if Xcode complains) and in old logs/reports (history only).
- Batch restarted.

### Step 73. iPad pairing after the Mac reset (2026-11-19)
- `xcrun devicectl` missing: `xcode-select` pointed at CommandLineTools after the reset. User ran
  `sudo xcode-select -s /Applications/Xcode.app`.
- Pairing was gone ("No devices found"). Cable + Trust -> paired, connected (wired).
- Unplugged: not found. The iPad was visible on Ethernet (`_companion-link._tcp` on en0) but did not
  advertise `_remotepairing._tcp`. Fix: cable in, Xcode > Devices and Simulators > "Connect via network",
  then unplug. Now `transportType localNetwork`, connected, with the Mac on Ethernet only (Wi-Fi off).
- Signing: no code-signing identity on the Mac after the reset. Needs Xcode > Settings > Accounts sign-in
  (team <team-id>); automatic signing then recreates the certificate/profiles.

### Step 74. Checking conversions on decoded results; fixes for the failures (2026-11-19)
- `compare.py`: `COMPUTE_UNITS=CPU_ONLY|CPU_AND_GPU|ALL` and `SAVE_NPZ=<file>` (both sides' outputs).
- New `native/tools/check_decoded.py <models>`: ONNX Runtime vs Core ML (ALL units, as in the apps) on
  what an app would show. Detection: candidates > 0.30 keyed by (output, anchor, class, y, x), pass = none
  missing/extra (other side < 0.25) and 99% of scores within 0.06; segmentation: argmax agreement > 99%;
  pose heatmaps: peak moved <= 1 px; embeddings: cosine > 0.99; attributes: sigmoid>0.5 agreement;
  super-resolution: PSNR > 40 dB; classification: same top-1 and top-5 set. Results in
  `native/check-decoded.jsonl`. OBB models use dota_image.png.
- Why: raw max |diff| is misleading. yolov11n_obb max diff 3.0, yet 413/413 candidates match; the big
  differences are in background cells, and the Neural Engine adds more noise than the CPU (worst score
  0.199 on ALL vs 0.027 on CPU, a single cell that NMS merges).
- First 42 of this batch: 41 pass. yolov12n fails (same 44 candidates but scores off by up to 0.41 in
  float16, also 0.075 on CPU); float32 matches exactly (5.2 ms vs 4.2 ms).
- 8 YOLOs (yolov3, yolov3_416, yolov4_leaky, yolov5s_wo_spp, yolov5xs_wo_spp,
  yolov5s_bbox_decoding_only, yolov7_tiny, yolov7e6) were not cut at the heads: the zoo gives no cut
  nodes, and `yolo_heads()` only ran for meta_arch "yolo" and skipped 5-D outputs. They ended in
  (1,3,H,W,85) or decoded boxes/confs instead of the HEF's (1,255,H,W). `yolo_heads()` now also runs for
  yolo_v3/yolo_v4, cuts 5-D exports and accepts 2-4 heads. Reconverting.
- Failure fixes (`convert_onnx.py` / `convert_all.py`):
  - yolo26*_seg: ConvTranspose (v11 through opset 21) added to the relabel-safe operators. Converts, but
    float16 scores are off by up to 0.67 (0.26 on CPU); float32 exact.
  - nextvit_base/small: AveragePool pads [0,0,1,1] -> ceil_mode=1 without pads (same result with
    count_include_pad=0 when the output sizes agree, which is checked). Top-5 identical to ONNX.
  - vit_small_bn, vit_pose_small_bn: Shape->Gather->Reshape chains folded to constants with ONNX
    Runtime's basic optimizer (667 -> 381 nodes) before onnx2torch. Top-5 / keypoint peaks identical.
  - efficientdet_lite0: Hailo's start node is pad_to_bounding_box/Pad (a no-op on the resized
    picture), in NHWC before tf2onnx's Transpose; the cut now starts after that Transpose. Also: a cut
    input without a shape now falls back to extract_subgraph, which sets 1x3xHxW.
  - clip_vit_l_14_laion2B_text_encoder: config names Add_4/"output", which this export does not have
    (it already starts at the token embeddings) -> keep the whole graph.
  - `FP32_MODELS` in convert_all.py: fastvit_sa12 (was done by hand), yolov12n, yolo26{n,s,m,l}_seg.
- Downloads: one S3 connection got stuck at ~450 KB/s (siglip2_b_16_text_encoder, 930 MB after 36 min)
  while a new connection did 13 MB/s. curl now drops anything under 1 MB/s for 60 s and retries on a new
  connection, resuming the .part file (`-C -`, `--retry 10 --retry-all-errors`).
- Running: the main batch (remaining big encoders) and `native/redo-convert.txt` (20 models, log
  `native/convert-redo-2026-11-19.log`).

### Step 75. Stick checks restarted; tested models copied to iPad and iPhone (2026-11-19)
- Stick plugged into the Mac. `ugen` rebuilt (`swift build` in UGenKit, old cache worked). yolov8m
  `native-map`: 5 of 5 stick objects, mean IoU 0.988. All 176 Core ML packages have a HEF in models/.
- `map_all.sh`: tasks without a ugen decoder (face/person attributes, landmarks, denoising, low light,
  re-ID, single-person pose, embedding) fall back to `classification` = raw output pairing only.
  Running on 110 packages without a .native.json (the 20 in redo-convert.txt follow after reconversion).
  all_minilm_l6_v2 cannot run there (text tokens, not an image).
- `native/tools/copy_to_device.sh <UDID> <list> [skip-list]`: copies <name>.mlpackage + .native.json into
  Artelico's Documents/models. Installed Artelico (built 2026-11-18 16:13) has the 61-model catalog, so
  only those show; 56 of them have a package + stick check (`native/copy-list.txt`, 2.1 GB). Copied to
  the iPad (all OK) and the iPhone (first run stopped when the iPhone lost Wi-Fi; resumed, all OK).
- iPhone over Wi-Fi: it was paired but unreachable because its Wi-Fi was off; once on Wi-Fi it
  advertised `_remotepairing._tcp` and connected (no Xcode step needed for it).
- New Model Zoo models in the apps need a new build: blocked on Xcode sign-in (no signing identity
  after the Mac reset).

### Step 76. Stick checks and ONNX checks: results, and more conversion fixes (2026-11-19)
- Stick run 1 stopped after detr_resnet_v1_18_bn: "configure: USB transfer failed", the stick reset,
  and every later model got "Driver not found". `map_all.sh` now waits 20 s and retries (3x) on that.
  detr left out (it is what knocked the stick over); to rerun alone.
- Reconversions (redo-convert.txt): all OK except three, now fixed:
  - yolov5s_wo_spp / yolov5xs_wo_spp: ONNX Runtime's folding turns the Focus slices into SpaceToDepth;
    converter added (`pixel_unshuffle` + channel regroup, rank <= 5, no shape arithmetic; equals ONNX's
    definition exactly).
  - efficientdet_lite0: Resize scale 1.6666666 on 3x3 -> 4.9999998, floored to 4 by ONNX (TensorFlow
    meant 5). `resize_scales_to_sizes()` swaps in explicit sizes (3 layers) in the converter and in the
    cut used as reference; the cut no longer stores inferred shapes (they kept the wrong 4x4).
  - The 8 YOLOs now end at (1,255,H,W) like the HEFs.
- ONNX check (check_decoded.py) of the 129 older packages: 117 pass. Real problem: efficientnet_s
  (TFLite route) - Core ML output unrelated to ONNX (cosine 0.00003, "can opener 100%"). The other
  "fails" are mostly the checker: yolov8 pose taken as heatmap pose, scdepthv3/segformer taken as anchor
  YOLO, stdc1/yolo26/dncnn only compared by cosine (0.996-0.999). To look at: yolov8l scores p99 0.18
  (Neural Engine), deeplab_v3_mobilenet_v2_wo_dilation 98.2% pixel agreement.
- Stick check (native-map) of 110 packages. Stick vs Core ML difference is 0.02-0.6 x stick spread
  (8-bit quantization on the chip; resnet_v1_18, accepted earlier, is 0.186).
  - Decoded results agree: classifiers (same top-1 for nearly all; swin_small/tiny and efficientnet_lite3
    swap the top two, both fig/Granny Smith), yolov5m_6.1 5/5 IoU 0.95, yolov5s_c3tr 5/5, yolov6n,
    OBB x3 (41-44 objects, same classes), scrfd_2.5g/500m 2/2 faces, mspn, person_attr, zero_dce.
  - Raw outputs only (no ugen decoder): damoyolo x3, centernet x2, centerpose, yolact x2, retinaface,
    re-ID, landmarks, depth, vit_pose, many tasks mapped to "classification".
  - ugen problems (stick side, not the conversions): inputs not 8-bit RGB (dncnn3 gray, espcn x2/x3/x4
    Y channel, efficientformer_l1 16-bit); detection layouts native-map does not know (efficientdet
    lite1/2, nanodet x2, ssd_mobilenet v1/v2, yolox x4, yolov6n nms_core); on-chip seg NMS (yolov5*_seg_hpp
    x3); crashes (tiny_yolov3 NaN->Int, yolov5m6_6.1 index out of range, lightface_slim NaN->Int); CLIP
    text encoders x5 + minilm need token inputs; centernet_resnet_v1_18 class heatmap 156x (cut differs).
  - Stick shows ~0.1% flat for efficientnet_l/m and mobilenet_v2_1.0: the stick output is already a
    probability and gets softmaxed again in ugen's display (Core ML side matches ONNX).

### Step 77. Signing restored; both apps rebuilt with the 216-model catalog and installed (2026-11-19)
- First build: "Your account already has an Apple Development signing certificate for this machine, but
  its private key is not installed in your keychain" (key lost with the Mac reset). The user added a new
  Apple Development certificate in Xcode > Settings > Accounts > Manage Certificates; Xcode would not
  remove the old one, which is not needed.
- Artelico: `xcodebuild -project Artelico.xcodeproj -scheme Artelico -configuration Release
  -destination 'generic/platform=iOS' -derivedDataPath build-next -allowProvisioningUpdates
  -allowProvisioningDeviceRegistration build` -> installed on iPad and iPhone (216 models in catalog).
- Hailo Studio: same with `-project UGenProbe.xcodeproj -scheme UGenProbe -derivedDataPath build-iphone`
  -> installed on the iPad. iPhone refuses it ("not made for this device"): iPad-only on purpose, iOS on
  iPhone does not offer third-party DriverKit drivers (step 51).
- Main batch finished: 209 Core ML packages. Still failing: siglip2_l_16_256_text_encoder (external
  weights `.onnx.data` "not regular file"), yolo_world_v2s ("Dynamic value of min/max", a Clip with
  computed limits).
- Second copy (`native/copy-list-2.txt`, 40 models that passed both the ONNX and the stick check and have
  an app decoder: 34 classifiers, yolov5m_6.1, yolov5s_c3tr, yolov6n_0.2.1, yolov11 n/m/x obb,
  scrfd_2.5g/500m) to iPad and iPhone.

### Step 78. Pose examples in Artelico (on the device's own chip, no stick) (2026-11-19)
User: build the UGen300 demos into Artelico, "first focus without HAILO, just pure metal", category by
category, "only come back when all is completed". Category 1: the six pose demos.
- `UGenKit/Sources/StudioCore/PoseGames.swift`: the demos' rules ported (Y2 gesture + anti-flicker state
  machine, Y4 hand-raise count, Y3 air-instrument zones, Y5 six yoga poses + hold timer + random round,
  WakeUp squat counter, Classroom attention: raised/head down/head on desk/turned/phone with hold times,
  phone-to-person assignment, 3x3 seat map). `BodyPose` puts a pose in the demos' pixel space (640 wide
  for Y*, 1280 for Classroom) so their tuned thresholds apply. `Pose`/`Keypoint` got public inits.
- `UGenKit/Tests/UGenKitTests/PoseGamesTests.swift`: 22 tests (the demos' own test_gesture_logic.py and
  test_attention.py ported, plus counter/instrument/yoga/squat). All pass (`swift test --filter PoseGamesTests`).
- Artelico `App/Examples/`: PoseKit.swift (ToneSynth: synthesized notes/chime/alarm with AVAudioEngine;
  PoseRunner: front/back camera or video, pose model on Core ML, tracking, mirrored for the front camera,
  optional second model; PoseStage, ExampleLayout that stacks when the width is short), SlidesExample
  (built-in deck or any PDF), MovementExamples (air instrument, yoga), RoomExamples (squat alarm with a
  time, a notification as reminder and screen kept awake; classroom with phone detection via a second
  model, seat map, rule switches, 60 s attention chart). Sidebar group "Body and pose". `-section
  slides|handcount|air|yoga|squat|classroom`, `-posesample bus.jpg` (still picture), `-autostart`.
- Checked on the iPad with the bus picture: 4 people found, 0 hands up, 100 % attention, yoga hint,
  air-instrument strips and notes; screenshots `logs/pose-examples/`. iPhone layout checked in the
  simulator (iPhone 18 Pro Max sim; the simulator's Core ML output is garbage and 1 fps - layout only).
  Installed on iPad and iPhone. Not yet tried by me with a person in front of the camera.

### Step 79. Object examples in Artelico: head count, traffic count, missing check, plate gate (2026-11-19)
- `StudioCore/DetectionGames.swift`: the demos' CentroidTracker (IoU, then centre distance) and
  LineCounter (each id once, up/down per class), MissingCheck (baseline of kinds, 8-frame presence window,
  missing/extra, people ignored by default), PlateText.normalize (the demo's Taiwanese formats plus
  Portuguese AA-00-AA / 00-AA-00 / 00-00-AA / AA-00-00; two separators -> Portuguese first; O/0
  restored in letter pairs), GateBarrier (+ `display(now:)` for drawing without changing state).
  `DetectionGamesTests.swift`: 7 tests (the demo's test_traffic_logic.py ported + new). 29 example tests pass.
- Runner generalised: `PoseRunner(task: .detection)`; sources now also "Stream address" (with Artelico's
  road-camera list) and "Photo"; `extra:` models loaded next to the main one (OCR for plates); `paused`
  (head count's Freeze).
- `App/Examples/DetectionExamples.swift`: Head count (median of 3, peak, 60 s chart, freeze, confidence
  slider), Traffic count (tracks with trails, movable line, per-class up/down, per-minute rate, CSV log
  via share), Missing check (Remember/Forget, banner red/yellow/green, beeps as in the demo), Plate gate
  (vehicles -> TextReader on each vehicle box or the whole photo -> plate check -> animated barrier,
  editable allowed list, log). Sidebar group "Objects"; `-section headcount|traffic|missing|plates`.
- iPad check with samples: traffic tracks 5 people + bus; missing check sees "bus"; plate gate read
  ABC-1234 from plate_sample.png, allowed, barrier opened. Track labels fixed after ("Peopl #1").
- One screenshot (head count) caught another app the user was using on the iPad (VBoxPad): deleted
  unviewed-for-content. The user is using the iPad: no more launches/screenshots there for now.

### Step 80. Faces, hands and pictures examples (2026-11-19)
- Face check-in (FaceCheckIn demo): `FaceGallery.confidentMatch` (best sample per person; refused when the
  runner-up is within 0.08 and also over the threshold), `FaceGallery.average` (enrolment vector),
  `CheckInBook` (0.6 s seen in a row; 3 s quiet after a reset). App: countdown 3 s, then 5 samples of the
  locked largest face (every 3rd frame, IoU >= 0.3, at most 6 s), averaged and stored in the app's face
  list (vectors only, no photos); welcome banner, list, CSV export, threshold slider, similarity display.
  Runner: `PoseRunner(task: .face)` runs FaceRecognition.describe each frame.
- Hands (HandDemos: GestureCaption, FruitNinja, AirBand): `StudioCore/HandGames.swift` - HandCrop (square
  along the forearm past the wrist, 1.1 x forearm), HandSigns.classify (the demo's geometry: 0-5, OK,
  finger heart, thumbs up/down, rock, pinky) + SignSmoother, FruitGame (gravity, fast-stroke cut > 250 px/s,
  bombs -5, 30 s rounds, best kept), AirBand (drums/piano/guitar zones and triggers). `HandGamesTests` 7.
  App: `HandKit.swift` HandReader (crop 224 x 224 from the unmirrored camera picture -> hand_landmark_lite
  -> the 63-value output in pixels, mapped back), HandLayer; screens Hand signs (big emoji captions, a
  checklist of signs seen), Fruit ninja (emoji fruit, blade trails), Air band (zones, piano keys, drum
  levels, chords; synthesized piano with 4 harmonics, Karplus-Strong guitar, kick/snare/hi-hat).
- Photo restore (PhotoRestore demo): `StudioCore/PhotoRestore.swift` - tiled picture-to-picture runner for
  any tile size and scale (zero_dce 600x400, dncnn_color_blind 481x321, real_esrgan_x2 512 -> 1024),
  margins dropped so no seams; the demo's brightness cap and blend. `PhotoRestoreTests` 4 (a fake x2 model
  through 40 px tiles gives an exact copy). App: photo or sample, steps + strengths, before/after slider,
  save/share; photos reduced to 1024 px first.

### Step 81. Language examples (2026-11-19)
- `StudioCore/LanguageGames.swift`: Nutrition (the demo's forgiving JSON parser: fences, quotes, unquoted
  keys, trailing commas, Chinese/English key names, truncated arrays; Python-style rounding; JSON booleans
  are not amounts) + DailyLog (file, resets each day); CodeBlocks (split/last/textOnly, streaming-safe);
  MeetingNotes (the demo's English system prompt, worked example, three-section check); ModelText
  (removes Qwen3 <think>). `LanguageGamesTests` 14 (demo tests ported).
- App `LanguageExamples.swift`: PictureSource (camera with self-timer, or photo), GGUFPicker,
  `StudioModel.stream` (system + user + optional picture, Qwen3 /no_think, cancellation stops llama.cpp);
  Outfit advisor, Fridge chef (presets + own question), Calories (table, totals, today's log), Face style
  report (descriptive only: no attractiveness scores - a deliberate change from the demo, to raise with the
  user), Offline code (Qwen2.5 Coder 1.5B added to the GGUF list: Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF,
  q4_k_m, 1066 MB, Apache-2.0; JavaScript runs in a throwaway WKWebView with CSP default-src 'none',
  10 s limit), Meeting notes (record or audio file or sample -> WhisperKit -> notes, one retry if the
  three sections are missing).
- JavaScript sandbox checked in the simulator (`-jstest`): output and return value, errors, endless loop
  stopped at the limit, fetch blocked ("Load failed"), runner fine after a stop.
- Sidebar groups now: Examples, Body and pose, Objects, Faces, Hands, Pictures, Ask the models.
- Full UGenKit suite: 142 tests, 0 failures (SmokeTests expected 61 models; updated to 216).
- Release build installed on the iPad. Not yet: iPhone install and copying hand_landmark_lite, zero_dce,
  dncnn_color_blind (`native/copy-list-3.txt`) - both devices locked/asleep at the end.
- Not covered: EdgeVsCloud (measures the stick against the cloud: belongs to the Hailo Studio pass).
- Not tried by me with a real person in front of a camera, real speech or a downloaded GGUF model on the
  devices (the iPad was in use by the user; iPhone screenshots are off-limits).

### Step 82. Demo screens in Hailo Studio too; checks on the stick (2026-11-20)
- iPhone: Artelico installed (the earlier attempt failed, phone locked); `native/copy-list-3.txt` copied to
  both devices; then every converted model the devices lacked (user: both have 2 TB): iPhone 148 files,
  iPad 147, no failures. All 209 Core ML packages are now on both.
- Plate gate, Head count, Missing check: "Samples" menu next to "Choose a photo" (bundled plate_sample.png,
  bus.jpg); the sample starts the example at once. Plate gate: the same plate is logged once per 30 s (the
  barrier still reopens for a car that stays, as the demo).
- Shared examples: `Artelico/App/Examples` is compiled into both apps (UGenProbe/project.yml adds the
  folder). `Examples/ExampleHost.swift` lists what the examples need from the app; each app's
  `App/ExampleSupport.swift` provides it:
  - Artelico: Core ML (`loadExtra` = CoreMLEngine.load primary false), llama.cpp GGUF models, WhisperKit;
    `canUse` = the package is on the device.
  - Hailo Studio: everything on the stick: vision models (`loadExtra` = UGenDevice.addModel, downloading
    the HEF first), chat models (Qwen2.5-1.5B, Qwen3-1.7B, Llama3.2-1B, Qwen2.5-Coder-1.5B), Qwen2-VL-2B
    for picture questions (instructions put in front of the question), Whisper-Base; every example call
    clears the stick's context first; `canUse` = on the iPad or downloadable (HEFs download on first use).
  - Examples no longer name Core ML, GGUF or Artelico (`ExampleApp.name`, `StudioModel.examplesRunOn`).
  - HandPoints/HandReader moved to StudioCore (HandGames.swift) so the CLI checks the same code.
  - Hailo Studio sidebar has the same groups as Artelico; StudioModel.enroll(_:embedding:) added.
- New demo: Edge vs cloud (EdgeVsCloud) in both apps (group Objects, `-section edgecloud`):
  `StudioCore/EdgeCloud.swift` (the demo's figures: cloud = 2 x connect time + 250 ms, US$1.5 per 1000,
  month = 8 h x 22 days, 2.5 W stick vs 300 W GPU) + `EdgeCloudTests` 3; the screen measures the model time
  per frame (PoseFrame.inferenceMilliseconds), FPS and frames, and the connect time to 1.1.1.1:443 every
  2 s (Network framework; nothing is sent).
- Stick fix: denoising models take their input in the HEF's quantization (dncnn_color_blind: zero point 46,
  scale 1.585); plain pixels came out too bright (output mean 1.03 vs Core ML 0.84). `UGenDevice.stickInputs`
  rescales q = pixel / scale + zero point for `image_denoising` models -> stick and Core ML differ by 1.7/255.
  Classifiers with such inputs (davit, cas_vit, efficientnet_lite, swin, person_attr) were measured with and
  without: top-1 the same either way, small changes both ways, so left as they were.
- `ugen examples [vision|language]`: the screens' stick steps on samples, vision also with Core ML on the Mac.
  Vision 7/7 pass: pose (4 people both, keypoints 0.005 apart), hands (thumbs_up.jpg, MediaPipe's gesture
  sample, now in testdata/samples and both apps' Samples: points 0.028 of the square apart, both read
  thumbs up), objects (same counts), plate (ABC-1234 on both), faces (2 and 2, same-face similarity 0.965,
  enrolment on the stick recognises Core ML's), zero_dce (0.83/255), dncnn (1.68/255 after the fix).
  Language 5/5 on the stick: Whisper (sample transcribed), meeting notes 4.9 tok/s with the three sections,
  offline code 6.8 tok/s with a JavaScript block (the 1.5B model's program printed the primes below 20,
  not the first 20), calories 5.3 tok/s (Qwen2-VL looped "apple" 12 times on 8 apples; frequency penalty
  1.1 gave one apple, 1.3 broke the numbers: defaults kept, as the demo), picture question fine.
  `ugen examples hands <pictures>` and `ugen examples raw <model> <picture>` for looking closer.
- Hand reading note: on victory.jpg the pose step puts the square below the hand (forearm leaves the
  picture), on both engines: a HandCrop limit from the demo, not the stick.
- Hailo Studio (Mac) test hook: `-testshots` with `-api` adds GET /v1/debug/window (a PNG of the app's own
  window); only with that launch argument.
- Hailo Studio (Mac, stick) screen by screen with -autostart and bundled samples, window pictures via the
  test endpoint: Head count (4 people), Traffic count (bus + people tracked), Missing check (bus), Plate gate
  (ABC-1234 read, barrier opened, 15 FPS), Face check-in (2 faces), the six pose screens (14-15 FPS,
  skeletons, yoga round, classroom 4 people), Hand signs (thumbs up from the stick), Fruit ninja, Air band,
  Photo restore (brighten + denoise of room.png in 19.6 s), Edge vs cloud (21 ms per picture on the stick,
  cloud estimate 285 ms with 35 ms measured network: 14x). All worked.
- Found by the screens: examples asked "is the model on this device", which in Hailo Studio is false
  until first use -> `canUse`/`modelLabel` per app (Plate gate refused to read before).
- Installed: Artelico on iPhone and iPad; Hailo Studio on the iPad (not launched: the iPad is in use).
- Unit tests (stick-free filter): 79, 0 failures.
- Next (user): a static-web Artelico, models loaded and run in the browser.

### Step 83. Artelico Web: the app as a static website, models in the browser (2026-11-20)
- `web/` (see web/README.md): plain HTML + ES modules, no build step (no Node on this Mac); dev server
  `python3 web/serve.py` (COOP/COEP for WebAssembly threads). Pinned vendor copies: ONNX Runtime Web 1.30.0
  (1.22 computed yolov8l/x, yolov10x, resnext wrong on WebGPU; 1.30 fixes all but hardnet68), WebLLM 0.2.87,
  Transformers.js 4.3.2 with its ONNX Runtime build.
- Models: `native/tools/export_web.py` takes the graph each Core ML package came from (cut or whole) and
  puts uint8 NHWC input + Model Zoo mean/std in front -> `native/web/<name>.onnx` (207 of 209; 23.7 GB fp32;
  not: all_minilm_l6_v2, clip_vit_l_14_laion2B_text_encoder). The Core ML `.native.json` is rewritten with
  ONNX output names (Core ML renamed them: "var_435", "/a.b" -> "_a_b"; paired by position, sizes checked).
  Browser fixes in the exporter: ceil-mode pooling written as end padding (scrfd: exact, WebGPU 152 -> 13 ms),
  unused ai.onnx.ml opset dropped, IR version 8-10, stored shapes and output sizes cleared (deeplab 513/512),
  old opsets upgraded + shape calculations folded (regnetx_1.6gf). `index.json` lists the models.
- Engine (`web/js/core/engine.js`): port of CoreMLEngine (native maps, NHWC reorder, activations, NMS
  emulation for dflHeads / anchorHeads / boxesThenScores / boxesObjectnessScores); WebGPU with fallback to
  WebAssembly; runs queued (two concurrent runs corrupted the runtime: Plate gate reading while detecting).
  `compare.html` (WebGPU vs WebAssembly, all 208): only hardnet68 differs (r 0.62) -> `backends.json`.
- Decoders and pipelines ported: detection (NMS list, YOLO26), classification, depth, segmentation, pose
  (v8, 26), SCRFD faces + ArcFace alignment, instances (v5/v8 seg), oriented boxes, lanes, OCR (DB + CTC),
  super-resolution; tracker (ByteTrack-style + Hungarian). All-models run (`test.html?checks=all`): 116 checks,
  detection/pose/faces as the stick (yolov8m: bus 0.94 + 4 people, 21 ms; scrfd 2 faces; yolov8m_pose 4 people),
  classifiers mostly Granny Smith/fig on apples; empty or wrong only where no stick-checked map exists yet
  (efficientdet, nanodet, ssd, yolox, some yolov5/v7, yolov12n) - same open list as native-map.
- Pages: Photos, Live, Models (server folder / local folder, keep offline, WebGPU adapter, storage use);
  the 16 vision demo screens (pose, objects incl. Edge vs cloud, Face check-in, hands, Photo restore) and
  Chat, Ask an image, Speech to text + the 6 "Ask the models" demos. Rules ported in `web/js/rules/`;
  the Swift rule tests ported to `rules-test.html`: 74/74 pass (one label wording fixed).
- Checked in headless Chrome (WebGPU): every vision demo page on its sample (screenshots: 20-45 FPS; Plate
  gate reads ABC-1234 and opens; Hand signs reads thumbs up; Edge vs cloud 17 ms vs 275 ms estimate);
  JavaScript sandbox (output, error, endless loop stopped, network blocked); Whisper base on the speech
  sample (correct, 6 s with loading); Qwen2.5 0.5B 13.8 tok/s and meeting notes with the three sections.
- Not checked by me: real camera/microphone use, other browsers (Safari/Firefox WebGPU), phones.
- Phi-3.5 vision (3.9 GB, WebGPU, ~6 tok/s here): describes apple.jpg ("six apples ... grey surface") and
  bus.jpg correctly, but answered the strict calories JSON prompt with "[]" on the apples (a model answer,
  not a page fault). Phone width (390 px) and dark mode checked on Head count.
- Dev server left running on http://localhost:8000/ (python3 web/serve.py).

### Step 84. Artelico on the Mac (Mac Catalyst), tested (2026-11-20)

- Builds and runs as before (the target already had Mac Catalyst): `xcodebuild -scheme Artelico
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath build-mac build` (Xcode via DEVELOPER_DIR).
- Test hook, Debug builds only: `-modelsfolder <path>` uses a models folder without the picker, allowed by
  `App/Artelico-Mac-Debug.entitlements` (temporary sandbox exception for `hailo/native/`). Release keeps the
  plain sandbox. `-chat` runs print `CHAT ANSWER ...` on stderr.
- All 130 models with an API task run through `POST /v1/vision/<task>` on the samples: all load and answer.
  Classifiers 51/52 "minibus" on bus.jpg; detection, pose (4 people), instances, oriented (DOTA), faces (2),
  lanes (3), OCR (GTIN label read), depth, segmentation, CLIP, Real-ESRGAN. Empty detections only where no
  native map exists yet (efficientdet, nanodet x2, ssd x2, yolov5m6_6.1, yolov5s/xs_wo_spp, yolov7_tiny,
  yolov7e6, yolox_s_wide, yolox_tiny). Warm runs 50-460 ms (yolov8s 463, mobilenet_v3 48).
- First load of a big transformer on the Mac compiles it for the Neural Engine (ANECompilerService):
  nextvit_base ~5 min, ocr_det ~23 s; cached by macOS afterwards.
- Fixed: face recognition always ran scrfd_10g by name, so choosing scrfd_500m / 2.5g failed with "No model
  is loaded" (StudioCore `FaceRecognition.describe` now uses the loaded SCRFD size). Fixed: API requests ran
  at the same time and unloaded each other's models (a client giving up on a slow load); both apps' APIs now
  queue vision requests (`inTurn`). 6 concurrent mixed requests: all correct.
- Chat: Gemma 3 1B (llama.cpp, Metal) answered correctly on the Mac.
- Model hosting on Hugging Face agreed; licence list in `native/hf/licences.json` (209 models: 140
  permissive, 61 GPL/AGPL, 6 non-commercial: InsightFace arcface/scrfd + SegFormer, 2 without a licence).

### Step 85. Models on Hugging Face; the apps download them (2026-11-20)

- Repo: https://huggingface.co/helmo/artelico-models (public), revision 81d8dbbaa15167134438e2deeafe4b5abdda8c55:
  209 models, 1110 files, 35.9 GB. `coreml/<name>.mlpackage/` (plain files, no zips: iOS needs no unzip),
  `web/<name>.onnx`, `<name>.native.json`, `manifest.json` (licence, source, every file's size + SHA-256),
  README model card (task, input, sizes, licence per model). Staged by `native/tools/package_hf.py`
  (hard links into native/hf/stage), uploaded in batches of 25 models (huggingface_hub in `.venv-hf`;
  token = HF_TOKEN in ~/.zshrc). Verified: every manifest file present with the right size.
- Licences (`native/hf/licences.json`): 140 permissive, 61 GPL/AGPL, 6 non-commercial (InsightFace,
  SegFormer), 2 without a licence; all uploaded at the user's request, each labelled in the card.
  Artelico is AGPL-3.0 (`Artelico/LICENSE`, `web/LICENSE`).
- Artelico (`App/ModelDownloads.swift`): a missing model downloads on first use from the pinned revision
  (into a staging folder, SHA-256 checked, then moved in). Mac, empty folder: yolov8s 4 s, scrfd_10g +
  arcface 7 s, mobilenet_v3 3 s, all correct. Debug `-redownload <name>` (delete, download, run on bus.jpg,
  Documents/redownload-test.txt) for devices.
- Artelico Web: models from `models/` when the site has them, otherwise from the pinned Hugging Face
  revision (`?models=hf` forces it). Headless Chrome: 208 models listed, yolov8s downloaded + loaded 1.9 s.
- iPhone and iPad: new build installed. Not yet run there (iPhone locked; iPad in use).

### Step 86. Artelico Web as a Hugging Face Space (2026-11-20)

- https://huggingface.co/spaces/helmo/artelico (static Space, free; direct: https://helmo-artelico.static.hf.space).
  Built by `web/tools/build_space.py` into native/hf/space: the vision pages and demos only
  (`<html data-language="off">`, no WebLLM / Transformers.js), models from helmo/artelico-models (pinned
  revision), COOP/COEP via `custom_headers` (crossOriginIsolated true on the direct link).
- Linked both ways: the Space's `models:` lists helmo/artelico-models; the model card links the Space.
- Live check (headless Chrome): 208 models from Hugging Face, Plate gate reads ABC-1234 and opens, 40 FPS.
- Road-camera hint removed from the web Traffic count (road cameras stay in the native apps only).
  Fixed: loading a sample photo now updates the source picker (stream box no longer shown with "Photo").

### Step 87. Artelico and the web show only their own models (2026-11-20)

- StudioCore `ModelCatalog.only` (optional set; `everything` = the whole table). Artelico sets it at launch
  from `App/artelico-models.json` (the 209 models in helmo/artelico-models, written by package_hf.py);
  Hailo Studio leaves it nil and keeps every model. Gone from Artelico: hailo_yolov8n_4_classes_vga,
  paddle_ocr_v5_mobile_*, siglip2_l_16_256_text_encoder, ssd_mobilenet_v1_visdrone, yolo_world_v2s,
  yolov11s_obb. Model list "Not available" row removed. Mac: API lists 209, Photos defaults to a real model.
- Web / Space: menus list only models that load here (no greyed "(not available)" entries). Live Space:
  68 menu entries, none Hailo-only. Builds: Artelico Mac + iOS, Hailo Studio iOS; installed on iPhone + iPad.

### Step 88. Space: real cameras, Hailo's demo videos (2026-11-20)

- Web camera: "Front camera" / "Back camera" replaced by one "Camera" source with a menu of the cameras
  the browser sees (a computer's webcams by name, a phone's front and back), remembered; screens' order
  still picks the default facing on phones. Mirrored when the camera faces the user (webcams). Switching
  camera / video while running reopens the source. Traffic count opens on the camera (not a stream).
- Hailo's demo videos (hailo-apps resources, S3 resources/video/, MIT © Hailo) in web/samples/videos/
  (11 files, 221 MB) and in the "Samples…" menus (`js/ui/hailo-videos.js`, marked "(Hailo)"): Head count
  / Edge vs cloud (street, office), Traffic (drive, aerial, street), Missing (office, parcels), Squat
  (gym squats), pose demos (office, street), Face check-in (face), Live (all). Credit on the Models page
  and in the Space README. Checked: squats 5/5 at 30 FPS (live Space too), traffic counts a car, head
  count 10 now / 13 peak. Plate gate does not read the dashcam's small US plates, so that video is not
  offered there.

### Step 89. Space: samples load inside the Hugging Face page; credit tags (2026-11-20)

- Bug (user report): in the Space embedded on huggingface.co, Photos stayed empty and Run did nothing.
  Space binary files redirect to the HF file CDN, and with COEP require-corp a no-CORS <img> from there is
  blocked ("Cannot read samples/bus.jpg"). `loadImage` now uses crossOrigin="anonymous" (the CDN sends
  access-control-allow-origin: *); Run without a picture says so. Checked inside the real HF page
  (headless Chrome, attached to the Space iframe): bus + 4 person, 1 bus after ~10 s incl. the 91 MB model.
- Credit tags (`js/ui/credits.js`): while a bundled sample is the source, a tag on the picture/video names
  its source with a link: Hailo (hailo-apps, MIT) for the videos and most pictures, UGen300 demos (MIT) for
  plate_sample.png, Google MediaPipe (Apache-2.0) for thumbs_up.jpg; hidden for the camera and own files.
  Space README credits list every file.
- Space edition (`<html data-edition="space">`): the Models page has no "Online models" / "A folder on this
  computer" buttons (the Space always uses helmo/artelico-models); the local site keeps them.

### Step 90. Hailo's demo videos and sample credits in the native apps (2026-11-20)

- Videos uploaded to helmo/artelico-models `samples/videos/` (revision 71694465b3bcc0d4499ceee2243d428d40735b8b).
- Shared `Artelico/App/Examples/SampleMedia.swift` (both apps): the videos, credits per file (Hailo /
  UGen300 demos / MediaPipe), `localVideo` (downloads once to Application Support/sample-videos), and
  `CreditTag`. PoseControls: "Samples" menu with pictures and videos for every demo (head count, traffic,
  missing, edge vs cloud, face check-in, squat, classroom, air instrument, yoga, raise hand, hand counter);
  the stage shows the credit tag while a sample plays. Live (both apps): "Samples" next to "Choose a video".
  Photos (both apps): credit tag on sample pictures. Local video files now loop (StreamSource) instead of
  stopping at the end. Debug `-samplevideo <file>` plays a demo video when an example opens.
- Checked: Mac Head count on the street video (peak 11), Squat alarm on the gym video with skeletons and the
  credit tag; iPhone downloaded grok-squats.mp4 (same MD5 as the original). Installed: iPad Artelico +
  Hailo Studio, iPhone Artelico (iPad not launched: in use).

### Step 91. Mac disk images (2026-11-20)

- `tools/make_dmg.sh [artelico|hailo]`: Release Mac Catalyst builds packed as drag-to-Applications disk
  images: dist/Artelico-1.0.dmg (15 MB), dist/Hailo-Studio-1.0.dmg (43 MB). Verified: checksums valid,
  each holds the app + an Applications link, signatures valid, arm64 (Apple silicon only).
- Signed "Apple Development" (the only certificate here): runs on this team's registered Macs; Gatekeeper
  rejects it elsewhere. Sharing needs a "Developer ID Application" certificate + notarization.

### Step 92. Download all, home-folder models, 2 FPS fix, decoders started (2026-11-20)

- Artelico Device and models: "Download the N models the app runs" and "Download all N models" (one after the
  other, Stop, failures named at the end, screen kept awake). `StudioModel.downloadAll(onlyUsable:)`.
- Mac default models folder outside the sandbox container: Artelico `~/.artelico/models`, Hailo Studio
  `~/.hailo/models` (temporary-exception home-relative entitlements; earlier container models move over once).
  Checked: Artelico downloaded + ran mobilenet_v3 there; Hailo Studio moved its 140 HEFs there.
- 2 FPS on hand screens (user, iPad/iPhone): the device builds were Debug, and StudioCore's per-value loops
  (Core ML output reorder/quantize, pixel conversion) run ~50x slower unoptimized. `ugen native-bench
  <pose model> <picture>` (Core ML only): Debug 725 ms/frame (1.4 FPS), Release 13.5 ms (74 FPS).
  Fix: Package.swift compiles StudioCore/UGenKit with -O (CUGenRT -O2) in Debug too -> Debug 14 ms (72 FPS);
  Release builds installed on iPad (Artelico, Hailo Studio) and iPhone (Artelico).
- Web: pose screens list yolov8s_pose / yolo26n / yolo26s first (was yolo26m_pose). Mac Chrome WebGPU 31 FPS.
  Not yet measured on WebAssembly / iPad Safari. Space not rebuilt yet.
- Decoders (not yet checked on the stick: it stopped answering, even `ugen identify` hangs; unplug/replug):
  `PostProcess+Detectors.swift` (anchor YOLOv3/tiny, YOLOv4 split, DAMO-YOLO, CenterNet, DETR, bbox-decoding-only),
  `PictureModels.swift` (any picture-in/picture-out model: espcn Y channel, zero_dce(_pp), dncnn(3), real_esrgan)
  and a new task `.enhancement` ("Brighten or clean up", catalog tasks low_light_enhancement + image_denoising;
  `VisionTask.catalogTasks`, used by `ModelCatalog.models(for:)`).

### Step 92. Check of the separate session's changes; DMGs rebuilt (2026-11-20)

- Present in the code: Download all (ModelDownloads/DeviceView/StudioModel); Mac models folders
  ~/.artelico/models and ~/.hailo/models (140 models there) with the home-relative sandbox exceptions in
  all three Mac entitlements; UGenKit always optimised (-O / -O2 in Debug); `ugen native-bench`; web pose
  default yolov8s_pose; PostProcess+Detectors.swift, PictureModels.swift and the `enhance` task.
- UGenKit: swift build OK, swift test 145 tests, 0 failures (17 skipped).
- dist/Artelico-1.0.dmg and dist/Hailo-Studio-1.0.dmg rebuilt (tools/make_dmg.sh). Artelico run from the
  mounted image (Release): entitlement /.artelico/ present, `enhance` offered, zero_dce and
  dncnn_color_blind downloaded into ~/.artelico/models and ran; zero_dce on bus.jpg darkened to mean 25
  -> mean 150, natural colours. Hailo Studio from the image not run (needs the stick).

### Step 93. Model list: helpers, unused, language models; memory readout (2026-11-21)

- Artelico Device and models: no more "not decoded yet" on every row. Helpers the app uses beside a main
  model say what for (`DeviceView.helperRoles`: arcface_mobilefacenet face recognition, ocr text reading,
  clip_vit_b_32_text_encoder tagging, hand_landmark_lite hand demos, all_minilm_l6_v2 Assistant tools).
  The 51 models no screen runs yet are in one "Not used by the app yet" section at the end (other
  CLIP/SigLIP/TinyCLIP encoders, arcface_r50, retinaface, lightface, YOLACT, YOLO26-seg, yolov5 *_hpp seg,
  ViTPose, MSPN, CenterPose, FastSAM, re-ID, attributes, 3DDFA, R3D, UNet, deeplab_v3_mobilenet_v2).
  "Download the models the app runs" now includes the helpers (`StudioModel.runs`).
- New "Language models (GGUF)" section: the 7 GGUF models with download / delete / progress per model and
  "Download all N language models" (one after another, Stop); they come from their makers' HF repos.
- Memory (`Examples/MemoryInfo.swift`, both apps): app footprint (task_vm_info phys_footprint, every 2 s),
  on iOS what is left before the system closes the app (os_proc_available_memory), device total, and what
  is loaded (vision model, language model, Whisper). Mac: 168 MB with yolov8m loaded.
- Release builds installed: iPad Artelico + Hailo Studio, iPhone Artelico; DMGs rebuilt.

### Step 94. Hands: upright crops, hand-present check, smoothing; Fruit ninja Play (2026-11-21)

- User reports: Hand signs detect poorly, hand lines shake on a still hand; Fruit ninja's Play does nothing.
- hand_landmark_lite outputs identified on test crops: fc4/Sigmoid_1 = hand present (0.98 on the hand,
  0.001 on a wall), fc2/Sigmoid = handedness (flips when mirrored). A thumbs-up turned 90 degrees drops to
  0.17: the model wants upright hands (MediaPipe turns its crops).
- `HandReader.read` (StudioCore): the square is turned along the forearm so the hand points up
  (`HandCrop.uprightAngle`, `RotatedSquare`, `RGBAPixels.crop` in new HandSteadying.swift), points are turned
  back; squares scoring below 0.5 "hand present" are dropped (the hidden left hand on thumbs_up.jpg: 0.16,
  before it gave 21 random points and phantom signs); optional `HandSmoother` damps the square (35% follow,
  jumps on big moves) and One-Euro-filters the 21 points (min cutoff 1 Hz, beta 0.02, in pixels). PoseRunner
  keeps one smoother. Measured (Core ML, wrist nudged +-4 px per frame): still hand moves 0.81 px/frame
  without smoothing, 0.11 with. thumbs_up turned 270 degrees: read with 0.985 presence (forearm at -143).
  At 90/180 degrees the pose model misplaces the wrists (not a hand-crop issue). `ugen examples hands`:
  stick and Core ML both read thumbs up. swift test: 148 pass (3 new).
- Fruit ninja: the field had `.id(tick)` (new view every frame) around the Play button, so taps were lost;
  only the fruit and trails are re-created per frame now.
- Installed (Release) on iPad (Artelico + Hailo Studio) and iPhone (Artelico) with the hand and Fruit ninja fixes
  (the face family's work in progress was in the build; it compiled and swift test passed).
- Web port (`web/js/rules/hand-games.js`): `uprightAngle`, `toPicture`, `OneEuroFilter`, `HandSmoother`, turned
  crop via canvas transform, presence check; `poseAnalysis` keeps one smoother per screen. rules-test 74/74;
  Hand signs on thumbs_up: one hand, Thumbs up, 30 FPS. Space republished (8696a44) incl. the other
  session's yolov8s_pose default; live check: Thumbs up, 30 FPS, models from Hugging Face.

### Step 95. Face detectors, a second face embedder, two more segmentation models (2026-11-21)

Five of the "Not used by the app yet" models now run (stick and Core ML), decoded in StudioCore so Photos,
Live and the REST API get them.
- **Per-channel quantization.** lightface_slim (and tiny_yolov3, yolov3, yolov3_416) quantize each output
  channel with its own scale; hefinfo printed scale 0 for them, so their outputs read as all zeros.
  `tools/hef_feature_quant.py` reads qp_zps/qp_scales from the HEF's protobuf (no Hailo library needed) and
  adds `qpZps`/`qpScales` to models.json (16 outputs). `StreamInfo` has them; the stick's tensors with them
  come out as float32 (`Tensor.withPerChannelDequantized`, in UGenDevice.collect and CapturedRun), Core ML
  keeps them float32. Fitting the stick's bytes against the ONNX outputs gave the same zero points (118, 164).
  Side effect: tiny_yolov3 / yolov3 now find bus.jpg's people and bus on the stick (they found nothing).
- **RetinaFace / LightFace** (`PostProcess+AnchorFaces.swift`): the Model Zoo's FaceDetectionPostProc
  (SSD priors, variances 0.1 / 0.2, softmax face score, NMS). Anchors from cfg/base/retinaface.yaml (strides
  8/16/32, sizes 16,32 / 64,128 / 256,512) and lightface_slim_base.yaml (8/16/32/64; 10,16,24 / 32,48 /
  64,96 / 128,192,256); centres (column + 0.5) x stride, as in the Ultra-Light original (for LightFace's
  last row of the 240-pixel input the Zoo's /grid would differ slightly). Thresholds 0.5 / 0.6 (the Zoo's
  0.02 / 0.1 are for mAP). Recognised by output layout (`PostProcess.faceAnchors`); `PostProcess.faces`
  picks SCRFD or anchors. Python reference (Zoo formulas, numpy) on the captured stick bytes and on ONNX:
  bus.jpg RetinaFace 0.998 / 0.995 (ONNX 0.995 / 0.984), boxes within 1-2 px, eye landmarks within 1 px;
  LightFace 0.970 / 0.783 (ONNX 0.973 / 0.836). Swift: same 2 faces on stick, Core ML and Artelico's API.
  `lightface_slim.native.json` created with `ugen native-map` (new file: the HF repo needs it).
- **LightFace has no landmarks**, and ArcFace only works on faces aligned by eyes, nose and mouth. So
  `FaceRecognition.describe` returns LightFace faces with an empty embedding: Photos / Live show their boxes
  without names (re-identification skips them, "Remember this face" says to choose SCRFD or RetinaFace),
  and Face check-in only offers detectors with landmarks (`FaceRecognition.findsLandmarks`). describe now
  uses whichever face detector is loaded (SCRFD, RetinaFace, LightFace), else scrfd_10g.
- **arcface_r50**: choice of embedder `FaceRecognition.embedderName` (default arcface_mobilefacenet),
  "Recognition model" picker (`Examples/FaceEmbedderPicker.swift`) in Photos' Known people (both apps) and
  in Face check-in (locked while running). Each embedder has its own list (`FaceGallery.embedder`,
  faces.json for MobileFaceNet as before, faces-arcface_r50.json); old lists decode as MobileFaceNet's;
  `recognize` never compares a list with another embedder's vectors. Device list: arcface_r50 is a helper
  ("face recognition, when chosen"). `ugen examples vision` now checks three pairs (all PASS):
  scrfd_10g + mobilefacenet: same face stick vs Core ML >= 0.965, the two people -0.215;
  scrfd_10g + r50: >= 0.930, different 0.111; retinaface + mobilefacenet: >= 0.903, different -0.059.
  Mirrored, cropped, scaled bus.jpg vs bus.jpg (`ugen faces --embedder ...`): same person 0.76 / 0.65
  (MobileFaceNet), 0.82 / 0.74 (R50); different people <= 0.14 / 0.11.
- **Segmentation**: deeplab_v3_mobilenet_v2 (21 Pascal VOC scores per pixel; the HEF says NCHW but the
  stick hands out NHWC, checked: NCHW reading gives noise) and unet_mobilenet_v2 (3 scores: TF tutorial's
  Oxford pet trimap, labels_offset 1 -> pet, background, pet outline) were rejected because supports()
  wanted a one-channel argmax map. `PostProcess.segmentation(_:model:)` takes the argmax on raw values.
  Class sets per model (`SegmentationLabels.swift`: VOC with its colour map, pets, Cityscapes); the map
  carries labels, colours and a background class, which pictures leave untinted. This also fixes
  deeplab_v3_mobilenet_v2_wo_dilation, which was labelled with Cityscapes names (it is VOC). dog_bicycle.jpg:
  deeplab background/bicycle/car/dog, 98.8% of pixels as ONNX; unet pet + outline around the dog, 99.7%.
  Core ML the same classes (ugen native-map, Artelico API).
- Tests: FaceAndSegmentationTests (6). swift test 154, 17 skipped, 1 failure in HandGamesTests'
  OneEuroFilter noise test from Step 94 (random input; failed on 3 of 4 runs here, spread 0.64 vs limit
  0.56-0.59; not mine, not touched).
  Artelico (Mac) and Hailo Studio (iOS) build. Not done: Artelico Web (JS decoders) for these models.

### Step 96. Instance segmentation: YOLO26-seg, YOLACT, YOLOv5-seg "hpp", FastSAM (2026-11-21)

Ten more of the "Not used by the app yet" models run (stick and Core ML), decoded in StudioCore.
- **Decoders** (`PostProcess.instances` picks by output layout; masks are built by the existing prototype code):
  - YOLO26-seg (`yolo26SegCandidates`, PostProcess+YOLO26.swift): the YOLO26 detection tensors (4 box
    distances, class logits) plus 32 coefficients per stride; class-wise NMS 0.7. `ValueReader` (was
    Y26Reader) moved to PostProcess.swift for sharing.
  - YOLACT (PostProcess+YOLACT.swift): 5 grids x 9 anchors (scales 24 x 2^level x 2^(k/3), ratios 1, 0.5, 2
    from cfg/base/yolact.yaml), SSD offsets with variances 0.1/0.2, softmax over 81 (0 = background),
    coefficients tanh'd on the chip (the .alls script), NMS 0.5 per class. My priors equal the source
    ONNX's own prior output (max diff 5e-8). The Zoo feeds YOLACT stretched pictures (mobilenet_ssd
    preprocessing), so `VisionPipeline.prepare` stretches for YOLACT (`isYOLACT`); bus.jpg then also finds
    the half-visible fifth person.
  - YOLOv5-seg "hpp" (PostProcess+ByteMask.swift): the stick runs Hailo's YOLOv5-seg post-processing and
    returns HailoRT's NMS_WITH_BYTE_MASK buffer: UInt16 count, per detection a packed 46-byte header
    (y_min, x_min, y_max, x_max, score as Float32, class UInt16, mask size, an unused pointer and the mask
    offset as UInt64) directly followed by its mask, one byte per input pixel over floor(x_min*640)..
    ceil(x_max*640) (hailort.h, nms_post_process.hpp; checked: sizes match on all 6 bus.jpg detections).
    Masks are kept at input resolution. `StreamInfo.isByteMaskNMS`. Threshold 0.3 like the other decoders
    (the device's is 0.2).
  - FastSAM: the YOLOv8-seg layout with one "object" score (sigmoid on the chip), so the YOLOv8 path
    decodes it; one-score models give "object 1, 2, ..." with class -1.
- **FastSAM as its own task** `VisionTask.segmentEverything` ("Segment everything", raw value
  segment_everything, catalog task zero_shot_instance_segmentation): it has a catalog task of its own,
  its answer has no class names, and "Instance segmentation" users expect named COCO objects. Result kind
  stays `.instances`, so Photos, Live, the result list and the REST API (/v1/vision/segment_everything)
  work unchanged. The renderer draws class-less instances (class -1) as masks only, largest first (FastSAM
  gives up to 100; boxes and labels made bus.jpg unreadable). Device list and samples (bus, dog_bicycle,
  room) list the new task in both apps.
- **Core ML**: `ugen native-map` maps for yolo26{n,s,m,l}_seg, fast_sam_s (sigmoid on the 3 score outputs,
  found automatically) and the three hpp models. For hpp, the stick has no raw outputs to compare with, so
  native-map describes the Core ML outputs as the plain model's (yolov5n_seg_hpp -> yolov5n_seg layout,
  hpp name) in the map's `model` and compares decoded instances (`nativeMapByteMask`, ugen/NativeMapInstances.swift).
  New activation "tanh" in NativeModelMap / CoreMLEngine / native-map (stick in -1..1, Core ML outside):
  YOLACT's coefficient outputs needed it; the existing yolact_*.native.json had none (re-written).
  native-map now also prints instance matches with mask IoU (256x256 grid over the picture).
- **Measured, bus.jpg, stick vs Core ML** (instances >= 0.3 matched / mean box IoU / mean mask IoU):
  yolo26n 4/4 0.945 0.959; yolo26s 4/4 0.965 0.975; yolo26m 5/5 0.948 0.920; yolo26l 5/5 0.968 0.940;
  yolact_800mf 5/6 0.960 0.938 (stick's extra is a 0.40 person); yolact_1.6gf 4/4 0.966 0.989;
  yolov5n_hpp 4/4 0.909 0.930; yolov5s_hpp 5/5 0.952 0.871; yolov5m_hpp 5/5 0.936 0.880;
  fast_sam_s 85/92 0.946 0.937. hpp stick scores equal the plain yolov5*_seg on the stick (n: 0.88/0.77/0.73/0.72
  vs 0.87/0.72/0.72/0.69).
- **Python reference** (full source ONNX on the captured stick input, Zoo/Ultralytics formulas; masks
  compared at input resolution): yolo26n_seg bus ONNX bus 0.930, persons 0.895/0.784/0.551, Core ML the same
  to 0.01, stick masks IoU 0.959 mean (min 0.946); dog_bicycle stick masks 0.971, Core ML dog 0.52 / cat 0.44
  like ONNX (0.520 / 0.444; the stick says cat 0.56: the model is torn); yolo26s 0.969. YOLACT 800mf stick
  masks 0.868 mean (5 of 6 >= 0.7; the sixth is the weak extra person). FastSAM: 81 of 92 stick masks
  >= 0.7 IoU with a reference mask, top 30 mean 0.902.
- Renders looked at (stick and Core ML via Artelico's API, bus, dog_bicycle, room): masks on the
  objects for all ten; YOLACT masks are blockier (128x128 prototypes); room.png gives many books and
  teddy bears (YOLACT 1.6gf also a carpet-sized "dining table" 0.56).
- `ugen replay ... out.png masks.bin` writes instance masks for reference checks.
- Tests: InstanceSegmentationTests (5: layouts, YOLACT prior box, YOLO26-seg box + mask, FastSAM numbering,
  byte-mask buffer). swift test 160, 17 skipped, 0 failures. Artelico (Mac) and Hailo Studio (iOS) build.
- New files for the Hugging Face repo: yolo26n_seg, yolo26s_seg, yolo26m_seg, yolo26l_seg, fast_sam_s,
  yolov5n_seg_hpp, yolov5s_seg_hpp, yolov5m_seg_hpp `.native.json`; changed: yolact_regnetx_800mf and
  yolact_regnetx_1.6gf `.native.json` (tanh; hard-linked into native/hf/stage/coreml, so the stage copy
  changed too). No .mlpackage or web ONNX changed. Not done: Artelico Web (JS decoders, its engine has no
  tanh) for these models.

### Step 97. Hugging Face: maps of families 1-2 uploaded; apps refresh outdated maps (2026-11-21)

- Restaged (package_hf.py) and uploaded helmo/artelico-models revision 11330bf3211695ebbd27c6486e67afe895b92438
  (1119 files; manifest check: none missing, sizes right): new maps lightface_slim, yolo26{n,s,m,l}_seg,
  fast_sam_s, yolov5{n,s,m}_seg_hpp; fixed yolact_regnetx_{800mf,1.6gf} (tanh). Pinned in
  Artelico/App/ModelDownloads.swift and web/js/core/source.js.
- `StudioModel.refreshModelMaps()` (ModelDownloads.swift), run at launch: for installed models, a missing
  `.native.json` or one whose SHA-256 differs from the manifest is fetched again (packages untouched).
  Checked on the Mac: a folder with only lightface_slim.mlpackage got its map at launch; 2 faces on bus.jpg.
- Also: Fruit ninja fruit size (Normal/Big/Huge, default Big) and speed (Slow/Normal/Fast) in both apps and
  the web/Space; `FruitGame.size/speed`; One-Euro test made deterministic. swift test 160 pass.

### Step 98. Pose: ViTPose, MSPN (person crops after a detector) and CenterPose (2026-11-21)

Four more of the "Not used by the app yet" models run for "Pose estimation" (stick and Core ML), giving the
usual `.poses`, so Photos, Live, the REST API, the renderer and the pose demos take them unchanged.
- **Top-down** (`TopDownPose.swift`, `PostProcess+Heatmaps.swift`): vit_pose_small, vit_pose_small_bn,
  mspn_regnetx_800mf take one person (192 x 256) and give 17 heatmaps (48 x 64). yolov8s finds the people
  (person >= 0.4, at most 6 per frame, best first); each box is cut out as the Model Zoo does
  (_bbox_xywh2cs: widened to 3:4, x 1.25; bilinear, black outside, cv2's pixel centres) and the crops go
  through the pose model two at a time (submit/collect). ViTPose: "unbiased" crop (get_warp_matrix) and
  DARK (log heatmap, one Newton step; the Zoo's Gaussian blur there has no effect, cv2's result is thrown
  away). MSPN: classic crop (get_affine_transform), 5 x 5 blur, quarter-cell step + 0.5. Pose box and score
  = the detector's. The two have one layout, so `heatmapStyle` tells them apart by name (mspn*).
  The detector is a companion: `VisionTask.companionModels` became `companionModels(for: model)` (pose ->
  yolov8s for top-down models only); both apps load it in prepare, `needsPipeline(.pose)` is true for them
  (Live then goes through runPipeline -> VisionPipeline.run, which runs TopDownPose), PoseRunner calls
  `TopDownPose.run` (with tracking). Without a detector (`VisionPipeline.prepare/decode`, native-map,
  capture/replay) the whole picture is one person's crop, as the Zoo does without a box.
  `.pose` covers the catalog task single_person_pose_estimation too.
- **MSPN scores**: its heatmap peaks are not probabilities (about 220 where sure); the Zoo's peak / 255 + 0.5
  (a COCO rescoring) put every keypoint above the renderer's 0.5. Score = peak / 170, set against ViTPose
  on the same crop of thumbs_up.jpg (ViTPose 0.5 ~ MSPN 85): bus legs drawn, out-of-frame knees hidden.
- **CenterPose** (`PostProcess+CenterPose.swift`): centerpose_postprocessing.py: 3 x 3 max-pool peaks of the
  centre map (>= 0.3 kept; the Zoo keeps 100 for mAP), box from size + offset, keypoints = centre cell +
  regression, moved to the nearest keypoint-heatmap peak (>= 0.1, inside the box, within 0.3 of its longer
  side). Added: people overlapping a better one by IoU > 0.7 are dropped (two neighbouring cells with the
  same score both pass the max-pool; bus.jpg's half-visible person came out twice). Letterbox padded black
  (the Zoo's warpAffine), not grey.
- **CenterPose wants BGR on Core ML**: its .alls has input_conversion(bgr_to_rgb), so the stick takes RGB and
  swaps on the chip, but the ONNX (and the .mlpackage) were trained on BGR. ONNX + Zoo decode vs the stick
  on bus.jpg: RGB 0.87/0.85/0.72/0.31, BGR 0.87/0.85/0.78/0.37, stick 0.87/0.86/0.77/0.37. New
  `NativeModelMap.bgr` (CoreMLEngine swaps red and blue for image inputs); `ugen native-map` tries both
  orders and takes BGR when clearly closer (centerpose: first output 0.0035 RGB vs 0.0021 BGR; all six
  outputs' errors about halve; stick vs Core ML 3 of 4 people -> 4 of 4). Old apps ignore the key.
- **Checks against the Python reference** (numpy copies of the Zoo's functions + source ONNX,
  scratchpad pose_ref.py): whole-picture crop of thumbs_up.jpg equals the Zoo's (mean |diff| 0.06 of 255);
  the stick's heatmaps decoded by the Zoo code and by Swift: identical keypoints (0.00 px), all three models;
  bus.jpg per-person crops, ONNX + Zoo vs Swift on the stick (visible keypoints): ViTPose 2.1-3.9 px,
  ViTPose-bn 1.6-3.2 px, MSPN 2.3-4.0 px (0.4-0.8% of the box; the half-visible fifth person more);
  CenterPose stick maps + Zoo decode = Swift's people and scores.
- **Stick vs Core ML** (Artelico's API and `ugen examples pose`, bus.jpg / thumbs_up.jpg): same people
  (4 / 1) for all four; keypoints within 0.0025-0.0036 of the picture on average (yolov8s_pose: 0.0039);
  scores within 0.06. Compared with yolov8m_pose: same 4 boxes (IoU 0.86-0.98), visible keypoints mostly 6-11 px
  apart (1.4-2.5% of the person's height; one person 21 px with ViTPose-bn). Renders looked at (stick and
  Core ML, both pictures).
- **Frame times** (`ugen examples pose`, bus.jpg, 4 people, M-series Mac; detector included):
  vit_pose_small 119 ms stick / 20 ms Core ML, vit_pose_small_bn 86 / 23, mspn 50 / 19, centerpose 28 / 17,
  yolov8s_pose 24 / 15. One person (thumbs_up.jpg) on the stick: ViTPose ~50 ms, MSPN ~34 ms. Per crop on the
  stick (ugen bench): ViTPose 22 ms, ViTPose-bn 14 ms, MSPN 5 ms. Kept in the demos' model lists (the default
  stays yolov8s_pose): at most 6 people bounds ViTPose to ~170 ms per frame on the stick. Checked in
  Artelico on the Mac: Squat alarm with vit_pose_small and Yoga coach with mspn_regnetx_800mf on bus.jpg
  (`-section squat|yoga -posesample bus.jpg -autostart -examples.model.pose <model>`), 15 FPS (the still
  source's cap), skeletons on all 4 people.
- ugen: `<task> <model> <image> result.json` and `replay ... out.png result.json` write the result as JSON;
  captures keep the source region (meta.json "region"); `ugen examples pose` (also in `examples vision`).
- Tests: PoseModelTests (5: layouts/companions, DARK sub-cell peak, MSPN step, person crop, CenterPose).
  swift test 165, 17 skipped, 0 failures. Artelico (Mac) and Hailo Studio (iOS) build.
- Maps: new `vit_pose_small_bn.native.json`; changed `centerpose_regnetx_800mf.native.json` ("bgr": true;
  hard-linked into native/hf/stage/coreml); vit_pose_small and mspn maps re-made, unchanged. Both need the
  Hugging Face upload. Until then Artelico's launch-time refreshModelMaps (Step 97) puts the old centerpose
  map back when started with `-modelsfolder native/coreml` (it did here; re-linked from the stage copy).
  No .mlpackage or web ONNX changed. Not done: Artelico Web (JS decoders) for these models.

### Step 99. Pose maps uploaded (2026-11-21)

- helmo/artelico-models revision 36209e79817d5effa096e27cb3625c09b8ce681d: vit_pose_small_bn map (new),
  centerpose_regnetx_800mf map with "bgr": true (checked on HF). Pinned in ModelDownloads.swift and
  web/js/core/source.js. Map refresh at launch is skipped in Debug runs with -modelsfolder (it had put the
  old centerpose map back over the new one in native/coreml).

### Step 100. Faces and people one at a time (attributes, re-ID, 3D landmarks, face mesh) and action in video (2026-11-21)

Seven more of the "Not used by the app yet" models run (stick and Core ML), as five new tasks in StudioCore,
so Photos, Live and the REST API of both apps take them.
- **New tasks** (`VisionTask`): `face_attribute` "Face attributes", `face_landmarks` "Face landmarks" (catalog
  task facial_landmark_detection), `person_attribute` "Person attributes", `person_re_id` "Person
  re-identification", `video_classification` "Action in video". New results: `.described([DescribedObject])`
  (box, detector score, attributes present >= 0.5, re-ID name + similarity; JSON type "described") and
  `.faceLandmarks([FaceLandmarks])` (points, 3DDFA head pose; JSON "faceLandmarks"). Drawn by
  VisionRenderer+Described.swift; ResultList cases in both apps.
- **Crops after a detector** (`CropTasks.swift`, like TopDownPose): faces from scrfd_10g, people from yolov8s
  (>= 0.4), at most 10, as companions (`companionModels(for:)`); crops run two at a time
  (`InferenceEngine.inferEach`, now also used by TopDownPose). Without a detector (prepare/decode,
  native-map, capture) the whole picture is the crop (stretched, as the Zoo's evaluation crops).
  - face_attr_resnet_v1_18: faces aligned on the five SCRFD landmarks onto CelebA's mean landmark spots in
    its 178 x 218 pictures (`FaceRecognition.align` now takes a template and size). 40 (absent, present)
    pairs, softmax (face_attr_postprocessing.py takes the argmax). "Attractive" is never shown.
  - person_attr_resnet_v1_18: box stretched to 224 x 224; 35 PETA logits, present when >= 0 (the Zoo's
    person_attr visualisation), probability = sigmoid. Plain-word labels for both attribute sets.
  - tddfa_mobilenet_v1: 3DDFA_V2's parse_roi_box_from_bbox square (1.58 x, 0.14 down), 120 x 120; 62
    parameters x std + mean, 68 points from the Basel Face Model's landmark rows, similar_transform; head
    pose = 3DDFA_V2 calc_pose. The BFM is not in the 2025 Zoo archive: the 2021-11-28 tddfa archive on
    Hailo's S3 has bfm_noneck_v3.pkl (same file as 3DDFA_V2's configs/, MIT repo; the Zoo asks to accept
    the BFM licence). Its 68-point subset (mean, 40 shape and 10 expression bases, 41 KB float32) is the new
    resource `tddfa_bfm68.bin` (read with a restricted unpickler that only rebuilds numpy arrays).
    The ONNX wants BGR: the .alls swaps on the chip, Core ML needs `"bgr": true` (native-map found it:
    RGB 0.146 vs BGR 0.023).
  - face_landmarks_lite: MediaPipe's ROI: a square 1.5 x the box's longer side, turned so the eyes are level
    (`RotatedSquare` from the hand code), 468 x (x, y, z) in 192-pixel units, face score (sigmoid on the chip).
  - osnet_x1_0 / repvgg_a0_person_reid_512: box stretched to 128 x 256, embedding scaled to unit length.
    `ReIdentification.name`: greedy matching (best pairs first, a name once per picture), up to 8 looks per
    person, new people "Person N". Thresholds: OSNet 0.75 (its vectors are post-ReLU: strangers on bus.jpg
    0.63-0.85), RepVGG 0.6 (strangers 0.2-0.62). The apps keep one gallery for Photos, Live and the API
    (`sessionPeople`), reset when Live starts or with Photos' "Count from 1 again".
- **Video** (`VideoClip.swift`): 16 frames resized to 171 x 128 and centre-cropped to 112 (r3d_18_preprocessing),
  normalised on the host and quantised with the input's zero point / scale (the HEF has no normalisation),
  channel = frame x 3 + colour (checked: the stick then equals ONNX). Live keeps a clip per source
  (`runPipeline(..., liveSource:)`), frames on a 12-per-second beat, an answer with the 16th frame and every 8
  after. Sampling, ONNX on grok-squats.mp4: 24/s "squat" first in 8 of 10 answers, 12/s 8 of 8 (0.69-1.00),
  8/s 4 of 5, 4/s 1 of 2; full_mov_slow.mp4 (driving): 13/s and 8/s "driving car" in 8 of 10 / 7 of 8. A photo (and the REST API's
  one picture) is the frame repeated 16 times: no motion, so approximate (Photos says so). Core ML takes the
  clip as [1, 3, 16, 112, 112]: CoreMLEngine's tensorInput rearranges 5-D inputs. `Labels.kinetics400`
  (labels.json).
- **Checks against the Python reference** (crops cut in numpy independently, source ONNX, Zoo formulas;
  scratchpad crops_ref.py / r3d_ref.py), bus.jpg, stick (Core ML):
  face attributes same set 1 of 2 (2 of 2): the stick adds "young" 0.60 (reference below 0.5), other
  probabilities within 0.25 ("no beard" 0.55 vs 0.80) (Core ML within 0.09);
  person attributes same set 3 of 4 ("sneakers" 0.51 borderline) (4 of 4), max diff 0.06 (0.02);
  3DDFA points 0.28 / 1.41 px mean (0.29 / 0.61) on 36-40 px faces; face mesh 0.23 / 0.36 px (0.03 / 0.04).
  r3d_18 squats, 8 answers: stick and ONNX same top-1 everywhere, probabilities within 0.06; Core ML (fp16)
  same top-1, one answer 0.41 vs 0.70. Renders looked at (stick and Core ML via Artelico's API, bus.jpg and
  walk_in_room frames: landmarks and mesh on the faces, profile face yaw -56).
- **Re-ID** (`ugen reid [--coreml] <model> <images...>`): bus.jpg vs mirrored vs cropped + 20% darker:
  every person keeps the number. Same person: OSNet 0.92-0.99 (Core ML 0.94-0.99), RepVGG 0.84-0.98 (0.89-0.98);
  different people: OSNet <= 0.85 (0.81), RepVGG <= 0.62 (0.62). walk_in_room frames every 2 s: the three
  people keep their numbers (extra "people" are reflections in the TV, also found by yolov8s). Live on
  Core ML (30 s of walk_in_room): 11 numbers for 3 people + reflections (blur and new views split some).
- **Live in Artelico** (new `-livelog` prints each live result; local HLS of the demo videos with -stream):
  r3d_18 on grok-squats: 147 frames, "squat" first in 7 of 8 answers; re-ID and 3DDFA on walk_in_room ~29 FPS.
- **Times** (bus.jpg, detector included): stick face attributes 49 ms (2 faces), person attributes 61 ms (4),
  OSNet 67 ms, RepVGG 54 ms, 3DDFA 47 ms, mesh 52 ms, r3d_18 28-30 ms per clip; Core ML (API) 10-15 ms,
  mesh 79 ms, r3d 11 ms.
- Device list: sections per new task (titles now from `VisionTask.title`), bus.jpg suggested for the four
  crop tasks. ugen: `reid`, `clip [--coreml] <fps> <frames...>`.
- Tests: CropModelTests (8). swift test 173, 17 skipped, 0 failures. Artelico (Mac) and Hailo Studio (iOS) build.
- Maps: new `r3d_18.native.json`; changed `tddfa_mobilenet_v1.native.json` ("bgr": true; hard-linked into
  native/hf/stage/coreml). The other five re-made, unchanged. Hugging Face upload needed for both. No
  .mlpackage or web ONNX changed. Not done: Artelico Web (JS) for these models.

### Step 101. Family 4 maps uploaded (2026-11-21)

- helmo/artelico-models revision c4e8165046b1b1d2d91909e7c8b8801c913743f3: r3d_18 map (new), tddfa_mobilenet_v1
  map with "bgr": true, manifest regenerated (checked by SHA-256 on HF). Pinned in ModelDownloads.swift and
  web/js/core/source.js. Spot-checked in the Mac app (Core ML, bus.jpg): face/person attributes, face_landmarks_lite,
  tddfa, RepVGG re-ID. swift test: 173, 17 skipped, 0 failures.
- Open: tddfa_bfm68.bin (68-point part of the Basel Face Model, in the app bundle) is under the BFM's own licence.

### Step 103. Artelico Web: the decoders of Steps 95-100 (families 1-4) in the browser (2026-11-21)

The 27 models of families 1-4 run in Artelico Web (Photos, Live, the demo screens), decoded as StudioCore does.
CLIP/SigLIP left out (other session).
- **Engine** (`js/core/engine.js`): `"bgr"` maps swap red and blue of picture inputs (centerpose, tddfa); activation
  "tanh" (YOLACT coefficients); a 5-D float input ([1, 3, 16, 112, 112], r3d_18's web graph) is filled from the
  stick-layout clip (channel = frame x 3 + colour), dequantized with the input's zero point and scale.
- **Decoders**, new files in `js/core/`: `faces.js` (RetinaFace / LightFace anchors, `faces()` picks SCRFD or anchors),
  `pose-models.js` (ViTPose DARK, MSPN classic peak, TopDownPose with yolov8s, CenterPose), `crop-tasks.js` (faces /
  people cut out after scrfd_10g / yolov8s, attributes, 3DDFA, face mesh, re-identification with a session gallery),
  `decode-crops.js` (CelebA / PETA labels, 3DDFA parameters + head pose, mesh), `video-clip.js` (16 frames at 12/s,
  171 x 128 -> centre 112, an answer every 8 frames), `render-people.js` (attributes, names, 68-point lines, mesh).
  `decode2.instances` gained YOLACT, YOLO26-seg and FastSAM's numbered class-less segments (drawn as masks only,
  largest first); `decode.segmentation` takes the argmax of per-class scores and carries the model's class set
  (VOC, pets, Cityscapes in `catalog.js`; background untinted). `prep.js`: exact bilinear crops (`warp`,
  `warpAffine`, `cropSquare`: cv2's pixel centres, black outside) - canvas scaling differs from the Zoo's crops;
  `toPicture` moved there from hand-games.js.
- **Tasks** (`pipeline.js`), titles as the apps: Segment everything, Face attributes, Face landmarks, Person attributes,
  Person re-identification, Action in video; catalog task aliases (single_person_pose_estimation,
  facial_landmark_detection, zero_shot_instance_segmentation); companions per model (`companionsFor`: yolov8s for
  top-down pose, the detector for crop tasks, the chosen ArcFace for faces). YOLACT stretched, CenterPose padded black.
  Photos: "Count from 1 again" for re-ID, a note that one photo gives r3d_18 no motion. Live keeps a VideoClip
  and a re-ID gallery per start. Face check-in: detectors with landmarks only (no LightFace) and a
  "Recognition model" picker (arcface_mobilefacenet / arcface_r50, one list of people each).
- **web/data**: models.json and labels.json copied from StudioCore's Resources (Kinetics-400 labels), and
  `tddfa_bfm68.bin` (41 KB, Basel Face Model licence; build_space.py would copy it into the Space too).
- **Web maps** (`export_web.py --maps [names]`, new: rewrites maps from the Core ML maps for existing web ONNX):
  new lightface_slim, yolo26{n,s,m,l}_seg, yolov5{n,s,m}_seg_hpp, fast_sam_s, vit_pose_small_bn, r3d_18; changed
  yolact_regnetx_{800mf,1.6gf} (tanh), centerpose_regnetx_800mf, tddfa_mobilenet_v1 (bgr). Written into native/web
  (the 4 changed ones are hard-linked into native/hf/stage/web). All other web maps equal the Core ML ones.
  Not yet on Hugging Face: the pinned revision serves no or old maps for these 15 (the site from HF then decodes
  them wrongly or not at all). No ONNX changed; every model's web ONNX is in native/web and in the manifest.
- **Checked in headless Chrome (WebGPU, models from native/web) against the stick** (`ugen`, same pictures;
  the Mac app was not used: the CLIP session had it):
  faces bus.jpg: RetinaFace 2/2, box IoU 0.90/0.86, landmarks 1.1 px mean; LightFace 2/2, IoU 0.98/0.88.
  Segmentation dog_bicycle (vs argmax of the stick's captured scores): deeplab 98.8% of pixels, unet 99.6%, same classes.
  Instances bus.jpg (paired by class + box, mask IoU on a 120 x 160 grid): yolo26n/s/m/l 4/4, 4/4, 5/5, 5/5, mask
  0.957/0.974/0.929/0.950; yolov5n/s/m_hpp 4/4, 5/5, 5/5, mask 0.932/0.870/0.876; yolact 800mf 6/6 0.906, 1.6gf 5/5
  0.970 (web adds a 0.34 bus); FastSAM 89 vs 92, 83 of 92 stick masks have a web mask >= 0.7 IoU (top 30: 0.953).
  Pose bus.jpg, 4/4 people for all four; visible keypoints mean 2.6 (ViTPose), 2.9 (-bn), 2.7 (MSPN), 3.6 px (CenterPose).
  Person attributes same sets 4 of 4 (max diff 0.20). 3DDFA 0.64/1.27 px, yaw within 1.5 deg; face mesh 0.31/0.36 px.
  Face attributes 1 of 2 same set: the glasses face's "male" 0.87 on the stick's landmarks drops to 0.31 with the
  browser's SCRFD landmarks (<= 1 px apart; Python reference with those landmarks gives the same 0.31): the model
  is unstable on 39-pixel faces. Canvas alignment had moved it too; the crop is now an exact bilinear warp.
  Re-ID bus / mirrored / cropped+darker: same numbers as the stick, same-person 0.88-0.99 (OSNet), 0.69-0.99 (RepVGG).
  r3d_18 grok-squats at 12/s: 8 answers, all "squat" (0.68-1.00), stick 0.63-1.00, same top-1 everywhere.
  ArcFace (bus vs mirrored): MobileFaceNet 0.90/0.71, R50 0.87/0.83 same person, -0.25/0.04 different.
- Screens looked at: Photos with every new task, Live (Action in video on grok-squats: squat 78%; re-ID on
  walk_in_room, 14 FPS), Squat alarm with vit_pose_small (4 FPS with 6 people), Face check-in.
  test.html for the older tasks unchanged; rules-test 74/74.

### Step 104. Web maps uploaded (2026-11-21)

- helmo/artelico-models revision 5a13d7392361c0b4664df9d82f0853d745e8fdd4: the 15 web maps from Step 103 (11 new,
  4 changed), each checked by SHA-256 on HF. Pinned in ModelDownloads.swift and web/js/core/source.js.
- Not in the Space yet: web/data/tddfa_bfm68.bin (Basel Face Model licence) waits for the owner's decision.

### Step 102. Tagging from text with every CLIP / SigLIP / TinyCLIP pair (2026-11-21)

13 image encoders now tag pictures from text prompts with their own text encoder (stick and Core ML), through
the existing "Tagging from text" task, so Photos, Live and the REST API of both apps take them. 24 of the 26
"Not used by the app yet" CLIP-family models are in use; the text encoders are listed as helpers.
- **Pairs** (`CLIPModels.swift`, `CLIPModels.pairs`): clip_vit_b_32, clip_vit_b_16, clip_resnet_50, clip_resnet_50x4,
  clip_vit_l_14_laion2B, tinyclip x4, siglip_b_16, siglip_l_16_256, siglip2_b_32_256, each with its text encoder;
  clip_vit_l_14_336_image_encoder with clip_vit_l_14_text_encoder (the Zoo has no 336 text encoder; OpenAI
  fine-tuned the 336 model from L/14, text tower weights 2-5% apart; zero-shot right on all samples).
  `VisionPipeline.supports(.tagging)` = any pair's image encoder; `companionModels(for:)` = its text encoder.
  Not done: siglip2_b_16_text_encoder and siglip2_l_16_256_text_encoder (no image encoder in the Zoo for them,
  and the second has no Core ML package either): still in "Not used by the app yet".
- **What the HEFs take** (Zoo configs, the source ONNX, create_coco_xtd10_*_tfrecord.py): every text encoder
  starts after the token lookup (input = token embeddings, position embeddings added on the chip). CLIP ones end
  at the last hidden state: the host takes the first end token's row, x text projection; TinyCLIP's cut also
  leaves out the final layer norm (end node encoder/layers.N/Add_1), done on the host (`CLIP.layerNorm`, eps
  1e-5). SigLIP ones end after the head (pooled, 1 x width): only L2-normalised. Image encoders give the
  projected embedding. Scores: softmax over the prompts of logit scale x cosine with each model's own scale
  (OpenAI/LAION 100, TinyCLIP 50, SigLIP b16 117.3, SigLIP l16 110.0, SigLIP2 b32 111.8, from the checkpoints).
- **Tokenizers**: CLIP's BPE (existing port; HF openai tokenizer.json now bundled as `clip_tokenizer.json`, MIT,
  2.2 MB). New `SentencePiece.swift`: SigLIP's unigram model (Viterbi, NFKC, lowercased, ASCII punctuation
  dropped, "▁" before each word, `</s>` and padding to 64 as SiglipTokenizer) from bundled `siglip_tokenizer.json`
  (32k pieces, Apache-2.0, 0.8 MB); Gemma's BPE for SigLIP 2 (merge the best-scoring pair, byte fallback, `<eos>`,
  pad 0, lowercased as Google recommends; Hailo's calibration used the raw processor) from an extra file. Both
  read the JSON native/tools/clip_assets.py writes from the original .model files. Checked on 424 phrases
  (prompts, punctuation, digits, accents, CJK, emoji, random dictionary words) against transformers 4.57
  (CLIPTokenizerFast, SiglipTokenizer, GemmaTokenizerFast): all ids equal (`testAllTokenizersMatchHuggingFace`,
  fixture testdata/configs/clip_reference_tokens.json).
- **Tables** (`native/tools/clip_assets.py` -> native/coreml, staged by package_hf.py next to the text encoder):
  `<text>.tokens.npy` float16 token table (from the source ONNX for TinyCLIP/SigLIP, the Zoo .npz for B/16, B/32,
  LAION; OpenAI's weights via timm's open_clip safetensors with HTTP range requests for RN50, RN50x4, L/14),
  `<text>.projection.npy` (CLIP, float32 width x embedding), `<text>.final_norm.npy` (TinyCLIP).
  `NPYFloatArray` reads float16 too. B/32's table equals Hailo's token_embedding_lut.npy within float16 rounding
  (1.7e-4); the TinyCLIP .npz files were checked against the ONNX tables (the Zoo's script points 40M at 61M's
  file; ours is right). 1.07 GB in all, siglip2's table 393 MB of it.
- **clip_resnet_50_text_encoder Core ML gave NaN everywhere** on real token embeddings (float16 overflow; also on
  the CPU; the zero-input check in convert_all.py had passed): re-converted in float32 (`FP32_MODELS`), now equal
  to ONNX (max diff 0.0000). `CoreMLEngine.tensor` no longer traps on NaN/infinity (it crashed ugen).
- **Stick: clip_vit_l_14_laion2B's two encoders do not configure together** (hailo_status 81, either order; each
  alone works): `CLIPPair.stickLoadsBoth` false, the stick runs the text encoder for the prompts, then keeps only
  the image encoder (Hailo Studio's prepare/prepareTagger, ugen, the device test).
- **Checks against the source ONNX** (scratchpad ref_embed.py: HF token ids, float32 source tables, ONNX text and
  image encoders, PIL bilinear stretch; `ugen tag [--coreml] --json`): text embedding cosine with the reference
  (min / mean over 13 prompts), image embedding cosine (bus, dog_bicycle, apple), largest change of a prompt's
  cosine similarity; stick | Core ML. Top-1 equals the reference everywhere except clip_resnet_50 on
  dog_bicycle (reference dog 0.215 vs bicycle 0.214; stick and Core ML say bicycle):
  clip_vit_b_32 0.93/0.96, 0.96-0.98, 0.029 | 1.00, 0.99-1.00, 0.009;  clip_vit_b_16 0.96/0.98, 0.91-0.94, 0.045 |
  1.00, 0.98-0.99, 0.006;  clip_resnet_50 0.94/0.96, 0.80-0.95, 0.032 | 1.00, 0.93-0.99, 0.021;  clip_resnet_50x4
  0.90/0.96, 0.95-0.97, 0.039 | 1.00, 0.99-1.00, 0.010;  clip_vit_l_14_336 0.88/0.93, 0.84-0.87, 0.105 | 1.00,
  0.98-1.00, 0.014;  laion2B 0.95/0.98, 0.94-0.97, 0.020 | 1.00, 0.97-0.99, 0.018;  tinyclip 8m 0.98/1.00,
  0.98, 0.029 | 1.00, 0.99-1.00, 0.009;  39m 0.99/0.99, 0.97-0.98, 0.021 | 1.00, 0.99-1.00, 0.007;  40m 0.93/0.96,
  0.93-0.97, 0.034 | 1.00, 0.99-1.00, 0.006;  61m 0.90/0.92, 0.96-0.98, 0.061 | 1.00, 0.99-1.00, 0.005;
  siglip_b_16 0.97/0.98, 0.91-0.97, 0.028 | 0.98/0.99, 0.95-0.99, 0.014;  siglip_l_16_256 0.79/0.89, 0.93-0.98,
  0.023 | 0.99/1.00, 0.94-0.99, 0.014;  siglip2_b_32_256 0.38/0.94, 0.90-0.95, 0.059 | 0.99/1.00, 0.99-1.00, 0.010.
  The stick's SigLIP text encoders lose accuracy on some prompts with the very same input frame Core ML gets
  (deterministic, so the HEF's quantisation): siglip_l 7 of 13 prompts at 0.80 (bus, dog, cat...), the others
  >= 0.99; siglip2 "person", "people", "man", "woman" 0.38-0.54, the rest >= 0.97. Rankings still right on the
  samples. Token ids equal the reference for every pair.
- **Zero-shot on the samples** (prompts bus, dog, bicycle, apple, person, cat, car, living room, ...): bus.jpg ->
  bus, dog_bicycle.jpg -> bicycle then dog, apple.jpg -> apple, for all 13 pairs on the stick
  (`UGEN_DEVICE_TESTS=1 swift test --filter testEndToEndOnDevice`, now every pair) and through Artelico's REST API
  on Core ML (`-modelsfolder native/coreml`, render looked at: siglip2 on dog_bicycle, bicycle 84% dog 16%).
- **Times** (13 prompts / one picture after the first; stick | Core ML API): b32 376 ms / 24 ms | 8 ms, b16
  404 / 35 | 12, RN50 378 / 12 | 3, RN50x4 448 / 24 | 7, L/14-336 641 / 211 | 150, LAION L/14 2.5 s (with the
  model swap) / 88 | 33, TinyCLIP 8m 63 / 11 | 4, 39m 205 / 17 | 5, 40m 203 / 13 | 8, 61m 297 / 16 | 6,
  SigLIP b16 510 / 43 | 7, SigLIP l16 2.1 s / 85 | 28, SigLIP2 b32 511 / 23 | 4.
- Apps: Artelico loads the tables from the models folder (they come with the text encoder's download;
  `downloadExtraFiles` fetches any an older download lacks, clip_vit_b_32's from Hailo's S3 if the repository has
  none; old Documents/clip files are moved over once); the text encoders are helpers in Device and models
  ("used by picture tagging with <image encoder>") and are deleted with their tables. Hailo Studio downloads them
  from helmo/artelico-models at a pinned revision (`clipFilesRevision`, still the pre-upload one: bump after
  uploading) into Documents/clip, b_32 falling back to Hailo's S3. ugen: `tag [--coreml] [--json] <image encoder>
  <labels> <images...>`.
- Tests: CLIPTests rewritten (12: tokenizers vs HF, float16 .npy, Hailo's b_32 frame values, pairs vs the model
  table and table shapes, layer norm, scales); they now find the project from #filePath (the old root path was
  another machine's, so they were all skipped). swift test 176, 13 skipped, 0 failures. Artelico (Mac) and
  Hailo Studio (iOS) build.
- Hugging Face (not uploaded): 28 new files next to 13 text encoders (1.07 GB, manifest regenerated in
  native/hf/stage), and clip_resnet_50_text_encoder.mlpackage changed (float32). No new or changed .native.json;
  no web ONNX changed. Not done: Artelico Web (JS) for these pairs.

### Step 105. CLIP tables uploaded (2026-11-21)

- helmo/artelico-models revision 955f8622458884b759d5b4baf89e35f3e744693a: 28 CLIP/SigLIP/TinyCLIP text tables and
  tokenizer from Step 102, float32 clip_resnet_50_text_encoder.mlpackage, manifest and card. All 1160 manifest
  files checked on HF (size + SHA-256): none missing or different. Pinned in Artelico ModelDownloads.swift,
  Hailo Studio clipFilesRevision and web/js/core/source.js.

### Step 107. Re-converted packages replace old copies; DMGs and devices (2026-11-21)

- refreshModelMaps also compares each installed package's Manifest.json with the repository's; a package
  re-converted there (clip_resnet_50_text_encoder, float16 -> float32) is downloaded again over the old one
  (`download(_:replacing:)`), and its stale .mlmodelc removed. Checked on this Mac (~/.artelico/models): only that
  model differed; replaced 16 s after launch; clip_resnet_50 then tags bus/dog_bicycle/apple right (0.999, bicycle
  0.57 / dog 0.43, 0.9997). siglip2_b_32 downloaded its 393 MB table and tokenizer on first use: bicycle 0.88, dog 0.12.
- DMGs rebuilt (dist/Artelico-1.0.dmg 16 MB, dist/Hailo-Studio-1.0.dmg 44 MB). iOS Release installed: Artelico on
  iPad and iPhone, Hailo Studio on iPad (not launched).

### Step 106. Artelico Web: tagging from text with all 13 CLIP / SigLIP / TinyCLIP pairs (2026-11-21)

The 13 pairs of Step 102 tag pictures in Artelico Web (Photos and Live, task "Tagging from text (CLIP)", prompts box
"car, truck, bus, person, bicycle, -empty road" as the apps, "-" = not this, "not: " in the result). Each image
encoder is in the task's model list and loads its own text encoder as a companion; text encoders are not main models
(Models shows them as "helper: used by tagging from text with ...").
- **Web text encoders take token embeddings** (input [1, 77 | 64, width] float, the cut after the token lookup, as the
  HEFs), not ids: the tables are needed. They come from the repository's `coreml/` folder at the pinned revision
  (manifest paths): `<text>.tokens.npy` is read **row by row with HTTP range requests** (header + one 0.5-2 KB row per
  token: siglip2's 393 MB table costs ~10 KB per prompt; HF's CDN answers 206 with CORS, checked in Chrome from HF
  with tinyclip 8m and siglip2: same scores as local), `<text>.projection.npy` (CLIP, whole, 1-2.4 MB) and
  `<text>.final_norm.npy` (TinyCLIP). Rows and files are kept in Cache Storage. `source.js`: `repositoryUrl`,
  `readFile`, `readRange` (a server ignoring ranges: the whole file once, kept in memory); a chosen folder must hold
  the tables next to the ONNX files. `serve.py`: range requests, `/coreml/` = native/coreml, `/testdata/` (dev only).
- **New** `js/core/clip.js` (pairs, logit scales, prompt embedding: first end token row, TinyCLIP layer norm,
  projection, L2; SigLIP pooled output L2; softmax of scale x cosine) and `js/core/tokenizers.js` (CLIP BPE,
  SentencePiece unigram for SigLIP, Gemma BPE for SigLIP 2, float32 Viterbi sums as Swift). `engine.js` takes a
  Float32Array input as real values. `prep.js` `prepareSmooth`: PIL-style antialiased bilinear stretch; the canvas
  stretch gave image embeddings only 0.937 cosine to the Python reference (bus.jpg 810x1080 -> 224), this one 1.0000.
- **web/data**: `clip_tokenizer.json` (openai/clip-vit-base-patch32, MIT), `siglip_tokenizer.json`
  (google/siglip-base-patch16-224, Apache-2.0), `siglip2_tokenizer.json` (google/siglip2-base-patch32-256,
  Apache-2.0; = coreml/siglip2_b_32_256_text_encoder.tokenizer.json, 5.7 MB). Licences in web/README.md and the
  Space README template (build_space.py). `test.html?tokens`: 424 reference phrases, 0 mismatches for all three.
- **clip_vit_l_14_laion2B_text_encoder.onnx (web) was broken**: 88 bytes, an empty graph (a stale empty
  `.cut.onnx` from a failed cut, which export_web prefers; the export failed and left it). Rebuilt from the whole
  source graph (input token embeddings [1, 77, 768] -> last hidden state), 340.5 MB, text embeddings equal Core ML's
  (cosine 1.0000). The stale cut is now a symlink to the source ONNX. Written to native/web, hard-linked into
  native/hf/stage/web, manifest entry (bytes, sha256 727ff8fd...), index.json sizes and the card's web size patched.
  **Needs uploading** (the pinned HF revision serves the 88-byte file: that pair fails from HF until then).
- **Checked in headless Chrome (WebGPU, models from native/web, tables from native/coreml)**, 13 prompts (bus, dog,
  bicycle, apple, person, cat, car, living room, keyboard, spinner, Raspberry Pi, unicorn mouse pad, wooden desk),
  against Python ONNX (same web ONNX and tables, PIL stretch: largest cosine difference 0.0006, 0.0023 for laion2B
  bus) and `ugen tag --coreml --json` (cosine differences 0.003-0.022, from the different resize). Top-1 web | Core ML:
  bus.jpg bus for all 13 (0.969-1.000 | 0.974-1.000); apple.jpg apple for all 13 (0.959-1.000 | 0.964-1.000);
  dog_bicycle.jpg bicycle then dog for 12: b32 0.900/0.088 | 0.919/0.073, b16 0.845/0.140 | 0.852/0.134, RN50x4
  0.853/0.120 | 0.881/0.094, L/14-336 0.617/0.364 | 0.601/0.377, laion2B 0.863/0.137 | 0.863/0.136, tinyclip 8m
  0.519/0.175 | 0.531/0.217, 39m 0.749/0.182 | 0.744/0.193, 40m 0.810/0.158 | 0.810/0.159, 61m 0.773/0.191 |
  0.758/0.208, SigLIP b16 0.898/0.102 | 0.873/0.127, l16 0.792/0.207 | 0.828/0.172, SigLIP2 0.831/0.165 |
  0.839/0.158; clip_resnet_50 dog 0.487, bicycle 0.450 (Python reference the same; Core ML bicycle 0.485, dog
  0.450: the tie Step 102 found in the source model).
  Picture times (WebGPU, M-series): 6 ms (tinyclip 8m) to 57 ms (L/14-336); first run with 13 new prompts 13-508 ms.
- Screens looked at: Photos siglip2 on dog_bicycle (bicycle 83.1%, dog 16.5%), laion2B on bus (default prompts,
  bus 100%), Live clip_vit_b_32 on bus (40 FPS), Models (helpers). Older checks (yolov8m, resnet_v1_50, scrfd) unchanged.
- Big in a browser: L/14-336 (1.22 GB) + its text encoder (0.34 GB), laion2B (1.22 + 0.34 GB) and SigLIP-L
  (1.26 + 1.21 GB, ~2.5 GB download, held twice in memory by the engine) ran in headless Chrome on this Mac but will
  not fit phones or small laptops.

### Step 108. Rebuilt laion2B web encoder uploaded; Space republished (2026-11-21)

- helmo/artelico-models revision 48d563feafae28e845eb4dc265b8908ec4a2f201: web clip_vit_l_14_laion2B_text_encoder.onnx
  (340.5 MB, was an empty 88-byte export), manifest, card. All 1160 manifest files checked on HF. Pinned in
  Artelico, Hailo Studio (clipFilesRevision) and web/js/core/source.js.
- test.html with ?models=hf at that revision (headless Chrome, WebGPU): siglip2_b_32 dog_bicycle bicycle 0.83,
  laion2B bus 1.00, yolo26n_seg, face_landmarks_lite, person_attr, vit_pose_small_bn all fine.
- Space helmo/artelico republished (commit 366aa36): every new task and the 13 CLIP pairs. data/tddfa_bfm68.bin
  is left out (Basel Face Model licence) and tddfa_mobilenet_v1 is hidden there; it 404s on the live Space as meant.
  Live Space lists 207 models.

### Step 109. Privacy camera (Artelico and Hailo Studio) (2026-11-21)

hailo-apps has a `face-blur` option in its community overlay (off by default, used by no app). Built a
full screen from it, shared by both apps (Faces group, `-section privacy`).
- **StudioCore `Privacy.swift`:**
  - `PrivacyScan`: faces (scrfd_10g first, boxes grown for hair and chin); plates as text found by ocr_det
    inside the 4 largest vehicles; all text in the picture; people from instance masks.
  - `RegionHold`: a region stays hidden 0.6 s after it was last found, so a missed frame doesn't flash a face.
  - `PrivacyFilter`: Core Image blur, pixelate or solid fill through a mask. Person masks are scaled up and widened.
    It returns nil on failure, and the screen then stops rather than showing the original.
- **PoseRunner:**
  - new `filter` hook: every frame is cleaned before it is shown, handed on or recorded;
  - instance-segmentation results (masks and boxes);
  - `required` models (downloaded if needed);
  - default instance model yolov8s_seg.
- **Artelico `loadExtra`** now downloads a missing model, as Hailo Studio's already did.
- **Screen:**
  - toggles for faces, licence plates, all text and whole people; style; outlines;
  - counts of what is hidden;
  - Record (only the cleaned frames) with Share.
- **Checked on the Mac (Core ML, still sources at 15 FPS):**
  - bus.jpg: 2 faces and 8 text regions on the bus hidden;
  - with Whole people: 3 people masked (yolov5n_seg, tight), then yolov8s_seg as default;
  - plate_sample.png with All text: plate and both text lines pixelated;
  - driving video: plates on the cars hidden, 13 FPS, some extra boxes (safe side).
- **Hailo Studio on the stick:** bus.jpg, 10 FPS, 2 faces, 7 plates/text, 4 people blurred.
- **Tests:** PrivacyTests (6 tests: mask placement and orientation, person mask vs box, hold timing, grow). swift test: 182,
  13 skipped, 0 failures.
- **Installed and rebuilt:** iOS Release installed (Artelico on iPad + iPhone, Hailo Studio on iPad; not launched). DMGs rebuilt.

### Step 113. Artelico Web: Privacy camera (2026-11-21)

The Privacy camera of Step 109 in Artelico Web (Faces group, `#privacy`), the same feature set as the Swift screen.
- **Rules** `web/js/rules/privacy.js` (port of Privacy.swift): `RegionHold` (0.6 s, same kind + IoU > 0.2 replaces),
  `PrivacyScan` (face detectors scrfd_10g, scrfd_2.5g, retinaface_mobilenet_v1, scrfd_500m; face boxes grown 20% /
  35% top / 15% bottom; text boxes 15% / 30% / 30%; text search area in whole pixels, skipped under 16 x 16; the 4
  largest car/truck/bus/motorcycle; people with their masks), `PrivacyFilter` (canvas 2D: blur sigma = longer side /
  40 with clamped edges, worked out at sigma 6 on a smaller copy and scaled up; pixelate blocks of the same size;
  solid rgb(31,31,36); person masks dilated by longer side / 90 and scaled to the picture; throws instead of
  returning the original). Browsers without canvas `filter` get a down/up-scale blur.
- **Screen** `web/js/ui/examples/privacy-screen.js`: toggles faces / licence plates / all text / whole people, Blur /
  Pixelate / Solid, outlines, counts per kind, face model picker (scrfd_10g default), instance model picker
  (yolov8s_seg first). The instance model only runs when people or plates (without All text) are on. Samples as
  Swift with credit tags: bus.jpg, plate_sample.png, street, office, face, driving videos.
- **Fail closed:** the runner grabs into its offscreen canvas, `PrivacyFilter.apply` draws a new cleaned canvas and
  only that one is drawn on screen (kit option `shown(frame)`, new) and into the recorder's own canvas. A throw stops
  the runner with "The picture could not be cleaned, so it is not shown" and the screen canvas is hidden (checked
  by replacing `apply` with a throwing function while running).
- **Record:** MediaRecorder on a separate canvas fed only cleaned frames (`captureStream(0)` + `requestFrame`),
  MP4 (H.264) where supported, else WebM; download link. Headless Chrome: 4 s of the face video -> 2.3 MB
  video/mp4, 1280 x 720, 4.01 s.
- **rules-test.html:** the 6 PrivacyTests ported + 2 web ones (blur removes fine stripes up to the picture's edge;
  pixel blocks, vehicles order, text box growth, search area): 82/82.
- **Checked in headless Chrome (WebGPU, models from native/web, port 8151)**, compared with Step 109 (Mac, Core ML):
  - bus.jpg, faces + plates: 2 faces, 9 plate/text regions on the bus (Mac: 2 and 8), 14 FPS. The bus's LED
    destination sign "MI SOL SEVILLA" is not found by ocr_det (neither in the bus crop nor with All text).
  - + Whole people: 4 people masked with yolov8s_seg (Mac yolov5n_seg 3; stick 4), 14 FPS.
  - plate_sample.png, All text, Pixelate: 3 texts (the plate and both text lines), as the Mac.
  - driving video, faces + plates: 1-6 plates over 8 readings, all on cars ahead; 4-6 FPS (Mac 13): per frame
    ~40 ms yolov8s_seg, ~35 ms scrfd_10g, up to 4 ocr_det runs ~100 ms, cleaning ~2 ms.
  - face video: 1-2 faces (one held), blur leaves no recognisable features, 12 FPS.
  - Space build (`build_space.py` into a scratch folder, models from Hugging Face at the pinned revision,
    data-edition="space"): bus.jpg with people 2 / 9 / 4, 14 FPS; the browser's fake camera through the
    Camera source, 18 FPS. Nothing needed on Hugging Face. The web edition has no road-camera list (Swift's
    stream picker), so none was added; Stream address stays.
- Also: Head count unchanged (kit change), web/README.md, the Space README template lists the privacy camera.

### Step 114. Space republished with the Privacy camera (2026-11-21)

- helmo/artelico Space commit 29fad86: Step 113's web Privacy camera. privacy-screen.js served (200);
  data/tddfa_bfm68.bin still left out (404).

### Step 111. Rep counter and Catch the eggs (Artelico and Hailo Studio) (2026-11-21)

Two new pose screens, shared by both apps.
- **Rep counter** ("Body and pose", `-section reps`), after hailo-apps' `--aigym` mode (yolo26/pose_estimation/aigym.py):
  - StudioCore `RepCounter.swift`: `Exercise` (squats, push-ups, pull-ups, sit-ups or crunches, jumping jacks, lunges),
    each one joint angle with a rest and a work threshold (dead band between). `RepTracker` per tracked person:
    a phase change needs 2 frames in a row, a rep is work then rest (as aigym, someone first seen down counts
    when they come up). Half reps (at least half way) give a hint ("Go lower", "Pull higher", "Arms higher"…);
    joints not seen give "Show your hips, knees and ankles". `RepCounter`: people by track number (untracked poses
    skipped), forgotten after 4 s out of sight, their reps kept in the total.
  - No "auto": from one camera a squat and a lunge, or a push-up and a pull-up, bend the same joints the same way.
  - Screen: a tag over each head (track number + count, green at rest / orange down, grows for a moment on a rep),
    the hint under it, the total, Reset, a list per person with the live angle, a rising note per rep (ToneSynth).
- **Catch the eggs** ("Hands", `-section eggs`), after hailo-apps' easter_game:
  - StudioCore `EggGame.swift`: eggs fall from the top with a small sway; the nearest player's hand within reach catches
    (+1, golden eggs 10 % +3), an egg past the bottom is a miss. Hands are the palms (wrist pushed 0.35 forearm out).
    60 s rounds; fall speed 2.2 x and eggs 2.4 x as often by the end; 1.6 x more eggs for two players. 1 or 2 players:
    between rounds the biggest people are the players, in a round a slot is kept while seen and freed after 1.5 s.
  - Screen: drawn eggs (egg outline, shaded shell, zigzag band with dots, shine; golden with a sparkle), broken
    eggs on the floor for misses, catch circles and skeletons in each player's colour, "+1" pops, scores, timer,
    misses, best. Fruit ninja's Play menu, size and speed settings and its view-identity fix (the egg canvas has
    `.id(tick)`, the buttons don't). Sounds for catches, golden eggs, misses and the end. `-autoplay` (debug) starts a round.
- **Checked on the Mac (Artelico, Core ML, yolov8s_pose, 19-25 FPS):**
  - grok-squats.mp4 (6 s, loops). My frame-by-frame count: everyone starts down and stands up 3 times per pass.
    Counted in the first pass: the four front women (grey, teal, centre, green) 3 / 3 each; the woman right of them
    2 / 3 (first rep under #5, then lost and re-tracked as #8); the woman cut by the right edge 2 / 3 (tracked late);
    the man cut by the left edge 0 / 3 (knees out of the picture: the screen says so). Over 40 s (6.6 passes) the
    front four reached 20 each, exactly the expected 20. The right-edge people get new track numbers at each loop
    jump, so their reps are split across numbers (the total keeps them).
  - walk_in_room.mp4, 2 players, mid-game: 10 and 14 caught, 17 missed at 36 s left; eggs, splats and pops drawn right.
- **Hailo Studio:** builds and runs both screens, but the stick could not be checked: "The runtime did not appear after
  the upload" (also with `ugen identify`); it needs a replug.
- **Tests:** RepCounterTests (7: angles, one rep = down then up, dead band and one-frame glitches, people's own counts
  and leaving, every exercise's direction, hints, exercise change) and EggGameTests (6: palm, catch and miss, speed rise
  and end, players between rounds, slots after leaving, nearest hand). swift test: 203, 13 skipped, 0 failures.

### Step 110. Find anything (YOLO-World) and Describe each object (CLIP on detections) (2026-11-21)

Two new vision tasks in StudioCore, so Photos, Live and the REST API of both apps take them.
- **Find anything** (`VisionTask.findAnything`, raw value = catalog task `zero_shot_object_detection`), yolo_world_v2s,
  `OpenVocabulary.swift`. First two-input path in `VisionPipeline.supports` (picture + 1 x 80 x 512 text embeddings).
  Text: Hailo's create_coco_tfrecord_with_text_embeddings.py = CLIP ViT-B/32 text model + projection, L2, on the bare
  class name (no "A photo of a"), so the prompts go through clip_vit_b_32_text_encoder (companion model) with
  `CLIPTagger.setPrompts(..., prefix: "")`. Fewer than 80 prompts are repeated to fill the slots (the neck's text
  attention takes a max over classes and each score uses only its own embedding, so copies change nothing; zero
  padding gave nearly the same on bus.jpg). Picture: centred letterbox, grey 114. Decoding = Zoo YoloWorldPostProc:
  DFL 4 x 16, sigmoid on the chip, every class over the threshold per cell, class-wise NMS 0.7; threshold 0.25 (open
  vocabulary scores run low: sunglasses 0.28). A "-x" prompt drops boxes whose class it is.
- **Describe each object** (`VisionTask.describeObjects`, raw `object_clip`, model = any CLIP/SigLIP image encoder),
  `ObjectCLIP.swift`: like hailo-apps clip `--detector`: People / Vehicles / Animals / Faces / Everything, any detector
  VisionPipeline decodes (default yolov8s; faces scrfd_10g), score >= 0.4, at most 10, each box cropped as is and
  stretched to the encoder (hailocropper), two at a time; "A photo of a <prompt>", softmax over the prompts.
  Result `.described` with the new `DescribedObject.label` (detector class); drawn with the best prompt only, list
  and JSON with all. Settings in `StudioModel.objectSettings` (saved), pickers next to the prompt box. laion2B: Hailo
  Studio embeds the prompts with the text encoder alone, then loads the image encoder + detector.
- **Apps:** `PromptOptions` (Components.swift: prompt box, Examples menu, objects and detector pickers); TaskOptions in
  ContentView.swift got one hook line for the two tasks (also Live). StudioModel: `prepareTagger(for:prompts:)` serves
  tagging, finding and describing; all three run through `VisionPipeline.run(..., prompts:)`. REST API: `prompts=`,
  `objects=`, `detector=`. Photos test flags `-task <task> <model>`, `-sample <file>` (with `-autorun`).
- **Core ML:** conversion failed before (onnx2torch read Clip's empty max input as a dynamic bound):
  `convert_onnx.py clip_without_empty_bounds`. compare.py (random text) fine; float16 kept. `yolo_world_v2s.native.json`
  written by hand first (Core ML outputs sorted by name otherwise), then by native-map (same).
  `ugen native-map zero_shot_object_detection yolo_world_v2s <image> <package> [prompts]` feeds Core ML-embedded prompts.
- **Python reference** (scratchpad yw/ref.py: HF tokens, source B/32 text ONNX + npz, full source YOLO-World ONNX with
  its own DFL, Zoo decoding) vs `ugen find --coreml`: bus.jpg "bus, person, handbag, sunglasses": person 0.924/0.917/
  0.915/0.582, bus 0.899, sunglasses 0.283 (Core ML 0.930/0.924/0.914/0.577, 0.912, 0.294), box IoU 0.983-0.997, text
  embeddings cosine 1.0000; dog_bicycle.jpg "dog, bicycle, car": bicycle 0.968, dog 0.949, car 0.729 (Core ML 0.965,
  0.949, 0.740), IoU >= 0.998. Describe (yw/describe_ref.py, same boxes, PIL crop + source B/32 ONNX), bus.jpg people
  "wearing sunglasses, not wearing sunglasses": 0.767/0.458/0.923/0.582 wearing (Core ML 0.773/0.480/0.912/0.586);
  the man at the right edge (back turned) is "not wearing" 0.52.
- **Artelico on the Mac (Core ML), looked at:** Photos Find anything bus.jpg (same 6 boxes, 152 ms), Describe bus.jpg
  (225 ms); Live full_mov_slow.mp4 "car, truck, traffic light, person" 13 FPS (cars 0.26-0.36 in the distance),
  Live walk_in_room describing people "wearing a hat, wearing a backpack, on a phone" 30 FPS (phone caller "on a
  phone" 0.69-0.79). Tags under a box at the picture's bottom are moved up into it.
- **Stick** (after the replug). `ugen native-map` wrote the same map as the hand-made one (box raw, scores + sigmoid;
  mean |diff| 0.13-0.14 x spread for boxes, 0.015-0.13 for scores); with the same text input stick and Core ML agree
  on all 5 bus.jpg objects, IoU 0.974, scores within 0.04.
  - **The stick's text encoder is too coarse for YOLO-World**: it ends in 8 bits, its embeddings are 0.98-0.99 alike to
    the reference, fine for tagging, but the stick's YOLO-World with them gives bus.jpg bus 0.97 and one person 0.32
    (the others lost; ONNX with the same embeddings still 0.84, so the quantized HEF amplifies it). With float
    embeddings it gives bus 0.90, people 0.90/0.90/0.82/0.51 (IoU 0.95-0.995 with the reference), dog_bicycle.jpg
    bicycle 0.90, dog 0.95; car (0.73 in ONNX) and sunglasses (0.28) are not found by the HEF.
  - So Hailo Studio embeds YOLO-World's prompts on the iPad/Mac with Core ML (`promptEncoder`: clip_vit_b_32_text_encoder
    .mlpackage, 76 MB, downloaded once into Documents/clip from the pinned repository revision, where it already is) and
    loads only yolo_world_v2s on the stick. `ugen find` does the same (`--stick-text` for the stick's encoder).
    Checked in Hailo Studio (Mac, stick): Photos bus.jpg bus 0.90, people 0.90/0.90/0.82/0.51 (first run with download
    7.2 s, then ~50 ms per picture on the stick).
  - Describe on the stick (b32 + yolov8s + text encoder all loaded, 100 ms for 4 people; Hailo Studio Photos looked
    at, 257 ms): same boxes, but the sunglasses pair is near a tie and the stick's text embeddings tip it: wearing
    0.38/0.30/0.60/0.39 vs reference 0.76/0.47/0.92/0.60 (2 of 4 tops agree). With Core ML text embeddings
    (`ugen describe --text-coreml`) 0.61/0.39/0.87/0.52: all 4 tops as the reference. Left on the stick's encoder
    (as tagging; other pairs' Core ML text encoders are up to 1.2 GB). laion2B: text encoder alone, then image encoder +
    yolov8s load together (344 ms; this prompt pair is poor with it).
  - After each ugen run the next one often finds "a session left by an earlier run" and restarts the stick (~40 s).
- Tests: PromptTaskTests (5). swift test 209, 13 skipped, 0 failures. Both apps build for Mac and iOS.
- **Hugging Face (not uploaded):** new `coreml/yolo_world_v2s.mlpackage` + `yolo_world_v2s.native.json`; licences.json
  entry (GPL-3.0, github.com/AILab-CVC/YOLO-World: "GPL-v3 ... supported for commercial usage"), card text, manifest
  and artelico-models.json restaged by package_hf.py. No web ONNX.

### Step 115. Rep counter and Catch the eggs on the stick (2026-11-21)

- The stick stopped answering (loader mode, "The runtime did not appear after the upload"); the user replugged it, after
  which `ugen identify` gave firmware 5.3.0, chip 32.9 C.
- Hailo Studio (Mac), squats video, yolov8s_pose: 24 FPS. After about 47 s (7.6 plays), the front four were at 23 reps each,
  expected 22–23. The man at the left edge got 0 ("Show your hips, knees and ankles"). The edge people were renumbered per loop (#13, #14).
- Catch the eggs, office video, autoplay: 30 FPS, eggs drawn, score 7 with 14 missed at 39 s left, the catch circles on the
  player's hands.

### Step 116. YOLO-World uploaded (2026-11-21)

- helmo/artelico-models revision 922f2602f2a1b313e357e83e004a2d47feddc7f1: yolo_world_v2s.mlpackage + map (GPL-3.0, on the
  card), manifest (210 models). All manifest files checked on HF (size + SHA-256). Pinned in Artelico ModelDownloads.swift,
  Hailo Studio clipFilesRevision and web/js/core/source.js.

### Step 112. Live with up to 4 sources, "Seen on camera", enrolling from photos, two-step Face report, chip health (2026-11-21)

The remaining items of the Hailo audit (task C).
- **Live: up to 4 sources** (both LiveViews; shared views in `Examples/LiveSourceViews.swift`, `StudioCore/LiveSources.swift`):
  - Source 1 is as before (camera, stream or video). "Add a source" adds sources 2-4: stream address or video file
    (own video or a demo video). Only source 1 can be a camera, because iOS runs one camera session at a time.
  - Panes: 1 alone, 2 side by side (stacked on a narrow screen), 3-4 in a 2 x 2 grid. Each pane has a badge with
    its number, name and FPS (`FrameRateMeter`, 0.5 s windows). The overall FPS is shown as before. Recordings
    are composed as the same grid (`LiveComposer.grid`).
  - One model is shared: the sources take turns, round robin, with 2 frames in flight on the stick.
  - Testing: `-stream2`, `-stream3` and `-stream4` add sources, and an address may be a file path (looped).
    `-livelog` now prints `LIVE FPS total [per source]` (also in Hailo Studio).
  - **Measured** (yolov8s, 720p 30 FPS videos walk_in_room, face_recognition, clip_example and example, Mac Debug
    builds, mean of the last 10 s):

    | Sources | Artelico (Core ML) | Hailo Studio (stick) |
    |---|---|---|
    | 1 | 29.9 (30 each) | 30.0 |
    | 2 | 60.0 (30 each) | 60.0 (30 each) |
    | 3 | 90.1 (30 each) | 79.7 (26.8 / 26.3 / 26.5) |
    | 4 | 90.3 (22.6 each) | 79.6 (20 each) |

    Up to 2 sources are limited by the videos' 30 FPS; beyond that, Core ML reaches about 90 FPS and the stick
    about 80 FPS in this app (decoding included). App memory on the Mac: 292 MB with 1 source, 539 MB with 4,
    so about 80 MB per extra 720p player.
  - **iOS cap:** `LiveSources.limit` allows 4 sources on devices with at least 4 GB (any reporting 3.5 GiB or
    more) and 2 on 3 GB devices. The reason is memory, from the Mac figure above. This was not measured on an
    iPad (no device runs in this task). AVPlayer decodes in hardware; decoder limits were not hit on the Mac.
- **"Seen on camera X"** (`StudioCore/SightingLog.swift`, `Examples/SightingLogView.swift`):
  - The idea of hailo-apps' reid_multisource ("first created at src N"), kept as a timeline instead of a label.
  - Every named face (Face recognition: names from Known people, or "Person N" when Number unknown people is on)
    and every Person re-identification number becomes a visit per source. A visit ends after 3 s unseen.
  - The log keeps first and last seen (with the source), the sources as coloured chips, one lane per source on a
    common time axis, and a 96-pixel thumbnail (re-cut only when the person is seen 20 % larger). It also has a
    newest-first timeline and a CSV share.
  - Toolbar button "Seen on camera" in Live for those two tasks; the open sheet refreshes once a second.
    `-sightings` opens it after 20 s; `-livelog` prints `SEEN <name> on source N`.
  - Checked, the same video on two or three sources:
    - Artelico, scrfd_10g on walk_in_room x2 + face_recognition: Persons 2, 3, 4, 5, 10 and 19 were seen on
      both walk_in_room sources; 72 FPS total.
    - Artelico, repvgg_a0_person_reid_512 on walk_in_room x2: all of Persons 1-9 on both sources; 50-60 FPS.
    - Hailo Studio (stick), scrfd_10g on walk_in_room x2: Persons 1-7 on both sources; 25 FPS total.
- **Enrol faces from photos** (`StudioCore/FaceEnrolment.swift`, `Examples/FacePhotoEnrolment.swift`, Face check-in
  "Enrol from photos…"):
  - Pick photos and/or folders (the file picker, so a folder on the Mac too). The name comes from the file
    ("ann_smith-02.png" -> Ann Smith; "Bob (3)" -> Bob) or from a folder per person; camera names like IMG_1234
    are refused.
  - A photo with one face is used. With several faces, the largest is used only if it is at least twice the
    next; otherwise the photo is refused, so a stranger is never stored under the name.
  - Each person's photos are averaged into one vector, in the shared face list (check-in, Photos, Live).
  - The sheet lists every photo: enrolled / no face found / N faces of similar size / no name in the file name.
  - Available once check-in has analysed a frame (the face models are loaded by then); the camera pauses
    meanwhile. `-enrolfolder <path>` enrols on start, logs `ENROL` and `CHECKIN` lines, and removes the test
    names 70 s later.
  - Checked with 9 photos: 4 frames of face_recognition.mp4 named after 3 people, a "Tan Shirt" folder with
    IMG_ files, bus.jpg as "Bus Group.jpg" and as IMG_0001.jpg, and dog_bicycle.jpg as "Dog.jpg".
    - Artelico: 4 people from 6 of 9 photos. Refused: Bus Group (2 faces of similar size), Dog (no face) and
      IMG_0001 (no name). Then on face_recognition.mp4, Curly Hair, Tan Shirt, Racquet Shirt and Walking Woman
      checked in at 15, 24, 42 and 47 s, which is when they appear.
    - Hailo Studio on the stick: the same 4 people from 6 of 9 photos, with the same check-ins at 15, 24, 42 and
      47 s. Its first try started before the face models were loaded ("No model is loaded"), so enrolment now
      waits for check-in's first analysed frame, and so does the button.
- **Two-step Face report** (`StudioCore/FaceReport.swift`, `Examples/FaceReportExample.swift`; the old one-prompt
  view was removed from LanguageExamples.swift), after the UGen300 FACE1 demo:
  1. The face is cropped (Apple Vision, largest face + 20 %).
  2. The picture model writes a flat JSON of 13 observations.
  3. A text model turns them into 5 scores plus a summary, 3 strengths and 4 tips (JSON).
  4. The card adds a pencil sketch (Core Image: grey, invert, blur, colour dodge, as sketch.py) with FACE1's
     thirds/fifths guides. The card can be shared as a picture (ImageRenderer).
  - Two model pickers. Hailo Studio swaps the VLM and the LLM on the stick; Artelico loads one GGUF after the other.
  - **Scores rate the photo and styling (lighting, sharpness, framing, expression, style harmony), not looks.**
    FACE1 scores symmetry, proportions, skin and contour; the previous version of ours deliberately gave no looks
    scores, and that choice is kept.
  - Small models copy a filled-in example: SmolVLM2 returned the example's "navy crew-neck jumper" for a striped
    top. The prompts now give `<hint>` templates; an answer that copies the template is rejected, and fields left
    as hints count as missing. All-equal scores are retried once (FACE1's check), and missing scores show "–"
    instead of a made-up 60.
  - Checked on frames of face_recognition.mp4:
    - Artelico (SmolVLM2 2.2B, then Qwen3 1.7B): 13 of 13 observations, scores 90/90/80/85/80, overall 85;
      about 250 and 210 tokens/s.
    - Hailo Studio (Qwen2-VL-2B, then Qwen2.5-1.5B on the stick): 12 of 13 observations, 5.5 tokens/s each.
      The small models misspell keys ("brods", "sharpeness"), so those fields stay empty.
    - `-facereport <picture>` runs a report and logs both answers.
- **Whisper tiny / tiny.en on the stick: not done**. What I found:
  - The h10h HEFs exist: tiny encoder 16.8 MB + decoder 33.5 MB; tiny.en 16.2 + 34.5 MB. That compares with
    Whisper-Base in the GenAI service (130 MB), which already transcribes at 0.2 s per second of audio.
  - Hailo's speech_recognition app needs a lot on the host:
    - log-mel on the host, in 10 s chunks;
    - a 51,865 x 384 float32 token-embedding table (about 80 MB, bigger than the HEFs) and an add-input table;
    - a GPT-2-style tokenizer;
    - a fixed-sequence decoder without a KV cache, run once per token over the whole sequence, with a repetition
      penalty.
  - In our runtime that also means:
    - a 2-input float decoder;
    - stream metadata for 4 new HEFs: `tools/hefinfo` no longer runs here, because its libhailort links
      Homebrew's libusb, which is gone;
    - a new download path.
  - The gain is a faster but less accurate model, next to a Whisper-Base that is already 5x real time. Skipped as
    agreed; the HEFs I fetched to size them are only in the scratchpad.
- **Chip health in Hailo Studio** (`CUGenRT`: `ugen_device_health`, `ugen_device_performance`, `ugen_device_power`,
  RPC actions 30, 31 and 25 of HailoRT 5.3.0's HailoRpcActionID; `UGenDevice.chipStats`; `ugen health [model]`;
  `UGenProbe/App/ChipStatsRows.swift` in the device screen, refreshed every 5 s, paused while Live or a
  language model uses the stick):
  - Stick answers: temperature 33-36 °C, core voltage 797-798 mV, self-test 0x0, stick CPU 26-28 %, and memory
    282 MB of 7.77 GB (the stick reports KiB, from Linux `free`). These are shown in the device screen; a
    screenshot was checked.
  - **Power: not supported.** Every power reading returns status 13 (HAILO_OPEN_FILE_FAILURE). In
    libhailort/src/device_common/control_soc.cpp the firmware reads power from a second hwmon
    (`/sys/class/hwmon/hwmon1/power1_input`), and the UGen300 has no such sensor.
  - **Neural-core utilisation is not shown.** The stick samples it while sleeping on the requesting connection,
    and our app has one connection. So it reads 0 % even with yolov8m running flat out (`ugen health yolov8m`).
    A second session on another interface could measure it, but I did not risk that driver change.
- Tests: LiveSourcesTests (3), FaceEnrolmentTests (3), FaceReportTests (3). swift test: 209, 13 skipped, 0 failures
  (with the other agents' tests). Artelico and Hailo Studio build for Mac Catalyst and iOS.
- Notes:
  - Test data (hard links, removed at the end): native/livetest-c, native/enroltest-c, ~/.hailo/livetest-c,
    ~/.hailo/enroltest-c, and Qwen2-VL-2B-Instruct.hef + Qwen2.5-1.5B-Instruct.hef linked into ~/.hailo/models.
  - A Hailo Studio killed by a test leaves its stick interface stuck, and the next launch recovers by rebooting
    the stick. Test runs now call `ugen identify` after each kill.

### Step 117. Steady video: even frame steps and smoothed boxes and skeletons (2026-11-21)

The user reported shaky pictures in videos. There were two causes:
- **Uneven frame steps.** Video files played in real time through AVPlayer, and each analysed frame was "whatever was newest", so
  the shown video jumped 2, then 4, then 3 frames as the model's time varied.
- **Per-frame jitter.** Every frame was detected from scratch, so boxes and body points moved a few pixels while nothing moved.

The fixes:
- **StudioCore `PacedVideo.swift`:**
  - `FramePacer`: the video moves on by the same step each time. The step changes only when the video drifts more than 0.4 s
    from the clock; when the model is faster than the video, the video plays at its own speed.
  - `PacedVideoReader`: AVAssetReader, decoding up to 8 frames ahead on its own queue, looping, applying the rotation. It is
    used by StreamSource for every video file (both apps: Live, the examples, the Privacy camera). Streams and cameras still
    take the newest frame, as they are live.
- **StudioCore `TrackSmoothing.swift`:** `TrackSmoother`, One-Euro filters per track number on the box (centre and size) and
  the body points. `ObjectTracker.track(_:time:)` uses it (`steadies`, on by default), which reaches Live (with Track on)
  and every pose screen. Masks keep their raw boxes, so they stay aligned.
- **Tests:** SteadyVideoTests (4: pacer evenness and catch-up, pacer waiting, jitter halved while a move is followed, the
  tracker's on/off). swift test: 213, 13 skipped, 0 failures.
- **Artelico on the Mac**, rep counter on the squats video: 25 FPS. At 43.4 s the front four were at 22 reps each, as expected
  at real-time speed (43.4 / 6 × 3 = 21.7), so the pacing keeps the video at real speed.
- Hailo Studio on the stick, same video: 24 reps for #1 at 48.0 s (expected 24). iOS Release installed (Artelico on iPad +
  iPhone, Hailo Studio on iPad; not launched), with Steps 110–113 and 115 included. DMGs rebuilt.

### Step 119. Sample videos checked by SHA-256, and a remove button (2026-11-21)

- **Checking:**
  - SampleMedia.videoChecks holds the size and SHA-256 of the 11 videos at artelico-models 7169446 (from the repository's
    file list).
  - A download is kept only if its SHA-256 matches (hashed in 4 MB pieces, off the main thread).
  - A kept file of the wrong size is downloaded again.
- **Device screen, both apps:** a "Sample videos" section: how many are downloaded and their size, and "Remove downloaded videos"
  (with a confirmation).
- **Mac test** (`-videochecktest <file>`, debug builds only, because the app's folder isn't readable from the terminal):
  - grok-squats.mp4 replaced by 11 bytes;
  - localVideo fetched it again, SHA-256 matches, 5 videos (190.8 MB);
  - after the remove: 0.
  - The Mac's downloaded sample videos were removed by the test.
- **Installed:** iOS Release on the iPad (both apps) and iPhone (Artelico), not launched. DMGs rebuilt.

### Step 118. Steady video on the web (2026-11-21)

Step 117's fix, ported to Artelico Web (and so the Space, through web/tools/build_space.py; not published).
- **Even frame steps** (`web/js/rules/steady-video.js` `FramePacer`, used by `PacedVideo` in `web/js/ui/runner.js`):
  - Every screen reads video through FrameRunner, so Live, all examples and the Privacy camera get it at once.
  - A video file's `<video>` is paused and seeked to the middle of each chosen frame. The frame rate comes from
    `requestVideoFrameCallback` while the video plays for a moment at the start (browsers do not tell it otherwise);
    without it (or without a known length) the video plays freely as before. Looping is done by the frame index.
  - The next frame is sought while the model works on the current one, so seeking costs nothing as long as it is
    faster than the model. Measured in headless Chrome: 13-18 ms median per seek (720p and the 560p squats video,
    p90 under 45 ms, also for example.mp4's 8 s keyframe gaps), 70 ms for 4K. Seeked frames were checked against
    ffmpeg's: 98 of 100 exact, 2 one frame off (neighbouring frames that look alike at 32x32).
  - Chosen over requestVideoFrameCallback on a playing video because that needs a buffer of copied frames (the
    wanted frame is often already past when the model is ready), and over WebCodecs because that needs an MP4
    demuxer. Cameras and streams still take the newest frame.
  - The frame time (`time` of onFrame and analyse) is now the video's own time for video files.
- **Steady boxes and skeletons** (`TrackSmoother`, reusing hand-games.js's OneEuroFilter, Swift's parameters):
  `ObjectTracker.track(result, time)` steadies numbered detection boxes and pose boxes and points (`steadies`, on by
  default). The pose screens and the example screens that track pass the frame time. Web Live has no Track switch
  (it never tracked), so nothing changes there; masks are not tracked on the web.
- **Tests:** rules-test.html has the 4 SteadyVideo tests (86 of 86 pass).
- **Measurements** (headless Chrome, squats video 24 fps, Squat alarm, first 20 s):
  - WebAssembly yolov8s_pose (5.4 FPS), before: steps 4,5,5,5,5,5,4,4,4,5,4,4,4,5,... (SD 0.49 frames, 24 changes),
    drift up to 0.46 s behind. After: 6 for 4 s while catching up from the slow first frame, then 4 for the rest
    (SD 0.95 over the 20 s because of that start, 9 changes), drift 0.01 s at 20 s (0.65 s at worst during the start).
  - WebGPU yolov8m_pose: before 27 analyses a second on a 24 fps video, so some frames were analysed twice (steps of
    0.6-1.2 frames); after exactly 1 frame each time, 24 FPS, drift at most 0.06 s.
  - Squat count at 43.4 s (one person, the biggest): 21 before and after on WebGPU (real time gives 21.7). On
    WebAssembly at 5 FPS the counter misses reps either way (17 and 15 free-running, 13 paced with steadying,
    10 paced without): the counter needs 3 frames in a pose, and the paced run lost a few early reps while its step
    was 6.
  - Steadiness, a still person (one frame of face_recognition.mp4 with changing noise, 12 s): keypoints moved 1.1 px
    a frame raw (median 0.8, p90 2.4, shoulders 2.1) and 0.2 px steadied (median 0.13, p90 0.4, shoulders 0.4).
    On the real face video (person talking and moving) 10.1 px raw and 9.7 px steadied: movement is followed.
- Checked with screenshots: Live on example.mp4 (30 FPS, looping), Squat alarm, Privacy camera with the fake camera
  and then a sample video.

### Step 120. Space republished with the steady-video fix (2026-11-21)

- helmo/artelico Space commit 18be385: Step 118's paced video files and steadied boxes and pose points. steady-video.js
  served (200); data/tddfa_bfm68.bin still left out.

### Step 121. Hailo's Python package (hailo_platform) built for the Mac; Jupyter works (2026-11-22)

- Hailo ships `hailo_platform` (pyHailoRT) for Linux and Windows only; the macOS USB port had "pyHailoRT wheel: not
  packaged". Its bindings compiled against the port's libhailort with 2 CMake lines patched
  (vendor/ref-hailort-macos-usb/hailort/libhailort/bindings/python/src/CMakeLists.txt; the Linux `.so` suffix and `-lrt`
  skipped on Apple; original kept as CMakeLists.txt.orig). No source changes.
- `tools/build_hailort_wheel.sh` → `dist/hailort-5.3.0-cp312-cp312-macosx_27_0_arm64.whl` (2.7 MB). Self-contained:
  libhailort and libusb are inside, linked by @loader_path, ad-hoc signed. macOS 27.2 or later (what the port was built
  for), Apple Silicon, Python 3.12. libusb 1.0.30 was reinstalled with Homebrew (it had gone from this Mac).
- `.venv-hailort` (Python 3.12, uv) has the wheel, JupyterLab and Pillow; Jupyter kernel "Python 3.12 (Hailo stick)".
- `notebooks/stick_quickstart.ipynb`, run headless with nbconvert, all cells pass:
  - YOLOv8s on testdata/bus.jpg: bus 0.89 and 3 people (0.92, 0.90, 0.88); 47 pictures/s with one-at-a-time runs.
  - Qwen2.5-1.5B chat streams word by word: 5.7 tokens/s (94 tokens), loads in 6.4 s.
  - Qwen2-VL-2B: "A man in a beige coat and sunglasses stands next to a blue bus with the text "CERO EMISIONES"…",
    8.0 s; loads in 9.1 s. Must be created with `optimize_memory_on_device=False`: the port is built with
    HAILO_BUILD_CLIENT_TOKENIZER=OFF, and True gives HailoRTStatusException 7 (not implemented).
  - Whisper-Base: 4.1 s of speech_sample.wav transcribed correctly in 0.7 s.
- Hailo's own tutorials (HRT_0…HRT_5) are installed with the wheel in site-packages/hailo_tutorials/notebooks; they
  need MODEL_PATH set, and HRT_4 needs the False above. HRT_2 (power measurement) is untested: the stick has no sensor.
- Still one program on the stick at a time: quit Hailo Studio before using a notebook.

### Step 122. A public copy for GitHub: ../hailo_github, exported by a script (2026-11-22)

- `tools/export_github.py` mirrors the shareable source into `../hailo_github` (384 files, 124 MB). Re-run it after
  changes. It leaves `.git` alone, then scans everything it wrote for private details and fails on any hit:
  - emails, the owner's name, the signing team, device IDs and names;
  - home folders, home network addresses, road-camera sites, tokens.
- **The repository's front page** lives in `github/`: README.md, CLAUDE.md, docs/ (building-apple, the-stick,
  models, porting, road-cameras), .gitignore and images/README.md.
- **Per-part guides:** `CLAUDE.md` files are in the project itself (Artelico, UGenProbe, UGenKit, web, native, tools).
- **LOG.md and FOLLOWUPS.md** are exported to docs/history/LOG.md and docs/FOLLOWUPS.md. Device IDs and names, LAN
  addresses, paths, camera sites and the weather-test city are replaced by placeholders.
- **Left out:**
  - builds, models, logs, venvs, vendor/, the DMGs, the old Artelico/Later views;
  - the runtime image;
  - tddfa_bfm68.bin;
  - web/samples/videos;
  - the 97 MB token table;
  - tools/build_streams.py and the export script itself.
- **Changed on export:**
  - project.yml uses `${DEVELOPMENT_TEAM}` / `${BUNDLE_ID_PREFIX}`, filled in by the new `tools/generate_projects.sh`;
  - streams.json is empty;
  - the Debug entitlements lose this project's path.
- **Code changes (here and exported):**
  - Road cameras are data-driven. `streams.json` = `{"cameras", "catalogues"}`; the 511 sites and the BC list moved
    from StreamCatalog.swift into the data (`build_streams.py` writes both apps'). With no catalogues the Fetch
    button hides. A `cameras.json` in Documents still overrides the list.
  - The web plays sample videos from `samples/videos/` when present, else from Hugging Face at revision 7169446.
    Checked in headless Chrome: frame read at 2 s, no tainted canvas.
  - tddfa_mobilenet_v1 is hidden in Swift (`VisionPipeline.supports`) and on the web (`app.js`, HEAD check) when
    tddfa_bfm68.bin is missing. Its two tests skip without the file.
  - `GenAITests.root` comes from `#filePath`, no longer a home path.
  - `web/test.html` uses `defaultSource()`: local models, else Hugging Face.
  - `build_labels.py` and `build_model_info.py` now name StudioCore/Resources.
- **New tools:**
  - `tools/fetch_runtime_image.sh`: ASUS zip → ext4, SHA-256 checked; needs zstd, which is now installed with
    Homebrew;
  - `native/tools/make_tddfa_bfm68.py`: from bfm_noneck_v3.pkl with an arrays-only unpickler; byte-identical to the
    bundled file;
  - `tools/patches/hailort-macos-usb-13c3dbb.patch`: the port changes used for the Python wheel.
- **Verified on the exported copy:**
  - `swift test`: 213 tests, 16 skipped, 0 failures. Here: 11 skipped, 0 failures.
  - The runtime-image script works, and its SHA-256 matches.
  - llama.cpp from a fresh clone + build_llama_xcframework.sh: OK.
  - generate_projects.sh, then both apps unsigned for Mac Catalyst and iOS: 4/4 builds OK.
  - The web from Hugging Face: yolov8s on bus.jpg (bus 0.91 + 4 people, WebGPU).
  - Afterwards the build outputs were deleted, leaving a clean checkout.
- **Licence:** the root LICENSE is the AGPL-3.0 already used by Artelico and the web, now covering the whole
  repository. Not yet a git repository; nothing pushed.

## Step 123: the web edition on GitHub Pages

- `web/tools/build_pages.py` builds the whole web edition (vision and language pages, no test pages, no
  `tddfa_bfm68.bin`) into `web/_site`, adds `coi-sw.js` (a service worker that adds COOP/COEP/CORP to the site's own
  responses) and a small script in `index.html` that registers it and reloads once per tab.
- `github/.github/workflows/pages.yml` (exported to the public repository, to be named `artelico`) runs it on pushes
  to `main` that change `web/`, then deploys with `actions/deploy-pages`.
- Checked: the site served under `/artelico/` by a plain `python3 -m http.server` (no headers, like Pages) reloads
  once and is then `crossOriginIsolated`, with the service worker in control, WebGPU and 207 models from Hugging
  Face. Built from the public copy it is 106 MB (largest file 28 MB, under Pages' 100 MB per file).
- Licence for the public repository confirmed: AGPL-3.0.
- README demo: `docs/media/artelico-traffic.gif` (in `github/`), Artelico Debug for Mac Catalyst launched with
  `-section traffic -samplevideo tiling_visdrone_720p.mp4`, 12 s of stills of the app's own window
  (`screencapture -l <window>`, about 8 a second); 4 s kept, cropped to the video and the counts, 580 px wide,
  7 frames a second, 96 colours: 0.9 MB.

## Step 124: sound in the web edition, and speech samples in six languages

- **Video sound** (`web/js/ui/runner.js`, `VideoSound`): video files are shown frame by frame from a paused
  `<video>`, so a second `<audio>` plays the same file in real time and is moved back to the frame shown when they
  drift more than 0.25 s apart. 🔊 / 🔇 button for video files and streams (remembered, on by default), hidden once
  the file is known to have no sound track. Chrome reports that through `captureStream().getAudioTracks()`
  (`webkitAudioDecodedByteCount` would need playing first). Muted, it keeps playing silently.
  - Checked in headless Chrome on Live: squats video, sound 0.15 s behind the frame analysed and following it;
    toggling works; parcels video (no sound track) hides the button; lanes video (silent track) shows it.
  - Fixed on the way: choosing a sample video while running only relabelled the source; it now switches to it
    (`useSample` reopens the source, as a chosen file already did).
- **Speech to text / Meeting notes**: a player for the audio used (sample, file, recording; remembers muting),
  a Samples menu, "Transcribe again", the language shown with the result.
  - Samples (`web/samples/speech/`, `SPEECH_SAMPLES` in `js/ui/credits.js`), 10–17 s, 48 kb/s mono MP3, 58–100 KB
    each: Kennedy's inaugural address (whisper.cpp's jfk.wav, public domain), LibriVox (public domain, cut after the
    LibriVox announcement): Machado de Assis (pt), Cervantes (es), Verne (fr), Collodi (it), Kafka (de). Cut points
    from whisper-small timestamps and ffmpeg silencedetect.
  - **Language detection**: Transformers.js does not detect the language; with none it assumed English and the
    Portuguese sample came out as an English "translation" ("The hand is the horse of the horse's hammer…").
    `Speech.detectLanguage` runs one decoder step after <|startoftranscript|> and takes the most likely of the 99
    language tokens: all six samples right, about 120 ms each (whisper-base, WebGPU). The field now says
    "empty: detect".
  - whisper-base with the language: Italian, English word for word; Portuguese, Spanish, French, German close
    (names misheard: "Krieger Samsa", "Estevan"). 0.4–1.4 s per clip after loading.
- The Space leaves out `samples/speech` (no speech pages there).

## Step 125: video sound and speech samples in the apps; Space republished

- **Space** helmo/artelico republished (commit ff6b0da): the video sound, the sidebar note, sample videos that switch
  while running. It keeps its sample videos (FOLLOWUPS item 8) and leaves out `samples/speech`.
- **Video sound** (both apps):
  - `StudioCore/VideoSound.swift`: an audio-only AVPlayer (an AVMutableComposition of the sound track, so the video
    is not decoded twice) moved back to the shown frame's presentation time when they drift more than 0.25 s apart;
    paused when no frame came for 1 s. `VideoSound.isOn` ("video.sound", on by default). On iOS it sets the audio
    session to playback (the speech screens leave it on record).
  - `PacedVideoReader(url:sound:)` keeps each decoded frame's presentation time and lets the sound follow it.
  - `StreamSource(url:sound:)` (both copies): files through VideoSound; streams unmute their own AVPlayer while the
    setting is on. Live gives the sound to one source only, the first video or stream.
  - `Examples/VideoSoundButton.swift` (shared): shown for a file with a sound track (checked with
    `loadTracks(.audio)`) and for streams. In the demo controls and in both Live screens (outside the controls that
    are disabled while running; Hailo Studio's row now disables its pickers one by one).
  - SwiftUI runs no `.task` on an empty view, so the button keeps a zero-size placeholder while hidden; without it
    the check never ran and the button never appeared.
- **Speech screens** (both apps): `Examples/SpeechSamples.swift` (shared): the web's seven samples (the six new
  MP3s copied into both `Samples/`), a player for the audio used (sample, file copied to temporary storage,
  recording) that remembers muting ("audio.muted"), a Samples menu. A sample sets the language. Artelico already
  detected the language (WhisperKit `detectLanguage`); Hailo Studio leaves it empty for the stick to detect.
  `-speechsample <file>` with `-autospeech`.
- Fixed on the way: Artelico's "Downloading openai_whisper-base…" bar stayed after the download (a late progress
  update set it again after `defer { speechProgress = nil }`).
- Checked on the Mac (Artelico, Debug, Mac Catalyst): Squat alarm with the squats video: "CoreMedia Playback" and
  audio-out to the built-in speakers while running; with `-video.sound NO` the button shows "Muted" next to "Other
  video". Speech: `-autospeech -speechsample assis_pt.mp3`: player with the title and LibriVox credit, Portuguese
  detected ("language: pt"), 16.6 s in 0.73 s with whisper-base. Both apps build for Mac Catalyst and iOS; UGenKit
  213 tests, 0 failures.
- Not checked: Hailo Studio running (the stick was not on this Mac); the devices (not reinstalled).

## Step 126: devices and DMGs (2026-11-22)

- iOS Release with Steps 123–125: Artelico on the iPad and iPhone, Hailo Studio on the iPad (not launched).
  The iOS Hailo Studio bundle is `UGenProbe/build-ios/Build/Products/Release-iphoneos/Hailo Studio.app`.
- DMGs rebuilt with `tools/make_dmg.sh`: dist/Artelico-1.0.dmg (17 MB), dist/Hailo-Studio-1.0.dmg (45 MB),
  checksums valid.

## Step 127: Whisper models on the Device screen (2026-11-22)

- Artelico's Device screen had no Whisper section, so "Download all" skipped them. Added "Speech models (Whisper)":
  the variants WhisperKit supports on the device (recommended one marked), each with its size, download/progress
  and delete, and "Download all N speech models (size)". Sizes: one call to the Hugging Face API
  (`argmaxinc/whisperkit-coreml?blobs=true`).
- `downloadWhisper(_:)` in SpeechEngine.swift: one download per model (a second request waits for it), progress in
  `whisperDownloads`, cancellable (Stop). The speech screens use it too.
- Mac: 21 models listed (26.6 GB), base ✓; whisper-tiny downloaded through the new path, loaded in 19 s and
  transcribed the German sample. iOS Release installed on the iPad and iPhone (not launched); Artelico DMG rebuilt.

## Step 128: model card links (2026-11-22)

- helmo/artelico-models README (commit 000922e): links to artelico.com and github.com/heldernoid/artelico. Same text in
  `native/tools/package_hf.py`. Card only; the apps' pinned revision needs no change (no model files touched).

## Step 129: a plain welcome page for the web edition (2026-11-22)

- Five design directions were proposed (artifact); the user preferred "a normal thing" without hype. Built a plain
  page in web/index.html instead: what Artelico is (the user's wording: an experiment in running computer vision and
  small speech-to-text, language and vision-language models on any device), what is here, how it works, other ways
  to run it, links, and Open Artelico. Shown once (artelico.welcomed), skipped for #screen links and in the Space;
  "About Artelico" in the sidebar brings it back.
- Checked in headless Chrome: desktop, dark, a #squat link opens the screen directly. Not yet exported or pushed.
- Downloads only on a click: Photos no longer runs the default model on opening (it downloaded yolov5m_wo_spp,
  91 MB, on every first visit). A new picture runs by itself only when the model is cached (`app.isDownloaded`);
  otherwise "Press Run to download … (N MB)". Speech to text: a sample or file waits for Transcribe until Whisper
  was downloaded once; Meeting notes has a Write notes button. Checked headless: nothing downloaded on opening,
  Run downloaded and ran (4 person, 1 bus), the next sample ran at once; Speech sample → "Press Transcribe", no download.
- Follow-up: Photos re-checks when the model or task changes (the message named the first model); demo screens
  (examples/kit.js) start on a chosen sample only if the models are here, else "Press Start to download … (N MB)".
  Headless: yolov9c → "Press Run to download yolov9c (101 MB)"; Squat alarm sample → "Press Start …", nothing downloaded.
