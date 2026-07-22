# Cold start performance and steady-state memory

Companion to `design/vnc-startup-replacement.md`. That document covers the structural
replacement of `vnc_startup.sh`. This one is narrower: where time and memory go in the
current path, and what to change to reduce both. Findings are evidence-driven (5-run
trace + boot log analysis); recommendations are grouped by independence so they can ship
out of order.

---

## Why

Two complaints, addressed separately:

a) **Time-to-first-launch feels slow.** The user perceives the gap between requesting a
   session and being able to interact with the desktop.

b) **Steady-state memory is high.** Enough that container density on a host is below
   what the workload would allow.

These are tracked together because the diagnostic path is the same (one instrumented
boot run gives both signals), but the fixes are mostly independent.

---

## What we measured

`src/common/startup_scripts/vnc_startup.sh` was patched with an opt-in trace
(`KASM_BOOT_TRACE=1`) that emits one JSON line per phase to
`/tmp/kasm-boot-trace.jsonl`. The patch is strictly additive — no existing behaviour,
including the `sleep 3` before the monitor loop, was removed. See the
"Trace instrumentation reference" section below for the directive list.

Phases captured:

- `boot_start` — anchor (UTC + epoch ms)
- `dbus_launch`, `network_wait`, `profile_pull`, `source_bashrc` — pre-cert setup
- `openssl_cert` — RSA-2048 self-signed cert generation
- `kasmvncpasswd` — password setup
- `kasmvnc_invoke` — wallclock cost of `start_kasmvnc` (synchronous part)
- `kasmvnc_port_open` — parallel waiter that records when `127.0.0.1:6901` first accepts a TCP connection
- `wm_invoke`, `wm_first_window` — same pattern for the WM (`_NET_SUPPORTING_WM_CHECK` set)
- `services_invoke` — total time spent invoking the audio/upload/gamepad/etc launchers
- `pre_monitor_sleep` — the hardcoded `sleep 3` before the supervisor loop
- `monitor_loop_entered` — supervisor loop start
- `mem_snapshot` records at: `boot`, `post_kasmvnc`, `post_services`, `steady_state_t+20s`,
  each containing cgroup `memory.current` / `memory.peak`, process count, and per-comm
  RSS breakdown via `ps -eo rss=,comm=`.

Environment for the runs documented here: arm64 macOS host, lima VM, podman 4.8.2,
image `docker.io/kasmweb/core-ubuntu-noble:1.18.0-rolling-daily` with the patched
script injected via a thin derived image. 5 runs each. No profile loader configured,
no egress gateway, no client connected. **Numbers will differ on x86_64, on bare
metal, and with different KASM_PROFILE_LDR / egress configurations.**

---

## Findings: timing

### Median per-phase dt (ms, 5 runs)

| Phase | Median | Notes |
|---|---|---|
| dbus_launch | 4 | negligible |
| network_wait | 2 | one-shot pass; would be much higher with egress |
| profile_pull | 1 | early-return (no profile loader configured) |
| source_bashrc | 2 | negligible |
| **openssl_cert** | **82** (max 253) | high variance, entropy/CPU sensitive |
| kasmvncpasswd | 3 | negligible |
| **kasmvnc_invoke** | **573** | dominated by perl wrapper + xdpyinfo poll loop |
| **kasmvnc_port_open** | **468** | listen socket up ~105ms before invoke returns |
| wm_invoke | 1 | XFCE backgrounded |
| wm_first_window | 221 | XFCE places its first window |
| services_invoke | 28 | all `&` forks; nothing blocks here |
| pre_monitor_sleep | 3003 | the hardcoded `sleep 3` |

### Time-from-boot to externally-meaningful events (ms)

| Event | Range | Median |
|---|---|---|
| KasmVNC TCP listening | 563 - 747 | ~580 |
| WM first window placed | 886 - 1069 | ~1000 |
| Supervisor loop entered | 3756 - 3907 | ~3800 |

### Where the 573ms in `kasmvnc_invoke` actually goes

`/usr/bin/vncserver` from KasmVNC is a 3119-line **Perl script**. The synchronous flow
inside `StartXvncOrExit` (vncserver:2773-2793) is:

```
ConstructXvncCmd  -> CheckSslCertReadable -> CheckBrowserHostDefined ->
DeleteLogLeftFromPreviousXvncRun -> StartXvncAndRecordPID -> WaitForXvncToRespond
```

`WaitForXvncToRespond` (vncserver:1131-1145):

```perl
my $sleepSlice = 0.1;        # 100ms
my $sleepLimit = 3;
until (IsXvncResponding() || $sleptFor >= $sleepLimit) {
    sleep($sleepSlice);
    $sleptFor += 0.1;
}
```

`IsXvncResponding()` is `xdpyinfo -display :1 >/dev/null 2>&1` — fork+exec a binary on
each iteration.

Decomposing the measured 573ms:

- Perl interpreter cold start + 3119-line parse: ~50-80ms
- Option parsing + dependency probes (`uname`, `xauth`, `hostname`, `whoami` via
  `system()` at vncserver:482), font-path detection, xauth setup: ~80-150ms
- Xvnc fork (instant, backgrounded)
- **WaitForXvncToRespond polling** (100ms-resolution, plus xdpyinfo fork-exec per
  iteration; Xvnc is ready before the first poll completes): **~250-400ms**
- Trailing prints: ~10ms

The TCP listen socket inside Xvnc binds at ~470ms — well before xdpyinfo can succeed
(xdpyinfo requires the X server fully initialized). That gap is why
`kasmvnc_port_open` (468ms) detects a listening socket ~105ms before
`kasmvnc_invoke` returns (573ms).

### Implications for the critical path

- The `sleep 3` before the supervisor loop is **not** on the TTFL path. KasmVNC has
  been listening for ~2.3s by the time the supervisor enters its loop. Removing the
  sleep would only tighten first-crash-detect from t≈3.8s to t≈0.8s. The user is
  correct that delays usually exist for a reason; this one is a "give services time
  to settle so the first `kill -0` doesn't trigger spurious restarts" heuristic and
  should be replaced with explicit per-service readiness probes, not deleted blind.
- `openssl_cert` is the only pre-listen synchronous cost above ~10ms.
- Once `kasmvnc_invoke` returns, the rest of the path (WM + helpers) happens in
  parallel via `&` and does not block TTFL.

### Realistic latency floor

| Change | Saving | Cumulative TTFL |
|---|---|---|
| Today | — | **~580ms** |
| Bake openssl cert at image build time | -82ms median, -250ms tail | ~500ms |
| `container-init` execs `Xvnc` directly with the same arg vector (skip the perl wrapper) | -50ms perl + -200ms xdpyinfo polling slop | **~250-300ms** |
| Use `inotify` on `/tmp/.X11-unix/` instead of polling xdpyinfo | further tightens the readiness wait | ~250-280ms |
| ~~Pre-cached xkbcomp output baked into the image~~ | *removed during Phase 1 execution: KasmVNC's Xvnc does not write `/var/lib/xkb/server-*.xkm`, so there is nothing to pre-cache* | n/a |

**Sub-100ms TTFL is unrealistic without modifying Xvnc itself** (lazy extension
loading, deferred framebuffer alloc). The "exec Xvnc directly from container-init" change
is the largest single lever and is purely on our side (shipped as `kasm-xvnc`;
see `design/kasm-xvnc-perl-bypass.md`) — the perl wrapper builds an
argv vector that we can build identically.

---

## Findings: memory

### Cgroup memory at each checkpoint (MiB, 5-run median)

| Checkpoint | memory.current | nproc |
|---|---|---|
| boot | 3 | 5 |
| post_kasmvnc | 23 | 14 |
| post_services | 55 | 19-21 |
| **steady_state t+20s** | **566** | 53 |

10× growth from `post_services` to `steady_state_t+20s` is XFCE applet wake-up plus
demand-paged code, not Kasm services.

### Top RSS contributors at steady state (KiB, single representative run)

| Process | RSS | Category |
|---|---|---|
| xfce4-session | 80636 | XFCE |
| Xvnc | 80496 | KasmVNC |
| kasm_upload_server | 47492 | Kasm helper (Python/Flask) |
| xfdesktop | 47380 | XFCE |
| ffmpeg | 46176 | audio out |
| xfce4-panel | 40836 | XFCE |
| xfwm4 | 39884 | XFCE |
| kasm_audio_out | 37676 | audio out |
| kasm_gamepad_server | 33964 | Kasm helper (rarely used) |
| kasm_audio_input | 31456 | audio in |
| nm-applet | 28588 | XFCE autostart (broken) |
| xfsettingsd | 27780 | XFCE |
| kasm_printer_service | 27060 | Kasm helper (rarely used) |
| tumblerd | 24808 | XFCE autostart |
| panel-2-systray | 24020 | XFCE plugin |
| Thunar | 23768 | XFCE |
| kasm_smartcard_bridge | 18940 | Kasm helper (rarely used; busy-loops) |
| xfce4-notifyd | 18536 | XFCE |
| pulseaudio | 12036 | audio |

Sum-of-RSS ≈ 660 MiB; cgroup `memory.current` is 566 MiB because shared mappings are
counted once at the cgroup level.

---

## Findings: boot log artifacts

Captured from `podman logs` of a single instrumented boot. These are the issues that
are not visible in the JSON trace.

### `/tmp/.ICE-unix` create failure

```
_IceTransmkdir: ERROR: euid != 0,directory /tmp/.ICE-unix will not be created.
```

Container runs as UID 1000; `/tmp/.ICE-unix` does not pre-exist; non-root cannot
create it. Fix at image build time, not at startup.

### XFCE autostart applets fail-but-stay-running

In a Kasm-style container there is no system D-Bus and no NetworkManager, so the
following XFCE autostarts fail their backend init then idle holding RAM:

- `xfsettingsd` — `libupower-glib WARNING: Couldn't connect to proxy`
- `polkit-gnome-authentication-agent-1` — `Error getting authority`
- `xiccd` — `Failed to connect to colord: Could not connect`
- `system-config-printer-applet` — `failed to connect to system D-Bus`
- `nm-applet` — 9 consecutive `nm-CRITICAL` assertions; **28 MiB RSS for nothing**
- `xfdesktop` partially — `Failed to get system bus`, `remote volume monitor not supported`

Combined waste: estimated 50-80 MiB at steady state, and they contribute to the boot
log noise that obscures real errors.

### Smartcard bridge is not idle — it busy-loops

```
2026-05-03 11:46:54 ERROR - bridge->relay: timeout: 0x01
2026-05-03 11:47:01 ERROR - bridge->relay: timeout: 0x01
2026-05-03 11:47:09 ERROR - bridge->relay: timeout: 0x01
```

Every ~7.5s for the lifetime of the container, in any session that doesn't use a
smartcard. The process runs a network call, times out, retries forever. This is one
piece of evidence for why **socket activation is not just a memory optimisation** —
it removes ongoing CPU/log waste from helpers that are pre-started but unused.

### Gamepad server logs 4 errors then idles

```
ERROR:KasmGamepadServer:Failed to connect input (/dev/input/event0) : No such file ...
ERROR:KasmGamepadServer:Failed to connect input (/dev/input/event1) : No such file ...
... (event2, event3 same)
```

Same pattern as smartcard.

### kasm_upload_server is Flask `app.run()` (werkzeug dev server)

```
service.py:79: DeprecationWarning: There is no current event loop
 * Serving Flask app 'kasm_upload_server'
 * Debug mode: off
WARNING: This is a development server. Do not use it in a production deployment.
 * Running on https://127.0.0.1:4902
```

Inspecting the binary inside the image:

```
/dockerstartup/upload_server/kasm_upload_server: ELF 64-bit LSB executable, ARM aarch64,
  statically linked, stripped
27M
```

The "statically linked" claim plus the 27 MB size plus the Flask startup banner
indicate **PyInstaller-bundled Python + Flask**. The "development server" warning is
technically misleading for a single-uploader workload (werkzeug handles one user
fine), but the runtime cost is real:

- 47 MiB RSS just for the Python interpreter + Flask
- 200-500ms cold start (PyInstaller extracts to `/tmp/_MEI*`, then imports Flask)
- Single-threaded by default

Same Python signature appears in printer (`INFO:KasmPrintingService`), gamepad
(`ERROR:KasmGamepadServer`), and smartcard (`INFO - bridge: starting`). All four
helpers are likely on the same Python+packaging stack.

### xkbcomp warns about unknown keysyms every boot

```
> Warning:          Could not resolve keysym XF86ClearvuSonar
> Warning:          Could not resolve keysym XF86SidevuSonar
> Warning:          Could not resolve keysym XF86NavInfo
```

Cosmetic, but a signal that the keymap is **recompiled at every Xvnc startup** rather
than served from a cached `.xkm`. Pre-compiling at image build is a real (small)
latency win and removes the warnings.

---

## Recommendations

Grouped by independence so they can ship out of order.

### Workstream 1 — Image-build cleanup (no shim required, ship today)

These are pure Dockerfile / autostart changes. Do not depend on `container-init`.

1. **Bake the SSL cert at image build time.** Generate `self-default.pem` once during
   the image build, copy/symlink to `~/.vnc/self.pem` at startup. Provide override
   mechanism (env var pointing to a mounted cert) for deployments that want a real
   cert. Saves 82-253ms per cold start.
2. **Pre-create `/tmp/.ICE-unix` at build time** with mode `1777`. Removes the
   `_IceTransmkdir` error.
3. ~~**Pre-compile xkbcomp output** to `/var/lib/xkb/server-*.xkm` at image build.~~
   *Removed during Phase 1 execution (2026-05-03).* Verified empirically on
   Ubuntu Noble: KasmVNC's Xvnc (1.4.1 in `core-ubuntu-noble:1.18.0-rolling-daily`)
   does not write the xorg-server `XkmOutputDir` cache — `find /` while Xvnc
   is running shows zero `.xkm` files on the filesystem. There is no path the
   pre-compiled output could occupy that Xvnc would consume; the recommendation
   was based on vanilla X.org behavior that this build doesn't exhibit.
   Eliminating xkbcomp's cost would require a KasmVNC source change, which is
   off-protocol for the current sequence.
4. **Trim XFCE autostart of broken applets.** Remove or disable:
   - `nm-applet.desktop`
   - `polkit-gnome-authentication-agent-1.desktop`
   - `xiccd.desktop`
   - `system-config-printer.desktop`
   - `gvfs-*-volume-monitor.desktop` (gated; some deployments may want gvfs for
     Thunar, so provide an env knob)
   Measured saving on Ubuntu Noble (Phase 1.4 execution, 2026-05-03):
   ~67 MiB sum-of-per-process RSS, ~13 MiB cgroup `memory.current`
   (the gap is shared-library accounting — removed processes share libc /
   libglib / libgtk mappings with surviving XFCE core), ~7 fewer
   processes, zero broken-applet boot-log lines. The original 100-130 MiB
   figure was an over-estimate based on per-process RSS; cgroup-level
   savings of that magnitude require Phase 3 + Phase 4 (kasm-upload-server
   rewrite, lazy helpers).

**Expected combined effect (1.1, 1.2, 1.4): ~80-250ms TTFL improvement (cert
bake), ~100-130 MiB RSS reduction (autostart trim).**

### Workstream 2 — `container-init` Go shim with first-class socket activation

Already designed in `vnc-startup-replacement.md`. Lives in this repo at
`src/common/container-init/` (binary `cmd/container-init`). The boot-log
evidence here extends that design with two confirmed requirements:

1. **Socket activation is in scope from day one,** not a follow-up. The smartcard
   busy-loop is concrete evidence that "lazy" is not just about RSS — it removes
   CPU and log noise. Without socket activation the helpers stay broken-but-running,
   which is what we have today.
2. **`.socket` units alongside `.service` units** in the unit-file subset. Directive
   list to add to the supported subset:
   - `[Socket]`: `ListenStream=`, `ListenDatagram=`, `Accept=` (default `no`),
     `SocketUser=`, `SocketGroup=`, `SocketMode=`, `Service=`,
     `ActivationMode=` (`native` | `proxy`),
     `ProxyTarget=`
   - `[Install]`: `WantedBy=sockets.target`

#### Shim implementation outline

For each `.socket` unit at boot:
- `socket(2)` + `bind(2)` + `listen(2)` on the configured address. Cheap, kernel-only.
- `epoll_wait` on the resulting fds.
- On readability of fd S whose service is not running: fork+exec the service with
  - `LISTEN_FDS=N` env
  - `LISTEN_PID=<child pid>` env
  - `LISTEN_FDNAMES=...` env (optional)
  - The listening fds inherited as fds 3..3+N, with `FD_CLOEXEC` cleared
- After spawn, the shim removes the fd from its epoll set (the service owns it).
- Restart=, OnFailure=, etc. apply to the service exactly as for an eagerly-started
  unit.

#### Native vs proxy activation

All work stays in this repo. We do not modify helper source in other
repos. Two activation modes cover this:

**Native mode** is used by helpers we own (the Go `kasm-upload-server`
we ship from `src/common/container-init/cmd/kasm-upload-server/`). The
helper consumes `LISTEN_PID` / `LISTEN_FDS` and uses the inherited
listening fd 3 directly:

```go
func listen(defaultAddr string) net.Listener {
    if pid, _ := strconv.Atoi(os.Getenv("LISTEN_PID")); pid == os.Getpid() {
        n, _ := strconv.Atoi(os.Getenv("LISTEN_FDS"))
        if n > 0 {
            f := os.NewFile(3, "listen")
            l, _ := net.FileListener(f)
            return l
        }
    }
    l, _ := net.Listen("tcp", defaultAddr)
    return l
}
```

**Proxy mode** is used by helpers we install as PyInstaller bundles from
S3 (printer, gamepad, smartcard, audio_in, audio_out_websocket, webcam).
Container-init binds the public socket itself; on first connect it
starts the helper on a private endpoint
(e.g. `tcp:127.0.0.1:14902` or `unix:/tmp/printer.real`) and proxies
bytes between the accepted public connection and the helper's private
endpoint. Subsequent connections reuse the running helper. The Python
helpers are not modified.

The proxy hop is a single in-process byte copy; for these helpers
(intermittent, low-throughput) the overhead is unmeasurable. As helpers
get Go-rewritten in this repo over time (out of scope for the current
sequence), they migrate from proxy mode to native mode unit-by-unit.

#### Mapping per helper

| Helper | Public listen | Mode | Notes |
|---|---|---|---|
| `kasm-upload-server` (Go, this repo) | tcp 4902 | native | replaces Flask binary |
| `kasm_audio_out-linux` | tcp 8081 | proxy | helper unchanged |
| `kasm_audio_input_server` | tcp (default) | proxy | helper unchanged |
| `kasm_gamepad_server` | tcp (default) | proxy | helper unchanged |
| `kasm_webcam_server` | tcp 4905 | proxy | gated on `/dev/video0` |
| `kasm_printer_service` | unix `/tmp/printer` | proxy | helper unchanged |
| `kasm_smartcard_bridge` | unix `/tmp/smartcard` | proxy | helper unchanged |
| `pcscd` | varies | n/a | eager start (no listen socket) |

For printer + smartcard, KasmVNC's existing `-UnixRelay` config in
`src/common/install/kasm_vnc/kasmvnc.yaml` already proxies websocket connections to
local Unix sockets. The shim creating those Unix sockets in listening state is
client-invisible.

#### Cold-start latency for activated helpers

Order-of-magnitude cold start on this host:

- Go helper, statically linked: 30-100ms
- Python via PyInstaller (today's pattern): 200-500ms

For features triggered by deliberate user actions (upload click, gamepad connect,
smartcard insert) 50-200ms first-use latency is invisible. KasmVNC's noVNC websocket
relay queues bytes during the brief connect window. **For Python helpers that stay on
the Python stack, prefer keeping a small idle process (the current model) rather
than activating cold.** This is exactly why workstream 3 matters.

### Workstream 3 — Rewrite `kasm_upload_server` in Go

Lives in this repo at
`src/common/container-init/cmd/kasm-upload-server/`. Shares the
`internal/socketact/` package with container-init for the
`sd_listen_fds` plumbing. Independent of the shim core; ships when ready.

#### Comparison

| | Today (PyInstaller + Flask) | Nuitka | Go |
|---|---|---|---|
| Binary size | 27 MB | ~15-25 MB | 5-8 MB static |
| Cold start | 200-500ms | 100-300ms | 5-15ms |
| Steady RSS | 47 MiB | 30-40 MiB | 5-10 MiB |
| Concurrency | werkzeug dev server, single-threaded | same | `net/http` handles N trivially |
| FD inheritance | possible but awkward | possible but awkward | `os.NewFile` + `net.FileListener` |
| Maintenance | Flask + 30 deps + PyInstaller pipeline | + Nuitka build chain | stdlib only |

#### Why Go beats nuitka for this specific service

- The Werkzeug "development server" warning is technically harmless for Kasm's
  single-uploader workload. The reasons to rewrite are **cold-start latency** (which
  matters once we socket-activate) and **RSS** (47 → ~6 MiB), plus removing one
  Python build pipeline from the image.
- The functional surface is small: HTTPS POST with multipart body + shared-token
  auth + write to `--upload_dir`. Estimated ~150 lines of Go using `net/http`, plus
  ~20 lines for fd inheritance. Weekend-sized, not a sprint.

#### Other Python helpers stay as PyInstaller bundles for now

- `kasm_printer_service` (Python — `INFO:KasmPrintingService:`)
- `kasm_gamepad_server` (Python — `ERROR:KasmGamepadServer:`)
- `kasm_smartcard_bridge` (Python — `INFO - bridge: starting`)
- `kasm_audio_input_server`, `kasm_audio_out-linux`, `kasm_webcam_server`
  (language varies)

These run via container-init's proxy-mode socket activation. Their RSS is
paid only when the feature is in use. Rewriting them in Go is out of
scope for this sequence -- see
`design/work_sequence.md` "Out of scope".

---

## Suggested order of work

This document captures *findings*. The execution sequence with explicit
phases, completion criteria, and out-of-scope items is in
`design/work_sequence.md` and is the source of truth for what we are
doing and in what order.

---

## Trace instrumentation reference

The instrumentation lives in
`src/common/startup_scripts/vnc_startup.sh`, gated on `KASM_BOOT_TRACE=1` (default
off). Output path: `${KASM_BOOT_TRACE_FILE:-/tmp/kasm-boot-trace.jsonl}`.

Each line is a self-contained JSON record:

```json
{"phase":"<name>","t_start_ms":<epoch_ms>,"dt_ms":<int>,"status":"ok"}
```

Memory snapshot records also include `cgroup_current_bytes`, `cgroup_peak_bytes`,
`cgroup_swap_bytes`, `nproc`, `rss_sum_bytes`, `by_comm` (array of `{comm, rss_kib}`).

Properties:
- `set -e` safe; every trace function returns 0.
- No new runtime dependencies. `xprop` is optional; if absent, `wm_first_window`
  records `timeout` rather than failing.
- Background waiters write their own records when satisfied; the main script does not
  block on them.
- `EPOCHREALTIME` used for ms precision (bash ≥5); falls back to `date +%s%3N`.

How to run:

```bash
podman run -e KASM_BOOT_TRACE=1 ... <core-image>
podman exec <id> cat /tmp/kasm-boot-trace.jsonl
```

Aggregate across runs:

```bash
jq -s 'sort_by(.t_start_ms)' /path/to/runs/*.jsonl
```

---

## Caveats on the numbers

- Single host — arm64 macOS lima → podman 4.8.2 → ubuntu-noble guest. x86_64 native,
  bare-metal ARM, and smolvm will differ. `openssl_cert` in particular is entropy and
  CPU sensitive.
- No profile loader. With `KASM_PROFILE_LDR=1` or `2`, `profile_pull` becomes the
  dominant phase and the `sleep 3` inside it is on the critical path.
- No egress gateway. With egress, `wait_for_network_devices` blocks until
  `/dockerstartup/.egress_status` exists.
- No client connected. Once a noVNC client attaches, encoder buffers expand; steady
  state will be higher.
- Single image (`core-ubuntu-noble`). Other distros, especially Alpine, will look
  different — bash variant, available xprop, etc.

A useful next measurement is a comparison pass with `KASM_PROFILE_LDR=1` against a
stub profile endpoint. Schedule alongside the spike.
