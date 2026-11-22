"""Screenshots of Artelico Web pages from headless Chrome (own throwaway profile), driven through the
DevTools protocol with only the standard library.

    python3 web/tools/shot.py <out.png> "<page#hash>" [--wait "<js condition>"] [--size 1400x1000]
                              [--timeout 120] [--eval "<js run after loading>"] [--dark]

Waits until the JavaScript condition is true (default: the status box says Ready), then saves a PNG.
The page's console errors are printed.
"""
import argparse, base64, json, os, socket, struct, subprocess, tempfile, time, urllib.request

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"


class CDP:
    def __init__(self, ws_url):
        host, rest = ws_url[len("ws://"):].split("/", 1)
        h, p = host.split(":")
        self.sock = socket.create_connection((h, int(p)))
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f"GET /{rest} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        response = b""
        while b"\r\n\r\n" not in response:
            response += self.sock.recv(1)
        self.id = 0
        self.events = []

    def _send(self, text):
        data = text.encode()
        header = bytes([0x81])
        mask = os.urandom(4)
        n = len(data)
        header += bytes([0x80 | n]) if n < 126 else (bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536 else bytes([0x80 | 127]) + struct.pack(">Q", n))
        self.sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _exact(self, n):
        out = b""
        while len(out) < n:
            chunk = self.sock.recv(n - len(out))
            if not chunk:
                raise ConnectionError("closed")
            out += chunk
        return out

    def _receive(self):
        message = b""
        while True:
            b0, b1 = self._exact(2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._exact(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._exact(8))[0]
            message += self._exact(n)
            if b0 & 0x80:
                return json.loads(message)

    def call(self, method, **params):
        self.id += 1
        self._send(json.dumps({"id": self.id, "method": method, "params": params}))
        while True:
            m = self._receive()
            if m.get("id") == self.id:
                if "error" in m:
                    raise RuntimeError(m["error"])
                return m.get("result", {})
            self.events.append(m)

    def evaluate(self, expression):
        r = self.call("Runtime.evaluate", expression=expression, awaitPromise=True, returnByValue=True)
        return r.get("result", {}).get("value")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("out")
    p.add_argument("page")
    p.add_argument("--port", type=int, default=8000)
    p.add_argument("--wait", default="document.querySelector('#status')?.textContent.includes('models from')")
    p.add_argument("--eval", default=None)
    p.add_argument("--after", type=float, default=1.0, help="seconds to wait after the condition")
    p.add_argument("--size", default="1400x1000")
    p.add_argument("--timeout", type=int, default=120)
    p.add_argument("--dark", action="store_true")
    p.add_argument("--profile", default=None, help="keep this Chrome profile folder (downloaded models stay cached)")
    a = p.parse_args()
    width, height = map(int, a.size.split("x"))
    profile = a.profile or tempfile.mkdtemp(prefix="artelico-chrome-")
    debug_port = 9333
    chrome = subprocess.Popen([CHROME, "--headless=new", f"--user-data-dir={profile}", f"--remote-debugging-port={debug_port}",
                               "--no-first-run", "--no-default-browser-check", "--enable-unsafe-webgpu", "--enable-features=WebGPU",
                               "--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream", "--autoplay-policy=no-user-gesture-required",
                               "about:blank"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            try:
                targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{debug_port}/json"))
                page = next(t for t in targets if t["type"] == "page")
                break
            except Exception:
                time.sleep(0.1)
        cdp = CDP(page["webSocketDebuggerUrl"])
        cdp.call("Runtime.enable")
        cdp.call("Emulation.setDeviceMetricsOverride", width=width, height=height, deviceScaleFactor=1, mobile=width < 600)
        if a.dark:
            cdp.call("Emulation.setEmulatedMedia", features=[{"name": "prefers-color-scheme", "value": "dark"}])
        cdp.call("Page.navigate", url=a.page if a.page.startswith("http") else f"http://localhost:{a.port}/{a.page}")
        deadline = time.time() + a.timeout
        ok = False
        time.sleep(0.5)
        while time.time() < deadline:
            try:
                if cdp.evaluate(f"Boolean({a.wait})"):
                    ok = True
                    break
            except Exception:
                pass
            time.sleep(0.5)
        if a.eval:
            print("eval:", cdp.evaluate(a.eval))
            time.sleep(a.after)
            deadline = time.time() + a.timeout
        time.sleep(a.after)
        shot = cdp.call("Page.captureScreenshot", format="png")
        with open(a.out, "wb") as f:
            f.write(base64.b64decode(shot["data"]))
        for e in cdp.events:
            if e.get("method") == "Runtime.exceptionThrown":
                print("exception:", e["params"]["exceptionDetails"].get("exception", {}).get("description", "")[:300])
            if e.get("method") == "Runtime.consoleAPICalled" and e["params"]["type"] in ("error", "warning"):
                print("console", e["params"]["type"] + ":", " ".join(str(x.get("value", x.get("description", ""))) for x in e["params"]["args"])[:300])
        print("saved" if ok else "saved (condition not met before the timeout)", a.out)
    finally:
        chrome.kill()


if __name__ == "__main__":
    main()
