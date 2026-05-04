# Ubuntu Noble — boot-time + memory before/after

End-to-end comparison of `dockerfile-kasm-core` (Ubuntu Noble base)
running under the legacy bash chain vs `container-init` (Phase 4).
**Both columns measured on the same image, same host, same options
— `kasm-entrypoint` chooses the path at boot via the `CONTAINER_INIT`
env var.**

**Host**: Apple Silicon, lima VM, podman 4.8.2 rootless, cgroup v2,
arm64. **Image**: `localhost/kasm-noble-phase5:latest`, built from
this branch with `BASE_IMAGE=ubuntu:24.04`. **Run options**:
`KASM_PROFILE_PULL=0 VNC_PW=vncpassword`, no client connected, 25 s
soak before snapshot. **Median-of-5** under Phase 5 5.x.2; per-run
data in `runs/noble/results.csv` and `runs/noble/{ci,bash}-N.trace.jsonl`.

## End-to-end boot time

Two TTFL views:
- **trace** = in-trace `kasmvnc_port_open.dt_ms` (bash) or
  `kasmvnc.service spawn dt_ms` (container-init: supervisor → exec
  `kasm-xvnc`; the Xvnc bind itself adds ~10 ms).
- **extern** = wall-clock host poll until `bash -c
  'exec 3<>/dev/tcp/127.0.0.1/6901'` succeeds inside the container,
  via `podman exec`. Conservative — adds podman-exec round-trip
  overhead (~50–100 ms per probe) on macOS/lima.

| Milestone                                 | Bash (Phase 0 entrypoint) | container-init (Phase 4) | Δ |
| -                                         | -:                       | -:                       | -: |
| boot_start → supervisor entered           | ~3 800 ms (sleep 3 + chain) | **2 ms**              | **−3 798 ms** |
| boot_start → kasm-setup completed         | n/a (inlined)             | **30 ms**                | — |
| boot_start → kasmvnc.service spawn        | n/a (inlined)             | **42 ms** median (n=5; range 22–49 ms) | — |
| boot_start → window-manager spawn         | n/a (inlined)             | ~30 ms                   | — |
| **kasmvnc_invoke (perl wrapper)**         | **582 ms**                | n/a (replaced by `kasm-xvnc`) | — |
| **TTFL trace median (n=5)**               | **577 ms** (n=4; range 518–927 ms) | **42 ms**       | **−535 ms (~14× faster)** |
| **TTFL extern median (n=5)**              | **912 ms**                | **456 ms**               | **−456 ms (~2× faster)** |
| wm_first_window                           | 219 ms                    | (same — XFCE itself)     | ~0 |

The bash trace had one 0-byte capture (`bash-1`) — likely the
`kasm_pre_shutdown_user.sh` truncating the trace mid-stop on a fast
container; n=4 medians excluding it. The container-init path captured
all 5 cleanly.

The Phase 0 baseline's dominant pre-port costs were:
- 582 ms inside the perl `vncserver` wrapper (option-parse + xauth +
  xdpyinfo poll loop). `kasm-xvnc` (Phase 4 launcher) builds the same
  argv vector and `syscall.Exec`s `/usr/bin/Xvnc` directly — saves
  all of it.
- 82 ms median (253 ms tail) for `openssl` cert generation. Now baked
  at image build time; `kasm-setup` only copies the file.
- 3 003 ms for `sleep 3` before the bash supervisor's first
  `kill -0`. Replaced by per-service ready signals.

## Steady-state memory (cgroup `memory.current`)

Same image, same options, same 25-second soak.

| Snapshot                | Bash      | container-init | Δ        |
| -                       | -:        | -:             | -:       |
| boot                    | 2 MiB     | 1 MiB          | −1 MiB   |
| post_kasmvnc            | 28 MiB    | (rolled into post_services) | — |
| post_services           | 59 MiB    | 2 MiB          | −57 MiB  |
| **steady_state t+20s** (median n=5) | **443 MiB** (range 427–677) | **230 MiB** (range 216–288) | **−213 MiB** (−48 %) |

For reference, the original Phase 0 measurement on
`kasmweb/core-ubuntu-noble:1.18.0-rolling-daily` (different
build commit, but same image family) recorded 566 MiB at
steady_state_t+20s; the 444 MiB number above is on this branch's
build, also under the bash entrypoint, isolating the Phase 4 unit-
set + helpers from the Phase 0 baseline drift.

### Top RSS contributors at steady state (KiB)

| Process              | Bash    | container-init | Note                       |
| -                    | -:      | -:             | -                          |
| xfce4-session        | 80 636  | 91 968         | XFCE                       |
| Xvnc                 | 80 496  | 87 460         | KasmVNC                    |
| **kasm_upload_server** | **47 492** | **(<5 MiB, not in top)** | Python/Flask → Go static (Phase 3) |
| xfdesktop            | 47 380  | (under top cap) | XFCE                      |
| ffmpeg               | 46 176  | 46 092         | audio-out                  |
| xfce4-panel          | 40 836  | (under top cap) | XFCE                      |
| xfwm4                | 39 884  | (under top cap) | XFCE                      |
| kasm_audio_out       | 37 676  | (socket-activated, not running) | now lazy        |
| kasm_gamepad_server  | 33 964  | (socket-activated, not running) | now lazy        |
| kasm_audio_input     | 31 456  | (socket-activated, not running) | now lazy        |
| **nm-applet**        | **28 588** | **(removed)** | autostart trim (Phase 1.4) |
| xfsettingsd         | 27 780  | (under top cap) | XFCE                      |
| **kasm_printer_service** | **27 060** | **27 080**     | runs eagerly (relay client) |
| **kasm_smartcard_bridge** | **18 940** | **18 940**     | runs eagerly (relay client) |
| pulseaudio           | 12 036  | 11 996         | audio                      |
| container-init        | n/a    | 6 860          | the supervisor itself      |

The biggest steady-state wins:
- **`kasm_upload_server`** (Python/Flask → Go static, Phase 3): saves
  ~42 MiB. The Go binary is 6 MiB cold, ~1 MiB RSS at steady state.
- **Lazy helpers** (`kasm_audio_out`, `kasm_gamepad_server`,
  `kasm_audio_input`, `kasm_audio_out_ws`): wrapped in
  socket-activated `.socket`+`.service` pairs. Idle containers do
  not start them; spin up only on first connect to the bound port.
  Saves ~75 MiB ambient RSS in the no-client-connected case.
- **XFCE autostart trim** (Phase 1.4): `nm-applet`, `polkit-gnome`,
  `xiccd`, `system-config-printer-applet` removed. ~50 MiB and
  ~5 broken processes gone.

`kasm_printer_service` and `kasm_smartcard_bridge` still run eagerly
under both paths — they are *clients* of `/tmp/printer` /
`/tmp/smartcard` (which Xvnc owns via `-UnixRelay`), so the lazy
socket-activated wiring landed in 4.6 was reverted during this 5.x.1
verification (see "Mid-flight unit-set fix" below).

## Process count

| Snapshot      | Bash | container-init | Δ        |
| -             | -:   | -:             | -:       |
| boot          | 6    | 1              | −5       |
| post_services | 25   | 1              | −24      |
| **steady (median n=5)** | **47** | **16** | **−31** (−66 %) |

Container-init's per-unit cgroup placement also means each of those
13 processes is in its own cgroup, individually killable via
`cgroup.kill` rather than the bash chain's coarse `pkill -P`.

## container-init's own cold start

Time from binary exec to `--validate` return (parses 23 units, runs
expansion + condition evaluation). Linux ARM64 stripped binary, run
inside the production image.

| Run | 1 | 2 | 3 | 4 | 5 |
| -   | -: | -: | -: | -: | -: |
| ms  | 1 | 1 | 1 | 1 | 1 |

Target: ≤10 ms. Actual: **1 ms**. Container-init's own overhead is
not on the TTFL critical path — measured as **2 ms from
`boot_start` to `supervisor_start`** in the live trace.

## Mid-flight unit-set fix landed during this measurement

The first noble-prod run hit a `kasmvnc.service` restart loop —
Xvnc rejected `-UnixRelay printer:/tmp/printer` with `Unrecognized
option`. Root cause: Phase 4.6's `printer.socket` and
`smartcard.socket` units bound `/tmp/printer` and `/tmp/smartcard`
via `ActivationMode=proxy`, racing Xvnc which expects to bind the
*same paths* itself (`-UnixRelay` makes Xvnc the *listener*, not a
client). The mental model was inverted: `kasm_printer_service` and
`kasm_smartcard_bridge` are clients of the relay socket Xvnc owns,
not servers behind it.

Fix:
- Deleted `units/printer.socket` and `units/smartcard.socket`.
- `printer.service` and `smartcard.service` now `After=kasmvnc.service
  Requires=kasmvnc.service` and connect to `/tmp/printer` /
  `/tmp/smartcard` directly (matching the bash chain's behaviour).
- Updated `internal/unit/units_corpus_test.go` to drop the deleted
  socket assertions.

After the fix, the same probe yielded one clean `kasmvnc.service`
spawn (no restart loop), and the steady-state numbers above.

## Mid-flight rename fix landed during 5.x.5

`kasm-os-user-rename`'s post-rename find sweep used plain `chown`
(no `-h`). Cursor "files" under `/usr/share/icons/capitaine-cursors/`
are symlinks; without `-h`, `chown` follows the link and chowns the
target, leaving the symlink itself at the old uid — and `find -uid`
keeps re-finding the symlinks. After rename to alice, 65 cursor
files (and a handful of other symlinks) remained at uid 1000,
breaking the 5.x.5 acceptance criterion `find / -mount -uid 1000 ==
empty`.

Fix: `find / -mount -uid 1000 -exec chown -h … +` and the matching
`-gid` sweep with `chgrp -h`. After the fix, the alice run reports
`count=0` for `find / -mount -uid 1000` on a fresh boot (no
post-boot manual sweep needed).

## 5.x.2 functional smoke

Three boots against `localhost/kasm-noble-phase5`, each soaked 18 s
before probing. Captured in `runs/noble/functional-smoke.log`.

| Run             | Path                                            | KasmVNC :6901 reachable | upload-server :4902 reachable | VNC-stack units running                |
| -               | -                                               | -:                      | -:                            | -                                      |
| `bash-vnc`      | bash, `KASM_VNC=1`                              | ✓ (TCP)                 | ✓ (HTTPS server replies 400)  | full XFCE + audio + helper stack       |
| `ci-vnc`        | container-init, `KASM_VNC=1`                    | ✓ (TCP)                 | ✓ (TCP; Go binary, no HTTP body within 1 s — different from bash chain's Python/Flask) | container-init + Xvnc + xfce4-session + ffmpeg + pcscd + pulseaudio + printer + smartcard (lazy helpers idle) |
| `ci-headless`   | container-init, `KASM_VNC=0`                    | NOT BOUND               | NOT BOUND                     | only container-init + dbus-daemon (Xvnc, xfce, audio, helpers all skipped) |

Container-init `KASM_VNC=0` correctly skips 20 units including
`kasmvnc.service`, `audio-*`, `gamepad`, `smartcard`, `printer`,
`upload`, `webcam`, `profile-*` — the headless mode contract holds.

## 5.x.5 KASM_OS_USER end-to-end smoke

Two boots against `localhost/kasm-noble-phase5` (rebuild includes
the `kasm-os-user-rename` `chown -h` fix landed below). Captured in
`runs/noble/os-user-smoke.log` and `runs/noble/osuser-{alice,default}.trace.jsonl`.

Run 1: `KASM_OS_USER=alice KASM_OS_UID=1500 KASM_OS_GID=1500 KASM_OS_HOME=/home/alice`.

- `id alice` → `uid=1500(alice) gid=1500(kasm-user) groups=1500(kasm-user)` ✓
- `/etc/passwd`: `alice:x:1500:1500::/home/alice:/bin/sh` ✓
- `/home/alice` populated (`.config`, `.cache`, `.vnc`, `Desktop`,
  `Documents`, `Downloads`, `Uploads`, `PDF`), all owned by `alice` ✓
- KasmVNC :6901 reachable ✓
- `find / -mount -uid 1000` → **count=0** (after `chown -h` fix) ✓
- `find / -mount -uid 1500` → 282 files, the expected set
  (kasmrx Downloads, profile nssdb, alice home tree, cursor symlinks)

Run 2: defaults — `id kasm-user` → `uid=1000(kasm-user) gid=1000(kasm-user)` ✓

### Quirks documented (5.x.5)

1. **GID name preserved as `kasm-user`.** With `KASM_OS_GID=1500` but
   no `KASM_OS_GROUP` override, `groupmod -g 1500 -n kasm-user
   kasm-user` only changes the gid; the group at gid 1500 remains
   named `kasm-user`. `id` correctly reports
   `gid=1500(kasm-user)` — this is by design (the rename script's
   default for `KASM_OS_GROUP` is `kasm-user`). Operators wanting a
   renamed group should set `KASM_OS_GROUP=alice`. Not a bug.

2. **`podman exec` requires `--workdir /` after rename.** The image's
   `WORKDIR=/home/kasm-default-profile` resolves at build time and
   later runtime ops on `kasm-user` HOME; once renamed, the container's
   WORKDIR `/home/kasm-user` no longer exists, so `podman exec` (which
   uses the image WORKDIR by default) fails with `chdir: No such
   file or directory`. Production callers (kasm-workspaces orchestrator
   et al.) typically pass an explicit cwd, so this is a test-side
   ergonomic only.

### Phase 4 bugs surfaced — out of scope for 5.x but tracked

- **`audio-out.service` priv-drop race when `KASM_OS_USER` differs
  from default.** Trace shows `audio-out.service` exits with
  `userdb: user "alice": not found` *before* `kasm-setup_invoke`
  fires. Root cause: `audio-out.service` had only
  `After=audio-out-ws.service`, and audio-out-ws is socket-activated
  (lazy), so audio-out had no eager dep blocking it from firing
  before kasm-setup ran the rename. Fix landed in this sweep —
  `units/audio-out.service` now includes
  `After=kasm-setup.service Requires=kasm-setup.service`. Other
  units with `User=${KASM_OS_USER}` were audited; they all reach
  `kasm-setup` transitively (via `kasmvnc.service` → `kasm-setup` or
  via `network-wait.service` → `kasm-setup`), so audio-out was the
  only outlier.

- **~~`audio-out-ws.service` restart loop~~ (FIXED in this sweep).**
  The first-pass diagnosis (auth token literal `kasm_user:default`
  vs `kasm_user:$VNC_PW`) was correct on the surface but masked a
  deeper bug: the kasm_audio_out-linux binary listens on **two**
  ports (`:8081` for MPEG-TS in, `:4901` for WebSocket out), and
  `audio-in.socket` had been mistakenly assigned to **`:4901`**,
  which collides — the binary exits with `EADDRINUSE :::4901` on
  every spawn, regardless of auth. The bash chain doesn't trip this
  because `kasm_audio_input_server` defaults to `:4904` and nothing
  occupies `:4901` until `kasm_audio_out-linux` runs.

  **Three landed fixes:**

  1. **`internal/unit/expand.go`** — added nested-`${…}` expansion
     via brace-depth tracking + recursive Expand. Tests now cover
     `${X:-${Y}}`, `${X:-${Y:-z}}`, two nested refs in one default,
     and outer-set short-circuit. Required so the audio token's
     fallback (`${KASM_AUDIO_AUTH:-${KASM_OS_USER:-kasm-user}:${VNC_PW}}`)
     resolves correctly.

  2. **`audio-in.socket`** — `ListenStream=4901` → `ListenStream=4904`,
     matching the bash chain's `kasm_audio_input_server` default
     port. Frees `:4901` for the WebSocket relay.

  3. **Audio auth token tracks `KASM_OS_USER`** — both
     `audio-out-ws.service` and `audio-in.service` defaults are now
     `${KASM_AUDIO_AUTH:-${KASM_OS_USER:-kasm-user}:${VNC_PW}}`.
     `kasm-setup`'s `kasmvncpasswd -u kasm_user` is now
     `kasmvncpasswd -u "$KASM_OS_USER"` (kasm_viewer kept literal —
     it's a role designator). Browser HTTP basic auth and the VNC
     `.kasmpasswd` record name now both follow the operator's chosen
     OS user, so the noVNC connect prompt accepts the same name.

  **Default-behavior change vs bash chain.** The bash chain's audio
  + VNC user was the literal string `kasm_user` (underscore). The
  OS user has always been `kasm-user` (hyphen). The new default
  unifies them on `kasm-user` — clients connecting *without*
  credentials passed by the Kasm orchestrator now need `kasm-user`
  instead of `kasm_user`. Orchestrated deployments pass the
  username explicitly per session, so they're unaffected.

  **After-fix verification (both noble + bookworm):**
  - `audio-out-ws.service`: spawns=1, failed_exits=0 (was 43+/43+
    in 25 s soak)
  - `audio-out.service`: spawns=1, failed_exits=0
  - Listeners `:4901` (WebSocket relay), `:4904` (audio-in.socket),
    `:8081`, `:14081`, `:4902`, `:4903` all bound cleanly
  - argv ends with `kasm-user:vncpassword` (was `kasm_user:default`)

## How to reproduce

```bash
# Build the production image (CONTAINER_INIT=1 path is opt-in via env).
podman build --platform=linux/arm64 \
    --build-arg BASE_IMAGE=ubuntu:24.04 \
    --build-arg DISTRO=ubuntu \
    --build-arg LANG=en_US.UTF-8 --build-arg LANGUAGE=en_US:en \
    --build-arg LC_ALL=en_US.UTF-8 \
    --build-arg START_PULSEAUDIO=1 --build-arg START_XFCE4=1 \
    --build-arg BG_IMG=bg_kasm.png --build-arg EXTRA_SH=noop.sh \
    -f dockerfile-kasm-core -t kasm-noble-phase5:latest .

# Median-of-5 dual-path probe (TTFL + cgmem + nproc).
N=5 SOAK=25 bash runs/noble-median-of-5.sh
# Outputs:
#   runs/noble/results.csv               — per-run TTFL trace/extern + cgmem + nproc
#   runs/noble/{ci,bash}-{1..5}.trace.jsonl
# Final lines print medians per path.

# 5.x.5 KASM_OS_USER end-to-end (rename + KasmVNC + uid sweep).
bash runs/noble-os-user-smoke.sh

# Functional smoke (KasmVNC reachable / KASM_VNC=0 / upload bound).
bash runs/noble-functional-smoke.sh
```

## Caveats

- Single-run numbers; Phase 5 5.x.2 should median-of-5 per distro.
- ARM64 host; x86_64 will land at slightly different absolute numbers
  but proportionally similar.
- No client connected. Lazy-helper savings shrink as soon as a real
  user session attaches and triggers socket activation for audio /
  upload / gamepad. The 230 MiB delta is the *idle warm-pool* gain;
  per-active-session steady-state is closer than these numbers
  suggest.
- `OnFailure=` chains and `ExitContainerOnFailure=true` units land
  identically under both paths (verified by probe-F shutdown timing).
