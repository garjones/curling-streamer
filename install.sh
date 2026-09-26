#!/bin/sh
# streamer installer — Debian stable (12/13), amd64, run as root.
#
#   sudo ./install.sh
#
# Idempotent: safe to re-run after pulling updates. It installs packages,
# the pinned MediaMTX, the streamer binaries and units, and the vendored
# counter renderer. It does NOT start any stream: that happens only after
# you create /etc/streamer/club.yaml and secrets.env and run
# streamer-generate — the last lines printed walk you through it.

set -eu

MEDIAMTX_VERSION="v1.19.1"
MEDIAMTX_SHA256="035ee04f91b1c7a0c02e13b2139ca2456e43b6bd6a80e3100e8c228556e07807"
MEDIAMTX_URL="https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/mediamtx_${MEDIAMTX_VERSION}_linux_amd64.tar.gz"

HERE="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }

echo "== packages"
apt-get update -qq
apt-get install -y --no-install-recommends \
    ffmpeg python3 python3-yaml chromium curl ca-certificates
# Intel GPU encode (VAAPI, iHD driver — covers Arc/DG2 and recent iGPUs).
# The driver lives in the non-free component; if this fails, add
# "non-free non-free-firmware" to /etc/apt/sources.list and re-run.
apt-get install -y intel-media-va-driver-non-free vainfo || {
    echo "WARNING: intel-media-va-driver-non-free not installed —"
    echo "  hardware encoding will not work until it is. Enable the"
    echo "  non-free apt component and re-run this installer."
}

echo "== user"
id streamer >/dev/null 2>&1 || \
    useradd -r -d /var/lib/streamer -s /usr/sbin/nologin streamer
usermod -aG video streamer 2>/dev/null || true
getent group render >/dev/null && usermod -aG render streamer || true
install -d -o streamer -g streamer /var/lib/streamer

echo "== mediamtx ${MEDIAMTX_VERSION}"
if [ ! -x /usr/local/bin/mediamtx ] || \
   ! /usr/local/bin/mediamtx --version 2>/dev/null | grep -q "${MEDIAMTX_VERSION}"; then
    tmp="$(mktemp -d)"
    curl -fsSL -o "${tmp}/mediamtx.tar.gz" "${MEDIAMTX_URL}"
    echo "${MEDIAMTX_SHA256}  ${tmp}/mediamtx.tar.gz" | sha256sum -c - || {
        echo "ERROR: mediamtx download failed its checksum — not installing." >&2
        rm -rf "${tmp}"; exit 1
    }
    tar -xzf "${tmp}/mediamtx.tar.gz" -C "${tmp}" mediamtx
    install -m 755 "${tmp}/mediamtx" /usr/local/bin/mediamtx
    rm -rf "${tmp}"
fi

echo "== streamer files"
install -m 755 "${HERE}/bin/streamer-generate"      /usr/local/bin/
install -m 755 "${HERE}/bin/streamer-compose"       /usr/local/bin/
install -m 755 "${HERE}/bin/streamer-status-server" /usr/local/bin/
install -d /opt/streamer/renderer
install -m 644 "${HERE}"/renderer/*.py "${HERE}"/renderer/*.md /opt/streamer/renderer/ 2>/dev/null || \
    install -m 644 "${HERE}"/renderer/*.py /opt/streamer/renderer/
install -m 644 "${HERE}/README.md" /opt/streamer/ 2>/dev/null || true
install -m 644 "${HERE}"/systemd/*.service /etc/systemd/system/

install -d -m 755 /etc/streamer
[ -f /etc/streamer/club.yaml ] || \
    install -m 644 "${HERE}/club.example.yaml" /etc/streamer/club.example.yaml
if [ ! -f /etc/streamer/secrets.env ]; then
    install -m 600 -o root -g streamer "${HERE}/secrets.example.env" \
        /etc/streamer/secrets.env
    chmod 640 /etc/streamer/secrets.env
fi
touch /etc/streamer/renderer.env

systemctl daemon-reload
systemctl enable streamer-status.service >/dev/null 2>&1 || true
systemctl restart streamer-status.service || true

if [ -f /etc/streamer/club.yaml ]; then
    echo "== regenerating config from existing club.yaml"
    streamer-generate || true
fi

cat <<'DONE'

== streamer installed. Next steps (first install):

 1. cp /etc/streamer/club.example.yaml /etc/streamer/club.yaml
    ...edit it for your club (cameras, layout, counter slug)
 2. edit /etc/streamer/secrets.env  (camera password, stream keys)
 3. streamer-generate --sheets 1-6      # the sheets THIS box carries
 4. systemctl enable --now streamer-mediamtx streamer-renderer
    systemctl enable --now streamer@1 streamer@2 ... (one per sheet)
 5. open http://this-box:8080/ — the status page — and check for green

Before the first real broadcast, run the bench:  tools/bench.sh --help
DONE
