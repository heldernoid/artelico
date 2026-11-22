"""Converts all-MiniLM-L6-v2 (sentence-transformers' official ONNX, Apache-2.0) to Core ML for the voice
assistant's tool selection.

Unlike hailo-apps' HEF (which takes word embeddings and leaves pooling to the CPU), this model takes token
ids and an attention mask (int32, length 64) and returns the sentence embedding: mean of the token vectors
under the mask, L2-normalised - what sentence-transformers' pooling config specifies.

usage: convert_minilm.py <model.onnx> <out.mlpackage> [--length 64]
"""
import argparse

import coremltools as ct
import numpy as np
import onnx
import onnxruntime as ort
import torch
from coremltools.converters.mil.frontend.torch.ops import _get_inputs
from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op
from onnx2torch import convert


@register_torch_op
def resolve_conj(context, node):
    context.add(_get_inputs(context, node, expected=1)[0], node.name)


@register_torch_op
def resolve_neg(context, node):
    context.add(_get_inputs(context, node, expected=1)[0], node.name)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("onnx")
    p.add_argument("out")
    p.add_argument("--length", type=int, default=64)
    a = p.parse_args()

    graph = onnx.load(a.onnx)
    names = [i.name for i in graph.graph.input]
    net = convert(graph).eval()

    class SentenceEmbedding(torch.nn.Module):
        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, input_ids, attention_mask):
            ids = input_ids.long()
            mask = attention_mask.long()
            feeds = {"input_ids": ids, "attention_mask": mask, "token_type_ids": torch.zeros_like(ids)}
            hidden = self.inner(*[feeds[n] for n in names])
            hidden = hidden[0] if isinstance(hidden, (tuple, list)) else hidden   # last_hidden_state
            weights = mask.unsqueeze(-1).to(hidden.dtype)
            pooled = (hidden * weights).sum(1) / weights.sum(1).clamp(min=1e-9)
            return torch.nn.functional.normalize(pooled, p=2, dim=1)

    wrapped = SentenceEmbedding(net).eval()
    ids = torch.zeros(1, a.length, dtype=torch.int32)
    ids[0, :6] = torch.tensor([101, 2054, 1005, 1055, 1996, 102])
    mask = (ids != 0).to(torch.int32)
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, (ids, mask))
        reference = wrapped(ids, mask).numpy()

    # The ONNX model itself, pooled the same way, for a check.
    session = ort.InferenceSession(a.onnx)
    feeds = {"input_ids": ids.numpy().astype(np.int64), "attention_mask": mask.numpy().astype(np.int64),
             "token_type_ids": np.zeros_like(ids.numpy(), dtype=np.int64)}
    hidden = session.run(None, {k: v for k, v in feeds.items() if k in names})[0]
    m = mask.numpy()[..., None].astype(np.float32)
    pooled = (hidden * m).sum(1) / m.sum(1)
    pooled /= np.linalg.norm(pooled, axis=1, keepdims=True)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input_ids", shape=(1, a.length), dtype=np.int32),
                ct.TensorType(name="attention_mask", shape=(1, a.length), dtype=np.int32)],
        outputs=[ct.TensorType(name="embedding")],
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.iOS17,
    )
    mlmodel.short_description = "all-MiniLM-L6-v2 sentence embedding (mean pooling, L2-normalised), token ids in"
    mlmodel.save(a.out)
    out = np.asarray(ct.models.MLModel(a.out).predict({"input_ids": ids.numpy(), "attention_mask": mask.numpy()})["embedding"])
    print("saved", a.out, "| cosine(Core ML, ONNX) =", float((out.reshape(-1) * pooled.reshape(-1)).sum()),
          "| torch vs ONNX max diff", float(np.abs(reference - pooled).max()))


if __name__ == "__main__":
    main()
