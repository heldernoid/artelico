// Tokenizers of the CLIP-family text encoders (port of StudioCore/CLIP.swift's CLIPTokenizer and
// SentencePiece.swift). Ids equal Hugging Face's (testdata/configs/clip_reference_tokens.json, checked by
// test.html?tokens): CLIPTokenizerFast (openai/clip-vit-base-patch32), SiglipTokenizer
// (google/siglip-base-patch16-224) and GemmaTokenizerFast (google/siglip2-base-patch32-256, lowercased).
// The vocabularies are web/data/clip_tokenizer.json, siglip_tokenizer.json and siglip2_tokenizer.json.

/** CLIP's byte-pair encoding, from a Hugging Face `tokenizers` JSON file. */
export class ClipTokenizer {
  static startToken = 49406;
  static endToken = 49407;
  static maxLength = 77;

  constructor(json) {
    const model = json.model;
    this.vocab = new Map(Object.entries(model.vocab));
    this.ranks = new Map();
    model.merges.forEach((merge, rank) => this.ranks.set(Array.isArray(merge) ? merge.join(" ") : merge, rank));
    this.suffix = model.end_of_word_suffix ?? "</w>";
    this.startID = this.vocab.get("<|startoftext|>") ?? ClipTokenizer.startToken;
    this.endID = this.vocab.get("<|endoftext|>") ?? ClipTokenizer.endToken;
    this.unknownID = this.vocab.get(model.unk_token) ?? this.endID;
    this.special = new Map([["<|startoftext|>", this.startID], ["<|endoftext|>", this.endID]]);
    this.cache = new Map();
  }

  /** Start token, the text's tokens, end token; cut to 77 like the reference (which can cut the end token off). */
  encode(text) {
    const normalized = text.normalize("NFC").replace(/\s+/gu, " ").toLowerCase();
    const ids = [this.startID];
    for (const [piece] of normalized.matchAll(SPLITTER)) {
      const special = this.special.get(piece);
      if (special !== undefined) ids.push(special); else ids.push(...this.bpe(piece));
    }
    ids.push(this.endID);
    return ids.slice(0, ClipTokenizer.maxLength);
  }

  bpe(word) {
    const known = this.cache.get(word);
    if (known) return known;
    let symbols = [...new TextEncoder().encode(word)].map((b) => BYTE_ALPHABET[b]);
    if (!symbols.length) return [];
    symbols[symbols.length - 1] += this.suffix;
    while (symbols.length > 1) {
      let bestRank = Infinity, left = "", right = "";
      for (let i = 0; i < symbols.length - 1; i++) {
        const rank = this.ranks.get(symbols[i] + " " + symbols[i + 1]);
        if (rank !== undefined && rank < bestRank) { bestRank = rank; left = symbols[i]; right = symbols[i + 1]; }
      }
      if (bestRank === Infinity) break;
      const merged = [];
      for (let i = 0; i < symbols.length; i++) {
        if (i + 1 < symbols.length && symbols[i] === left && symbols[i + 1] === right) { merged.push(left + right); i++; } else merged.push(symbols[i]);
      }
      symbols = merged;
    }
    const ids = symbols.map((s) => this.vocab.get(s) ?? this.unknownID);
    this.cache.set(word, ids);
    return ids;
  }
}

/** CLIP's word splitter: special tokens, English contractions, letters, single digits, other non-space runs. */
const SPLITTER = /<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+/gu;

/** GPT-2's byte-to-character table: printable bytes map to themselves, the rest to U+0100 onwards. */
const BYTE_ALPHABET = (() => {
  const table = new Array(256);
  let next = 256;
  for (let b = 0; b < 256; b++) {
    const printable = (b >= 33 && b <= 126) || (b >= 161 && b <= 172) || (b >= 174 && b <= 255);
    table[b] = String.fromCodePoint(printable ? b : next++);
  }
  return table;
})();

/** Python's string.punctuation (SigLIP drops it). */
const ASCII_PUNCTUATION = new Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~");

/**
 * SentencePiece: SigLIP's unigram model (Viterbi; NFKC, lowercased, ASCII punctuation dropped, "▁" before
 * every word) or Gemma's BPE (SigLIP 2: best-scoring pair first, byte fallback), from the JSON that
 * native/tools/clip_assets.py writes. Ends with the end token and pads to the encoder's length.
 */
export class SentencePieceTokenizer {
  constructor(json) {
    if (json.pieces.length !== json.scores.length || json.pieces.length !== json.types.length) throw new Error("Not a SentencePiece vocabulary.");
    this.algorithm = json.algorithm;
    this.lowercase = !!json.lowercase;
    this.removePunctuation = !!json.removePunctuation;
    this.endID = json.eos;
    this.padID = json.pad;
    this.pieces = new Map();
    this.byteIDs = new Array(256).fill(-1);
    this.unknownID = -1;
    let longest = 1, lowest = Infinity;
    json.pieces.forEach((piece, id) => {
      switch (json.types[id]) {
        case 1: {   // normal
          const score = Math.fround(json.scores[id]);
          this.pieces.set(piece, { id, score });
          longest = Math.max(longest, [...piece].length);
          lowest = Math.min(lowest, score);
          break;
        }
        case 2: this.unknownID = id; break;
        case 6: this.byteIDs[parseInt(piece.slice(3, -1), 16)] = id; break;   // "<0x41>"
        default: break;   // control, user defined, unused
      }
    });
    if (this.unknownID < 0 || this.byteIDs.includes(-1)) throw new Error("The SentencePiece vocabulary has no unknown or byte pieces.");
    // SentencePiece scores an unknown character 10 below the least likely piece.
    this.unknownScore = Math.fround(lowest - 10);
    this.longest = longest;
  }

  encode(text, length) {
    const ids = this.encodeWithoutPadding(text).slice(0, length - 1);
    ids.push(this.endID);
    while (ids.length < length) ids.push(this.padID);
    return ids;
  }

  encodeWithoutPadding(text) {
    let normalized = this.lowercase ? text.toLowerCase() : text;
    if (this.removePunctuation) normalized = [...normalized].filter((c) => !ASCII_PUNCTUATION.has(c)).join("");
    const words = normalized.split(/\s+/u).filter(Boolean);
    if (!words.length) return [];
    if (this.algorithm === "unigram") return this.viterbi([...("▁" + words.join("▁")).normalize("NFKC")]);
    return this.merge([...words.join("▁")]);
  }

  /** The most likely split into pieces (sum of float32 log probabilities, as SentencePiece). */
  viterbi(chars) {
    const n = chars.length;
    const best = new Float64Array(n + 1).fill(-Infinity);
    const fromStart = new Int32Array(n + 1), fromID = new Int32Array(n + 1);
    best[0] = 0;
    for (let start = 0; start < n; start++) {
      if (best[start] === -Infinity) continue;
      let piece = "", singleFound = false;
      for (let end = start + 1; end <= Math.min(n, start + this.longest); end++) {
        piece += chars[end - 1];
        const match = this.pieces.get(piece);
        if (!match) continue;
        if (end === start + 1) singleFound = true;
        const score = Math.fround(best[start] + match.score);
        if (score > best[end]) { best[end] = score; fromStart[end] = start; fromID[end] = match.id; }
      }
      // A character no piece starts with is unknown on its own.
      const unknown = Math.fround(best[start] + this.unknownScore);
      if (!singleFound && unknown > best[start + 1]) { best[start + 1] = unknown; fromStart[start + 1] = start; fromID[start + 1] = this.unknownID; }
    }
    const ids = [];
    for (let end = n; end > 0; end = fromStart[end]) {
      const start = fromStart[end], id = fromID[end];
      if (id === this.unknownID) ids.push(...[...new TextEncoder().encode(chars.slice(start, end).join(""))].reverse().map((b) => this.byteIDs[b]));
      else ids.push(id);
    }
    return ids.reverse();
  }

  /** Gemma's merges: characters (unknown ones as bytes, which never merge), then the best-scoring pair, leftmost first. */
  merge(chars) {
    let symbols = [], fixed = [];
    for (const c of chars) {
      if (this.pieces.has(c)) { symbols.push(c); fixed.push(null); } else for (const b of new TextEncoder().encode(c)) { symbols.push(""); fixed.push(this.byteIDs[b]); }
    }
    while (symbols.length > 1) {
      let bestIndex = -1, bestScore = -Infinity, bestID = Infinity;
      for (let i = 0; i < symbols.length - 1; i++) {
        if (fixed[i] !== null || fixed[i + 1] !== null) continue;
        const match = this.pieces.get(symbols[i] + symbols[i + 1]);
        if (!match) continue;
        if (match.score > bestScore || (match.score === bestScore && match.id < bestID)) { bestScore = match.score; bestID = match.id; bestIndex = i; }
      }
      if (bestIndex < 0) break;
      const left = symbols[bestIndex], right = symbols[bestIndex + 1];
      // Every other occurrence of the same pair to the right merges in the same round.
      for (let i = bestIndex; i < symbols.length - 1; i++) {
        if (fixed[i] === null && fixed[i + 1] === null && symbols[i] === left && symbols[i + 1] === right) {
          symbols[i] = left + right; symbols.splice(i + 1, 1); fixed.splice(i + 1, 1);
        }
      }
    }
    return symbols.map((s, i) => fixed[i] ?? this.pieces.get(s)?.id ?? this.unknownID);
  }
}
