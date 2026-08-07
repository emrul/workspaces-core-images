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
| Disk footprint measured (gate for swap size, §3.0a) | ✅ 10 GB safe, big margin (§3.0a) | 2026-08-06 |
| Baseline (RAM-only) measured | ✅ idle ~341 MiB marginal; **CPU-request-bound, not memory** (§6.0) | 2026-08-06 |
| Swap + zswap DaemonSet built | ✅ applied — 10 GB swap + zswap zstd (pool 20%) on all 3 nodes | 2026-08-06 |
| kubelet NodeSwap enabled + verified | ✅ all 3 nodes; Burstable pod gets proportional swap.max (§3.2a) | 2026-08-06 |
| Workspace memory requests/limits set | ⚠️ **agent doesn't map memory_bytes** — use direct CR (`runs/chrome-density/zswap-test-session.yaml`); Kasm-launched sessions get no mem req → zero swap (§3.3a) | 2026-08-06 |
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
| 2026-08-06 | Proportional LimitedSwap, NOT fixed 4 GB/pod | k8s has no fixed per-pod swap knob; fixed 4 GB would need ~51 GB swap → breaks the nodefs eviction floor on the 80 GB disk (§3.0). |
| 2026-08-06 | **Start host swap at 10 GB/node**, grow only if measured disk headroom allows (ceiling ~24 GB) | Disk (shared with multi-GB workspace images + ephemeral, under the 20% nodefs eviction floor) is the binding constraint, not swap sizing. 10 GB is the safe floor; per-pod grant is small (~0.8 GB at 2.5 Gi req) so this pass measures *whether/ratio*, not max gain. SWAP_GB is a DaemonSet env var for a second sweep. |
| 2026-08-06 | Baseline shows density is **CPU-request-bound**, not memory-bound (§6.0) | Idle marginal RAM ~341 MiB (nix file sharing); nodes 94–98% CPU-requested at 2 CPU/session default. zswap can't raise density until session CPU requests drop. Reprioritise: pursue the CPU-request lever first; zswap value now hinges on W2 (Chrome anon growth). |
| 2026-08-06 | Session CPU set to **1 core**; **use Shares (request-only), not Quotas** | Measured (§6.2a): Quotas hard-cap is 7× slower on a multi-thread burst, and 5× slower than 2 contended Shares sessions. Shares degrades gracefully under co-location; Quotas clamps every render spike. CPU allocation method dominates perception over density. |
| 2026-08-06 | **PSI unavailable on CIVO k3s** → drop PSI-based usability metric | `/proc/pressure/*` absent (no `psi=1`, unsettable on managed nodes). Whole doc's PSI plan void. Substitute wall-clock timing + memory.stat refault/pswpin + cpu.stat throttled_usec (§5). Affects every remaining measurement in §6. |
| 2026-08-06 | **Plumbing switched ON** — swap+zswap+NodeSwap live on all 3 nodes | §3.2a. swapBehavior=LimitedSwap needs a config-dir drop-in (flags alone default NoSwap). Verified swap grants match the formula. Ready for manual testing; metrics captured next week. |
| 2026-08-06 | Test via **direct CR**, not Kasm-launched sessions | Agent doesn't map memory_bytes → Kasm sessions get no mem req → zero swap (§3.3a). `runs/chrome-density/zswap-test-session.yaml` is the harness. |

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

### 3.0 How much swap each pod actually gets — the LimitedSwap math

**k8s has no fixed per-pod swap knob.** `UnlimitedSwap` was removed; only
`NoSwap` and `LimitedSwap` are valid. Under `LimitedSwap` on cgroup v2 the
kubelet *derives* each **Burstable** pod's swap (Guaranteed and BestEffort get
**zero**):

```
pod_swap_max = (container_memory_request / node_total_memory) × total_node_swap
```

Consequence for the original "~4 GB swap/pod, 10 GB host swap" idea — it can't
hold both ways on a 32 GB / 80 GB-disk `g4m.kube.medium`:

- 10 GB host swap + 2.5 Gi request → `2.5/32 × 10 ≈ 0.8 GB`/pod. Far below 4 GB.
- Forcing 4 GB/pod at 2.5 Gi request → `4 × 32 / 2.5 ≈ 51 GB` host swap, which
  **breaks the `nodefs.available<20%` eviction floor** (must keep ~16 GB free
  on the 80 GB disk; 51 GB swap + the multi-GB nix image crosses it → disk-
  pressure evictions mid-experiment).

**Disk is the binding constraint, not swap sizing.** The 80 GB node disk is
shared by: the containerd image store (the tracelabs nix image is multi-GB;
a nix fat-store image is much larger; more enabled images stack), pod ephemeral
storage + `/dev/shm`, OS/logs, AND the swapfile — all under the
`nodefs.available<20%` (~16 GB must stay free) eviction floor. Note the image
is stored **once per node** (co-located sessions share it), so it's a per-node
fixed cost, not per-session.

**Chosen design: start host swap at 10 GB/node — deliberately conservative —
then grow only if measured free disk allows (§3.0a).** Let the proportion set
per-pod swap; lean on zswap compression. Expected per-pod grants at 10 GB
(verify live against `container_swap_limit_bytes`; formula uses node *total*
physical mem ≈ 32 GB, not allocatable):

| request | host swap 10 GB → pod_swap | (if grown) 16 GB | (ceiling) 24 GB |
|---|---|---|---|
| 2.5 Gi | ~0.8 GB | ~1.25 GB | ~1.9 GB |
| 1.8 Gi | ~0.55 GB | ~0.9 GB | ~1.35 GB |
| 1.2 Gi | ~0.4 GB | ~0.6 GB | ~0.9 GB |

At 10 GB the per-pod grant is small (~0.4–0.8 GB), so the compressed-density
effect is correspondingly bounded — this first pass measures *whether* it helps
and what the compression ratio is, not the maximum gain. If §3.0a shows disk
headroom, a second sweep at 16 GB (never above the ~24 GB disk-safe ceiling)
widens the grant. A literal fixed 4 GB/pod is a bigger-disk / self-managed-node
decision (§9), out of scope pre-customer.

### 3.0a Measure disk footprint before sizing swap

Before creating the swapfile, on one node (via the probe pod's host mount)
record: total/free disk on the fs backing containerd (`df -h /host/var/lib`),
the image-store size (`du -sh /host/var/lib/rancher/k3s/agent/containerd` or the
node's snapshotter dir), and headroom vs the ~16 GB eviction floor. 10 GB swap
is safe if free disk after swapfile stays comfortably above 16 GB with the
image(s) present. Re-check after loading N sessions (ephemeral +`/dev/shm`
growth) before any decision to grow swap. Record actuals in §6.

**Measured 2026-08-06** (node `…38df-6n69d`, representative — the image-puller
pulls to all 3 nodes so they match): single fs `/dev/vda` **73.8 GB** (the
"80 GB" is nominal), **22.0 GB used / 48.8 GB free**. Image store
(`…/k3s/agent/containerd`) already **21 GB** — tracelabs nix image + k3s system
images (one large nix image dominates). Kubelet ephemeral 75 MB. `/dev/shm` is
tmpfs (RAM, not disk) so it doesn't count here. Eviction floor
`nodefs.available<20%` = keep **14.8 GB** free → **34 GB spendable**. Margins
over the floor: **10 GB swap → 24 GB margin** (very safe), 16 GB → 18 GB, 24 GB
→ 10 GB. Verdict: **10 GB confirmed safe, wide margin**; 16 GB second sweep is
fine; 24 GB only if no additional large workspace image is enabled (each new
nix image is multi-GB and eats the margin).

### 3.1 Node mutation — privileged DaemonSet `zswap-enabler`

One DaemonSet (namespace `kube-system`, tolerates all taints, nodeSelector on
the session pool) whose container runs an **idempotent** setup script then
`sleep infinity` (so it stays as the applied-state marker and re-runs on new
nodes at join). All writes are to the host via `hostPath: /` + `privileged`.

Per node, idempotently:

1. **Swap file.** Only after §3.0a confirms disk headroom. If `/proc/swaps`
   has no entry: `fallocate -l 10G /host/var/lib/kasm-swap/swapfile` (or `dd`
   if the fs rejects fallocate), `chmod 600`, `mkswap`, `swapon`. Size =
   **10 GB** to start (conservative — see §3.0). Make the size a DaemonSet env
   var (`SWAP_GB`, default 10) so a second sweep can raise it without editing
   the script; **never above ~24 GB** or the `nodefs.available<20%` floor is at
   risk. Record actual + remaining free disk in §6.
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

### 3.2a DONE — what actually worked (2026-08-06)

Applied to all 3 nodes; verified. The exact recipe (k3s v1.36, Alpine/openrc):

1. **Swap + zswap** via `runs/chrome-density/zswap-enabler.daemonset.yaml`:
   10 GB swapfile at `/var/lib/kasm-swap/swapfile`, `zswap enabled=Y
   compressor=zstd max_pool_percent=20`. DaemonSet stays as the marker so new
   nodes get swap+zswap automatically.
2. **kubelet NodeSwap** — per node, edit `/etc/rancher/k3s/config.yaml`
   (backup kept as `config.yaml.bak-zswap`), appending under `kubelet-arg:`:
   `- fail-swap-on=false`, `- feature-gates=NodeSwap=true`,
   `- config-dir=/etc/rancher/k3s/kubelet.conf.d`; then a drop-in
   `/etc/rancher/k3s/kubelet.conf.d/10-swap.conf`:
   ```
   apiVersion: kubelet.config.k8s.io/v1beta1
   kind: KubeletConfiguration
   memorySwap:
     swapBehavior: LimitedSwap
   ```
   then `rc-service k3s restart`.
   **Finding: flags alone are NOT enough.** With just
   `fail-swap-on=false`+`NodeSwap=true`, a Burstable pod still gets
   `memory.swap.max=0` — this k3s defaults to `NoSwap` (the concept doc is
   right; the KEP's "default LimitedSwap when gate on" does not hold here).
   `swapBehavior=LimitedSwap` via the config-dir drop-in is required.
3. **Verified:** Burstable pod, 256 Mi request → `swap.max` 85.7 MiB; session-
   shaped 2.5 Gi request → **856 MiB** — matches `(request/32 GB)×10 GB`.

**Persistence caveats:** the config.yaml edits are on-disk (survive node
reboot) but are **per-node manual** — a CIVO node recycle/scale gives a new
node swap+zswap (DaemonSet) but **NOT** the kubelet NodeSwap config. Fine for
the fixed 3-node experiment before ~08-13; a durable rollout needs the kubelet
config templated at node bootstrap. Rollback: restore `config.yaml.bak-zswap`
+ `rc-service k3s restart`, then §8.

### 3.3a Blocker for Kasm-launched sessions — agent memory mapping

The k8s agent maps `cores` into pod resources but **not memory**:
`provisioner.py:_build_resources` reads `container_config.get("memory")` while
the value is carried as `memory_bytes` (DB column; image config 2.7 GiB). Result
observed on live `kws-trace-la-*` pods: `resources={"requests":{"cpu":"1"}}`,
`memory.max=max`, **`swap.max=0`**. No memory request → BestEffort-on-memory →
LimitedSwap grants zero swap, and no cap to force reclaim. **So the plumbing is
inert for Kasm-launched sessions.** For measurement use the direct CR
`runs/chrome-density/zswap-test-session.yaml` (explicit mem req+limit → Burstable
→ gets swap). Colleague item: fix the `memory`/`memory_bytes` field mismatch.

### 3.3 Workload — the KasmWorkspace CR

Sessions need memory **request < limit** (Burstable) for LimitedSwap to grant
swap. Test matrix caps (limit), request pinned at ~60% of limit; expected
per-pod swap at the starting **10 GB** host swap (§3.0), to verify against
`container_swap_limit_bytes` at runtime:

| cap (limit) | request | expected pod swap (10 GB host) | intent |
|---|---|---|---|
| 4Gi | 2.5Gi | ~0.8 GB | generous / near natural working set |
| 3Gi | 1.8Gi | ~0.55 GB | moderate squeeze |
| 2Gi | 1.2Gi | ~0.4 GB | aggressive — where zswap should earn its keep |
| 1.5Gi | 1Gi | ~0.3 GB | stress / find the usability cliff |

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
- **Usability** — ~~the session's OWN `memory.pressure` full avg10~~
  **CORRECTION (2026-08-06): PSI is unavailable on these CIVO k3s nodes**
  (`/proc/pressure/*` and per-cgroup `*.pressure` absent; kernel not booted with
  `psi=1`, unsettable on managed nodes). The whole PSI-based usability plan does
  not work here. Substitutes: (a) **wall-clock timing** of a fixed CPU/mem work
  burst (the §6.2a method — direct perception proxy); (b) **`memory.stat`
  refault counters** (`workingset_refault_anon/file`, `pgscan`, `pswpin`) as the
  thrash signal in place of `memory.pressure`; (c) **`cpu.stat throttled_usec`**
  for Quotas throttling. Node-level `vmstat` si/so for swap activity.
- **Node headroom** — `MemAvailable`, `/proc/swaps` Used, node PSI.

Derived: **sessions/node** (fill until cgPSI full10 > a threshold — propose 5%
sustained as the "still usable" line, tune on W1) and **sessions/100 GB** =
sessions/node × 100 / (allocatable GB).

A small collector script (`runs/chrome-density/zswap-probe-k8s.sh`, to write)
should snapshot all of the above across every session cgroup on a node into one
JSONL line per sample, like the `.140` probe.

---

## 6. Results (fill in)

### 6.0 RAM-only baseline + the bottleneck finding (measured 2026-08-06)

Direct KasmWorkspace CRs (not Kasm-orchestrated), tracelabs image,
`KASM_SKIP_STARTUP_SCRIPT=1`, memory req 2.5 Gi / limit 4 Gi, co-located on one
node. Desktop booted clean (0 ICE rejections — confirms the operator env-gate +
image `EnvironmentFile` fix). `memory.swap.max=0` throughout (NodeSwap not yet
enabled — correct RAM-only baseline).

| metric | value |
|---|---|
| 1 idle session `memory.current` | **781 MiB** (anon **185**, file **560**, slab 24) |
| 2nd co-located session, per-cgroup | 788 MiB (anon 187, file 565) |
| **2nd session marginal node RAM** (`MemAvailable` 28154→27813) | **~341 MiB** |

**The finding that reframes this experiment.** The 2nd session costs only
~341 MiB at the margin despite a 788 MiB cgroup, because its ~565 MiB of file
pages are shared `/nix/store` already cached from session 1. So **idle-session
RAM is already cheap (~340 MiB marginal) — memory is not the density bottleneck
on this cluster.** zswap compresses anon (~185 MiB); compressing a 185 MiB
anon set that's already this small is low-value at idle. zswap's case rests
entirely on W2 (Chrome), where anon balloons — §6.2.

**The actual bottleneck is CPU *requests*.** All three 4-core nodes sit at
94–98% CPU requested with memory at 4–23%. Cause: Kasm's default session
requests **2000m CPU** (seen on the leftover `kws-trace-la-*` sessions), plus
control plane (guac 1000m, db 750m, api/manager/proxy/gateways 500m each). At
2 CPU/session a 4-core node holds ~1 session beside the control plane —
**density here is CPU-request-bound long before memory-bound, so zswap cannot
raise it until session CPU requests drop.** This is the higher-value lever and
should be resolved (or at least measured) before the zswap sweep. See §9.

### 6.0a CPU sizing → user perception (config changed to 1 core, 2026-08-06)

Session config now `cores=1`, `cpu_allocation_method=Inherit`, memory
`2.7 GiB`. How the agent maps `cores` decides perception
(`provisioner.py:207–214`):

| cpu_allocation_method | k8s result | QoS | perception |
|---|---|---|---|
| **Shares** (Kasm default; `Inherit` resolves here unless changed) | `requests.cpu=1`, **no limit** | Burstable | a lone session **bursts to idle node cores** → feels like the whole box; degrades only as the node packs and active sessions contend |
| **Quotas** | `requests.cpu=1` **and** `limits.cpu=1` | (still Burstable, mem req==lim) | **hard CFS throttle at 1 core always** — page-load/render bursts (want 2–4 cores for ~1 s) get stretched → visible jank even on an empty node |

`default_cpu_allocation_method` is stored **encrypted** in `settings`, so the
resolved value isn't DB-readable. Confirm on the next launch:
`kubectl get pod <kws-pod> -o jsonpath='{.spec.containers[0].resources}'` —
**`limits.cpu` absent = Shares (good); `=1` = Quotas (throttled)**.

**The core trade.** With Shares, "1 CPU" is a *request*, not a ceiling, so
perception is **load-dependent**: excellent at low occupancy, worst-case only
when several co-located sessions are simultaneously *active*. Density and
worst-case interactivity therefore trade directly — the 1-core request is what
lets you pack, and packing is exactly what erodes p99 feel. The predictor is
per-session **`cpu.pressure` `some` avg10** under concurrent active load, not
idle. Two amplifiers specific to this fleet:

- **Software rendering (llvmpipe, no GPU)** — all browser paint/compositing is
  CPU, so a browsing desktop is CPU-hungry precisely where users feel it
  (scroll, video, canvas). This is likely the #1 felt limit under contention;
  no swap/zswap change touches it. A GPU or fewer/bigger sessions is the only
  real fix.
- **phx1 RTT** — a constant latency floor that stacks on any render jank.

**Where zswap actually helps perception (not density):** the memory **limit is
a hard 2.7 GiB**. A Chrome-heavy session that exceeds it OOM-kills tabs/session
*without* swap; *with* zswap+swap it spills cold anon to a compressed pool and
**degrades gracefully (slight slowness) instead of crashing**. So on this
1-core / 2.7 GiB config zswap's value reframes from "more sessions" to
"fewer tab/session crashes under memory pressure" — a perception win at the
ceiling. That is the W2 hypothesis to test (§6.2).

**Perception measurement to add to the run:** at N=1,2,3,4 co-located *active*
sessions (real browser workload, not idle), record per-session
`cpu.pressure some avg10` and a wall-clock proxy (page-load time or scripted
scroll FPS). The N where `some avg10` crosses ~20–30% sustained is the real
**active** sessions/node — expect it well below the idle packing number. Report
both; the honest density figure for interactive use is the active one.

### 6.0b Load-harness run + the concurrency-limit stack (2026-08-07)

Harness `runs/chrome-density/kasm-loadtest.sh` (Kasm Developer API launch →
pod correlation via `kasm.kasmid` label → `nix-launch firefox` drive →
per-session cgroup time-series → `destroy_kasm` teardown). Ramp mode: staggered
arrival (one session / 20 s), drive-on-arrival, sustained peak sampling.

**Attempting 18 concurrent revealed three stacked caps, hit in order:**

| limit | where | was | action |
|---|---|---|---|
| server `max_simultaneous_sessions` | `servers` row (auto-registered k8s agent default) | 1 | raised to 30 |
| `max_kasms_per_user` | group_settings ("All Users") | 5 | raised to 20 |
| **concurrent-session LICENSE limit** | Kasm license entitlement | **5** | **hard ceiling — not bypassed** |

So **peak concurrency on this deployment is 5** ("Per concurrent session license
limit exceeded" at the 6th). Testing the 18-session peak needs a license with
≥18 concurrent seats; everything else (CPU oversubscription, slots, per-user cap)
is already provisioned for it.

**5-session peak (firefox, 8 tabs each, staggered ramp):**

| metric | value |
|---|---|
| per-session `memory.current` | ~2.3 GB (anon ~1.6 GB) |
| total across fleet | 11.3 GB over 3 nodes (~3.8 GB/node) |
| node spread | 1 / 2 / 2 (k8s balanced) |
| cpu request / actual | 300m request (oversubscribed), bursting via Shares |
| **swap used / zswap pool** | **0 / 0** |

**zswap armed but did not engage** — each session (~2.3 GB) stays under its
2.77 GB cap, and nodes sit at ~11 GB of ~27 GB RAM, so there is no memory
pressure to reclaim. This re-confirms §6.0: at achievable density **memory is
not the constraint** (CPU is, which is why we oversubscribed). zswap only earns
its keep under much heavier *per-session* memory (more tabs, or a lower cap) —
i.e. the §6.2 W2 cap-sweep, not the raw session count. A realistic peak of 18
light sessions would still sit comfortably in RAM (~40 GB / 81 GB) and not
compress.

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

### 6.2a Perception — Shares vs Quotas, measured 2026-08-06

**PSI is unavailable on these nodes** (`/proc/pressure/*` and per-cgroup
`*.pressure` absent — CIVO's k3s kernel doesn't set `psi=1`, unsettable on
managed nodes). The doc's planned usability metric (cgroup PSI) does not exist
here — see §5 correction. Substituted a **wall-clock proxy**: a 3-thread fixed
CPU burst (`hashlib.sha256` ×3, approximating Chrome's multi-threaded
render/JS), timed under each condition. Confirmed cgroup wiring: Shares
`cpu.max = "max 100000"` (no cap), Quotas `cpu.max = "100000 100000"` (hard 1
core).

| condition | 3-thread burst wall time | throttling |
|---|---:|---|
| **Shares, solo** (bursts to free node cores) | **0.76 s** | 0 |
| **Shares, 2 co-located both bursting** (6 threads / ~2.85 free cores) | **1.05 / 1.15 s** | 0 |
| **Quotas, solo** (hard-capped at 1 core) | **5.30 s** | 57 s `throttled_usec` under load; **10.9 s accrued just at idle boot** |

**Verdict — CPU allocation method dominates perception, not density.**
Quotas is **7× slower** than Shares on a multi-threaded burst, and even a
*single* Quotas session (5.30 s) is **5× slower than two contended Shares
sessions** (1.05 s). Shares degrades gracefully under co-location (0.76→1.1 s,
~1.4×) because both sessions burst and the scheduler shares free cores fairly;
Quotas clamps every render spike regardless of idle capacity — the 10.9 s of
throttling accrued just booting is what a user feels as UI lag. **Ship
`cpu_allocation_method=Shares`** (request-only, no CFS limit). With Shares, the
1-core config is a request that protects density without hurting interactive
feel until the node is genuinely saturated; the remaining felt limit is then
llvmpipe (software render), not CPU scheduling.

Caveat: synthetic hash burst ≈ CPU-bound render, but not identical to real
Chrome (GPU-less paint, GC, network). Re-run with the nix-testbench + Kasm API
driving real browser workloads to confirm the wall-times translate, and to find
the active-session count where even Shares contention becomes noticeable.

### 6.3 Narrative
_(compression ratio achieved, where the usability cliff sits, how it compares
to `.140`'s 2–3× at 400–600m, whether cgroup-v2 LimitedSwap changed the shape,
and — the headline for the 1-core config — at what active-session count
cpu.pressure makes it feel slow, i.e. the gap between idle packing density and
usable active density.)_

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
   still `feature-gates=NodeSwap=true`? Confirm before §3.2. (Related, resolved
   2026-08-06: no fixed per-pod swap on k8s — it's proportional; §3.0.)
6. Does the LimitedSwap formula divide by node *total* physical memory or
   *allocatable*? Assumed total (~32 GB); confirm against
   `container_swap_limit_bytes` on the first Burstable test pod — it changes the
   per-pod grants in §3.0/§3.3 by ~15%.
2. Does the node's crypto stack have zstd, or do we fall back to lzo?
3. Is fallocate honoured on the node root fs, or do we need `dd`?
4. One-node-per-cell (clean isolation, 3 cells at a time) vs serialise on one
   node (more cells, slower) — pick before starting.
5. Usability threshold: is cgPSI full10 = 5% the right "still usable" line, or
   calibrate against a hands-on session first?
