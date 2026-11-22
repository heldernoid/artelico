"""Extracts label sets from hailo-apps sources into UGenKit/Sources/StudioCore/Resources/labels.json."""
import json, re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APPS = ROOT / "vendor/hailo-apps/hailo_apps/cpp"

def strings(path):
    return re.findall(r'=\s*"([^"]*)"\s*;', path.read_text())

imagenet = strings(APPS / "classification/imagenet_labels.hpp")
cityscapes = []
for line in (APPS / "semantic_segmentation/cityscape_labels.hpp").read_text().split("\n"):
    if m := re.search(r"Vec3f\(([\d.]+),\s*([\d.]+),\s*([\d.]+)\s*\);\s*//\s*\w+\s*-\s*(\w+)", line):
        cityscapes.append({"name": m.group(4), "color": [int(float(m.group(i))) for i in (1, 2, 3)]})
dota = re.findall(r'"([^"]+)"', (APPS / "common/labels/dota_fifteen.hpp").read_text())
dota = [d for d in dota if not d.endswith(".hpp")]
out = {"imagenet": imagenet, "cityscapes": cityscapes, "dota": dota}
target = ROOT / "UGenKit/Sources/StudioCore/Resources/labels.json"
target.write_text(json.dumps(out, indent=0))
print({k: len(v) for k, v in out.items()}, "->", target.relative_to(ROOT))
print(imagenet[:3], cityscapes[:2], dota[:15])
