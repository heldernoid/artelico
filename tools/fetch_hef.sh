#!/bin/sh
# Downloads one compiled Hailo-10H HEF (Model Zoo v5.3.0) into models/<name>.hef. Used by download_hefs.sh.
name=$1
base=https://hailo-model-zoo.s3.eu-west-2.amazonaws.com/ModelZoo/Compiled/v5.3.0/hailo10h
out=models/$name.hef
magic=$(xxd -p -l 4 models/yolov8m.hef)
if [ -s "$out" ]; then echo "have $name"; exit 0; fi
code=$(curl -s -L --retry 3 -o "$out.part" -w "%{http_code}" "$base/$name.hef")
if [ "$code" = 200 ] && [ "$(xxd -p -l 4 "$out.part")" = "$magic" ]; then mv "$out.part" "$out"; echo "ok $name $(du -h "$out" | cut -f1)"
else rm -f "$out.part"; echo "FAILED $name (HTTP $code)"; fi
