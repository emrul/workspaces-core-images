# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

> **Fork status:** this is a soft fork of Kasm's upstream at
> `https://gitlab.com/kasm-technologies/internal/workspaces-core-images`
> (remote `kasm`, branch `develop`). The work lives on `feat/container-init`
> on the fork (`origin = https://github.com/emrul/workspaces-core-images`).
> Upstream changes are absorbed via merge + `git rerere`; we never push
> our work back. See `design/` for the multi-phase migration that
> replaced the bash boot supervisor with a Go PID 1 supervisor
> (`container-init`).

**workspaces-core-images** produces the base ("core") Docker images from which every other Kasm Workspaces image is derived. These images bundle a Linux desktop environment, a VNC/browser-access stack (KasmVNC), and the in-container wiring that lets a workspace integrate with the Kasm platform (audio, clipboard, uploads/downloads, webcam, microphone, printing, profile sync, session recording, etc.).

The output is a family of images published as `kasmweb/core-<distro>:<tag>` (e.g. `kasmweb/core-ubuntu-noble`, `kasmweb/core-fedora-41`, `kasmweb/core-alpine-321`). Downstream repos — notably `workspaces-images` (single-app images like Chrome, Firefox, VS Code) and customer-built workspaces — inherit `FROM` these core images.

Related repos in the broader Kasm system:

- `kasm_backend` (parent of this clone) — the backend services that orchestrate workspaces
- `workspaces-images` — application-specific images built on top of these cores
- `KasmVNC` — the VNC server that renders the desktop to a browser
- `kasm_squid_adapter`, `kasm_upload_service`, `kasm_printer_service`, `kasm-webcam-server`, `kasm-gamepad-server`, `profile-sync`, `kasm_smartcard_bridge`, `kasm_websocket_relay`, `kasm_audio_input_server`, `kasm_recorder_service`, `kasm-squid-builder` — component binaries pulled in at image build time

## Repository Layout

```
workspaces-core-images/
├── dockerfile-kasm-core              # Debian/Ubuntu family (default)
├── dockerfile-kasm-core-alpine       # Alpine
├── dockerfile-kasm-core-centos       # CentOS 7
├── dockerfile-kasm-core-fedora       # Fedora
├── dockerfile-kasm-core-kasmos       # KasmOS (Debian bookworm slim)
├── dockerfile-kasm-core-oracle       # Oracle Linux / RHEL / Rocky / Alma
├── dockerfile-kasm-core-suse         # openSUSE
│
├── src/
│   ├── common/                       # Shared across all distros
│   │   ├── install/                  # kasm_vnc, profile_sync configs
│   │   ├── kasm-go/                  # Go module: kasm-upload-server, kasm-xvnc,
│   │   │                             #   container-init unit files, kasm-* shell helpers
│   │   ├── resources/images/         # Backgrounds, icons, branding
│   │   ├── scripts/kasm_hook_scripts # Session lifecycle hooks (see below)
│   │   ├── scripts/kasm-entrypoint   # 4-line shim that execs container-init
│   │   └── startup_scripts/          # generate_container_user + utility scripts
│   │                                 #   (vnc_startup.sh removed; see Runtime lifecycle)
│   │
│   ├── ubuntu/                       # Ubuntu/Debian install scripts
│   │   ├── install/                  # One subdir per feature (audio, webcam, …)
│   │   ├── xfce/                     # XFCE desktop configs
│   │   └── icewm/                    # IceWM (lightweight alt) configs
│   │
│   ├── alpine/  centos/  fedora*/  kasmos/
│   ├── opensuse/  oracle7/ oracle8/ oracle9/
│   ├── rhel9/  rockylinux*/  almalinux*/
│   ├── parrotos6/  kali/             # Distro-specific install scripts
│
├── ci-scripts/                       # GitLab CI build/test/manifest tooling
│   ├── build.sh, test.sh             # Called per matrix row from .gitlab-ci.yml
│   ├── template-gitlab.py            # Jinja2 renderer for gitlab-ci.template
│   ├── template-vars.yaml            # Matrix of images to build + change-file rules
│   ├── gitlab-ci.template            # The actual CI config, rendered dynamically
│   ├── manifest.sh                   # Multi-arch manifest assembly
│   ├── scan/, vulnerability-filter.rego  # Trivy scan + Rego filtering
│   └── readme.sh, quay_readme.sh     # Dockerhub/Quay README publishing
│
├── bin/                              # Prebuilt helpers shipped into images
│   ├── intel-gpu-dri3, intel-gpu-virtualgl, intel-gpu-zink
│
├── docs/core-<distro>/               # Per-image README/description for Dockerhub
│                                     # (README.md, description.txt, demo.txt)
│
├── design/                           # Phase notes for the container-init migration
│                                     # (phase4–6 status, before/after probes, work_sequence)
│
├── runs/                             # Smoke-test scripts + trace JSONL captures
│                                     # (lean-noble-build.sh, noble-functional-smoke.sh, ...)
│
└── kasm-desktop-kde/                 # KDE desktop variant (WIP/placeholder)
```

## What's inside a core image

Every dockerfile has two leading multi-stage builders specific to this fork:

- `containerinit_fetch` (alpine:3) — `ADD`s the upstream `container-init`
  release binary from `github.com/emrul/container-init/releases` (pinned via
  `CONTAINER_INIT_VERSION`, default `v1.0.0`). Bump that ARG to update.
- `kasmgo_builder` (golang:1.24-alpine) — `go build`s `kasm-upload-server`
  and `kasm-xvnc` from `src/common/kasm-go/cmd/`.

The runtime stage then copies the supervisor binary, the two Go helpers,
and the unit/scripts trees into the image. After that, dockerfiles follow
the same shape — a series of `COPY` + `RUN bash $INST_SCRIPTS/<feature>/install_<feature>.sh` blocks — and install (roughly in order):

1. **Package rules** — apt/yum/apk pinning and repo setup
2. **Base tools** — curl, jq, sudo, xz, etc.
3. **Fonts** — custom Kasm fonts + distro fonts
4. **Desktop environment** — XFCE (default), IceWM (lightweight), or KDE variant
5. **KasmVNC** — the browser-accessible VNC server (heart of the image)
6. **profile_sync** — persists user profile to object storage between sessions
7. **kasm_upload_server** — handles browser-initiated file uploads/downloads
8. **Audio output** (`kasm_websocket_relay`) — PulseAudio → WebSocket bridge for audio streaming
9. **Audio input** (`kasm_audio_input_server`) — microphone passthrough from browser
10. **Gamepad** (`kasm_gamepad_server`) — HID passthrough from browser
11. **Webcam** (`kasm_webcam_server`) — virtual webcam device
12. **Printer** (`kasm_printer_service`) — CUPS + start_cups.sh
13. **Recorder** (`kasm_recorder_service`) — session recording via FFmpeg + KasmVNC capture
14. **Cursors** — custom cursor theme
15. **Squid** (`kasm_squid_adapter` + `kasm-squid-builder`) — per-session egress proxy
16. **Smartcard** (`kasm_smartcard_bridge`) — CCID/pcscd passthrough
17. **NVIDIA / VirtualGL** — optional GPU acceleration
18. **Hook scripts** — `src/common/scripts/kasm_hook_scripts/` (see below)
19. **Cleanup** — strip caches, man pages, locales to shrink layers

Environment variables set by every core image:

- `HOME=/home/kasm-user` — runtime home (overridable per session via `KASM_OS_USER` / `KASM_OS_HOME`)
- `STARTUPDIR=/dockerstartup` — houses the hook scripts and per-feature runtime assets
- `INST_SCRIPTS=/dockerstartup/install` — scratch dir used only during build (removed after each install)
- `KASM_VNC_PATH=/usr/share/kasmvnc`

OS-user identity is owned by container-init's `kasm-setup.service` (in
`src/common/kasm-go/units/`), which honours `KASM_OS_USER` / `KASM_OS_UID`
/ `KASM_OS_GID` / `KASM_OS_HOME` for per-session renames.

## Runtime lifecycle

`ENTRYPOINT` is `/usr/local/bin/kasm-entrypoint`, a 4-line shim that
execs `/usr/local/bin/container-init` as PID 1. The supervisor:

1. Reads units from `/etc/container-init/units/` (core, populated from
   `src/common/kasm-go/units/`) plus drop-ins from `/etc/container-init.d/`
   (additive or override; downstream images extend the unit set here).
2. Resolves `After=` / `Requires=` ordering, starts services concurrently
   when independent. Sockets bind eagerly via `sd_listen_fds` (native) or
   proxy mode so cold-start latency lands on first-connect, not at boot.
3. Owns identity setup via `kasm-setup.service`: regenerates the container
   user (`KASM_OS_USER`/`_UID`/`_GID`/`_HOME`), seeds the default profile,
   maintains `Desktop/Uploads` + `Desktop/Downloads` symlinks.
4. Supervises KasmVNC (via `kasm-xvnc`, our Go launcher that bypasses
   the perl `vncserver` wrapper), the desktop window-manager, audio in/out,
   the upload server, recorder, webcam, gamepad, smartcard, printer, etc.
5. Reaps zombies via a dedicated SIGCHLD `wait4(-1)` loop; forwards
   SIGTERM to all children on shutdown with reverse-dependency ordering.
6. Emits a JSONL boot trace to `/tmp/container-init-trace.jsonl` when
   `CONTAINER_INIT_TRACE=1`.

**Lifecycle hooks** — the legacy `src/common/scripts/kasm_hook_scripts/`
hooks (`kasm_post_run_root.sh`, `kasm_post_run_user.sh`,
`kasm_pre_shutdown_root.sh` / `kasm_pre_shutdown_user.sh`,
`kasm_end_session_recoverable.sh`) are invoked from unit files at the
equivalent moments. Downstream images can override them by dropping
replacements at the same path during their own build, or wire entirely
new lifecycle services via `/etc/container-init.d/<name>.service`.

**Sysbox special case** — when running under real systemd via sysbox,
container-init runs as a system unit (`kasm.service`) rather than PID 1.
See `src/ubuntu/install/sysbox/install_systemd.sh`.

**Boot trace** — `bash runs/lean-noble-build.sh && podman run --rm -e CONTAINER_INIT_TRACE=1 kasm-noble-lean:latest`,
then `podman exec ... cat /tmp/container-init-trace.jsonl | jq` to see
per-phase `dt_ms`, unit start order, and the `supervisor_start` event.

## Build system

### Local / manual build

The README shows the user-facing form:

```bash
sudo docker run --rm -it --shm-size=512m -p 6901:6901 \
  -e VNC_PW=password --build-arg START_XFCE4=1 \
  kasmweb/core-ubuntu-noble:<tag>
```

For building from source, each dockerfile takes these build args:

- `BASE_IMAGE`  — e.g. `ubuntu:24.04`, `fedora:41`, `alpine:3.21`
- `DISTRO`      — selects which `src/<distro>/` tree of install scripts to copy
- `BG_IMG`      — which wallpaper from `src/common/resources/images/` to use
- `EXTRA_SH`    — optional extra install script (defaults to `noop.sh`)

```bash
docker build \
  -f dockerfile-kasm-core \
  --build-arg BASE_IMAGE=ubuntu:24.04 \
  --build-arg DISTRO=ubuntu \
  --build-arg BG_IMG=bg_kasm.png \
  -t kasmweb/core-ubuntu-noble:dev .
```

### GitLab CI

The CI pipeline is **dynamically generated**:

1. `template-gitlab.py` reads `template-vars.yaml` (matrix of image names, base images, dockerfiles, change-file globs)
2. It renders `gitlab-ci.template` (Jinja2) into a `.gitlab-ci-child.yml`
3. GitLab runs that child pipeline with stages: build → test → scan → manifest → release

Key scripts invoked from the template:

- `ci-scripts/build.sh NAME1 NAME2 BASE BG DISTRO DOCKERFILE` — per-arch build, pushes to private image cache
- `ci-scripts/test.sh ... ARCH AWS_ID AWS_KEY` — spins up an EC2 instance to smoke-test the image
- `ci-scripts/manifest.sh` / `weekly-manifest.sh` — joins x86_64 + aarch64 into a single multi-arch manifest
- `ci-scripts/scan/` + `vulnerability-filter.rego` — Trivy CVE scan with Rego-based allowlist
- `ci-scripts/readme.sh`, `quay_readme.sh` — push the per-image `docs/core-*/README.md` to Dockerhub/Quay

`FILE_LIMITS` gating: on feature branches the pipeline only builds images whose `files:` globs in `template-vars.yaml` actually changed. `develop` and `release/*` branches build everything. `UNIVERSAL_CHANGE_FILES` (at the top of `template-vars.yaml`) is the set of paths that force rebuilding every image — edit those conservatively.

## Common tasks

**Add support for a new distro version:**

1. Add a block to `template-vars.yaml` (`images:` list) with its name, base image, dockerfile, and change-file globs
2. Create `src/<distro>/install/` trees if a new family (usually just reuse ubuntu/fedora/alpine/etc.)
3. Add `docs/core-<distro>/` with `README.md`, `description.txt`, `demo.txt`
4. Verify change-file globs pick up the right paths on feature-branch builds

**Add a new in-container feature (e.g., new passthrough device):**

1. Create `src/ubuntu/install/<feature>/install_<feature>.sh` (and peers for other distro families)
2. Add `COPY` + `RUN bash $INST_SCRIPTS/<feature>/install_<feature>.sh` to every relevant dockerfile
3. If the feature needs a runtime process: drop a unit file at
   `src/common/kasm-go/units/<feature>.service` (and `.socket` for socket
   activation). Use `After=` / `Requires=` to slot it into the dep graph.
   Validate locally with `make -C src/common/kasm-go test` plus a build —
   the Dockerfile's `container-init --strict-units --validate` gate
   fails the build on any parse warning.
4. Add the path to `UNIVERSAL_CHANGE_FILES` in `template-vars.yaml` so all images rebuild on change

**Debug a failing image at runtime:**

- Start with `-e VNC_PW=password` and connect to `https://<host>:6901` as `kasm_user` / `password`
- Check `/var/log/kasm-*` and the container's stdout — container-init tags
  each line with `[unit-name]` so you can attribute output to its service.
- For boot-time issues, set `-e CONTAINER_INIT_TRACE=1` and inspect
  `/tmp/container-init-trace.jsonl` — per-phase `dt_ms`, unit start
  events, and `mem_snapshot` labels.
- If running inside a real Kasm deployment, logs are forwarded to the
  Kasm API via `KASM_API_JWT` / `KASM_API_HOST` / `KASM_API_PORT`.

## Conventions / gotchas

- **Install scripts run at build time only.** `$INST_SCRIPTS` is removed after each install step — do not reference it from runtime code.
- **Downstream images inherit everything.** Be conservative when adding packages; a 50MB addition to a core image fans out across every application image.
- **Multi-arch.** Every dockerfile must work on both `amd64` and `arm64`. Shell out to `$(arch)` or `dpkg --print-architecture` rather than hardcoding.
- **No secrets in images.** Anything in `$HOME/kasm-default-profile` ships in the public image.
- **Cleanup matters.** Each feature's install script is expected to remove its own build-time caches before the layer closes (`apt clean`, `rm -rf /var/lib/apt/lists/*`, etc.) — missing cleanup bloats every downstream image.
- **`dockerfile-kasm-core` is the reference.** The other 6 dockerfiles are variants with equivalent structure; when adding a feature, update them all in the same commit to avoid drift. Use `grep -n` across all 7 first — some have subtle ordering differences (kasmos has no VirtualGL; sysbox is per-distro).
- **Upstream syncs use rerere.** This repo has `rerere.enabled=true rerere.autoupdate=false` set in `.git/config`. After a `git merge kasm/develop`, resolve conflicts manually once; identical conflict signatures auto-replay on subsequent syncs (the `vnc_startup.sh` modify/delete and the `install_kasm_upload_server.sh` `COMMIT_ID` bump are recurring offenders). Don't enable `rerere.autoupdate` — manual staging is the safety net.

## License

See `LICENSE.md` (Kasm Technologies license, not OSS).
