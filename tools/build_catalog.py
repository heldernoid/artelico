"""Builds models/catalog.json: every Hailo-10H model that Hailo Studio can use, with its download URL.
Source of truth is hailo-apps' resources_config.yaml (vendor/hailo-apps), read with a small parser so
no third-party YAML module is needed. Model Zoo version is pinned to the runtime on the stick."""
import json, re, sys, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "vendor/hailo-apps/hailo_apps/config/resources_config.yaml"
MODEL_ZOO = "https://hailo-model-zoo.s3.eu-west-2.amazonaws.com/ModelZoo/Compiled"
S3 = "https://hailo-csdata.s3.eu-west-2.amazonaws.com/resources"
GENAI = "https://dev-public.hailo.ai"
ZOO_VERSION = "v5.3.0"  # matches HailoRT 5.3.0 on the stick
SKIP_APPS = {"videos", "images", "json", "npy", "metadata", "whisper_h8"}

def parse():
    apps, app, arch, kind, entry = {}, None, None, None, None
    for line in CONFIG.read_text().split("\n"):
        if m := re.match(r"^([a-z_0-9]+):\s*(\*\w+)?", line):
            app, arch, entry = m.group(1), None, None
            continue
        if m := re.match(r"^\s{4}(hailo\w+):", line):
            arch, entry = m.group(1), None
            continue
        if m := re.match(r"^\s{6}(default|extra):", line):
            kind, entry = m.group(1), None
            continue
        if app in SKIP_APPS or arch != "hailo10h":
            continue
        if m := re.match(r"^\s+-\s+name:\s*\"?([\w.\-]+)\"?", line):
            entry = {"name": m.group(1), "default": kind == "default", "source": None, "url": None}
            apps.setdefault(app, []).append(entry)
        elif entry is not None and (m := re.match(r"^\s+(source|url):\s*\"?([^\"\s]+)\"?", line)):
            entry[m.group(1)] = m.group(2)
    return apps

def url_for(entry):
    if entry["url"]:
        return entry["url"]
    name = entry["name"]
    if entry["source"] == "mz":
        return f"{MODEL_ZOO}/{ZOO_VERSION}/hailo10h/{name}.hef"
    if entry["source"] == "s3":
        return f"{S3}/hefs/h10/{name}.hef"
    if entry["source"] == "gen-ai-mz":
        return f"{GENAI}/{ZOO_VERSION}/blob/{name}.hef"
    return None

def remote_size(url):
    try:
        request = urllib.request.Request(url, method="HEAD")
        with urllib.request.urlopen(request, timeout=20) as response:
            return int(response.headers.get("Content-Length", 0))
    except Exception as error:  # noqa: BLE001 - report and continue
        return f"error: {error}"

if __name__ == "__main__":
    apps = parse()
    models = {}
    for app, entries in apps.items():
        for entry in entries:
            record = models.setdefault(entry["name"], {"name": entry["name"], "source": entry["source"],
                                                       "url": url_for(entry), "apps": [], "default_for": []})
            record["apps"].append(app)
            if entry["default"]:
                record["default_for"].append(app)
    check = "--check" in sys.argv
    for record in models.values():
        if check:
            record["size"] = remote_size(record["url"]) if record["url"] else "no url"
    (ROOT / "models").mkdir(exist_ok=True)
    (ROOT / "models/catalog.json").write_text(json.dumps(sorted(models.values(), key=lambda r: r["name"]), indent=1))
    for record in sorted(models.values(), key=lambda r: r["name"]):
        print(f'{record["name"]:<40} {record["source"] or "?":<10} {record.get("size", "")!s:<12} {",".join(record["apps"])}')
    print(len(models), "models")
