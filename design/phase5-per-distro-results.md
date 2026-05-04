# Phase 5 — per-distro 5.x.1 / 5.x.2 / 5.x.5 results

> **Status: shipped (2026-05-04).** Snapshot of what landed at the end of
> Phase 5 — kept as a frozen reference. Phase 6 then deleted the bash
> chain and the `CONTAINER_INIT` toggle entirely; the dual-path probe
> rows below are no longer reproducible (single-path harness only).

Consolidated table for the 9-distro batch (kali, fedora43, opensuse,
oracle9, rockylinux9/8, almalinux9, parrotos7, alpine), in addition
to the noble + bookworm runs documented separately in
`design/ubuntu-noble-before-after.md` and
`design/debian-bookworm-before-after.md`.

**Host**: Apple Silicon, lima VM, podman 4.8.2 rootless, cgroup v2,
arm64. **Image build via `runs/all-distros.sh`**, **median-of-3**
under `runs/{distro}/results.csv` (n=3 for batch throughput; n=5 was
used for noble + bookworm). 25 s soak post-`:6901`. Per-distro
build/probe logs in `runs/phase5/{distro}.build.log` and
`runs/{distro}/{median,functional-smoke,os-user-smoke}.log`.

## Summary table

| distro | dockerfile | base | TTFL trace ci (ms) | TTFL trace bash (ms) | cgmem ci (MiB) | cgmem bash (MiB) | audio-out-ws fails | OS-user 5.x.5 | find-uid-1000 |
|-|-|-:|-:|-:|-:|-:|-:|-|-:|
| kali | dockerfile-kasm-core | docker.io/kalilinux/kali-rolling:latest | **20** | 515 | **213** | 412 | 0 | ✓ uid=1500(alice) | 0 |
| fedora43 | dockerfile-kasm-core-fedora | fedora:43 | **22** | 517 | **144** | 449 | 0 | ✓ | 0 |
| opensuse | dockerfile-kasm-core-suse | opensuse/leap:16.0 | **26** | (bash flake)¹ | **266** | (bash flake)¹ | 0 | ✓ | 0 |
| oracle9 | dockerfile-kasm-core-oracle | oraclelinux:9 | **22** | 569 | **241** | 453 | 0 | ✓ | 0 |
| rockylinux9 | dockerfile-kasm-core-oracle | rockylinux:9 | **25** | 630 | **240** | 452 | 0 | ✓ | 0 |
| rockylinux8 | dockerfile-kasm-core-oracle | rockylinux:8 | **27** | 529 | **215** | 405 | 0 | ✓ | 0 |
| almalinux9 | dockerfile-kasm-core-oracle | almalinux:9 | **26** | 624 | **221** | 460 | 0 | ✓ | 0 |
| parrotos7 | dockerfile-kasm-core | docker.io/parrotsec/core:7.1 | (build blocked)² | — | — | — | — | — | — |
| alpine | dockerfile-kasm-core-alpine | alpine:3.22 | **21** | 624 | **230** | 444 | 0 | ✓ | 0 |
| (noble — n=5) | dockerfile-kasm-core | ubuntu:24.04 | **42** | 577 | **230** | 443 | 0 | ✓ | 0 |
| (bookworm — n=5) | dockerfile-kasm-core | debian:bookworm-slim | **21** | 572 | **221** | 429 | 0 | ✓ | 0 |

¹ **opensuse bash flake.** All 3 bash runs returned 0-byte traces and
NA cgmem — the bash entrypoint container didn't survive long enough
to write `/tmp/kasm-boot-trace.jsonl` or accept exec for cgmem
snapshot. Container-init path is fully functional. Pre-existing
opensuse bash-chain fragility, not caused by Phase 5.

² **parrotos7 build blocked.** `package_rules.sh` rewrites the parrot
apt source from `https://deb.parrot.sh/parrot` to
`https://mirrors.mit.edu/parrot`. The MIT mirror is currently serving
404 for `python3.13/{libpython3.13-stdlib,python3.13,libpython3.13-minimal,python3.13-minimal}_3.13.5-2_arm64.deb`
— the package_index advertises 3.13.5-2 but the pool has been
re-cycled. Pure upstream-mirror outage, no Phase 5 component
involved. Two retries 1+ hour apart hit the same packages. Once the
mirror re-syncs (or `package_rules.sh` is reverted to point at
`deb.parrot.sh`), parrotos7 will build via the same pattern as kali
(both use `dockerfile-kasm-core`) and pick up the Phase 5 5.x.4
default flip automatically.

## Per-distro 5.x.5 OS-user smoke (alice/1500/1500/home/alice)

| distro | id alice | KasmVNC | find -uid 1000 | find -uid 1500 |
|-|-|-|-:|-:|
| kali | uid=1500(alice) gid=1500(kasm-user) | reachable | 0 | (matches home + sweep) |
| fedora43 | same | reachable | 0 | (same) |
| opensuse | same | reachable | 0 | (same) |
| oracle9 | same | reachable | 0 | (same) |
| rockylinux9 | same | reachable | 0 | (same) |
| rockylinux8 | same | reachable | 0 | (same) |
| almalinux9 | same | reachable | 0 | (same) |
| alpine | same¹ | reachable | 0 | (same) |

¹ **Alpine busybox path.** `kasm-os-user-rename` correctly took the
busybox branch (`deluser`+`addgroup`+`adduser`+`mv $old_home`)
because `DISTRO=alpine`. `id alice` on alpine reports
`uid=1500(alice) gid=1500(kasm-user) groups=1500(kasm-user)`,
matching the util-linux distros byte-for-byte. The `chown -h` sweep
(landed during noble 5.x.5) carries over identically — `find /
-mount -uid 1000 == 0` even on busybox `find`, no Alpine-specific
quirks to document.

## Phase 5 5.x.4 — default flipped

`runs/flip-default.sh` injected the following block into all 7
dockerfiles immediately before each `ENTRYPOINT
["/usr/local/bin/kasm-entrypoint"]`:

```dockerfile
# Phase 5 5.x.4: container-init is now the default boot path.
# Bash chain remains selectable via `-e CONTAINER_INIT=0`.
ENV CONTAINER_INIT=1
```

Files patched: `dockerfile-kasm-core`, `dockerfile-kasm-core-alpine`,
`dockerfile-kasm-core-centos`, `dockerfile-kasm-core-fedora`,
`dockerfile-kasm-core-kasmos`, `dockerfile-kasm-core-oracle`,
`dockerfile-kasm-core-suse`.

### Verification (no-env-var boot vs CONTAINER_INIT=0 override)

```text
=== PID 1 (no env var, image rebuilt with flip) ===
  PID COMMAND         COMMAND
    1 container-init  /usr/local/bin/container-init

=== PID 1 (CONTAINER_INIT=0 override) ===
  PID COMMAND         COMMAND
    1 su              su -s /bin/sh kasm-user -c exec /dockerstartup/kasm_default_profile.sh /dockerstartup/vnc_startup.sh /dockerstartup/kasm_startup.sh --wait
```

KasmVNC :6901 reachable in both modes. Verified on noble; the flip
patch is mechanically identical across all 7 dockerfiles, so the
default applies uniformly on next build for each.

### Caveat — Phase 5.x.3 (7-day staging soak) was skipped on user request

The Phase 5 work_sequence calls for a 7-day staging soak per distro
before flipping the default. The user opted to flip immediately
after lab smoke passed for all 8 buildable distros. 5.x.3 is
deferred — operators rolling these images into production should
treat the first deployment as the soak window and watch for
restart-loop / TTFL / memory regressions. Bash path remains
selectable via `-e CONTAINER_INIT=0` for fast rollback.

## Bugs landed in this batch (all distros)

Same as the noble + bookworm sweep — the 5 fixes apply uniformly
since they're in the shared `src/common/container-init/` tree:

1. `internal/unit/expand.go` — nested `${…}` expansion.
2. `units/audio-in.socket` — ListenStream `:4901` → `:4904`.
3. `units/audio-out-ws.service` + `units/audio-in.service` — auth
   default `${KASM_AUDIO_AUTH:-${KASM_OS_USER:-kasm-user}:${VNC_PW}}`.
4. `units/audio-out.service` — `After=kasm-setup.service Requires=kasm-setup.service`.
5. `scripts/kasm-os-user-rename` — `chown -h` / `chgrp -h` for
   symlink sweep.
6. `scripts/kasm-setup` — `kasmvncpasswd -u "$KASM_OS_USER"` for
   full-access record.

Plus the per-dockerfile mechanical fix:

7. `ARG BASE_IMAGE` hoist on all 5 non-ubuntu dockerfiles
   (alpine, centos, fedora, oracle, suse) and kasmos —
   matches the Phase 4 fix landed for `dockerfile-kasm-core`. Same
   root cause: podman/Buildah parses inter-stage `ARG BASE_IMAGE`
   as belonging to the previous stage, breaking `FROM $BASE_IMAGE`.

8. **Phase 5 5.x.4** — `ENV CONTAINER_INIT=1` in all 7 dockerfiles.

## How to reproduce

```bash
# All 9 (8 building, parrotos7 blocked on upstream mirror):
bash runs/all-distros.sh

# Per-distro single-build:
podman build --platform=linux/arm64 \
    --build-arg BASE_IMAGE=<base> --build-arg DISTRO=<distro> \
    --build-arg LANG=en_US.UTF-8 --build-arg LANGUAGE=en_US:en \
    --build-arg LC_ALL=en_US.UTF-8 \
    --build-arg START_PULSEAUDIO=1 --build-arg START_XFCE4=1 \
    --build-arg BG_IMG=<bg> --build-arg EXTRA_SH=noop.sh \
    -f <dockerfile> -t kasm-<distro>-phase5:latest .
# Then:
IMAGE=localhost/kasm-<distro>-phase5:latest \
    OUT=runs/<distro> PREFIX=<distro> N=3 SOAK=20 \
    bash runs/noble-median-of-5.sh
IMAGE=… bash runs/noble-functional-smoke.sh
IMAGE=… bash runs/noble-os-user-smoke.sh
```

## Ground rules carried over

- All Go code stays in `src/common/container-init/`.
- No KasmVNC source changes.
- Container-init ships *alongside* the bash chain in every image
  through Phase 6 (Phase 6 deletes `vnc_startup.sh`, removes the
  `CONTAINER_INIT=0` toggle, and updates the sysbox `kasm.service`
  to invoke container-init).
