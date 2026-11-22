// Where every bundled sample comes from, shown as a small tag on the picture or video while it is used.
import { el } from "./common.js";

const HAILO = { who: "Hailo", what: "hailo-apps, MIT licence", href: "https://github.com/hailo-ai/hailo-apps" };
const DEMOS = { who: "UGen300 demos", what: "MIT licence", href: "https://github.com/erp0917-stack/ugen300-demos" };
const MEDIAPIPE = { who: "Google MediaPipe", what: "Apache-2.0", href: "https://github.com/google-ai-edge/mediapipe" };

const BY_FILE = {
  "plate_sample.png": DEMOS,
  "thumbs_up.jpg": MEDIAPIPE,
};

/** The credit for a bundled sample (a file in samples/ or samples/videos/), or null. */
export function creditFor(file) {
  if (!file) return null;
  const name = file.split("/").pop();
  return BY_FILE[name] ?? HAILO;   // every other sample picture and all videos are Hailo's
}

export const HAILO_CREDIT = "Demo videos and most sample pictures: Hailo (hailo-apps resources, MIT licence). " +
  "Plate picture: UGen300 demos (MIT). Thumbs-up picture: Google MediaPipe (Apache-2.0).";

/** A tag to place inside a .stage; `tag.show(file)` shows that sample's credit, `tag.show(null)` hides it. */
export function creditTag() {
  const tag = el("a.credit-tag", { target: "_blank", rel: "noopener", hidden: true });
  tag.show = (file) => {
    const c = creditFor(file);
    tag.hidden = !c;
    if (!c) return;
    tag.href = c.href;
    tag.textContent = `${file.endsWith(".mp4") ? "🎬 Video" : "📷 Picture"}: ${c.who} · ${c.what}`;
  };
  return tag;
}
