"""Runs every model in UGenKit's model table on the stick from the Mac, through tools/ugenrt.
mode "native": no stream parameters, outputs in the HEF's own types.
mode "float":  tensor outputs requested as float32 (NMS and argmax outputs left as they are)."""
import json, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
mode = sys.argv[1] if len(sys.argv) > 1 else "native"
only = set(sys.argv[2:])
models = json.load(open(ROOT / "UGenKit/Sources/UGenKit/Resources/models.json"))
results = {}
for m in models:
    if only and m["name"] not in only:
        continue
    args = [str(ROOT / "tools/ugenrt"), "run", str(ROOT / f"models/{m['name']}.hef"), tempfile.mkdtemp(), "20"]
    args += [f"in:{s['frameSize']}" for s in m["inputs"]]
    for s in m["outputs"]:
        as_float = mode == "float" and s["order"] not in ("NMS_BY_CLASS", "NHW") and s["type"] != "FLOAT32"
        args.append(f"out:{s['elements'] * 4}:{s['name']}" if as_float else f"out:{s['frameSize']}")
    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=180)
        line = (done.stdout.strip().split("\n")[-1] if done.stdout.strip() else "") or done.stderr.strip().split("\n")[-1]
    except subprocess.TimeoutExpired:
        line = "TIMEOUT"
    results[m["name"]] = line
    print(f"{m['name']:<38} {line}", flush=True)
ok = sum(1 for v in results.values() if v.startswith("OK"))
print(f"{ok}/{len(results)} models ran ({mode})")
json.dump(results, open(ROOT / f"logs/all-models-{mode}.json", "w"), indent=1)
