// Registers the UGen300 demo screens in the sidebar. Each page module mounts one screen; leaving the page
// sends "detach" to its view, which stops the camera, the model loop and any timers.
import { addPages } from "../../app.js";

function page(id, title, icon, file, name) {
  let view = null;
  return {
    id, title, icon,
    load: async () => {
      const module = await import(file);
      return {
        mount(v, app) { view = v; module[name](v, app); },
        unmount() { view?.dispatchEvent(new Event("detach")); view = null; },
      };
    },
  };
}

addPages("Body and pose", [
  page("slides", "Raise hand to flip", "👉", "./pose-screens.js", "slides"),
  page("handcount", "Hand-raise counter", "✋", "./pose-screens.js", "handCounter"),
  page("air", "Air instrument", "🎵", "./pose-screens.js", "airInstrument"),
  page("yoga", "Yoga coach", "🧘", "./pose-screens.js", "yoga"),
  page("squat", "Squat alarm", "⏰", "./pose-screens.js", "squatAlarm"),
  page("classroom", "Classroom", "🏫", "./pose-screens.js", "classroom"),
]);
addPages("Objects", [
  page("headcount", "Head count", "👥", "./object-screens.js", "headCount"),
  page("traffic", "Traffic count", "🚗", "./object-screens.js", "traffic"),
  page("missing", "Missing check", "⚠️", "./object-screens.js", "missingCheck"),
  page("plates", "Plate gate", "🅿️", "./object-screens.js", "plateGate"),
  page("edgecloud", "Edge vs cloud", "☁️", "./object-screens.js", "edgeCloud"),
]);
addPages("Faces", [
  page("checkin", "Face check-in", "🪪", "./object-screens.js", "faceCheckIn"),
  page("privacy", "Privacy camera", "🕶️", "./privacy-screen.js", "privacyCamera"),
]);
addPages("Hands", [
  page("signs", "Hand signs", "👍", "./hand-screens.js", "handSigns"),
  page("fruit", "Fruit ninja", "🍉", "./hand-screens.js", "fruitNinja"),
  page("band", "Air band", "🎸", "./hand-screens.js", "airBand"),
]);
addPages("Pictures", [page("restore", "Photo restore", "🪄", "./hand-screens.js", "photoRestore")]);
