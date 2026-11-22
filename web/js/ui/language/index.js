// Registers the language pages and the "Ask the models" demos in the sidebar.
import { addPages } from "../../app.js";

function page(id, title, icon, name) {
  let view = null;
  return {
    id, title, icon,
    load: async () => {
      const module = await import("./pages.js");
      return {
        mount(v, app) { view = v; module[name](v, app); },
        unmount() { view?.dispatchEvent(new Event("detach")); view?.querySelectorAll("*").forEach((n) => n.dispatchEvent(new Event("detach"))); view = null; },
      };
    },
  };
}

addPages("Language", [
  page("chat", "Chat", "💬", "chat"),
  page("ask", "Ask an image", "🔍", "askImage"),
  page("speech", "Speech to text", "🎙️", "speech"),
], "Body and pose");
addPages("Ask the models", [
  page("outfit", "Outfit advisor", "👕", "outfit"),
  page("fridge", "Fridge chef", "🧊", "fridge"),
  page("calories", "Calories", "🍽️", "calories"),
  page("facereport", "Face style report", "🙂", "faceReport"),
  page("code", "Offline code", "⌨️", "offlineCode"),
  page("notes", "Meeting notes", "📋", "meetingNotes"),
]);
