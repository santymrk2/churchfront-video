import socket, time, struct, json, urllib.request
seq = 0
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.settimeout(1)
def send(body, inquiry=False):
    global seq; seq += 1
    u.sendto(bytes([0x01, 0x10 if inquiry else 0x00, 0, len(body)]) + struct.pack(">I", seq) + bytes(body), ("127.0.0.1", 52381))
def replies(n):
    out = []
    for _ in range(n):
        try: out.append(u.recv(256)[8:].hex(" "))
        except socket.timeout: break
    return out
def word(b): v = int("".join(f"{x & 15:x}" for x in b), 16); return v - 0x10000 if v >= 0x8000 else v
def pos():
    send([0x81, 0x09, 0x06, 0x12, 0xFF], True); r = bytes.fromhex(replies(1)[0].replace(" ", ""))
    send([0x81, 0x09, 0x04, 0x47, 0xFF], True); z = bytes.fromhex(replies(1)[0].replace(" ", ""))
    return word(r[2:6]) / 14.4, word(r[6:10]) / 14.4, word(z[2:6])
ok = lambda c, m: print("ok  " if c else "FAIL", m)
u.sendto(bytes([0x02, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0x01]), ("127.0.0.1", 52381)); print("reset ->", u.recv(64).hex(" "))
send([0x81, 0x09, 0x04, 0x00, 0xFF], True); ok(replies(1) == ["90 50 02 ff"], "power inquiry answers on")
send([0x81, 0x01, 0x06, 0x01, 0x18, 0x01, 0x02, 0x03, 0xFF]); ok(replies(2) == ["90 41 ff", "90 51 ff"], "drive acked + completed")
time.sleep(0.5); send([0x81, 0x01, 0x06, 0x01, 0x01, 0x01, 0x03, 0x03, 0xFF]); replies(2)
p, t, z = pos(); ok(40 < p < 60 and t == 0, f"panned right at top speed for 0.5s: pan {p:.1f}°")
send([0x81, 0x01, 0x04, 0x3F, 0x01, 0x00, 0xFF]); replies(2)
send([0x81, 0x01, 0x06, 0x02, 0x14, 0x12] + [0xF, 0xE, 0x9, 0x8] + [0, 0, 0x9, 0x0] + [0xFF]); replies(2)  # pan -360 counts (-25°), tilt 144 (10°)
time.sleep(1.2); p, t, z = pos(); ok(abs(p + 25) < 0.1 and abs(t - 10) < 0.1, f"absolute go to: pan {p:.1f}°, tilt {t:.1f}°")
send([0x81, 0x01, 0x04, 0x47, 0x2, 0x0, 0x0, 0x0, 0xFF]); replies(2); time.sleep(1.0)
p, t, z = pos(); ok(z == 0x2000, f"zoom to 8192: {z}")
send([0x81, 0x01, 0x04, 0x3F, 0x02, 0x00, 0xFF]); replies(2); time.sleep(2.5)
p, t, z = pos(); ok(abs(p - 50) < 10 and z == 0, f"preset 1 recalled: pan {p:.1f}°, zoom {z}")
send([0x81, 0x09, 0x04, 0x4A, 0xFF], True); ok(replies(1) == ["90 50 00 00 00 06 ff"], "shutter inquiry, 7 bytes")
send([0x81, 0x09, 0x04, 0x20, 0xFF], True); ok(len(replies(1)[0].split()) == 4, "color temp inquiry, 4 bytes")
t_ = socket.create_connection(("127.0.0.1", 5679)); t_.settimeout(1)
t_.sendall(bytes([0x81, 0x01, 0x06, 0x04, 0xFF, 0x81, 0x09, 0x06, 0x12, 0xFF]))
time.sleep(0.2); ok(t_.recv(256).hex(" ").startswith("90 41 ff 90 51 ff 90 50"), "TCP camera 2: two messages in one write")
st = json.load(urllib.request.urlopen("http://127.0.0.1:8099/state"))
ok(len(st) == 2 and st[0]["presets"] == [0] and "recall preset" in st[0]["last"], f"viewer state: {st[0]}")
html = urllib.request.urlopen("http://127.0.0.1:8099/").read().decode()
open("page.js", "w").write(html.split("<script>")[1].split("</script>")[0])
