# Phase 2 spike result — GO

Decision date: 2026-05-03. The Phase 2 spike (`design/work_sequence.md`
§ Phase 2) executed end-to-end on Ubuntu Noble under podman 4.8.2 in
lima. All four probes pass, both static binaries cross-build for
linux/amd64 and linux/arm64, and the env-var expansion hook required
by the cross-cutting OS-user work (Phase 4.10) is in the parser with
unit-test coverage. **Recommendation: proceed with Phase 3 (Go rewrite
of `kasm_upload_server`) and Phase 4 (full container-init build).**

## What ran

Source tree: `src/common/container-init/` (this repo).

```
make -C src/common/container-init clean build helper
  → bin/container-init.linux-amd64   2.79 MiB  static, stripped
  → bin/container-init.linux-arm64   2.75 MiB  static, stripped
  → bin/spike-helper.linux-amd64     2.22 MiB  static, stripped
  → bin/spike-helper.linux-arm64     2.23 MiB  static, stripped
```

Probe image: `kasm-spike:latest`, layered on
`docker.io/kasmweb/core-ubuntu-noble:1.18.0-rolling-daily`. Entry
point overridden to `container-init --units /etc/container-init/units`.
Hand-written unit set under `design/spike/units/` exercises every
spike directive at least once: `Description`, `After`, `Requires`,
`OnFailure`, `ConditionEnvironment`, `Type=simple|oneshot`,
`ExecStart`, `Restart=on-failure`, `RestartSec`, `User=` (parser
hook only), `ExitContainerOnFailure`, `[Socket] ListenStream`,
`Accept=no`, `Service=`, `ActivationMode=native|proxy`, `ProxyTarget=`,
`[Install] WantedBy`.

Probes (driver: `design/spike/scripts/probe.sh`):

| Probe | Outcome | Evidence |
|---|---|---|
| **D** — WM dies + recorder running → drain + container exit | PASS, container exit 0 | trace records `OnFailure: invoking recorder-drain.service` → `recorder-drain: drain complete (spike stub)` → `reverse_shutdown_done exit=0` (container exit code matches) |
| **E** — WM dies + recorder NOT running → `Restart=on-failure` restart | PASS, ≥2 `wm-stub: running indefinitely` lines, container still up | `recorder-drain.service` skipped via `ConditionEnvironment=KASM_SVC_RECORDER=1`, OnFailure becomes a no-op, `Restart=on-failure` fires after 200 ms (RestartSec) |
| **F-native** — `upload.{socket,service}` cold-starts on first connect; restarts on failure; `cond-skip.socket` stays unbound when its `ConditionEnvironment` is unmet | PASS, two distinct helper PIDs across reconnects, no listener on :4999 | `first_connect` event at +164 ms; `spawn upload.service`; helper exits via `SPIKE_HELPER_DIE_AFTER=1`; second `spawn` 200 ms later (RestartSec) under a fresh PID; `ss -tln` confirms :4902 + :8081 bound, :4999 absent |
| **F-proxy** — `audio-out-ws.{socket,service}` proxy-mode cold-start + restart | PASS, two distinct PIDs across reconnects | `first_connect` on `audio-out-ws.socket` → `spawn audio-out-ws.service -mode proxy -listen 127.0.0.1:14081`; helper dies; supervisor respawns the helper and the next public connection proxies cleanly to the new private endpoint |

Run logs and trace JSONL captured under `design/spike/runs/`.

The Phase 2.6 cross-cutting hook (env-var expansion on directive
values) is verified by `internal/unit/expand_test.go` (10 cases of
`${VAR}` and `${VAR:-default}` resolution including unset, empty,
embedded, and chained forms) and by `internal/unit/parse_test.go`
`TestExpansionFixture`, which loads a unit with
`User=${KASM_OS_USER:-kasm-user}` twice — once with the variable
unset (resolves to `kasm-user`) and once with it overridden to
`alice` — and asserts the typed `Unit.User` field matches.

## Design surprises and the resulting decisions

The implementation surfaced four design points worth noting before
Phase 4 work begins. Each is a real constraint we'll hit again, not
spike-only paper-cuts.

### 1. PID-1 reaper vs `os/exec.Wait` is mutually exclusive

A standalone `wait4(-1, …)` reaper goroutine racing `os/exec.Cmd.Wait`
silently steals child exit statuses, breaking the
`Restart=`/`OnFailure=` paths in the supervisor. The spike removes
the explicit reaper and relies on `os/exec`'s SIGCHLD-driven Wait for
every supervised child (zero double-forks in the spike unit set).

**Phase 4 implication.** Production units that double-fork
(`dbus-launch`, anything `Type=forking`) will leave orphans that
nobody reaps. The Phase 4 plan: a single SIGCHLD dispatch routine
that owns `wait4(-1, WNOHANG)` and routes results to per-unit
channels, replacing `cmd.Wait()` calls inside the supervisor. This
is a meaningful refactor — call it ~1.5 days, not the half-day the
original 3-week Phase 4 estimate implied. The existing 3-week
estimate has slack for it.

### 2. Pipe write-end retention by orphan grandchildren wedges `cmd.Wait()`

`cmd.Stdout = customWriter` causes `os/exec` to set up an internal
pipe and copy goroutine; `cmd.Wait()` blocks until the pipe EOFs;
the pipe doesn't EOF while any grandchild still holds the write fd.
Spike resolution: `cmd.Stdout = os.Stdout` directly (no pipe), so
`Wait` returns the moment the immediate child exits. We lose the
per-line `<unit-name>: ` prefix on raw stdio (still preserved in the
trace JSONL).

**Phase 4 implication.** The unified SIGCHLD dispatcher (item 1)
makes this obsolete — once we don't depend on `cmd.Wait` for
per-process exit events, the prefixing wrapper can return. Or we keep
the single combined stream and do prefixing at the journal/log-driver
side. Either way, no spike-imposed regression on the production
output format.

### 3. Linux PID + PGID reuse defeats delayed `kill -PGID`

The supervisor's first cut sent SIGTERM immediately and SIGKILL after
500 ms to the dead unit's process group, to clean up orphaned
grandchildren that ignored SIGTERM. PIDs and PGIDs are reused almost
immediately on Linux; the delayed SIGKILL landed on whatever the
kernel had since assigned to that slot — typically the restarted
instance of the same unit, but in one observed case kasmvnc.service
was killed by a 500 ms-delayed SIGKILL targeting the previous WM's
recycled PGID. Spike resolution: drop the delayed SIGKILL; immediate
SIGTERM races the kernel for orphan cleanup; if the orphan ignores
SIGTERM the spike accepts the leak.

**Phase 4 implication.** Replace per-unit kill-by-PID with cgroup-v2
`cgroup.kill` writes (one syscall, atomic, no reuse hazards).
Container-init can mkdir its own subdirectory under
`/sys/fs/cgroup/` per unit and write `1` to `cgroup.kill` to take
out everything, named or orphaned, in one atomic step. cgroup v2 is
available on every distro in the Phase 1 matrix (Linux ≥ 4.5; the
oldest base, Ubuntu Jammy 22.04, ships 5.15). Adds ~half a day to
Phase 4.

### 4. `syscall.Select` + Go runtime preemption needs an EINTR + return-count check

Go 1.14 introduced asynchronous goroutine preemption via SIGURG.
`syscall.Select` returns EINTR routinely under any goroutine load.
Linux leaves the FdSet unmodified on EINTR — Go's `syscall.FdSet` is
ours, the bit we set is still set, so a naïve "is the bit still on"
check after `Select` returns produces phantom readability events on
every busy goroutine. Symptom in spike: `upload.socket` fired
`first_connect` at +800 ms with zero external connections, simply
because container-init's other goroutines were preempting each other.
Fix: check `n > 0 && fdIsSet(...)`, treat EINTR as a clean retry. One
line of code; massive correctness impact.

**Phase 4 implication.** When we widen the spike's per-fd
`syscall.Select` to a real epoll loop (or use `golang.org/x/sys/unix`
ppoll), preserve the same return-count discipline. The bug is
identical in shape with poll/ppoll/epoll_wait if we ever check the
returned event mask before the return value.

## What the spike did not exercise

Out of scope by Phase 2 design — these are explicit Phase 4 tasks,
not spike gaps:

- `EnvironmentFile=` parsing (Phase 4.2). Parser stub absent; needs
  systemd-quoting fuzz tests against the systemd test corpus.
- `User=` / `Group=` / `WorkingDirectory=` privilege drop (Phase 4.3).
  Parser accepts the directives and runs ${VAR}/${VAR:-default}
  expansion through them (so the values land on `Unit.User` etc.),
  but the supervisor does not yet `setresuid`/`setresgid`.
- Direct `Xvnc` exec from `kasmvnc.service` (Phase 4.4). The spike
  uses a sleep stub; no KasmVNC argv assembly yet.
- Production trace JSONL with memory snapshots and the bash trace's
  exact phase names (Phase 4.5). The spike emits a smaller schema
  — `boot_start`, `units_loaded`, `bound`, `first_connect`,
  `spawn`, `exited`, `onfailure_invoke`, `onfailure_exited`,
  `signal_received`, `reverse_shutdown_done`, `boot_done` — useful
  for debugging the spike but narrower than the bash baseline.
- Full Kasm unit set (Phase 4.6). Spike units are sleep/echo stubs.
- Extension point at `/etc/container-init.d/` (Phase 4.7). Loader
  reads only `/etc/container-init/units/` in the spike.
- Distro-matrix CI (Phase 4.8). Spike runs on Ubuntu Noble only.
- OS-user rename/chown logic (Phase 4.10). Phase 2.6 hook is in
  place for the parser side; the rename step lands in
  `kasm-setup.service`'s ExecStart in Phase 4.

## Verdict

**GO.** The directive subset, both socket-activation modes, the
goroutine-per-service supervisor, OnFailure chains, and reverse
shutdown all behave as `design/vnc-startup-replacement.md` predicted.
Cross-platform build trivially produces single static binaries on
both target architectures. The four design surprises documented
above are tractable in Phase 4 — none of them argue for the
gdraheim + Nuitka fallback, which would lose socket activation
entirely and still saddle us with EnvironmentFile + privilege drop
work on top of someone else's interpreter.

Phase 3 (`kasm-upload-server` Go rewrite) and Phase 4 (production
`container-init`) can begin in parallel as
`design/work_sequence.md` describes.
