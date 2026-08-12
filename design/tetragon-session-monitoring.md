# Tetragon session monitoring

Runtime detection for Kasm workspace sessions. This documents **what is built,
what it does, and why it is configured the way it is** — so that changes are
deliberate rather than rediscovered.

If you are changing this system, read §5 first. Most of the configuration here
looks arbitrary and is not; several settings fail *silently* when changed.

---

## 1. Purpose

Kasm here is shared hosting: each user gets a containerised desktop on
infrastructure shared with other users. Two duties follow:

1. **Protect the host and co-tenants** — a container escape, runtime-socket
   connect, or kernel-surface probe from one session threatens every other
   session on that node.
2. **Detect abusive use of the service** — mining, outbound scanning, spam
   relay. This is contained *within* a session, so containment controls never
   fire; it has to be observed.

Both require attributing an action to a session. `design/security-model.md`
covers the preventive side; this is the detection side.

**What Tetragon is not.** It is not a syscall log. It sees the event types its
base sensors emit plus the hooks in loaded policies. A syscall rejected by
seccomp never reaches a downstream kprobe, so *absence of an event is not
evidence of prevention*.

---

## 2. What is deployed

Tetragon **v1.7.0** as a DaemonSet on the CIVO cluster `kasm-tracelabs`
(region `phx1`), namespace `kube-system`, helm release `tetragon`.

```
CIVO phx1 (3 nodes)                        OCI us-phoenix-1
┌──────────────────────────────┐          ┌──────────────────────────┐
│ Tetragon DaemonSet           │  TLS     │ obs-1 (A1.Flex 2/12)     │
│  → /var/lib/tetragon/export/ │  ──────► │  Caddy :443 (LetsEncrypt)│
│    tetragon.log (0600)       │  basic   │  Loki  (14d retention)   │
│ Alloy DaemonSet              │  auth    │  Prometheus (health, 7d) │
│  ro mount, positions on host │          │  Grafana                 │
└──────────────────────────────┘          └──────────────────────────┘
```

**Live end to end since 2026-08-09.** Session events reach Loki and Tetragon's
metrics reach Prometheus. `grafana.emrul.oci.dev.remotebrowser.net`; config in
`deploy/obs/` and `deploy/tetragon/alloy*`.

### Verified node facts (2026-08-08)

| | |
|---|---|
| Nodes | 3 × `g4m.kube.medium`, Alpine Linux 3.22 |
| Kernel | `6.12.85-0-lts` — clears ≥5.11 (`sockaddr_un`) and ≥6.1 (`security_create_user_ns`) |
| BTF | `/sys/kernel/btf/vmlinux` present, 4.86 MB — Tetragon's hard gate |
| LSMs | `lockdown,capability,landlock,yama` — **no AppArmor, no SELinux, no BPF LSM** |
| CRI socket | `/run/k3s/containerd/containerd.sock` — the *only* one present |
| `/run` | tmpfs, 6.0 GB — **never export here** |
| `/var/lib` | `/dev/vda` ext4, root filesystem, **74–79% used**, 15–19 GB free |
| Listeners | `:2112` metrics, `:6789` gRPC health. No event socket, gops, or pprof |

### Session selection

Session pods carry `kasm.kasmid=<canonical uuid>` at creation. The export
allowlist and every policy select on that key's **existence**:

```
kubectl get pods -A -l kasm.kasmid
```

A bare label *key* is an Exists selector, so no session identifier enters the
configuration. Pods do **not** carry `kasm.com/kasm-id` — that label is on the
`KasmWorkspace` CR only.

Pod names look like `kws-trace-la-080004eacdd0-deploy-<rs>-<suffix>`:
`kws-{img8}-{id12}`, where `id12` is `kasm_id.replace("-","")[:12]`. On this
deployment there is **no username fragment** — the `kws-{user8}-{img8}-{id12}`
form requires `KASM_USER` populated. Attribution therefore reaches the *session*,
and resolving a session to an account is currently manual.

### Measured volume (base sensors only, no policies loaded)

| Node | Events | Window | Rate | Bytes/event | Per hour |
|---|---:|---:|---:|---:|---:|
| ...6n69d | 1552 | 15m37s | 1.66/s | 8.8 KB | ~52 MB |
| ...r818z | 509 | 6m36s | 1.29/s | 6.6 KB | ~30 MB |
| ...d6463 | 288 | 36m38s | 0.13/s | 5.5 KB | ~2.6 MB |

**Per active session, 2026-08-09:** one real workspace produced **1434 events
in 10 minutes** (~2.4/s, ~8.6k/hour). That window includes browser startup, so
it is an *active* figure, not idle — but it means a single busy session is
roughly the same order as the earlier busiest-node total. Size concurrency
against this, not against the node figures below.

~85 MB/hour cluster-wide ≈ 2 GB/day ≈ 29 GB raw per 14 days. The 550 MB/node
buffer gives ~10 hours at peak, well beyond the 30-minute outage target, and
rotation caps on-disk use so a shipper outage cannot fill the node disk.

Events are large (5.5–8.8 KB). Drivers: base64 `exec_id`s, pod metadata repeated
across `process`/`parent`/`ancestors`, and a 558-byte `node_labels` blob (§5.4).

---

## 3. Configuration

Live values: `values-tetragon.yaml` (see §7 — needs a permanent home).
Deployed via a helm post-renderer plugin, **not** `--post-renderer <path>`.

```bash
helm upgrade --install tetragon cilium/tetragon --version 1.7.0 \
  -n kube-system -f values-tetragon.yaml \
  --post-renderer tetragon-postrender --wait
```

The settings that matter, and why:

| Setting | Value | Why |
|---|---|---|
| `exportDirectory` | `/var/lib/tetragon/export` | Top-level key, **not** under `tetragon:`. `/run` is tmpfs — exporting there spends node RAM and loses data on reboot |
| `export.mode` | `""` | Disables the stdout sidecar, which would duplicate every event into pod logs |
| `tetragon.grpc.enabled` | `false` | File filters are **per-request**; a gRPC client supplying empty filters reads everything, including argv |
| `tetragon.gops.enabled` | `false` | Unauthenticated node-loopback surface under hostNetwork; also a *control* channel (forced GC) into the agent |
| `tetragon.pprof.enabled` | `false` | Same class of surface |
| `enableKeepSensorsOnExit` | `false` | Kill switch depends on sensors unloading on exit |
| `exportFilePerm` | `"600"` | Reader runs as UID 0 with all capabilities dropped |
| `exportFileMaxSizeMB/Backups` | `50` / `10` | ~550 MB/node. Reduced from 100×20 because `/var/lib` is the root fs at 74–79% |
| `metricsLabelFilter` | `"namespace"` | `workload` is the Deployment name and carries the session fragment — see §5.5 |
| `processAncestors.enabled` | `"base,kprobe"` | Renders as `enable-ancestors`. `base` is required by every other type |
| `clusterName` | `civo-phx1` | Appears on every event |

### Export filtering

Selection runs **before** field filtering, so pod labels select the event and
are then stripped from its body.

```
exportAllowList:  {"labels":["kasm.kasmid"], "event_set":[...]}
exportDenyList:   {"health_check":true}
fieldFilters:     EXCLUDE process/parent/ancestors × arguments,
                          environment_variables, cwd,
                          pod_labels, pod_annotations
redactionFilters: token / password / VNC_PW / kasm_user: patterns
```

**Arguments and environment variables are excluded entirely**, because Kasm puts
credentials in argv:

- `src/common/kasm-go/scripts/kasm-setup` — VNC password inside an `sh -c` string
- `src/common/kasm-go/units/audio-in.service` — `--auth-token kasm_user:$VNC_PW`
- `src/common/kasm-go/units/audio-out-ws.service` — same, as a bare positional

Redaction replaces regex **capture groups** only, and cannot identify the
unmarked positional password in the `sh -c` case. It is defence in depth, not
the control. Re-enabling argv requires removing those call sites first.

### Verified clean

Against both synthetic and **live session** data: no `arguments`,
`environment_variables`, `cwd`, `pod_labels`, or `pod_annotations` keys; no
`VNC_PW`, `kasm_user:`, `KASM_API_JWT`, `auth-token`, or `Bearer` strings; no
planted test literals in export files or pod logs.

---

## 4. Detection policies

**Status: six loaded, `enabled=6 error=0 load_error=0` on all three nodes**
(verified 2026-08-12). Sources in `deploy/tetragon/policy-*.yaml`; install order in
`deploy/civo/README.md` §2.10.

| Policy | Hooks |
|---|---|
| `kasm-observe-userns` | `create_user_ns` (return captured) |
| `kasm-observe-runtime-sockets` | `security_socket_connect` + `sockaddr_un` |
| `kasm-observe-bpf-perf` | `bpf_check`, `security_perf_event_alloc`, `security_bpf_map_alloc`/`_create` |
| `kasm-observe-modules` | `security_kernel_module_request`, `security_kernel_read_file` |
| `kasm-observe-foreign-binary` | `security_bprm_check` — exec from a writable path |
| `kasm-observe-egress` | `tcp_connect` — external, non web/DNS/NTP port |

**Noise: zero.** Across all three nodes, real sessions produced **no kprobe
events at all** — every one observed so far came from deliberate probes. These
are high-signal policies, not a volume problem. Alert on them accordingly.

All policies are observe-only, carry the session `podSelector`, and are
validated with server-side dry-run *and* confirmed loaded via metrics.

```yaml
podSelector:
  matchExpressions:
    - key: kasm.kasmid
      operator: Exists
```

### Planned set

**User namespaces** — kprobe `create_user_ns`, `syscall: false`, `return: true`,
`returnArg: {index: 0, type: int}`.

> On these nodes there is no AppArmor, so a negative return does **not** mean
> "AppArmor blocked it" — nothing mediates `userns_create` here. Report as
> *userns creation observed / refused*. A seccomp rejection produces **no event
> at all**, which is a different result. The policy still earns its place: a
> successful userns creation from a tenant shell is the signal that matters.

**ANSWERED 2026-08-09, in a real Kasm session.** `unshare -U true` from the
session terminal returned **0**, confirmed both by `echo $?` and by the captured
`return.int_arg`. So:

- **Seccomp does not block `unshare(CLONE_NEWUSER)`** under the profile a real
  workspace actually gets. It is not merely a property of unconfined test pods.
- With no AppArmor either (§5), **nothing on these nodes mediates user-namespace
  creation**. A tenant can obtain a namespace in which they are root — the usual
  first step toward kernel LPE, and precisely the Model B risk in
  `security-model.md`.

**But it cannot simply be blocked.** In one ~10-minute session, 29
`create_user_ns` calls were observed, all returning 0:

| Count | Binary |
|---:|---|
| 14 | `/usr/bin/bwrap.real` |
| 10 | firefox (`…/lib/firefox/firefox`, `.firefox-wrapped`) |
| 4 | chromium (`…/libexec/chromium/chromium`) |
| **1** | **`/usr/bin/unshare`** ← the tenant |

28 of 29 are the browser sandboxes doing their job. Disabling user namespaces
wholesale would break the browsers, which are the product. This is exactly the
tension `security-model.md` §5.2 predicted, and its answer — per-binary scoping
— requires AppArmor, which these nodes do not have.

**So prevention is unavailable here, but discrimination is easy.** The legitimate
creators are a short, stable set of paths. Anything else is signal. Proposed
rule, which the loaded policy already supports without modification:

> Alert on `create_user_ns` where the binary is **not** bwrap, firefox, or
> chromium. Baseline those three; treat `/usr/bin/unshare`, any shell, or any
> unexpected path as high severity regardless of return value.

Match on the resolved path and keep the allowlist in version control — a Nix
store path changes on every package update, so match the trailing component
(`/lib/firefox/firefox`), not the hash.

**Runtime sockets** — kprobe `security_socket_connect`, arg 0 `socket`, arg 1
`sockaddr_un`, one selector matching `Family: AF_UNIX` plus `Equal` over all
socket paths. See §5.1 — this must be **one** selector, not one per path.
`/run/k3s/containerd/containerd.sock` is the only path that exists here; the
others are cheap defence in depth.

**BPF / perf / modules** — from the pinned v1.7.0 policy library, adding the
`podSelector`. Take `bpf_check`, `security_perf_event_alloc`,
`security_bpf_map_alloc`, `security_bpf_map_create` from `bpf.yaml`, and
`security_kernel_read_file` from `modules.yaml`.
Keep upstream's `ignore: {callNotFound: true}` on **both** map hooks — the
symbol changed at Linux 6.9 and dropping either guard can block policy load.
Do **not** copy `bpf.yaml` wholesale: `security_file_permission` and
`security_mmap_file` attach to hot LSM paths for no query we have.
`security_kernel_module_request` has no argument selector upstream (unlike its
`READING_MODULE`-scoped sibling) — baseline it before alerting.

### Abuse detection — measured baselines

These target §1 duty 2, and each carries a measured carve-out rather than a
guess. Three need no new kernel probe at all: they are Loki rules over exec
events we already collect, which is the payoff for keeping raw exec.

| Signal | Baseline measured | Discriminator |
|---|---|---|
| User-supplied binary | 828 execs/90min, 8 outside shipped paths | exec from a writable path |
| Unusual egress | verified: 3333 and 25 alert, 443 does not | external + not web/DNS/NTP |
| Privilege escalation | `su` runs **21×** per session, **all** from our boot chain | parent binary, *not* uid |
| Miner names | zero | name match — trivially evaded, bonus only |
| Host root in a session | 4 execs/pod-start, all `/proc/self/fd/*` | host uid 0 that is not runc's own setup |

**`hostUsers: false` also changes the userns risk assessment above.** With
container root mapped to an unprivileged host uid, a tenant creating nested user
namespaces holds no host privilege at any point, so the "nothing mediates
userns creation" finding is materially less severe than when first recorded.
Detection still matters — the mapping is the control, and this alert is what
proves the control is actually on.

It doubles as a **rollout-compliance check**: sessions created before the
`hostUsers` change ran unremapped, showing 423 execs at plain uid 0 and uid 1000
with no mapped range, and would fire immediately.

Two traps found while measuring these:

- **`su` is not rare.** It runs 21 times in a normal session, always from
  `kasm-setup`, `nix-activate`, `timeout` or `runc`, dropping privilege rather
  than raising it. `sudo` is not installed at all. A naive "alert on su" rule is
  pure noise.
- **Those odd uid values are user-namespace remapping, not corruption.** I first
  recorded them as untrustworthy; that was wrong. Session pods run with
  `pod.spec.hostUsers: false`, so the kubelet maps container uids onto an
  unprivileged host range and Tetragon reports the **host-side** uid. Measured on
  one pod: container uid 0 → `3597729792`, container uid 1000 → `3597730792`
  (base + container uid, a distinct base per pod). Comparing uid to `0` or `1000`
  inside a session does not mean what it looks like — but the uid itself is
  precise and useful.

Mining detection deliberately does not lean on names. A downloaded miner trips
the user-supplied-binary rule whatever it is called, and its pool connection
trips the egress rule; the name list only catches the careless.

### Later, and deliberately re-prioritised

The ordering above is containment-first. For shared hosting the *likely* event
is in-session abuse — mining, outbound scanning, spam relay, credential
stuffing — none of which trips a containment control, and all of which get your
address ranges blocklisted. Promote egress and miner rules once the co-tenant
policies are proven. Neither rule is written yet.

Not alert conditions, deliberately: raw exec volume (collected, but noisy).
Not collected at all: browsing history, `$HOME` file reads.

---

## 5. Traps

Every item here was found the hard way. Each fails **silently** or misleads.

### 5.1 A kprobe accepts at most 5 selectors

`MaxSelectors = 5`, enforced at *sensor construction* — a server-side dry-run
passes and the policy then fails to load. Use one selector with many `Equal`
values (values within one `matchArgs` entry are OR'd), not one selector per
value.

### 5.2 Unknown field-filter paths are silently ignored

FieldMask paths are format-validated, never checked against the schema. A typo
strips nothing and reports nothing. Note `ancestors` is a **top-level sibling**
of `process`/`parent` — `process.ancestors.arguments` would be a no-op.
**Always assert on exported JSON keys**, not on planted values.

### 5.3 Settings that render nothing when correct

- `enableKeepSensorsOnExit: false` → the ConfigMap key is **absent**. There is
  no `"false"` form to grep for.
- `gops` / `pprof` disabled → `gops-address` / `pprof-address` absent. Both are
  **ConfigMap keys**, not container args — checking the arg list proves nothing.
- `extraArgs: enable-process-environment-variables: "false"` → **keep the
  quotes**. Unquoted YAML `false` is falsy in Go templates and emits the *bare
  flag*, which pflag reads as **true**.

### 5.4 `node_labels` cannot be field-filtered

It is field 1004 on the `GetEventsResponse` **wrapper**, not the event message,
so no FieldMask reaches it. Excluding it is accepted and does nothing. It is 558
bytes on every event (~7–10%) and carries the node's **external IP** and Civo
pool UUID. Drop it in Alloy at ingest.

### 5.5 The metrics plane bypasses the field filters

`metricsLabelFilter` accepts `namespace,workload,pod,binary`. `workload` is the
Deployment name — which carries the session fragment — so enabling it copies
identifiers into Prometheus as labels, under a *different* retention, with one
series per session. Use `namespace` only.

Note the filter **blanks label values, it does not remove label keys**. A check
that greps for `workload=` will false-positive; assert no *non-empty* values.

### 5.6 The chart hard-codes a 1-second grace period

`terminationGracePeriodSeconds: 1` is literal in the DaemonSet template with no
values key. One second is not enough to unload BPF sensors, so draining the
DaemonSet leaves programs attached — pods gone, instrumentation still running.

**Do not fix this with `kubectl patch`.** Doing so makes kubectl the field
manager for that path and the next `helm upgrade` fails with a server-side-apply
conflict (observed). Use the post-renderer. Helm 4 changed `--post-renderer` to
take a **plugin name**, not a path, so it is installed as a `postrenderer/v1`
plugin.

### 5.7 Export selection fails closed on the enrichment race

The label filter returns false when an event has no Pod. The event cache retries
pod association 15 × 2s, then emits the event **unenriched anyway** — where the
allowlist drops it. Startup execs can be lost silently. Alert on
`tetragon_event_cache_fetch_failures_total{entry_type="pod_info"}`.

Fail-closed is the deliberate choice: the alternative exports unrelated host
activity.

**Measured, 2026-08-09.** A pod ran three `unshare` calls: two in its first
second, one several seconds later after an `apk add`. Only the *late* one
produced an event. Re-running all three by `kubectl exec` into the same,
now-established pod produced all three. **Two of three events were lost in the
opening seconds of pod life.**

**How much this matters: less than it first appears.** The missed window holds
the *image's own boot* — `container-init`, its units, KasmVNC starting. A tenant
cannot reach it: they must wait for KasmVNC to listen, the proxy to route, the
browser to connect and authenticate, and then type something. That is many
seconds and gated on a human. Staged/assigned sessions widen the distance
further, since the pod is created well before a user is attached.

It matters only where code you do not control runs at t=0:

- a hostile or compromised **workspace image** — a different threat model from
  "the user is hostile", and on this deployment images come from our catalog;
- a **tenant-supplied image, `command`, or `args`**, if any workspace definition
  allows one. *This is the question that decides the priority of this gap.*

The real residual cost is baseline quality, not defence: session boot is exactly
what the dataset cannot see, so this design cannot detect a tampered image
running something unexpected at startup.

Note the mechanism, because it changes the fix: the events were almost certainly
never *generated* (the pod was not yet in the **policy filter** map) rather than
generated-and-dropped. The export path caches unenriched events and retries for
~30s, and these never appeared long after that. So raising `eventCacheRetries`
would not help; only the runtime hooks would. **Inferred, not measured.**

### 5.8 gRPC bypasses the export filters entirely

Allow/deny/field filters are **per-request**. A client with empty filters gets
full argv, cwd, and pod labels. Only redaction is global — it is applied at
process-cache construction, so it covers gRPC too. This is why the event server
is off.

### 5.9 Verify policy state via metrics, not `tetra`

With gRPC disabled, `tetra status` and `tetra tracingpolicy list` cannot run.
Use `tetragon_tracingpolicy_loaded{state=...}`. It is an aggregate count by
state with **no `policy` label**, so it tells you *that* something failed, not
*which* — read node logs for that.

### 5.10 Version-pinned behaviour

`sockaddr_un` is **v1.7.0+**. Downgrading rejects the policy at CRD validation.
Abstract socket names use a 107-byte NUL-padded form with the leading `@`
stripped before matching, so `Equal` on a visually similar value never matches —
filesystem paths only.

---

### 5.11 A kprobe event is "hook reached", not "operation succeeded"

Demonstrated on the socket policy: a connect to
`/run/k3s/containerd/containerd.sock` from a pod where that socket is not
mounted returns **ENOENT**, and still produces a full event with the decoded
path — because `security_socket_connect` is an LSM hook that runs *before* unix
path resolution. Read the userspace return separately from the event.

Conversely, a seccomp rejection produces **no event at all**. Absence proves
nothing on its own.

---

## 6. Data handling

### What is collected

Per event, where the event type supplies it: executable path, PID, UID, start
time, pod/container/namespace/workload, node, cluster, policy name, decoded
kprobe arguments, return values, and the ancestor chain of executable paths.

**Not collected:** command arguments, environment variables, working
directories, pod labels/annotations, file contents, URLs or browsing history,
keystrokes, screen contents, clipboard, audio, video, network payloads.

### Identifiability

Events carry `id12` — a session fragment — in the pod and workload name. On this
deployment there is no username fragment (§2). Kasm's own session records are
**not** ingested (§7), so within this system a record resolves to a pod, node,
and session — not to an account. Resolving to an account is manual.

Attribution is **intended**, not incidental: an unattributed detection cannot be
investigated or acted on. What is minimised is *how* it is held, not whether —
never as a Loki stream label, same 14-day retention as the events, same audited
access.

`user8`, where it exists, is an 8-character prefix and users can collide. Never
act on an account on the strength of it; resolve via `id12` first.

### Retention

14 days, enforced by the Loki Compactor (`retention_enabled: true`,
`retention_period: 336h`, `delete_request_store: filesystem`, persistent working
directory). Disk size is not retention — filesystem Loki keeps data forever by
default.

### For counsel

The characterisation and the determination are counsel's, not engineering's.
Engineering keeps these facts current; it does not self-assess them.

- Shared-hosting service; stated purposes are protecting co-tenants and
  detecting abusive use; the system is designed to identify the responsible
  account rather than avoid doing so.
- The dataset shows which executables ran in a session, in what order, and when
  — therefore which applications a person used and when. It does not show what
  they did inside an application.
- Regions: CIVO `phx1`; OCI region for `obs-1` **not yet chosen**.
- Populations, in order: synthetic tests → staff sessions → hosted users.
- Alert notifications leave the system (Slack is in the architecture, still an
  open choice). An annotation carrying session fragments exports identifiers to
  a third party with its own retention and access model. Default to a
  non-identifying Grafana link until that is decided.
- Credentials appear in process arguments, which is why argv is excluded. Any
  real credential observed is a security incident requiring rotation.

Open questions: whether this is personal data; what basis, notice, or
safeguards attach to the attribution purpose; what is required *before* acting
against an account rather than investigating; whether staff monitoring engages
distinct obligations; whether the region pair raises a transfer question;
whether AUP or terms language must cover this before hosted users are observed.

---

## 7. Not built yet

| | |
|---|---|
| **Seccomp reality check** | Whether a real Kasm session's seccomp profile blocks `unshare` — see §4. Launch a workspace we own; do not probe a tenant's live session. |
| **Health-plane alerts** | Prometheus is receiving remote-write, but no alert rules are defined yet: loss counters, canary gap, disk >80%, clock offset, `tracingpolicy_loaded` errors. |
| **Canary DaemonSet** | Not deployed. Needed to prove the pipeline end to end per node when no session is running. |
| **Health plane** | Prometheus (health-only, 7 days), per-node canary DaemonSet, alerts on loss counters, canary gaps, disk >80%, clock offset. Rules key on `(cluster, node)` — node names are not unique across clusters. |
| **Kill switch** | Two modes: stop shipping (pause Alloy, preserve positions), stop collection (drain via unsatisfiable node selector). Must verify post-drain that no BPF pins survive under `/sys/fs/bpf/tetragon`. |
| **Kasm session correlation** | **Blocked.** `provision.create` fires *before* provisioning succeeds and carries no `kasm_id`, `server_id`, or account; the documented JSON log files are absent from the k8s `api`/`manager` pods. Needs a post-success lifecycle event (`session.started`/`session.ended`) with `container_id`, `kasm_id`, account, image, server — a `kasm_backend` change owned by another team. |
| **Config home** | ~~scratchpad~~ **done** — `values-tetragon.yaml`, the post-renderer and the policies are committed under `deploy/tetragon/`, and the live helm values match that file byte for byte (checked 2026-08-12). The whole deployment's recreate path is `deploy/civo/README.md`. The objection stands in principle — this repo builds container images — but a rebuild needing files nobody can find was the worse failure. |

Rules that survive whenever correlation is built: ingest a session *dimension*
(a few lines per session), never URL-level data, never a session ID as a Loki
stream label, correlate at query time (LogQL has no join), and reject
ingest-time API enrichment — it would put a Kasm credential on every node.

---

## 8. Decision log

| Date | Decision | Why |
|---|---|---|
| 2026-08-04 | Tetragon over Falco | A customer already runs it; shared policy language, kernel-side filtering, an enforcement path if ever justified |
| 2026-08-04 | Self-hosted Loki + Grafana on one OCI VM | Spike economics; VictoriaLogs is the lighter fallback |
| 2026-08-04 | Observe-only, no enforcement | A false-positive `Sigkill` kills a customer session |
| 2026-08-07 | Exclude argv/env for the whole spike | Kasm puts credentials in argv; regex cannot safely redact an unmarked positional password |
| 2026-08-07 | Treat events as "hook reached", not proof of a syscall attempt | Seccomp rejects before downstream hooks; no event ≠ no attempt |
| 2026-08-07 | Disable gRPC, gops, pprof | Export filters are per-request; all three are unauthenticated node-local surfaces under hostNetwork |
| 2026-08-07 | Fail-closed export selection | An unenriched event is lost rather than exporting unrelated host activity |
| 2026-08-07 | 14-day retention, Compactor-enforced | A concrete enforced window beats an unevaluated range |
| 2026-08-08 | **AppArmor out of scope** | Nodes are Alpine with no AppArmor and it will not be enabled. `security-model.md` §5.2 per-binary userns scoping is not implementable here; userns events lose their AppArmor interpretation but keep detection value |
| 2026-08-08 | Select on `kasm.kasmid` (Exists) | Already on every session pod; a bare key is an existence test so no identifier enters config. Needs no operator change. A boolean `kasm.com/session=true` stays preferable long-term |
| 2026-08-08 | Buffer 50 MB × 10 | `/var/lib` is the root fs at 74–79%; measured peak still gives ~10h against a 30-min target |
| 2026-08-08 | `metricsLabelFilter: "namespace"` | `workload` carries the session fragment into a plane the field filters never touch |
| 2026-08-08 | Grace period via helm **plugin** post-renderer | Chart hard-codes 1s with no values key; `kubectl patch` breaks the next upgrade |
| 2026-08-08 | Correlation blocked, not designed | The source event does not exist in the product today |
| 2026-08-08 | Attribution retained deliberately | Shared hosting: an unattributed detection cannot be investigated or acted on |
| 2026-08-09 | Four policies loaded; alert on them rather than sample | Real sessions produce zero kprobe events, so these are signal not volume |
| 2026-08-09 | **Userns creation is unmediated on these nodes** — detect, do not attempt to prevent | Confirmed in a real session: `unshare -U` returns 0 under the production seccomp profile, and there is no AppArmor. Browsers legitimately create 28 of every 29 namespaces, so blocking breaks the product. Alert on non-browser creators instead |
| 2026-08-09 | Keep `ignore.callNotFound` on both BPF map hooks | Confirmed on 6.12: `security_bpf_map_create` loads, `security_bpf_map_alloc` is absent and silently skipped. Without the guard the policy would fail to load |

---

*Keep this current. Deployed changes go in §2 or §3; choices go in §8 with the
reason. Anything discovered that fails silently goes in §5.*
