"""Per-feature (per-channel) output quantization of a HEF.

Some HEFs quantize each channel of an output with its own scale (lightface_slim, yolov3, tiny_yolov3,
yolov3_416). Hailo's single-value quant_info, which tools/hefinfo prints, is then 0, and the outputs
cannot be dequantized from it. The per-channel values are in the HEF's protobuf
(ProtoHEFEdgeLayerNumericInfo.qp_scales / qp_zps, hailort/libhailort/hef.proto); this reads them with a
schema-less protobuf walk, so it needs neither the Hailo library nor protoc.

Usage: python3 tools/hef_feature_quant.py [model ...]   (default: every output in models.json whose
qpScale is 0) -- adds "qpZps" and "qpScales" (one per feature) to those outputs in models.json."""
import json, struct, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODELS = ROOT / "UGenKit/Sources/StudioCore/Resources/models.json"


def _varint(b, i):
    value = shift = 0
    while True:
        c = b[i]; i += 1
        value |= (c & 0x7F) << shift; shift += 7
        if c < 0x80:
            return value, i


def _fields(b):
    """The (field, wire type, value) list of a protobuf message, or None if `b` is not one."""
    out, i = [], 0
    try:
        while i < len(b):
            key, i = _varint(b, i)
            field, wire = key >> 3, key & 7
            if field == 0:
                return None
            if wire == 0:
                value, i = _varint(b, i)
            elif wire == 1:
                value = b[i:i + 8]; i += 8
            elif wire == 5:
                value = b[i:i + 4]; i += 4
            elif wire == 2:
                n, i = _varint(b, i)
                value = b[i:i + n]; i += n
            else:
                return None
            out.append((field, wire, value))
    except IndexError:
        return None
    return out if i == len(b) else None


def feature_quant(hef):
    """{layer name: (zero points, scales)} for every edge layer with per-feature scales."""
    data = Path(hef).read_bytes()
    size = struct.unpack(">I", data[8:12])[0]
    header = 56 if struct.unpack(">I", data[4:8])[0] == 3 else None   # hef__header_t, version 3
    if header is None:
        raise ValueError(f"{hef}: only version-3 HEF headers are handled")
    found = {}

    def walk(b, parent_strings):
        fields = _fields(b)
        if fields is None:
            return
        strings = [v.decode() for f, w, v in fields if w == 2 and 0 < len(v) < 120 and all(32 <= c < 127 for c in v)]
        by_field = {f: (w, v) for f, w, v in fields}
        scales = by_field.get(6)
        # NumericInfo: qp_zp (1, float), qp_scale (2, float), qp_zps (5, packed double), qp_scales (6, packed double).
        if scales and scales[0] == 2 and len(scales[1]) >= 16 and len(scales[1]) % 8 == 0 and by_field.get(2, (0,))[0] == 5:
            scale_list = list(struct.unpack(f"<{len(scales[1]) // 8}d", scales[1]))
            if 5 in by_field and by_field[5][1]:
                zps = list(struct.unpack(f"<{len(by_field[5][1]) // 8}d", by_field[5][1]))
            else:
                zp = struct.unpack("<f", by_field[1][1])[0] if 1 in by_field else 0.0
                zps = [zp] * len(scale_list)
            # The layer's own name is a string of the edge-layer message that holds this one.
            for name in parent_strings:
                found.setdefault(name, (zps, scale_list))
            return
        for f, w, v in fields:
            if w == 2 and len(v) > 2:
                walk(v, strings)

    walk(data[header:header + size], [])
    return found


if __name__ == "__main__":
    models = json.loads(MODELS.read_text())
    wanted = set(sys.argv[1:])
    changed = 0
    for model in models:
        streams = [s for s in model["outputs"] if s.get("qpScale") == 0 and s.get("features")]
        if not streams or (wanted and model["name"] not in wanted):
            continue
        quant = feature_quant(ROOT / f"models/{model['name']}.hef")
        for stream in streams:
            zps, scales = quant.get(stream["name"], (None, None))
            if scales is None or len(scales) != stream["features"]:
                print(f"{model['name']}: no per-feature quantization for {stream['name']}")
                continue
            stream["qpZps"] = [round(z, 6) for z in zps]
            stream["qpScales"] = [float(f"{s:.9g}") for s in scales]
            changed += 1
    MODELS.write_text(json.dumps(models, indent=1))
    print(changed, "outputs given per-feature quantization in", MODELS.relative_to(ROOT))
