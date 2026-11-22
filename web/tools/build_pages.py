"""Builds the GitHub Pages version of Artelico Web: the whole web edition (vision and language pages) as
static files. Models, and the demo videos when samples/videos is absent, load from Hugging Face.

    python3 web/tools/build_pages.py [out]        # default: web/_site

The repository's workflow (.github/workflows/pages.yml) runs this and publishes the result.

GitHub Pages can't send the cross-origin isolation headers that serve.py sends, and without them ONNX
Runtime runs on one WebAssembly thread. So this build adds a small service worker (coi-sw.js) that adds
the headers to the site's own pages; the first visit loads once without it and reloads itself once the
worker is active. Browsers without service workers simply stay on one thread.
"""
import os, shutil, sys

WEB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(WEB, "_site")
COPY = ("css", "js", "data", "samples", "vendor", "LICENSE")   # not the test pages: they need local models
LEAVE_OUT = {"data/tddfa_bfm68.bin"}   # Basel Face Model licence: not for a public site without the owner's OK
PAGES = ("index.html",)

SERVICE_WORKER = """// Adds the cross-origin isolation headers to this site's own responses (GitHub Pages can't send them),
// so ONNX Runtime can use several WebAssembly threads. Other sites' responses pass through untouched.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));
self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (new URL(request.url).origin !== self.location.origin) return;
  event.respondWith(fetch(request).then((response) => {
    if (response.status === 0 || response.type === "opaqueredirect") return response;
    const headers = new Headers(response.headers);
    headers.set("Cross-Origin-Embedder-Policy", "require-corp");
    headers.set("Cross-Origin-Opener-Policy", "same-origin");
    headers.set("Cross-Origin-Resource-Policy", "cross-origin");
    return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
  }));
});
"""

# Registers the worker and reloads once when the page isn't isolated yet (at most once per tab).
REGISTER = """<script>
  (() => {
    if (window.crossOriginIsolated || !window.isSecureContext || !("serviceWorker" in navigator)) return;
    let tried = true;
    try { tried = sessionStorage.getItem("artelico.coi") === "1"; sessionStorage.setItem("artelico.coi", "1"); } catch { /* no reload loop risk: stay on one thread */ }
    navigator.serviceWorker.register("coi-sw.js").then(() => navigator.serviceWorker.ready).then(() => { if (!tried) location.reload(); }).catch(() => {});
  })();
  </script>
"""


def main():
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    for item in COPY:
        src = os.path.join(WEB, item)
        if os.path.isdir(src):
            shutil.copytree(src, os.path.join(OUT, item),
                            ignore=lambda folder, names: [n for n in names if os.path.relpath(os.path.join(folder, n), WEB) in LEAVE_OUT or n == ".DS_Store"])
        elif os.path.isfile(src):
            shutil.copyfile(src, os.path.join(OUT, item))
    for page in PAGES:
        src = os.path.join(WEB, page)
        if not os.path.isfile(src):
            continue
        html = open(src).read()
        assert "</head>" in html, page
        open(os.path.join(OUT, page), "w").write(html.replace("</head>", REGISTER + "</head>", 1))
    open(os.path.join(OUT, "coi-sw.js"), "w").write(SERVICE_WORKER)
    open(os.path.join(OUT, ".nojekyll"), "w").close()
    size = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(OUT) for f in fs)
    print(f"Pages site built in {os.path.abspath(OUT)}: {size / 1e6:.0f} MB")


if __name__ == "__main__":
    main()
