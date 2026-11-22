"""Download, cut, convert and check every model in native/zoo-configs.json.

For each model: download the Model Zoo zip into native/src/<name>/, cut the ONNX graph at the same
start/end nodes Hailo uses (so outputs match the HEF's outputs, before Hailo's on-chip post-processing),
convert to Core ML with the model's normalization baked in, and compare with ONNX Runtime on bus.jpg.
Writes native/coreml/<name>.mlpackage and a line per model to native/convert-report.jsonl.

usage: convert_all.py [name ...]   (default: all)
"""
import json, os, subprocess, sys, time, traceback, urllib.request, zipfile
import numpy as np, onnx, onnxruntime as ort

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
NATIVE = os.path.join(ROOT, "native")
PY = os.path.join(ROOT, ".venv-convert/bin/python")


def download(cfg):
    folder = os.path.join(NATIVE, "src", cfg["name"])
    os.makedirs(folder, exist_ok=True)
    archive = os.path.join(folder, cfg["url"].rsplit("/", 1)[-1])
    if not os.path.exists(archive):
        # curl with a stall timeout: urllib waits forever on a dead connection. A single S3 connection can
        # get stuck slow (450 KB/s while a new one did 13 MB/s, 2026-11-19), so anything under 1 MB/s for
        # a minute is dropped and retried on a new connection, resuming the partial file (-C -).
        subprocess.run(["curl", "-sfL", "--retry", "10", "--retry-all-errors", "-C", "-",
                        "--speed-limit", "1000000", "--speed-time", "60",
                        "-o", archive + ".part", cfg["url"]], check=True, timeout=7200)
        os.rename(archive + ".part", archive)
    if archive.endswith(".zip"):
        with zipfile.ZipFile(archive) as z:
            z.extractall(folder)
    found = [os.path.join(r, f) for r, _, fs in os.walk(folder) for f in fs if f.endswith((".onnx", ".tflite"))]
    return found


TFLITE_PY = os.path.join(ROOT, ".venv-tflite/bin/python")

# Models whose float16 Core ML output changes the result (checked with check_decoded.py / compare.py);
# float32 matches ONNX Runtime exactly. They run on the GPU instead of the Neural Engine (about 1.2-2x slower).
#   fastvit_sa12: logits; yolov12n: scores off by up to 0.41 (attention blocks);
#   yolo26*_seg: scores off by up to 0.67, also on the CPU;
#   clip_resnet_50_text_encoder: NaN everywhere on real token embeddings (float16 overflow; the zero input
#   of compare.py passed), also on the CPU.
FP32_MODELS = {"fastvit_sa12", "yolov12n", "yolo26n_seg", "yolo26s_seg", "yolo26m_seg", "yolo26l_seg", "clip_resnet_50_text_encoder"}


def from_tflite(path, name):
    """TFLite -> ONNX with tf2onnx (in its own environment, .venv-tflite). The image input is turned
    channels-first (TFLite uses NHWC) so the rest of the pipeline treats it like the ONNX models;
    tensor names are kept, so Hailo's cut points still apply."""
    out = os.path.join(NATIVE, "src", name, f"{name}.from_tflite.onnx")
    if os.path.exists(out):
        return out
    probe = out + ".probe.onnx"
    subprocess.run([TFLITE_PY, "-I", "-m", "tf2onnx.convert", "--tflite", path, "--output", probe, "--opset", "13"],
                   capture_output=True, text=True, timeout=3600, check=True)
    image_inputs = [i.name for i in onnx.load(probe).graph.input
                    if len(i.type.tensor_type.shape.dim) == 4 and i.type.tensor_type.shape.dim[3].dim_value == 3]
    os.remove(probe)
    args = [TFLITE_PY, "-I", "-m", "tf2onnx.convert", "--tflite", path, "--output", out, "--opset", "13"]
    if image_inputs:
        args += ["--inputs-as-nchw", ",".join(image_inputs)]
    subprocess.run(args, capture_output=True, text=True, timeout=3600, check=True)
    return out


CUT_INPUT_SHAPE = None   # set per model by main() from the Model Zoo config (H, W, C)


def info_input_shape(name):
    """(H, W, C) from the network config's info section ("300x300x3"), with its base chain."""
    sys.path.insert(0, os.path.join(NATIVE, "tools"))
    import zoo_config
    try:
        cfg = zoo_config.load(os.path.join(zoo_config.CFG, "networks", f"{name}.yaml"))
    except FileNotFoundError:
        return None
    text = str((cfg.get("info") or {}).get("input_shape") or "")
    parts = [int(p) for p in text.split("x") if p.strip().isdigit()]
    return parts if len(parts) == 3 else None


def cut(path, nodes, out_path):
    """Keep the part of the graph between Hailo's start node and end nodes."""
    model = onnx.load(path)
    graph = model.graph
    if not nodes or not any(nodes):
        return path, [o.name for o in graph.output]
    start, ends = nodes[0], nodes[1]
    if isinstance(ends, str):
        ends = [ends]
    by_name = {n.name: n for n in graph.node}
    initializers = {i.name for i in graph.initializer}
    graph_inputs = [i.name for i in graph.input if i.name not in initializers]
    consumers = {}
    for n in graph.node:
        for i in n.input:
            consumers.setdefault(i, []).append(n)
    if start in by_name and by_name[start].op_type == "Pad":
        # TFLite exports (efficientdet_lite0): Hailo starts at pad_to_bounding_box, which pads the resized
        # picture to the size it already has (a no-op), in NHWC before tf2onnx's Transpose to NCHW. Start
        # after that Transpose instead, so the input is the usual 1x3xHxW image.
        after = consumers.get(by_name[start].output[0], [])
        if len(after) == 1 and after[0].op_type == "Transpose":
            perm = list(next((a.ints for a in after[0].attribute if a.name == "perm"), []))
            nxt = consumers.get(after[0].output[0], [])
            if perm == [0, 3, 1, 2] and nxt:
                print(f"start moved past the no-op Pad + Transpose to {nxt[0].op_type}")
                start = nxt[0].name
    if start in graph_inputs or start is None:
        inputs = graph_inputs
    elif start in by_name:
        inputs = [x for x in by_name[start].input if x not in initializers][:1]
    else:
        inputs = graph_inputs
    tensors = {o for n in graph.node for o in n.output}
    outputs = []
    for e in ends:
        if e in by_name:
            outputs.append(by_name[e].output[0])
        elif e in tensors:   # some configs name the tensor itself
            outputs.append(e)
    if len(outputs) != len(ends):
        # The config names nodes this export does not have (clip_vit_l_14_laion2B_text_encoder: Add_4 and
        # "output"; the file already starts at the token embeddings). Keep the whole graph.
        print(f"end nodes not in this graph ({[e for e in ends if e not in by_name and e not in tensors]}); keeping the whole graph")
        return path, [o.name for o in graph.output]
    try:
        onnx.utils.extract_model(path, out_path, inputs, outputs)
        cut_inputs = onnx.load(out_path, load_external_data=False).graph.input
        if any(not i.type.tensor_type.shape.dim for i in cut_inputs):
            raise ValueError("cut input has no shape")
    except Exception as error:
        # extract_model validates the whole original graph first; TFLite graphs converted by tf2onnx can
        # contain TensorFlow preprocessing ONNX cannot represent (TensorArray loops), which Hailo cuts
        # away anyway. Copy just the part between the cut points instead (this also gives a cut input
        # after a channels-first Transpose its 1x3xHxW shape).
        print(f"extract_model failed ({type(error).__name__}: {error}); copying the subgraph directly")
        extract_subgraph(model, inputs, outputs, out_path, CUT_INPUT_SHAPE)
    return out_path, outputs


def extract_subgraph(model, inputs, outputs, out_path, input_shape=None):
    """The nodes needed to compute `outputs` from `inputs`, with only the initializers they use. The new
    graph input gets shape 1x3xHxW when it is the output of a channels-first Transpose (tf2onnx's
    NHWC -> NCHW in front of the first convolution)."""
    graph = model.graph
    producer = {o: n for n in graph.node for o in n.output}
    keep, seen, stack = set(), set(), list(outputs)
    while stack:
        tensor = stack.pop()
        if tensor in seen or tensor in inputs:
            continue
        seen.add(tensor)
        node = producer.get(tensor)
        if node is None:
            continue
        keep.add(id(node))
        stack.extend(i for i in node.input if i)
    nodes = [n for n in graph.node if id(n) in keep]
    used = {i for n in nodes for i in n.input}
    initializers = [t for t in graph.initializer if t.name in used]
    new_inputs = []
    for name in inputs:
        shape = None
        source = producer.get(name)
        if source is not None and source.op_type == "Transpose":
            perm = list(next((a.ints for a in source.attribute if a.name == "perm"), []))
            if perm == [0, 3, 1, 2] and input_shape:
                shape = [1, input_shape[2], input_shape[0], input_shape[1]]
        new_inputs.append(onnx.helper.make_tensor_value_info(name, onnx.TensorProto.FLOAT, shape))
    new_outputs = [onnx.helper.make_tensor_value_info(o, onnx.TensorProto.FLOAT, None) for o in outputs]
    sub = onnx.helper.make_graph(nodes, graph.name + "_cut", new_inputs, new_outputs, initializers)
    cut_model = onnx.helper.make_model(sub, opset_imports=model.opset_import)
    # No stored intermediate shapes: ONNX's rounding of Resize scales can store a wrong one
    # (efficientdet_lite0: 4x4 where TensorFlow meant 5x5), which ONNX Runtime then refuses to load.
    onnx.save(cut_model, out_path)


def yolo_heads(path, classes=80, anchors=3):
    """End nodes for an anchor-based YOLO whose export goes past the heads: the convs with
    anchors x (5 + classes) output channels, which is where Hailo's HEFs end (1 x 255 x H x W). Exports
    go past them with a reshape to (1, 3, H, W, 85) (YOLOv5/v7) or with full decoding to boxes/confs
    (darknet YOLOv3/v4). 2 heads for tiny models, 4 for the P6 ones (yolov7e6).
    Returns None when the graph already ends at the heads."""
    model = onnx.load(path)
    outputs = model.graph.output
    channels = anchors * (5 + classes)
    dims = [[d.dim_value for d in o.type.tensor_type.shape.dim] for o in outputs]
    if all(len(d) == 4 and d[1] == channels for d in dims):
        return None
    weights = {i.name: list(i.dims) for i in model.graph.initializer}
    heads = [n.name for n in model.graph.node if n.op_type == "Conv" and weights.get(n.input[1], [0])[0] == channels]
    return [None, heads] if 2 <= len(heads) <= 4 else None


def main():
    configs = json.load(open(os.path.join(NATIVE, "zoo-configs.json")))
    # "app_name=zoo_name" converts the Model Zoo network under the name the apps use
    # (for example ocr_det=paddle_ocr_v5_mobile_detection).
    aliases = dict(a.split("=", 1) for a in sys.argv[1:] if "=" in a)
    if aliases:
        import subprocess as sp
        extra = json.loads(sp.run([PY, "-I", os.path.join(NATIVE, "tools/zoo_config.py"), *aliases.values()],
                                  capture_output=True, text=True, check=True).stdout)
        for app_name, cfg in zip(aliases, extra):
            cfg["zoo_name"] = cfg["name"]
            cfg["name"] = app_name
            configs = [c for c in configs if c["name"] != app_name] + [cfg]
    wanted = {a.split("=", 1)[0] for a in sys.argv[1:]}
    report_path = os.path.join(NATIVE, "convert-report.jsonl")
    os.makedirs(os.path.join(NATIVE, "coreml"), exist_ok=True)
    for cfg in configs:
        name = cfg["name"]
        if wanted and name not in wanted:
            continue
        row = {"name": name}
        started = time.time()
        try:
            if cfg.get("local_onnx"):   # an original from elsewhere than the Model Zoo, already downloaded and verified
                files = [os.path.join(ROOT, cfg["local_onnx"])]
            else:
                files = download(cfg)
            onnx_files = [f for f in files if f.endswith(".onnx") and not f.endswith((".cut.onnx", ".from_tflite.onnx"))]
            tflite_files = [f for f in files if f.endswith(".tflite")]
            if not onnx_files and tflite_files:
                onnx_files = [from_tflite(tflite_files[0], name)]
                row["source_format"] = "tflite (tf2onnx)"
            if not onnx_files:
                row["status"] = "no-onnx"; row["files"] = [os.path.basename(f) for f in files]
                raise StopIteration
            source = onnx_files[0]
            cut_path = os.path.join(NATIVE, "src", name, f"{name}.cut.onnx")
            nodes = cfg["nodes"]
            if (not nodes or not any(nodes)) and cfg.get("meta_arch") in ("yolo", "yolo_v3", "yolo_v4"):
                nodes = yolo_heads(source)   # Hailo's parser finds the heads itself; do the same
            global CUT_INPUT_SHAPE
            CUT_INPUT_SHAPE = cfg.get("input_shape") or info_input_shape(cfg.get("zoo_name") or name)
            model_path, outputs = cut(source, nodes, cut_path)
            if model_path == cut_path:
                # The cut is also the reference for compare.py, so ONNX Runtime must load it; near-integer
                # Resize scales (efficientdet_lite0) round to the wrong size there too. Same fix as the
                # converter applies.
                sys.path.insert(0, os.path.join(NATIVE, "tools"))
                from convert_onnx import resize_scales_to_sizes
                fixed = resize_scales_to_sizes(onnx.load(cut_path))
                if any(n.op_type == "Resize" and len(n.input) > 3 and n.input[3] for n in fixed.graph.node):
                    onnx.save(fixed, cut_path)
            row["outputs"] = outputs
            mean = ",".join(str(x) for x in (cfg["mean"] or [0, 0, 0]))
            std = ",".join(str(x) for x in (cfg["std"] or [1, 1, 1]))
            out = os.path.join(NATIVE, "coreml", f"{name}.mlpackage")
            conv = subprocess.run([PY, "-I", os.path.join(NATIVE, "tools/convert_onnx.py"), model_path, out,
                                   "--mean", mean, "--std", std] + (["--fp32"] if name in FP32_MODELS else []),
                                  capture_output=True, text=True, timeout=3600)
            if name in FP32_MODELS:
                row["precision"] = "float32"
            if conv.returncode != 0:
                row["status"] = "convert-failed"
                row["error"] = [l for l in conv.stderr.splitlines() if l.strip()][-1:]
                raise StopIteration
            cmp = subprocess.run([PY, "-I", os.path.join(NATIVE, "tools/compare.py"), model_path, out,
                                  os.path.join(ROOT, "testdata/bus.jpg"), mean, std],
                                 capture_output=True, text=True, timeout=1800)
            row["compare"] = [l for l in cmp.stdout.splitlines() if l.strip()]
            row["status"] = "ok" if cmp.returncode == 0 else "compare-failed"
            if cmp.returncode != 0:
                row["error"] = [l for l in cmp.stderr.splitlines() if l.strip()][-1:]
        except StopIteration:
            pass
        except Exception as e:
            row["status"] = "error"; row["error"] = [repr(e)]
            row["trace"] = traceback.format_exc().splitlines()[-3:]
        row["seconds"] = round(time.time() - started)
        with open(report_path, "a") as f:
            f.write(json.dumps(row) + "\n")
        print(name, row["status"], flush=True)


if __name__ == "__main__":
    main()
