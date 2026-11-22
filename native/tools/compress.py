"""Store a converted model's weights as 8-bit integers (per-channel, symmetric), like the HEFs do.
The maths still runs in float16; only the stored weights shrink.

usage: compress.py <in.mlpackage> <out.mlpackage> [--bits 8|6|4]
"""
import argparse

import coremltools as ct
import coremltools.optimize.coreml as cto

p = argparse.ArgumentParser()
p.add_argument("src")
p.add_argument("out")
p.add_argument("--bits", type=int, default=8)
a = p.parse_args()

model = ct.models.MLModel(a.src)
if a.bits == 8:
    config = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", granularity="per_channel"))
    compressed = cto.linear_quantize_weights(model, config=config)
else:
    # 6 or 4 bits: a look-up table of 2^bits values per weight tensor (palettization; per-group tables need iOS 18).
    config = cto.OptimizationConfig(global_config=cto.OpPalettizerConfig(nbits=a.bits, mode="kmeans", granularity="per_tensor"))
    compressed = cto.palettize_weights(model, config=config)
compressed.save(a.out)
print("saved", a.out)
