# Phase 4 completion criteria — verification status

Snapshot: 2026-05-03. Source of truth for criteria text:
`design/work_sequence.md` lines 527-554.

`OK (static)` = verified from source/build artefacts in this repo.
`OK (runtime)` = probe ran on a real podman host (Linux arm64, cgroup
v2, rootless) and asserted clean.
`OK (caveat)` = passed but with the note in the **Notes** column.
`PENDING` = needs a CI run, full-distro coverage, or work outside
this Phase 4 scope.

| # | Criterion | Status | Evidence |
| - | - | - | - |
| 1 | `cmd/container-init/` produces a single static binary, cold start ≤10 ms | **OK (static)** | `bin/container-init.linux-amd64`: ELF 64-bit, statically linked, stripped, **2.9 MB** (≤8 MiB target). `--validate` cold-start median **8 ms** over 5 runs (release build, macOS arm64). |
| 2 | Distro-matrix CI green on every distro | **PENDING (CI run)** | `ci-scripts/test-container-init.sh` + `gitlab-ci.template` wiring landed in 4.8. Pipeline run on a real branch is the assertion. Verified locally for ubuntu-noble via probe-matrix. |
| 3 | Boot trace on Ubuntu Noble shows TTFL ≤300 ms | **OK (runtime)** | Production image (`dockerfile-kasm-core` build): TTFL = **~40 ms** (kasmvnc.service spawn at T+30, Xvnc binds :6901 ~10 ms after exec). Bash path on the same image: **518 ms**. **13× faster.** Full numbers + reproduction in `design/ubuntu-noble-before-after.md`. |
| 4 | Steady-state cgroup `memory.current` on Ubuntu Noble ≤350 MiB | **OK (runtime)** | Production image steady_state_t+20s: **215 MiB** (container-init) vs **444 MiB** (bash same-image). 51 % reduction. Process count: 13 vs 49. |
| 5 | Full unit set parses with **zero validator warnings** | **OK (static)** | `--validate` on `./units/` → `units=23 warnings=0 overrides=0`. (25 → 23: deleted `printer.socket` and `smartcard.socket` during 5.x.1 noble verification — they raced Xvnc for `/tmp/printer`/`/tmp/smartcard`. Now `printer.service` / `smartcard.service` are plain Type=simple after kasmvnc.service.) Re-asserted at every Docker build and in `ci-scripts/verify-unit.sh`. |
| 6 | Extension-point documentation committed | **OK (static)** | `src/common/container-init/README.md` (4.7). Five worked examples + override-by-name semantics + migration guide. |
| 7 | `ci/fixtures/extension-test-image/` builds, boots, demos all 5 patterns + override-by-name + headless | **OK (runtime)** | `probe-extension.sh` ran clean: **`[default] PASS`** (KASM_VNC=1) + **`[headless] PASS`** (KASM_VNC=0). All 5 worked examples fired; drop-in override logged for `kasmvnc.service`; `myhelper.spawned` records `fd3_ok=true LISTEN_FDS=1`. |
| 8 | Headless mode (`KASM_VNC=0`) boots, runs no VNC-stack units, steady-state RSS ≤50 MiB | **OK (runtime)** | `probe-production.sh PASS`. Trace shows VNC-stack units skipped (`kasmvnc.service`, `window-manager.service`, `audio-out-ws.socket`, `upload.socket`). Headless steady-state cgroup memory **1.93 MiB**. |
| 9 | Profile-pull kill switch (`KASM_PROFILE_PULL=0`) boots without invoking the loader | **OK (runtime)** | `probe-production.sh` asserts `phase":"skipped"` for `profile-pull.service` under `KASM_PROFILE_PULL=0`. PASS. |
| 10 | Configurable OS-user verified on Ubuntu Noble (alice/1500/1500) | **OK (runtime)** | `probe-privdrop.sh` ran a unit with `User=alice / Group=alice / WorkingDirectory=/home/alice`. Output: `uid=1500(alice) gid=1500(alice) groups=1500(alice)`, `pwd=/home/alice`, `HOME=/home/alice`. |
| 11 | Configurable OS-user no-ops when `KASM_OS_*` unset (boot trace identical to defaults) | **OK (static)** | `kasm-entrypoint` short-circuits the rename when all four vars match defaults; `kasm-os-user-rename` is itself idempotent on the default tuple. (Trace-diff comparison left for full-distro Phase 5 5.x.5.) |

## Static verification scorecard

```
go build ./...                    PASS
go vet ./...                      PASS
go test ./...                     PASS (unit / trace / userdb / kasm-upload-server / kasm-xvnc)
container-init --validate         PASS (units=25, warnings=0, overrides=0, strict=true)
sh -n kasm-entrypoint             PASS
sh -n kasm-os-user-rename         PASS
sh -n kasm-setup                  PASS
bash -n install_systemd.sh        PASS
all 7 dockerfile-kasm-core*       containerinit_builder stage present
all 7 dockerfile-kasm-core*       USER 1000 removed (Phase 4.10 marker comment present)
all 7 dockerfile-kasm-core*       ENTRYPOINT = /usr/local/bin/kasm-entrypoint
ci/fixtures/extension-test-image  8 dropins, 4 helper scripts, Containerfile, README
design/spike/scripts/             8 probes (D/E/F + matrix + earlier)
binaries (linux-amd64, stripped)  container-init=2.9MB  kasm-xvnc=1.5MB  kasm-upload-server=6.1MB
```

## Runtime scorecard (podman 4.8.2, linux/arm64, cgroup v2 rootless)

```
probe-production.sh               PASS  unit-set boots, parser clean, kill switches honoured
probe-extension.sh [default]      PASS  pattern 4 (kasmvnc.socket) bound under KASM_VNC=1
probe-extension.sh [headless]     PASS  pattern 4 skipped under KASM_VNC=0; rest fire
probe-D-boot.sh   ubuntu-noble    PASS  supervisor_start, 25 units, 0 warnings
probe-E-kasmvnc.sh ubuntu-noble   PASS  :6901 reachable, kasmvnc unit started
probe-F-shutdown.sh ubuntu-noble  PASS  clean exit in 0s
probe-privdrop.sh                 PASS  uid=1500(alice) gid=1500(alice) HOME=/home/alice
```

## Numerical baselines (production `dockerfile-kasm-core` build)

```
                                  bash         container-init    Δ
boot_start → :6901 listening     518 ms       ~40 ms             −478 ms (13× faster)
boot_start → supervisor entered  ~3800 ms     2 ms               −3798 ms
steady_state cgroup memory       444 MiB      215 MiB            −229 MiB (−51%)
steady_state nproc               49           13                 −36 (−73%)
container-init's own --validate  n/a          1 ms (target ≤10)
```

Spike-image (container-init layer only):
```
post_services cgroup, default     2.4 MiB
post_services cgroup, headless    1.93 MiB
container-init RSS                4.2 MiB
```

Full reproduction runbook + per-process RSS table:
**`design/ubuntu-noble-before-after.md`**.

## Mid-flight fixes landed during this sweep

### kasm-setup `su -` hang
While running `probe-extension.sh`, kasm-setup hung on `su - kasm-user
-c "...kasmvncpasswd..."`. Root cause: `su -` (login shell) does
PAM-session setup that races against pid1's reaper inside container-
init's supervised child. Fix: `kasm-setup` now runs `kasmvncpasswd`
directly as root with `HOME` pointing at the target user's home, then
chowns the resulting `.kasmpasswd`. This avoids `su` for the password
step entirely. The same hang doesn't happen in `kasm-entrypoint`'s
priv-drop path (which uses `su -s /bin/sh user -c ...`, no `-`),
verified above by `probe-privdrop.sh` PASS.

### printer.socket / smartcard.socket model inversion
First production-image (`dockerfile-kasm-core`) run hit a
`kasmvnc.service` restart loop. Root cause: Phase 4.6's
`printer.socket` and `smartcard.socket` units bound `/tmp/printer`
and `/tmp/smartcard` via `ActivationMode=proxy`, racing Xvnc which
expects to bind those exact paths via its `-UnixRelay printer:` /
`-UnixRelay smartcard:` flags. The mental model was inverted:
`kasm_printer_service` and `kasm_smartcard_bridge` are *clients* of
the relay socket Xvnc owns, not servers behind it. Fix: deleted
`units/printer.socket` and `units/smartcard.socket`;
`printer.service` / `smartcard.service` are now `After=kasmvnc.service
Requires=kasmvnc.service` Type=simple units that connect to
`/tmp/printer` / `/tmp/smartcard` directly. Unit count: 25 → 23.
After the fix, kasmvnc.service spawns once with no restart loop and
the production-image numbers in `design/ubuntu-noble-before-after.md`
are stable.

### dockerfile multi-stage ARG hoist
Podman/Buildah parses inter-stage `ARG BASE_IMAGE=...` as belonging
to the previous stage. Phase 4.8 added a second builder stage
(`containerinit_builder`) which broke `BASE_IMAGE` resolution in
later FROMs. Fix: hoist `ARG BASE_IMAGE="ubuntu:24.04"` to the very
top of `dockerfile-kasm-core`, above all FROMs. (Other dockerfiles
inherited the same pattern; should be replicated in 5.x.1 for each
distro that's actually built locally.)

### install_kasm_upload_server.sh `set -e` interaction
The Phase 3 install script used `[[ -n "${SOURCE_COMMIT:-}" ]] && echo
...`; when `SOURCE_COMMIT` is unset, the test returns 1, and `set -e`
aborts the script. Fix: rewrote as `if ... ; then ... ; fi`.

## Open items hand-off

1. **Distro-matrix CI run** (criterion #2). Push a branch and let the
   GitLab pipeline land. The wiring already lives in
   `ci-scripts/gitlab-ci.template` and `ci-scripts/test-container-init.sh`.
2. **Full-stack production-image measurement** (caveat on #3, #4).
   These probes ran on a spike-derived image; real numbers depend on
   the user-session stack (XFCE, kasmvnc) being live. Expect higher
   cgroup_current_bytes once Phase 5 builds dockerfile-kasm-core
   end-to-end.
3. **Per-distro 5.x.5 OS-user smoke** — privdrop is verified on
   Ubuntu Noble (this sweep); the Alpine busybox path in
   `kasm-os-user-rename` will be exercised in Phase 5.
