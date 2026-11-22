"""Writes tddfa_bfm68.bin: the 68-landmark part of the Basel Face Model that tddfa_mobilenet_v1's
(3DDFA_V2) parameters drive. Needed only for the "3D face landmarks" model; without the file the apps
and the web simply don't offer that model.

The file is not in the public repository because the Basel Face Model has its own licence
(https://faces.dmi.unibas.ch/bfm/ — read and accept it first). Get bfm_noneck_v3.pkl from
3DDFA_V2 (https://github.com/cleardusk/3DDFA_V2, configs/bfm_noneck_v3.pkl), then:

    python3 -I native/tools/make_tddfa_bfm68.py path/to/bfm_noneck_v3.pkl

It writes UGenKit/Sources/StudioCore/Resources/tddfa_bfm68.bin and web/data/tddfa_bfm68.bin
(41,616 bytes: float32, little-endian; the mean shape 204 values, x y z per point, then 40 shape bases
204 x 40 and 10 expression bases 204 x 10, row by row). Needs numpy.

The pickle is read with an unpickler that only rebuilds numpy arrays, so a tampered file cannot run code.
"""
import pickle
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
TARGETS = [ROOT / "UGenKit/Sources/StudioCore/Resources/tddfa_bfm68.bin", ROOT / "web/data/tddfa_bfm68.bin"]
ALLOWED = {
    ("numpy.core.multiarray", "_reconstruct"), ("numpy._core.multiarray", "_reconstruct"),
    ("numpy", "ndarray"), ("numpy", "dtype"), ("numpy.core.multiarray", "scalar"), ("numpy._core.multiarray", "scalar"),
}


class ArraysOnly(pickle.Unpickler):
    def find_class(self, module, name):
        if (module, name) not in ALLOWED:
            raise pickle.UnpicklingError(f"refusing {module}.{name}: only numpy arrays are expected")
        if module.startswith("numpy._core") and not hasattr(np, "_core"):
            module = module.replace("numpy._core", "numpy.core")
        return super().find_class(module, name)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with open(sys.argv[1], "rb") as f:
        bfm = ArraysOnly(f, encoding="latin1").load()
    # 3DDFA_V2 bfm/bfm.py: the landmark rows of the mean, the first 40 shape and the first 10 expression bases.
    keypoints = bfm["keypoints"].astype(np.int64).ravel()
    mean = bfm["u"].astype(np.float32).reshape(-1)[keypoints]
    shape = bfm["w_shp"].astype(np.float32)[keypoints, :40]
    expression = bfm["w_exp"].astype(np.float32)[keypoints, :10]
    assert mean.shape == (204,) and shape.shape == (204, 40) and expression.shape == (204, 10)
    data = np.concatenate([mean, shape.ravel(), expression.ravel()]).astype("<f4").tobytes()
    for target in TARGETS:
        target.write_bytes(data)
        print(f"{target.relative_to(ROOT)}: {len(data):,} bytes")


if __name__ == "__main__":
    main()
