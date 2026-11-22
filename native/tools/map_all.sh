#!/bin/zsh
# Runs `ugen native-map` (stick vs Core ML) for every converted model that has no .native.json yet.
# usage: native/tools/map_all.sh [model ...]
cd "$(dirname $0)/../.."
mkdir -p native/map-logs
python3 - "$@" <<'PY' > native/map-jobs.txt
import json, os, sys
catalog = json.load(open("UGenKit/Sources/StudioCore/Resources/models.json"))
items = catalog if isinstance(catalog, list) else catalog.get("models", catalog)
task_names = {"ocr": "ocr", "clip": "classification", "embedding": "classification", "face": "face"}
image_for = {"classification": "testdata/samples/apple.jpg", "depth": "testdata/samples/room.png",
             "semantic_segmentation": "testdata/samples/lane.png", "lane_detection": "testdata/samples/lane.png",
             "oriented_detection": "testdata/samples/dota_image.png", "super_resolution": "testdata/samples/input_image.png"}
ugen_tasks = {"detection", "pose", "classification", "depth", "semantic_segmentation", "instance_segmentation",
              "oriented_detection", "super_resolution", "lane_detection", "face", "ocr", "clip", "stereo_depth"}
wanted = set(sys.argv[1:])
for m in items:
    name = m["name"]
    if wanted and name not in wanted: continue
    if not os.path.isdir(f"native/coreml/{name}.mlpackage"): continue
    if not wanted and os.path.exists(f"native/coreml/{name}.native.json"): continue
    task = task_names.get(m["tasks"][0], m["tasks"][0])
    if task not in ugen_tasks: task = "classification"   # no ugen decoder for this task yet: raw outputs only
    if name in ("arcface_mobilefacenet", "clip_vit_b_32_image_encoder", "ocr"): task = "classification"   # raw outputs only
    print(name, task, image_for.get(task, "testdata/bus.jpg"))
PY
while read name task image; do
  echo "== $name ($task)"
  # The stick can reset after a failed transfer (detr_resnet_v1_18_bn, 2026-11-19); everything after it
  # then failed with "Driver not found". Wait for it to come back and try again (up to 3 times).
  for attempt in 1 2 3; do
    (cd UGenKit && UGEN_ROOT=.. .build/debug/ugen native-map $task $name ../$image ../native/coreml/$name.mlpackage) > native/map-logs/$name.txt 2>&1
    grep -qE 'Driver not found|Could not open the driver|USB transfer failed|stick is restarting' native/map-logs/$name.txt || break
    echo "   stick not available (attempt $attempt), waiting 20 s"
    sleep 20
  done
  tail -4 native/map-logs/$name.txt
done < native/map-jobs.txt
