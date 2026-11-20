#!/usr/bin/env python3
"""Pretend VISCA PTZ cameras you can watch move, for trying Churchfront Video's camera
controls without cameras.

    python3 Tools/fake_ptz.py [--cams 3] [--web 8090]

Each camera answers VISCA over IP (UDP 52381, 52382, ...) and VISCA over TCP (5678, 5679, ...),
like a PTZOptics: it pans, tilts and zooms at the speed it's asked, goes to absolute
positions and presets, and answers position and exposure questions, so saved shots, presets,
home and the exposure row all work. Open http://localhost:8090 to watch what each camera
"sees": a drawn church stage, and where on it the camera points.

The quickest way to try it with the app, with no setup and nothing saved:

    python3 Tools/fake_avmatrix.py          (or: python3 Tools/fake_atem.py 9910)
    python3 Tools/fake_ptz.py
    CUEVIDEO_HOST=127.0.0.1 CUEVIDEO_SWITCHER=avmatrix CUEVIDEO_FAKECAMS=127.0.0.1 \\
        "./Churchfront Video.app/Contents/MacOS/CueVideo"

CUEVIDEO_FAKECAMS adds three VISCA cameras on 127.0.0.1, ports 52381 to 52383, on switcher
inputs 1 to 3. Put input 1, 2 or 3 on Next and the joystick moves that camera.

These cameras send no video, so the app's camera tiles stay black and auto tracking (which
watches the camera's picture for people) can't run on them.
"""
import argparse
import json
import math
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# PTZOptics units, as the app's VISCAUnits.ptzOptics expects them.
COUNTS_PER_DEG = 14.4
PAN_LIMIT = 170 * COUNTS_PER_DEG
TILT_DOWN, TILT_UP = -30 * COUNTS_PER_DEG, 90 * COUNTS_PER_DEG
ZOOM_MAX = 16384
WIDE_FOV, ZOOM_RATIO = 58.0, 20.0
MAX_PAN_DPS, MAX_TILT_DPS = 100.0, 70.0      # degrees a second at the top speed
ZOOM_FULL_SECONDS = 3.0                      # wide to tele at the top zoom speed


def nibbles(v, n=4):
    v &= (1 << (4 * n)) - 1
    return [(v >> (4 * (n - 1 - i))) & 0x0F for i in range(n)]


def from_nibbles(b):
    v = 0
    for x in b:
        v = (v << 4) | (x & 0x0F)
    return v - 0x10000 if v >= 0x8000 else v


class Camera:
    def __init__(self, n):
        self.n = n
        self.lock = threading.Lock()
        self.pan = self.tilt = 0.0          # counts
        self.zoom = 0.0                     # 0 to ZOOM_MAX
        self.pan_v = self.tilt_v = 0.0      # counts a second, signed
        self.zoom_v = 0.0
        self.target = None                  # (pan, tilt, pan speed, tilt speed) in counts
        self.zoom_target = None
        self.presets = {}
        self.autofocus = True
        self.ae, self.shutter, self.iris, self.gain = 0x00, 6, 7, 0
        self.wb, self.kelvin_pos = 0x00, 30
        self.last = "waiting for the app"

    # -- Motion, 50 times a second -------------------------------------------------------
    def step(self, dt):
        with self.lock:
            if self.target:
                tp, tt, sp, st = self.target
                self.pan = self._toward(self.pan, tp, sp * dt)
                self.tilt = self._toward(self.tilt, tt, st * dt)
                if self.pan == tp and self.tilt == tt:
                    self.target = None
            else:
                self.pan = max(-PAN_LIMIT, min(PAN_LIMIT, self.pan + self.pan_v * dt))
                self.tilt = max(TILT_DOWN, min(TILT_UP, self.tilt + self.tilt_v * dt))
            if self.zoom_target is not None:
                self.zoom = self._toward(self.zoom, self.zoom_target, ZOOM_MAX / ZOOM_FULL_SECONDS * dt)
                if self.zoom == self.zoom_target:
                    self.zoom_target = None
            else:
                self.zoom = max(0.0, min(ZOOM_MAX, self.zoom + self.zoom_v * dt))

    @staticmethod
    def _toward(v, goal, by):
        return goal if abs(goal - v) <= by else v + math.copysign(by, goal - v)

    @staticmethod
    def _speed(s, top, top_dps):
        """VISCA speed step (1 to top) as counts a second."""
        s = max(1, min(top, s))
        return (0.5 + (top_dps - 0.5) * ((s - 1) / (top - 1)) ** 2) * COUNTS_PER_DEG

    def fov(self):
        return WIDE_FOV * (1 / ZOOM_RATIO) ** (self.zoom / ZOOM_MAX)

    # -- VISCA -------------------------------------------------------------------------
    def handle(self, m):
        """One VISCA message (from 8x to FF). Returns the reply messages."""
        ack, done = [0x90, 0x41, 0xFF], [0x90, 0x51, 0xFF]
        if len(m) < 3:
            return []
        with self.lock:
            if m[1] == 0x09:
                return [self._inquiry(m[2:-1])]
            if m[1] != 0x01:
                return []
            c = m[2:-1]
            what = self._command(c)
            if what:
                self.last = what
            return [ack, done]

    def _command(self, c):
        if c[:2] == [0x06, 0x01] and len(c) >= 6:          # drive
            ps, ts, pd, td = c[2], c[3], c[4], c[5]
            self.target = None
            self.pan_v = {0x01: -1, 0x02: 1}.get(pd, 0) * self._speed(ps, 0x18, MAX_PAN_DPS)
            self.tilt_v = {0x01: 1, 0x02: -1}.get(td, 0) * self._speed(ts, 0x14, MAX_TILT_DPS)
            if self.pan_v == 0 and self.tilt_v == 0:
                return "stop"
            way = ("left" if pd == 1 else "right" if pd == 2 else "") + ("up" if td == 1 else "down" if td == 2 else "")
            return f"move {way} (speed {ps}/{ts})"
        if c[:2] == [0x06, 0x02] and len(c) >= 12:         # absolute position
            sp, st = self._speed(c[2], 0x18, MAX_PAN_DPS), self._speed(c[3], 0x14, MAX_TILT_DPS)
            p, t = from_nibbles(c[4:8]), from_nibbles(c[8:12])
            self.pan_v = self.tilt_v = 0
            self.target = (max(-PAN_LIMIT, min(PAN_LIMIT, p)), max(TILT_DOWN, min(TILT_UP, t)), sp, st)
            return f"go to pan {p / COUNTS_PER_DEG:.1f}°, tilt {t / COUNTS_PER_DEG:.1f}°"
        if c[:2] == [0x06, 0x04]:                           # home
            self.pan_v = self.tilt_v = 0
            self.target = (0, 0, self._speed(0x14, 0x18, MAX_PAN_DPS), self._speed(0x12, 0x14, MAX_TILT_DPS))
            return "home"
        if c[:2] == [0x04, 0x07] and len(c) >= 3:           # zoom
            v = c[2]
            self.zoom_target = None
            rate = ZOOM_MAX / ZOOM_FULL_SECONDS * ((v & 0x0F) + 1) / 8
            self.zoom_v = rate if v & 0xF0 == 0x20 else -rate if v & 0xF0 == 0x30 else 0
            return "zoom stop" if self.zoom_v == 0 else f"zoom {'in' if self.zoom_v > 0 else 'out'}"
        if c[:2] == [0x04, 0x47] and len(c) >= 6:           # zoom to
            self.zoom_v = 0
            self.zoom_target = max(0, min(ZOOM_MAX, from_nibbles(c[2:6]) & 0xFFFF))
            return f"zoom to {self.zoom_target}"
        if c[:2] == [0x04, 0x3F] and len(c) >= 4:           # presets
            op, n = c[2], c[3]
            if op == 0x01:
                self.presets[n] = (self.pan, self.tilt, self.zoom)
                return f"save preset {n}"
            if op == 0x02 and n in self.presets:
                p, t, z = self.presets[n]
                self.pan_v = self.tilt_v = self.zoom_v = 0
                self.target = (p, t, self._speed(0x14, 0x18, MAX_PAN_DPS), self._speed(0x12, 0x14, MAX_TILT_DPS))
                self.zoom_target = z
                return f"recall preset {n}"
            if op == 0x02:
                return f"recall preset {n} (empty)"
            if op == 0x00:
                self.presets.pop(n, None)
                return f"clear preset {n}"
        if c[:2] == [0x04, 0x38] and len(c) >= 3:
            self.autofocus = c[2] == 0x02
            return f"focus {'auto' if self.autofocus else 'manual'}"
        if c[:2] == [0x04, 0x18]:
            return "focus once"
        if c[:2] == [0x04, 0x39] and len(c) >= 3:
            self.ae = c[2]
            return "exposure " + ("auto" if c[2] == 0 else "manual" if c[2] == 3 else f"mode {c[2]:02x}")
        if len(c) >= 6 and c[0] == 0x04 and c[1] in (0x4A, 0x4B, 0x0C):
            v = (c[4] << 4) | c[5]
            name = {0x4A: "shutter", 0x4B: "iris", 0x0C: "gain"}[c[1]]
            setattr(self, name, v)
            return f"{name} {v}"
        if c[:2] == [0x04, 0x35] and len(c) >= 3:
            self.wb = c[2]
            return "white balance " + {0: "auto", 1: "tungsten", 2: "daylight", 0x20: "kelvin"}.get(c[2], "?")
        if c[:2] == [0x04, 0x20] and len(c) >= 4:
            self.kelvin_pos = (c[2] << 4) | c[3]
            return f"color temperature {2500 + self.kelvin_pos * 100} K"
        return "command " + " ".join(f"{b:02x}" for b in c)

    def _inquiry(self, q):
        def value7(v): return [0x90, 0x50, 0, 0, (v >> 4) & 0x0F, v & 0x0F, 0xFF]
        if q == [0x06, 0x12]:
            return [0x90, 0x50] + nibbles(round(self.pan)) + nibbles(round(self.tilt)) + [0xFF]
        if q == [0x04, 0x47]:
            return [0x90, 0x50] + nibbles(round(self.zoom)) + [0xFF]
        if q == [0x04, 0x00]:
            return [0x90, 0x50, 0x02, 0xFF]                       # power on
        if q == [0x04, 0x39]: return [0x90, 0x50, self.ae, 0xFF]
        if q == [0x04, 0x4A]: return value7(self.shutter)
        if q == [0x04, 0x4B]: return value7(self.iris)
        if q == [0x04, 0x4C]: return value7(self.gain)
        if q == [0x04, 0x35]: return [0x90, 0x50, self.wb, 0xFF]
        if q == [0x04, 0x20]: return [0x90, 0x50, self.kelvin_pos, 0xFF]
        return [0x90, 0x60, 0x02, 0xFF]                           # syntax error: not known

    def snapshot(self):
        with self.lock:
            moving = bool(self.target or self.pan_v or self.tilt_v or self.zoom_v or self.zoom_target is not None)
            return {"n": self.n, "pan": self.pan / COUNTS_PER_DEG, "tilt": self.tilt / COUNTS_PER_DEG,
                    "fov": self.fov(), "zoom": ZOOM_RATIO ** (self.zoom / ZOOM_MAX), "moving": moving,
                    "last": self.last, "presets": sorted(self.presets)}


def split(buf):
    """Whole VISCA messages (ending FF) from a byte list; returns (messages, rest)."""
    out = []
    while 0xFF in buf:
        i = buf.index(0xFF)
        out.append(buf[:i + 1])
        buf = buf[i + 1:]
    return out, buf


def serve_udp(cam, s):
    while True:
        b, addr = s.recvfrom(2048)
        if len(b) >= 8 and b[0] == 0x02 and b[1] == 0x00:      # control: reset sequence
            s.sendto(bytes([0x02, 0x01, 0, 1]) + b[4:8] + bytes([0x01]), addr)
            continue
        if len(b) < 9 or b[0] != 0x01:
            continue
        seq = b[4:8]
        for m in split(list(b[8:]))[0]:
            for r in cam.handle(m):
                s.sendto(bytes([0x01, 0x11, 0, len(r)]) + seq + bytes(r), addr)


def serve_tcp(cam, srv):
    def client(c):
        buf = []
        with c:
            while True:
                b = c.recv(2048)
                if not b:
                    return
                msgs, buf = split(buf + list(b))
                for m in msgs:
                    for r in cam.handle(m):
                        c.sendall(bytes(r))
    while True:
        c, _ = srv.accept()
        threading.Thread(target=client, args=(c,), daemon=True).start()


PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>Pretend PTZ cameras</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root{--bg:#111418;--card:#1b2027;--ink:#e8ecf1;--muted:#8b95a3;--accent:#f2b23a;--live:#e5484d}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.4 -apple-system,system-ui,sans-serif}
header{padding:16px 20px}h1{font-size:18px;margin:0 0 4px}header p{margin:0;color:var(--muted)}
main{display:flex;flex-wrap:wrap;gap:16px;padding:0 20px 20px}
.cam{background:var(--card);border-radius:10px;padding:12px;width:min(480px,100%)}
.cam h2{font-size:14px;margin:0 0 8px;display:flex;justify-content:space-between}
canvas{width:100%;border-radius:6px;display:block;background:#000}
.hud{display:grid;grid-template-columns:repeat(3,1fr);gap:4px;margin-top:8px;font-variant-numeric:tabular-nums}
.hud div span{display:block;color:var(--muted);font-size:11px}.last{margin-top:6px;color:var(--accent);font-size:12px;min-height:16px}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:#3a414b;margin-right:6px}.dot.on{background:var(--accent)}
</style></head><body>
<header><h1>Pretend PTZ cameras</h1><p>What each camera points at on a drawn stage. The strip under each view is the whole stage, with the camera's frame on it.</p></header>
<main id="cams"></main>
<script>
const W = 480, H = 270;
// The stage, in degrees from the camera (pan right +, tilt up +).
const people = [
  {name:"Pastor", az:0, el:-4, h:9, color:"#4a7bd0", walk:18},
  {name:"Worship lead", az:-22, el:-6, h:8, color:"#c0563f"},
  {name:"Guitar", az:-34, el:-6, h:8, color:"#5a9b5a"},
  {name:"Keys", az:28, el:-6, h:8, color:"#9b6bc0"},
  {name:"Drums", az:40, el:-4, h:7, color:"#c09b3f"},
];
function stage(ctx, proj, t) {
  const r = (a0, e0, a1, e1, fill) => { const p = proj(a0, e1), q = proj(a1, e0); ctx.fillStyle = fill; ctx.fillRect(p.x, p.y, q.x - p.x, q.y - p.y); };
  r(-90, -40, 90, 60, "#2a2320");            // back wall
  r(-90, -40, 90, -14, "#3b2e25");           // stage floor
  r(-14, 6, 14, 24, "#20344d");              // big screen
  r(-12, 8, 12, 22, "#2f5f8f");
  ctx.fillStyle = "#e8ecf1"; const c = proj(0, 15); ctx.font = `${Math.max(8, proj(4,0).x - proj(0,0).x)}px system-ui`; ctx.textAlign = "center"; ctx.fillText("Welcome", c.x, c.y);
  r(-2.5, -14, 2.5, -6, "#6b4a32");          // pulpit
  r(38, -12, 46, -6, "#555");                // drum riser
  r(24, -9, 32, -7, "#222");                 // keyboard
  for (const p of people) {
    const az = p.walk ? p.az + p.walk * Math.sin(t / 6000) : p.az;
    const top = proj(az, p.el + p.h), feet = proj(az, p.el - 6), head = (feet.y - top.y) / 7;
    ctx.fillStyle = p.color;
    ctx.beginPath(); ctx.roundRect(top.x - head * 1.1, top.y + head * 2, head * 2.2, feet.y - top.y - head * 2, head * 0.6); ctx.fill();
    ctx.fillStyle = "#e0b48f"; ctx.beginPath(); ctx.arc(top.x, top.y + head, head, 0, 7); ctx.fill();
    ctx.fillStyle = "rgba(255,255,255,.75)"; ctx.font = `${Math.max(8, head)}px system-ui`; ctx.fillText(p.name, top.x, feet.y + head * 1.4);
  }
}
function draw(cam, el, t) {
  const v = el.querySelector(".view").getContext("2d"), s = el.querySelector(".strip").getContext("2d");
  const fx = cam.fov, fy = cam.fov * 9 / 16;
  stage(v, (a, e) => ({x: (a - cam.pan) / fx * W + W / 2, y: H / 2 - (e - cam.tilt) / fy * H}), t);
  v.strokeStyle = "rgba(255,255,255,.35)"; v.lineWidth = 1; v.beginPath();
  v.moveTo(W/2 - 10, H/2); v.lineTo(W/2 + 10, H/2); v.moveTo(W/2, H/2 - 10); v.lineTo(W/2, H/2 + 10); v.stroke();
  const SW = 480, SH = 90, sx = a => (a + 90) / 180 * SW, sy = e => SH / 2 - (e - 10) / 50 * SH;
  stage(s, (a, e) => ({x: sx(a), y: sy(e)}), t);
  s.strokeStyle = cam.moving ? "#f2b23a" : "#fff"; s.lineWidth = 2;
  s.strokeRect(sx(cam.pan - fx / 2), sy(cam.tilt + fy / 2), sx(cam.pan + fx / 2) - sx(cam.pan - fx / 2), sy(cam.tilt - fy / 2) - sy(cam.tilt + fy / 2));
  el.querySelector(".pan").textContent = cam.pan.toFixed(1) + "°";
  el.querySelector(".tilt").textContent = cam.tilt.toFixed(1) + "°";
  el.querySelector(".zoom").textContent = cam.zoom.toFixed(1) + "×";
  el.querySelector(".dot").classList.toggle("on", cam.moving);
  el.querySelector(".last").textContent = cam.last + (cam.presets.length ? `  ·  presets: ${cam.presets.join(", ")}` : "");
}
const els = {};
let state = [];
async function poll() {
  try { state = await (await fetch("/state")).json(); } catch (e) {}
  for (const cam of state) {
    if (!els[cam.n]) {
      const d = document.createElement("section"); d.className = "cam";
      d.innerHTML = `<h2><span><i class="dot"></i>Camera ${cam.n}</span><span style="color:var(--muted)">VISCA UDP ${cam.udp} · TCP ${cam.tcp}</span></h2>
        <canvas class="view" width="${W}" height="${H}"></canvas><canvas class="strip" width="480" height="90" style="margin-top:6px"></canvas>
        <div class="hud"><div><span>Pan</span><b class="pan"></b></div><div><span>Tilt</span><b class="tilt"></b></div><div><span>Zoom</span><b class="zoom"></b></div></div>
        <div class="last"></div>`;
      document.getElementById("cams").appendChild(d); els[cam.n] = d;
    }
  }
  setTimeout(poll, 60);
}
function frame(t) { for (const cam of state) if (els[cam.n]) draw(cam, els[cam.n], t); requestAnimationFrame(frame); }
poll(); requestAnimationFrame(frame);
</script></body></html>"""


def main():
    ap = argparse.ArgumentParser(description="Pretend VISCA PTZ cameras with a viewer.")
    ap.add_argument("--cams", type=int, default=3, help="how many cameras (default 3)")
    ap.add_argument("--udp", type=int, default=52381, help="first VISCA over IP port (default 52381)")
    ap.add_argument("--tcp", type=int, default=5678, help="first VISCA over TCP port (default 5678)")
    ap.add_argument("--web", type=int, default=8090, help="viewer port (default 8090)")
    a = ap.parse_args()

    # Open every port first, so one in use (another copy of this, or a real camera's
    # software) stops it with a clear message rather than leaving a camera that never answers.
    def open_port(kind, port):
        try:
            if kind == "UDP":
                s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                s.bind(("0.0.0.0", port))
            else:
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                s.bind(("0.0.0.0", port))
                s.listen(4)
            return s
        except OSError as e:
            raise SystemExit(f"{kind} port {port} is in use ({e.strerror}). Is another fake_ptz.py still running? "
                             f"Close it, or pick other ports with --udp, --tcp and --web.")

    cams = [Camera(i + 1) for i in range(a.cams)]
    socks = []
    for i, c in enumerate(cams):
        c.udp, c.tcp = a.udp + i, a.tcp + i
        socks.append((c, open_port("UDP", c.udp), open_port("TCP", c.tcp)))
    try:
        web = ThreadingHTTPServer(("0.0.0.0", a.web), None)
    except OSError as e:
        raise SystemExit(f"Viewer port {a.web} is in use ({e.strerror}). Pick another with --web.")
    for c, u, t in socks:
        threading.Thread(target=serve_udp, args=(c, u), daemon=True).start()
        threading.Thread(target=serve_tcp, args=(c, t), daemon=True).start()

    def physics():
        last = time.monotonic()
        while True:
            time.sleep(0.02)
            now = time.monotonic()
            for c in cams:
                c.step(now - last)
            last = now
    threading.Thread(target=physics, daemon=True).start()

    class Web(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/state":
                body = json.dumps([dict(c.snapshot(), udp=c.udp, tcp=c.tcp) for c in cams]).encode()
                kind = "application/json"
            else:
                body, kind = PAGE.encode(), "text/html; charset=utf-8"
            self.send_response(200)
            self.send_header("Content-Type", kind)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    for c in cams:
        print(f"Camera {c.n}: VISCA over IP on UDP {c.udp}, VISCA over TCP on {c.tcp}", flush=True)
    print(f"Watch them at http://localhost:{a.web}", flush=True)
    last_seen = {}
    web.RequestHandlerClass = Web
    threading.Thread(target=web.serve_forever, daemon=True).start()
    try:
        watch(cams, last_seen)
    except KeyboardInterrupt:
        print()


def watch(cams, last_seen):
    """Prints each new command, until Ctrl+C."""
    while True:
        time.sleep(0.2)
        for c in cams:
            s = c.snapshot()
            if last_seen.get(c.n) != s["last"]:
                last_seen[c.n] = s["last"]
                if s["last"] != "waiting for the app":
                    print(f"Camera {c.n}: {s['last']}", flush=True)


if __name__ == "__main__":
    main()
