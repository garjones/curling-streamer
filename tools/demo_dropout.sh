#!/bin/sh
# demo_dropout.sh — prove that a lost input RESTARTS the compositor rather
# than freezing the stream.
#
#   tools/demo_dropout.sh [--keep]          (DEMO_ENCODER=vaapi on the box)
#
# Same topology as demo_stack.sh (MediaMTX, two synthetic cameras, a
# scorebug FIFO, one x264 compositor), then, mid-stream, it takes away
# first the home camera and then the scorebug writer. Each time the
# compositor must EXIT within a few seconds: in production systemd then
# restarts streamer@N, which reconnects to MediaMTX and reopens the FIFO.
#
# Why this exists: before 6 Oct 2026 the overlay filters kept their default
# eof_action=repeat, so a camera that dropped (or a renderer restart) left
# that tile frozen on its last frame for the rest of the broadcast with the
# unit still "active" and the status page green. Exit 0 = both cases
# behave; a FAIL here means a frozen tile at the club.

set -eu
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

HERE="$(cd "$(dirname "$0")/.." && pwd)"
MTX="${MEDIAMTX:-/usr/local/bin/mediamtx}"
[ -x "${MTX}" ] || MTX="${HERE}/vendor/mediamtx"
[ -x "${MTX}" ] || { echo "dropout: mediamtx not found (set MEDIAMTX=...)"; exit 1; }
PORT="${DEMO_RTSP_PORT:-8554}"
# DEMO_ENCODER=vaapi runs the GPU graph (overlay_vaapi eof_action) on the
# encoder box itself — the production path, which is what must exit.
ENCODER="${DEMO_ENCODER:-x264}"
RTSP="rtsp://127.0.0.1:${PORT}"
GRACE=20     # seconds the compositor is allowed to take to notice and exit
WORK="$(mktemp -d /tmp/streamer-dropout.XXXXXX)"
cleanup() {
    kill $(cat "${WORK}"/*.pid 2>/dev/null) 2>/dev/null || true
    wait 2>/dev/null || true
    [ "${KEEP}" = 1 ] && echo "dropout: artefacts kept in ${WORK}" || rm -rf "${WORK}"
}
trap cleanup EXIT

echo "dropout: mediamtx up on :${PORT}"
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
kill -0 "$(cat "${WORK}/mtx.pid")" 2>/dev/null || {
    echo "dropout: FAIL — our mediamtx did not start (is something else on :${PORT}?"
    echo "         set DEMO_RTSP_PORT to a free port); its log:"; cat "${WORK}/mtx.log"
    exit 1
}

publish() {   # publish <lavfi source> <path> ; prints the pid
    ffmpeg -hide_banner -loglevel error -re \
        -f lavfi -i "$1=size=854x480:rate=30" \
        -c:v libx264 -preset ultrafast -tune zerolatency -g 60 -pix_fmt yuv420p \
        -f rtsp -rtsp_transport tcp "${RTSP}/$2" >"${WORK}/pub-$2.log" 2>&1 &
    echo $!
}
echo "dropout: two synthetic cameras publishing"
HOME_PID=$(publish testsrc2 cam-1-home); echo "${HOME_PID}" >> "${WORK}/pubs.pid"
AWAY_PID=$(publish smptebars cam-1-away); echo "${AWAY_PID}" >> "${WORK}/pubs.pid"
sleep 2

# A scorebug writer that behaves like the renderer: repeats a frame at
# 1 fps and reopens the FIFO when its reader goes away.
mkfifo "${WORK}/bug-01.fifo"
start_writer() {
    python3 - "${WORK}/bug-01.fifo" <<'EOF' >"${WORK}/fifo.log" 2>&1 &
import sys, time
frame = bytes((208, 59, 59, 255)) * (640 * 360)
while True:
    try:
        with open(sys.argv[1], "wb", buffering=0) as f:
            while True:
                f.write(frame); time.sleep(1)
    except (BrokenPipeError, OSError):
        time.sleep(0.5)
EOF
    echo $! > "${WORK}/fifopy.pid"
}
start_writer

ffmpeg -hide_banner -loglevel error -f lavfi \
    -i "color=c=0x3987e5:size=1920x360" -frames:v 1 -y "${WORK}/rail.png"
[ -s "${WORK}/rail.png" ] || { echo "dropout: FAIL — could not make rail.png"; exit 1; }

start_compositor() {   # prints the pid; runs up to 60 s unless an input ends
    env SHEET=1 FPS=30 CANVAS_W=1920 CANVAS_H=1080 BITRATE_K=4500 ENCODER="${ENCODER}" \
        HOME_URL="${RTSP}/cam-1-home" HERO_X=0 HERO_Y=0 HERO_W=1280 HERO_H=720 \
        AWAY_URL="${RTSP}/cam-1-away" AWAY_X=1280 AWAY_Y=0 AWAY_W=640 AWAY_H=360 \
        FIFO="${WORK}/bug-01.fifo" BUG_X=1280 BUG_Y=360 BUG_W=640 BUG_H=360 \
        SPONSOR="${WORK}/rail.png" RAIL_X=0 RAIL_Y=720 RAIL_W=1920 RAIL_H=360 \
        DURATION=60 OUTPUT_OVERRIDE=null \
        "${HERE}/bin/streamer-compose" >"${WORK}/compose-$1.log" 2>&1 &
    echo $!
}

# run_case <name> <what to kill>: the compositor must exit within GRACE s
# of losing that input. The log must show it noticed, not that it died of
# something else.
run_case() {
    name=$1; victim=$2
    cpid=$(start_compositor "${name}")
    echo "${cpid}" > "${WORK}/compose.pid"
    # Wait for the first progress line: ffmpeg probes two RTSP inputs
    # before it encodes anything, which can take several seconds.
    t0=$(date +%s)
    until grep -q 'speed=' "${WORK}/compose-${name}.log"; do
        if ! kill -0 "${cpid}" 2>/dev/null || [ $(( $(date +%s) - t0 )) -ge 30 ]; then
            echo "dropout: FAIL — compositor never got going; log:"
            kill "${cpid}" 2>/dev/null || true
            cat "${WORK}/compose-${name}.log"; exit 1
        fi
        sleep 1
    done
    sleep 3
    echo "dropout: streaming; now the ${name} goes away"
    kill "${victim}"; wait "${victim}" 2>/dev/null || true
    t0=$(date +%s); gone=0
    while [ $(( $(date +%s) - t0 )) -lt "${GRACE}" ]; do
        kill -0 "${cpid}" 2>/dev/null || { gone=1; break; }
        sleep 1
    done
    took=$(( $(date +%s) - t0 ))
    if [ "${gone}" = 1 ]; then
        echo "dropout: PASS — compositor exited ${took} s after losing the ${name}"
    else
        echo "dropout: FAIL — compositor still running ${took} s after losing the ${name}"
        echo "         (the tile would be frozen for the rest of the broadcast); log:"
        kill "${cpid}" 2>/dev/null || true
        cat "${WORK}/compose-${name}.log"; exit 1
    fi
}

run_case "home camera" "${HOME_PID}"

# Reset for the second case: camera back, and the writer is still there
# (it reopened the FIFO when the first compositor went away).
HOME_PID=$(publish testsrc2 cam-1-home); echo "${HOME_PID}" >> "${WORK}/pubs.pid"
sleep 2
run_case "scorebug writer" "$(cat "${WORK}/fifopy.pid")"

echo "dropout: PASS — a lost camera or renderer ends the compositor; systemd's Restart=always does the rest."
