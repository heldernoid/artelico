"""Exports Ultra-Fast-Lane-Detection v2 (TuSimple, ResNet-18) to ONNX in the layout of hailo-apps'
ufld_v2_tu HEF: input 1x3x320x800, four flat outputs (loc_row 22400, loc_col 16400, exist_row 448,
exist_col 328).

Source: github.com/cfzd/Ultra-Fast-Lane-Detection-v2 @ c903880 (vendor/ufld-v2, MIT); weights
tusimple_res18.pth from the project's Google Drive link. The checkpoint is a pickle, so it is loaded
with torch.load(weights_only=True), which only accepts tensors and plain containers.

usage: export_ufld.py <tusimple_res18.pth> <out.onnx>
"""
import os, sys, types
import torch

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
sys.path.insert(0, os.path.join(ROOT, "vendor/ufld-v2"))
# The project's utils.common pulls in training-only packages; the model only needs this initialiser,
# which trained weights overwrite anyway.
common = types.ModuleType("utils.common")
common.initialize_weights = lambda *args, **kwargs: None
sys.modules["utils"] = types.ModuleType("utils")
sys.modules["utils.common"] = common
from model.model_tusimple import parsingNet  # noqa: E402

checkpoint, out = sys.argv[1], sys.argv[2]
net = parsingNet(pretrained=False, backbone="18", num_grid_row=100, num_cls_row=56, num_grid_col=100, num_cls_col=41,
                 num_lane_on_row=4, num_lane_on_col=4, use_aux=False, input_height=320, input_width=800, fc_norm=False)
state = torch.load(checkpoint, map_location="cpu", weights_only=True)
state = state.get("model", state)
state = {k.removeprefix("module."): v for k, v in state.items()}
missing, unexpected = net.load_state_dict(state, strict=False)
print("missing keys:", missing, "| unexpected:", unexpected[:5])
net.eval()


class Flat(torch.nn.Module):
    def __init__(self, inner):
        super().__init__()
        self.inner = inner

    def forward(self, x):
        p = self.inner(x)
        return tuple(p[k].reshape(1, -1) for k in ("loc_row", "loc_col", "exist_row", "exist_col"))


with torch.no_grad():
    shapes = [t.shape for t in Flat(net)(torch.rand(1, 3, 320, 800))]
print("outputs:", shapes)
torch.onnx.export(Flat(net), torch.rand(1, 3, 320, 800), out, opset_version=13, input_names=["images"],
                  output_names=["loc_row", "loc_col", "exist_row", "exist_col"], dynamo=False)
print("wrote", out)
