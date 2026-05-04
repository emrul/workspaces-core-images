# Work sequence

Concrete, ordered execution plan for the work described in
`design/vnc-startup-replacement.md` and
`design/cold-start-perf-and-memory.md`. Each phase has explicit completion
criteria. No phase is "ongoing" or "opportunistic" — every item in this
document is something we are committing to finish before the next phase
starts. Anything not listed here is **out of scope**, not "deferred."

The sequence assumes the spike at Phase 2 returns GO. If it returns NO-GO,
we stop and write a different document for the alternative path
(gdraheim + Nuitka); that alternative is not detailed here because we are
not committing to it.

---

## Rules of the sequence

1. **No deferrals.** A phase is either fully complete (every task done,
   every completion criterion met) or it is in progress. Phases do not move
   forward leaving tasks behind.
2. **All work lives in this repo.** Code we write or modify is committed to
   `workspaces-core-images`. The single exception is **KasmVNC**: if during
   execution we discover we need a KasmVNC source change, we branch
   `/Users/emrul/dev/kasm/gitlab/KasmVNC` and open a draft merge request.
   No KasmVNC changes are anticipated by the current sequence — Phase 4.4
   (direct `Xvnc` exec) sidesteps the perl wrapper entirely.
3. **Each phase has a written completion check.** When the check passes,
   the phase is closed and we move to the next.
4. **Out-of-scope items are listed at the end.** If something is not in
   this document, it is not happening as part of this work — not later, not
   opportunistically.
5. **Phases are presented linearly.** Some adjacent phases can run in
   parallel by separate people; parallelisation notes are explicit where
   they apply.
6. **Performance baselines are measured, not asserted.** Each phase that
   claims a perf improvement gets a before/after measurement using the
   trace instrumentation already in `vnc_startup.sh`.

---

## Repository layout (introduced in this sequence)

All Go code introduced by this work lives under `src/common/container-init/`:

```
src/common/container-init/
  go.mod
  cmd/
    container-init/main.go          # PID 1 supervisor binary
    kasm-upload-server/main.go      # Go rewrite of kasm_upload_server
  internal/
    unit/                           # unit-file parser + Kasm-subset validator
    supervisor/                     # goroutine-per-service supervision
    socketact/                      # socket activation: native + proxy modes
    pid1/                           # zombie reaping, signals, reverse shutdown
    trace/                          # JSONL boot-trace emission
  units/                            # the Kasm unit set (.service / .socket)
  Makefile
  README.md
```

Image-install paths:

- `/usr/bin/container-init`
- `/usr/bin/kasm-upload-server`
- `/etc/container-init/units/*.{service,socket}`
- `/etc/container-init.d/*.{service,socket}` (drop-in slot for image authors
  who layer on top of core; the extension contract is documented as part
  of Phase 4 — see Phase 4.7)

---

## Phase 0 — Baseline (already complete)

**Goal.** Frozen baseline measurements that every later phase compares
against.

**Tasks.**
- Trace instrumentation merged into
  `src/common/startup_scripts/vnc_startup.sh`, gated on `KASM_BOOT_TRACE=1`.
- 5-run trace + memory snapshots captured on
  `docker.io/kasmweb/core-ubuntu-noble:1.18.0-rolling-daily`.
- Findings written up in `design/cold-start-perf-and-memory.md`.

**Completion criteria.**
- `design/cold-start-perf-and-memory.md` exists and contains the median
  per-phase timings, steady-state RSS table, top-RSS contributors list, and
  boot-log artefact list. ✓ done.

---

## Phase 1 — Image-build cleanup, full distro matrix

**Goal.** Remove every fix that is a pure Dockerfile / autostart change,
across every distro we ship. After this phase, the bash path itself is
faster and lighter; this also strips confounders before the container-init
benchmarking.

**Tasks (per distro: ubuntu, debian, kali, fedora42, fedora43, opensuse,
oracle8, oracle9, rockylinux8, rockylinux9, almalinux8, almalinux9,
parrotos7, alpine).**

- 1.1 Bake the KasmVNC self-signed SSL cert at image build time to
  `/etc/kasm/self-default.pem`. Provide an env-var override
  (`KASM_TLS_CERT_PATH`) so deployments can mount a real cert. Update
  `vnc_startup.sh` to copy the baked cert to `~/.vnc/self.pem` instead of
  generating one with `openssl req`.
- 1.2 Add `RUN install -d -m 1777 /tmp/.ICE-unix` (or distro equivalent) to
  the Dockerfile. Removes the `_IceTransmkdir` startup error.
- 1.3 *Dropped during execution (2026-05-03).* The original task was to
  pre-compile xkbcomp output to `/var/lib/xkb/server-*.xkm` at image
  build. Empirical finding on Ubuntu Noble: KasmVNC's Xvnc (KasmVNC 1.4.1
  as packaged in `core-ubuntu-noble:1.18.0-rolling-daily`) does not write
  the xorg-server `XkmOutputDir` cache — `find /` during Xvnc startup
  shows zero `.xkm` files written anywhere on the filesystem. The
  pre-compile premise is broken: there is no path Xvnc would consume.
  Eliminating the xkbcomp cost would require a KasmVNC source change
  (off-protocol for this sequence — see rule 2) or a non-trivial
  alternative we don't have. The ~50–150 ms latency lever is removed
  from the Phase 4 floor; remaining Phase 4 wins (direct `Xvnc` exec,
  socket activation, lazy helpers) still deliver the headline TTFL and
  RSS reductions.
- 1.4 Trim the XFCE autostart entries that fail without a system D-Bus:
  remove `nm-applet.desktop`,
  `polkit-gnome-authentication-agent-1.desktop`, `xiccd.desktop`,
  `system-config-printer.desktop`. Gate `gvfs-*-volume-monitor.desktop`
  removal behind a `KASM_ENABLE_GVFS=1` env knob (default disabled). Only
  applies to distros shipping XFCE.

**Completion criteria.**
- For every distro in the matrix: image build merged with the three
  remaining changes (1.1, 1.2, 1.4 where applicable; 1.3 was dropped
  during execution — see above). Distros without XFCE skip 1.4;
  per-distro skips noted explicitly in the PR description.
- Boot trace re-run on each distro with `KASM_BOOT_TRACE=1`; the openssl
  cert phase reports `dt_ms <= 5` (file copy only).
- `_IceTransmkdir` error absent from the boot log on every distro.
- `nm-applet`, `polkit-gnome-authentication-agent-1`, `xiccd`,
  `system-config-printer-applet` absent from `ps -e` at steady state on
  every distro that ships XFCE.
- Steady-state on Ubuntu Noble vs Phase 0 baseline: cgroup
  `memory.current` reduced by **≥10 MiB**, sum-of-per-process RSS
  reduced by **≥50 MiB**, and ≥7 fewer processes. (Original target was
  ≥80 MiB cgroup reduction; revised 2026-05-03 after measurement showed
  Phase 1 alone hits ~13 MiB cgroup / ~67 MiB per-process — the rest of
  the doc's 100 MiB estimate lives in shared-library mappings that
  surviving XFCE processes keep resident. The ≥80 MiB cgroup figure now
  belongs to Phase 3 + Phase 4 cumulative — see those phases'
  completion criteria.) Comparable proportional reduction on the other
  XFCE distros.

**Effort.** ~1 week if run in parallel across distros by image owners;
sequential walk through the matrix if not parallelised.

**Parallelisation.** This phase is independent of Phase 2 and can run in
parallel with the spike by a different person.

---

## Phase 2 — `container-init` spike and decision gate

**Goal.** Prove the Go shim approach end-to-end on a small unit set,
including **both** native and proxy socket-activation modes. Produce a
written GO/NO-GO decision before any larger investment.

**Tasks.**

- 2.1 Create `src/common/container-init/` skeleton (go.mod, internal
  packages, Makefile).
- 2.2 Implement minimum `container-init` in Go with the following directives:
  - `[Unit]`: `Description`, `After`, `Requires`, `ConditionEnvironment`,
    `ConditionPathExists`, `OnFailure`
  - `[Service]`: `Type=simple`, `ExecStart`, `Restart=on-failure`,
    `RestartSec`, `Environment`, `ExitContainerOnFailure`
  - `[Socket]`: `ListenStream` (TCP and AF_UNIX), `Accept=no`, `Service`,
    `ActivationMode=native|proxy`, `ProxyTarget=`
  - `[Install]`: `WantedBy=multi-user.target | sockets.target`
  - PID-1 responsibilities: zombie reaping (`syscall.Wait4`), signal
    forwarding, reverse shutdown on SIGTERM/SIGINT.
  - Goroutine-per-service supervision; `internal/socketact/` implements
    both native (sd_listen_fds) and proxy (in-process byte copy) modes.
- 2.3 Build a probe container against a hand-written unit set: kasmvnc +
  window-manager + one native-mode socket + one proxy-mode socket + recorder.
- 2.4 Run probes D, E, F in podman 4.8.2:
  - **D**: WM dies + recorder running → drain + container exit (clean exit
    code, full reverse shutdown observed).
  - **E**: WM dies + recorder *not* running → restart per
    `Restart=on-failure`.
  - **F**: socket-activated services cold-start on first connect under
    *both* native and proxy modes; restart under `Restart=on-failure`;
    stay unbound when their `ConditionEnvironment` is unmet.
- 2.5 Write a one-page decision document (`design/spike-result.md`) with
  GO / NO-GO and rationale.
- 2.6 **Cross-cutting (configurable OS user — see end-of-doc section):**
  while building the directive parser in 2.2, design env-var expansion
  (`${VAR}` and `${VAR:-default}`) into the value side of every
  directive — so `User=${KASM_OS_USER:-kasm-user}`,
  `Group=${KASM_OS_GROUP:-kasm-user}`,
  `WorkingDirectory=${KASM_OS_HOME:-/home/kasm-user}` resolve at
  unit-load time. Same expansion mechanism reused later for
  `EnvironmentFile=`. Defer the actual rename/chown logic to Phase 4.10
  — the spike just needs the parser hook in place.

**Completion criteria.**
- `src/common/container-init/cmd/container-init/` builds a single static
  binary on linux/amd64 and linux/arm64.
- All three probes pass (D, E, F-native, F-proxy) with the expected
  outcomes, observed in container stdout + boot-trace JSONL.
- `design/spike-result.md` committed with explicit verdict.
- Directive-value `${VAR}` / `${VAR:-default}` expansion lands in the
  parser (verified by a unit-test fixture using
  `User=${KASM_OS_USER:-kasm-user}`); Phase 4.10 will consume it.
- If NO-GO: this sequence stops here and we restart from a fresh sequence
  document.

**Effort.** ~2-3 days for one Go-fluent engineer (the extra half-day vs
the original estimate covers the proxy-mode implementation).

---

## Phase 3 — Go rewrite of `kasm_upload_server`

**Goal.** Replace the PyInstaller-bundled Flask `kasm_upload_server` with a
single static Go binary. Native-mode socket activation built in from the
start.

**Tasks.**

- 3.1 Implement `src/common/container-init/cmd/kasm-upload-server/`:
  - HTTPS POST with multipart body
  - Shared-token auth (same env-var protocol as the existing Python
    helper)
  - Write to `--upload_dir`
  - Native socket activation via `LISTEN_PID`/`LISTEN_FDS` (uses the
    `internal/socketact/` library shared with container-init)
  - Optional 5-minute idle timeout (configurable; default off so behaviour
    matches today)
- 3.2 CI parity tests against the existing Python helper: same upload
  succeeds with same auth, same file ends up at the same path with the
  same mode/owner.
- 3.3 Replace the Python binary in the image build per distro
  (`src/ubuntu/install/kasm_upload_server/install_kasm_upload_server.sh`
  and equivalents) — install `/usr/bin/kasm-upload-server` from this
  repo's build artefact instead of wgetting the PyInstaller bundle.

**Completion criteria.**
- Go binary at `src/common/container-init/cmd/kasm-upload-server/`
  compiles statically; ≤8 MiB.
- Image-build install script for every distro pulls the in-repo Go binary,
  not the PyInstaller bundle.
- Steady-state RSS for `kasm-upload-server` measured at ≤10 MiB on Ubuntu
  Noble (was 47 MiB).
- Cold-start measured at ≤20 ms (was 200-500 ms).
- The "This is a development server" line is gone from the boot log on
  every distro.
- Manual upload test passes from the noVNC client on every distro.

**Effort.** ~3-5 days for one Go engineer covering writing, parity tests,
and image integration.

**Parallelisation.** Independent of Phase 4. Can begin the day Phase 2 is
GO.

---

## Phase 4 — Full `container-init` build

**Goal.** Production `container-init` binary covering the full directive
subset documented in `design/vnc-startup-replacement.md`, with the
complete Kasm unit set, direct `Xvnc` exec, and ported trace
instrumentation. Not yet enabled by default — Phase 5 handles rollout.

**Tasks.**

- 4.1 Implement the full directive subset (all `[Unit]`, `[Service]`,
  `[Socket]`, `[Install]` directives listed in the replacement doc).
- 4.2 EnvironmentFile parser matching systemd's quoting rules. Fuzz test
  against a corpus pulled from systemd's own test suite.
- 4.3 `User=`, `Group=`, `WorkingDirectory=` privilege drop on every distro
  in the matrix. Manual test per distro. **Cross-cutting: each of these
  three directives must accept the env-expansion form
  (`User=${KASM_OS_USER:-kasm-user}` etc.) added in Phase 2.6 — see
  Phase 4.10 and the cross-cutting section at the end of this doc.**
- 4.4 Direct `Xvnc` exec from `kasmvnc.service`. The argv is built by
  `container-init` and matches what the perl `vncserver`'s
  `ConstructXvncCmd` would produce — captured by reading
  `/Users/emrul/dev/kasm/gitlab/KasmVNC/unix/vncserver` and porting the
  argv assembly into Go. **Bypasses the perl wrapper entirely; no
  KasmVNC source change.**
- 4.5 Trace instrumentation in `container-init` emits the same JSONL
  format as the bash trace from Phase 0, with phase names that mirror
  the bash trace (`boot`, `post_kasmvnc`, `post_services`,
  `steady_state_t+20s`, etc. — derived from unit names so the trace
  itself stays generic). Gated on `CONTAINER_INIT_TRACE=1`, default
  path `${CONTAINER_INIT_TRACE_FILE:-/tmp/container-init-trace.jsonl}`.
  For A/B comparison in Kasm images, read both
  `/tmp/kasm-boot-trace.jsonl` (bash) and
  `/tmp/container-init-trace.jsonl` (container-init) and merge by phase
  name.
- 4.6 Write the Kasm unit set under `src/common/container-init/units/`.

  Two top-level kill switches are wired in via `ConditionEnvironment=`,
  both default-enabled (the unit runs unless the operator sets the
  variable to `0`):

  - `KASM_VNC=1` (default) — set `KASM_VNC=0` to skip every
    VNC-stack unit. Headless containers run `kasm-setup.service`,
    `network-wait.service`, `profile-pull.service` (if enabled), and
    whatever drop-ins from `/etc/container-init.d/` carry the actual
    workload. Steady-state RSS in this mode is ~30 MiB instead of
    ~350 MiB.
  - `KASM_PROFILE_PULL=1` (default) — set `KASM_PROFILE_PULL=0` to
    take `profile-pull.service` out of the boot loop entirely. Intended
    as the kill switch ahead of a separate profile-pull refactor;
    `KASM_PROFILE_LDR` continues to select loader v0/v1/v2 when the
    pull *is* enabled.

  The unit set:

  - `kasm-setup.service` (oneshot — envdump, mkdir, dbus-launch, copy
    cert, kasmvncpasswd; **also runs the Phase 4.10 OS-user
    rename/chown step when `KASM_OS_*` env vars differ from defaults
    — see Phase 4.10 below and the cross-cutting section at the end of
    this doc**)
  - `network-wait.service` (oneshot)
  - `profile-pull.service` (oneshot;
    `ConditionEnvironment=KASM_PROFILE_PULL=1`)
  - `kasmvnc.service` (simple, direct Xvnc exec;
    `ConditionEnvironment=KASM_VNC=1`)
  - `window-manager.service` (simple;
    `ConditionEnvironment=KASM_VNC=1`)
  - `audio-out-ws.{socket,service}` (proxy mode;
    `ConditionEnvironment=KASM_VNC=1` on the socket)
  - `audio-out.service` (simple, after audio-out-ws;
    `ConditionEnvironment=KASM_VNC=1`)
  - `audio-in.{socket,service}` (proxy mode;
    `ConditionEnvironment=KASM_VNC=1`)
  - `upload.{socket,service}` (**native mode**, target =
    `kasm-upload-server`; `ConditionEnvironment=KASM_VNC=1`)
  - `gamepad.{socket,service}` (proxy mode;
    `ConditionEnvironment=KASM_VNC=1`)
  - `webcam.{socket,service}` (proxy mode;
    `ConditionEnvironment=KASM_VNC=1`)
  - `printer.{socket,service}` (proxy mode;
    `ConditionEnvironment=KASM_VNC=1`)
  - `pcscd.service` (eager; `ConditionEnvironment=KASM_VNC=1`)
  - `smartcard.{socket,service}` (proxy mode;
    `ConditionEnvironment=KASM_VNC=1`)
  - `profile-size-check.service`
    (`ConditionEnvironment=KASM_PROFILE_PULL=1`)
  - `recorder-watch.service` (`ConditionEnvironment=KASM_VNC=1`)
  - `recorder-drain.service` (oneshot, `OnFailure` target;
    `ConditionEnvironment=KASM_VNC=1`)
  - `custom-startup.service` (single-script back-compat shim that runs
    `/dockerstartup/custom_startup.sh` if present; preserves today's
    one-script extension hook for images that already use it)
- 4.7 **Document the `/etc/container-init.d/` extension point** as a
  first-class part of the container-init contract. This is the primary
  way base images (chrome, firefox, vscode, etc.) layered on top of core
  add their own services, and it replaces the single
  `custom_startup.sh` hook with something that participates in
  dependency ordering, restart policy, conditions, and socket
  activation. Deliverables:
  - `src/common/container-init/README.md` (or
    `docs/container-init/extension-points.md`) with:
    - Directory contract: `/etc/container-init.d/*.service` and
      `*.socket` are loaded at container-init start, **after** the
      built-in `/etc/container-init/units/` set, with drop-ins able to
      reference core units via `After=` / `Requires=` /
      `OnFailure=`.
    - Override semantics: a drop-in named identically to a core unit
      replaces it (last-write-wins by full unit name); otherwise
      drop-ins are additive. Document this explicitly because it is the
      behavior most likely to surprise.
    - Naming conventions: drop-ins should not use the `kasm-*` prefix
      (reserved for core-image units); recommended convention is
      `<image-name>-<service>.service`
      (e.g. `chrome-launcher.service`).
    - Validation: drop-ins go through the same Kasm-subset validator as
      core units; unsupported directives produce a parse-time warning
      (default) or fail-fast (configurable via container-init's own
      config).
    - Worked examples covering the five patterns base-image authors
      and operators actually use:
      1. A one-shot that runs at boot
         (`After=kasm-setup.service`).
      2. A long-running app service
         `After=window-manager.service` with `Restart=on-failure`.
      3. A socket-activated helper with `ActivationMode=native`.
      4. **Socket-activated KasmVNC for warm-pool deployments.** The
         operator drops in a `kasmvnc.socket`
         (`ListenStream=6901`, `ActivationMode=proxy`,
         `ProxyTarget=127.0.0.1:16901`,
         `Service=kasmvnc.service`) plus a same-named
         `kasmvnc.service` override that adds
         `Requires=kasmvnc.socket` and points Xvnc at the private
         port. Phase 4.7's override-by-name behaviour replaces the
         eager core unit cleanly. With this drop-in, a pre-provisioned
         container holds ~30 MiB until first connect, then pays
         ~580 ms of Xvnc cold-start as user-perceived latency on the
         first websocket connection. Documented caveats:
         - **Profile pull stays eager** (`KASM_PROFILE_LDR`-driven
           pulls take seconds to minutes; deferring them past the
           websocket handshake times out the noVNC client). If the
           operator wants no profile pull at all, they set
           `KASM_PROFILE_PULL=0`.
         - **Health-check timeouts** must be ≥ Xvnc cold-start. The
           Kasm Workspaces server polls 6901; container-init's bound
           socket completes the TCP handshake immediately, but the
           websocket upgrade hangs during cold-start. Operator must
           ensure the upstream health-check timeout is ≥1 second.
         - **Default Kasm provisioning (reactive: container spawned
           per user request) should not enable this drop-in.** In
           that model, eager start hides KasmVNC boot inside
           container-creation latency; lazy start surfaces it as
           connect-time latency. Socket-activated VNC pays off only
           when the deployment maintains a pool of idle containers.
      5. **Socket-activated system D-Bus for derived images that bundle
         a system-bus backend** (polkitd, NetworkManager stub, custom
         hardware daemons, etc.). The core image deliberately ships
         only a per-session bus (`dbus-launch` in `vnc_startup.sh` /
         `kasm-setup.service`); a system bus adds ~5 MiB ambient and a
         setuid surface, and is useless on its own because none of the
         core-image apps register services on it. Image authors who
         layer a backend on top can drop in:
         - `dbus-system.socket` — `ListenStream=/run/dbus/system_bus_socket`,
           `SocketUser=root`, `SocketMode=0666`,
           `ActivationMode=native`, `Service=dbus-system.service`.
         - `dbus-system.service` — `Type=simple`,
           `ExecStartPre=/usr/bin/install -d -m 0755 /run/dbus`,
           `ExecStart=/usr/bin/dbus-daemon --system --nofork --nopidfile --syslog-only`,
           `Requires=dbus-system.socket`.
         The author's backend service (e.g. `polkitd.service`) gets
         `Requires=dbus-system.service` and `After=dbus-system.service`.
         Container-init hands the inherited listen fd to dbus-daemon
         via `LISTEN_PID`/`LISTEN_FDS`; dbus-daemon natively understands
         the `sd_listen_fds` protocol. Documented caveats:
         - **Setuid surface.** `dbus-daemon --system` traditionally
           drops privileges to the `messagebus` user via setuid;
           container-init's `User=` directive can do this declaratively,
           but the image must contain a `messagebus` user (most distros
           install one with `dbus`). Image authors should set
           `User=messagebus` and `Group=messagebus` on
           `dbus-system.service`.
         - **Pointless without a backend.** Adding only a system bus
           does not restore nm-applet / polkit-gnome / xiccd /
           system-config-printer-applet (Phase 1.4 trim targets) —
           those need their backend services *registered on the bus*,
           not just the bus existing. The pattern is for image authors
           who are also bringing a backend.
         - **Not in the core unit set.** Phase 4.6's unit set does not
           include `dbus-system.*` because no core-image app needs it.
           Pulling it in is a per-image-author decision via the
           extension point.
    - Migration guide for existing images: how to convert a current
      `custom_startup.sh` to a drop-in `.service` (one section).
  - Container-init implementation:
    - Loader reads both `/etc/container-init/units/` and
      `/etc/container-init.d/`; the latter overlays the former by unit
      name.
    - Override and conflict logging: container-init logs a single line
      per overridden core unit at startup so operators can see at a
      glance what a base image has changed.
  - CI: a small fixture base image
    (`ci/fixtures/extension-test-image/`) that layers on top of core
    with one drop-in of each of the five documented patterns.
    Container-init boots it, the drop-ins run in the right order, the
    override-by-name behaviour is observed (specifically including
    the `kasmvnc.service` override from pattern 4), pattern 5's
    `dbus-system.socket` is verified to lazily start `dbus-daemon
    --system` on first connect (the fixture includes a tiny client
    that opens `/run/dbus/system_bus_socket` after boot), and a
    separate headless variant boots with `KASM_VNC=0` and
    `KASM_PROFILE_PULL=0` to confirm both kill switches work.
- 4.8 Distro-matrix CI: build each image with container-init as PID 1
  (alongside the bash path), boot it, run probes D/E/F, verify the unit
  set executes correctly.
- 4.10 **Configurable container OS user/uid/gid** (cross-cutting work
  item — see end-of-doc section). Lands inside `kasm-setup.service`'s
  ExecStart as a privileged-context oneshot block executed before the
  cert copy / kasmvncpasswd steps. Behaviour:
  - Read `KASM_OS_USER`, `KASM_OS_UID`, `KASM_OS_GID`, `KASM_OS_GROUP`,
    `KASM_OS_HOME` from the environment (defaults: `kasm-user`, `1000`,
    `1000`, `kasm-user`, `/home/kasm-user`).
  - Short-circuit (no-op) when every value matches its default — zero
    overhead for existing deployments and Workspaces server orchestration.
  - When any value differs:
    - `groupmod -g $KASM_OS_GID -n $KASM_OS_GROUP kasm-user` (gid +
      group rename in one step where the tool supports it; otherwise
      sequential).
    - `usermod -u $KASM_OS_UID -g $KASM_OS_GID -l $KASM_OS_USER -d
      $KASM_OS_HOME -m kasm-user` (uid + primary-gid + login + home
      rename + move home contents).
    - `find / -mount -uid 1000 -exec chown $KASM_OS_UID:$KASM_OS_GID
      {} +` and `find / -mount -gid 1000 -exec chgrp $KASM_OS_GID
      {} +` to fix the few non-home files owned by the old uid (squid
      nssdb, unison config, /run/pcscd, $STARTUPDIR/kasmrx/Downloads).
    - Update `/etc/passwd`'s HOME column if `usermod -d` doesn't on the
      target distro.
    - `sed -i "s|/home/kasm-user|$KASM_OS_HOME|g"` over the
      copied-in xfce panel XML configs in
      `$KASM_OS_HOME/.config/xfce4/xfconf/xfce-perchannel-xml/`
      (only the `xfce4-panel.xml` files in
      `src/{kali,oracle8,oracle9,rhel9}/xfce/.config/`; verify those
      still exist at this point in the build).
  - Per-distro nuance: Alpine ships busybox `usermod` which lacks `-m`
    and `-l` flags — fall back to `delgroup`/`addgroup`/`adduser`/`mv`
    sequence; gate on `${DISTRO}` env (already set by every Dockerfile).
  - Container-init's `User=` / `Group=` directives on every other unit
    use the env-expansion form (`User=${KASM_OS_USER:-kasm-user}` etc.)
    landed in Phase 2.6, so they resolve to the new user automatically
    after kasm-setup runs.
  - Drop `USER 1000` from every `dockerfile-kasm-core*` (entry runs as
    root; container-init drops to the configured user per unit).
  - Replace literal `/home/kasm-user` with `$HOME` in `vnc_startup.sh`
    (lines 250-252) and `kasm_pre_shutdown_user.sh` (lines 90-93);
    those scripts go away in Phase 6 but the parameterisation should
    land here so the bash-fallback path also honours `KASM_OS_HOME`.
  - Sysbox path: `src/ubuntu/install/sysbox/install_systemd.sh`
    generates a `kasm.service` unit with hardcoded `User=kasm-user` /
    `Group=kasm-user` / `chown kasm-user:kasm-user /var/run/pulse` —
    rewrite to either (a) generate the unit at first boot from env, or
    (b) set `User=`/`Group=` to a placeholder that's substituted by a
    `kasm-sysbox-setup.sh` step before `systemctl start kasm`.

**Completion criteria.**
- `src/common/container-init/cmd/container-init/` produces a single static
  binary; cold start ≤10 ms.
- Distro-matrix CI is green on every distro.
- Boot trace on Ubuntu Noble shows TTFL (time-from-boot to KasmVNC TCP
  listening) **≤300 ms** — a 280 ms improvement vs Phase 0 baseline.
- Steady-state cgroup `memory.current` on Ubuntu Noble is **≤350 MiB**, a
  ~200 MiB improvement vs Phase 0 (Phase 1 + lazy helpers).
- Full unit set written, parsed, and validated against the container-init
  validator with zero warnings.
- Extension-point documentation (Phase 4.7) committed at its documented
  path; `ci/fixtures/extension-test-image/` builds, boots under
  container-init, and demonstrates each of the four documented drop-in
  patterns plus the override-by-name behaviour.
- Headless mode verified: an image built with `KASM_VNC=0` boots, runs
  no VNC-stack units, holds steady-state RSS ≤50 MiB, and can run a
  drop-in workload (one of the Phase 4.7 fixture patterns) to
  completion.
- Profile-pull kill switch verified: an image built with
  `KASM_PROFILE_PULL=0` boots without invoking the profile loader
  even when `KASM_PROFILE_LDR` is set.
- Configurable OS-user verified (Phase 4.10): on Ubuntu Noble with
  `KASM_OS_USER=alice KASM_OS_UID=1500 KASM_OS_GID=1500
  KASM_OS_HOME=/home/alice`, the container boots, `id` reports
  `uid=1500(alice) gid=1500(alice)`, `$HOME` is `/home/alice`, KasmVNC
  starts and accepts connections, and `find / -uid 1000` returns
  empty. Verified to no-op when the env vars are unset (boot trace
  identical to defaults run).

**Effort.** ~3 weeks for one Go engineer covering implementation, unit
set, and CI integration.

---

## Phase 5 — Per-distro rollout of `container-init`

> **Status: shipped (2026-05-04).** All 8 buildable distros (kali, fedora43,
> opensuse, oracle9, rockylinux9, rockylinux8, almalinux9, alpine — plus
> noble/bookworm from the prior sweep) made it through 5.x.1 → 5.x.5.
> 5.x.4 baked `ENV CONTAINER_INIT=1` so container-init became the default
> boot path; the bash chain remained selectable via `-e CONTAINER_INIT=0`
> until Phase 6. parrotos7 deferred — external mirror outage on
> mirrors.mit.edu/parrot blocked the build at apt-index resolve time;
> picks up Phase 6's deletes when the mirror recovers. See
> `design/phase5-per-distro-results.md` for the full per-distro numbers
> and bug fixes carried in.


**Goal.** Switch every distro from the bash path to container-init as the
default ENTRYPOINT. Each distro is a separate sub-deliverable.

**Tasks (per distro, in this order: ubuntu noble, debian, bookworm, kali, 
fedora43, opensuse, oracle9, rockylinux9, rockylinux8, almalinux9, 
parrotos7, alpine).**

- 5.x.1 Build the image with `CONTAINER_INIT=1` toggle alongside the bash
  path. Boot it, run integration tests, run the trace under both paths.
- 5.x.2 Compare boot-trace JSONL between bash and container-init paths.
  Verify TTFL improvement; verify no regression in functional smoke
  tests.
- 5.x.3 Deploy the container-init image to the staging environment for
  that distro. Run for 7 calendar days. Watch for crash reports, restart
  storms, profile-sync failures.
- 5.x.4 Flip `CONTAINER_INIT=1` to default for that distro. Bash path
  remains in the image as fallback (still selectable via
  `CONTAINER_INIT=0`) until Phase 6.
- 5.x.5 **Cross-cutting (configurable OS user — Phase 4.10):** smoke-test
  the rename/chown path on this distro. Boot once with
  `KASM_OS_USER=alice KASM_OS_UID=1500 KASM_OS_GID=1500
  KASM_OS_HOME=/home/alice`, verify `id` reports the new user, `$HOME`
  resolves to `/home/alice`, KasmVNC accepts a connection, and `find /
  -mount -uid 1000` returns empty. Critical on Alpine (busybox
  `usermod` lacks `-l`/`-m`); document any fallback path that fires.
  Boot once more with no `KASM_OS_*` vars set and confirm the boot
  trace is identical to the default-user run (no-op short circuit).

**Completion criteria.**
- Every distro in the matrix has been through 5.x.1 → 5.x.5.
- No regressions logged in staging for any distro during its 7-day window.
- All distros' published images are built with container-init as the
  default PID 1.
- Phase 4.10's `KASM_OS_*` rename/chown path verified on every distro
  (5.x.5); Alpine fallback path documented.

**Effort.** ~7 days per distro of calendar time (mostly the soak), but
distros overlap. Total elapsed time ~3-4 weeks for the full matrix if
two distros are in soak at once.

---

## Phase 6 — Retire `vnc_startup.sh` and the bash path

> **Status: shipped (2026-05-04).** `vnc_startup.sh` and
> `kasm_default_profile.sh` deleted. `kasm-entrypoint` collapsed to a
> 4-line shim that execs `container-init`. `ENV CONTAINER_INIT=1`
> removed from all 7 dockerfiles (the toggle no longer exists —
> container-init is the only path). Sysbox `kasm.service` updated to
> exec container-init under real systemd. Bash arm of the
> dual-path probe stripped from the regression harness. Perl-runtime
> drop scaffolded as a side-quest (6.7) — see notes inline.


**Goal.** Delete the bash supervisor and the dead `kasm_startup.sh` arg.
After this phase, container-init is the only path; there is no fallback.

**Tasks.**

- 6.1 Delete `src/common/startup_scripts/vnc_startup.sh`.
- 6.2 Delete the `kasm_startup.sh` reference and the third arg in every
  Dockerfile's `ENTRYPOINT`. Update the ENTRYPOINT to call
  `/usr/bin/container-init` directly (or `kasm_default_profile.sh`
  followed by `exec /usr/bin/container-init`, depending on whether we
  keep the default-profile prologue as a separate step or fold it into
  `kasm-setup.service`).
- 6.3 Remove the `CONTAINER_INIT=0` fallback toggle from every Dockerfile.
- 6.4 Update `dockerfile-kasm-core*` files across the matrix.
- 6.5 Update README, CLAUDE.md (if it references the startup chain), and
  any docs in `docs/` that mention `vnc_startup.sh`.
- 6.6 Update the existing real-systemd path in
  `src/ubuntu/install/sysbox/install_systemd.sh` so the sysbox
  `kasm.service` unit invokes `container-init` rather than the bash
  chain. (Sysbox keeps real systemd as PID 1; container-init runs as a
  child unit there. This is the only path where container-init is *not*
  PID 1.) **Cross-cutting (Phase 4.10):** the sysbox unit's hardcoded
  `User=kasm-user` / `Group=kasm-user` lines must point at
  `${KASM_OS_USER}` / `${KASM_OS_GROUP}` (or be regenerated at first
  boot from env). Pick whichever option Phase 4.10 chose; this is just
  removing the now-duplicate bash-path hardcoded values.

**Completion criteria.**
- `git grep vnc_startup.sh` returns zero hits.
- `git grep kasm_startup.sh` returns zero hits.
- `git grep CONTAINER_INIT` returns zero hits (no more toggle).
- Every distro's CI build still passes with container-init as the only
  path.
- Released images run only container-init.

**Effort.** ~3-5 days, mostly mechanical.

---

## Cross-cutting: configurable container OS user/uid/gid

Tracked separately as a parallel work item; recommended landing point is
**Phase 4.10** (a new sub-phase added when Phase 4 work begins). Lets
operators set the in-container username/uid/gid via env vars
(`KASM_OS_USER` / `KASM_OS_UID` / `KASM_OS_GID` / `KASM_OS_HOME`) so
host-mounted user directories don't need permission gymnastics.

Naming caveat: `KASM_USER` and `KASM_USER_ID` are already in use by the
Workspaces server for audit-log identity — must NOT be reused for OS-user
config. The `KASM_OS_*` prefix avoids the collision.

Per-phase impact:
- **Phase 2 spike:** add `${ENV_VAR}` expansion to container-init's
  directive parser so `User=${KASM_OS_USER:-kasm-user}` resolves at
  unit-load time. ~50 LOC; co-locates with the existing `EnvironmentFile=`
  parsing work.
- **Phase 3:** zero impact — `kasm-upload-server` is user-agnostic.
- **Phase 4:** the rename/chown logic lives in `kasm-setup.service`'s
  ExecStart (already a privileged oneshot); gated to no-op when env vars
  match defaults. Unit set's `User=`/`Group=` directives use the env
  expansion from Phase 2. Drop `USER 1000` from every Dockerfile; entry
  runs as root, container-init drops to `${KASM_OS_USER}` per unit.
- **Phase 5 rollout:** per-distro rename smoke test (Alpine busybox
  `usermod` differs from util-linux; verify on every distro).

Defaults preserved at every phase: when `KASM_OS_*` vars are unset, the
container is bit-for-bit identical to today (kasm-user / 1000 / 1000 /
/home/kasm-user). Workspaces server orchestration unchanged.

---

## Out of scope for this sequence

These items are **not** part of this work. They are not deferred — they
are deliberately not included. If we want any of them, we add a new phase
to this document with explicit completion criteria first.

- **Go rewrites of the six PyInstaller-bundled helpers** (`kasm_audio_out-linux`,
  `kasm_audio_input_server`, `kasm_gamepad_server`, `kasm_webcam_server`,
  `kasm_printer_service`, `kasm_smartcard_bridge`). They are activated by
  container-init's proxy mode (Phase 4) without source modifications.
  Rewriting any of them in Go later means migrating the corresponding
  unit from `ActivationMode=proxy` to `ActivationMode=native` —
  trivial; not on this sequence.
- **Migration of audio off ffmpeg + pulseaudio onto KasmVNC native
  audio.** Depends on a KasmVNC capability we do not own and on the
  KasmVNC release timeline.
- **Modifications to KasmVNC source.** Not anticipated by this sequence.
  Phase 4.4 (direct `Xvnc` exec) gives us the latency floor without
  modifying KasmVNC. If we discover a need during execution, the
  protocol is: branch `/Users/emrul/dev/kasm/gitlab/KasmVNC`, open a
  draft MR, do not block this sequence on it.
- **Go rewrite of KasmVNC's perl `vncserver` wrapper.** The 3119-line
  perl script accounts for ~250-300 ms of `kasmvnc_invoke` and pulls
  in perl + ~15 CPAN deps (~30-50 MiB on Alpine and minimal images).
  Rewriting it would benefit standalone-CLI users and shrink minimal
  images. **It is not in this sequence** because Phase 4.4 sidesteps
  it entirely on Kasm's path — `container-init` exec's `Xvnc` directly
  with the argv ported from reading `ConstructXvncCmd`, so the perl
  startup tax disappears for Kasm core images without touching KasmVNC
  source. The wrapper still has callers we don't control
  (standalone CLI: `vncserver -kill`, `-list`, multi-display
  management; distro-package users running KasmVNC outside a Kasm
  container; `kasmvncpasswd` invocations from `kasm-setup.service`)
  — those use cases would justify a Go rewrite, but as a KasmVNC
  project living in `/Users/emrul/dev/kasm/gitlab/KasmVNC`, not in
  this repo. Hand-off protocol if/when we want to do it: open a
  KasmVNC issue capturing the scope (multi-display lock files, log
  rotation, xauth cookie generation, default-options resolution from
  `~/.vnc/config`, all currently in perl), then a draft MR with the
  Go binary replacing `unix/vncserver` and the deb/rpm/apk recipes
  swapping `perl` runtime deps for the static Go binary. Distro
  smoke-tests must verify `vncserver -kill :1` etc. behave
  identically.
- **`profile_size_check` rewrite as a oneshot/timer instead of a
  perpetual bash subshell.** Phase 4.6 packages it as a unit; the
  internal "perpetual loop vs interval timer" decision stays the same as
  today.
- **DLP fail-secure and `KASMVNC_AUTO_RECOVER` semantic redesign.**
  Implemented as-is in Phase 4 via existing directives; any rework of
  semantics is a separate piece of work.
- **Replacement of the existing trace instrumentation in
  `vnc_startup.sh` after Phase 6.** Phase 4.5 ports it into
  container-init; the bash version is deleted as part of Phase 6. We do
  not also reimplement it on top of e.g. OpenTelemetry.

---

## Reference

- `design/vnc-startup-replacement.md` — the directive subset (the
  `container-init` API), full unit decomposition, validation evidence,
  repository layout.
- `design/cold-start-perf-and-memory.md` — the measurement methodology,
  baseline numbers, and the fix-list that drives Phase 1.
- `src/common/startup_scripts/vnc_startup.sh` — current bash supervisor,
  including the trace instrumentation that Phase 4.5 reuses.
