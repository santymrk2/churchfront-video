#!/usr/bin/env python3
"""A pretend AVMATRIX switcher (PVS0403U / HVS0403U / HVS0402U), for trying Churchfront
Video without the hardware.

    python3 Tools/fake_avmatrix.py [--port 19523] [--reply-port 19522]

It listens on UDP 19523 like the real switcher and answers, and reports every change,
to port 19522 on the computer that sent the command. It keeps program, preview, fade to
black, key states and PIP sources, and prints each command it gets.

Then, in Churchfront Video: Setup > Switcher > AVMATRIX, address 127.0.0.1 (or this
computer's address from another one). Or set "switcher": "avmatrix" and "atemHost" in
config.json.

Typing in this window changes the pretend switcher as if someone pressed its buttons:
"p 3" puts input 3 on program, "v 2" on preview, "c" cuts, "a" auto, "f" fade to black,
"pip 1 6 on" puts input 3 (PIP source 6) in PIP 1 on air.
"""
import argparse
import select
import socket
import sys


def frame(cmd, data=()):
    body = [0x5A, 0, 0, 0, 0, 0, 1 + len(data), cmd, *data]
    total = len(body) + 2
    body[1] = total & 0xFF
    body[2] = (total >> 8) & 0xFF
    return bytes(body + [sum(body) & 0xFF, 0xDD])


def parse(b):
    out, i = [], 0
    while i + 10 <= len(b):
        if b[i] != 0x5A:
            i += 1
            continue
        n = b[i + 1] | b[i + 2] << 8
        if n < 10 or i + n > len(b) or b[i + n - 1] != 0xDD:
            i += 1
            continue
        dl = b[i + 6]
        out.append((b[i + 7], list(b[i + 8:i + 7 + dl])))
        i += n
    return out


class Switcher:
    def __init__(self):
        self.pgm, self.pvw, self.ftb = 1, 2, 0
        self.keys = [0] * 6          # luma, chroma, PIP 1, PIP 2, DSK, logo
        self.pip = [4, 5]            # PIP 1 and 2 sources (4..7 are inputs 1..4)

    def status(self):
        return [frame(0x12, [self.pgm]), frame(0x13, [self.pvw]), frame(0x11, [0x03, self.ftb]),
                frame(0x20, self.keys), frame(0x24, [self.pip[0], 0, 50, 50]), frame(0x25, [self.pip[1], 0, 60, 60])]

    def take(self):
        self.pgm, self.pvw = self.pvw, self.pgm

    def apply(self, cmd, d):
        """Returns a description, and whether the state changed."""
        if cmd == 0x12 and d: self.pgm = d[0]; return f"program {d[0]}", True
        if cmd == 0x13 and d: self.pvw = d[0]; return f"preview {d[0]}", True
        if cmd == 0x11 and len(d) >= 2:
            if d[0] == 0x01: self.take(); return "auto", True
            if d[0] == 0x02: self.take(); return "cut", True
            if d[0] == 0x03: self.ftb = d[1]; return f"fade to black {'on' if d[1] else 'off'}", True
            return f"transition {d[0]:02x} {d[1]:02x}", False
        if cmd == 0x20 and len(d) >= 6: self.keys = d[:6]; return f"keys {d[:6]}", True
        if cmd == 0xFE: return None, False
        if cmd == 0xFF: return None, False
        return f"command {cmd:02x} {bytes(d).hex(' ')} (ignored)", False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=19523)
    ap.add_argument("--reply-port", type=int, default=19522)
    a = ap.parse_args()
    sw = Switcher()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", a.port))
    clients = set()
    print(f"Pretend AVMATRIX on UDP {a.port}, answering to port {a.reply_port}. Program {sw.pgm}, preview {sw.pvw}.", flush=True)

    def report():
        for c in clients:
            for f in sw.status():
                sock.sendto(f, (c, a.reply_port))

    inputs = [sock] + ([sys.stdin] if sys.stdin.isatty() else [])
    while True:
        ready, _, _ = select.select(inputs, [], [])
        if sock in ready:
            data, (addr, _) = sock.recvfrom(2048)
            clients.add(addr)
            changed = False
            for cmd, d in parse(data):
                what, ch = sw.apply(cmd, d)
                changed |= ch
                if what:
                    print(f"{addr}: {what}  ->  program {sw.pgm}, preview {sw.pvw}, black {sw.ftb}", flush=True)
                if cmd == 0xFE:
                    for f in sw.status():
                        sock.sendto(f, (addr, a.reply_port))
            if changed:
                report()
        if sys.stdin in ready:
            w = sys.stdin.readline().split()
            if not w:
                continue
            try:
                if w[0] == "p": sw.pgm = int(w[1])
                elif w[0] == "v": sw.pvw = int(w[1])
                elif w[0] in ("c", "a"): sw.take()
                elif w[0] == "f": sw.ftb = 0 if sw.ftb else 1
                elif w[0] == "pip":
                    n = int(w[1]) - 1
                    sw.pip[n] = int(w[2])
                    sw.keys[2 + n] = 2 if (len(w) > 3 and w[3] == "on") else 0
                print(f"panel  ->  program {sw.pgm}, preview {sw.pvw}, black {sw.ftb}, PIP {sw.pip} keys {sw.keys}", flush=True)
                report()
            except (IndexError, ValueError):
                print("p N, v N, c, a, f, pip N SOURCE on|off", flush=True)


if __name__ == "__main__":
    main()
