# Hailo Studio (folder `UGenProbe/`)

Everything here runs **on the stick**: the Hailo-10H model zoo, the UGen300 demo screens, chat, picture questions and
speech.
- **iPad:** an app plus a DriverKit driver.
- **Mac:** the same app as Mac Catalyst, which opens the stick through IOKit, with no driver.

The folder, the Xcode project and the bundle identifier keep the project's first name, `UGenProbe`. The product is
named "Hailo Studio" (module `HailoStudio`).

## Build

See `docs/building-apple.md`.

- **Before building:** fetch `../images/core-image-hailo-hailo10-usb-dongle.ext4` with
  `tools/fetch_runtime_image.sh`. It's bundled in the app.
- **Generating and building:** run `tools/generate_projects.sh`, then build the `UGenProbe` scheme.
- **On the iPad:** register the iPad before the first signed build (DriverKit profile), then turn the driver on in
  Settings > Apps > Hailo Studio > Drivers.

## Parts

- **`Driver/` (C++, DriverKit, iPadOS only):**
  - matches the ASUS vendor ID (`idVendor` 2821) on `IOUSBHostDevice`;
  - exposes a user client that is only a USB pipe: control transfers, bulk transfers, configuration and reset.
  - **All protocol logic is in UGenKit's C runtime**, used through `ugen_ios_transport.c`.
  - `Shared/` holds the selectors and structures that the app and the driver share.
- **`App/StudioModel.swift`:**
  - connecting: find the stick, upload the runtime if it's in loader mode, reconnect after the app was killed;
  - the models folder, and HEF downloads from Hailo's servers (with progress);
  - the loaded model, and refusing REST API requests while a live screen uses the stick.
- **`App/DeviceView.swift`:**
  - stick state and firmware, the USB-C power offered, chip readouts (`ChipStatsRows.swift`);
  - the sample videos;
  - the REST API switch;
  - the model list (download / delete per model, "Download all");
  - the language and speech HEFs. Those come from `dev-public.hailo.ai`, which only serves browsers, so
    `WebDownload.swift` downloads them in an in-app browser view.
- **The other screens:**
  - `VisionView.swift` (photos);
  - `LiveView.swift` + `StreamSource.swift` + `CameraSource.swift`;
  - `ChatView.swift`, `AskImageView.swift`, `SpeechView.swift` (GenAI on the stick, `LanguageModels.swift`);
  - `APIServer.swift`: the REST API, documented in the file's header comment.
- **The demo screens** come from `../Artelico/App/Examples` (shared with Artelico). This app's `ExampleSupport.swift`
  runs them on the stick.
  - Text tasks with CLIP B/32 download that model's text pieces from the model repository (`clipFilesRevision` in
    `StudioModel.swift`).

## Testing

- **Launch arguments:** `-section <name>`, `-sample <file>`, `-autorun`, `-api`, `-stream <url>`, `-testshots`,
  `-livelog`, `-sightings`. The shared screens add more; see `Artelico/CLAUDE.md`.
- **Without the app:** most stick behaviour can be checked from `UGenKit` with `swift run ugen …` and
  `UGEN_DEVICE_TESTS=1 swift test`.
- **One holder at a time:** quit the app first. Only one process can hold the stick.
- **The iPad's only USB-C port** is taken by the stick. Install and launch over Wi-Fi with `xcrun devicectl`; see
  `docs/building-apple.md` §6.

## Rules

- **Identical copies:** `StreamCatalog.swift`, `streams.json`, `CameraSource.swift` and `Recorder.swift` are the same
  as Artelico's. Keep them identical.
- **The driver stays a pipe:** protocol changes belong in `UGenKit/Sources/CUGenRT`, not the driver. A driver
  change needs a reinstall and, on the iPad, often a replug.
- **When the runtime doesn't appear:** if the stick ends up in loader mode and "The runtime did not appear after
  the upload", replug it. It happens after a killed session.
