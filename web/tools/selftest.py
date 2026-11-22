"""Runs a page of Artelico Web in headless Chrome (own throwaway profile) and prints its RESULT lines.

    python3 web/tools/selftest.py "test.html?checks=detection:yolov8m@bus.jpg" [--port 8000] [--timeout 300]

The page prints "RESULT {json}" lines to the console and "DONE" at the end. The dev server must be
running (web/serve.py).
"""
import argparse, json, re, subprocess, sys, tempfile, time

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

p = argparse.ArgumentParser()
p.add_argument("page")
p.add_argument("--port", type=int, default=8000)
p.add_argument("--timeout", type=int, default=300)
p.add_argument("--wasm", action="store_true", help="hide WebGPU (test the WebAssembly fallback)")
a = p.parse_args()

profile = tempfile.mkdtemp(prefix="artelico-chrome-")
flags = ["--headless=new", f"--user-data-dir={profile}", "--no-first-run", "--no-default-browser-check",
         "--enable-logging=stderr", "--v=0", "--disable-extensions", "--remote-debugging-port=0"]
flags += ["--disable-features=WebGPU"] if a.wasm else ["--enable-unsafe-webgpu", "--enable-features=WebGPU"]
url = f"http://localhost:{a.port}/{a.page}"
chrome = subprocess.Popen([CHROME, *flags, url], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, errors="replace")
deadline = time.time() + a.timeout
results = []
try:
    for line in chrome.stderr:
        m = re.search(r'"(RESULT .*|INFO .*|DONE)"', line) or re.search(r"(RESULT \{.*\}|INFO .*|DONE)", line)
        if m:
            text = m.group(1).replace('\\"', '"')
            if text == "DONE":
                break
            print(text, flush=True)
            if text.startswith("RESULT "):
                results.append(text)
        elif "Uncaught" in line or "ERROR:" in line and "CONSOLE" in line:
            print("console:", line.strip()[:300], flush=True)
        if time.time() > deadline:
            print("TIMEOUT", flush=True)
            break
finally:
    chrome.kill()
sys.exit(0 if results and all('"error"' not in r for r in results) else 1)
