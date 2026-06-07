#!/usr/bin/env python3
"""Measure how many full 64x64 frames/sec a Pixoo 64 actually accepts over HTTP.

Usage: python3 tools/pixoo-bench.py <ip> [frames]

Tests two modes so we know whether the device honors HTTP keep-alive:
  - keep-alive: one TCP connection reused for every frame (best case)
  - per-frame : a fresh TCP connection per frame (what we get if it sends Connection: close)
Resets the GIF id every 30 frames, like the app, so the firmware buffer never overflows."""

import base64
import json
import sys
import time
import http.client


def make_frame(shift):
    data = bytearray()
    for y in range(64):
        for x in range(64):
            data += bytes(((x * 4 + shift) % 256, (y * 4 + shift) % 256, ((x + y) * 2 + shift) % 256))
    return base64.b64encode(bytes(data)).decode()


def gif_body(pic_id, picdata):
    return json.dumps({
        "Command": "Draw/SendHttpGif", "PicNum": 1, "PicWidth": 64,
        "PicOffset": 0, "PicID": pic_id, "PicSpeed": 1000, "PicData": picdata,
    })


def reset(conn):
    conn.request("POST", "/post", json.dumps({"Command": "Draw/ResetHttpGifId"}))
    conn.getresponse().read()


def bench(ip, n, keepalive):
    frames = [make_frame(i * 6) for i in range(n)]
    conn = http.client.HTTPConnection(ip, 80, timeout=10)
    reset(conn)
    pid = 0
    errors = 0
    t0 = time.time()
    for i, f in enumerate(frames):
        if not keepalive:
            conn.close()
            conn = http.client.HTTPConnection(ip, 80, timeout=10)
        pid += 1
        if pid >= 30:
            reset(conn)
            pid = 1
        conn.request("POST", "/post", gif_body(pid, f))
        resp = conn.getresponse()
        payload = resp.read()
        try:
            if json.loads(payload or b"{}").get("error_code", 0) != 0:
                errors += 1
        except Exception:
            pass
    dt = time.time() - t0
    conn.close()
    return n / dt, dt, errors


def bench_concurrent(ip, n, threads):
    import threading
    frames = [make_frame(i * 6) for i in range(n)]
    # Single reset up front; keep n under ~30 so the buffer can't overflow without resets.
    c0 = http.client.HTTPConnection(ip, 80, timeout=10)
    reset(c0)
    c0.close()

    work = list(range(n))
    lock = threading.Lock()
    idx = [0]
    errors = [0]

    def worker():
        conn = http.client.HTTPConnection(ip, 80, timeout=10)
        while True:
            with lock:
                i = idx[0]
                idx[0] += 1
            if i >= n:
                break
            conn.request("POST", "/post", gif_body((i % 28) + 1, frames[i]))
            payload = conn.getresponse().read()
            try:
                if json.loads(payload or b"{}").get("error_code", 0) != 0:
                    with lock:
                        errors[0] += 1
            except Exception:
                pass
        conn.close()

    t0 = time.time()
    ts = [threading.Thread(target=worker) for _ in range(threads)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    dt = time.time() - t0
    return n / dt, dt, errors[0]


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    ip = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 60

    for label, keepalive in [("keep-alive", True), ("per-frame ", False)]:
        fps, dt, errors = bench(ip, n, keepalive)
        print(f"[{label}]    {n} frames in {dt:5.2f}s  ->  {fps:5.1f} fps   "
              f"({1000*dt/n:4.0f} ms/frame){'  errors='+str(errors) if errors else ''}")

    print("--- concurrency (can the device overlap receive + render?) ---")
    for threads in (2, 3, 4):
        fps, dt, errors = bench_concurrent(ip, 28, threads)
        print(f"[{threads} threads]  28 frames in {dt:5.2f}s  ->  {fps:5.1f} fps   "
              f"({1000*dt/28:4.0f} ms/frame){'  errors='+str(errors) if errors else ''}")


if __name__ == "__main__":
    main()
