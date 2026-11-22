// Text rules for the language examples (Calories, Offline code, Meeting notes). Port of
// StudioCore/LanguageGames.swift.

const ALIASES = (() => {
  const table = {
    item: ["item", "name", "food", "品名", "名稱", "食物", "品項", "菜名", "dish"],
    portion: ["portion", "serving", "amount", "份量", "分量", "量", "數量", "size"],
    kcal: ["kcal", "calories", "calorie", "energy", "熱量", "卡路里", "大卡"],
    protein_g: ["protein_g", "protein", "蛋白質", "蛋白质"],
  };
  const out = {};
  for (const [k, names] of Object.entries(table)) for (const n of names) out[n] = k;
  return out;
})();

/** Python's round(): half to even. */
const roundEven = (x) => { const r = Math.round(x); return Math.abs(x % 1) === 0.5 && r % 2 !== 0 ? r - 1 : r; };

export const Nutrition = {
  prompt: "You are a nutritionist. Identify every food or drink in the photo and estimate the portion, the calories (kcal) and the protein (grams). " +
    "Output only a JSON array with the keys item, portion, kcal, protein_g, all in double quotes, and no other text. " +
    'Example: [{"item":"chicken rice","portion":"1 bowl","kcal":550,"protein_g":18},{"item":"bubble tea","portion":"700 ml","kcal":480,"protein_g":6}]. ' +
    "If there is no food in the photo, output [].",

  integer(value, fallback = 0) {
    if (typeof value === "boolean") return fallback;
    if (typeof value === "number") return roundEven(value);
    if (typeof value === "string") { const m = value.match(/-?\d+(?:\.\d+)?/); return m ? roundEven(Number(m[0])) : fallback; }
    return fallback;
  },

  normalizeJSONText(s) {
    return s.replace(/```(?:json)?/g, "").replace(/'/g, '"')
      .replace(/([{,]\s*)([A-Za-z_]\w*|[一-鿿]+)\s*:/g, '$1"$2":').replace(/:\s*\+(\d)/g, ": $1");
  },

  itemFrom(dict) {
    const out = { item: "", portion: "", kcal: 0, proteinGrams: 0 };
    for (const [key, value] of Object.entries(dict)) {
      const k = key.trim();
      switch (ALIASES[k.toLowerCase()] ?? ALIASES[k]) {
        case "item": out.item = String(value).trim(); break;
        case "portion": out.portion = String(value).trim(); break;
        case "kcal": out.kcal = Math.max(0, this.integer(value)); break;
        case "protein_g": out.proteinGrams = Math.max(0, this.integer(value)); break;
      }
    }
    return out.item ? out : null;
  },

  /** Food items from an answer, as forgiving as the demo (fences, quotes, unquoted keys, cut-off arrays). */
  parseItems(text) {
    if (!text) return [];
    const s = this.normalizeJSONText(text), items = [];
    for (const m of s.matchAll(/\{[^{}]*\}/g)) {
      const chunk = m[0].replace(/,\s*\}/g, "}");
      let dict = null;
      try { dict = JSON.parse(chunk); } catch {
        dict = {};
        for (const p of chunk.matchAll(/"([^"]+)"\s*:\s*"?([^",}]*)"?/g)) dict[p[1]] = p[2];
      }
      const item = dict && typeof dict === "object" ? this.itemFrom(dict) : null;
      if (item) items.push(item);
    }
    return items;
  },

  totals(items) { return { kcal: items.reduce((a, i) => a + i.kcal, 0), proteinGrams: items.reduce((a, i) => a + i.proteinGrams, 0) }; },
};

/** Today's meals in localStorage; a new day starts empty. */
export class DailyLog {
  static key = "artelico.calories";
  static today(now = new Date()) { return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`; }
  static load(now = new Date()) {
    try { const saved = JSON.parse(localStorage.getItem(this.key)); if (saved?.date === this.today(now)) return Object.assign(new DailyLog(), saved); } catch { /* new log */ }
    return Object.assign(new DailyLog(), { date: this.today(now), meals: [] });
  }
  add(items, time = new Date()) { const t = Nutrition.totals(items); this.meals.push({ items, kcal: t.kcal, proteinGrams: t.proteinGrams, time: time.toISOString() }); this.save(); }
  clear() { this.meals = []; this.save(); }
  get kcal() { return this.meals.reduce((a, m) => a + m.kcal, 0); }
  get proteinGrams() { return this.meals.reduce((a, m) => a + m.proteinGrams, 0); }
  save() { try { localStorage.setItem(DailyLog.key, JSON.stringify({ date: this.date, meals: this.meals })); } catch { /* not kept */ } }
}

const LANG = { py: "python", python3: "python", js: "javascript", node: "javascript", sh: "bash", shell: "bash", "": "text" };

export const CodeBlocks = {
  /** Text and fenced code blocks; an unclosed fence (still streaming) counts as code. */
  split(answer) {
    const text = answer.replace(/\r\n?/g, "\n"), out = [], fence = /```[ \t]*([A-Za-z0-9_+#.-]*)[ \t]*\n/g;
    let pos = 0;
    for (;;) {
      fence.lastIndex = pos;
      const m = fence.exec(text);
      if (!m) { const rest = text.slice(pos); if (rest.trim()) out.push({ text: rest }); break; }
      const before = text.slice(pos, m.index);
      if (before.trim()) out.push({ text: before });
      const raw = m[1].toLowerCase(), language = LANG[raw] ?? raw, start = m.index + m[0].length, end = text.indexOf("```", start);
      if (end < 0) { out.push({ language, code: text.slice(start) }); break; }
      out.push({ language, code: text.slice(start, end).replace(/\n+$/, "") });
      pos = end + 3;
    }
    return out;
  },
  blocks(answer) { return this.split(answer).filter((s) => "code" in s); },
  last(answer, prefer = ["javascript"]) {
    const all = this.blocks(answer);
    for (const l of prefer) { const f = all.filter((b) => b.language === l && b.code.trim()).pop(); if (f) return f; }
    return all[all.length - 1] ?? null;
  },
  textOnly(answer) {
    const t = answer.replace(/\n```[A-Za-z0-9_+#.-]*$/, "");
    return this.split(t).map((s) => ("code" in s ? `[${s.language} code → shown on the right]` : s.text)).join("\n").replace(/\n\n+/g, "\n").trim();
  },
};

export const MeetingNotes = {
  system: `You are a professional meeting-notes assistant.
Strict rules:
(1) Write in the same language as the transcript. Use clear, correct words.
(2) Always follow the example's fixed format. Section order must be "Key Points -> Action Items -> Decisions". Do not change the section names.
(3) If a field has no information, write "Not mentioned". Never invent facts or names.
(4) No greetings, no closing remarks, no self-comments. Output the three sections directly.`,
  exampleTranscript: "Okay, today we mainly discuss the Q4 marketing budget. First, please have John submit the KPI report by the end of October. " +
    "Second, for social, we decided to pause LinkedIn ads and focus on Instagram. Third, keep the total budget under five hundred " +
    "thousand this quarter. OK, meeting adjourned.",
  exampleOutput: `Key Points:
- Discussed Q4 marketing budget allocation.
- Confirmed KPI report delivery schedule.
- Decided social ad platform strategy.
Action Items:
- Owner: John  Task: Submit KPI report  Deadline: end of October
Decisions:
- Pause LinkedIn ads, focus social budget on Instagram.
- Total Q4 budget capped at five hundred thousand.`,
  userMessage(transcript) {
    return `Example:\n----- Example transcript -----\n${this.exampleTranscript}\n----- Example output -----\n${this.exampleOutput}\n` +
      `Now summarize the following transcript using the EXACT same format (Key Points, Action Items, Decisions):\n----- Transcript -----\n${transcript}`;
  },
  looksValid(summary) {
    const s = summary.trim().toLowerCase();
    return s.length >= 20 && ["key points", "action items", "decisions"].every((h) => s.includes(h));
  },
};

/** Removes Qwen3's <think>…</think> (also an unfinished one at the end). */
export function withoutThinking(text) {
  let t = text.replace(/<think>[\s\S]*?<\/think>/g, "");
  const open = t.indexOf("<think>");
  if (open >= 0) t = t.slice(0, open);
  return t.trim();
}
