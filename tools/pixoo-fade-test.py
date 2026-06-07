#!/usr/bin/env python3
"""Test a 'fade through black' transition on the Pixoo using brightness control.

Usage: python3 tools/pixoo-fade-test.py <ip>

A cross-dissolve isn't possible (no fast frame path), but Channel/SetBrightness is a single
quick command, so we can fade the panel DOWN to black, swap the static image underneath, and
fade it back UP. Shows image A, fades to black, swaps to image B, fades up. Watch whether the
brightness ramp looks smooth and how long each fade takes."""

import base64
import json
import sys
import time
import http.client


def post(conn, body):
    conn.request("POST", "/post", json.dumps(body))
    return json.loads(conn.getresponse().read() or b"{}")


def show(conn, rgb, pic_id):
    data = bytearray()
    for _ in range(64 * 64):
        data += bytes(rgb)
    post(conn, {
        "Command": "Draw/SendHttpGif", "PicNum": 1, "PicWidth": 64, "PicOffset": 0,
        "PicID": pic_id, "PicSpeed": 1000, "PicData": base64.b64encode(bytes(data)).decode(),
    })


def ramp(conn, levels):
    t0 = time.time()
    for v in levels:
        post(conn, {"Command": "Channel/SetBrightness", "Brightness": v})
    return (time.time() - t0) / max(1, len(levels))


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    ip = sys.argv[1]
    conn = http.client.HTTPConnection(ip, 80, timeout=10)
    post(conn, {"Command": "Draw/ResetHttpGifId"})

    down = list(range(100, -1, -10))   # 100,90,...,0
    up = list(range(0, 101, 10))

    post(conn, {"Command": "Channel/SetBrightness", "Brightness": 100})
    print("[*] Showing A (orange) for 1.5s…")
    show(conn, (255, 90, 0), 1)
    time.sleep(1.5)

    print("[*] Fading A -> black…")
    per = ramp(conn, down)
    print(f"    {len(down)} brightness steps, {per*1000:.0f} ms/step")

    print("[*] Swapping to B (cyan) while dark, fading up…")
    show(conn, (0, 200, 255), 2)
    ramp(conn, up)
    time.sleep(1.0)

    print("[*] Again, faster (5 steps each way)…")
    ramp(conn, [80, 60, 40, 20, 0])
    show(conn, (255, 90, 0), 3)
    ramp(conn, [20, 40, 60, 80, 100])

    conn.close()
    print("[ok] Did the dips look like smooth fades, or steppy? And fast enough?")


if __name__ == "__main__":
    main()
