#!/usr/bin/env python3
"""Prove the Pixoo plays a loaded multi-frame animation SMOOTHLY on its own.

Usage: python3 tools/pixoo-anim-test.py <ip>

Loads ONE animation (a smooth horizontal gradient scroll) as N frames via Draw/SendHttpGif
(PicNum=N, PicOffset=0..N-1, same PicID, PicSpeed ms/frame). Loading takes a few seconds
over HTTP, but once loaded the device should loop it buttery-smooth — far smoother than the
~3-5 fps we can stream. If this looks smooth, the app should drive the device this way."""

import base64
import json
import sys
import time
import http.client

N = 30           # frames in the animation (keep well under the ~40-frame firmware limit)
SPEED_MS = 40    # playback speed: 40 ms/frame ~= 25 fps, set by the device, not by HTTP


def frame(shift):
    data = bytearray()
    for y in range(64):
        for x in range(64):
            v = (x + shift) % 64
            data += bytes((v * 4, 255 - v * 4, (y * 4) % 256))
    return base64.b64encode(bytes(data)).decode()


def post(conn, body):
    conn.request("POST", "/post", json.dumps(body))
    return json.loads(conn.getresponse().read() or b"{}")


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    ip = sys.argv[1]
    conn = http.client.HTTPConnection(ip, 80, timeout=10)

    post(conn, {"Command": "Channel/SetBrightness", "Brightness": 100})
    post(conn, {"Command": "Draw/ResetHttpGifId"})

    pic_id = 1
    print(f"[*] Loading a {N}-frame animation ({SPEED_MS} ms/frame)…")
    t0 = time.time()
    for i in range(N):
        r = post(conn, {
            "Command": "Draw/SendHttpGif",
            "PicNum": N,            # total frames in this animation
            "PicWidth": 64,
            "PicOffset": i,         # this frame's index
            "PicID": pic_id,        # same id for every frame of the animation
            "PicSpeed": SPEED_MS,
            "PicData": frame(i * 2),
        })
        if r.get("error_code", 0) != 0:
            print(f"    frame {i}: error {r}")
    conn.close()
    print(f"[ok] Loaded in {time.time()-t0:.1f}s. The panel should now loop a SMOOTH scroll")
    print(f"     (~{1000//SPEED_MS} fps) with no further network traffic. Watch it for a few seconds.")


if __name__ == "__main__":
    main()
