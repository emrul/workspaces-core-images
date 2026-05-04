# Debian Bookworm — boot-time + memory before/after

End-to-end comparison of `dockerfile-kasm-core` (Debian Bookworm
base, `BASE_IMAGE=debian:bookworm-slim`) running under the legacy
bash chain vs `container-init` (Phase 4). **Both columns measured on
the same image, same host, same options — `kasm-entrypoint` chooses
the path at boot via the `CONTAINER_INIT` env var.**

**Host**: Apple Silicon, lima VM, podman 4.8.2 rootless, cgroup v2,
arm64. **Image**: `localhost/kasm-bookworm-phase5:latest`, built from
this branch via `dockerfile-kasm-core` with
`BASE_IMAGE=debian:bookworm-slim DISTRO=debian
BG_IMG=bg_debian.svg`. **Run options**: `KASM_PROFILE_PULL=0
VNC_PW=vncpassword`, no client connected, 25 s soak before snapshot.
**Median-of-5** under Phase 5 5.x.2; per-run data in
`runs/bookworm/results.csv` and `runs/bookworm/{ci,bash}-N.trace.jsonl`.

> Source-of-truth note: the Phase 5 session prompt initially mapped
> debian-bookworm to `dockerfile-kasm-core-kasmos`; that file is the
> KasmOS *KDE* variant and depends on the `kasm-desktop-kde`
> submodule (not initialised in this checkout, build fails at
> `COPY ./kasm-desktop-kde/src`). `ci-scripts/template-vars.yaml`'s
> `name1: debian, name2: bookworm` entry uses `dockerfile:
> dockerfile-kasm-core`; that is what was built and measured here.
> `dockerfile-kasm-core-kasmos` did receive the Phase 4 ARG-hoist
> fix in this sweep (it had the same multi-stage `ARG BASE_IMAGE`
> placement issue as `dockerfile-kasm-core`), but is not exercised
> on the Phase 5 distro list.

## End-to-end boot time

Definitions match `design/ubuntu-noble-before-after.md` (TTFL trace =
in-trace `kasmvnc_port_open.dt_ms` for bash / `kasmvnc.service spawn
dt_ms` for container-init; TTFL extern = host-side `/dev/tcp` poll
via `podman exec`).

| Milestone                                  | Bash                                  | container-init           | Δ                          |
| -                                          | -:                                    | -:                       | -:                         |
| boot_start → kasmvnc.service spawn         | n/a (inlined)                         | **21 ms** median (n=5; range 21–37) | —                |
| **TTFL trace median (n=5)**                | **571.5 ms** (n=4; range 571–620)     | **21 ms**                | **−550 ms (~27× faster)**  |
| **TTFL extern median (n=5)**               | **983 ms**                            | **453 ms**               | **−530 ms (~2× faster)**   |

As with noble, one bash run had a 0-byte trace capture (`bash-1`);
the `kasm_pre_shutdown_user.sh` truncation pattern repeats on bookworm
verbatim. n=4 medians for the bash-trace TTFL.

## Steady-state memory (cgroup `memory.current`)

| Snapshot                    | Bash                          | container-init                | Δ                       |
| -                           | -:                            | -:                            | -:                      |
| **steady_state t+25s** (median n=5) | **429 MiB** (range 429–432)   | **221 MiB** (range 220–223)   | **−208 MiB (−48 %)**    |

Bookworm is ~14 MiB lighter than noble under both paths at steady
state (debian-slim vs ubuntu, fewer transitive packages). The
container-init delta is essentially identical, dominated by lazy
helpers staying idle.

## Process count

| Snapshot                | Bash | container-init | Δ                    |
| -                       | -:   | -:             | -:                   |
| **steady (median n=5)** | **44** | **16**       | **−28 (−64 %)**      |

## 5.x.2 functional smoke

Captured in `runs/bookworm/functional-smoke.log`. Same matrix as noble.

| Run             | Path                                          | KasmVNC :6901          | upload-server :4902     | VNC-stack units running |
| -               | -                                             | -:                     | -:                      | -                       |
| `bash-vnc`      | bash, `KASM_VNC=1`                            | ✓ (TCP)                | ✓ (HTTPS server replies 400) | full XFCE + audio + helper stack |
| `ci-vnc`        | container-init, `KASM_VNC=1`                  | ✓ (TCP)                | ✓ (TCP; Go binary)      | container-init + Xvnc + xfce4-session + ffmpeg + pcscd + pulseaudio + printer + smartcard |
| `ci-headless`   | container-init, `KASM_VNC=0`                  | NOT BOUND              | NOT BOUND               | only container-init + dbus-daemon |

Identical pass profile to noble — same 20 units skipped under
`KASM_VNC=0`, same lazy-helper pattern under `KASM_VNC=1`.

## 5.x.5 KASM_OS_USER end-to-end smoke

Captured in `runs/bookworm/os-user-smoke.log` and
`runs/bookworm/osuser-{alice,default}.trace.jsonl`. Image rebuild
includes the `chown -h` fix in `kasm-os-user-rename` landed during
noble 5.x.5.

Run 1: `KASM_OS_USER=alice KASM_OS_UID=1500 KASM_OS_GID=1500 KASM_OS_HOME=/home/alice`.

- `id alice` → `uid=1500(alice) gid=1500(kasm-user) groups=1500(kasm-user)` ✓
- `/etc/passwd`: `alice:x:1500:1500::/home/alice:/bin/sh` ✓
- `/home/alice` populated, owned by `alice` ✓
- KasmVNC :6901 reachable ✓ (verified by isolated re-probe; smoke
  script's KasmVNC echo line was racy and printed empty —
  `runs/bookworm/osuser-alice.trace.jsonl` shows
  `kasmvnc.service spawn` and `kasmvnc_invoke` cleanly)
- `find / -mount -uid 1000` → **count=0** (chown -h fix in effect) ✓
- `find / -mount -uid 1500` → 293 files

Run 2: defaults — `id kasm-user` → `uid=1000(kasm-user) gid=1000(kasm-user)` ✓

### Quirks documented (5.x.5 — bookworm-specific)

None. Same `groupmod -n` "GID name preserved" behaviour as noble (by
design). `usermod -m -l` works identically under shadow on debian as
under util-linux on ubuntu.

### Phase 4 bugs surfaced — same set as noble, all fixed in this sweep

- `audio-out.service` priv-drop race when `KASM_OS_USER` differs
  from default. Fix landed in `units/audio-out.service`
  (`After=kasm-setup.service Requires=kasm-setup.service`).
- `audio-out-ws.service` restart loop. Real root cause was an
  `audio-in.socket` port collision on `:4901`, not the auth token.
  Three landed fixes (nested `${…}` expander, `audio-in.socket
  :4901→:4904`, audio auth token `${KASM_AUDIO_AUTH:-${KASM_OS_USER:-kasm-user}:${VNC_PW}}`)
  plus `kasmvncpasswd -u "$KASM_OS_USER"` in `kasm-setup`. See
  `design/ubuntu-noble-before-after.md` for full detail.

  **After-fix verification (bookworm):** `audio-out-ws.service`
  spawns=1, failed_exits=0 in both `osuser-alice.trace.jsonl` and
  `osuser-default.trace.jsonl` (was 43+/43+ pre-fix).

## How to reproduce

```bash
podman build --platform=linux/arm64 \
    --build-arg BASE_IMAGE=debian:bookworm-slim \
    --build-arg DISTRO=debian \
    --build-arg LANG=en_US.UTF-8 --build-arg LANGUAGE=en_US:en \
    --build-arg LC_ALL=en_US.UTF-8 \
    --build-arg START_PULSEAUDIO=1 --build-arg START_XFCE4=1 \
    --build-arg BG_IMG=bg_debian.svg --build-arg EXTRA_SH=noop.sh \
    -f dockerfile-kasm-core -t kasm-bookworm-phase5:latest .

# Median-of-5 dual-path probe.
N=5 SOAK=25 bash runs/bookworm-median-of-5.sh

# 5.x.5 + functional smoke.
bash runs/bookworm-os-user-smoke.sh
bash runs/bookworm-functional-smoke.sh
```

## Caveats

Same as noble:
- ARM64 host; x86_64 absolute numbers will drift slightly.
- No client connected; lazy-helper savings shrink under active sessions.
- Single ARM64 host; staging soak (5.x.3) under real workloads is
  the next gate before flipping `CONTAINER_INIT=1` as the default.
