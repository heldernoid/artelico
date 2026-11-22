// Where model files come from: the Artelico model repository on Hugging Face, a folder on the web server
// next to the site ("models/", used when it exists), or a folder on this computer chosen by the user
// (File System Access API). Downloads from the server are kept in the
// browser's Cache Storage so a model downloads once. Tagging from text also reads the text encoders'
// tables from the repository's coreml/ folder (readFile, readRange).

const CACHE = "artelico-models-v1";

/** The model repository (native/tools/package_hf.py uploads it). Pinned to a commit for releases. */
export const HUGGING_FACE = "https://huggingface.co/helmo/artelico-models/resolve/922f2602f2a1b313e357e83e004a2d47feddc7f1/web";

/** "models/" next to the site when it has models (development), otherwise Hugging Face. */
export async function defaultSource() {
  const asked = new URLSearchParams(location.search).get("models");
  if (asked) return new ServerSource(asked === "hf" ? HUGGING_FACE : asked);
  try { if ((await fetch("models/index.json", { method: "HEAD" })).ok) return new ServerSource("models"); } catch {}
  return new ServerSource(HUGGING_FACE);
}

async function readWithProgress(response, onProgress) {
  const total = Number(response.headers.get("content-length")) || 0;
  if (!response.body || !onProgress) return response.arrayBuffer();
  const reader = response.body.getReader();
  const chunks = [];
  let received = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    received += value.length;
    onProgress(received, total);
  }
  const out = new Uint8Array(received);
  let o = 0;
  for (const c of chunks) { out.set(c, o); o += c.length; }
  return out.buffer;
}

export class ServerSource {
  constructor(base = "models") {
    this.base = base.replace(/\/$/, "");
    this.kind = "server";
    this.where = this.base.startsWith("https://huggingface.co/") ? "models from Hugging Face" : "models from this site";
  }

  url(name, ext) { return `${this.base}/${name}.${ext}`; }

  async fetch(name, ext, onProgress) {
    const url = this.url(name, ext);
    const cache = "caches" in self ? await caches.open(CACHE).catch(() => null) : null;
    const cached = await cache?.match(url);
    if (cached) return cached.arrayBuffer();
    const response = await fetch(url);
    if (!response.ok) { if (response.status === 404) return null; throw new Error(`${url}: HTTP ${response.status}`); }
    const bytes = await readWithProgress(response, onProgress);
    if (cache && ext === "onnx") await cache.put(url, new Response(bytes, { headers: { "content-type": "application/octet-stream" } })).catch(() => {});
    return bytes;
  }

  /** Models that must run on WebAssembly (backends.json, from compare.html). */
  async wasmOnly() {
    try { const r = await fetch(`${this.base}/backends.json`); return r.ok ? (await r.json()).wasmOnly ?? [] : []; } catch { return []; }
  }

  /** Model names available on the server (from its index.json, written by the exporter). */
  async list() {
    try { const r = await fetch(`${this.base}/index.json`); return r.ok ? (await r.json()).models ?? [] : []; } catch { return []; }
  }

  async cached(name) {
    const cache = "caches" in self ? await caches.open(CACHE).catch(() => null) : null;
    return !!(await cache?.match(this.url(name, "onnx")));
  }

  /**
   * A file of the model repository by its manifest path ("coreml/<text encoder>.tokens.npy"): next to web/
   * on Hugging Face; for this site's models/ folder, /coreml/ (serve.py serves native/coreml there).
   */
  repositoryUrl(path) { return this.base.endsWith("/web") ? `${this.base.slice(0, -4)}/${path}` : `${this.base}/../${path}`; }

  /** A whole repository file (kept in Cache Storage), or null when it is missing. */
  async readFile(path) {
    const url = this.repositoryUrl(path);
    const cache = "caches" in self ? await caches.open(CACHE).catch(() => null) : null;
    const cached = await cache?.match(url);
    if (cached) return cached.arrayBuffer();
    const response = await fetch(url);
    if (!response.ok) { if (response.status === 404) return null; throw new Error(`${url}: HTTP ${response.status}`); }
    const bytes = await response.arrayBuffer();
    await cache?.put(url, new Response(bytes)).catch(() => {});
    return bytes;
  }

  /**
   * Bytes start..<end of a repository file, with an HTTP range request: a prompt needs a few rows of a
   * token table, not the whole table (siglip2's is 393 MB). Pieces are kept in Cache Storage. A server
   * that ignores ranges sends the whole file, which is then kept in memory for the next reads.
   */
  async readRange(path, start, end) {
    const url = this.repositoryUrl(path);
    this.whole ??= new Map();
    if (this.whole.has(url)) return new Uint8Array(await this.whole.get(url), start, end - start);
    const key = `${url}?bytes=${start}-${end - 1}`;
    const cache = "caches" in self ? await caches.open(CACHE).catch(() => null) : null;
    const cached = await cache?.match(key);
    if (cached) return new Uint8Array(await cached.arrayBuffer());
    const response = await fetch(url, { headers: { Range: `bytes=${start}-${end - 1}` } });
    if (!response.ok) throw new Error(response.status === 404 ? `${path} is not in the model repository.` : `${url}: HTTP ${response.status}`);
    if (response.status !== 206) {
      const whole = response.arrayBuffer();
      this.whole.set(url, whole);
      return new Uint8Array(await whole, start, end - start);
    }
    const bytes = await response.arrayBuffer();
    await cache?.put(key, new Response(bytes)).catch(() => {});
    return new Uint8Array(bytes);
  }

  async forget(name) {
    const cache = "caches" in self ? await caches.open(CACHE).catch(() => null) : null;
    await cache?.delete(this.url(name, "onnx"));
  }
}

export class FolderSource {
  constructor(handle) { this.handle = handle; this.kind = "folder"; }

  async fetch(name, ext, onProgress) {
    try {
      const file = await (await this.handle.getFileHandle(`${name}.${ext}`)).getFile();
      onProgress?.(file.size, file.size);
      return file.arrayBuffer();
    } catch { return null; }
  }

  async list() {
    const names = [];
    for await (const [entry] of this.handle.entries()) if (entry.endsWith(".onnx")) names.push(entry.slice(0, -5));
    return names.sort();
  }

  async cached(name) { return (await this.list()).includes(name); }

  /** A repository file ("coreml/<file>") from the same folder, by its file name. */
  async file(path) {
    try { return await (await this.handle.getFileHandle(path.split("/").pop())).getFile(); } catch { return null; }
  }

  async readFile(path) { return (await this.file(path))?.arrayBuffer() ?? null; }

  async readRange(path, start, end) {
    const file = await this.file(path);
    if (!file) throw new Error(`${path.split("/").pop()} is not in the chosen folder.`);
    return new Uint8Array(await file.slice(start, end).arrayBuffer());
  }

  async wasmOnly() {
    const bytes = await this.fetch("backends", "json");
    try { return bytes ? JSON.parse(new TextDecoder().decode(bytes)).wasmOnly ?? [] : []; } catch { return []; }
  }
}
