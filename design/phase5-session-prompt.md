# Phase 5 — Session prompt

Use this as the opening message in a new Claude Code session to pick
up Phase 5 (per-distro rollout of `container-init`). Trim or extend
the distro list to match scope at the time the session starts.

---

You are picking up **Phase 5: per-distro rollout of `container-init`**
on the kasm `workspaces-core-images` repo. Phase 4 just landed: the
Go supervisor (`src/common/container-init/`), the production unit
set, the extension point + fixture, the distro-matrix CI wiring, and
the configurable `KASM_OS_USER` path. The runtime sweep on Ubuntu
Noble (spike-derived image) is green. The bash chain is still the
default ENTRYPOINT path; Phase 5 flips it on a distro-by-distro
basis.

## Read first (in order)

1. `design/work_sequence.md` — Phase 5 section (around line 561).
   Includes the trimmed distro list and the 5.x.1 → 5.x.5 task shape.
2. `design/phase4-completion-status.md` — what landed, what numbers
   look like, the one mid-flight fix (`kasm-setup` `su` hang), and
   the open hand-off items.
3. `design/ubuntu-noble-before-after.md` — Phase 0 baseline numbers
   plus the Phase 4 measurements. Phase 5 5.x.2's job is to fill in
   the per-distro version of this table.
4. `src/common/container-init/README.md` — extension-point contract.
   Image authors who layer drop-ins will hit this; you may field
   questions about it during 5.x.3 soak.
5. `ci-scripts/test-container-init.sh` + `ci-scripts/gitlab-ci.template`
   — the CI wiring. Each distro gets a `CONTAINER_INIT=1` smoke pass
   in its `test_<name>_<variant>` job alongside the existing tests.

## Distro list (trim/edit to taste at session start)

In **this order** (overlap allowed once one or two distros are in
soak; aim for two parallel soaks max):

```
ubuntu noble
debian bookworm
kali
fedora43
opensuse
oracle9
rockylinux9
rockylinux8
almalinux9
parrotos7
alpine
```

Map these to `dockerfile-kasm-core*`:

| Distro     | Dockerfile                       | BASE_IMAGE arg                  |
| ---------- | -------------------------------- | ------------------------------- |
| ubuntu noble | `dockerfile-kasm-core`         | `ubuntu:24.04`                  |
| debian bookworm | `dockerfile-kasm-core-kasmos`| `debian:bookworm-slim`          |
| kali       | `dockerfile-kasm-core`           | `kalilinux/kali-rolling:latest` |
| fedora43   | `dockerfile-kasm-core-fedora`    | `fedora:43`                     |
| opensuse   | `dockerfile-kasm-core-suse`      | `opensuse/leap:16.0`            |
| oracle9    | `dockerfile-kasm-core-oracle`    | `oraclelinux:9`                 |
| rockylinux9 | `dockerfile-kasm-core-centos`   | `rockylinux:9`                  |
| rockylinux8 | `dockerfile-kasm-core-centos`   | `rockylinux:8`                  |
| almalinux9 | `dockerfile-kasm-core-centos`    | `almalinux:9`                   |
| parrotos7  | `dockerfile-kasm-core`           | `parrotsec/security:latest`     |
| alpine     | `dockerfile-kasm-core-alpine`    | `alpine:3.19`                   |

Resolve each `BASE_IMAGE` against `ci-scripts/template-vars.yaml`
before building — that file is the source of truth.

## Per-distro task shape (each distro takes ~7 calendar days)

For each distro `<D>`:

### 5.<D>.1 — Build the image, run both paths
- One `podman build` of the dockerfile produces a single artefact;
  `kasm-entrypoint` picks bash vs container-init at run time based
  on `CONTAINER_INIT`. **Don't build twice — it's the same image,
  exercised under two env settings.**
- For multi-stage dockerfiles where podman hits "no FROM statement
  found" because of an inter-stage `ARG BASE_IMAGE`, hoist the ARG
  to the very top of the file (above the first FROM). This already
  landed for `dockerfile-kasm-core` in Phase 4; replicate per-distro
  if you build locally with podman.
- Boot the image twice:
  - Bash: `-e KASM_BOOT_TRACE=1 -e KASM_PROFILE_PULL=0 -e VNC_PW=vncpassword`
  - container-init: `-e CONTAINER_INIT=1 -e CONTAINER_INIT_TRACE=1
    -e KASM_VNC=1 -e KASM_PROFILE_PULL=0 -e VNC_PW=vncpassword`
- 25-second soak (or longer) so `steady_state_t+20s` is captured.
- The exact runbook lives in `design/ubuntu-noble-before-after.md`
  under "How to reproduce".

### 5.<D>.2 — Compare boot trace JSONL
- Diff the two traces. The container-init path should drop TTFL by
  ~280 ms vs the bash baseline (Phase 0 reference: ~580 ms median).
- Verify functional smoke tests (KasmVNC connect, audio, clipboard,
  upload, no-vnc-stack-when-`KASM_VNC=0`) pass under both paths.
- File a row in `design/<distro>-before-after.md` mirroring the
  ubuntu-noble template.

### 5.<D>.3 — Soak in staging (7 calendar days)
- Push the `CONTAINER_INIT=1` image to staging for that distro.
- Watch crash reports, restart storms, profile-sync failures.
- The `OnFailure` chain + `ExitContainerOnFailure=true` units mean
  any unrecoverable failure should exit the container cleanly, not
  hang. Investigate any container that hangs > 60 s post-failure.

### 5.<D>.4 — Flip the default
- Change the dockerfile's `ENV CONTAINER_INIT` (if introduced) to
  default `1`, or — equivalent — remove the toggle and bake
  `CONTAINER_INIT=1` into the image. Bash path remains selectable
  via `CONTAINER_INIT=0` until Phase 6.

### 5.<D>.5 — KASM_OS_USER smoke
- Boot the image with
  `KASM_OS_USER=alice KASM_OS_UID=1500 KASM_OS_GID=1500
  KASM_OS_HOME=/home/alice`. Verify:
  - `id` reports `uid=1500(alice) gid=1500(alice) groups=1500(alice)`
  - `pwd` and `$HOME` resolve to `/home/alice`
  - KasmVNC accepts a connection
  - `find / -mount -uid 1000` returns empty
- Critical on Alpine — busybox `usermod` lacks `-l`/`-m`, so
  `kasm-os-user-rename`'s busybox branch (delete-and-recreate)
  fires. Document any quirks.
- Boot once more with no `KASM_OS_*` set; trace must be byte-identical
  (modulo timestamps) to the default-user run.

## Done-when

- Every distro in the list has been through 5.x.1 → 5.x.5.
- Zero regressions logged in staging during any 7-day soak.
- All distros' published images carry `CONTAINER_INIT=1` as default.
- A `design/<distro>-before-after.md` exists for every distro with
  measured TTFL + steady-state cgroup numbers under both paths.
- Alpine's busybox `kasm-os-user-rename` fallback has documented
  quirks (or a clean bill).

## Ground rules (carried over from Phase 4)

- All Go code stays in `src/common/container-init/`.
- No KasmVNC source changes.
- Container-init ships *alongside* the bash chain in every image
  until Phase 6. The flip is a runtime env var, not a code branch.
- Boot probes D/E/F (`design/spike/scripts/probe-{D,E,F}*.sh`)
  remain authoritative for boot smoke. Per-distro work should reuse
  them, parameterised by image:label.
- Don't touch `vnc_startup.sh` or the bash chain in Phase 5 —
  that's Phase 6's job.

## What I expect at hand-off after each distro

A single comment with:
- Distro name + dockerfile + base image used
- TTFL bash vs container-init (ms, with measurement runbook)
- Steady-state cgroup memory bash vs container-init (MiB)
- Functional smoke tests pass/fail
- Any hung-on-shutdown observations
- Any drop-in regressions surfaced
- Whether 5.x.5 (KASM_OS_USER) passed with no quirks

## Bug-fix watchlist (surfaced during Phase 4 noble verification)

Don't be surprised if these resurface on a different distro — re-test
each carefully:

1. **`kasm-setup` `su -` hang** — `su -` (login shell) hangs from
   container-init's supervised child on PAM-stack distros. The
   workaround running `kasmvncpasswd` as root with `HOME` override
   was applied in `scripts/kasm-setup`. If a new distro hangs at
   `kasm-setup_invoke` with no `exited` trace, suspect this.
2. **`-UnixRelay` socket conflict** — Xvnc's `-UnixRelay
   printer:/tmp/printer` makes Xvnc the listener on that path. The
   Phase 4.6 unit set's `printer.socket` / `smartcard.socket` raced
   it; both were deleted. If a future image author writes a
   `relay-something.socket` drop-in for an `Xvnc -UnixRelay X:/path`
   target, document the conflict. printer/smartcard service files
   keep the new `After=kasmvnc.service` ordering.
3. **Dockerfile `ARG BASE_IMAGE` placement** — podman/Buildah
   parses inter-stage ARGs as belonging to the previous stage. Hoist
   the ARG to the top of the file (above all FROMs) on any distro
   dockerfile that hasn't already been touched.
4. **`set -e` + `[[ -n ... ]] && echo` in install scripts** — when
   the variable is empty, the test returns 1 and `set -e` aborts.
   Use `if ... ; then ... ; fi`.

## Out of scope (don't do these in Phase 5)

- Deleting `vnc_startup.sh` (Phase 6).
- Adding new container-init features (Phase 4 froze the directive
  set; new directives are a Phase 6+ conversation).
- Changing the production unit set without a tracked issue —
  `units/` is the API surface for image authors at this point.

## First action

Pick the first distro in the list (ubuntu noble), confirm it's not
already at 5.x.4 or beyond, and start at 5.<distro>.1. If you can,
parallelise: kick off the build for distro N+1 in the background
while soaking distro N.
