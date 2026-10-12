#!/bin/sh
# bench.sh — the bench gate: measure the REAL per-sheet filter graph.
#
#   tools/bench.sh [--sheets 6] [--encoder vaapi|qsv|x264] [--duration 60]
#                  [--source-size 854x480] [--canvas 1920x1080] [--real]
#
# --canvas sets the output size (hero-away-bug-rail layout, same tile
# maths as streamer-generate). The GPU's video-processing engine cost
# scales with canvas pixels: 1280x720 is 2.25x cheaper than 1080p, and
# for 854x480 cameras the hero tile becomes native size instead of a
# 1.5x upscale.
#
# The A380's published margin (478 fps at 1080p H.264, 2.66x for six
# channels) is an ENCODE-ONLY number. This runs N complete channels —
# 2x RTSP decode + scale + overlay + scorebug FIFO + encode — and reports
# each channel's ffmpeg speed. Every channel must hold speed >= 1.00x
# with headroom (aim >= 1.3x); anything less means fewer sheets per box.
#
# Default mode is fully synthetic: a local MediaMTX receives 2N test-card
# publishers and the N compositors pull from it, exactly the production
# topology. The publishers cost CPU, so on the real encoder box prefer
#     --real     which uses the cameras already configured by
# streamer-generate (pulls via the local MediaMTX, harmless to the club:
# each camera still sees one client).
#
# Results belong in the deployment notes: date, box, encoder, N, speeds.

set -eu

SHEETS=6
ENCODER="${ENCODER:-vaapi}"
DURATION=60
SRC=854x480
CANVAS=1920x1080
REAL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --sheets)   SHEETS=$2; shift 2;;
        --encoder)  ENCODER=$2; shift 2;;
        --duration) DURATION=$2; shift 2;;
        --source-size) SRC=$2; shift 2;;
        --canvas)   CANVAS=$2; shift 2;;
        --real)     REAL=1; shift;;
        *) sed -n '2,20p' "$0"; exit 1;;
    esac
done

HERE="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="${HERE}/bin/streamer-compose"
[ -x /usr/local/bin/streamer-compose ] && COMPOSE=/usr/local/bin/streamer-compose
MTX="${MEDIAMTX:-/usr/local/bin/mediamtx}"
PORT="${DEMO_RTSP_PORT:-8554}"      # synthetic mode only; --real uses the box's own
WORK="$(mktemp -d /tmp/streamer-bench.XXXXXX)"
trap 'kill $(cat "${WORK}"/*.pid 2>/dev/null) 2>/dev/null; wait 2>/dev/null; rm -rf "${WORK}"' EXIT

echo "bench: ${SHEETS} channels, encoder=${ENCODER}, ${DURATION}s"

if [ "${REAL}" = 1 ]; then
    RTSP_BASE="rtsp://127.0.0.1:8554"
    echo "bench: using the club's real cameras via the running MediaMTX"
else
    # A private MediaMTX on :8554 fed by synthetic 'cameras' that
    # approximate an old camera's default stream (h264, ${SRC}, 30 fps).
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
    # Ours must be the one listening, or the bench measures some other
    # server's streams (same check as demo_stack.sh).
    kill -0 "$(cat "${WORK}/mtx.pid")" 2>/dev/null || {
        echo "bench: FAIL — our mediamtx did not start (is something else on :${PORT}?"
        echo "       stop it, or set DEMO_RTSP_PORT to a free port); its log:"
        cat "${WORK}/mtx.log"; exit 1
    }
    i=1
    while [ "${i}" -le "${SHEETS}" ]; do
        for role in home away; do
            ffmpeg -hide_banner -loglevel error -re \
                -f lavfi -i "testsrc2=size=${SRC}:rate=30" \
                -c:v libx264 -preset ultrafast -tune zerolatency \
                -b:v 2000k -g 60 -pix_fmt yuv420p \
                -f rtsp -rtsp_transport tcp \
                "rtsp://127.0.0.1:${PORT}/cam-${i}-${role}" \
                >"${WORK}/pub-${i}-${role}.log" 2>&1 &
            echo $! >> "${WORK}/pubs.pid"
        done
        i=$((i+1))
    done
    RTSP_BASE="rtsp://127.0.0.1:${PORT}"
    sleep 2
fi

# Scorebug FIFOs with a writer repeating a frame at 1 fps (what the
# renderer does between score changes).
mkdir -p "${WORK}/fifo"
python3 - "$WORK/fifo" "$SHEETS" <<'EOF' &
import os, sys, time, threading
d, n = sys.argv[1], int(sys.argv[2])
frame = bytes(640*360*4)
def w(p):
    while True:
        try:
            with open(p, "wb", buffering=0) as f:
                while True:
                    f.write(frame); time.sleep(1)
        except (BrokenPipeError, OSError):
            time.sleep(0.5)
for i in range(1, n+1):
    p = os.path.join(d, f"bug-{i:02d}.fifo")
    os.path.exists(p) or os.mkfifo(p)
    threading.Thread(target=w, args=(p,), daemon=True).start()
while True: time.sleep(60)
EOF
echo $! > "${WORK}/fifo.pid"

# Sponsor rail placeholder
ffmpeg -hide_banner -loglevel error -f lavfi \
    -i "color=c=0x1a1a19:size=1920x360" -frames:v 1 -y "${WORK}/rail.png"

# Each compositor gets a hard deadline (DURATION + 45 s, then SIGKILL).
# Without it a channel whose source dies can sit dropping frames for ever
# and the bench never returns — seen 12 Oct 2026. A killed channel has no
# final speed= line and is reported as NO RESULT below.
# Tile geometry for hero-away-bug-rail at this canvas — the same even-
# rounded thirds streamer-generate uses, so the bench tests the real
# layout at any size (odd sizes break VAAPI nv12 surfaces).
CW=${CANVAS%x*}; CH=${CANVAS#*x}
ev() { printf '%d' "$(( ( ($1) + 1 ) / 2 * 2 ))"; }
HX=0; HY=0; HW=$(ev $((CW*2/3))); HH=$(ev $((CH*2/3)))
AX=$HW; AY=0; AW=$((CW-HW)); AH=$(ev $((CH/3)))
BX=$HW; BY=$AH; BW=$AW; BH=$((HH-AH))
RX=0; RY=$HH; RW=$CW; RH=$((CH-HH))
echo "bench: canvas ${CANVAS} — hero ${HW}x${HH} away ${AW}x${AH} bug ${BW}x${BH} rail ${RW}x${RH}"

echo "bench: starting ${SHEETS} compositors..."
i=1
while [ "${i}" -le "${SHEETS}" ]; do
    env SHEET="${i}" FPS=30 CANVAS_W="${CW}" CANVAS_H="${CH}" BITRATE_K=4500 \
        ENCODER="${ENCODER}" \
        HOME_URL="${RTSP_BASE}/cam-${i}-home" HERO_X="${HX}" HERO_Y="${HY}" \
        HERO_W="${HW}" HERO_H="${HH}" \
        AWAY_URL="${RTSP_BASE}/cam-${i}-away" AWAY_X="${AX}" AWAY_Y="${AY}" \
        AWAY_W="${AW}" AWAY_H="${AH}" \
        FIFO="${WORK}/fifo/bug-$(printf %02d "${i}").fifo" \
        BUG_X="${BX}" BUG_Y="${BY}" BUG_W="${BW}" BUG_H="${BH}" \
        SPONSOR="${WORK}/rail.png" RAIL_X="${RX}" RAIL_Y="${RY}" RAIL_W="${RW}" RAIL_H="${RH}" \
        DURATION="${DURATION}" OUTPUT_OVERRIDE=null \
        timeout -k 10 "$((DURATION + 45))" \
        "${COMPOSE}" >"${WORK}/ch-${i}.log" 2>&1 &
    echo $! >> "${WORK}/chan.pid"
    i=$((i+1))
done

wait $(cat "${WORK}/chan.pid") || true

echo
echo "bench results (${SHEETS} channels, ${ENCODER}, source ${SRC}, canvas ${CANVAS}):"
fail=0
i=1
while [ "${i}" -le "${SHEETS}" ]; do
    speed=$(grep -o 'speed=[0-9.]*x' "${WORK}/ch-${i}.log" | tail -1)
    [ -n "${speed}" ] || { speed="NO RESULT — see ${WORK}/ch-${i}.log"; fail=1; }
    case "${speed}" in
        speed=0.*) fail=1;;
    esac
    echo "  channel ${i}: ${speed}"
    i=$((i+1))
done
echo
if [ "${fail}" = 1 ]; then
    echo "VERDICT: FAIL — at least one channel below realtime (or no"
    echo "result). Fewer sheets per box, a faster encoder path, or a"
    echo "lower canvas. Logs kept in ${WORK} (trap disabled on fail)."
    trap - EXIT
    kill $(cat "${WORK}"/*.pid 2>/dev/null) 2>/dev/null || true
    exit 1
fi
echo "VERDICT: PASS if every channel is comfortably >= 1.00x (aim 1.3x)."
echo "Record date, box, encoder and speeds in the deployment notes."
