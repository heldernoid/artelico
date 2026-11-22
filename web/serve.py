"""Development server for Artelico Web: serves this folder (models/ links to native/web).

    python3 web/serve.py [port]      (default 8000)

Sends the cross-origin isolation headers, so ONNX Runtime can use several WebAssembly threads, and
the right types for .mjs, .wasm and .onnx files. Answers range requests (tagging from text reads a few
rows of the token tables). /coreml/ is the model repository's coreml/ folder next to models/
(native/coreml: the CLIP / SigLIP tables), as on Hugging Face; /testdata/ is the project's testdata
(test.html?tokens).
"""
import http.server, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(HERE)
# URL prefix -> folder outside web/ (development only).
OUTSIDE = {"/coreml/": os.path.join(os.path.realpath(os.path.join(HERE, "models")), "..", "coreml"),
           "/testdata/": os.path.join(HERE, "..", "testdata")}


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                      ".mjs": "text/javascript", ".js": "text/javascript", ".wasm": "application/wasm",
                      ".onnx": "application/octet-stream", ".json": "application/json", ".gguf": "application/octet-stream",
                      ".npy": "application/octet-stream"}

    def translate_path(self, path):
        clean = path.split("?", 1)[0].split("#", 1)[0]
        for prefix, folder in OUTSIDE.items():
            if clean.startswith(prefix) and not os.path.exists(os.path.join(HERE, clean.lstrip("/"))):
                relative = os.path.normpath(clean[len(prefix):]).lstrip("/")
                if relative.startswith(".."):
                    return os.path.join(HERE, "missing")
                return os.path.join(folder, relative)
        return super().translate_path(path)

    def send_head(self):
        match = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", "").strip())
        path = self.translate_path(self.path)
        if not match or not os.path.isfile(path):
            return super().send_head()
        size = os.path.getsize(path)
        start = int(match.group(1))
        end = min(int(match.group(2)) if match.group(2) else size - 1, size - 1)
        if start > end:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.end_headers()
            return None
        f = open(path, "rb")
        f.seek(start)
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        self.range_left = end - start + 1
        return f

    def copyfile(self, source, outputfile):
        left = getattr(self, "range_left", None)
        if left is None:
            return super().copyfile(source, outputfile)
        self.range_left = None
        while left > 0:
            chunk = source.read(min(left, 1 << 16))
            if not chunk:
                break
            outputfile.write(chunk)
            left -= len(chunk)

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "cross-origin")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def log_message(self, *args):
        pass


port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
print(f"Artelico Web on http://localhost:{port}/", flush=True)
http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
