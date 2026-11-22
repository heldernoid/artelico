"""Convert one Hailo Model Zoo ONNX model to Core ML (.mlpackage).

Inputs with 3 channels become images (RGB, 0-255) with the model's normalization baked in, named
"image", "image_2", ... in graph order, so the app can feed the same pictures it sends to the stick.
Other inputs (for example CLIP's token embeddings) stay float tensors under their graph names.

usage: convert_onnx.py <model.onnx> <out.mlpackage> [--mean m0,m1,m2] [--std s0,s1,s2] [--fp32]
"""
import argparse
import math

import coremltools as ct
import onnx
import onnx.numpy_helper
from onnx import version_converter
import torch
from coremltools.converters.mil.frontend.torch.ops import _get_inputs
from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op
from onnx2torch import convert
from onnx2torch.node_converters.registry import add_converter
from onnx2torch.node_converters.resize import OnnxResizeV10
from onnx2torch.node_converters.split import OnnxSplit13
from onnx2torch.utils.common import OperationConverterResult, onnx_mapping_from_node


# onnx2torch graphs contain these no-op markers (complex conjugate / negative-bit views), which
# coremltools does not know. They do nothing for real tensors.
@register_torch_op
def resolve_conj(context, node):
    context.add(_get_inputs(context, node, expected=1)[0], node.name)


@register_torch_op
def resolve_neg(context, node):
    context.add(_get_inputs(context, node, expected=1)[0], node.name)


# Split 18 only adds the `num_outputs` attribute; with no `split` input it means equal parts, which
# onnx2torch's Split 13 module already does (it splits into as many parts as the node has outputs).
@add_converter(operation_type="Split", version=18)
def _split18(node, graph):
    return OperationConverterResult(
        torch_module=OnnxSplit13(axis=node.attributes.get("axis", 0), num_splits=len(node.output_values)),
        onnx_mapping=onnx_mapping_from_node(node=node),
    )


# Upsample (opset 7-9) has the same inputs and meaning as Resize 10: data and per-axis scales.
class _SpaceToDepth(torch.nn.Module):
    """ONNX SpaceToDepth: output channel = (row offset * b + column offset) * C + c, which is not the
    order of torch's pixel_unshuffle (c * b * b + ...), so it is spelled out."""
    def __init__(self, block):
        super().__init__()
        self.block = block

    def forward(self, x):
        # pixel_unshuffle orders channels c * b * b + offset; regroup to offset * C + c. Rank 5 at most
        # (Core ML's limit) and no shape arithmetic (coremltools cannot convert traced int(h // b)).
        b = self.block
        y = torch.nn.functional.pixel_unshuffle(x, b).unflatten(1, (-1, b * b))
        return y.transpose(1, 2).flatten(1, 2)


# ONNX Runtime's basic optimizer (fold_shape_computations) turns YOLOv5's Focus slices into SpaceToDepth.
@add_converter(operation_type="SpaceToDepth", version=13)
@add_converter(operation_type="SpaceToDepth", version=1)
def _space_to_depth(node, graph):
    return OperationConverterResult(
        torch_module=_SpaceToDepth(node.attributes["blocksize"]),
        onnx_mapping=onnx_mapping_from_node(node),
    )


@add_converter(operation_type="Upsample", version=9)
@add_converter(operation_type="Upsample", version=7)
def _upsample(node, graph):
    return OperationConverterResult(
        torch_module=OnnxResizeV10(mode=node.attributes.get("mode", "nearest")),
        onnx_mapping=onnx_mapping_from_node(node),
    )


def explicit_padding(model):
    """Replaces auto_pad=SAME_UPPER/SAME_LOWER (not supported by onnx2torch) with explicit pads."""
    inferred = onnx.shape_inference.infer_shapes(model)
    shapes = {}
    for vi in list(inferred.graph.value_info) + list(inferred.graph.input) + list(inferred.graph.output):
        shapes[vi.name] = [d.dim_value for d in vi.type.tensor_type.shape.dim]
    weights = {i.name: list(i.dims) for i in model.graph.initializer}
    changed = 0
    for node in model.graph.node:
        if node.op_type not in ("Conv", "MaxPool", "AveragePool"):
            continue
        attrs = {a.name: a for a in node.attribute}
        mode = attrs["auto_pad"].s.decode() if "auto_pad" in attrs else "NOTSET"
        if mode not in ("SAME_UPPER", "SAME_LOWER"):
            continue
        spatial = shapes.get(node.input[0], [])[2:]
        if "kernel_shape" in attrs:
            kernel = list(attrs["kernel_shape"].ints)
        else:
            kernel = weights[node.input[1]][2:]
        strides = list(attrs["strides"].ints) if "strides" in attrs else [1] * len(kernel)
        dilations = list(attrs["dilations"].ints) if "dilations" in attrs else [1] * len(kernel)
        begin, end = [], []
        for size, k, s, d in zip(spatial, kernel, strides, dilations):
            out = math.ceil(size / s)
            total = max((out - 1) * s + (k - 1) * d + 1 - size, 0)
            small, big = total // 2, total - total // 2
            begin.append(small if mode == "SAME_UPPER" else big)
            end.append(big if mode == "SAME_UPPER" else small)
        node.attribute.remove(attrs["auto_pad"])
        if "pads" in attrs:
            node.attribute.remove(attrs["pads"])
        node.attribute.append(onnx.helper.make_attribute("pads", begin + end))
        changed += 1
    if changed:
        print(f"rewrote auto_pad on {changed} nodes")
    return model


def fold_shape_computations(model):
    """Graphs that compute shapes at run time (Shape -> Gather -> Concat -> Reshape, as in the timm ViT
    exports vit_small_bn and vit_pose_small_bn) reach coremltools with tensors of unknown rank, which its
    BatchNorm cannot take. With the input sizes fixed, ONNX Runtime's basic optimizer folds those chains
    into constants (constant folding and standard-op fusions only, no ONNX Runtime-specific operators)."""
    if not any(n.op_type == "Shape" for n in model.graph.node):
        return model
    import os, tempfile
    import onnxruntime as ort
    initializers = {i.name for i in model.graph.initializer}
    # Old exports also list the weights as graph inputs; ONNX Runtime then treats them as overridable
    # and will not fold through them.
    for i in [i for i in model.graph.input if i.name in initializers]:
        model.graph.input.remove(i)
    with tempfile.TemporaryDirectory() as tmp:
        src, dst = os.path.join(tmp, "in.onnx"), os.path.join(tmp, "out.onnx")
        onnx.save(model, src)
        options = ort.SessionOptions()
        options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_BASIC
        options.optimized_model_filepath = dst
        ort.InferenceSession(src, options, providers=["CPUExecutionProvider"])
        folded = onnx.load(dst)
    before, after = len(model.graph.node), len(folded.graph.node)
    print(f"folded shape computations: {before} -> {after} nodes")
    return folded


def resize_scales_to_sizes(model):
    """Resize with constant scales whose product with the input size is just under a whole number
    (efficientdet_lite0: 3 x 1.6666666 = 4.9999998, meant as 5; ONNX rounds down to 4, so shape inference
    stops there and later layers have no shape). Replaced by the explicit sizes, one layer at a time
    because each fix lets shape inference reach the next one."""
    import numpy as np
    changed = 0
    for _ in range(50):
        inferred = onnx.shape_inference.infer_shapes(model)
        shapes = {vi.name: [d.dim_value for d in vi.type.tensor_type.shape.dim]
                  for vi in list(inferred.graph.value_info) + list(inferred.graph.input)}
        inits = {i.name: i for i in model.graph.initializer}
        fixed = False
        for node in model.graph.node:
            if node.op_type != "Resize" or len(node.input) < 3 or node.input[2] not in inits:
                continue
            if len(node.input) > 3 and node.input[3]:
                continue
            size = shapes.get(node.input[0])
            if not size or not all(size):
                continue
            scales = onnx.numpy_helper.to_array(inits[node.input[2]]).astype(np.float64)
            if scales.size != len(size):
                continue
            exact = np.array(size) * scales
            target = np.round(exact).astype(np.int64)
            if np.all(np.floor(exact) == target):
                continue   # ONNX's rounding already gives the intended size
            if np.any(np.abs(exact - target) > 1e-3):
                continue   # not a rounding problem
            name = node.name + "_sizes"
            model.graph.initializer.append(onnx.numpy_helper.from_array(target, name))
            while len(node.input) < 4:
                node.input.append("")
            node.input[2] = ""
            node.input[3] = name
            # Stored shapes from an earlier inference (the cut keeps them) would keep the wrong size.
            del model.graph.value_info[:]
            changed += 1
            fixed = True
            break
        if not fixed:
            break
    if changed:
        print(f"replaced near-integer Resize scales with sizes on {changed} nodes")
    return model


def one_sided_avgpool(model):
    """AveragePool with padding only at the end (nextvit: kernel 2, stride 2, pads [0,0,1,1]) is not
    supported by onnx2torch. With count_include_pad=0 it equals ceil_mode=1 without padding whenever the
    output sizes agree: the last window runs over the edge and is averaged over the values it covers."""
    inferred = onnx.shape_inference.infer_shapes(model)
    shapes = {vi.name: [d.dim_value for d in vi.type.tensor_type.shape.dim]
              for vi in list(inferred.graph.value_info) + list(inferred.graph.input)}
    changed = 0
    for node in model.graph.node:
        if node.op_type != "AveragePool":
            continue
        attrs = {a.name: a for a in node.attribute}
        pads = list(attrs["pads"].ints) if "pads" in attrs else []
        n = len(pads) // 2
        if not pads or pads[:n] == pads[n:] or any(pads[:n]):
            continue
        if "count_include_pad" in attrs and attrs["count_include_pad"].i:
            raise ValueError(f"{node.name}: one-sided padding with count_include_pad=1 has no ceil_mode equivalent")
        if "ceil_mode" in attrs and attrs["ceil_mode"].i:
            raise ValueError(f"{node.name}: one-sided padding together with ceil_mode")
        kernel = list(attrs["kernel_shape"].ints)
        strides = list(attrs["strides"].ints) if "strides" in attrs else [1] * n
        size = shapes.get(node.input[0], [])[2:]
        if len(size) != n or not all(size):
            raise ValueError(f"{node.name}: input size unknown, cannot check the ceil_mode rewrite")
        for s, k, st, p in zip(size, kernel, strides, pads[n:]):
            if (s + p - k) // st + 1 != -(-(s - k) // st) + 1 or p >= k:
                raise ValueError(f"{node.name}: one-sided pads {pads} do not match ceil_mode for size {size}")
        node.attribute.remove(attrs["pads"])
        node.attribute.append(onnx.helper.make_attribute("ceil_mode", 1))
        changed += 1
    if changed:
        print(f"rewrote {changed} one-sided AveragePool pads as ceil_mode")
    return model


def clip_without_empty_bounds(model):
    """Clip with only a lower bound (yolo_world_v2s: the epsilon of F.normalize on the text embeddings)
    lists its missing upper bound as an empty input name, which onnx2torch reads as a computed value
    ("Dynamic value of min/max is not implemented"). Trailing empty inputs are dropped; they mean the same."""
    changed = 0
    for node in model.graph.node:
        if node.op_type == "Clip" and node.input and node.input[-1] == "":
            while node.input and node.input[-1] == "":
                node.input.pop()
            changed += 1
    if changed:
        print(f"dropped empty bounds from {changed} Clip nodes")
    return model


# Operators whose meaning did not change between opset 17 and 21, apart from Split and Resize (handled below).
SAFE_FOR_RELABEL = {"Add", "Sub", "Mul", "Div", "Concat", "Conv", "MatMul", "MaxPool", "Reshape", "Resize", "Sigmoid",
                    "Softmax", "Split", "Transpose", "Relu", "Gemm", "Flatten", "Slice", "Gather", "Unsqueeze", "Squeeze",
                    "ConvTranspose"}   # ConvTranspose: version 11 from opset 11 to 21


def to_opset17(model, opset):
    """Makes a newer-opset graph readable by onnx2torch. Graphs that only use the operators above are
    rewritten in place (Split's num_outputs becomes explicit sizes; Resize's new attributes, at their
    defaults, are dropped) and relabelled as opset 17; anything else goes through ONNX's converter."""
    ops = {n.op_type for n in model.graph.node}
    if not ops <= SAFE_FOR_RELABEL:
        print(f"converting opset {opset} -> 17 with onnx.version_converter (ops: {sorted(ops - SAFE_FOR_RELABEL)})")
        return version_converter.convert_version(model, 17)
    inferred = onnx.shape_inference.infer_shapes(model)
    shapes = {}
    for vi in list(inferred.graph.value_info) + list(inferred.graph.input) + list(inferred.graph.output):
        shapes[vi.name] = [d.dim_value for d in vi.type.tensor_type.shape.dim]
    for node in model.graph.node:
        attrs = {a.name: a for a in node.attribute}
        if node.op_type == "Split" and "num_outputs" in attrs:
            axis = attrs["axis"].i if "axis" in attrs else 0
            count = attrs["num_outputs"].i
            length = shapes[node.input[0]][axis]
            part = math.ceil(length / count)
            sizes = [part] * (count - 1) + [length - part * (count - 1)]
            name = node.name + "_split_sizes"
            model.graph.initializer.append(onnx.numpy_helper.from_array(__import__("numpy").array(sizes, dtype="int64"), name))
            while len(node.input) < 2:
                node.input.append("")
            node.input[1] = name
            node.attribute.remove(attrs["num_outputs"])
        if node.op_type == "Resize":
            for key, default in (("antialias", 0), ("keep_aspect_ratio_policy", b"stretch")):
                if key in attrs:
                    value = attrs[key].i if attrs[key].type == onnx.AttributeProto.INT else attrs[key].s
                    if value != default:
                        raise ValueError(f"Resize {key}={value} has no opset-17 equivalent")
                    node.attribute.remove(attrs[key])
            if "axes" in attrs:
                raise ValueError("Resize with axes has no opset-17 equivalent")
    for o in model.opset_import:
        if o.domain in ("", "ai.onnx"):
            o.version = 17
    print(f"relabelled opset {opset} -> 17 (Split sizes made explicit)")
    return model


def main():
    p = argparse.ArgumentParser()
    p.add_argument("onnx")
    p.add_argument("out")
    p.add_argument("--mean", default="0,0,0")
    p.add_argument("--std", default="255,255,255")
    p.add_argument("--fp32", action="store_true", help="keep float32 maths (default float16, which the Neural Engine needs)")
    a = p.parse_args()

    model = onnx.load(a.onnx)
    opset = next((o.version for o in model.opset_import if o.domain in ("", "ai.onnx")), 17)
    if opset < 11:
        # Very old graphs (ONNX Model Zoo ResNet v1: opset 7/8) use operator versions onnx2torch lacks;
        # upgrading is well supported by ONNX's own converter.
        model = version_converter.convert_version(model, 13)
        print(f"upgraded opset {opset} -> 13")
    elif opset > 17:
        # onnx2torch knows operator versions up to opset 17 (newer exports use Reshape 19, Split 18, ...).
        model = to_opset17(model, opset)
    model = fold_shape_computations(model)
    model = resize_scales_to_sizes(model)
    model = explicit_padding(model)
    model = one_sided_avgpool(model)
    model = clip_without_empty_bounds(model)
    initializers = {i.name for i in model.graph.initializer}
    graph_inputs = [i for i in model.graph.input if i.name not in initializers]
    shapes = [[d.dim_value or 1 for d in i.type.tensor_type.shape.dim] for i in graph_inputs]
    is_image = [len(s) == 4 and s[1] == 3 for s in shapes]
    torch_model = convert(model).eval()
    mean = [float(x) for x in a.mean.split(",")]
    std = [float(x) for x in a.std.split(",")]
    if len(mean) != 3 or len(std) != 3:   # e.g. CLIP's text encoder: normalization([0], [1]) on a non-image input
        mean, std = [0.0, 0.0, 0.0], [1.0, 1.0, 1.0]

    class Normalized(torch.nn.Module):
        """(pixel - mean) / std on image inputs, then the original network. Per-channel std is folded
        in here because Core ML's ImageType only has one scale for all channels."""
        def __init__(self, net):
            super().__init__()
            self.net = net
            self.register_buffer("mean", torch.tensor(mean).view(1, 3, 1, 1))
            self.register_buffer("std", torch.tensor(std).view(1, 3, 1, 1))

        def forward(self, *inputs):
            return self.net(*[(x - self.mean) / self.std if image else x for x, image in zip(inputs, is_image)])

    wrapped = Normalized(torch_model).eval()
    examples = tuple(torch.rand(*s) * (255.0 if image else 1.0) for s, image in zip(shapes, is_image))
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, examples)
        reference = wrapped(*examples)
    outputs = reference if isinstance(reference, (tuple, list)) else (reference,)
    names = [o.name for o in model.graph.output]

    ml_inputs = []
    image_count = 0
    for graph_input, shape, image in zip(graph_inputs, shapes, is_image):
        if image:
            image_count += 1
            name = "image" if image_count == 1 else f"image_{image_count}"
            ml_inputs.append(ct.ImageType(name=name, shape=shape, color_layout=ct.colorlayout.RGB, scale=1.0, bias=[0, 0, 0]))
        else:
            ml_inputs.append(ct.TensorType(name=graph_input.name, shape=shape))

    mlmodel = ct.convert(
        traced,
        inputs=ml_inputs,
        outputs=[ct.TensorType(name=n) for n in names],
        compute_precision=ct.precision.FLOAT32 if a.fp32 else ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
    )
    mlmodel.short_description = f"{a.onnx.rsplit('/', 1)[-1]} converted from Hailo Model Zoo ONNX"
    mlmodel.save(a.out)
    print("saved", a.out, "outputs", [(n, tuple(o.shape)) for n, o in zip(names, outputs)])


if __name__ == "__main__":
    main()
