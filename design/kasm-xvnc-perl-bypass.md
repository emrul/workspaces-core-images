# kasm-xvnc: bypassing the perl `vncserver` wrapper

Status: shipped (all container-init images). Written 2026-07-22, prompted by
questions from the KasmVNC eng team about how we made session boot faster and
what configurability the bypass costs.

This doc consolidates what was previously scattered across
`design/cold-start-perf-and-memory.md` (the measurements),
`design/vnc-startup-replacement.md` (the container-init design), and the
header comment of `src/common/kasm-go/cmd/kasm-xvnc/main.go` (the scope-outs),
and adds the configurability-parity analysis that wasn't written down anywhere.

---

## TL;DR

We did **not** refactor or speed up the perl script. We stopped calling it at
boot. `kasmvnc.service` execs `kasm-xvnc`, a ~390-line Go launcher that emits
the same Xvnc argv the perl wrapper would have emitted for the out-of-the-box
config, and execs `/usr/bin/Xvnc` directly. Saving: **~250–300 ms** off a
~580 ms time-to-first-listen. No KasmVNC source changes; the perl wrapper
still ships in the image and still works when invoked manually.

The one real configurability loss: **`kasmvnc.yaml` is no longer read at
boot** (system- or user-level). Everything the Kasm platform itself configures
(env vars, `VNCOPTIONS`, DLP flags injected by the backend) is retained. See
"Configurability parity" below.

## What the perl wrapper cost

`/usr/bin/vncserver` from KasmVNC is a 3,119-line perl script. On the Kasm
boot path its synchronous flow is (`vncserver:2773-2793`):

```
ConstructXvncCmd -> CheckSslCertReadable -> CheckBrowserHostDefined ->
DeleteLogLeftFromPreviousXvncRun -> StartXvncAndRecordPID -> WaitForXvncToRespond
```

Measured at 573 ms median (`kasmvnc_invoke` phase, 5 runs, ubuntu-noble
1.18.0-rolling-daily — full methodology in
`design/cold-start-perf-and-memory.md`):

| Cost | Where it goes |
|---|---|
| ~50–80 ms | perl interpreter cold start + parsing 3,119 lines |
| ~80–150 ms | option parsing; dependency probes (`uname`, `xauth`, `hostname`, `whoami`, each fork+exec'd via `system()` at vncserver:482); font-path detection; xauth setup |
| ~250–400 ms | `WaitForXvncToRespond` (vncserver:1131-1145): a 100 ms-resolution sleep loop that fork+execs `xdpyinfo -display :1` per iteration until X responds |

The damning detail: Xvnc's TCP listen socket binds at ~470 ms, but the
wrapper doesn't return until 573 ms. `xdpyinfo` requires the X server *fully*
initialized (not just listening), and the 100 ms poll granularity adds slop
on top — so ~100 ms+ is burned after the server is already usable.

## What we did instead

The insight that made this tractable: **on the boot path, the wrapper's only
real job is constructing an argv and forking Xvnc.** Everything else is
either not needed under a supervisor or not on the boot path at all.

1. **Captured the argv, didn't port the logic.** We ran the stock
   `kasmweb/core-ubuntu-noble:1.18.0-rolling-daily` image, captured the exact
   Xvnc argv the perl wrapper emits for the OOTB `kasmvnc.yaml`, and
   hard-coded that ~70-flag argv verbatim in
   `src/common/kasm-go/cmd/kasm-xvnc/main.go` (`buildXvncArgs`). Only
   genuinely dynamic values are substituted from env: `DISPLAY`,
   `KASM_OS_USER`/`KASM_OS_HOME` (via the root-owned identity snapshot at
   `/run/kasm/os-user.env`), `VNC_RESOLUTION`, `VNC_COL_DEPTH`,
   `MAX_FRAME_RATE`, `NO_VNC_PORT`, `DRINODE`, `KASM_VNC_PATH`, hostname.
   We deliberately did **not** re-implement kasmvnc.yaml parsing — that is
   the 3,000-line scope the port avoided.
2. **Deleted the readiness poll instead of speeding it up.** The perl waits
   for X because it is a fire-and-forget launcher that must confirm success
   before exiting. Under container-init, `kasmvnc.service` is `Type=simple`
   with `Restart=on-failure` — the supervisor owns liveness, so there is no
   synchronous readiness wait at all. The ~250–400 ms poll cost doesn't
   exist anymore.
3. **No KasmVNC source changes.** The perl wrapper still ships; we just
   don't call it at boot.

### Gotchas encoded in kasm-xvnc (read these before touching the argv)

- **Argv order matters.** The perl emits yaml-derived args first, then
  defaults, then operator overrides, relying on Xvnc's last-wins parsing
  (e.g. `-FrameRate=24` early, `-FrameRate 60` later). Order is preserved
  verbatim; don't "clean it up".
- **Conditional flags:** `-UnixRelay printer:/tmp/printer` and
  `-UnixRelay smartcard:/tmp/smartcard` are appended only when
  `KASM_SVC_PRINTER` / `KASM_SVC_SMARTCARD` are enabled (unset/empty = on,
  matching the bash `${VAR:-1}` idiom).
- **`VNCOPTIONS` (plus `KASM_SVC_SEND_CUT_TEXT` / `KASM_SVC_ACCEPT_CUT_TEXT`)
  are word-split and appended last** — matching the old bash chain, and the
  key to the configurability story below.
- **aarch64 needs `LD_PRELOAD=libgcc_s.so.1`** — Xvnc unwind-table
  resolution bug under multi-threaded fork when libgcc isn't already in the
  link map.
- **We can't pure-`exec(3)`.** Xvnc has a compiled-in
  `printf("TOTAL FRAME TOOK: ...")` per frame that bypasses `-Log` and
  floods stdout, so kasm-xvnc forks with a piped stdout and filters those
  lines. Tracked as `TODO(KASMVNC-UPSTREAM)` in main.go; revert to
  `syscall.Exec` when Xvnc drops the printf.

## Configurability parity

Who reads what (verified against KasmVNC source, `unix/vncserver`):
`kasmvnc.yaml` — both `/etc/kasmvnc/kasmvnc.yaml` and `~/.vnc/kasmvnc.yaml`
(`vncserver:1200-1208`) — is read **only by the perl wrapper**, which
converts keys to Xvnc CLI args. The `Xvnc` binary itself never parses yaml.
Bypassing the wrapper therefore has exactly these consequences:

### Lost

| Surface | Detail |
|---|---|
| System `kasmvnc.yaml` edits | A downstream image that `COPY`s a modified `/etc/kasmvnc/kasmvnc.yaml` gets no effect. The OOTB yaml's *effective values* are baked into kasm-xvnc's argv; the file is dead config on container-init images. |
| User `~/.vnc/kasmvnc.yaml` | Ignored — including one arriving via profile sync. |
| Env→yaml overrides | `allow_environment_variables_to_override_config_settings: true` was a wrapper feature; gone with it. |
| Automatic upstream defaults | If a future KasmVNC release changes a yaml default, the perl path would pick it up; our baked argv won't. See "KasmVNC version bumps" below. |

### Retained

| Surface | Detail |
|---|---|
| All documented Kasm env vars | `VNC_RESOLUTION`, `VNC_COL_DEPTH`, `MAX_FRAME_RATE`, `NO_VNC_PORT`, `DRINODE`, `VNC_PW` (via kasm-setup's `kasmvncpasswd`), `KASM_SVC_*` gates — substituted the same way `vnc_startup.sh` did. |
| **`VNCOPTIONS`** | Appended *last*; Xvnc parsing is last-wins, so **any** Xvnc parameter — a superset of what yaml can express — is overridable at runtime with no rebuild. This is also how the Kasm backend injects per-workspace settings (DLP flags etc.), so real deployments keep full configurability. |
| perl wrapper itself | Still in the image. `-kill` / `-list` / `-clean` and standalone `vncserver` runs work as before. |
| Unit-level escape hatch | A downstream image can drop an override `kasmvnc.service` in `/etc/container-init.d/` pointing `ExecStart` back at the perl wrapper (or its own launcher) if it genuinely needs yaml semantics — paying the ~300 ms back. |

### Sounds lost but wasn't

- The wrapper's `xstartup` / DE-selection machinery was never on the Kasm
  boot path (`vnc_startup.sh` launched the WM itself; now
  `window-manager.service` does).
- The yaml's `-UnixRelay` printer/smartcard entries are reproduced
  conditionally on the `KASM_SVC_*` gates.
- `runtime_configuration.allow_override_list` (`pointer.enabled`) is baked
  as `-AllowOverride AcceptPointerEvents`.

**Bottom line:** the only regression is "edit kasmvnc.yaml, restart, see the
change". Anyone doing that must switch to `VNCOPTIONS` (runtime) or a
container-init drop-in (image build). For the Kasm platform's own
configuration paths there is no functional loss.

## Maintenance: KasmVNC version bumps

The cost we accepted instead of yaml parsing is **argv re-capture on KasmVNC
upgrades**:

1. Run the stock (non-container-init) image for the new KasmVNC version.
2. Capture the running Xvnc's argv: `tr '\0' '\n' < /proc/$(pgrep -x Xvnc)/cmdline`.
3. Diff against `buildXvncArgs` in `src/common/kasm-go/cmd/kasm-xvnc/main.go`;
   fold in additions/changes, preserving order.
4. `make -C src/common/kasm-go test` — `main_test.go` pins every conditional
   flag and the env-substitution behaviour.

## Advice for anyone attempting the same upstream

If the goal is making `vncserver` startup faster, the leverage is not perl
optimization — it's recognizing that on a supervised boot path the wrapper is
an **argv generator you can snapshot**. Capture its output once per config
surface, mirror it in a launcher the supervisor owns, and delete the
readiness poll by letting the supervisor own liveness. The remaining ~250 ms
to first-listen is inside Xvnc itself (extension loading, framebuffer alloc);
sub-100 ms is unrealistic without modifying Xvnc.

## Pointers

- `src/common/kasm-go/cmd/kasm-xvnc/main.go` — the launcher (header comment
  lists the scope-outs), `main_test.go` — pinned argv behaviour
- `src/common/kasm-go/units/kasmvnc.service` — the unit that execs it
- `design/cold-start-perf-and-memory.md` — measurement methodology, full
  phase table, memory findings
- `design/vnc-startup-replacement.md` — the container-init design this was
  part of (§ "Mapping vnc_startup.sh to units")
