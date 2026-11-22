# Follow-ups

Open questions and decisions waiting for the project's owner, and known gaps anyone could pick up. When asked "are there any follow-up issues?", go through this
list and check that each item still holds (the code or the situation may have changed). Move an item to "Done" with a
date once it's settled. Details are in history/LOG.md at the step named.

## Decisions waiting for the owner

1. **Hailo Studio: "Describe each object" with CLIP B/32 and Core ML text** (LOG Step 110).
   - On the stick, the prompts are embedded by the stick's own 8-bit text encoder. On bus.jpg, "wearing sunglasses / not wearing
     sunglasses" picks the reference's answer for only 2 of 4 people.
   - Embedding the prompts with Core ML instead (`clip_vit_b_32_text_encoder.mlpackage`, 76 MB, already downloaded by "Find
     anything") gives 4 of 4.
   - Recommendation: switch B/32 to Core ML text in Hailo Studio. The other pairs' Core ML text encoders are up to 1.2 GB, so
     they stay on the stick.
2. **Basel Face Model file** (`tddfa_bfm68.bin`, 41 KB, LOG Steps 100, 104 and 122).
   - It's bundled in both apps here; it's left out of the public Space and the GitHub copy (the model is hidden
     without it, and `native/tools/make_tddfa_bfm68.py` remakes it).
   - The owner should check the BFM licence before the apps are shared or the file is published.
3. **Face report scoring** (LOG Step 112).
   - It now scores the photo (lighting, sharpness, framing, expression, style), not looks. Hailo's FACE1 scores symmetry, skin and
     contour.
   - Keep ours or switch?
4. **Space size** (sample videos).
   - The 11 Hailo videos are stored twice: in the Space (`samples/videos`, most of its 294 MB) and in helmo/artelico-models.
   - The Space could load them from the model repository like the apps do (down to about 75 MB).
5. **Sharing the Mac apps.**
   - The DMGs are signed with Apple Development only, so they run on registered Macs only. Sharing them needs a Developer ID plus
     notarisation.
   - Also: universal (Intel) builds?
6. **Road cameras on the web.**
   - They're in the native apps only.
   - Open: check a few open-data traffic cameras (licence + CORS) for the web and Space.

7. **Public repository (`../hailo_github`, Step 122).**
   - Licence: AGPL-3.0 for the whole repository, confirmed by the user on 2026-11-22.
   - GitHub repository name: `artelico`. Pages deploys the web edition (`.github/workflows/pages.yml`); turn on
     Settings → Pages → Source: GitHub Actions once. Commits there: no co-author line.
   - It is not a git repository yet. To publish: `git init`, commit with the GitHub noreply address, create the
     repository, push. Re-run `python3 -I tools/export_github.py` before each commit.
8. **Space videos.** The web now falls back to Hugging Face for sample videos, so `build_space.py` could leave out
   `samples/videos` (item 4: the Space would shrink to about 75 MB). Not done yet.

## Known gaps (could be done when wanted)

- **Web Live has no "Track" switch**, so its boxes aren't steadied (the pose and example screens are) (Step 118).
- **4 Live sources on iOS:** the cap of 2 on 3 GB devices is estimated from Mac memory, not measured on an iPad (Step 112).
- **Rep counter:** only squats are tuned on real video; push-ups, pull-ups, sit-ups, jumping jacks and lunges are tested with
  synthetic poses only (Step 111).
- **Hailo Studio Face report:** the stick's writer model sometimes misspells a score key or gives fewer strengths (Step 112).
- **Whisper tiny on the stick:** skipped as a big job for little gain over Whisper-Base (Step 112).
- **Chip neural-core use:** the stick reads 0% while our single connection is busy. Power can't be read; there's no sensor (Step 112).
- **Privacy camera:**
  - the bus destination sign isn't found by ocr_det;
  - held regions don't move with the object (short trails);
  - the web is slower on the driving video (4–6 FPS) (Steps 109, 113).
- **The stick sometimes needs a replug** after a killed session (loader mode, "The runtime did not appear after the upload").
  It was seen once on 2026-11-21.
- **Python wheel (Step 121):** macOS 27.2+ and Python 3.12 only; built without the host-side tokenizer
  (HAILO_BUILD_CLIENT_TOKENIZER=OFF), so VLM needs `optimize_memory_on_device=False`. Rebuilding the port with it on
  would allow True.
- **Devices not updated since Step 122:** the road-camera change (data-driven catalogues) is built here but not yet
  installed on the iPad or iPhone.
- **DecidaBERT on the Hailo stick:** needs the Hailo Dataflow Compiler on a Linux x86 machine; nothing tried yet (see
  a separate project).

## Done

(none yet)
