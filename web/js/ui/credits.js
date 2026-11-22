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

// Speech samples (samples/speech/): 10–17 s from the start of public-domain recordings, as 48 kb/s mono MP3.
// LibriVox: readings by volunteers, public domain (archive.org item named in `href`).
const LIBRIVOX = (item) => `https://archive.org/details/${item}`;
export const SPEECH_SAMPLES = [
  { file: "speech_sample.wav", lang: "en", title: "English · a short test sentence", credit: "Made for this project with macOS speech" },
  { file: "speech/kennedy_en.mp3", lang: "en", title: "English · John F. Kennedy, 1961", credit: "Inaugural address, 20 January 1961 · public domain (US government)",
    href: "https://www.jfklibrary.org/learn/about-jfk/historic-speeches/inaugural-address" },
  { file: "speech/assis_pt.mp3", lang: "pt", title: "Portuguese · Machado de Assis, A Mão e a Luva", credit: "LibriVox recording · public domain", href: LIBRIVOX("a_mao_e_a_luva_1401_librivox") },
  { file: "speech/cervantes_es.mp3", lang: "es", title: "Spanish · Cervantes, Don Quijote", credit: "LibriVox recording · public domain", href: LIBRIVOX("don_quijote_vol1_0706_librivox") },
  { file: "speech/verne_fr.mp3", lang: "fr", title: "French · Jules Verne, Le Tour du monde en 80 jours", credit: "LibriVox recording · public domain", href: LIBRIVOX("tour_du_monde_en_80_jours_librivox") },
  { file: "speech/collodi_it.mp3", lang: "it", title: "Italian · Collodi, Pinocchio", credit: "LibriVox recording · public domain", href: LIBRIVOX("avventure_pinocchio_librivox") },
  { file: "speech/kafka_de.mp3", lang: "de", title: "German · Kafka, Die Verwandlung", credit: "LibriVox recording · public domain", href: LIBRIVOX("verwandlung_mw_0811_librivox") },
];

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
