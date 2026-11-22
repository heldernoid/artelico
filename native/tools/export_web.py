"""Builds the browser versions of the converted models (Artelico Web).

    export_web.py [name ...]        (default: every model that has a Core ML package)
    export_web.py --maps [name ...] (only rewrite the .native.json maps, for ONNX files already here)

For each model it takes the same ONNX graph the Core ML package was made from (the cut at Hailo's end
nodes, or the whole graph) and puts the same input step in front: picture inputs become 8-bit RGB in
NHWC, as the stick takes them, then cast to float, transposed when the network wants NCHW, and
normalized with the Model Zoo's mean and std. Outputs are untouched, so the `.native.json` map written
for Core ML applies as it is. Writes native/web/<name>.onnx and copies <name>.native.json next to it;
a row per model goes to native/web/export-report.jsonl.
"""
import json, os, subprocess, sys, tempfile, time

import numpy as np
import onnx
from onnx import helper, numpy_helper, TensorProto

NATIVE = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
ROOT = os.path.dirname(NATIVE)
OUT = os.path.join(NATIVE, "web")
PY = sys.executable
# App names that are Model Zoo networks under another name (as convert_all.py was run with).
ALIASES = {"ocr_det": "paddle_ocr_v5_mobile_detection", "ocr": "paddle_ocr_v5_mobile_recognition",
           "yolo11s_obb": "yolov11s_obb"}


def source_onnx(name):
    """The graph the Core ML package was converted from."""
    folder = os.path.join(NATIVE, "src", name)
    if not os.path.isdir(folder):
        return None
    files = os.listdir(folder)
    for preferred in (f"{name}.cut.onnx", f"{name}.from_tflite.onnx"):
        if preferred in files:
            return os.path.join(folder, preferred)
    plain = sorted(f for f in files if f.endswith(".onnx") and not f.endswith((".cut.onnx", ".probe.onnx")))
    return os.path.join(folder, plain[0]) if plain else None


def stick_inputs(name):
    """Input streams of the stick's model (models.json): sizes for inputs the graph leaves open."""
    catalog = json.load(open(os.path.join(ROOT, "UGenKit/Sources/StudioCore/Resources/models.json")))
    models = catalog if isinstance(catalog, list) else catalog.get("models", catalog)
    for m in models:
        if m["name"] == name:
            return m.get("inputs", [])
    return []


def dims(value_info):
    return [d.dim_value if d.HasField("dim_value") else None for d in value_info.type.tensor_type.shape.dim]


def wrap(model, mean, std, streams):
    """Puts uint8 NHWC picture inputs in front of the graph. Returns the names of the new inputs."""
    graph = model.graph
    initializers = {i.name for i in graph.initializer}
    real_inputs = [i for i in graph.input if i.name not in initializers]
    new_inputs, nodes, wrapped = [], [], []
    image_index = 0
    for index, inp in enumerate(real_inputs):
        shape = dims(inp)
        nchw = len(shape) == 4 and shape[1] == 3
        nhwc = len(shape) == 4 and shape[3] == 3 and not nchw
        if not (nchw or nhwc):
            new_inputs.append(inp)     # not a picture (e.g. a text encoder's tokens): unchanged
            continue
        stream = streams[index] if index < len(streams) else {}
        h = (shape[2] if nchw else shape[1]) or stream.get("height")
        w = (shape[3] if nchw else shape[2]) or stream.get("width")
        if not h or not w:
            raise ValueError(f"input {inp.name} has no fixed size")
        image_index += 1
        new_name = "image" if image_index == 1 else f"image_{image_index}"
        prefix = f"web_{image_index}_"
        new_inputs.append(helper.make_tensor_value_info(new_name, TensorProto.UINT8, [1, h, w, 3]))
        channel_shape = [1, 3, 1, 1] if nchw else [1, 1, 1, 3]
        graph.initializer.extend([
            numpy_helper.from_array(np.array(mean, np.float32).reshape(channel_shape), prefix + "mean"),
            numpy_helper.from_array(np.array(std, np.float32).reshape(channel_shape), prefix + "std"),
        ])
        current = prefix + "float"
        nodes.append(helper.make_node("Cast", [new_name], [current], to=TensorProto.FLOAT, name=prefix + "cast"))
        if nchw:
            nodes.append(helper.make_node("Transpose", [current], [prefix + "nchw"], perm=[0, 3, 1, 2], name=prefix + "transpose"))
            current = prefix + "nchw"
        nodes.append(helper.make_node("Sub", [current, prefix + "mean"], [prefix + "centred"], name=prefix + "sub"))
        nodes.append(helper.make_node("Div", [prefix + "centred", prefix + "std"], [inp.name], name=prefix + "div"))
        wrapped.append(new_name)
    del graph.input[:]
    graph.input.extend(new_inputs)
    old_nodes = list(graph.node)
    del graph.node[:]
    graph.node.extend(nodes + old_nodes)
    return wrapped


def pooling_without_ceil(model):
    """WebGPU cannot run AveragePool/MaxPool with ceil_mode (scrfd). With count_include_pad 0, ceil mode is
    the same as padding the end by the part of the last window that sticks out: write that instead."""
    import math
    from onnx import shape_inference
    inferred = shape_inference.infer_shapes(model)
    shapes = {v.name: dims(v) for v in list(inferred.graph.value_info) + list(inferred.graph.input) + list(inferred.graph.output)}
    changed = 0
    for node in model.graph.node:
        if node.op_type not in ("AveragePool", "MaxPool"):
            continue
        attrs = {a.name: a for a in node.attribute}
        if "ceil_mode" not in attrs or attrs["ceil_mode"].i != 1:
            continue
        if node.op_type == "AveragePool" and "count_include_pad" in attrs and attrs["count_include_pad"].i == 1:
            continue
        shape = shapes.get(node.input[0])
        if not shape or any(d is None for d in shape[2:]):
            continue
        kernel = list(attrs["kernel_shape"].ints)
        n = len(kernel)
        strides = list(attrs["strides"].ints) if "strides" in attrs else [1] * n
        pads = list(attrs["pads"].ints) if "pads" in attrs else [0] * (2 * n)
        for axis in range(n):
            size = shape[2 + axis] + pads[axis] + pads[n + axis]
            out = math.ceil((size - kernel[axis]) / strides[axis]) + 1
            # PyTorch/ONNX rule: the last window must start inside the input or the start padding.
            if (out - 1) * strides[axis] >= shape[2 + axis] + pads[axis]:
                out -= 1
            pads[n + axis] += max(0, (out - 1) * strides[axis] + kernel[axis] - size)
        for a in list(node.attribute):
            if a.name in ("ceil_mode", "pads"):
                node.attribute.remove(a)
        node.attribute.extend([helper.make_attribute("ceil_mode", 0), helper.make_attribute("pads", pads)])
        changed += 1
    return changed


def fold_constants(model):
    """Works out shape calculations once (ONNX Runtime's basic offline optimizer), so the browser does
    not meet their casts (regnetx_1.6gf: a Cast the web runtime has no kernel for)."""
    import onnxruntime as ort
    with tempfile.TemporaryDirectory() as folder:
        source, folded = os.path.join(folder, "in.onnx"), os.path.join(folder, "out.onnx")
        onnx.save(model, source)
        options = ort.SessionOptions()
        options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_BASIC
        options.optimized_model_filepath = folded
        ort.InferenceSession(source, options, providers=["CPUExecutionProvider"])
        return onnx.load(folded)


def tidy_for_browser(model):
    """What ONNX Runtime Web refuses: an ai.onnx.ml opset import with no ml operators in the graph (the
    web build has no ml domain), stored shapes that disagree with inference (deeplab: 513 vs 512), and
    very old opsets (regnetx_1.6gf, opset 8). Returns the model to save (possibly converted)."""
    used = {n.domain for n in model.graph.node}
    keep = [o for o in model.opset_import if o.domain in ("", "ai.onnx") or o.domain in used]
    if len(keep) != len(model.opset_import):
        del model.opset_import[:]
        model.opset_import.extend(keep)
    del model.graph.value_info[:]
    version = next((o.version for o in model.opset_import if o.domain in ("", "ai.onnx")), 13)
    if version < 11:
        from onnx import version_converter
        try:
            model = version_converter.convert_version(model, 13)
        except Exception:   # resnet_v1_34/50: the converter rejects the added initializers; keep the opset
            pass
        del model.graph.value_info[:]
        model = fold_constants(model)
    # The browser runtime reads IR versions up to 10; opsets 13-17 need 8 or later.
    model.ir_version = min(max(model.ir_version, 8), 10)
    # Declared output sizes can disagree with what the graph computes (deeplab: 513 declared, 512 computed).
    for output in model.graph.output:
        for d in output.type.tensor_type.shape.dim:
            if d.HasField("dim_value"):
                d.ClearField("dim_value")
    return model


def web_map(native_map, package, model):
    """The Core ML map with sources renamed to the ONNX graph's output names. Core ML keeps the graph's
    output order but may rename outputs ("var_435", "/a.b" -> "_a_b"); pair them by position and check
    that the element counts agree."""
    import coremltools as ct
    spec = ct.models.MLModel(package, skip_model_load=True).get_spec()
    coreml = [(o.name, list(o.type.multiArrayType.shape)) for o in spec.description.output]
    onnx_outputs = [(o.name, dims(o)) for o in model.graph.output]
    if len(coreml) != len(onnx_outputs):
        raise ValueError(f"Core ML has {len(coreml)} outputs, ONNX {len(onnx_outputs)}")
    rename = {}
    for (cname, cshape), (oname, oshape) in zip(coreml, onnx_outputs):
        csize = int(np.prod(cshape)) if cshape else None
        osize = int(np.prod(oshape)) if oshape and all(oshape) else None
        if csize and osize and csize != osize:
            raise ValueError(f"output {cname} {cshape} does not match {oname} {oshape}")
        rename[cname] = oname
    for output in native_map.get("outputs", []):
        output["source"] = rename.get(output["source"], output["source"])
    return native_map


def check(path, wrapped):
    """Loads the result in ONNX Runtime and runs it once on a grey picture."""
    import onnxruntime as ort
    session = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
    feeds = {}
    for i in session.get_inputs():
        shape = [d if isinstance(d, int) else 1 for d in i.shape]
        if i.type == "tensor(uint8)":
            feeds[i.name] = np.full(shape, 114, np.uint8)
        elif "int" in i.type:
            feeds[i.name] = np.zeros(shape, np.int64 if "64" in i.type else np.int32)
        else:
            feeds[i.name] = np.zeros(shape, np.float32)
    started = time.time()
    outputs = session.run(None, feeds)
    return [list(o.shape) for o in outputs], round((time.time() - started) * 1000)


def write_maps(names):
    """Rewrites <name>.native.json from the Core ML map for models whose web ONNX exists (a map changed
    or was added after the export; the ONNX graph's output names are all that is read)."""
    names = names or sorted(f[:-5] for f in os.listdir(OUT) if f.endswith(".onnx"))
    for name in names:
        native_map = os.path.join(NATIVE, "coreml", f"{name}.native.json")
        out = os.path.join(OUT, f"{name}.native.json")
        if not os.path.exists(native_map) or not os.path.exists(os.path.join(OUT, f"{name}.onnx")):
            continue
        model = onnx.load(os.path.join(OUT, f"{name}.onnx"), load_external_data=False)
        mapped = web_map(json.load(open(native_map)), os.path.join(NATIVE, "coreml", f"{name}.mlpackage"), model)
        old = json.load(open(out)) if os.path.exists(out) else None
        if old != mapped:
            with open(out, "w") as g:
                json.dump(mapped, g, indent=1)
            print(f"{name}: {'changed' if old else 'new'}", flush=True)


def main():
    if sys.argv[1:2] == ["--maps"]:
        write_maps(sys.argv[2:])
        return
    os.makedirs(OUT, exist_ok=True)
    configs = {c["name"]: c for c in json.load(open(os.path.join(NATIVE, "zoo-configs.json")))}
    wanted = sys.argv[1:] or sorted(f[:-10] for f in os.listdir(os.path.join(NATIVE, "coreml")) if f.endswith(".mlpackage"))
    report = open(os.path.join(OUT, "export-report.jsonl"), "a")
    for name in wanted:
        row = {"name": name}
        try:
            cfg = configs.get(name)
            if cfg is None and name in ALIASES:
                cfg = json.loads(subprocess.run([PY, "-I", os.path.join(NATIVE, "tools/zoo_config.py"), ALIASES[name]],
                                                capture_output=True, text=True, check=True).stdout)[0]
            if cfg is None:
                raise ValueError("no Model Zoo config (mean/std unknown)")
            source = source_onnx(name)
            if source is None:
                raise ValueError("no source ONNX in native/src")
            model = onnx.load(source)
            mean = cfg.get("mean") or [0, 0, 0]
            std = cfg.get("std") or [1, 1, 1]
            if len(mean) != 3 or len(std) != 3:
                mean, std = [0, 0, 0], [1, 1, 1]
            wrapped = wrap(model, mean, std, stick_inputs(name))
            row["pools_rewritten"] = pooling_without_ceil(model)
            model = tidy_for_browser(model)
            out = os.path.join(OUT, f"{name}.onnx")
            onnx.save(model, out)
            row.update(source=os.path.relpath(source, NATIVE), images=wrapped, mean=mean, std=std,
                       megabytes=round(os.path.getsize(out) / 1e6, 1))
            row["outputs"], row["ms"] = check(out, wrapped)
            native_map = os.path.join(NATIVE, "coreml", f"{name}.native.json")
            if os.path.exists(native_map):
                mapped = web_map(json.load(open(native_map)), os.path.join(NATIVE, "coreml", f"{name}.mlpackage"), model)
                with open(os.path.join(OUT, f"{name}.native.json"), "w") as g:
                    json.dump(mapped, g, indent=1)
            row["status"] = "ok"
        except Exception as error:   # noqa: BLE001 - one bad model must not stop the rest
            row["status"] = "failed"
            row["error"] = f"{type(error).__name__}: {error}"[:300]
        print(json.dumps(row), flush=True)
        report.write(json.dumps(row) + "\n")
    write_index()


def write_index():
    """native/web/index.json: the models that are here, with their sizes (read by the site)."""
    models = []
    for f in sorted(os.listdir(OUT)):
        if f.endswith(".onnx"):
            models.append({"name": f[:-5], "bytes": os.path.getsize(os.path.join(OUT, f))})
    with open(os.path.join(OUT, "index.json"), "w") as g:
        json.dump({"models": [m["name"] for m in models], "sizes": {m["name"]: m["bytes"] for m in models}}, g)


if __name__ == "__main__":
    main()
