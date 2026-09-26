#!/usr/bin/env python3
"""Dev-machine proof, NOT part of any deployment.

Demonstrates the whole video path end to end against a running Counter
server: it starts the renderer, captures video frames off a sheet's FIFO
with ffmpeg, changes the score partway through the capture (by POSTing to
the sheet's tablet endpoint), and shows that the captured frames actually
change. This is the demo that proves the "ffmpeg caches a still image
forever" trap is defeated.

    Counter ──WS──▶ renderer ──▶ bug-NN.fifo ──▶ ffmpeg -f rawvideo ──▶ frame PNGs

Usage (against `wrangler dev` with a club added by the admin CLI):

    python3 renderer/fifo_demo.py --server http://127.0.0.1:8787 \
        --club demo --sheet 1 --token <that sheet's token>

Needs ffmpeg and Chromium, like the renderer itself. The sheet's game is
reset at the start and end of the demo — use a spare sheet.
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = os.path.dirname(os.path.abspath(__file__))
CAPTURE_FRAMES = 18          # at 1 fps
POST_AFTER = 8               # change the score this many seconds into capture


def post(server, token, action, _n=[0]):
    _n[0] += 1
    action = dict(action, id=f"fifo-demo-{time.time():.0f}-{_n[0]}")
    req = urllib.request.Request(
        f"{server}/api/t/{token}",
        data=json.dumps(action).encode(), method="POST",
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())


def main():
    parser = argparse.ArgumentParser(description="FIFO video-path proof")
    parser.add_argument("--server", default="http://127.0.0.1:8787")
    parser.add_argument("--club", default="demo")
    parser.add_argument("--sheet", type=int, default=1)
    parser.add_argument("--token", required=True,
                        help="the sheet's tablet token (admin CLI `list`)")
    args = parser.parse_args()

    work = tempfile.mkdtemp(prefix="counter-fifo-demo-")
    frames_dir = os.path.join(work, "frames")
    os.makedirs(frames_dir)
    procs = []
    try:
        # 1. a known starting score on the sheet
        post(args.server, args.token, {"type": "reset"})
        post(args.server, args.token,
             {"type": "start", "yellow": "Demo", "red": "Proof",
              "first_hammer": "red"})
        post(args.server, args.token,
             {"type": "set_end", "end": 1, "team": "red", "points": 2})

        # 2. the real renderer, FIFOs in the temp dir (not /run)
        renderer_log = open(os.path.join(work, "renderer.log"), "w")
        procs.append(subprocess.Popen(
            [sys.executable, os.path.join(ROOT, "counter_renderer.py"),
             "--server", args.server, "--club", args.club,
             "--sheets", str(args.sheet),
             "--fifo-dir", os.path.join(work, "fifos")],
            stdout=renderer_log, stderr=renderer_log))
        fifo = os.path.join(work, "fifos", f"bug-{args.sheet:02d}.fifo")
        for _ in range(50):
            if os.path.exists(fifo):
                break
            time.sleep(0.2)

        # 3. ffmpeg captures N seconds of video off the FIFO as PNG frames
        print(f"capturing {CAPTURE_FRAMES} frames at 1 fps from {fifo} ...")
        ff = subprocess.Popen(
            ["ffmpeg", "-v", "error",
             "-f", "rawvideo", "-pix_fmt", "rgba", "-video_size", "640x360",
             "-framerate", "1", "-i", fifo,
             "-frames:v", str(CAPTURE_FRAMES),
             os.path.join(frames_dir, "frame-%02d.png")])
        procs.append(ff)

        # 4. partway through the capture, the score changes
        time.sleep(POST_AFTER)
        print(f"t+{POST_AFTER}s: scoring 4 for yellow in end 2")
        post(args.server, args.token,
             {"type": "set_end", "end": 2, "team": "yellow", "points": 4})

        ff.wait(timeout=CAPTURE_FRAMES * 2 + 60)

        # 5. did the captured frames actually change?
        names = sorted(os.listdir(frames_dir))
        hashes = []
        for n in names:
            with open(os.path.join(frames_dir, n), "rb") as f:
                hashes.append(hashlib.sha256(f.read()).hexdigest()[:10])
        distinct = []
        for i, h in enumerate(hashes, 1):
            if not distinct or distinct[-1][1] != h:
                distinct.append((i, h))
        print(f"captured {len(names)} frames; content changes at frames "
              f"{[i for i, _ in distinct]}: {[h for _, h in distinct]}")
        # Expect: (black startup frame ->) first score -> updated score.
        ok = len(names) == CAPTURE_FRAMES and len(distinct) >= 2 \
            and hashes[-1] != hashes[POST_AFTER - 2]
        print("PASS: frames captured off the FIFO changed when the score did"
              if ok else "FAIL: captured frames did not change")
        return 0 if ok else 1
    finally:
        try:
            post(args.server, args.token, {"type": "reset"})
        except OSError:
            pass
        for p in procs:
            if p.poll() is None:
                p.terminate()
        for p in procs:
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
