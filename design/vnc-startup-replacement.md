# vnc_startup.sh Replacement

Status: design proposal, pre-spike. Author: investigation captured 2026-05-03.

> The perl `vncserver` bypass sketched under "Mapping vnc_startup.sh to
> units" shipped as `kasm-xvnc`; its full write-up — including the
> configurability-parity analysis and the argv re-capture procedure for
> KasmVNC bumps — is `design/kasm-xvnc-perl-bypass.md`.

## Why

`src/common/startup_scripts/vnc_startup.sh` is a 743-line bash script that
serves as the de-facto container init for every Kasm core image. It does
network waiting, profile sync, cert generation, password setup, then launches
~12 services as background jobs and runs an infinite monitor loop that decides
per-service whether to restart or exit the container on death.

Concrete pain points that motivate replacing it:

- **Not extensible.** Adding a service is three coupled edits to the same file
  (a `start_x` function, a launch-phase line, a `case` arm in the monitor
  loop). Image-author / customer extension is one ungoverned hook
  (`/dockerstartup/custom_startup.sh`) with no ordering, no gating, no restart
  policy.
- **Cross-service rules live in `case` arms.** "If window manager dies and the
  recorder is running, drain the recorder then exit the container" is
  expressed as bash inside the monitor loop. So is "if KasmVNC dies and
  `KASMVNC_AUTO_RECOVER=false`, exit." So is "if DLP fail-secure, exit on any
  death." These belong in declarative config.
- **Restart logic is partial.** The monitor loop has TODO comments admitting
  audio_in / gamepad / upload auto-restart "needs work in python project" and
  is silently broken. There is no central restart policy; each service is
  hand-coded.
- **No observability story.** All output goes to one `vnc_startup.log` (set
  -x). Per-service status, last-failure reason, restart counters: none exist.
- **Fragile shutdown.** The `cleanup` trap is `kill -s SIGTERM $!; exit 0` --
  signals exactly one PID (the most recently backgrounded one) and does not
  invoke any of the per-service cleanup that would matter for graceful drain.

## Framing

We are *not* trying to be systemd-compatible. We are not adopting systemd, not
adopting `gdraheim/docker-systemctl-replacement`, not running real systemd as
PID 1.

We are replacing the bash with a **purpose-built Kasm container init that
reads systemd unit files** as its config format. The unit-file syntax was
chosen because it is familiar to the ops audience, has a well-understood
mental model, and is a strict superset of what we need. We define a fixed
subset; everything outside the subset is a parse-time warning (or fail-fast,
configurable).

The bug-surface comparison is **bash today vs Container-init tomorrow**. It is not
"Container-init vs systemd spec coverage." We are not absorbing systemd's edge
cases; we are replacing 743 lines of bash with a smaller, declarative,
testable equivalent.

## What we ruled out

- **Real systemd as PID 1** (e.g. `j8r/dockerfiles/systemd` style). Requires
  cgroup mounts and effectively privileged or sysbox runtimes. Kasm runs in
  unprivileged docker/podman, k8s without privileges, and smolvm. Real
  systemd was never a candidate for those. (The repo's existing
  `src/ubuntu/install/sysbox/install_systemd.sh` *does* use real systemd, but
  only on sysbox runtimes -- it remains relevant only for that path.)
- **gdraheim/docker-systemctl-replacement.** Useful as a feasibility probe
  (see below). Rejected for shipping because: (1) `OnFailure=` is silently
  ignored -- zero references in 7333 lines, validated empirically; (2) start
  is strictly sequential (`for unit in sorted_after(...)`); (3) Python runtime
  dependency; (4) we would still own our extensions
  (`ExitContainerOnFailure`, `ActivationMode`, `ProxyTarget`) bolted on
  top of someone else's interpreter.
- **s6-overlay / runit / tini / dumb-init.** Either too minimal (no
  unit-file-style declarative config) or unfamiliar enough that the
  familiarity argument that motivated unit-file syntax does not apply.
- **Inventing a Kasm-native YAML / TOML format.** No upside over systemd unit
  syntax; loses the familiarity argument.

## What we ruled in: a small Go binary as PID 1

Implementation language: **Go.** Native binary, fast cold start (<10ms vs
~230ms for the Python equivalent), zero runtime deps (statically linked,
multi-arch trivial), goroutine-per-service maps naturally to parallel
supervision, signal handling and zombie reaping are stdlib. Drops Python from
all non-Alpine images entirely.

We use `github.com/coreos/go-systemd/v22/unit` (Apache-2) for unit-file
parsing -- we do not write a parser from scratch.

### container-init is a universal binary, not a Kasm-specific one

The binary, its directive set, its env vars, its trace plumbing, and its
on-disk layout (`/etc/container-init/units/*`,
`/etc/container-init.d/*`) are all **generic**. Nothing inside
`src/common/container-init/` is image-specific. The Kasm-specific things
are the **content** the image installs: the unit files
(`kasmvnc.service`, `kasm-setup.service`, …), the `kasm-upload-server`
binary, and the values in those units (Kasm env vars, Kasm paths, Kasm
binaries to ExecStart). That separation is deliberate: container-init is
reusable; the Kasm unit set is one consumer of it.

This means:

- Directive names are not Kasm-prefixed. `ExitContainerOnFailure`,
  `ActivationMode`, `ProxyTarget` are container-init's own directives,
  not "Kasm extensions."
- Env vars that gate container-init's behaviour use the
  `CONTAINER_INIT_*` prefix (`CONTAINER_INIT_TRACE`,
  `CONTAINER_INIT_TRACE_FILE`).
- Default paths use the binary name
  (`/tmp/container-init-trace.jsonl`,
  `/etc/container-init/units/`).
- Where Kasm wants A/B parity with the bash trace, the *image* (not the
  binary) configures container-init's trace path/env to match. The
  binary stays generic.

### Repository layout

All Go code we write for this work lives in this repo. Helpers we
rewrite in Go also live here. The only external-repo work is KasmVNC; if
we discover during execution that we need a KasmVNC source change, we
branch `/Users/emrul/dev/kasm/gitlab/KasmVNC` and open a draft merge
request. None are anticipated by the current sequence.

```
src/common/container-init/
  go.mod
  cmd/
    container-init/main.go        # the PID 1 supervisor binary
    kasm-upload-server/main.go    # Go rewrite of kasm_upload_server
  internal/
    unit/                         # unit-file parser + Kasm-subset validator
    supervisor/                   # goroutine-per-service supervision
    socketact/                    # socket activation (native + proxy modes)
    pid1/                         # zombie reaping, signal forwarding, reverse shutdown
    trace/                        # JSONL boot-trace emission (matches vnc_startup.sh)
  units/                          # the Kasm unit set (.service / .socket files)
  Makefile
  README.md
```

Image-build install paths:

- Binary: `/usr/bin/container-init`
- Unit set: `/etc/container-init/units/*.{service,socket}`
- Author drop-in: `/etc/container-init.d/*.{service,socket}` -- the
  primary extension point for base images (chrome, firefox, vscode,
  etc.) that layer on top of core. Drop-ins go through the same parser
  and validator as the core unit set, can reference core units via
  `After=` / `Requires=` / `OnFailure=`, and override core units when
  named identically. The contract is documented as a Phase 4.7
  deliverable in `design/work_sequence.md`.

## Validation evidence

Built `ubuntu:24.04 + python3 + procps + systemctl3.py 1.7.1076` rootless,
ran four probes in podman 5.7.1 to test the two open questions from the
boot-sequence audit:

### Conditional units -- works natively in any unit-file interpreter

`ConditionPathExists=/dev/video0` and `ConditionEnvironment=KASM_SVC_X=1` both
cause units to be skipped cleanly when conditions are unmet. This is an
unconditional yes; it carries forward to our Go implementation.

### Cross-service rule (window-manager + recorder)

Three approaches tested against systemctl3.py:

1. `OnFailure=other.service` -- silently ignored. Zero source references.
2. `ExecStopPost=` -- runs only on initial-start-failure (line 4135) or
   explicit stop (line 4660), **does not fire between Restart= cycles**.
   Verified empirically.
3. Wrap `ExecStart` with a shell script that, after the real command exits,
   either `exit 1` (lets `Restart=on-failure` restart it) or `kill -TERM 1`
   (init breaks the loop and runs reverse shutdown). **Works.** Container
   exits cleanly at ~9s when the rule fires (probe D); restarts the unit
   indefinitely when it does not (probe E).

Note that `kill -QUIT 1` is wrong: SIGQUIT only switches the init loop into
"exit when no procs left" mode (systemctl3.py line 6643), it does not
break out. SIGTERM/SIGINT do (line 6648).

In our Go implementation, `OnFailure=` becomes a first-class directive, and
the cross-service rule becomes a `ExitContainerOnFailure=true` flag --
the wrapper-script hack disappears.

### Socket activation (added after cold-start audit)

Beyond the WM/recorder cross-service rule, the second non-trivial primitive
the design needs is **socket activation**, driven by evidence in
`design/cold-start-perf-and-memory.md`:

- 5 helpers (gamepad, smartcard, printer, audio_in, webcam) start eagerly
  but go unused in most sessions. ~115 MiB of ambient RSS for nothing.
- The smartcard bridge isn't even idle -- it busy-loops on a 7.5s retry
  cycle for the lifetime of the container. Socket activation removes the
  busy-loop entirely.
- Some helpers exit with errors when the device is missing (gamepad on
  `/dev/input/event*`, webcam on `/dev/video0`). `ConditionPathExists=`
  helps but is a one-shot check at boot; socket activation gives us
  start-on-demand semantics that match how the noVNC client triggers the
  feature.

#### Two activation modes

Container-init supports both:

1. **Native** -- binds the listen socket, on first read fork+exec the
   service with the listening fd inherited as fd 3 plus
   `LISTEN_PID`/`LISTEN_FDS` env. The service uses the inherited fd
   instead of calling `Listen()` itself. Used for binaries we own (the Go
   `kasm-upload-server` we ship in this repo, plus any future Go
   rewrites). Standard `sd_listen_fds` protocol.
2. **Proxy** -- binds the public listen socket itself. On first read,
   accepts the connection and starts the helper on a private endpoint
   (e.g. `tcp:127.0.0.1:14902` or `unix:/tmp/printer.real`), then proxies
   bytes between the accepted public connection and the helper's private
   endpoint. Subsequent connections reuse the running helper. Used for
   binaries we do not modify (Python helpers shipped as PyInstaller
   bundles).

Mode is selected per-unit via a directive in `[Socket]`:
`ActivationMode=native|proxy` (default `native`). Native units declare
just `ListenStream=`; proxy units additionally declare `ProxyTarget=`
(the private endpoint container-init will start the helper on). Both
directives are part of container-init's API; they are not in real
systemd, which only does native activation.

This pair gives us full lazy startup without ever needing to modify code
outside this repo. The proxy hop adds an in-process byte copy, which is
negligible for these helpers (intermittent, low-throughput).

Validation needed: **probe F -- socket-activated unit cold-starts on first
connect, restarts under `Restart=on-failure`, respects
`ConditionEnvironment=`** (so a `smartcard.socket` unit stays unbound when
`KASM_SVC_SMARTCARD=0`). Run during the spike. Both native and proxy
modes are exercised.

### Sequential start

Confirmed in source: `start_units` is `for unit in sorted_after(units):
start_unit(unit)`. No parallelism. The bash today already parallel-starts via
`&` -- the cold-start trace measures total `services_invoke` time at **28-46ms**
for all 11 helpers (see `design/cold-start-perf-and-memory.md`). So the
gdraheim sequential cost is bounded but not the headline win.

The container-init differentiator vs gdraheim is **correctness** (real `Restart=`,
real `OnFailure=`, socket activation), not raw boot speed. Our Go
implementation supervises units with one goroutine each, so the
sequential-start issue does not arise -- independent units start in parallel
by default. Frame the sales pitch around correctness, not parallel start.

## Supported directive subset (the API)

This is the contract. Unit files outside this subset get a parse-time warning
or fail-fast (configurable). The subset is fixed; growth is a deliberate
product decision, not an organic drift.

```
[Unit]
  Description
  After
  Before
  Requires
  Wants
  ConditionPathExists
  ConditionPathExistsGlob
  ConditionEnvironment
  OnFailure                       # vanilla systemd semantics

[Service]
  Type                            # simple | oneshot | forking
  ExecStart
  ExecStartPre
  ExecStop
  ExecStopPost
  Restart                         # no | on-failure | always
  RestartSec
  StartLimitBurst
  StartLimitIntervalSec
  EnvironmentFile
  Environment
  User                            # accepts ${VAR} / ${VAR:-default}
                                  # expansion -- see "Env-var expansion"
                                  # below
  Group                           # same expansion as User
  WorkingDirectory                # same expansion as User
  KillSignal
  TimeoutStartSec
  TimeoutStopSec
  RemainAfterExit
  PIDFile

  ExitContainerOnFailure          # if true, on unit failure (after Restart=
                                  # is exhausted or skipped), init sends
                                  # SIGTERM to PID 1 and the container exits
                                  # via reverse shutdown. Beyond systemd.

[Socket]                          # added after cold-start audit
  ListenStream                    # tcp port or AF_UNIX path
  ListenDatagram                  # for completeness
  Accept                          # default no -- pass listen fd via sd_listen_fds
  SocketUser
  SocketGroup
  SocketMode                      # AF_UNIX permissions
  Service                         # which .service to activate

  ActivationMode                  # native (default) | proxy. Beyond systemd.
  ProxyTarget                     # private endpoint to start the helper on
                                  # when ActivationMode=proxy. Beyond systemd.

[Install]
  WantedBy                        # multi-user.target | sockets.target
```

Specifier expansion: only `%n` (unit name), `%N` (unit name without
extension), `%H` (hostname). No `%i`, no `%f`, no template units.

Env-var expansion: directive *values* (right-hand side of `=`) accept
`${VAR}` and `${VAR:-default}` forms, resolved at unit-load time
against `container-init`'s process environment. This is what lets
`User=${KASM_OS_USER:-kasm-user}`,
`Group=${KASM_OS_GROUP:-kasm-user}`,
`WorkingDirectory=${KASM_OS_HOME:-/home/kasm-user}` (and equivalent
`SocketUser=`/`SocketGroup=`) flow through to whatever value
`kasm-setup.service` set up at boot — see the configurable-OS-user
work item in `design/work_sequence.md`.

EnvironmentFile parsing: matches systemd's quoting rules (single/double
quotes, line continuations, `#` comments). This is the one place we cannot
cut corners -- existing operator scripts depend on the exact semantics.

## Mapping vnc_startup.sh to units

Sketch -- final form pending the spike.

`kasmvnc.service` execs `Xvnc` directly, **bypassing the 3119-line perl
`vncserver` wrapper**. The wrapper accounts for ~250-300ms of the measured
573ms `kasmvnc_invoke` time (perl startup + xdpyinfo poll loop --
see `design/cold-start-perf-and-memory.md`). Constructing the same argv
that the perl `ConstructXvncCmd` builds is on our side, not KasmVNC's. With
direct exec, `kasmvnc.service` is `Type=simple` -- the `Type=forking` open
question (was: line 316) is resolved.

### Top-level kill switches

Two `ConditionEnvironment=` flags carry through the unit set, both
default-on (omit or set to `1` for current behaviour; set to `0` to
take the unit out of the boot loop):

- `KASM_VNC=1` — gates `kasmvnc.service` and every unit that depends on
  it (window-manager, audio-*, upload, gamepad, webcam, printer,
  pcscd, smartcard, recorder-*). `KASM_VNC=0` produces a headless
  container that boots `kasm-setup` → `network-wait` → optional
  `profile-pull` → idle, with custom workloads driven by drop-ins from
  `/etc/container-init.d/`. Steady-state RSS ~30 MiB instead of
  ~350 MiB.
- `KASM_PROFILE_PULL=1` — gates `profile-pull.service` and
  `profile-size-check.service`. `KASM_PROFILE_PULL=0` removes profile
  loading from the boot path entirely. `KASM_PROFILE_LDR` continues to
  select loader v0/v1/v2 *when the pull is enabled*; the new flag is
  the orthogonal "do we run it at all at boot" switch, intended as the
  kill switch ahead of a separate profile-pull refactor.

For brevity these conditions are not repeated in every line of the
sketch below; assume `ConditionEnvironment=KASM_VNC=1` on every
VNC-stack unit (everything except `kasm-setup`, `network-wait`,
`profile-pull`, `profile-size-check`, `custom-startup`), and
`ConditionEnvironment=KASM_PROFILE_PULL=1` on `profile-pull.service`
and `profile-size-check.service`.

For socket-activated KasmVNC (warm-pool deployments), the operator
drops in a `kasmvnc.socket` plus a same-named `kasmvnc.service`
override via `/etc/container-init.d/`. Not the default. See Phase 4.7
worked example #4 in `design/work_sequence.md` for the full pattern
and caveats (profile pull stays eager; health-check timeouts must be
≥1s; reactive provisioning models should not enable it).

```
kasm-setup.service          oneshot   (envdump from /proc/1/environ; mkdir
                                       /var/run/pulse, /var/log/journal;
                                       dbus-launch; copy baked-in cert from
                                       /etc/kasm/self-default.pem if no
                                       override; kasmvncpasswd; **OS-user
                                       rename/chown when KASM_OS_* env
                                       vars differ from defaults --
                                       see Phase 4.10 in
                                       work_sequence.md**)
network-wait.service        oneshot   After=kasm-setup
profile-pull.service        oneshot   After=network-wait      # pull_profile()
kasmvnc.service             simple    After=profile-pull
                                      ExecStart=/usr/bin/Xvnc :1 \
                                        -drinode ${DRINODE} \
                                        -depth ${VNC_COL_DEPTH} \
                                        -geometry ${VNC_RESOLUTION} \
                                        -websocketPort ${NO_VNC_PORT} \
                                        -httpd ${KASM_VNC_PATH}/www \
                                        -SSLOnly -FrameRate=${MAX_FRAME_RATE} \
                                        -interface 0.0.0.0 \
                                        -BlacklistThreshold=0 \
                                        -FreeKeyMappings ${VNCOPTIONS}
                                      Restart=on-failure (when
                                      KASMVNC_AUTO_RECOVER=true)
                                      ExitContainerOnFailure=true (when
                                      KASMVNC_AUTO_RECOVER=false)
window-manager.service      simple    After=kasmvnc
                                      Restart=on-failure
                                      OnFailure=recorder-drain.service (when
                                      KASM_SVC_RECORDER=1)
audio-out-ws.socket         socket    ListenStream=8081
                                      ConditionEnvironment=KASM_SVC_AUDIO=1
audio-out-ws.service        simple    Requires=audio-out-ws.socket
                                      Restart=on-failure
audio-out.service           simple    After=audio-out-ws
                                      ConditionEnvironment=KASM_SVC_AUDIO=1
                                      Restart=on-failure
audio-in.socket             socket    ListenStream=4901
                                      ConditionEnvironment=KASM_SVC_AUDIO_INPUT=1
audio-in.service            simple    Requires=audio-in.socket
                                      Restart=no
upload.socket               socket    ListenStream=4902
                                      ConditionEnvironment=KASM_SVC_UPLOADS=1
upload.service              simple    Requires=upload.socket
                                      Restart=on-failure
gamepad.socket              socket    ListenStream=4903
                                      ConditionEnvironment=KASM_SVC_GAMEPAD=1
gamepad.service             simple    Requires=gamepad.socket
                                      Restart=no
webcam.socket               socket    ListenStream=4905
                                      ConditionEnvironment=KASM_SVC_WEBCAM=1
                                      ConditionPathExists=/dev/video0
webcam.service              simple    Requires=webcam.socket
                                      Restart=on-failure
printer.socket              socket    ListenStream=/tmp/printer
                                      ConditionEnvironment=KASM_SVC_PRINTER=1
printer.service             simple    Requires=printer.socket
                                      Restart=on-failure
pcscd.service               simple    After=kasmvnc
                                      ConditionEnvironment=KASM_SVC_SMARTCARD=1
                                      Restart=on-failure
smartcard.socket            socket    ListenStream=/tmp/smartcard
                                      ConditionEnvironment=KASM_SVC_SMARTCARD=1
smartcard.service           simple    Requires=smartcard.socket
                                      After=pcscd
                                      Restart=on-failure
profile-size-check.service  simple    After=profile-pull
                                      Restart=on-failure
recorder-watch.service      simple    After=kasmvnc
                                      ConditionEnvironment=KASM_SVC_RECORDER=1
custom-startup.service      simple    After=kasmvnc
                                      ConditionFileIsExecutable=/dockerstartup/custom_startup.sh
recorder-drain.service      oneshot   (only invoked via OnFailure=; runs the
                                      ensure_recorder_terminates_gracefully
                                      pgrep loop, then ExitContainerOnFailure)
```

DLP fail-secure (`DLP_PROCESS_FAIL_SECURE=1`) is global rather than
per-service, which suggests a top-level option in the init's own config (not
a unit directive). Open question; resolve in spike.

Note that `audio-out-ws.service`, `audio-in.service`, `upload.service`,
`gamepad.service`, `webcam.service`, `printer.service`, and
`smartcard.service` are all socket-activated. They are not started at boot;
the corresponding `.socket` units bind their listeners and the kernel wakes
the shim on first connect, which then starts the service with the listening
fd inherited as fd 3. For features the user never invokes, the helper never
runs -- removing both ambient RSS and the smartcard busy-loop documented in
`design/cold-start-perf-and-memory.md`. KasmVNC's existing `-UnixRelay`
config in `src/common/install/kasm_vnc/kasmvnc.yaml` already proxies to the
two AF_UNIX listeners, so this is invisible to the noVNC client.

Helpers we ship as Go binaries in this repo (`kasm-upload-server`) consume
`LISTEN_PID` / `LISTEN_FDS` and bind via inherited fd 3 (native mode).
Helpers we install as binaries from S3 unchanged (the Python PyInstaller
bundles for printer, gamepad, smartcard, audio_in, audio_out_websocket,
webcam) are activated via container-init's proxy mode -- container-init
binds the public socket and proxies to the helper on a private endpoint.
Either way, all activation happens within this repo: there is no
cross-repo dependency.

## Lifecycle hooks

The five hook scripts in `src/common/scripts/kasm_hook_scripts/`
(`kasm_post_run_root.sh`, `kasm_post_run_user.sh`, `kasm_pre_shutdown_root.sh`,
`kasm_pre_shutdown_user.sh`, `kasm_end_session_recoverable.sh`) are invoked
by the Kasm Workspaces server *outside* the container init -- they do not
need to be modeled as units. They run as-is.

## Effort and risk

Estimated effort for one focused engineer who knows Go: ~3 weeks.

- Unit parser via go-systemd/unit + Kasm-subset validator: 1 day
- Topological sort, parallel goroutine supervisor with restart accounting:
  3-4 days
- Conditions, OnFailure, ExitContainerOnFailure: 2 days
- Init loop, zombie reaping, signal forwarding, reverse shutdown: 2 days
- User/Group/WorkingDirectory + privilege drop (fiddly): 1-2 days
- EnvironmentFile parser matching systemd quoting: 1 day
- Distro-matrix CI + tests against the actual Kasm units: 3-4 days

Risks:

- **Scope creep.** The directive list is the API. Defending it against
  drive-by additions is the entire scope-control strategy. Document each
  addition with a rationale; otherwise refuse.
- **EnvironmentFile semantics.** Easy to get subtly wrong. Use a vetted lib
  if one exists for Go; otherwise fuzz-test against systemd's actual
  behavior.
- **PID 1 responsibilities.** Zombie reaping, signal forwarding,
  process-group handling, terminal handling. Stdlib supports all of it but
  it's easy to leak children. Use `syscall.Wait4(-1, ...)` in the reaper;
  use `SysProcAttr.Setpgid: true` so children form their own process groups.
- **Loss of bash flexibility.** Some current behaviors are accidental
  (e.g. `set -ex` debug output is genuinely useful when things fail). Make
  sure the Go init has equivalent debug verbosity (`KASM_DEBUG=1` →
  per-unit ExecStart command logged before fork).

## Plan

**Pre-step: Workstream 1 from `design/cold-start-perf-and-memory.md` ships
first.** Bake the SSL cert at build time, pre-create `/tmp/.ICE-unix`,
pre-compile xkbcomp output, trim the broken XFCE autostart applets
(nm-applet, polkit-gnome-authentication-agent-1, xiccd,
system-config-printer-applet, optionally gvfs-* monitors). These are pure
Dockerfile / autostart changes, ship per-distro independently of container-init,
and remove ~100-130 MiB of steady-state RSS plus ~100-300ms of TTFL.
Critically, they also **remove confounders from the container-init validation**:
when we benchmark container-init against the bash baseline, both should be
running on a cleaned-up image so the comparison measures the shim, not the
cert work.

1. **Spike (1-2 days).** Build a minimum `container-init` in Go that handles
   `Type=simple`, `After=`, `Restart=on-failure`, `ConditionEnvironment=`,
   `ConditionPathExists=`, `OnFailure=`, **socket activation
   (`.socket` units with fd inheritance via `LISTEN_PID`/`LISTEN_FDS`)**,
   signal-driven reverse shutdown, and parallel goroutine supervision.
   Ship as a single binary. Run it as PID 1 in a probe container against a
   hand-written subset of the Kasm unit set (kasmvnc + window-manager + one
   audio service + recorder + one socket-activated helper). Replicate
   probes D and E from the validation work above, plus probe F (socket
   activation) from the "Socket activation" section. Adds ~half a day to
   the original 1-2 day estimate; absorbs into the same window.
2. **Decision gate.** If the spike works in the budget and feels right,
   commit to the 3-week build. If it reveals scope-creep landmines (e.g.
   EnvironmentFile turns out to be a tarpit, or User= privilege drop is
   harder than expected on the distro matrix, or socket activation across
   the helper matrix is more involved than expected), revisit -- the
   fallback is gdraheim + Nuitka, which gets us 90% of the perf story and
   the unit-file format with zero ownership cost, at the price of keeping
   the ExecStart-wrapper hack for cross-service rules **and giving up
   socket activation**.
3. **Build.** Implement the full directive subset, write the Kasm unit set,
   port the existing service launches one at a time. Keep `vnc_startup.sh`
   as a fallback path during transition (selectable by Dockerfile arg or
   environment variable) so we can A/B image variants in CI. The trace
   instrumentation in `vnc_startup.sh`
   (`KASM_BOOT_TRACE=1` -> `/tmp/kasm-boot-trace.jsonl`) is mirrored into
   container-init under its own gate
   (`CONTAINER_INIT_TRACE=1` -> `/tmp/container-init-trace.jsonl` by
   default) emitting the **same JSONL format with the same phase
   names** -- gives us A/B-comparable boot timing and memory snapshots
   vs the bash baseline using the same dashboards/tooling.
3a. **Activation mode coverage.** Native mode is consumed by the Go
    `kasm-upload-server` we ship in this repo. Proxy mode is configured
    in the unit set for the six PyInstaller-bundled helpers
    (audio_out_websocket, audio_in, gamepad, webcam, printer, smartcard);
    no helper-source modifications and no other repos are involved.
4. **Roll out per-distro.** Ubuntu first (largest user base, easiest to
   validate). Then the rest of the matrix.
5. **Retire `vnc_startup.sh`.** Delete the file, the entrypoint chain, and
   the dead `kasm_startup.sh` arg. Update docs.

## Open questions (resolve in spike)

- DLP fail-secure as global option vs per-unit `ExitContainerOnFailure`?
- ~~`custom_startup` extension hook: keep as a single-script ExecStart
  in a unit, or expose `/etc/container-init.d/*.service` as a documented
  drop-in dir for image authors?~~ **Resolved: both.**
  `/etc/container-init.d/` is the primary extension point for base
  images and is documented as a Phase 4.7 deliverable in
  `design/work_sequence.md`. The legacy `custom_startup.sh` hook is
  preserved as a back-compat shim (`custom-startup.service`) so existing
  images don't break during migration.
- ~~`Type=forking` necessary, or can we get away with `simple` + `oneshot`
  only?~~ **Resolved.** Direct `Xvnc` exec from `kasmvnc.service`
  (skipping the perl `vncserver` wrapper) means `Type=simple` is sufficient.
  See "Mapping vnc_startup.sh to units" above.
- Restart-on-config-change semantics: not in scope for v1, but worth
  noting -- env var changes today require container restart, that does
  not change.
- Logging: prefix per-unit stdout with `unit-name:` to one combined stream
  (mirrors gdraheim, mirrors current bash), or per-unit log files? Default
  to combined; make per-unit a flag.
