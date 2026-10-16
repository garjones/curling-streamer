#!/usr/bin/env python3
"""Counter scorebug renderer — turns each sheet's scorebug page into live video.

OPTIONAL. This runs on a club's own encoder box and only exists for clubs
that composite a scorebug into a video stream. A scoring-only club never
installs this; the tablets, viewer pages and TV pages need nothing on site
but a browser. Ported from kcc-scoreboard's kcc_scorebug.py; the only real
change is that the old /api/rev poll loop is now one WebSocket to the club
(no polling, anywhere — see the README).

    one WebSocket ──▶ headless Chromium screenshot (one at a time)
                          └─▶ decoded RGBA frame held in memory
                                  └─▶ one writer thread per sheet (and per
                                      tile: bug, and rail with --rail)
                                          └─▶ bug-07.fifo ──▶ ffmpeg ──▶ stream
                                              rail-07.fifo ─┘

Why a FIFO at all: `ffmpeg -loop 1 -i bug.png` reads the file ONCE and caches
the decoded frame — overwriting the PNG changes nothing, and ffmpeg 6.x has
no reload option for still images (neither the image2 demuxer nor the movie
filter). So instead we feed ffmpeg an endless rawvideo stream through a named
pipe and simply keep repeating the latest frame. ffmpeg consumes it with:

    ffmpeg -f rawvideo -pix_fmt rgba -video_size 640x360 -framerate 1 \
           -i /run/counter/bug-07.fifo ...

Launching Chromium is expensive, so it happens only when a sheet's revision
counter changes — roughly eight times per game — never per frame. Screenshots
are serialised through a single queue; while a sheet waits its turn, its
writer thread keeps repeating the previous frame, so no stream ever stalls.
If the network drops, the writers keep pushing the last known frame: the
stream shows a frozen score rather than breaking.

With --rail the same machinery also renders the sponsor rail: /rail/<club>/<n>
is screenshotted into rail-NN.fifo whenever the club's rail revision changes
(the hello carries club.rail_rev; every admin-page save pushes
{"type":"rail","rev":N} on the same socket). Scores change often and
sponsors rarely, so the bug is always queued ahead of the rail.

Run:  python3 counter_renderer.py --server https://counter.gareth.live --club kelowna [--rail]

Standard library only. Needs Chromium (env COUNTER_CHROMIUM) and ffmpeg on
PATH.
"""

import argparse
import json
import os
import stat
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ws_client import ConnectionClosed, WebSocket  # noqa: E402

WIDTH, HEIGHT = 640, 360
FRAME_BYTES = WIDTH * HEIGHT * 4          # RGBA
SCREENSHOT_TIMEOUT = 60                   # seconds; Chromium can be slow to cold-start


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def default_chromium():
    env = os.environ.get("COUNTER_CHROMIUM")
    if env:
        return env
    if sys.platform == "darwin":
        return "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    return "chromium"


def screenshot_rgba(chromium, url, workdir):
    """Screenshot `url` at exactly 640x360 and return the raw RGBA bytes.

    The flags matter: without --hide-scrollbars you get a scrollbar baked
    into the stream, and without --force-device-scale-factor=1 a HiDPI
    machine hands you a double-size PNG. Chrome sometimes writes the PNG
    within a couple of seconds but never exits (a stuck updater helper), so
    we do not trust Chrome's exit at all: we poll for a PNG that decodes to
    a full frame, then kill the browser.
    """
    png = os.path.join(workdir, "shot.png")
    profile = os.path.join(workdir, "profile")   # keep clear of any real browser profile
    cmd = [
        chromium, "--headless", "--disable-gpu",
        "--no-first-run", "--no-default-browser-check",
        f"--user-data-dir={profile}",
        "--window-size=640,360", "--hide-scrollbars",
        "--force-device-scale-factor=1",
        f"--screenshot={png}", url,
    ]
    # Output goes to a file, not a pipe: Chrome helpers can inherit a pipe
    # and keep it open forever, which would hang us on communicate().
    chromelog = os.path.join(workdir, "chromium.log")
    with open(chromelog, "wb") as logf:
        proc = subprocess.Popen(cmd, stdout=logf, stderr=logf)
    try:
        deadline = time.time() + SCREENSHOT_TIMEOUT
        while time.time() < deadline:
            raw = _decode_png(png)
            if raw is not None:
                return raw
            if proc.poll() is not None:      # exited without a usable PNG
                break
            time.sleep(0.3)
        raw = _decode_png(png)               # one last look after exit
        if raw is not None:
            return raw
        with open(chromelog, "rb") as logf:
            tail = logf.read()[-400:].decode(errors="replace")
        raise RuntimeError(
            f"no usable 640x360 screenshot of {url} "
            f"(chromium exit={proc.poll()}): {tail}")
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.wait()


def _decode_png(png):
    """PNG -> raw RGBA bytes, or None if absent/partial/wrong size."""
    if not os.path.exists(png):
        return None
    try:
        raw = subprocess.run(
            ["ffmpeg", "-v", "error", "-i", png,
             "-f", "rawvideo", "-pix_fmt", "rgba", "-"],
            check=True, capture_output=True, timeout=30).stdout
    except subprocess.SubprocessError:
        return None
    if len(raw) != FRAME_BYTES:
        # Log loudly: a wrong-size frame would corrupt the video stream.
        log(f"ERROR: {png} decoded to {len(raw)} bytes, expected "
            f"{FRAME_BYTES} (640x360x4) — check Chromium flags/version")
        return None
    return raw


# The two tiles a sheet can have. Sorted order matters: the shooter always
# takes the lowest pending job, so "bug" (scores) goes before "rail".
BUG, RAIL = "bug", "rail"


class Renderer:
    def __init__(self, server, club, fifo_dir, sheets, chromium, fps, rail=False):
        self.server = server.rstrip("/")
        self.club = club
        self.fifo_dir = fifo_dir
        self.sheets = sheets                 # None until the hello arrives
        self.chromium = chromium
        self.frame_interval = 1.0 / fps
        self.kinds = (BUG, RAIL) if rail else (BUG,)
        self.frames = {}                     # (kind, sheet) -> latest RGBA frame
        self.last_rev = {}                   # sheet -> last bug rev seen
        self.rail_rev = None                 # last rail rev seen (club-wide)
        self.pending = set()                 # (kind, sheet) waiting for a screenshot
        self.cond = threading.Condition()
        self.started_writers = set()         # (kind, sheet)
        self.known_sheets = set()

    def ws_url(self):
        scheme = "wss" if self.server.startswith("https") else "ws"
        host = self.server.split("://", 1)[1]
        return f"{scheme}://{host}/api/ws/c/{self.club}"

    def fifo_path(self, kind, sheet):
        return os.path.join(self.fifo_dir, f"{kind}-{sheet:02d}.fifo")

    def ensure_sheet(self, sheet):
        """Create the FIFO(s) and writer thread(s) for a sheet, once."""
        self.known_sheets.add(sheet)
        for kind in self.kinds:
            key = (kind, sheet)
            if key in self.started_writers:
                continue
            self.started_writers.add(key)
            # Until the first screenshot lands, feed black so streams can start.
            self.frames.setdefault(key, bytes(FRAME_BYTES))
            path = self.fifo_path(kind, sheet)
            if os.path.exists(path):
                if not stat.S_ISFIFO(os.stat(path).st_mode):
                    raise SystemExit(f"{path} exists and is not a FIFO")
            else:
                os.mkfifo(path)
            threading.Thread(target=self.writer, args=(key,), daemon=True).start()

    # -- one writer thread per tile: repeat the latest frame at ~1 fps -----
    def writer(self, key):
        kind, sheet = key
        path = self.fifo_path(kind, sheet)
        while True:
            try:
                # Opening a FIFO for writing blocks until a reader (ffmpeg)
                # attaches. That is correct: this thread parks until the
                # sheet's stream starts.
                with open(path, "wb", buffering=0) as fifo:
                    log(f"{kind} {sheet}: ffmpeg attached to {path}")
                    # Pace on an absolute schedule, not "write then sleep":
                    # the frames carry synthetic timestamps (-framerate 1,
                    # one second per frame) and ffmpeg's overlay cannot
                    # release a camera frame until the NEXT tile frame has
                    # arrived, so the tile's cadence IS the stream's clock.
                    # "write then sleep(1.0)" runs a few ms per frame slow,
                    # the stream falls behind the wall clock by that much
                    # every second — 0.1–0.2 %, ~7 s/hour — and YouTube
                    # reports "video output low" on a box that is otherwise
                    # perfect (15 Oct 2026, six sheets). A blocked write
                    # (ffmpeg not reading yet) resets the schedule instead
                    # of bursting to catch up.
                    due = time.monotonic()
                    while True:
                        fifo.write(self.frames[key])
                        due += self.frame_interval
                        wait = due - time.monotonic()
                        if wait > 0:
                            time.sleep(wait)
                        else:
                            due = time.monotonic()
            except BrokenPipeError:
                # ffmpeg restarted; reopen and the stream self-recovers
                log(f"{kind} {sheet}: reader went away, waiting for it to return")
            except OSError as e:
                log(f"{kind} {sheet}: FIFO error {e}; retrying in 5s")
                time.sleep(5)

    # -- one screenshot worker: strictly one Chromium at a time ------------
    def shooter(self):
        while True:
            with self.cond:
                while not self.pending:
                    self.cond.wait()
                key = min(self.pending)      # ("bug", n) sorts before ("rail", n)
                self.pending.discard(key)
            kind, sheet = key
            url = f"{self.server}/{kind}/{self.club}/{sheet}"
            t0 = time.time()
            try:
                with tempfile.TemporaryDirectory(prefix="counter-shot-") as workdir:
                    self.frames[key] = screenshot_rgba(self.chromium, url, workdir)
                log(f"{kind} {sheet}: new frame in {time.time() - t0:.1f}s")
            except Exception as e:
                # Do not swallow this: a sheet that stops updating must say
                # so. The stream keeps showing the previous frame.
                detail = ""
                if isinstance(e, subprocess.CalledProcessError):
                    detail = " — " + e.stderr.decode(errors="replace").strip()[-300:]
                log(f"ERROR {kind} {sheet}: screenshot failed: {e}{detail}; "
                    "stream keeps showing the previous frame")
                time.sleep(2)

    def mark_pending(self, sheet, rev):
        with self.cond:
            if rev is None or rev != self.last_rev.get(sheet):
                if rev is not None:
                    self.last_rev[sheet] = rev
                self.pending.add((BUG, sheet))
                self.cond.notify_all()

    def mark_rail_pending(self, rev):
        """A new rail revision: every sheet's rail tile is re-shot (a rail
        change may affect any sheet, and six screenshots is cheap)."""
        if RAIL not in self.kinds:
            return
        with self.cond:
            if rev is not None and rev == self.rail_rev:
                return
            self.rail_rev = rev
            for n in sorted(self.known_sheets):
                self.pending.add((RAIL, n))
            if self.known_sheets:
                log(f"rail rev {rev}: re-rendering {len(self.known_sheets)} sheet(s)")
            self.cond.notify_all()

    # -- the one WebSocket: reconnect forever, never poll -------------------
    def run(self):
        os.makedirs(self.fifo_dir, exist_ok=True)
        if self.sheets:
            for n in self.sheets:
                self.ensure_sheet(n)
        threading.Thread(target=self.shooter, daemon=True).start()
        log(f"rendering club '{self.club}' from {self.server} into {self.fifo_dir}")

        backoff = 1
        while True:
            try:
                ws = WebSocket(self.ws_url())
                log(f"connected to {self.ws_url()}")
                backoff = 1
                last_traffic = time.time()
                while True:
                    msg = ws.recv(timeout=20)
                    if msg is None:
                        # Quiet link: keepalive, and give up if it stays dead
                        # (the writers keep repeating the last frame).
                        ws.send_text("ping")
                        if time.time() - last_traffic > 90:
                            raise ConnectionClosed("no traffic for 90s")
                        continue
                    last_traffic = time.time()
                    if msg == "pong":
                        continue
                    try:
                        m = json.loads(msg)
                    except ValueError:
                        continue
                    if m.get("type") == "hello":
                        states = m.get("states", {})
                        wanted = self.sheets or sorted(int(k) for k in states)
                        for n in wanted:
                            self.ensure_sheet(n)
                            s = states.get(str(n))
                            self.mark_pending(n, s.get("rev") if s else None)
                        self.mark_rail_pending((m.get("club") or {}).get("rail_rev"))
                    elif m.get("type") == "rail":
                        self.mark_rail_pending(m.get("rev"))
                    elif m.get("type") == "state":
                        s = m["state"]
                        n = int(s["sheet"])
                        if self.sheets and n not in self.sheets:
                            continue
                        self.ensure_sheet(n)
                        self.mark_pending(n, s.get("rev"))
            except (ConnectionClosed, OSError, ValueError) as e:
                log(f"WARNING: WebSocket down ({e}); reconnecting in {backoff}s "
                    "— streams keep showing the last frame")
                time.sleep(backoff)
                backoff = min(backoff * 2, 30)


def parse_sheets(spec):
    if not spec:
        return None    # follow whatever the club's hello lists
    if "-" in spec:
        lo, hi = spec.split("-", 1)
        return list(range(int(lo), int(hi) + 1))
    return [int(s) for s in spec.split(",")]


def main(argv=None):
    parser = argparse.ArgumentParser(description="Counter scorebug renderer")
    parser.add_argument("--server", default="https://counter.gareth.live")
    parser.add_argument("--club", required=True, help="club slug, e.g. kelowna")
    parser.add_argument("--fifo-dir", default="/run/counter",
                        help="where the bug-NN.fifo pipes live")
    parser.add_argument("--sheets", default="",
                        help="e.g. 1-12 or 3,7,9 (default: every sheet the club has)")
    parser.add_argument("--chromium", default=default_chromium(),
                        help="Chromium binary (default: $COUNTER_CHROMIUM)")
    parser.add_argument("--fps", type=float, default=1.0)
    parser.add_argument("--rail", action="store_true",
                        help="also render the sponsor rail into rail-NN.fifo")
    args = parser.parse_args(argv)
    try:
        Renderer(args.server, args.club, args.fifo_dir,
                 parse_sheets(args.sheets), args.chromium, args.fps,
                 rail=args.rail).run()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
