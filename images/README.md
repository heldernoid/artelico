# images/

The UGen300's runtime image goes here: `core-image-hailo-hailo10-usb-dongle.ext4` (103 MB). It's Hailo's / ASUS's
file, so it isn't in the repository. Get it with:

```sh
tools/fetch_runtime_image.sh
```

Hailo Studio bundles it (its `project.yml` points here), and `ugen boot` and the device tests read it from here.
