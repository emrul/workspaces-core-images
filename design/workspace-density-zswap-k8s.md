# Compressed-memory density on k8s — CIVO experiment plan

Audience: whoever runs this experiment and reviewers of the result. **Living
document** — keep the Status table and Results section current; numbers beat
adjectives. Companion to `design/workspace-density-zswap.md` (the `.140`
dockerised results); this one ports that method to the CIVO k3s cluster and
adds an in-session Chrome workload.

> TL;DR — Measure how many concurrent tracelabs sessions a `g4m.kube.medium`
> node holds with zswap + kubelet NodeSwap enabled, vs the RAM-only baseline,
> using idle XFCE and Chrome-loaded sessions as the workload. The parent doc
> got 2–3× on Chrome under tight caps on a Docker host; the open question is
> how much of that survives on managed k3s with cgroup-v2 swap accounting.
> **zswap alone changes nothing here** — it needs a swap device, kubelet
> NodeSwap, and per-pod memory limits first (§3). This doc is the plan to
> stand those up safely, measure, and tear down before the customer returns.

---

## 0. Status

| Item | State | Updated |
|---|---|---|
| Node feasibility probed | ✅ (§2) | 2026-08-06 |
| Plan reviewed | ☐ | |
| Baseline (RAM-only) measured | ☐ | |
| Swap + zswap DaemonSet built | ☐ | |
| kubelet NodeSwap enabled + verified | ☐ | |
| Workspace memory requests/limits set | ☐ | |
| zswap density measured (idle) | ☐ | |
| zswap density measured (Chrome) | ☐ | |
| Torn down, nodes clean | ☐ **hard gate before customer returns** | |

**Deadline:** customer resumes use of this environment ~2026-08-13. All node
mutations reverted and verified clean before then (§8).

### Decision log

| Date | Decision | Why |
|---|---|---|
| 2026-08-06 | zswap, not zram | Parent doc §"Why zswap": graceful degradation, preserves page-cache (the nix file-sharing win), per-cgroup accounting. Unchanged here. |
| 2026-08-06 | Apply via privileged DaemonSet, not one-off node edits | CIVO reprovisions nodes from an image on scale/recycle; a DaemonSet re-applies on every node join. One-off `ssh`+edit does not survive. |
| 2026-08-06 | Experiment on this cluster, then revert | Customer environment; not a permanent posture decision. If it pays off, productionising it is a separate piece of work (§9). |

---

## 1. Objective & hypothesis

**Objective.** Quantify sessions-per-node and sessions-per-100 GB for the
`tracelabs-osint:nix` workspace on `g4m.kube.medium` nodes, RAM-only vs
zswap-backed, at several per-pod memory caps, for two workloads (idle desktop;
Chrome with N tabs).

**Hypothesis.** The session working set is dominated by **anon** (per-session
private pages) that the nix file-page sharing can't touch. zswap compresses
cold anon, so a memory-capped session that would OOM/evict on RAM alone stays
usable by spilling cold anon into a compressed pool. Expected: meaningful
density gain at caps below the natural working set, tapering as the cap
approaches it. Chrome amplifies the effect (large, partly-cold heaps).

**Success criteria.** A defensible sessions/100 GB number for each
(workload × cap × zswap on/off) cell, each with its own per-cgroup pressure
(PSI) so "density" is always qualified by "still usable". A gain that only
shows up as raw packing but tanks PSI is not a gain.

---

## 2. Environment (probed 2026-08-06)

Cluster `kasm-tracelabs`, pool `edffd1f3` = 3× `g4m.kube.medium`.

| Property | Value | Implication |
|---|---|---|
| Node | 4 vCPU / 32 GB, Alpine v3.22, kernel **6.12.85-0-lts** | Modern zswap (per-cgroup `memory.zswap.current`) |
| Allocatable RAM | ~27–28 GB (`kube-reserved=3745Mi`, `system-reserved=200Mi`) | The denominator for "sessions/node" |
| cgroup | **v2** (`cgroup.controllers` present) | Pod swap gated by `memory.swap.max`; kubelet sets it 0 without NodeSwap |
| zswap | `CONFIG_ZSWAP=y`, **`enabled=N`**, compressor `lzo`, zpool `zsmalloc` | Runtime-togglable via sysfs; want `zstd` (verify crypto zstd present) |
| **Swap** | **none** (`SwapTotal` 0, `/proc/swaps` empty) | Must create a swap file first — zswap is inert without it |
| kubelet (k3s v1.36) | `/etc/rancher/k3s/config.yaml` `kubelet-arg:`; **no** `fail-swap-on=false`, **no** `feature-gates=NodeSwap`, **no** `memorySwap` | Default "swap off for pods"; must reconfigure + restart k3s-agent |
| Session pods today | `requests: cpu=2`, **no memory request/limit** | Nothing reclaims to zswap; also unbounded — one heavy session can starve a node |
| max-pods | 110 | Not the binding limit at these densities |

**The precondition chain (all four, in order):** swap file → zswap on →
kubelet NodeSwap → per-pod memory limits. Skip any one and the gain is zero.
This is the single most important framing in the doc.

---

## 3. Setup

### 3.1 Node mutation — privileged DaemonSet `zswap-enabler`

One DaemonSet (namespace `kube-system`, tolerates all taints, nodeSelector on
the session pool) whose container runs an **idempotent** setup script then
`sleep infinity` (so it stays as the applied-state marker and re-runs on new
nodes at join). All writes are to the host via `hostPath: /` + `privileged`.

Per node, idempotently:

1. **Swap file.** If `/proc/swaps` has no entry: `fallocate -l 16G
   /host/var/lib/kasm-swap/swapfile` (or `dd` if the fs rejects fallocate),
   `chmod 600`, `mkswap`, `swapon`. Size rationale: ~half of the 32 GB node,
   headroom for a ~2× compressed pool without starving page cache. Record
   actual.
2. **zswap.** `echo zstd > /sys/module/zswap/parameters/compressor` (fall back
   to `lzo` if zstd rejected), `echo 20 > .../max_pool_percent`, `echo 1 >
   .../enabled`. Verify `enabled=Y`.
3. **Marker + logging.** Write what it did to stdout so `kubectl logs` is the
   audit trail; label the node `kasm.com/zswap=on` on success.

Reversibility: delete the DaemonSet, then a **teardown** DaemonSet (or a manual
pass) `swapoff` + `rm` the file + `echo 0 > .../enabled`. See §8.

### 3.2 kubelet NodeSwap

`memory.swap.max=0` on pod cgroups is the real gate (cgroup v2). Needs, per
node in `/etc/rancher/k3s/config.yaml` `kubelet-arg`:

- `fail-swap-on=false`
- `feature-gates=NodeSwap=true` (beta/GA on 1.36 — confirm the gate name/state
  for this exact build before assuming)
- `memory-swap=swapBehavior=LimitedSwap` (via kubelet config; LimitedSwap
  grants Burstable pods swap ∝ memory request)

then **restart k3s-agent** (`rc-service k3s-agent restart` on Alpine/openrc).

⚠️ **Blast radius:** restarting k3s-agent bounces that node's pods. Do it one
node at a time, draining session pods first. On a managed cluster this edit
does **not** survive node recycle — the DaemonSet approach can template the
config write + a guarded restart, but a kubelet restart loop inside a DaemonSet
is genuinely risky; for a time-boxed experiment, doing §3.2 **manually per
node** (3 nodes) is safer than automating it. Decide and log which.

Verify NodeSwap live: a Burstable test pod with a memory request should show
`memory.swap.max` > 0 in its cgroup (not 0). That check gates the whole
experiment — if swap.max stays 0, nothing downstream measures anything.

### 3.3 Workload — the KasmWorkspace CR

Sessions need memory **request < limit** (Burstable) for LimitedSwap to grant
swap. Test matrix caps (limit), request pinned at ~60% of limit:

| cap (limit) | request | intent |
|---|---|---|
| 4Gi | 2.5Gi | generous / near natural working set |
| 3Gi | 1.8Gi | moderate squeeze |
| 2Gi | 1.2Gi | aggressive — where zswap should earn its keep |
| 1.5Gi | 1Gi | stress / find the usability cliff |

Set via `spec.resources.{requests,limits}` on the workspace (the operator
passes these straight through — confirmed in `deployment.py`).

---

## 4. Workloads

Two, run at each cap, zswap off then on:

- **W1 — idle desktop.** Launch tracelabs, let XFCE settle (the §prior
  black-screen fix means ~3 s to steady state), no apps. Establishes the floor
  working set and the nix file-page sharing baseline.
- **W2 — Chrome loaded.** In-session, open Chrome (chromium from the tracelabs
  bundle) with a fixed tab set — **8 distinct-site tabs**, mirroring
  `chrome-at-scale.md` scenario 2, so results compare to the `.140` numbers.
  Let it settle 60 s, then measure. This is where anon dominates and
  compression should show.

Drive N identical sessions per node up to the point the node fills or PSI
spikes. Because we're the only tenant until ~08-13, run each cell on its own
node in the 3-node pool for isolation, or serialise — log which.

---

## 5. Measurement

Per-cgroup, cgroup v2, same as parent doc but the pod cgroup lives under the
kubelet hierarchy. For a session pod, find its cgroup on the node:

```
# on the node (via the probe/enabler pod's host mount)
find /sys/fs/cgroup/kubepods.slice -name 'memory.current' | grep <pod-uid>
```

Collect per session:

- **Real RAM** — `memory.current` (the compressed pool is charged here, so this
  is true RAM under the cap).
- **Compressed pool** — `memory.zswap.current`.
- **Swapped** — `memory.swap.current` (RAM-resident-compressed + disk-written).
- **Compression ratio** — global `stored_pages*4096 / pool_total_size` from
  `/sys/kernel/debug/zswap/*`, cross-checked per-cgroup via
  `swap.current / zswap.current`.
- **Usability** — the session's OWN `memory.pressure` full avg10. Node-wide PSI
  (`/proc/pressure/memory`) stays ~0 while the node has spare RAM; the
  per-cgroup pressure is the real signal.
- **Node headroom** — `MemAvailable`, `/proc/swaps` Used, node PSI.

Derived: **sessions/node** (fill until cgPSI full10 > a threshold — propose 5%
sustained as the "still usable" line, tune on W1) and **sessions/100 GB** =
sessions/node × 100 / (allocatable GB).

A small collector script (`runs/chrome-density/zswap-probe-k8s.sh`, to write)
should snapshot all of the above across every session cgroup on a node into one
JSONL line per sample, like the `.140` probe.

---

## 6. Results (fill in)

### 6.1 W1 idle — cap sweep

| cap | zswap | real RAM/sess | resident anon | zswap pool | swap used | ratio | cgPSI full10 | sess/node | → sess/100 GB |
|----:|:-----:|--------------:|--------------:|-----------:|----------:|------:|-------------:|----------:|--------------:|
| 4Gi | off | | | — | — | — | | | |
| 4Gi | on | | | | | | | | |
| 2Gi | off | | | — | — | — | | | |
| 2Gi | on | | | | | | | | |

### 6.2 W2 Chrome (8 tabs) — cap sweep

| cap | zswap | real RAM/sess | resident anon | zswap pool | swap used | ratio | cgPSI full10 | sess/node | → sess/100 GB |
|----:|:-----:|--------------:|--------------:|-----------:|----------:|------:|-------------:|----------:|--------------:|
| … | | | | | | | | | |

### 6.3 Narrative
_(compression ratio achieved, where the usability cliff sits, how it compares
to `.140`'s 2–3× at 400–600m, and whether cgroup-v2 LimitedSwap changed the
shape.)_

---

## 7. Confounders to control

- **Interactivity ≠ throughput.** These nodes are in **phx1**; measuring "feel"
  over a high-RTT link conflates zswap latency with network latency. Measure
  density from cgroup stats, not from the browser feel; note RTT separately.
- **Software render.** Sessions run llvmpipe (`LIBGL_ALWAYS_SOFTWARE=1`, no
  GPU) — Chrome CPU is higher than on `.140`'s GPU host, so CPU may bind before
  memory at high density. Watch `cpu.pressure` too; report whichever binds.
- **nix file-page sharing** only helps when sessions are **co-located** on one
  node (shared page cache). Keep a cell to one node so the sharing win is in
  the baseline, not accidentally spread across three.
- **zstd availability.** If the kernel's crypto zstd isn't present, we fall
  back to lzo — worse ratio; record which compressor actually loaded.
- **Eviction race.** `eviction-hard=memory.available<100Mi` is tight; under
  heavy swap the node could evict before zswap tiers to disk. Watch for
  kubelet evictions in events and treat any as a failed (not a data) point.

---

## 8. Teardown (hard gate — before ~08-13)

1. Delete `zswap-enabler` DaemonSet.
2. Teardown pass (DaemonSet or manual): `swapoff -a`, `rm
   /var/lib/kasm-swap/swapfile`, `echo 0 > /sys/module/zswap/parameters/enabled`,
   remove the `kasm.com/zswap` node label.
3. Revert `/etc/rancher/k3s/config.yaml` kubelet-arg changes on each node,
   restart k3s-agent, confirm a test pod's `memory.swap.max` is back to 0.
4. Remove memory requests/limits from the workspace CR if they were only for
   the experiment (or keep — see §9).
5. Verify: `/proc/swaps` empty on all nodes, all Kasm pods Running, a fresh
   session launches clean.

Log completion in §0.

---

## 9. If it pays off (out of scope now, capture the thought)

- Node mutation on managed CIVO won't survive recycle; productionising means
  either a bootstrap DaemonSet that's part of the platform install, or moving
  session nodes to a self-managed pool where kernel cmdline / kubelet config is
  ours. Note the §"deployment shapes" discussion in
  `design/tetragon-session-monitoring.md` — same managed-cluster constraint.
- **Keeping memory requests/limits on sessions is worth doing regardless of
  zswap** — it's the honest-scheduling fix and the prerequisite that makes any
  density work meaningful. Consider landing that independently.
- Tetragon (if the observability spike lands) gives per-session syscall/PSI
  visibility that would make a standing density dashboard cheap.

## 10. Open questions

1. Exact NodeSwap gate state on this k3s v1.36 build — GA (no gate needed) or
   still `feature-gates=NodeSwap=true`? Confirm before §3.2.
2. Does the node's crypto stack have zstd, or do we fall back to lzo?
3. Is fallocate honoured on the node root fs, or do we need `dd`?
4. One-node-per-cell (clean isolation, 3 cells at a time) vs serialise on one
   node (more cells, slower) — pick before starting.
5. Usability threshold: is cgPSI full10 = 5% the right "still usable" line, or
   calibrate against a hands-on session first?
