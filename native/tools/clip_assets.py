"""Builds the files the CLIP / SigLIP text encoders need next to them (Hailo's compiled text encoders start
after the token lookup, and the CLIP ones end before the projection).

    .venv-convert/bin/python -I native/tools/clip_assets.py            # -> native/coreml/, StudioCore/Resources/

Per text encoder, in native/coreml/ (downloaded with the model, see EXTRA in package_hf.py):
    <name>.tokens.npy       token embedding table, float16 [vocab, width] (the stick's input is one row per token)
    <name>.projection.npy   CLIP only: text projection, float32 [width, embedding] (row vector x matrix)
    <name>.final_norm.npy   TinyCLIP only: final layer norm, float32 [2, width] (weight, bias); Hailo's cut ends
                            at the last residual add
    siglip2_b_32_256_text_encoder.tokenizer.json   Gemma's SentencePiece vocabulary (256k pieces), too big to bundle
Bundled in UGenKit/Sources/StudioCore/Resources/:
    siglip_tokenizer.json   SigLIP's SentencePiece vocabulary (32k pieces, Apache-2.0)

Sources: the Model Zoo's ONNX files and .npz files in native/src/<model>/ where they hold the tables; OpenAI's
weights (ResNet-50, ResNet-50x4, ViT-L/14), which no Zoo file has, are read from timm's open_clip safetensors
on Hugging Face with HTTP range requests (only the needed tensors).
"""
import json, os, struct, sys, urllib.request
import numpy as np
import onnx
from onnx import numpy_helper

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "src")
OUT = os.path.join(HERE, "..", "coreml")
RESOURCES = os.path.join(HERE, "..", "..", "UGenKit", "Sources", "StudioCore", "Resources")
HF = "https://huggingface.co"


def safetensors(url, names):
    """Named tensors of a remote .safetensors file, fetched with range requests."""
    def get(a, b):
        return urllib.request.urlopen(urllib.request.Request(url, headers={"Range": f"bytes={a}-{b}"})).read()
    n = struct.unpack("<Q", get(0, 7))[0]
    header = json.loads(get(8, 8 + n - 1))
    out = {}
    for name in names:
        v = header[name]
        a, b = v["data_offsets"]
        assert v["dtype"] == "F32", v["dtype"]
        out[name] = np.frombuffer(get(8 + n + a, 8 + n + b - 1), np.float32).reshape(v["shape"])
    return out


def onnx_tensors(path, names):
    model = onnx.load(path)
    found = {t.name: numpy_helper.to_array(t) for t in model.graph.initializer if t.name in names}
    missing = set(names) - set(found)
    assert not missing, f"{path}: no {missing}"
    return found


def npz(model, file):
    return np.load(os.path.join(SRC, model, file))


def save(name, kind, array):
    path = os.path.join(OUT, f"{name}.{kind}.npy")
    np.save(path, np.ascontiguousarray(array))   # transposed views would be saved Fortran-ordered
    print(f"  {os.path.basename(path)} {array.dtype} {list(array.shape)} {os.path.getsize(path) / 1e6:.1f} MB")


def open_clip_weights(repo):
    t = safetensors(f"{HF}/timm/{repo}/resolve/main/open_clip_model.safetensors", ["token_embedding.weight", "text_projection"])
    return t["token_embedding.weight"], t["text_projection"]


def clip_models():
    """(text encoder, token table, projection [width, embedding], final norm or None)."""
    for name, file in (("clip_vit_b_32_text_encoder", "openai-clip-vit-base-patch32.npz"),
                       ("clip_vit_b_16_text_encoder", "openai-clip-vit-base-patch16.npz")):
        z = npz(name, file)
        yield name, z["text_embeddings"], z["projection_layer"].T, None   # HF Linear weight is [out, in]
    z = npz("clip_vit_l_14_laion2B_text_encoder", "clip_text_encoder_vit_l_14_laion2B/hg-clip-vit-l-14-laion2b.npz")
    yield "clip_vit_l_14_laion2B_text_encoder", z["text_embeddings"], z["projection_layer"].T, None
    for name, repo in (("clip_resnet_50_text_encoder", "resnet50_clip.openai"),
                       ("clip_resnet_50x4_text_encoder", "resnet50x4_clip.openai"),
                       ("clip_vit_l_14_text_encoder", "vit_large_patch14_clip_224.openai")):
        tokens, projection = open_clip_weights(repo)
        yield name, tokens, projection, None
    for name, stem in (("tinyclip_vit_8m_16_text_3m_yfcc15m_text_encoder", "TinyCLIP-ViT-8M-16-Text-3M-YFCC15M"),
                       ("tinyclip_vit_39m_16_text_19m_yfcc15m_text_encoder", "TinyCLIP-ViT-39M-16-Text-19M-YFCC15M"),
                       ("tinyclip_vit_40m_32_text_19m_laion400m_text_encoder", "TinyCLIP-ViT-40M-32-Text-19M-LAION400M"),
                       ("tinyclip_vit_61m_32_text_29m_laion400m_text_encoder", "TinyCLIP-ViT-61M-32-Text-29M-LAION400M")):
        onnx_file = next(f for f in os.listdir(os.path.join(SRC, name)) if f.endswith(".sim.onnx"))
        t = onnx_tensors(os.path.join(SRC, name, onnx_file),
                         ["embeddings.token_embedding.weight", "final_layer_norm.weight", "final_layer_norm.bias"])
        z = npz(name, f"{stem}.npz")
        # The .npz must belong to this model (the Zoo's download script once pointed 40M at 61M's file).
        assert np.array_equal(z["text_embeddings"], t["embeddings.token_embedding.weight"]), f"{name}: .npz is another model's"
        norm = np.stack([t["final_layer_norm.weight"], t["final_layer_norm.bias"]]).astype(np.float32)
        yield name, t["embeddings.token_embedding.weight"], z["projection_layer"].T, norm


def siglip_models():
    for name, onnx_file, table in (
            ("siglip_b_16_text_encoder", "siglip_base_patch16_224_text_encoder.sim.onnx", "embeddings.token_embedding.weight"),
            ("siglip_l_16_256_text_encoder", "siglip_large_patch16_256_text_encoder.sim.onnx", "embeddings.token_embedding.weight"),
            ("siglip2_b_32_256_text_encoder", "siglip2-base-patch32-256_text_encoder.sim.onnx", "model.embeddings.token_embedding.weight")):
        yield name, onnx_tensors(os.path.join(SRC, name, onnx_file), [table])[table]


def sentencepiece_pieces(data):
    """(piece, score, type) of a SentencePiece ModelProto, read without the sentencepiece package
    (field 1 = repeated SentencePiece {1: piece, 2: score, 3: type})."""
    def varint(buf, i):
        value = shift = 0
        while True:
            b = buf[i]; i += 1
            value |= (b & 0x7F) << shift; shift += 7
            if b < 0x80:
                return value, i
    pieces, i = [], 0
    while i < len(data):
        key, i = varint(data, i)
        field, wire = key >> 3, key & 7
        if wire == 2:
            length, i = varint(data, i)
            body, i = data[i:i + length], i + length
            if field == 1:
                piece, score, kind, j = "", 0.0, 1, 0
                while j < len(body):
                    k, j = varint(body, j)
                    if k == (1 << 3 | 2):
                        n, j = varint(body, j); piece = body[j:j + n].decode("utf-8"); j += n
                    elif k == (2 << 3 | 5):
                        score = struct.unpack("<f", body[j:j + 4])[0]; j += 4
                    elif k == (3 << 3 | 0):
                        kind, j = varint(body, j)
                    else:
                        raise ValueError(f"unexpected field {k} in a piece")
                pieces.append((piece, score, kind))
        elif wire == 0:
            _, i = varint(data, i)
        elif wire == 5:
            i += 4
        elif wire == 1:
            i += 8
        else:
            raise ValueError(f"wire type {wire}")
    return pieces


def tokenizer_json(repo, file, algorithm, path, **options):
    data = urllib.request.urlopen(f"{HF}/google/{repo}/resolve/main/{file}").read()
    pieces = sentencepiece_pieces(data)
    out = {"source": f"{HF}/google/{repo} ({file}, Apache-2.0)", "algorithm": algorithm,
           "pieces": [p for p, _, _ in pieces], "scores": [round(s, 6) for _, s, _ in pieces],
           # SentencePiece types: 1 normal, 2 unknown, 3 control, 4 user defined, 5 unused, 6 byte
           "types": [t for _, _, t in pieces], **options}
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
    print(f"  {os.path.basename(path)}: {len(pieces)} pieces, {os.path.getsize(path) / 1e6:.1f} MB")


def main():
    only = set(sys.argv[1:])
    print("CLIP text encoders")
    for name, tokens, projection, norm in clip_models():
        if only and name not in only:
            continue
        assert tokens.shape[0] == 49408 and projection.shape[0] == tokens.shape[1], (name, tokens.shape, projection.shape)
        save(name, "tokens", tokens.astype(np.float16))
        save(name, "projection", projection.astype(np.float32))
        if norm is not None:
            save(name, "final_norm", norm)
    print("SigLIP text encoders")
    for name, tokens in siglip_models():
        if only and name not in only:
            continue
        save(name, "tokens", tokens.astype(np.float16))
    if not only:
        print("Tokenizers")
        tokenizer_json("siglip-base-patch16-224", "spiece.model", "unigram", os.path.join(RESOURCES, "siglip_tokenizer.json"),
                       lowercase=True, removePunctuation=True, eos=1, pad=1)
        tokenizer_json("siglip2-base-patch32-256", "tokenizer.model", "bpe",
                       os.path.join(OUT, "siglip2_b_32_256_text_encoder.tokenizer.json"), lowercase=True, eos=1, pad=0)


if __name__ == "__main__":
    main()
