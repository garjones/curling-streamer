# streamer — repo guide for Claude Code

Unattended per-sheet stream compositor for a curling club: MediaMTX fans
out the club cameras, one ffmpeg per sheet composites camera(s) + scorebug
+ sponsor rail and pushes RTMP, the scorebug renderer feeds each ffmpeg
through a named FIFO, and a LAN page shows status. **Read `README.md`
first — it is the real documentation** and explains every constraint the
design is bent around. The umbrella project guide is `../CLAUDE.md`
(the `curling` monorepo of sub-projects); read it for the wider context
and conventions.

**Club-agnostic — this is the product, not one club.** Nothing in this
repo may hard-code a single club's cameras, sheet count, colours, layout
or credentials. Pilot-site (KCC) material lives outside this repo, under
`clubs/kcc/` in the umbrella. If a change would only ever be true for one
club, it belongs in `club.yaml` or `secrets.env`, not here — flag it.

## Running the checks

This repo is meant to be verifiable end to end. When asked to **"check
everything"** (or to review, verify or audit the repo), work through the
Verification playbook below in order, run what can be run, reason about
the rest, and finish with a findings report (format at the end). Do not
change code while checking unless asked — report first.

The runnable checks need `ffmpeg`, `python3` with PyYAML, and a
MediaMTX binary (path in `$MEDIAMTX`). Chromium is **not** needed — the
demo drives the scorebug FIFO with a synthetic writer, not the live
renderer. No GPU is needed for the demo; it encodes with x264.

This checkout runs on either platform — adapt to the one you are on:

- **macOS (Gareth's laptop).** `brew install ffmpeg mediamtx` and
  `pip3 install pyyaml`; set `MEDIAMTX="$(command -v mediamtx)"`.
  Sections A, B, C and E all run. `install.sh` and the `systemd/` units
  are Debian-only — **read and `sh -n` them, never run them here**
  (no `apt`, no `systemd`, no `useradd`). The VAAPI/QSV encoders and the
  hardware bench (D) need a real Intel-GPU Linux box and do **not** run on
  a Mac — report them NOT-RUN, do not fake them or swap in videotoolbox.
- **Debian/Ubuntu (the encoder box).** `apt-get install ffmpeg python3
  python3-yaml`; MediaMTX is the pinned `v1.19.1` binary `install.sh`
  downloads. All sections run, including the bench on real hardware.

Either way: say what you could not run rather than faking a result.

## Verification playbook

### A. Static checks (always runnable)
1. Byte-compile the Python:
   `python3 -m py_compile bin/streamer-generate bin/streamer-compose bin/streamer-status-server renderer/*.py`
2. Syntax-check the shell: `sh -n install.sh bootstrap.sh bin/streamer-deploy tools/*.sh`
   (`bootstrap.sh` and `install.sh` are Debian-only — read, never run
   here; `streamer-deploy` runs on a Mac with `STREAMER_ETC=<dir>` and
   `--no-enable` against a fake club dir holding `streaming/club.yaml`
   and a `secrets.env.age` encrypted to any SSH key — check it decrypts,
   generates, and exits 78 on a missing or wrong key)
3. Config generation, dry run — prove `streamer-generate` turns the
   example config into correct runtime files:
   ```sh
   d=$(mktemp -d); cp club.example.yaml "$d/club.yaml"
   printf 'CAM_USER=root\nCAM_PASS=x\nSHEET_1_KEY=k1\nSHEET_2_KEY=k2\n' > "$d/secrets.env"
   chmod 600 "$d/secrets.env"
   STREAMER_ETC="$d" ./bin/streamer-generate --sheets 1-2
   cat "$d/sheet-1.env" "$d/mediamtx.yml"; rm -rf "$d"
   ```
   Check: tile geometry adds up to the canvas, `cam-N-home/away` paths
   carry the expanded credentials, `sourceOnDemand: true`, and every
   consumer reads from the local MediaMTX (never a camera directly).

### B. Secrets hygiene (must pass)
- `git ls-files | grep -iE 'secrets\.env$|(^|/)club\.yaml$|auto\.(crt|key)|\.pyc$'`
  must be **empty** — only the `.example` files are ever tracked.
- Confirm `.gitignore` covers `secrets.env`, `club.yaml`, `vendor/`,
  `auto.crt`, `auto.key`, `__pycache__/`.
- Grep the tracked tree for anything that looks like a real credential,
  RTMP stream key or non-example camera IP. There should be none.

### C. End-to-end plumbing (runnable, no GPU)
- `MEDIAMTX=/path/to/mediamtx ./tools/demo_stack.sh`
- It stands up MediaMTX + two synthetic cameras + a scorebug FIFO + one
  compositor, encodes 12 s with x264, and **proves a mid-stream scorebug
  change travelled through the FIFO** by diffing an early and a late
  frame. It must print `PASS`. A failure here is a real defect.
- `MEDIAMTX=/path/to/mediamtx ./tools/demo_dropout.sh` — same topology;
  kills the home camera, then the scorebug writer, mid-stream and
  requires the compositor to **exit within 20 s** each time (systemd
  restarts it in production). Must print `PASS` twice.
- Both refuse to run if something else holds :8554 — on the laptop a
  Homebrew `mediamtx` service may (`brew services list`). Do not stop
  it; run with `DEMO_RTSP_PORT=8560` and say so in the report.

### D. Hardware bench (only on a real Intel-GPU box)
- `./tools/bench.sh --sheets 6 --encoder vaapi` (add `--real` to use the
  club's cameras). This is the gate before any club buys hardware: every
  channel must hold `>= 1.00x` (aim `>= 1.3x`). It cannot run in a
  sandbox — report it as not-run, do not fake a result.

### E. Design-conformance review (read and reason)
Confirm the non-negotiables actually hold in the code, not just the docs:
- **FIFO, never a still image.** `streamer-compose` must feed the
  scorebug as rawvideo over a FIFO. `ffmpeg -loop 1 -i bug.png` is a bug,
  not a simplification — it decodes once and caches forever.
- **No polling.** The renderer holds one WebSocket per club; nothing
  polls an HTTP endpoint on a timer.
- **Club-agnostic.** No hard-coded sheet count, camera address, colour or
  layout anywhere in this repo. Sheets, cameras, canvas, layout, encoder
  and destination all come from `club.yaml`.
- **Secrets off the command line.** Stream keys reach ffmpeg via
  systemd `EnvironmentFile`, never argv (where `ps`/journald would leak
  them). The destination URL is assembled inside `streamer-compose`.
- **Honest failure.** `streamer@.service` uses `Restart=always` with
  `RestartPreventExitStatus=78` so a missing key parks the unit with a
  readable status instead of a restart loop. Every *live* overlay in
  `streamer-compose` (cameras, scorebug) carries `eof_action=endall` so
  a lost input ends ffmpeg and the restart reconnects it; the default
  `repeat` is a frozen tile with a green status page.
- **No scorebug, no renderer.** With `counter_server` absent,
  `streamer-generate` must leave `renderer.env` **empty** (zero bytes):
  `streamer-renderer.service` keys on `ConditionFileNotEmpty`.
- **README ↔ code.** Spot-check that README claims match the code
  (layout maths, the FIFO contract, the pinned MediaMTX version and its
  sha256 in `install.sh`).

## Conventions
- Prose is British-inflected (colour, licence, optimise) — match it.
- Small, meaningful commits with a why in the body; never commit a
  secret; keep the repo private.
- Optimise for the volunteer at 8pm on a Tuesday: fewer dependencies,
  plainer failure modes, states a human can read.

## Reporting a check
Finish with a short report: one line per playbook section (PASS / FAIL /
NOT-RUN with the reason), then a findings list ordered by severity —
each finding naming the file, what is wrong, and why it matters. If
everything passes, say so plainly and note what could not be run here
(the VAAPI/QSV paths and the hardware bench).
