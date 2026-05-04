# container-init

PID 1 supervisor for Kasm core images. Reads a fixed subset of systemd unit
files, supervises services, and provides socket activation in two modes
(native via `sd_listen_fds`, and proxy for unmodified upstream binaries).

This directory holds the binary and its unit-set consumers. The binary
itself is generic — Kasm specificity lives in the unit-set content under
`/etc/container-init/units/`, not in this code.

## Layout

```
cmd/
  container-init/      PID 1 supervisor binary
  kasm-upload-server/  Go drop-in for the PyInstaller upload helper (Phase 3)
  kasm-xvnc/           Direct-Xvnc launcher; bypasses the perl wrapper (Phase 4.4)
  spike-helper/        Phase 2 spike test helper (removed in Phase 5)
internal/
  unit/                unit-file parser + Kasm-subset validator + env expansion
  supervisor/          goroutine-per-service supervision
  socketact/           socket activation (native + proxy)
  cgroup/              per-unit cgroup-v2 placement + cgroup.kill teardown
  pid1/                SIGCHLD dispatcher, signal forwarding, reverse shutdown
  trace/               JSONL boot-trace emission (mirrors vnc_startup.sh)
  userdb/              /etc/passwd + /etc/group resolution for User= / Group=
units/                 production Kasm unit set (Phase 4.6)
scripts/               wrapper scripts the unit set's ExecStart= invokes
Makefile
```

## Building

```
make build      # produces bin/container-init.linux-{amd64,arm64}
make xvnc       # produces bin/kasm-xvnc.linux-{amd64,arm64}
make upload     # produces bin/kasm-upload-server.linux-{amd64,arm64}
make all        # all of the above + the spike helper
make test
```

All binaries are statically linked, CGO disabled, ≤ 8 MiB each.

## Run-time layout (image side)

Container-init reads from two directories, in priority order:

1. **`/etc/container-init/units/`** — core unit files installed by the
   base image (the contents of this directory's `units/`).
2. **`/etc/container-init.d/`** — drop-ins shipped by base images that
   layer on top of core (chrome, firefox, vscode, etc.). Drop-ins go
   through the same parser and validator as core; they can reference
   core units via `After=` / `Requires=` / `OnFailure=`.

Both paths are configurable via the `--units` and `--drop-in` flags;
the defaults match the documented contract.

The `--strict-units` flag promotes any parser warning (unknown
directive / section, unsupported value form) into a fatal load error —
useful in CI to catch typos before they ship.

## Extension point — `/etc/container-init.d/`

This is the primary, first-class way for layered images to add their own
services or replace core ones.

### Override semantics

A drop-in named *identically* to a core unit (full filename match,
including the `.service` / `.socket` suffix) **replaces** the core unit.
Container-init logs one line per replacement at startup:

```
container-init: drop-in override: kasmvnc.service replaces /etc/container-init/units/kasmvnc.service with /etc/container-init.d/kasmvnc.service
```

The trace JSONL (when `CONTAINER_INIT_TRACE=1`) emits an
`unit_overridden` event so dashboards can spot overlays at a glance.

A drop-in with any *other* name is **additive** — added to the unit
graph, parsed, supervised, and shut down alongside the core set.

### Naming conventions

- The `kasm-*` filename prefix is reserved for core-image units.
  Layered images should avoid it.
- Recommended convention: `<image-name>-<service>.service` —
  `chrome-launcher.service`, `vscode-server.service`,
  `firefox-default-window.service`.
- For an *intentional* override, name the drop-in identically to the
  core unit you want to replace. There is no namespacing; full
  filename match is the override key.

### Validation

Drop-ins go through the same Kasm-subset validator as core units.
Unsupported directives produce a parse-time warning naming the file +
section + directive (default) or fail-fast (`--strict-units`).

### Restart, conditions, lifecycle

Drop-ins participate in the supervisor's full lifecycle:

- **Restart= / RestartSec= / StartLimitBurst= / StartLimitIntervalSec=** —
  per-unit restart policy and rate limiting.
- **ConditionPathExists= / ConditionPathExistsGlob= / ConditionEnvironment=** —
  unit is loaded but skipped at boot when conditions are unmet.
- **OnFailure=** — invoke a sibling oneshot when this unit's restart
  policy is exhausted; chains across the core/drop-in boundary
  identically.
- **ExitContainerOnFailure=true** — fail-secure: take the whole
  container down via reverse shutdown when this unit's failure path
  is reached. Useful for compliance gates an image author owns.
- **User= / Group= / WorkingDirectory=** — privilege drop. Accepts the
  `${KASM_OS_USER:-kasm-user}` env-expansion form so per-image
  overrides flow through Phase 4.10's OS-user rename automatically.

## Worked examples

The five drop-in patterns base-image authors actually use.

### 1. One-shot at boot

A simple per-image initialisation step that needs to run after Kasm's
session setup but before the WM comes up:

```ini
# /etc/container-init.d/myimage-init.service
[Unit]
Description=My image's per-session init
After=kasm-setup.service
Requires=kasm-setup.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=${KASM_OS_USER:-kasm-user}
ExecStart=/usr/local/bin/myimage-init
TimeoutStartSec=60s
```

### 2. Long-running app under the WM

A per-image app that should restart on crash and bring the container
down only on terminal failure:

```ini
# /etc/container-init.d/myimage-app.service
[Unit]
Description=Background app
After=window-manager.service
Requires=window-manager.service

[Service]
Type=simple
User=${KASM_OS_USER:-kasm-user}
WorkingDirectory=${KASM_OS_HOME:-/home/kasm-user}
Environment=DISPLAY=:1
ExecStart=/usr/local/bin/myimage-app --listen 127.0.0.1:5000
Restart=on-failure
RestartSec=2s
StartLimitBurst=5
StartLimitIntervalSec=60s
```

### 3. Socket-activated helper, native mode

When the helper is a Go binary you ship (or any binary that consumes
`LISTEN_PID` / `LISTEN_FDS`), use native activation. Container-init
binds the public port and hands the listener fd over on first connect:

```ini
# /etc/container-init.d/myhelper.socket
[Unit]
Description=My helper — public listener (native sd_listen_fds)

[Socket]
ListenStream=5050
ActivationMode=native
Service=myhelper.service

[Install]
WantedBy=sockets.target
```

```ini
# /etc/container-init.d/myhelper.service
[Unit]
Description=My helper (Go, native socket activation)
Requires=myhelper.socket

[Service]
Type=simple
User=${KASM_OS_USER:-kasm-user}
ExecStart=/usr/local/bin/myhelper --auth-token ${MYHELPER_AUTH:-}
Restart=on-failure
RestartSec=500ms
```

The helper reads `LISTEN_PID` / `LISTEN_FDS` and uses `os.NewFile(3,
"listener")` to consume the inherited fd. Cold-start lands on the
first connection, not at boot.

### 4. Socket-activated KasmVNC for warm-pool deployments

Pool-based deployments hold many idle containers warm. Cold-start
KasmVNC turns ~80 MiB ambient + ~580 ms of Xvnc startup into a
deferred cost paid only on first websocket connect:

```ini
# /etc/container-init.d/kasmvnc.socket
[Unit]
Description=KasmVNC — public listener (warm-pool drop-in)
ConditionEnvironment=KASM_VNC=1

[Socket]
ListenStream=6901
ActivationMode=proxy
ProxyTarget=127.0.0.1:16901
Service=kasmvnc.service

[Install]
WantedBy=sockets.target
```

```ini
# /etc/container-init.d/kasmvnc.service
# *Replaces* core /etc/container-init/units/kasmvnc.service via the
# override-by-name semantic.
[Unit]
Description=KasmVNC (warm-pool drop-in)
Requires=kasmvnc.socket
After=kasm-setup.service

[Service]
Type=simple
User=${KASM_OS_USER:-kasm-user}
WorkingDirectory=${KASM_OS_HOME:-/home/kasm-user}
Environment=NO_VNC_PORT=16901
ExecStart=/usr/local/bin/kasm-xvnc
Restart=on-failure
RestartSec=200ms
```

**Caveats — read before enabling:**

- **Profile pull stays eager.** `KASM_PROFILE_LDR`-driven pulls take
  seconds to minutes; deferring them past the websocket handshake
  times out the noVNC client. If the operator wants no profile pull
  at all, set `KASM_PROFILE_PULL=0`.
- **Health-check timeouts must be ≥ Xvnc cold-start.** Kasm Workspaces
  polls `:6901`; container-init's bound socket completes the TCP
  handshake immediately, but the websocket upgrade hangs during
  cold-start. Operators must ensure the upstream health-check
  timeout is ≥ 1 s.
- **Default Kasm provisioning (reactive — container spawned per user
  request) should NOT enable this drop-in.** In that model, eager
  start hides KasmVNC boot inside container-creation latency; lazy
  start surfaces it as connect-time latency, hurting TTFL.
  Socket-activated VNC pays off only when the deployment maintains a
  pool of idle containers.

### 5. Socket-activated system D-Bus for derived images that bundle a backend

The core image ships only a per-session bus (`dbus-launch` in
`kasm-setup.service`); a system bus adds ~5 MiB ambient and a setuid
surface, and is useless on its own because none of the core-image apps
register on it. Image authors who layer a backend (polkitd,
NetworkManager stub, custom hardware daemons) can drop in:

```ini
# /etc/container-init.d/dbus-system.socket
[Unit]
Description=System D-Bus — public AF_UNIX listener

[Socket]
ListenStream=/run/dbus/system_bus_socket
SocketUser=root
SocketMode=0666
ActivationMode=native
Service=dbus-system.service

[Install]
WantedBy=sockets.target
```

```ini
# /etc/container-init.d/dbus-system.service
[Unit]
Description=System D-Bus daemon
Requires=dbus-system.socket

[Service]
Type=simple
User=messagebus
Group=messagebus
ExecStartPre=/usr/bin/install -d -m 0755 /run/dbus
ExecStart=/usr/bin/dbus-daemon --system --nofork --nopidfile --syslog-only
Restart=on-failure
```

The author's backend service then `Requires=dbus-system.service` and
`After=dbus-system.service`. dbus-daemon natively understands the
`sd_listen_fds` protocol and consumes the listener fd container-init
hands over.

**Caveats:**

- **Setuid surface.** `dbus-daemon --system` traditionally drops
  privileges to `messagebus` via setuid. Most distros install a
  `messagebus` user with `dbus`; image authors should confirm and set
  `User=messagebus` / `Group=messagebus` declaratively.
- **Pointless without a backend.** Adding only a system bus does NOT
  restore nm-applet / polkit-gnome / xiccd / system-config-printer-applet
  (the Phase 1.4 trim targets). Those need their backend services
  *registered on the bus*, not just the bus existing. The pattern is
  for image authors who are also bringing a backend.
- **Not in the core unit set.** Phase 4.6's unit set deliberately does
  not include `dbus-system.*` because no core-image app needs it.
  Pulling it in is a per-image decision via the extension point.

## Migration: `custom_startup.sh` → drop-in

Existing images shipping a `/dockerstartup/custom_startup.sh` continue
to work — the back-compat `custom-startup.service` core unit invokes
it after `window-manager.service`. To migrate to a drop-in:

1. Decide what the script actually does. Most fall into one of:
   - One-shot init (open a config, copy a file): pattern 1 above.
   - Background app (browser, IDE): pattern 2 above.
   - Listener (long-running daemon): pattern 3 above.
2. Rewrite as a `.service` (and `.socket` if applicable). Use the
   relevant pattern as a template.
3. Drop the file at `/etc/container-init.d/<image-name>-<service>.service`.
4. Delete the old `custom_startup.sh` from the image (or leave it —
   the back-compat shim will continue to invoke it harmlessly).

Drop-ins win the dependency-ordering and restart-policy story that
`custom_startup.sh` never had: they participate in `After=` /
`Requires=` / `OnFailure=`, get supervised restarts, and shut down in
reverse-dependency order at container teardown.

## Status

Phase 4 (production build). Phase 5 (per-distro rollout to
`CONTAINER_INIT=1` default) and Phase 6 (delete `vnc_startup.sh`) are
the remaining sequence steps. See `design/work_sequence.md` for the
full plan.
