#!/usr/bin/env python3
"""Test the Pixoo's NATIVE scrolling text (Draw/SendHttpText) over a static background.

Usage: python3 tools/pixoo-text-test.py <ip>

Sends one static background frame, then a scrolling-text overlay the firmware animates
itself — no frame loading. If the text scrolls smoothly, this is how the app should render
the now-playing ticker (instead of streaming frames at ~4 fps)."""

import base64
import json
import sys
import http.client


def post(conn, body):
    conn.request("POST", "/post", json.dumps(body))
    return json.loads(conn.getresponse().read() or b"{}")


def background(conn):
    # A dim diagonal so we can see the text sits on top of a real frame.
    data = bytearray()
    for y in range(64):
        for x in range(64):
            data += bytes((x, 0, y))
    post(conn, {
        "Command": "Draw/SendHttpGif", "PicNum": 1, "PicWidth": 64,
        "PicOffset": 0, "PicID": 1, "PicSpeed": 1000,
        "PicData": base64.b64encode(bytes(data)).decode(),
    })


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    ip = sys.argv[1]
    conn = http.client.HTTPConnection(ip, 80, timeout=10)

    post(conn, {"Command": "Channel/SetBrightness", "Brightness": 100})
    post(conn, {"Command": "Draw/ResetHttpGifId"})
    background(conn)

    print("[*] Sending scrolling text overlay…")
    for speed in (50,):  # ms; lower = faster
        r = post(conn, {
            "Command": "Draw/SendHttpText",
            "TextId": 1,
            "x": 0,
            "y": 46,
            "dir": 0,                 # 0 = scroll left
            "font": 2,
            "TextWidth": 64,
            "speed": speed,
            "TextString": "DEAD KENNEDYS  -  CALIFORNIA UBER ALLES   * * *   ",
            "color": "#FFE400",
        })
        print(f"    speed={speed}: {r}")
    conn.close()
    print("[ok] The text should be scrolling smoothly across the bottom, device-driven.")


if __name__ == "__main__":
    main()
