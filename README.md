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

**One line on a fresh Debian stable (amd64) box:**

```sh
curl -fsSL https://raw.githubusercontent.com/garjones/curling-streamer/main/bootstrap.sh \
  | sudo sh -s -- --club <owner>/<site-repo> --sheets 1-6
```

It installs the product, then asks for exactly one thing: the **club
machine key**, an SSH private key kept in the club's password manager.
That key reads the club's private *site repo* on GitHub (as a read-only
deploy key) and decrypts the secrets inside it (as an `age` identity —
`age` accepts SSH keys directly). Everything else is fetched. Running the
same line again is the upgrade path.

The site repo is the club's, not the product's: one private repo per
club holding `streaming/club.yaml`, `streaming/secrets.env.age` (the
secrets file encrypted to the machine key) and optionally
`streaming/sponsor.png`. That is the whole contract; `streamer-deploy`
applies such a checkout to the box and is what `bootstrap.sh` calls last:

```sh
cd /opt/curling-club && git pull && sudo streamer-deploy . --sheets 1-6
```

Rebuilding a box therefore needs nothing that lives only on someone's
laptop: the product is public, the site repo is on GitHub, and the one
secret that unlocks it is in the password manager. Rotating the machine
key means re-encrypting `secrets.env.age` to the new key and replacing
the deploy key — one commit and one GitHub setting.

**By hand**, as root: `./install.sh`, then follow its printed
next-steps (`club.yaml`, `secrets.env`, `streamer-generate --sheets 1-6`,
enable units, open `:8080`). **ffmpeg 5 or newer is required** (Debian 12/13 and Homebrew both
qualify; Ubuntu 22.04's ffmpeg 4.4 does not — there `-timeout` on an
RTSP input means *listen* and the compositor tries to become a server;
found by the 12 Oct 2026 check). The installer pins MediaMTX v1.19.1 by
SHA-256 and installs the Intel VAAPI driver
(`intel-media-va-driver-non-free` — needs the `non-free` apt component;
the iHD driver covers Arc/DG2 and recent iGPUs).

## Layouts

Presets, computed from the canvas — a club with better or worse cameras
changes `canvas`/cameras, not code:

- `hero-away-bug-rail` (the KCC Silver layout) — hero ⅔×⅔ top-left,
  away camera ⅓×⅓ top-right, scorebug under it, sponsor rail across the
  bottom. At 1920×1080 that is exactly 1280×720 + 640×360 + 640×360 +
  1920×360, and the scorebug slot is the bug's native size.
- `quad` — both houses the same size side by side on top, sponsor panel
  bottom-left, scorebug bottom-right. The end in play alternates every
  end, so a layout that favours one house is wrong half the time; this
  one never is. At 1280×720 every tile is 640×360 — cameras at 0.75×,
  scorebug native. The sponsor image is 16:9 here (a panel, not a
  strip); the club name is already on the scorebug, so keep the panel
  to logo and sponsors.
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

A live pipeline cannot exceed 1.0× — output follows input — so a
channel that keeps up reads ~0.97–0.99× over 60 s (startup counts as
wall time). The bench passes a channel at ≥ (1 − 3 s/duration) **with
zero dropped frames**; drops are the real sign of falling behind.
`--duration 300` tightens the bar. Note that pre-10th-gen
refurb boards have no Resizable BAR; the media engine is believed to be
largely indifferent but the bench, not the belief, is the gate. Record
date, box, encoder and speeds in the deployment notes.

`tools/demo_stack.sh` is the smaller cousin: proves RTSP in → composite
out → live FIFO change on any machine, no GPU, in ~20 seconds. Run it
whenever you doubt the plumbing. `tools/demo_dropout.sh` then takes a
camera and the scorebug writer away mid-stream and proves the compositor
exits (so systemd can restart it) instead of freezing. Both start their
own MediaMTX on :8554 and refuse to run if something else holds the port
(set `DEMO_RTSP_PORT` to a free one) — a demo that quietly used some
other server's streams would prove nothing.

`tools/home_soak.sh` is the last step before the box leaves for the
club, and the only one that needs a real stream key: it runs ONE real
`streamer@N` unit — production MediaMTX, the renderer against the club's
counter server, sponsor rail, RTMP push — fed by two synthetic cameras
on the box, so YouTube ingest and the auto-stop-off behaviour get tested
from home. `start`, then `survive` (SIGKILLs the compositor; you confirm
in YouTube Studio that the broadcast kept its watch URL), then `stop`,
which restores the club's own config. Run `stop` before the box travels.

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
- Club link gone? The scorebug freezes on its last score (the renderer
  keeps repeating the frame) and catches up when the link returns; the
  cameras are local, so the picture never stops.
- A camera gone, or the renderer restarted? The compositor **exits** and
  systemd restarts it 5 s later, reconnected. That is a short blip on
  the broadcast, which is why auto-stop must be off (YouTube notes).
  Until 6 Oct 2026 this README claimed streams "recover on their own";
  they did not — the overlay kept the tile's last frame for the rest of
  the broadcast with the unit still `active` and the status page green.
  `tools/demo_dropout.sh` now proves the restart.

## Decisions taken while building (flagged, not asked)

- **VAAPI is the default encoder**, not QSV: Debian stable's ffmpeg
  speaks to Arc through the iHD VAAPI driver out of the box, while the
  QSV/oneVPL path wants a newer ffmpeg than stable ships. `encoder:
  qsv` and `x264` exist; the bench decides if VAAPI needs revisiting.
- **Scaling and overlay run on the GPU** (`filtering: gpu`, the
  default): VAAPI hardware decode → `scale_vaapi` → `overlay_vaapi` →
  `h264_vaapi`, so a frame never enters system memory. The original
  software graph is still there as `filtering: cpu` (both modes now
  re-base every live camera to t=0 — see below).
  **Why it changed:** the first bench on the pilot box (i7-6700 + Arc
  A380, 12 Oct 2026) measured the software graph at **~2 CPU cores per
  channel** — two channels pegged the 4-core box at 1.06x and six
  channels managed 0.68x, while the Arc idled doing only the encode.
  The earlier note here said software filtering was fine until the bench
  said otherwise; the bench said otherwise.
- **Live inputs are re-based to zero** (`setpts=PTS-STARTPTS`). The
  silent audio track starts at t=0 and a camera's RTSP clock does not;
  the muxer interleaves by timestamp, so once the hero became the main
  input the output inherited the camera's offset and the muxer stalled
  waiting for audio to catch up — a flat 0.62x at any resolution and
  any channel count, with the GPU idle. Bisected on 12 Oct 2026; the
  generated canvas of the old graph had been masking it.
- **MediaMTX pinned to v1.19.1** (sha256 in `install.sh`), RTSP only,
  every other protocol and its API switched off — including MoQ, which
  that version turns on by default and which tried to write a
  certificate into the read-only working directory (6 Oct 2026).
- **A lost input ends the compositor.** Every live overlay (cameras,
  scorebug) uses `eof_action=endall`, and RTSP reads time out after
  10 s of silence, so a dead input makes ffmpeg exit and `Restart=always`
  reconnects it. The alternative — repeating the last frame — looked
  like resilience and was a frozen tile nobody would notice.
- **`sourceOnDemand: true`** — a camera is pulled only while something
  is reading it.
- Camera credentials do end up inside generated `/etc/streamer/
  mediamtx.yml` (mode 640): MediaMTX cannot read per-path secrets from
  env files. Config lives outside any repo; acceptable, documented.

## Tested on hardware (12 Oct 2026, pilot box: i7-6700 + Arc A380)

The full GPU graph — VAAPI decode, `scale_vaapi`, `pad_vaapi`, three
`overlay_vaapi`, `h264_vaapi` — plus the FIFO scorebug, sponsor rail and
silent audio: **six channels at 1280×720, every one ≥0.965× with zero
dropped frames**, compositors ~25% CPU each, GPU engines barely warm;
**six channels at 1920×1080 pass too** (0.987–1.01×, zero drops). That
is six sheets per box on refurbished hardware at either canvas, with
headroom. `tools/demo_dropout.sh` with `DEMO_ENCODER=vaapi` passes on
the same box: the GPU graph exits on a lost camera or renderer. The
day's wrong turns (VPP pixels, pad cost, FIFO starvation, camera clock
skew — all tested and ruled out) and the real cause (audio/video clock
offset, fixed with `setpts=PTS-STARTPTS`) are in the git log and the
comments in `streamer-compose`.

**First run on real cameras (13 Oct 2026, at the club) found what a test
card cannot:** several cameras send H.264 *Baseline* (not Constrained
Baseline), which the Intel driver does not list, so the hardware decoder
refused them and the VAAPI graph died with `-38`. Fixed with
`-hwaccel_flags allow_profile_mismatch` on every live input (what such
cameras emit is constrained baseline in all but name). Check a new
club's cameras with `ffprobe -show_entries stream=profile` before
blaming the box. The bench also makes the synthetic card High profile —
real cameras are the only test of this path.

The same day found the second thing a test card hides: the **silent
audio track**, generated as a separate `-f lavfi -i anullsrc` input,
ran at a fraction of real time against real cameras and the muxer
paced the whole stream to it (0.2–0.3x; YouTube reported "not
receiving enough video"). Generated inside the filter graph instead,
the full graph runs at 1.1x and **six sheets on the real cameras pass
the bench** (13 Oct 2026). Why the standalone input misbehaves is not
understood; the comment in `streamer-compose` says what was measured.

## Not yet tested (honestly)

Real cameras (synthetic 854×480 test cards so far — run `tools/bench.sh
--real` at the club), QSV, actual YouTube ingest and the renderer under
this box's systemd wrapping (both covered by `tools/home_soak.sh` once a
stream key exists — results go in the club's deployment notes).
