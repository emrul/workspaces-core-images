# Phase 6 — Session prompt

Use this as the opening message in a new Claude Code session to pick
up Phase 6 (delete `vnc_startup.sh` and the bash-chain fallback).

---

You are picking up **Phase 6: retire `vnc_startup.sh` and the bash
path** on the kasm `workspaces-core-images` repo. Phase 5 just
landed: 8 of 9 distros (kali, fedora43, opensuse, oracle9,
rockylinux9, rockylinux8, almalinux9, alpine — plus noble + bookworm
from the prior sweep) are through 5.x.1 / 5.x.2 / 5.x.5, and
**Phase 5 5.x.4 is done — `ENV CONTAINER_INIT=1` is now baked into
all 7 dockerfiles, so container-init is the default boot path**.
Bash chain still ships in every image and is selectable via
`-e CONTAINER_INIT=0` until Phase 6 deletes it.

parrotos7 is blocked on an external mirror outage
(`mirrors.mit.edu/parrot` serving 404s for python3.13 packages
referenced from the apt index) — not a Phase 5 issue, will inherit
the Phase 6 deletes when the mirror recovers.

## Read first (in order)

1. `design/work_sequence.md` — Phase 6 section (around line 605).
   Six tasks: delete `vnc_startup.sh`, delete `kasm_startup.sh`,
   remove the `CONTAINER_INIT=0` toggle, simplify `kasm-entrypoint`,
   update docs, update sysbox install path.
2. `design/phase5-per-distro-results.md` — what landed in Phase 5,
   the bug fixes carried in (`chown -h`, audio-out-ws auth nesting,
   `audio-in.socket :4901→:4904`, `audio-out.service After=`),
   and the per-distro median TTFL + cgmem numbers.
3. `design/ubuntu-noble-before-after.md` and
   `design/debian-bookworm-before-after.md` — the n=5 baselines you
   are not allowed to regress against. Phase 6's deletions must not
   move TTFL > 50 ms or steady-state cgmem > 240 MiB on noble.
4. `src/common/scripts/kasm-entrypoint` — the dispatcher being
   simplified. Currently: bash branch + container-init branch + OS-user
   rename branch. After Phase 6: just exec container-init (the rename
   moves into kasm-setup.service, which already runs it; the branch
   here is redundant once bash is gone).
5. `src/ubuntu/install/sysbox/install_systemd.sh` — sysbox is the
   only path where container-init is *not* PID 1 (real systemd is).
   The `kasm.service` unit there must be updated to invoke
   container-init, and its hardcoded `User=kasm-user` must follow
   `${KASM_OS_USER}` per Phase 4.10.

## Tasks (in this order)

### 6.1 — Delete `vnc_startup.sh`
- `rm src/common/startup_scripts/vnc_startup.sh`.
- `git grep vnc_startup` must return zero hits afterward (one place
  refers to it via `kasm-entrypoint`'s exec; that goes in 6.3).

### 6.2 — Delete `kasm_startup.sh` references
- `kasm_startup.sh` is the third arg to vnc_startup.sh today; it's
  effectively no-op'd. Remove its callers.
- `git grep kasm_startup` must return zero hits afterward.

### 6.3 — Simplify `kasm-entrypoint` and remove the toggle
- `src/common/scripts/kasm-entrypoint` collapses to:
  ```sh
  #!/bin/sh
  set -e
  exec /usr/local/bin/container-init
  ```
  No more `CONTAINER_INIT=0` branch. No more `kasm_default_profile.sh`
  / `vnc_startup.sh` / `kasm_startup.sh` invocation. The OS-user
  rename moves into `kasm-setup.service` (it already runs there;
  delete the duplicate priv-drop block in `kasm-entrypoint`).
- Remove `ENV CONTAINER_INIT=1` from each dockerfile (it's unconditional
  now — no toggle to set).
- `git grep CONTAINER_INIT` must return zero hits afterward.

### 6.4 — Update each `dockerfile-kasm-core*`
- Drop the line above the `ENTRYPOINT`:
  `ENV CONTAINER_INIT=1` (added in Phase 5 5.x.4) — no longer needed.
- `kasm-entrypoint` is now a 4-line script; some dockerfiles may want
  to skip the COPY of it entirely and bake the exec directly into
  ENTRYPOINT (`ENTRYPOINT ["/usr/local/bin/container-init"]`). Pick
  one approach — the script-as-thin-shim form keeps the dispatch
  point if Phase 7 ever wants to add another branch.

### 6.5 — Docs sweep
- `git grep -l vnc_startup\\|kasm_startup\\|CONTAINER_INIT` to find
  any markdown / docs references. Update or delete each.
- `design/work_sequence.md` Phase 5/6 sections should be marked
  complete; consider promoting `design/phase5-per-distro-results.md`
  to a "shipped" status note.

### 6.6 — Sysbox path: container-init under real systemd
- `src/ubuntu/install/sysbox/install_systemd.sh` writes a
  `kasm.service` systemd unit. Today it execs the bash chain. Update
  to exec `/usr/local/bin/container-init` (PID 1 of the user-session
  scope, not the container).
- The unit's hardcoded `User=kasm-user / Group=kasm-user` lines must
  point at `${KASM_OS_USER}` / `${KASM_OS_GROUP}`. Phase 4.10's
  precedent: kasm-setup writes `/tmp/kasm.env` with the resolved
  user; the sysbox `kasm.service` should `EnvironmentFile=/tmp/kasm.env`
  and reference `${KASM_OS_USER}` directly. Sysbox is the *only*
  path where container-init is not PID 1; double-check the unit
  doesn't break the rename's first-boot ordering.

### 6.7 — Drop perl runtime (image-size win, ~70 MiB)

Once the bash chain is gone (6.1–6.3), nothing in the kasm core
images calls perl: `kasm-xvnc` (Phase 4.4) execs `/usr/bin/Xvnc`
directly with the argv it would have built, skipping KasmVNC's perl
`/usr/bin/vncserver` wrapper. The wrapper still exists in the
KasmVNC package but is unreferenced from container-init's path.

**Tasks:**

- Verify nothing else needs perl: `git grep -E '/usr/bin/perl|^use |#!.*perl|require [A-Z]'`
  across `src/`. Common false-positives are check-tools (in `tools/`
  which is build-time only). Anything that actually runs at boot
  must move off perl or stay (rare in Kasm core).
- After bash chain deletion, audit each distro:
  ```
  podman run --rm --entrypoint sh localhost/kasm-noble-phase6:latest \
      -c 'find /usr -type f \( -name "*.pl" -o -name "*.pm" \) | head; \
          which perl perl5; \
          ls /usr/lib/aarch64-linux-gnu/perl 2>/dev/null'
  ```
- Add a per-distro perl-removal step in each install path **only** after
  KasmVNC's `vncserver` wrapper is confirmed unused. The current
  KasmVNC package on Debian-family declares `perl` as a hard `Depends:`,
  so naive `apt-get remove perl` will pull KasmVNC out too. Two
  workable approaches:
  1. **Force-remove** with `dpkg --remove --force-depends perl perl-base
     perl-modules-* libperl5.*` after KasmVNC install. Image becomes
     non-installable for new perl-needing packages but boots fine.
     Captures ~70 MiB savings.
  2. **Filed upstream**: open a KasmVNC issue to demote `perl` from
     `Depends:` to `Recommends:` (the wrapper is one of several entry
     points; the binary itself doesn't need perl at runtime). Tracked
     out-of-band; this is the clean fix.
- For Alpine, perl ships separately and KasmVNC there doesn't depend
  on it — drop is a clean `apk del perl`. Save ~25 MiB.
- For Fedora/RHEL family, KasmVNC RPM declares perl-interpreter
  `Requires:`. Same two-option fork as Ubuntu.

**Verification:** boot each distro, confirm KasmVNC :6901 still
reachable, no perl in `ps -e`, no perl in `/usr/bin /usr/lib/`.

**Caveats:**
- `kasmvncpasswd` is a C binary — survives perl removal.
- The KasmVNC server itself (`/usr/bin/Xvnc`) is C — survives.
- Standalone `vncserver -kill :1` / `-list` operations stop working
  if perl is removed and the wrapper is shipped. Kasm orchestrator
  doesn't use these — it stops containers, not vnc displays. If an
  image author needs the standalone CLI, document `INCLUDE_PERL=1`
  build arg as the escape hatch.

**Estimated savings:**
- Ubuntu/Debian: ~70 MiB (perl + perl-modules-* + libperl)
- Alpine: ~25 MiB
- Fedora/RHEL: ~50 MiB (perl-interpreter + minimal perl libs)

## Done-when

- `git grep vnc_startup\\|kasm_startup\\|CONTAINER_INIT` returns zero
  hits across the repo.
- `kasm-entrypoint` is ≤10 lines or removed entirely (depending on
  6.4 choice).
- All 7 dockerfiles still build cleanly under both
  `INCLUDE_SQUID=1` (default) and `INCLUDE_SQUID=0` — the squid
  build-arg landed end-of-Phase-5.
- All 9 distros (8 build-able + parrotos7 once mirror recovers)
  boot with `container-init` as PID 1 — *no env var needed*.
- Boot trace + cgmem on noble + bookworm not worse than the n=5
  baselines in `design/{ubuntu-noble,debian-bookworm}-before-after.md`
  (TTFL ≤50 ms, cgmem ≤240 MiB at steady_state_t+20s).
- Sysbox (`install_systemd.sh`) path boots, container-init runs as
  child of real systemd, KasmVNC reachable, `KASM_OS_USER=alice`
  takes effect.
- Perl runtime removed from each distro's image (or escape hatch
  `INCLUDE_PERL=1` documented). `which perl` returns nothing in the
  default build. KasmVNC :6901 + audio + upload still functional.
- Image-size delta documented per distro (expected ~25–70 MiB
  reduction depending on family).

## Ground rules (carried over from Phase 5)

- All Go code stays in `src/common/container-init/`.
- No KasmVNC source changes.
- `runs/all-distros.sh` (Phase 5) is the regression harness — re-run
  it as the last thing before declaring Phase 6 done. Adjust the
  median script's `-e CONTAINER_INIT=*` setting (the `bash` arm of
  the dual-path probe should be deleted; container-init is the only
  path now).
- Don't reintroduce the bash chain even temporarily. If a regression
  surfaces under container-init that the bash chain hid, the bug is
  in container-init or its unit set — fix it there, not by
  re-enabling bash.

## Watchlist (carried from Phase 5)

These shipped fixes need to be remembered when reading old code /
docs that may still reference the broken behaviour:

1. **`audio-in.socket` ListenStream is :4904** (was :4901 — collided
   with the `kasm_audio_out-linux` WebSocket relay). Don't switch it
   back.
2. **Audio + VNC username defaults to `${KASM_OS_USER}`** (was
   literal `kasm_user`). Browser HTTP basic auth + VNC `.kasmpasswd`
   record both use the OS user. Default is `kasm-user` (hyphen),
   *not* `kasm_user` (underscore). Documentation referencing the old
   underscore name needs updating.
3. **`kasm-os-user-rename` uses `chown -h`** for the symlink sweep
   (cursor files are symlinks; plain chown follows them, leaving the
   link itself at the old uid).
4. **`audio-out.service` requires `kasm-setup.service`** explicitly
   — without it, audio-out tries to priv-drop to a not-yet-existent
   user when `KASM_OS_USER` differs from default.
5. **container-init's expander supports nested `${X:-${Y}}`** —
   landed for the audio token. New unit defaults can rely on this.
6. **`ARG BASE_IMAGE` is hoisted to the top of every dockerfile** —
   podman/Buildah parses inter-stage ARGs as belonging to the
   previous stage, breaking `FROM $BASE_IMAGE`. Don't move it back
   inside the build stage.
7. **`INCLUDE_SQUID=1` default; `=0` skips the install entirely** —
   saves ~110 MiB. The squid block in each dockerfile is gated by a
   single `RUN if [ "$INCLUDE_SQUID" = "1" ]; then ...`. Don't
   reintroduce unconditional COPYs of squid resources.

## Out of scope (don't do these in Phase 6)

- Redesigning the unit set. Phase 4.6's directive set is frozen
  through Phase 6. New directives are a Phase 7+ conversation.
- Replacing socket activation with eager start (or vice versa).
- Touching `kasm_audio_out-linux` / `kasm_audio_input_server` /
  helper-binary internals — Phase 6 is *only* about the bash-chain
  retirement and the sysbox unit fix.
- Anything in the "Out of scope" list of `design/work_sequence.md`
  (Go rewrites of PyInstaller helpers, KasmVNC perl `vncserver`
  rewrite, profile_size_check refactor, audio-off-ffmpeg migration,
  DLP fail-secure redesign, OpenTelemetry).

## What I expect at hand-off

A single comment with:
- Confirmation that `git grep` shows zero hits for `vnc_startup`,
  `kasm_startup`, `CONTAINER_INIT`.
- Re-run of `runs/all-distros.sh` (with median script's bash arm
  removed) showing TTFL + cgmem ≤ Phase 5 baselines.
- Verification that the sysbox path still boots with container-init
  + `KASM_OS_USER=alice`.
- Confirmation that `INCLUDE_SQUID=0` still produces a buildable,
  bootable image after Phase 6 deletions.
- Diff stat of files removed (vnc_startup.sh + kasm_startup.sh +
  whatever else is dead with them).

## First action

Read `design/work_sequence.md` Phase 6 section verbatim, then
`src/common/scripts/kasm-entrypoint` and
`src/ubuntu/install/sysbox/install_systemd.sh`. Confirm `git status`
is clean (or branch the Phase 5 working tree first). Start at 6.1
(delete vnc_startup.sh) — fastest to flush out implicit dependencies
the rest of the matrix will surface.
