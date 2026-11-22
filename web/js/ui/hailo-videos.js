// Hailo's demo videos (from the hailo-apps resources, MIT licence, © Hailo), in samples/videos/.
// Sample lists take [title, file]; a file ending in .mp4 plays as a video source.

const v = (title, file) => [`🎬 ${title} (Hailo)`, file];

export const VIDEOS = {
  street: v("People walking in a street", "example.mp4"),
  office: v("Two people in an office", "walk_in_room.mp4"),
  drive: v("Driving in traffic (plates)", "full_mov_slow.mp4"),
  aerial: v("Traffic from above", "tiling_visdrone_720p.mp4"),
  squats: v("Gym class doing squats", "grok-squats.mp4"),
  face: v("A person talking to the camera", "face_recognition.mp4"),
  text: v("Text on wooden blocks", "ocr.mp4"),
  highway: v("Highway lanes", "lane_detection.mp4"),
  parcels: v("Parcels with barcodes", "barcode.mp4"),
  toy: v("A toy on a table", "clip_example.mp4"),
};

export const isVideo = (file) => file.endsWith(".mp4");

/** The same files at a fixed commit of the Artelico model repository (as the apps download them). */
export const VIDEOS_ONLINE = "https://huggingface.co/helmo/artelico-models/resolve/f9537295cef67e21ed9045aa959de4b6722ef833/samples/videos/";

/** samples/videos/<file> when this site has it, else the copy on Hugging Face (a checkout without the videos). */
export async function sampleVideoURL(file) {
  const local = `samples/videos/${file}`;
  try {
    const response = await fetch(local, { method: "HEAD" });
    if (response.ok && (response.headers.get("Content-Type") || "").startsWith("video/")) return local;
  } catch { /* not served here */ }
  return VIDEOS_ONLINE + file;
}
