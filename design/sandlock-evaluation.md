# SandLock for Kasm workspaces — evaluation

Investigating <https://github.com/multikernel/sandlock> against two proposals:

1. run SandLock **inside** the existing Nix workspace container;
2. make it a **new runtime tier** — the k8s operator launches "sandlocked
   workspaces" instead of containers, à la
   [ch-operator](https://github.com/nalajala4naresh/ch-operator) launching
   cloud-hypervisor microVMs — and ultimately picks per workload between
   sandlock / container / microVM.

**Bottom line:** proposal 2 is the right *architectural instinct* but the wrong
*mechanism*, and Kubernetes already has the abstraction it needs (`RuntimeClass`) —
no new operator required. SandLock cannot host a Kasm desktop without losing
capabilities the catalogue depends on, and the latency/memory wins it advertises do
not materialise at our workload shape. There is one narrow, genuinely strong fit
(proposal 1, aimed at the **session agent** rather than the desktop) and one
speculative-but-interesting angle unique to our Nix store model. Details below.

Facts verified 2026-08-12: Apache-2.0, v0.8.6, repo created 2026-03-13, active
(pushed 2026-08-11), 344 stars / 20 open issues. Pre-1.0, ~5 months old.

---

## 1. What SandLock actually is

A **process** sandbox. It confines a process tree with three kernel features and
nothing else:

| mechanism | does |
|---|---|
| **Landlock** (ABI v6, Linux 6.12+) | filesystem, network and IPC access control |
| **seccomp-bpf** | syscall filtering / denylists |
| **seccomp user notification** | runtime policy decisions, memory + process caps, `/proc` virtualisation |

Plus a copy-on-write staging layer, a `policy_fn` callback for per-syscall verdicts,
and HTTP-level ACLs with optional HTTPS MITM (`--http-allow "POST api.openai.com/v1/*"`).
Ships `sandlock-cli`, Rust/Python/Go SDKs, and `sandlock-oci`, an OCI runtime shim.

Stated targets: **AI agents, FaaS, untrusted code execution** — "the lightest AI
sandbox".

### What it is not

From `sandlock-oci`'s own documentation:

- **"Namespaces: ignored by design. The runtime is namespace-less by architecture."**
- **cgroups: not used.**
- mount types with no namespace-less equivalent — `devpts`, `mqueue`, `cgroup`,
  `cgroup2` — are **skipped**.
- **"`exec` is non-TTY only … there is no PTY support yet."**
- The OCI spec is "translated by intent rather than replaying Linux primitives".

It is not a VM, not a namespace/image runtime, and not a drop-in runc. It is a
*policy layer over host processes*. Our kernels are fine for it: forge and the GPU
test box are both on 7.0.0.

---

## 2. Why it cannot host a Kasm desktop (yet)

Five structural mismatches, in descending order of how hard they are to fix.

### 2.1 Our workloads are themselves sandbox users — this is the big one

A Kasm workspace's payload is a browser or an FHS-wrapped desktop app, and those
build their own sandboxes:

- Chromium/Electron need `clone`/`clone3`/`unshare`/`setns` to make a user namespace
  for the zygote — this is exactly what `processing/runconfigs/runConfig.chrome.json`
  in the registry exists to *permit*.
- `buildFHSEnv` apps (OnlyOffice, Steam, and everything that launches via
  `nix-bwrap-run`) need the whole mount family — `mount`, `umount2`, `pivot_root`,
  `move_mount`, `open_tree`, `fsopen`… — which is what `runConfig.bwrap.json` permits.
  Without them bwrap dies with `bwrap: Failed to make / slave: Operation not permitted`
  (already in our notes).

So the direction of travel is opposite. Our per-app run configs exist to *loosen*
seccomp so the apps can sandbox themselves; SandLock's value is *tightening* it. And
because it is namespace-less, `pivot_root`/`mount` cannot work in the first place —
there is no mount namespace to pivot within. **Every bwrap/FHS app in the catalogue
is a hard blocker, not a tuning problem.**

### 2.2 No PID namespace vs `container-init`

Our supervisor is PID 1 by design: it resolves the unit graph, reaps zombies with a
dedicated `wait4(-1)` loop, and forwards SIGTERM in reverse dependency order.
`sandlock-oci` supplies its **own** `sandlock-init` as PID 1 so the workload and all
`exec`s share one seccomp supervisor. Two inits, and "PID 1" without a PID namespace
is nominal — orphan reaping semantics we rely on do not hold.

### 2.3 No PTYs

`devpts` is skipped and PTY support is explicitly absent. A Kasm desktop ships a
terminal emulator; the OSINT and dev images are largely *about* terminals. A desktop
where no terminal can allocate a PTY is not shippable.

### 2.4 No network namespace → no per-workspace IP

Kasm's model gives each workspace its own address and proxies to `:6901`. SandLock
offers TCP allowlists and port remapping on the **host** network stack, not an
interface. Every session on a node would contend for host ports, and workspace↔workspace
network isolation gets weaker, not stronger.

### 2.5 Threat model runs the wrong way

Kasm's product *is* running code the user controls — that is the hostile-insider case.
Landlock + seccomp on a shared kernel, with no user-namespace/UID separation, is a
weaker boundary than our current container (userns + seccomp + AppArmor), let alone a
microVM. SandLock is excellent at confining code **you** author and deploy; it is not
positioned as a multi-tenant boundary for adversarial interactive sessions. That cuts
against the direction of the security-model work and the Tetragon detection layer.

---

## 3. Where it *is* a strong fit: the session agent

The one place SandLock's design centre matches ours exactly is
[`kasm-session-agent`](../../kasm-nix/) — an in-session agent taking model-driven
actions inside a workspace. That is literally SandLock's headline use case, and the
threat it addresses (prompt injection → exfiltration or local damage) is real for us:

- `--http-allow "POST api.anthropic.com/v1/*"` confines the agent's egress at the
  request level, not just by host;
- `policy_fn` can deny `execve` of specific tools, or `connect` to specific hosts, at
  runtime;
- credential injection keeps API keys out of the agent's own filesystem view;
- the agent is *our* code running *our* tools — cooperative, non-namespace-hungry, and
  therefore not blocked by any of §2.

This is proposal 1, but pointed at the agent instead of the desktop, and it is the
only piece I would spike in the near term. Note it does **not** need the OCI shim —
just `sandlock-cli` or the Python SDK around the agent's tool execution.

Everything else about proposal 1 ("run it in the existing nix container") I would
skip: the desktop's processes are the ones that need permissive syscalls, we already
apply seccomp + AppArmor at the container boundary, and adding a second, stricter
policy layer inside is most likely to manifest as apps that mysteriously stop working.

---

## 4. Proposal 2: pluggable isolation per workload

The instinct — *let each workspace choose its isolation tier* — is sound, and worth
pursuing. Three corrections to how.

### 4.1 Kubernetes already models this: `RuntimeClass`

Per-pod runtime selection is a built-in: `runtimeClassName: runc | kata-qemu | kata-clh
| sandlock`. SandLock ships an OCI shim precisely so it can be wired this way. The
work is then *plumbing, not architecture*:

- register the runtime handler on the nodes (containerd config);
- let a workspace definition carry a runtime choice — our registry `run_config`
  already carries per-app `seccomp`/`apparmor` today, so this is the same shape;
- have the Kasm k8s operator pass it through as `runtimeClassName`.

That gets "different isolation mechanism per Kasm workload" without a new control
plane. It is also incrementally testable: one RuntimeClass, one workspace, no
migration.

### 4.2 For the microVM tier, prefer Kata over a bespoke CH operator

ch-operator is a **custom controller** with `VirtualMachine` / `VMSnapshot` /
`VMPool` CRDs, a per-node daemon and a per-pod pre-runner — i.e. owning a VM control
plane. Its own README says it "is still a work in progress, its API may change
without prior notice", and it targets k8s v1.35+.

Kata Containers reaches the same place through `RuntimeClass`, keeps OCI images and
pod semantics, and has a **cloud-hypervisor** backend already (`kata-clh`). If the
goal is microVM-isolated workspaces, that is the cheaper and far better-supported
path, and it composes with §4.1 instead of competing with it. ch-operator is worth
reading for its snapshot/pool ideas (VM templating for fast start is genuinely
interesting for workspace warm pools) — not as a template to clone.

### 4.3 The advertised wins do not materialise at our shape

This is the part I would push back on hardest before anyone invests:

- **Startup latency.** The 5–7 ms vs Docker's 307 ms figure is `/bin/echo`. Kasm
  workspace start is dominated by image pull/mount plus bringing up Xvnc, the window
  manager, audio and the app — seconds at best, and for the Nix images gigabytes of
  store. Saving 300 ms of runtime setup is inside the noise. (Our own
  `CONTAINER_INIT_TRACE` boot traces already show where the time actually goes; that
  is the profile to optimise against.)
- **Memory overhead.** Removing image and cgroup overhead is real but small next to a
  desktop plus browser (hundreds of MB to GB). The zswap/compressed-memory density
  experiment is a much larger lever on the same problem.

Both claims are true for FaaS and agent workloads. Neither is where a workspace's
cost lives. If density and start latency are the actual goals, they are better
attacked directly — warm pools, store-on-node, memory compression.

---

## 5. The one angle unique to us

SandLock has no image concept: it confines processes over the **host** filesystem
with Landlock rules. Almost every container platform finds that awkward — but our Nix
model is unusually close to it already:

- apps are content-addressed closures under `/nix/store`;
- the fat store is mounted onto the node rather than baked per app;
- `nix-activate` selects which app to run at launch from `launch_selections.json`.

A node that already has the fat store on disk could, in principle, run an app's
closure directly under Landlock confinement with **no container image at all** — the
"sandlocked workspace" idea in its strongest form, and only available to us because
of the store model. It still runs into §2.1–2.4 (bwrap apps, PTYs, per-session
networking), so it is a research direction rather than a plan; but it is the one
version of proposal 2 that would be more than a re-skin of what containers already
do, and it is worth keeping in mind as the store-on-node work matures.

---

## 6. Recommendation

1. **Do not rebuild the workspace runtime around SandLock.** The blockers in §2.1–2.3
   are structural, and it is pre-1.0 (v0.8.6, 5 months old) for a component that
   would be a security boundary.
2. **Spike SandLock around the session agent** (§3). Small, self-contained, real
   threat model, no dependency on the OCI shim.
3. **If per-workload isolation is the goal, build it as `RuntimeClass` plumbing**
   (§4.1): workspace definition → operator → `runtimeClassName`. That is the
   deliverable the second proposal is really asking for, and SandLock can be *one*
   registered handler later without committing to it now.
4. **Evaluate `kata-clh` for the microVM tier** before considering a CH operator
   (§4.2).

### The one-day experiment that would settle §2 with evidence

Rather than argue from documentation, run it on forge (kernel 7.0.0, so Landlock v6
is available):

```bash
# 1. build the shim
cargo install --path crates/sandlock-cli   # + sandlock-oci

# 2. register it as a containerd runtime handler, then try, in order:
#    a) a trivial app image  (expect: works)
#    b) chrome:nix           (expect: zygote may work; watch for clone/unshare denials)
#    c) only-office:nix      (expect: FAILS — bwrap needs mount/pivot_root, and there
#                             is no mount namespace to pivot in)
#    d) any image, then open a terminal in the desktop  (expect: FAILS — no PTY)
```

Outcomes (b)–(d) are the decision. If (c) and (d) fail as predicted, SandLock is
ruled out as a workspace runtime for the current catalogue and the conversation moves
to §3/§4. If they somehow pass, this document is wrong in an interesting way and
worth revisiting.

## 7. Open questions

- Does a Landlock+seccomp-confined process retain the ability to create user
  namespaces (Chromium zygote)? Documentation does not say; test (b) answers it.
- Multi-tenant story: is there any UID/user-namespace separation between two
  sandboxes on one node, or only Landlock path rules?
- `--http-inject-ca` implies HTTPS MITM. Attractive for an agent; needs a policy
  decision before it touches anything user-facing.
- ~~What kernel do the CIVO k3s nodes run?~~ **Answered 2026-08-12:** Alpine 3.22,
  kernel **6.12.85**, so Landlock ABI v6 *is* available there. forge and the GPU box
  are on 7.0.0. Kernel version is not a blocker for SandLock on any host we run.
