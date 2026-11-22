"""Builds the Hugging Face Space version of Artelico Web: the vision pages and demos, without the
language pages (no WebLLM, no Transformers.js). Models load from the model repository on Hugging Face.

    python3 web/tools/build_space.py [out]        # default: native/hf/space

It is a static Space (free; the models run in the visitor's browser, so it needs no server GPU).
"""
import os, re, shutil, sys

WEB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(WEB, "..", "native", "hf", "space")
LEAVE_OUT = {"js/ui/language", "js/core/language.js", "js/rules/language-games.js",
             "vendor/web-llm-0.2.87", "vendor/transformers-4.3.2", "samples/speech",
             "data/tddfa_bfm68.bin"}   # Basel Face Model licence: not for a public site without the owner's OK

README = """---
title: Artelico
emoji: 🎯
colorFrom: purple
colorTo: yellow
sdk: static
app_file: index.html
pinned: false
license: agpl-3.0
short_description: 200+ vision models running in your browser (WebGPU)
models:
  - helmo/artelico-models
custom_headers:
  cross-origin-embedder-policy: require-corp
  cross-origin-opener-policy: same-origin
  cross-origin-resource-policy: cross-origin
---

# Artelico Web

Over 200 computer-vision models from the Hailo Model Zoo running **in your browser**: detection, pose,
faces, segmentation, depth, OCR, lanes, oriented boxes, super-resolution and more, plus demos built on
them (head count, traffic count, plate gate, privacy camera, yoga coach, squat alarm, hand signs, photo
restore, ...).

Nothing is uploaded: pictures and the camera stay on your computer. Models download from
[helmo/artelico-models](https://huggingface.co/helmo/artelico-models) the first time they are used and
stay in the browser. Best in Chrome or Edge (WebGPU); other browsers use WebAssembly (slower).

For the full speed (several WebAssembly threads) open the Space on its own page
(the "Embed this Space" / direct link) rather than inside the Hugging Face page.

Licence: AGPL-3.0. Each model keeps its own licence (see the model repository).

## Credits

- Models: the networks of the [Hailo Model Zoo](https://github.com/hailo-ai/hailo_model_zoo) (MIT) and
  their original authors, listed per model in [helmo/artelico-models](https://huggingface.co/helmo/artelico-models).
- Demo videos and sample pictures: [Hailo](https://hailo.ai), from the resources of
  [hailo-apps](https://github.com/hailo-ai/hailo-apps) (MIT licence, © Hailo): street, office, traffic,
  aerial traffic, squats, face, text, highway lanes, parcels and toy videos (samples/videos/), and the
  pictures bus.jpg, dog_bicycle.jpg, apple.jpg, room.png, input_image.png, ocr_img1.png, ocr_img2.png,
  dota_image.png, lane.png (a frame of Hailo's lane video) and the stereo pair stereo_left/right.jpg.
- Licence-plate picture (plate_sample.png): [UGen300 demos](https://github.com/erp0917-stack/ugen300-demos) (MIT).
- Thumbs-up picture (thumbs_up.jpg): [Google MediaPipe](https://github.com/google-ai-edge/mediapipe)'s
  gesture sample (Apache-2.0).
- Tokenizers of tagging from text (data/): OpenAI CLIP's (openai/clip-vit-base-patch32, MIT), SigLIP's
  (google/siglip-base-patch16-224, Apache-2.0) and SigLIP 2's (google/siglip2-base-patch32-256, Apache-2.0).

Each sample shows its credit on the picture or video while it is in use.
"""


def main():
    if os.path.isdir(OUT):
        keep = os.path.join(OUT, ".git")
        for name in os.listdir(OUT):
            if os.path.join(OUT, name) != keep:
                path = os.path.join(OUT, name)
                shutil.rmtree(path) if os.path.isdir(path) and not os.path.islink(path) else os.remove(path)
    os.makedirs(OUT, exist_ok=True)
    for item in ("css", "js", "data", "samples", "vendor", "LICENSE"):
        src = os.path.join(WEB, item)
        if os.path.isdir(src):
            shutil.copytree(src, os.path.join(OUT, item),
                            ignore=lambda folder, names: [n for n in names if os.path.relpath(os.path.join(folder, n), WEB) in LEAVE_OUT or n == ".DS_Store"])
        else:
            shutil.copyfile(src, os.path.join(OUT, item))
    html = open(os.path.join(WEB, "index.html")).read()
    html = html.replace('<html lang="en">', '<html lang="en" data-language="off" data-edition="space">', 1)
    html = re.sub(r'content="Vision and language models running in your browser\.', 'content="Vision models running in your browser.', html)
    open(os.path.join(OUT, "index.html"), "w").write(html)
    open(os.path.join(OUT, "README.md"), "w").write(README)
    size = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(OUT) for f in fs)
    print(f"Space built in {os.path.abspath(OUT)}: {size / 1e6:.0f} MB")


if __name__ == "__main__":
    main()
