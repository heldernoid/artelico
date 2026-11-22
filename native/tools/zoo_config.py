"""Resolve a Hailo Model Zoo v5.3.0 network config (with its `base:` chain) and its .alls script.

    zoo_config.py [model ...]   -> prints a JSON summary per model
"""
import json, os, re, sys
import yaml

ZOO = os.path.join(os.path.dirname(__file__), "../../vendor/hailo_model_zoo-5.3.0/hailo_model_zoo")
CFG = os.path.join(ZOO, "cfg")


def merge(a, b):
    out = dict(a)
    for k, v in b.items():
        out[k] = merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


def load(path):
    with open(path) as f:
        data = yaml.safe_load(f) or {}
    result = {}
    for base in data.pop("base", []) or []:
        result = merge(result, load(os.path.join(CFG, base)))
    return merge(result, data)


def find_alls(name):
    for root, _, files in os.walk(os.path.join(CFG, "alls")):
        for f in files:
            if f == name:
                yield os.path.join(root, f)


def config(model):
    cfg = load(os.path.join(CFG, "networks", f"{model}.yaml"))
    alls_name = (cfg.get("paths") or {}).get("alls_script")
    alls_text = ""
    paths = sorted(find_alls(alls_name)) if alls_name else []
    # Prefer the hailo10h script when several targets have one.
    paths.sort(key=lambda p: (("hailo10h" not in p), p))
    if paths:
        alls_text = open(paths[0]).read()
    mean = std = None
    m = re.search(r"normalization\(\[([^\]]*)\],\s*\[([^\]]*)\]\)", alls_text)
    if m:
        mean = [float(x) for x in m.group(1).split(",")]
        std = [float(x) for x in m.group(2).split(",")]
    else:
        n = (cfg.get("parser") or {}).get("normalization_params") or {}
        if n.get("normalize_in_net") and n.get("mean_list") is not None:
            mean, std = n["mean_list"], n["std_list"]
    hn = cfg.get("hn_editor") or {}
    return {
        "name": model,
        "url": (cfg.get("paths") or {}).get("url"),
        "onnx": ((cfg.get("paths") or {}).get("network_path") or [None])[0],
        "nodes": (cfg.get("parser") or {}).get("nodes"),
        "start_node_shapes": (cfg.get("parser") or {}).get("start_node_shapes"),
        "mean": mean, "std": std,
        "bgr2rgb": hn.get("bgr2rgb", False),
        "yuv": any(hn.get(k) for k in ("yuv2rgb", "yuy2", "nv12")),
        "input_resize": (hn.get("input_resize") or {}).get("enabled", False),
        "input_shape": (cfg.get("preprocessing") or {}).get("input_shape"),
        "task": (cfg.get("info") or {}).get("task"),
        "license": (cfg.get("info") or {}).get("license_name"),
        "alls": paths[0][len(CFG) + 1:] if paths else None,
        "alls_ops": sorted(set(re.findall(r"^\s*(?:\w+\s*=\s*)?(\w+)\(", alls_text, re.M))),
        "meta_arch": (cfg.get("postprocessing") or {}).get("meta_arch"),
        "anchors": ((cfg.get("postprocessing") or {}).get("anchors") or {}).get("sizes"),
        "strides": ((cfg.get("postprocessing") or {}).get("anchors") or {}).get("strides"),
    }


if __name__ == "__main__":
    print(json.dumps([config(m) for m in sys.argv[1:]], indent=1))
