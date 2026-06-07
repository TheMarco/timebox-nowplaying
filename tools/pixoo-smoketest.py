#!/usr/bin/env python3
"""Quick connectivity test for a Divoom Pixoo 64 over its HTTP API — no app involved.

Usage:
    python3 tools/pixoo-smoketest.py <ip>
    python3 tools/pixoo-smoketest.py 192.168.1.42

Fills the panel solid red, green, blue, then a diagonal gradient. If you see those, the
device is reachable and the same Draw/SendHttpGif path the macOS app uses works — so any
remaining problem is in the app, not the network/protocol. Stdlib only (no pip install)."""

import base64
import json
import sys
import time
import urllib.request


def post(ip, body):
    req = urllib.request.Request(
        f"http://{ip}/post",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read() or b"{}")


def send_frame(ip, pixels, pic_id):
    # pixels: list of (r, g, b), length 64*64, row-major with the top-left pixel first.
    data = bytearray()
    for r, g, b in pixels:
        data += bytes((r, g, b))
    return post(ip, {
        "Command": "Draw/SendHttpGif",
        "PicNum": 1,
        "PicWidth": 64,
        "PicOffset": 0,
        "PicID": pic_id,
        "PicSpeed": 1000,
        "PicData": base64.b64encode(bytes(data)).decode(),
    })


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    ip = sys.argv[1]

    print(f"[*] GetHttpGifId from {ip} ...")
    print("   ", post(ip, {"Command": "Draw/GetHttpGifId"}))
    post(ip, {"Command": "Channel/SetBrightness", "Brightness": 100})
    post(ip, {"Command": "Draw/ResetHttpGifId"})

    pid = 1
    for name, color in [("red", (255, 0, 0)), ("green", (0, 255, 0)), ("blue", (0, 0, 255))]:
        print(f"[*] Filling {name} (PicID {pid}) ...")
        print("   ", send_frame(ip, [color] * (64 * 64), pid))
        pid += 1
        time.sleep(1)

    print(f"[*] Diagonal gradient (PicID {pid}) ...")
    grad = [((x * 4) % 256, (y * 4) % 256, ((x + y) * 2) % 256)
            for y in range(64) for x in range(64)]
    print("   ", send_frame(ip, grad, pid))
    print("[ok] Saw red, green, blue, then a gradient? The Pixoo path works — test the app next.")


if __name__ == "__main__":
    main()
