#!/bin/sh
# demo_stack.sh — prove the plumbing end to end, no cameras needed.
#
#   tools/demo_stack.sh [--keep]
#
# Production topology in miniature: a local MediaMTX receives two
# synthetic camera publishers (854x480 H.264, like an old camera's
# default stream); one compositor pulls both over RTSP, overlays a
# scorebug and sponsor rail each fed through a named FIFO, encodes with
# x264 (no GPU needed) and writes 12 seconds of FLV. The FIFO writer
# changes the scorebug colour at t=6 — mid-stream, through the pipe —
# and the script PROVES the change reached the output by comparing the
# scorebug region of an early frame and a late frame. That is the FIFO
# claim from counter/README.md, demonstrated on this machine.
#
# Exit 0 = the stack works here. Run it whenever you doubt the plumbing.

set -eu
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

HERE="$(cd "$(dirname "$0")/.." && pwd)"
MTX="${MEDIAMTX:-/usr/local/bin/mediamtx}"
[ -x "${MTX}" ] || MTX="${HERE}/vendor/mediamtx"
[ -x "${MTX}" ] || { echo "demo: mediamtx not found (set MEDIAMTX=...)"; exit 1; }
PORT="${DEMO_RTSP_PORT:-8554}"      # a free port, if 8554 is already taken
RTSP="rtsp://127.0.0.1:${PORT}"
WORK="$(mktemp -d /tmp/streamer-demo.XXXXXX)"
cleanup() {
    kill $(cat "${WORK}"/*.pid 2>/dev/null) 2>/dev/null || true
    wait 2>/dev/null || true
    [ "${KEEP}" = 1 ] && echo "demo: artefacts kept in ${WORK}" || rm -rf "${WORK}"
}
trap cleanup EXIT

echo "demo: mediamtx up on :${PORT}"
cat > "${WORK}/mtx.yml" <<EOF
logLevel: error
api: false
rtmp: false
hls: false
webrtc: false
srt: false
moq: false
rtspAddress: :${PORT}
rtspTransports: [tcp]
paths:
  all_others:
EOF
"${MTX}" "${WORK}/mtx.yml" >"${WORK}/mtx.log" 2>&1 &
echo $! > "${WORK}/mtx.pid"
sleep 1
# Make sure it is OUR mediamtx the cameras publish to. If the port is
# taken, ours exits and the rest of the demo silently tests whatever else
# is listening (a Homebrew `mediamtx` service, say) — a PASS that proves
# nothing about this config. Seen on 6 Oct 2026.
kill -0 "$(cat "${WORK}/mtx.pid")" 2>/dev/null || {
    echo "demo: FAIL — our mediamtx did not start (is something else on :${PORT}?"
    echo "      set DEMO_RTSP_PORT to a free port); its log:"; cat "${WORK}/mtx.log"
    exit 1
}

echo "demo: two synthetic cameras publishing"
ffmpeg -hide_banner -loglevel error -re \
    -f lavfi -i "testsrc2=size=854x480:rate=30" \
    -c:v libx264 -preset ultrafast -tune zerolatency -g 60 -pix_fmt yuv420p \
    -f rtsp -rtsp_transport tcp "${RTSP}/cam-1-home" \
    >"${WORK}/pub-home.log" 2>&1 &
echo $! >> "${WORK}/pubs.pid"
ffmpeg -hide_banner -loglevel error -re \
    -f lavfi -i "smptebars=size=854x480:rate=30" \
    -c:v libx264 -preset ultrafast -tune zerolatency -g 60 -pix_fmt yuv420p \
    -f rtsp -rtsp_transport tcp "${RTSP}/cam-1-away" \
    >"${WORK}/pub-away.log" 2>&1 &
echo $! >> "${WORK}/pubs.pid"
sleep 2

echo "demo: scorebug FIFO writer (colour flips at t=6)"
mkfifo "${WORK}/bug-01.fifo"
python3 - "${WORK}/bug-01.fifo" <<'EOF' >"${WORK}/fifo.log" 2>&1 &
import sys, time
path = sys.argv[1]
def frame(rgba):
    return bytes(rgba) * (640 * 360)
early = frame((208, 59, 59, 255))     # rock red
late = frame((237, 161, 0, 255))      # rock yellow
# open() blocks until ffmpeg attaches, so the clock starts with the
# compositor — the flip lands mid-recording regardless of startup time.
with open(path, "wb", buffering=0) as f:
    start = time.time()
    while True:
        f.write(early if time.time() - start < 5 else late)
        time.sleep(1)
EOF
echo $! > "${WORK}/fifopy.pid"

echo "demo: sponsor-rail FIFO writer (colour flips at t=5, like the bug)"
mkfifo "${WORK}/rail-01.fifo"
python3 - "${WORK}/rail-01.fifo" <<'RAILEOF' >"${WORK}/railfifo.log" 2>&1 &
import sys, time
path = sys.argv[1]
def frame(rgba):
    return bytes(rgba) * (640 * 360)
early = frame((57, 135, 229, 255))    # counter accent blue
late = frame((40, 170, 90, 255))      # green
with open(path, "wb", buffering=0) as f:
    start = time.time()
    while True:
        f.write(early if time.time() - start < 5 else late)
        time.sleep(1)
RAILEOF
echo $! >> "${WORK}/fifopy.pid"

echo "demo: compositor running (12 s, x264)"
env SHEET=1 FPS=30 CANVAS_W=1920 CANVAS_H=1080 BITRATE_K=4500 ENCODER=x264 \
    HOME_URL="${RTSP}/cam-1-home" \
    HERO_X=0 HERO_Y=0 HERO_W=1280 HERO_H=720 \
    AWAY_URL="${RTSP}/cam-1-away" \
    AWAY_X=1280 AWAY_Y=0 AWAY_W=640 AWAY_H=360 \
    FIFO="${WORK}/bug-01.fifo" BUG_X=1280 BUG_Y=360 BUG_W=640 BUG_H=360 \
    RAIL_FIFO="${WORK}/rail-01.fifo" RAIL_X=0 RAIL_Y=720 RAIL_W=1920 RAIL_H=360 \
    DURATION=12 OUTPUT_OVERRIDE="${WORK}/demo.flv" \
    "${HERE}/bin/streamer-compose" >"${WORK}/compose.log" 2>&1 || {
        echo "demo: FAIL — compositor died; log:"; cat "${WORK}/compose.log"
        exit 1
    }

frames=$(ffprobe -v error -count_packets -select_streams v \
    -show_entries stream=nb_read_packets -of csv=p=0 "${WORK}/demo.flv")
echo "demo: output has ${frames} video packets"
[ "${frames}" -gt 250 ] || { echo "demo: FAIL — too few frames"; exit 1; }

# Prove the FIFO delivered a mid-stream change: sample the scorebug tile
# in an early and a late frame and require different dominant colours.
ffmpeg -hide_banner -loglevel error -ss 1 -i "${WORK}/demo.flv" \
    -frames:v 1 -y "${WORK}/early.png"
ffmpeg -hide_banner -loglevel error -ss 10 -i "${WORK}/demo.flv" \
    -frames:v 1 -y "${WORK}/late.png"
python3 - "${WORK}/early.png" "${WORK}/late.png" <<'EOF'
import subprocess, sys
def bug_pixel(png):
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", png, "-f", "rawvideo",
         "-pix_fmt", "rgb24", "-"], check=True, capture_output=True).stdout
    # centre of the scorebug tile: (1280+320, 360+180) on 1920-wide RGB
    off = ((360 + 180) * 1920 + (1280 + 320)) * 3
    return raw[off:off + 3]
def rail_pixel(png):
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", png, "-f", "rawvideo",
         "-pix_fmt", "rgb24", "-"], check=True, capture_output=True).stdout
    # centre of the rail (0..1920 x 720..1080): (960, 900)
    off = (900 * 1920 + 960) * 3
    return raw[off:off + 3]
e, l = bug_pixel(sys.argv[1]), bug_pixel(sys.argv[2])
print(f"demo: scorebug centre pixel early={tuple(e)} late={tuple(l)}")
assert e != l, "scorebug did NOT change — FIFO plumbing is broken"
assert e[0] > 150 and l[1] > 100, "unexpected colours in scorebug tile"
re_, rl = rail_pixel(sys.argv[1]), rail_pixel(sys.argv[2])
print(f"demo: rail centre pixel early={tuple(re_)} late={tuple(rl)}")
assert re_ != rl, "sponsor rail did NOT change — rail FIFO plumbing is broken"
assert re_[2] > 150 and rl[1] > 120, "unexpected colours in rail tile"
print("demo: PASS — mid-stream scorebug AND rail changes reached the output")
EOF
echo "demo: PASS — RTSP in, composite out, FIFO live. Stack works here."
