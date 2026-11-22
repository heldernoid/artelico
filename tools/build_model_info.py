"""Builds UGenKit's model table from ground truth produced by Hailo's own library:
- tools/hefinfo (stream names, types, shapes, quantization scale and zero point), and
- `hailortcli parse-hef` text in logs/parse-hef/ (frame sizes to cross-check, NMS thresholds),
joined with the download catalog (models/catalog.json).
Output: UGenKit/Sources/StudioCore/Resources/models.json"""
import json, re, subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TASKS = {  # hailo-apps app name -> Studio task
    "detection": "detection", "simple_detection": "detection", "tiling": "detection",
    "pose_estimation": "pose", "pose_estimation_onnx_postproc": "pose",
    "instance_segmentation": "instance_segmentation", "onnxrt_hailo_pipeline": "instance_segmentation",
    "classifier": "classification", "depth": "depth", "depth_estimation_stereo": "stereo_depth",
    "semantic_segmentation": "semantic_segmentation", "oriented_object_detection": "oriented_detection",
    "super_resolution": "super_resolution", "lane_detection": "lane_detection", "paddle_ocr": "ocr",
    "face_recognition": "face", "reid_multisource": "face", "clip": "clip", "v2a_demo": "embedding",
}
BYTES = {"UINT8": 1, "UINT16": 2, "FLOAT32": 4}

def parse(text):
    info = {"inputs": [], "outputs": [], "nms": None}
    for line in text.split("\n"):
        line = line.strip()
        if m := re.match(r"(Input|Output)\s+(\S+)\s+(\w+),\s+(.*)$", line):
            kind, name, dtype, rest = m.groups()
            stream = {"name": name, "type": dtype}
            if n := re.match(r"HAILO NMS BY CLASS\(number of classes: (\d+), maximum bounding boxes per class: (\d+), maximum frame size: (\d+)\)", rest):
                stream.update(order="NMS_BY_CLASS", classes=int(n.group(1)), maxBoxes=int(n.group(2)), frameSize=int(n.group(3)))
            elif n := re.match(r"HAILO NMS WITH BYTE MASK\(number of classes: (\d+), maximum bounding boxes total: (\d+), maximum frame size: (\d+)\)", rest):
                # Boxes with a per-box mask, from the on-chip YOLOv5-seg post-process (yolov5*_seg_hpp).
                stream.update(order="NMS_BYTE_MASK", classes=int(n.group(1)), maxBoxes=int(n.group(2)), frameSize=int(n.group(3)))
            elif n := re.match(r"(\w+)\(([\dx]+)\)", rest):
                dims = [int(d) for d in n.group(2).split("x")]
                stream.update(order=n.group(1), shape=dims)
                elements = 1
                for d in dims:
                    elements *= d
                stream["frameSize"] = elements * BYTES[dtype]
                stream["elements"] = elements
            else:
                stream.update(order="UNKNOWN", raw=rest)
            info["inputs" if kind == "Input" else "outputs"].append(stream)
        elif m := re.match(r"Score threshold: ([\d.]+)", line):
            info.setdefault("nmsScore", float(m.group(1)))
        elif m := re.match(r"IoU threshold: ([\d.]+)", line):
            info.setdefault("nmsIoU", float(m.group(1)))
        elif m := re.match(r"Op (\w+)", line):
            info.setdefault("op", m.group(1))
    return info

# Hailo Model Zoo v5.3.0 task pages (docs/public_models/HAILO10H/HAILO10H_<page>.rst) -> Studio tasks.
# Pages without a Studio task yet keep their own name as the task (not decodable until a decoder exists).
PAGE_TASKS = {
    "classification": ["classification"], "object_detection": ["detection"], "pose_estimation": ["pose"],
    "instance_segmentation": ["instance_segmentation"], "semantic_segmentation": ["semantic_segmentation"],
    "depth_estimation": ["depth"], "zero_shot_depth_estimation": ["depth"], "stereo_depth_estimation": ["stereo_depth"],
    "oriented_object_detection": ["oriented_detection"], "super_resolution": ["super_resolution"],
    "face_detection": ["face"], "face_recognition": ["face"], "text_detection": ["ocr"], "text_recognition": ["ocr"],
    "zero_shot_classification": ["clip"], "text_image_retrieval": ["clip"],
}
ZOO_HEF = "https://hailo-model-zoo.s3.eu-west-2.amazonaws.com/ModelZoo/Compiled/v5.3.0/hailo10h/{}.hef"

if __name__ == "__main__":
    catalog = {m["name"]: m for m in json.load(open(ROOT / "models/catalog.json"))}
    pages = json.load(open(ROOT / "native/zoo-hailo10h-inventory.json"))   # model -> task page
    # The Hailo-10H Model Zoo models hailo-apps does not use: same download place for all of them.
    for name, page in pages.items():
        if name not in catalog:
            catalog[name] = {"name": name, "source": "mz", "url": ZOO_HEF.format(name), "apps": [], "default_for": [],
                             "size": (ROOT / f"models/{name}.hef").stat().st_size}
        catalog[name]["page"] = page
    # Language and speech models (Hailo's GenAI zoo) are used by Chat / Speech, not the vision list.
    catalog = {n: e for n, e in catalog.items() if e.get("source") != "gen-ai-mz"}
    # parse-hef text for every model in the catalog that has a HEF here.
    for name in catalog:
        text = ROOT / f"logs/parse-hef/{name}.txt"
        if not text.exists() and (ROOT / f"models/{name}.hef").exists():
            out = subprocess.run([str(ROOT / "vendor/ref-hailort-macos-usb/build-macos-usb/hailort/hailortcli/hailortcli"),
                                  "parse-hef", str(ROOT / f"models/{name}.hef")], capture_output=True, text=True)
            text.write_text(out.stdout)
    models, problems = [], []
    for path in sorted((ROOT / "logs/parse-hef").glob("*.txt")):
        name = path.stem
        if name not in catalog:
            continue
        info = parse(path.read_text())
        # Replace the text-derived streams with hefinfo's, which carry quantization parameters.
        raw = json.loads(subprocess.run([str(ROOT / "tools/hefinfo"), str(ROOT / f"models/{name}.hef")],
                                        capture_output=True, text=True, check=True).stdout)
        expected = {s["name"]: s["frameSize"] for s in info["inputs"] + info["outputs"]}
        info["inputs"], info["outputs"] = [], []
        for r in raw:
            dtype = {1: "UINT8", 2: "UINT16", 3: "FLOAT32"}[r["formatType"]]
            order = {1: "NHWC", 3: "FCR", 4: "NCHW", 5: "NHW", 6: "NC", 20: "NMS_BYTE_MASK", 22: "NMS_BY_CLASS"}.get(r["formatOrder"], f"ORDER_{r['formatOrder']}")
            stream = {"name": r["name"], "type": dtype, "order": order}
            if order == "NMS_BY_CLASS":
                stream.update(classes=r["classes"], maxBoxes=r["maxBoxes"],
                              frameSize=r["classes"] * (1 + r["maxBoxes"] * 5) * 4)
            elif order == "NMS_BYTE_MASK":
                stream.update(classes=r.get("classes"), maxBoxes=r.get("maxBoxesTotal") or r.get("maxBoxes"),
                              frameSize=expected.get(r["name"]))
            else:
                elements = r["height"] * r["width"] * r["features"]
                stream.update(height=r["height"], width=r["width"], features=r["features"], elements=elements,
                              frameSize=elements * BYTES[dtype], qpZp=r["qpZp"], qpScale=r["qpScale"])
            if expected.get(r["name"]) != stream["frameSize"]:
                problems.append(f"{name}: frame size mismatch on {r['name']}")
            info["inputs" if r["direction"] == "input" else "outputs"].append(stream)
        entry = catalog[name]
        tasks = sorted({TASKS[a] for a in entry["apps"] if a in TASKS} | set(PAGE_TASKS.get(entry.get("page"), [entry["page"]] if entry.get("page") else [])))
        if not info["inputs"] or not info["outputs"] or any(s["order"].startswith("ORDER_") for s in info["inputs"] + info["outputs"]):
            problems.append(name)
        models.append({"name": name, "tasks": tasks, "url": entry["url"], "fileSize": entry.get("size") if isinstance(entry.get("size"), int) else None,
                       "taskPage": entry.get("page"),
                       "defaultFor": sorted({TASKS[a] for a in entry["default_for"] if a in TASKS}), **info})
    out = ROOT / "UGenKit/Sources/StudioCore/Resources/models.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(models, indent=1))
    print(len(models), "models written to", out.relative_to(ROOT))
    # hefinfo gives one scale per stream; outputs quantized per channel get theirs from the HEF itself.
    subprocess.run(["python3", str(ROOT / "tools/hef_feature_quant.py")], check=True)
    print("problems:", problems)
    by_task = {}
    for m in models:
        for t in m["tasks"]:
            by_task.setdefault(t, []).append(m["name"])
    for t, names in sorted(by_task.items()):
        print(f"  {t:<24} {len(names):>2}  {', '.join(names)}")
    odd = sorted({(s['type'], s['order']) for m in models for s in m['inputs'] + m['outputs']})
    print("stream kinds:", odd)
    multi_in = [m["name"] for m in models if len(m["inputs"]) > 1]
    print("multi-input models:", multi_in)
