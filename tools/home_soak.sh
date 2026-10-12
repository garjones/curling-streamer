#!/bin/sh
# home_soak.sh — run ONE real production unit (streamer@N) at home, fed by
# synthetic cameras, pushing to the sheet's real YouTube stream key.
#
#   sudo tools/home_soak.sh start   [--sheet 1] [--club /opt/curling-club]
#   sudo tools/home_soak.sh survive [--sheet 1]
#   sudo tools/home_soak.sh stop    [--club /opt/curling-club]
#
# bench.sh proves the GPU keeps up; this proves everything bench.sh
# bypasses: the systemd unit and its EnvironmentFiles, the production
# MediaMTX pulling "cameras" on demand, the live scorebug renderer against
# the real counter server, the sponsor rail, the RTMP push and YouTube's
# ingest — all without being at the club.
#
# start:   two live test-card publishers (home shows a running clock, so a
#          freeze is visible on YouTube) go into a private MediaMTX on
#          :8654; a copy of the club's club.yaml with sheet N's camera URLs
#          pointed at them is applied with streamer-deploy --sheets N. The
#          production stack (MediaMTX :8554, renderer, streamer@N) then
#          runs exactly as it would at the club.
# survive: SIGKILLs the compositor (an encoder blip). systemd must restart
#          it within ~5 s; YOU confirm in YouTube Studio that the broadcast
#          stayed live on the same watch URL — the auto-stop-OFF check the
#          README asks for. Undocumented YouTube behaviour: only a test
#          proves it.
# stop:    kills the publishers and re-applies the real club config for
#          the sheets this box had before the soak. ALWAYS run this before
#          the box goes to the club — until then its club.yaml points
#          sheet N at 127.0.0.1.
#
# Needs: the stack installed and deployed once (bootstrap.sh), SHEET_N_KEY
# filled in /etc/streamer/secrets.env, and the box online (counter server,
# YouTube). Start the broadcast UNLISTED on the channel first.

set -eu

STATE="${SOAK_STATE:-/var/lib/streamer-soak}"
ETC="${STREAMER_ETC:-/etc/streamer}"
MTX="${MEDIAMTX:-/usr/local/bin/mediamtx}"
PORT="${SOAK_RTSP_PORT:-8654}"
SRC="${SOAK_SOURCE_SIZE:-854x480}"
SHEET=1
CLUB=/opt/curling-club
CMD="${1:-}"; [ $# -gt 0 ] && shift

usage() { sed -n '2,8p' "$0" >&2; exit 1; }
while [ $# -gt 0 ]; do
    case "$1" in
        --sheet) SHEET=$2; shift 2;;
        --club)  CLUB=$2; shift 2;;
        *) usage;;
    esac
done
[ "$(id -u)" = 0 ] || { echo "soak: run as root (sudo)"; exit 1; }

box_ip() { hostname -I 2>/dev/null | awk '{print $1}'; }
deployed_sheets() {
    # What streamer-deploy last wrote for this box — restored by stop.
    ls "$ETC"/sheet-*.env 2>/dev/null | sed 's/.*sheet-\([0-9]*\)\.env/\1/' \
        | sort -n | tr '\n' ',' | sed 's/,$//'
}

start() {
    [ -f "$CLUB/streaming/club.yaml" ] || { echo "soak: $CLUB/streaming/club.yaml not found"; exit 78; }
    [ -x "$MTX" ] || { echo "soak: mediamtx not found at $MTX"; exit 78; }
    command -v streamer-deploy >/dev/null || { echo "soak: streamer is not installed"; exit 78; }
    grep -q "^SHEET_${SHEET}_KEY=.." "$ETC/secrets.env" 2>/dev/null || {
        echo "soak: SHEET_${SHEET}_KEY is blank in $ETC/secrets.env — paste the key from"
        echo "      YouTube Studio (Go live -> Stream -> Manage) and re-run."; exit 78; }
    [ -f "$STATE/active" ] && { echo "soak: already running (sheet $(cat "$STATE/active")) — 'stop' first"; exit 1; }

    install -d -m 700 "$STATE"
    deployed_sheets > "$STATE/restore-sheets"
    [ -s "$STATE/restore-sheets" ] || echo "soak: note — no sheet-*.env found; stop will restore sheet $SHEET only"
    [ -s "$STATE/restore-sheets" ] || echo "$SHEET" > "$STATE/restore-sheets"

    # -- private MediaMTX for the synthetic cameras ------------------------
    cat > "$STATE/mtx.yml" <<YML
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
YML
    nohup "$MTX" "$STATE/mtx.yml" >"$STATE/mtx.log" 2>&1 &
    echo $! > "$STATE/mtx.pid"
    sleep 1
    kill -0 "$(cat "$STATE/mtx.pid")" 2>/dev/null || {
        echo "soak: our mediamtx did not start on :$PORT (set SOAK_RTSP_PORT to a free port):"
        cat "$STATE/mtx.log"; exit 1; }

    # -- two live 'cameras' (x264, ~half a core each). testsrc carries a
    #    running timestamp: if the clock on YouTube stops, the chain froze.
    for role in home away; do
        if [ "$role" = home ]; then gen="testsrc=size=${SRC}:rate=30"
        else gen="testsrc2=size=${SRC}:rate=30"; fi
        nohup ffmpeg -hide_banner -loglevel error -re -f lavfi -i "$gen" \
            -c:v libx264 -preset ultrafast -tune zerolatency -b:v 2000k -g 60 \
            -pix_fmt yuv420p -f rtsp -rtsp_transport tcp \
            "rtsp://127.0.0.1:${PORT}/soak-${role}" >"$STATE/pub-${role}.log" 2>&1 &
        echo $! >> "$STATE/pubs.pid"
    done
    sleep 2

    # -- club.yaml override: sheet N's cameras -> the synthetic ones ---------
    install -d -m 755 "$STATE/override/streaming"
    python3 - "$CLUB/streaming/club.yaml" "$STATE/override/streaming/club.yaml" "$SHEET" "$PORT" <<'PY'
import sys, yaml
src, dst, n, port = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
club = yaml.safe_load(open(src))
hit = False
for s in club.get("sheets", []):
    if int(s["n"]) == n:
        s["home"] = f"rtsp://127.0.0.1:{port}/soak-home"
        s["away"] = f"rtsp://127.0.0.1:{port}/soak-away"
        hit = True
if not hit:
    sys.exit(f"soak: sheet {n} is not in {src}")
with open(dst, "w") as f:
    f.write("# HOME SOAK OVERRIDE — generated by tools/home_soak.sh; sheet %d's\n"
            "# cameras point at synthetic publishers on this box. Not for the club.\n" % n)
    yaml.safe_dump(club, f, sort_keys=False)
PY
    [ -f "$CLUB/streaming/sponsor.png" ] && install -m 644 "$CLUB/streaming/sponsor.png" "$STATE/override/streaming/"
    # No secrets.env.age in the override: streamer-deploy keeps the real
    # /etc/streamer/secrets.env, which already holds the key.

    echo "soak: applying override for sheet $SHEET (production stack restarts)"
    streamer-deploy "$STATE/override" --sheets "$SHEET"
    echo "$SHEET" > "$STATE/active"
    sleep 8
    echo
    systemctl --no-pager --lines=0 status "streamer@$SHEET" | sed -n 1,5p || true
    echo
    echo "soak: running. Watch:"
    echo "  status page      http://$(box_ip):8080/"
    echo "  compositor log   journalctl -fu streamer@$SHEET"
    echo "  YouTube Studio   stream health should go green within ~30 s; the hero tile"
    echo "                   shows a running clock, the scorebug is sheet $SHEET on the"
    echo "                   club's counter, the rail is streaming/sponsor.png."
    echo "  then             sudo $0 survive --sheet $SHEET"
    echo "  finally          sudo $0 stop"
}

survive() {
    [ -f "$STATE/active" ] || { echo "soak: not running — 'start' first"; exit 1; }
    echo "soak: note the broadcast's watch URL in YouTube Studio NOW, then press Enter."
    read -r _ </dev/tty
    pid=$(systemctl show -p MainPID --value "streamer@$SHEET")
    echo "soak: SIGKILL compositor pid $pid (simulated encoder crash) at $(date +%T)"
    systemctl kill -s SIGKILL "streamer@$SHEET"
    sleep 7
    state=$(systemctl show -p ActiveState --value "streamer@$SHEET")
    newpid=$(systemctl show -p MainPID --value "streamer@$SHEET")
    if [ "$state" = active ] && [ "$newpid" != "$pid" ] && [ "$newpid" != 0 ]; then
        echo "soak: systemd restarted it (pid $newpid) — box side PASS"
    else
        echo "soak: unit is '$state' pid $newpid — box side FAIL; see journalctl -u streamer@$SHEET"
    fi
    echo "soak: now the part only you can judge, in YouTube Studio within ~60 s:"
    echo "      - broadcast still LIVE (not ended), same watch URL      => auto-stop is off: PASS"
    echo "      - broadcast ended / a new watch URL appeared            => auto-stop is ON: fix it"
    echo "        (Stream settings -> Enable Auto-stop OFF) and run survive again"
    echo "      Record both results in the deployment notes."
}

stop() {
    [ -d "$STATE" ] || { echo "soak: nothing to stop"; exit 0; }
    kill $(cat "$STATE"/pubs.pid "$STATE"/mtx.pid 2>/dev/null) 2>/dev/null || true
    restore=$(cat "$STATE/restore-sheets" 2>/dev/null || echo "$SHEET")
    echo "soak: restoring the real club config for sheets $restore"
    streamer-deploy "$CLUB" --sheets "$restore"
    rm -rf "$STATE"
    grep -q '127.0.0.1:'"$PORT" "$ETC/club.yaml" && { echo "soak: WARNING $ETC/club.yaml still carries the override"; exit 1; }
    echo "soak: clean — $ETC/club.yaml is the club's again."
}

case "$CMD" in
    start)   start;;
    survive) survive;;
    stop)    stop;;
    *)       usage;;
esac
