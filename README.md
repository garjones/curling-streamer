# streamer

Turns one commodity Intel box on a curling club's LAN into an unattended
per-sheet stream compositor: cameras in, finished YouTube-ready streams
out, scorebug and sponsor rail burned in. Built for the KCC pilot; shaped
so nothing about it is KCC-specific (see `docs/streaming-design.md` in
the umbrella project — the club-agnostic design is parked but this
implements its node architecture).

Companion to **counter** (the live scoreboard): the only seam between
them is the scorebug — one URL and a named-pipe contract. A club that
does not stream never installs this; a club that streams without counter
just omits `counter_server` from its config.

## What runs on the box

Four services, all boring on purpose:

| Unit | What it is |
|---|---|
| `streamer-mediamtx` | [MediaMTX](https://github.com/bluenviron/mediamtx) pulls each camera's **default stream** exactly once and republishes on the LAN. Every consumer — compositors, kiosk TVs, a coach's VLC — reads `rtsp://<box>:8554/cam-N-{home,away}` instead of touching a camera. An old camera therefore ever sees **one client**, which is the structural fix for the identical-streams rule (Axis: identical requests share one encoder instance; different ones don't, and a 2014 SoC runs out fast). |
| `streamer@N` | One ffmpeg per sheet: decode both cameras, scale, overlay scorebug + sponsor rail, encode (VAAPI on Intel GPU), push RTMP. `systemctl status streamer@7` is the whole debugging story. |
| `streamer-renderer` | counter's scorebug renderer, vendored verbatim in `renderer/` — one WebSocket to the club (never polling), headless Chromium screenshot on score change, raw RGBA repeated at 1 fps into `/run/counter/bug-NN.fifo`. Why a FIFO and not a PNG: ffmpeg decodes a still image **once** and caches it forever; the pipe is the only way a changing image reaches a running ffmpeg (proved by `renderer/fifo_demo.py`, and again by `tools/demo_stack.sh`). |
| `streamer-status` | One dark, phone-readable page at `http://<box>:8080/` — per-sheet unit state, FIFO presence, camera reachability. No accounts; being on the club LAN is the credential. |

Configuration is **one YAML file** (`/etc/streamer/club.yaml`) plus one
secrets file (`/etc/streamer/secrets.env`, mode 600 — camera password
and stream keys, never committed, never on a command line where it would
leak into `ps` or the journal). `streamer-generate` turns them into the
files systemd reads; run it after every config change.

## Install

Debian stable (12/13) amd64, as root:

```sh
./install.sh
# then follow the printed next-steps (club.yaml, secrets.env,
# streamer-generate --sheets 1-6, enable units, open :8080)
```

The installer pins MediaMTX v1.19.1 by SHA-256 and installs the Intel
VAAPI driver (`intel-media-va-driver-non-free` — needs the `non-free`
apt component; the iHD driver covers Arc/DG2 and recent iGPUs).

## Layouts

Presets, computed from the canvas — a club with better or worse cameras
changes `canvas`/cameras, not code:

- `hero-away-bug-rail` (the KCC Silver layout) — hero ⅔×⅔ top-left,
  away camera ⅓×⅓ top-right, scorebug under it, sponsor rail across the
  bottom. At 1920×1080 that is exactly 1280×720 + 640×360 + 640×360 +
  1920×360, and the scorebug slot is the bug's native size.
- `full-bug` — one camera full-frame, scorebug anchored bottom-right.

The scorebug is always 640×360 by counter's contract and is scaled only
if a layout slot differs. The sponsor rail is a static image for now;
**rotation is a TODO** and will need its own small FIFO writer — do not
try `-loop 1` with a changing file (see the FIFO note above).

A silent stereo audio track is always included: platforms expect one,
the cameras have none, and the club audio question (house mic vs music
copyright claims) is deliberately unresolved.

## The bench gate — before any club buys hardware

The A380's published 478 fps / 2.66× six-channel margin is encode-only.
`tools/bench.sh` runs the **real** graph — N × (2 RTSP decodes + scales
+ overlays + FIFO + encode) — and reports per-channel ffmpeg speed:

```sh
tools/bench.sh --sheets 6 --encoder vaapi          # synthetic sources
tools/bench.sh --sheets 6 --encoder vaapi --real   # the club's cameras
```

Every channel must hold ≥ 1.00× (aim ≥ 1.3×). Note that pre-10th-gen
refurb boards have no Resizable BAR; the media engine is believed to be
largely indifferent but the bench, not the belief, is the gate. Record
date, box, encoder and speeds in the deployment notes.

`tools/demo_stack.sh` is the smaller cousin: proves RTSP in → composite
out → live FIFO change on any machine, no GPU, in ~20 seconds. Run it
whenever you doubt the plumbing.

## YouTube notes (verified Aug 2026 — see HANDOFF.md §3.3)

10 active streams per channel, 3 per stream key → twelve sheets = two
channels, six keys each. A phone number verifies only 2 channels/year.
First-time live enablement takes 24 h. **Disable auto-stop on every
broadcast** — otherwise an encoder blip mints a new watch URL and kills
every embed; verify by killing `streamer@N` and watching the broadcast
survive. Keys go in `secrets.env` only.

## Operational model (the volunteer at 8pm on a Tuesday)

- Is it working? `http://<box>:8080/` — green words, red words.
- One stream down? `systemctl restart streamer@7`.
- Everything down? Power-cycle the box; every unit is `Restart=always`
  and the whole stack comes up by itself. The UPS exists so a flicker
  never forces that.
- A missing stream key parks the unit with a readable message instead
  of a restart loop (`RestartPreventExitStatus=78`).
- Network gone? Streams freeze (renderer repeats the last scorebug
  frame) rather than break, and recover on their own.

## Decisions taken while building (flagged, not asked)

- **VAAPI is the default encoder**, not QSV: Debian stable's ffmpeg
  speaks to Arc through the iHD VAAPI driver out of the box, while the
  QSV/oneVPL path wants a newer ffmpeg than stable ships. `encoder:
  qsv` and `x264` exist; the bench decides if VAAPI needs revisiting.
- **Scaling/overlay run in software**, encode on GPU. Simplest correct
  graph first; if the bench says the CPU is the bottleneck, VAAPI
  scaling is the next lever.
- **MediaMTX pinned to v1.19.1** (sha256 in `install.sh`), RTSP only,
  every other protocol and its API switched off.
- **`sourceOnDemand: true`** — a camera is pulled only while something
  is reading it.
- Camera credentials do end up inside generated `/etc/streamer/
  mediamtx.yml` (mode 640): MediaMTX cannot read per-path secrets from
  env files. Config lives outside any repo; acceptable, documented.

## Not yet tested (honestly)

Real cameras, a real Intel GPU (VAAPI path is untestable in the build
container — `x264` is what the demo proves), QSV, actual YouTube ingest,
and the renderer against a live club (it is verbatim counter code, but
this box's systemd wrapping of it is new). First hardware day: run
`tools/demo_stack.sh`, then `tools/bench.sh --encoder vaapi`, then one
real camera end to end.
