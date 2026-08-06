# Tetragon session monitoring — runtime detection for Kasm workspaces

Audience: engineers building/operating the observability spike, and reviewers of
the security posture. This is a **living document** — update the Status table
and Decision log as the work moves; do not let it fossilize into a proposal
nobody re-reads.

> TL;DR — Tetragon (eBPF, from the Cilium project) runs as a DaemonSet on the
> CIVO cluster and observes every process/syscall event inside Kasm session
> containers. Events ship to a small OCI VM running Loki + Grafana, where alert
> rules fire on suspicious activity (escape attempts, docker.sock access,
> reverse shells, miners). This is the **detection layer** for the Model B
> threat in `design/security-model.md` — that doc is all prevention; this one
> watches whether prevention holds, and turns its §8 one-off audit probes into
> standing checks.

---

## 0. Status

| Item | State | Updated |
|---|---|---|
| Design agreed | ✅ this doc | 2026-08-04 |
| Tetragon installed on CIVO | ☐ not started | |
| BTF/kernel compat verified (`tetra status`) | ☐ | |
| Baseline noise measured (events/session/hour) | ☐ | |
| Redaction filters enabled | ☐ **gate for shipping any real data** | |
| OCI VM stood up (Loki+Grafana) | ☐ | |
| Shipper (Alloy) wired CIVO → OCI | ☐ | |
| Starter policies deployed | ☐ | |
| Alert rules live (docker.sock, userns) | ☐ | |
| Red-team validation passed (§7 step 4) | ☐ | |
| Legal/compliance sign-off for real users | ☐ **gate — see §6.3** | |
| Enforcement (Sigkill) considered | ☐ deliberately last | |

### Decision log

| Date | Decision | Why |
|---|---|---|
| 2026-08-04 | Tetragon over Falco | A customer already runs Tetragon — shared policy language with them; kernel-side filtering (lower overhead); enforcement path if we ever want it |
| 2026-08-04 | Loki + Grafana on one OCI VM, not a hosted service | Spike economics; Grafana alerting is sufficient; VictoriaLogs noted as lighter fallback if the VM strains |
| 2026-08-04 | Observe-only; no enforcement | Detection value is immediate; a false-positive `Sigkill` kills a customer session. Revisit only after weeks of clean data |
| 2026-08-06 | Sessions run **in-cluster** via the dev `kasm-kubernetes-operator` (`KasmWorkspace` CRD) — not external Docker agents | Corrects §5's assumption (public docs describe only the GA external-agent model). Tetragon's DaemonSet sees session pods natively, with real pod attribution — no standalone deployment needed for these sessions |

---

## 1. Why, and how it relates to the security model

`design/security-model.md` defines two threat models; its controls for
**Model B ("the user is hostile")** are preventive: seccomp deltas, AppArmor
userns scoping (§5.2), placement, host sysctls. None of them tell us whether a
tenant is *trying*. Tetragon closes that gap:

- **Visibility** — every `process_exec` in a session, with full ancestry and
  pod identity, answers "what are users doing in their sessions".
- **Detection** — TracingPolicies alert on the specific actions the security
  model worries about (userns creation, mount API, bpf, module load,
  docker.sock).
- **Verification** — the same events prove the preventive controls work.
  When §5.2's per-binary AppArmor scoping lands, the userns policy (§5.1 below)
  should show tenant shells failing `unshare` while the browser succeeds —
  continuously, not just during the §8 audit.

A secondary payoff: policies we write are directly usable by (and reviewable
against) the customer already running Tetragon.

## 2. Architecture

```
CIVO k8s cluster                                OCI VM ("obs-1", small shape)
┌────────────────────────────────┐              ┌────────────────────────────┐
│ node A: tetragon (DaemonSet)   │              │  Caddy/nginx  :443         │
│         └ /var/log/tetragon/   │   HTTPS      │   TLS + auth               │
│           tetragon.log         │  ─────────►  │      │                     │
│         alloy (DaemonSet)      │  loki push   │   Loki (monolithic,        │
│           tails + pushes       │              │    filesystem storage)     │
│ node B: (same)                 │              │      │                     │
│ ...                            │              │   Grafana ── alerts ──► Slack
└────────────────────────────────┘              └────────────────────────────┘
```

### 2.1 CIVO side

- **Tetragon v1.7.0** via Helm (`helm repo add cilium https://helm.cilium.io`,
  chart `cilium/tetragon`, namespace `kube-system`). CNI-agnostic — does not
  require Cilium.
- Kernel requirement: BTF-enabled (CIVO k3s nodes on Ubuntu ≥5.15 qualify).
  **Verify on day one** with `tetra status` and the DaemonSet logs; do not
  assume.
- Default output: `process_exec`/`process_exit` for everything. Additional
  hooks come from `TracingPolicy` CRDs (kprobes/tracepoints with in-kernel
  `matchBinaries`/`matchArgs` filtering, namespace/pod-label scoping).
- Export: JSON to `/var/log/tetragon/tetragon.log` per node (rotated). There
  is **no native remote push** — a shipper is required.

### 2.2 Shipper

Grafana Alloy DaemonSet (Vector is the alternative if we want heavier
transform logic in transit). Tails the tetragon log, pushes Loki-protocol over
HTTPS to the OCI VM. Tetragon events already embed pod/namespace/binary
metadata, so the shipper only adds `cluster` and `node` labels. Keep Loki
label cardinality low: label on `cluster`, `node`, `namespace`, event type;
everything else stays in the JSON body and is queried with LogQL json filters.

Volume control happens in **Tetragon**, not the shipper:

- **Export allowlist/denylist** (`tetragon.exportAllowList` / `DenyList` Helm
  values) — restrict to session namespaces/pods; drop kube-system chatter.
- **Field filters** — strip bulky fields we don't query (e.g. full env — we
  redact anyway, see §6.1).

### 2.3 OCI VM

- Shape: **A1.Flex 2 OCPU / 12 GB** preferred (Always Free envelope if the
  region has capacity — historically contested; fall back to **E4.Flex 1–2
  OCPU burstable**, already priced in the OCI runner sizing notes). 100–200 GB
  block volume.
- Stack: **Loki** (monolithic mode, filesystem storage, 14–30 d retention) +
  **Grafana** (dashboards + alert rules → Slack). No Alertmanager, no object
  storage, no Prometheus for the spike — Grafana alerting on LogQL is enough.
  Add Tetragon's Prometheus metrics later only if agent health becomes a
  question.
- Lighter fallback: **VictoriaLogs** speaks the Loki push protocol and uses a
  fraction of the memory; swap it in if Loki strains the shape.

### 2.4 Pipeline security (non-negotiable, spike or not)

- TLS on ingest (Caddy or nginx terminating :443, real cert via ACME).
- Auth on push: basic-auth token minimum; mTLS if cheap to wire in Alloy.
- OCI NSG: :443 open **only** to the CIVO cluster's egress IP(s); :22 only to
  admin IPs; nothing else listening publicly. Grafana behind the same proxy
  with its own auth (no anonymous access — see §6.3).
- Encrypted boot/block volumes (OCI default — keep it), no credentials baked
  into images or repo; the push token lives in a k8s Secret on CIVO and the
  proxy config on the VM only.
- The VM's own auth/audit logs retained — the monitoring system is itself an
  attractive target.

## 3. Detection policies — starter set

Priority-ordered. Each becomes one `TracingPolicy` + one Grafana alert rule.
The YAML below is the intended shape, **not yet validated against v1.7** —
check each against the upstream policy library
(<https://tetragon.io/docs/policy-library/observability/>) before deploying,
and record deviations here.

### 3.1 Userns / namespace-escape attempts — the §5.2 verifier

```yaml
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: kasm-detect-userns
spec:
  kprobes:
    - call: "create_user_ns"
      syscall: false
      selectors:
        - matchActions:
            - action: Post
```

Alert: any hit from a binary that is **not** the browser launcher path.
Once security-model §5.2 lands, this is the standing proof it works: tenant
`unshare -Ur` should appear here as an attempt *and* fail; browser hits are
expected baseline. Consider companions on `setns` and the `unshare` syscall.

### 3.2 Container-runtime reach-around

File-access kprobes (`security_file_permission` per the upstream
file-monitoring policy) on:

- `/var/run/docker.sock` — nothing in a session may touch this. Zero
  false-positive expectation; alert at highest severity.
- writes under `/dockerstartup/`, `/etc/container-init/` — immutable after
  boot in our images; a post-boot write is tampering.
- `nsenter` exec (cheap `matchBinaries` on the default exec events — may need
  no policy at all, just a LogQL rule).

### 3.3 Kernel-surface probing

Kprobes on `bpf`, `perf_event_open`, module-load paths. Our seccomp profiles
**block** these (security-model §2), so a hit means someone is *probing* —
attempt-level signal with near-zero legitimate baseline. High severity.

### 3.4 Reverse shells / suspicious egress

`tcp_connect` kprobe. Noise-prone — scope hard: alert on connects from
binaries outside an expected set (browsers, profile-sync, upload server,
squid), and/or shell binaries with socket ancestry. Expect several tuning
rounds; start as a dashboard panel, promote to alert once quiet.

### 3.5 Miners

Exec of known miner names (xmrig etc.) + `tcp_connect` to stratum-typical
ports (3333/4444/5555/14444). Cheap, decent signal on long-running sessions.

### 3.6 Privilege escalation

`sudo`/setuid execs after the boot phase. In container-init images, root is
PID 1 + setup units (security-model §3) — post-boot escalation by the session
user is anomalous. Needs a boot-window carve-out to avoid alerting on
`kasm-setup.service`.

### What we deliberately do NOT alert on (yet)

Raw exec volume, browsing behavior, file reads in `$HOME` — high noise, high
privacy cost, low security signal. Keep the alert set small and defensible.

## 4. Noise budget

An XFCE desktop is an exec-event firehose: shell completions, xdg helpers,
panel plugins, dbus spawns. **The filter tuning is the real work of this
spike; the install is an afternoon.** Method:

1. Measure raw: one idle session + one active session, events/hour, before
   any filtering. Record numbers here.
2. Apply export allowlists (session namespaces only) + field filters;
   re-measure.
3. Target: a number Loki on the small VM absorbs comfortably —
   O(10⁴–10⁵) events/session/hour raw is plausible; we want the shipped
   volume well under that. Fill in actuals: _raw = ?, filtered = ?_.

## 5. Deployment shapes

**Resolved 2026-08-06:** sessions run **in-cluster** as pods, launched by the
dev `kasm-kubernetes-operator` (repo: `gitlab/kasm-kubernetes-operator` —
`KasmWorkspace` CRD + `kasm-services` operators for image-pull/autoscale/
networks). The Tetragon DaemonSet therefore sees session pods natively with
full pod attribution; the plan's original assumption holds. Standalone
Tetragon (docker/systemd mode, same policies, container-label attribution)
remains the shape for any non-k8s Docker hosts we later put sessions on
(forge, GPU test host) — currently none planned.

Operator facts that matter to *this* doc (from source, corrected 2026-08-06 —
an earlier revision wrongly claimed no seccomp/AppArmor support; that was read
off the older standalone `KasmWorkspace` path on `main`). The repo carries two
generations:

- **Standalone `KasmWorkspace` operator** (`main`): `nodeSelector` yes /
  tolerations no; caps drop ALL by default (`capabilities.add` to grant);
  no seccomp on the workspace container.
- **`kasm-agent`** (dev branches `refactor/shared-manifest-builders`,
  `feature/DEV-228-k8s-agent-egress`) — the Kasm-managed-session path, and
  the one that matters going forward. It translates the registry `run_config`
  into the pod securityContext:
  - `security_opt seccomp=` → inline profile content-hashed (sha256) into a
    shared `kasm-seccomp-profiles` ConfigMap; a **seccomp-installer
    DaemonSet** mirrors keys onto every node as `<SECCOMP_DIR>/kasm/<hash>.json`;
    the pod gets `seccompProfile: {type: Localhost, localhostProfile: kasm/<hash>.json}`.
    Profiles are **pre-staged at heartbeat time** so first launch doesn't race
    the installer. So the per-workspace `chrome.json`/`bwrap.json` posture
    from `security-model.md` **does** carry to k8s sessions.
  - AppArmor: `build_apparmor_profile(run_config)` → `appArmorProfile` on the
    container context.
  - caps from run_config `cap_add`/`cap_drop`; `runAsUser: 0` (container-init
    compatible by design); `nodeSelector` built from the agent
    `include_labels` mechanism → node-pool targeting works via existing Kasm
    agent-label conventions.
- **Residual nuance to verify:** `build_seccomp_profile` returns nothing when
  the run_config has no `seccomp=` entry, so images *without* a custom profile
  fall through to the cluster default — **Unconfined** unless the kubelet sets
  `seccompDefault: true` (or the builder grows a RuntimeDefault fallback).
  Check the CIVO kubelet config; this decides whether Tetragon's §3.3
  kernel-surface hits mean "blocked attempt" or "open surface" for
  profile-less images. For images *with* tight profiles, §3.3 hits are
  attempts against a closed door — high-signal either way, but severity
  triage differs per workspace.

## 6. Data handling, privacy, access

### 6.1 Redaction — enabled before any real data ships

Session process args/env can carry `VNC_PW`, `KASM_API_JWT`, and whatever
users paste into terminals. Tetragon supports RE2 **redaction filters**
applied before export — enable from day one with patterns for at least:
`VNC_PW`, `KASM_API_*`, `password=`, `token=`, `Authorization:`, key-material
shapes. Prefer field-filtering env out entirely and redacting args. A
credential that reaches Loki is a rotation event, not a shrug.

### 6.2 Retention & minimization

14–30 d in Loki for the spike; alerts (the distilled signal) can persist
longer than raw events. Don't ship fields we have no query for.

### 6.3 Legal/compliance gate

This is user-activity monitoring. Before it observes anyone beyond ourselves
driving test sessions, Kasm legal/compliance signs off on: what is collected,
retention, who can query Grafana (named individuals, audited), and what is
disclosed to session users. Engineering keeps the spike on our own sessions
until that lands. (Status table tracks this as a hard gate.)

## 7. Spike sequence

1. **Install & look.** Helm-install with defaults; `tetra getevents -o compact
   --pods <session-pod>` while driving a session. Verify BTF/kernel compat.
   Outcome: gut feel for signal-to-noise, §4 raw numbers.
2. **Filter & redact.** Export allowlists, field filters, redaction filters.
   Re-measure. Outcome: §4 filtered numbers; redaction verified by grepping
   export for a known-planted fake secret.
3. **Stand up OCI VM.** Caddy + Loki + Grafana (compose or plain systemd
   units); NSG per §2.4; Alloy DaemonSet on CIVO pushing. Outcome: session
   events queryable in Grafana.
4. **Policies & alerts.** Deploy §3.1–§3.3 + alert rules (docker.sock and
   userns first — near-zero false positives). Then **red-team from inside a
   session**: `unshare -Ur true`, an `nc` reverse shell, `curl | bash`,
   `ls -la /var/run/docker.sock`. Every probe must alert; record the matrix
   here. This doubles as security-model §8 audit evidence.
5. **Soak.** Run against team sessions for 2–4 weeks; tune §3.4; log false
   positives in the Decision log.
6. **Then, maybe:** enforcement (`Sigkill` on docker.sock open?), standalone
   Tetragon on Docker agent hosts, Tetragon metrics → health dashboard.

## 8. Open questions

1. ~~Where do sessions actually run today?~~ **Answered 2026-08-06:**
   in-cluster on CIVO via the dev kasm-kubernetes-operator (§5).
2. A1.Flex capacity in-region — or straight to E4.Flex burstable?
3. Alert destination — Slack channel name / routing conventions?
4. Does the customer running Tetragon want to compare policy sets? (Their
   policies may already encode lessons about desktop-workspace noise.)
5. k3s specifics: containerd socket path and kernel version on current CIVO
   node image — confirm Tetragon's process-metadata enrichment works there
   (it should; verify, don't assume).

---

*Update discipline: every deployed change lands in the Status table; every
"we chose X over Y" lands in the Decision log with the why. Numbers beat
adjectives — fill in §4.*
