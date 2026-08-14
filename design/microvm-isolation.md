# MicroVM isolation for Nix workspaces on Kubernetes

Can a Nix workspace run in a microVM instead of a container, for a stronger boundary
than namespaces + seccomp? Assessed against
[cloud-hypervisor](https://github.com/cloud-hypervisor/cloud-hypervisor) and
[ch-operator](https://github.com/nalajala4naresh/ch-operator).

**Verdict — tested, not argued.** It works, and it costs less than expected in the place
we feared and more in a place we hadn't measured:

- **Feasible today.** A workspace image runs **unmodified** in a cloud-hypervisor microVM:
  KasmVNC serves, `container-init` is PID 1 in the guest, bwrap/FHS apps work — better
  than in a container on an Ubuntu 26.04 host (§6a).
- **Memory is a non-issue.** ~175 MB/sandbox + ~33 MB per GB assigned; a matched desktop
  measured 790 MB (kata) vs 754 MB (runc), ≈**5%** (§6a).
- **Startup is the binding constraint.** ~400 ms under runc vs ~1100 ms under kata —
  **+700 ms, ≈2.7×** — and Kata's VM templating cannot fix it because templating is
  incompatible with virtio-fs (§6b). Fixable only by *pre-paying* the cost with warm pools.
- **Shared GPU for _graphics_ rules out every stronger-isolation option.** Not compute —
  graphics. clh has no virtio-gpu, VFIO is 1:1, and gVisor's `nvproxy` explicitly lacks
  `/dev/nvidia-drm`/`modeset`, so WebGL in a browser does not work under any of them (§5.1).
- **Blocked on the CIVO nodes regardless**, which expose no KVM at all (§1).

**Therefore the recommended posture is to wait — deliberately, not passively.** The one
architecture that would give a hardware boundary *and* a shared GPU for graphics is
**virtio-gpu with a host-side renderer (virglrenderer for GL, venus for Vulkan)** — QEMU's
`virtio-gpu-gl` and **libkrun**. Neither is adoptable for us yet. Everything else we need
already works. So: ship the cheap, runtime-agnostic `runtimeClassName` plumbing now, offer
the microVM tier to software-rendered workspaces where it already works, and track
virtio-gpu/venus maturity for the GPU case (§5.1a). Software path remains Kata + `clh` via
`RuntimeClass`, not a bespoke VM operator (§3).

---

## 1. The infrastructure gate — measured, 2026-08-12

Kata's own installation docs: *"Kata Containers requires nested virtualization or
bare metal."* So the first question is not software, it is whether our nodes can host
a VM at all.

| host | `/dev/kvm` | `vmx`/`svm` | `hypervisor` flag | verdict |
|---|---|---|---|---|
| CIVO k3s ×3 (`g4m.kube.medium`) | **NO** | **absent** | present | **cannot run microVMs** |
| forge (`51.195.190.65`) | YES (`root:kvm`) | `vmx` | absent → bare metal | can |
| gpu-test (`192.168.1.140`) | YES | `vmx` | absent → bare metal | can |

The CIVO nodes are themselves guests (`hypervisor` flag set, Intel Xeon Icelake,
~30 GB RAM each) with no `kvm` modules loaded and no virtualisation CPU flag exposed.
That rules out **every** VMM — cloud-hypervisor, QEMU, Firecracker — not just one
choice. Cluster detail for the record: k3s 1.36.0, **Alpine Linux v3.22**, kernel
6.12.85, containerd 2.2.3-k3s1, flannel.

So any microVM plan needs an infrastructure decision first:

- run workspace nodes on **bare metal** (forge and the GPU box already qualify, and
  are where a PoC belongs), or
- move to a provider/shape that exposes nested virtualisation, or
- keep containers on CIVO and treat microVMs as a separate, higher-assurance pool.

Everything below is contingent on that.

---

## 2. Why this is a much better fit than SandLock

The comparison is instructive, because the two proposals fail and succeed for exactly
opposite reasons.

Kata mounts the OCI bundle into the guest over **virtio-fs**, and then — per its
architecture docs — *"Linux cgroups and namespaces are created inside the VM by the
guest kernel to isolate the workload from the VM environment"*. The consequence is
the whole argument:

| our requirement | SandLock (namespace-less) | Kata + microVM |
|---|---|---|
| `container-init` as PID 1, `wait4(-1)` reaping | broken (no PID ns; its own init) | **works** — real PID namespace in the guest |
| Chromium zygote (`clone`/`unshare`/`setns`) | uncertain, and against the grain | **works** — normal userns inside the guest |
| bwrap/FHS apps (`mount`, `pivot_root`) — OnlyOffice, Steam | **impossible** (no mount ns) | **works** — real mount namespace |
| PTYs (terminals in the desktop) | absent | **works** |
| per-workspace network identity | host ports only | **works** — pod networking, own IP |
| our images | would need rebuilding around a new model | **unmodified** |

A microVM *adds* a boundary underneath the container without removing any capability
the container gives us. That is the property that makes it worth taking seriously:
the migration is a runtime-selection change, not an image-architecture change.

The isolation gain is real too: a container escape has to get through the guest
kernel and then the VMM, and cloud-hypervisor is a small Rust VMM with a deliberately
narrow device model. For the security model work — where the threat is a hostile user
inside a workspace — that is the strongest boundary on the table.

---

## 3. Kata + `clh`, not ch-operator

| | ch-operator | Kata Containers (`kata-clh`) |
|---|---|---|
| model | custom controller + CRDs (`VirtualMachine`, `VMSnapshot`, `VMPool`, `VMSet`), cluster controller + per-node daemon + per-pod pre-runner | `RuntimeClass` handler; pods stay pods |
| our images | rootfs conversion / DataVolumes (CDI) | OCI bundle over virtio-fs, **unchanged** |
| Kasm operator integration | new object model to teach it | set `runtimeClassName` on the pod it already creates |
| `kubectl exec` / session teardown | VM semantics, different path | normal container exec (agent in guest) |
| maturity | *"still a work in progress, its API may change without prior notice"*, targets k8s v1.35+ | CNCF project, shipped for years, `kata-deploy` Helm chart |

ch-operator is worth reading for two ideas we would eventually want — **VM snapshots
and VM pools**, i.e. templating a booted workspace and cloning it for fast start —
but adopting it means owning a VM control plane, and cloud-hypervisor explicitly does
*not* guarantee snapshot/restore across versions, so that capability is not free
there either.

The cheap path is the one already sketched in `sandlock-evaluation.md` §4.1: teach the
workspace definition to carry a runtime tier, have the operator pass it through as
`runtimeClassName`, and register handlers on the nodes. Our registry `run_config`
already carries per-app `seccomp`/`apparmor`, so *per-workspace isolation tier* is
the same shape of change — `chrome` on `runc`, `tracelabs-osint` on `kata-clh`.

---

## 4. The angle that is specific to us: the fat store over virtio-fs + DAX

Kata supports DAX for both QEMU and cloud-hypervisor (the `dax` FsConfig option),
which maps a shared filesystem into the guest so pages come from the **host** page
cache rather than being copied per guest.

Our architecture is unusually well suited to that:

- the Nix store is **read-only and content-addressed** — the ideal shared mount;
- the fat store already exists as a single ~29 GB artifact that we deliberately share
  across apps by digest;
- `nix-activate` already selects apps at launch from a store mounted into the
  workspace, rather than baking per-app rootfs.

So the interesting shape is: **one read-only `/nix` on the node, shared into every
workspace microVM via virtio-fs with DAX**, with each VM's writable layer being only
its profile and `/tmp`. That recovers most of the page-cache sharing a container gets
for free, which is normally the biggest density argument *against* microVMs. It is
also the same direction as the store-on-node work, not a detour from it.

> **Measured since (§6a):** enabling it (`virtio_fs_cache_size`) stops the clh VM booting,
> and memory turned out to be ≈5% *without* it — so this is a worthwhile optimisation for
> many-workspaces-per-node, not the deciding factor it is framed as above. It also
> conflicts with VM templating (§6b), which is the one thing that would fix startup, so
> the two levers we most want are currently mutually exclusive.

---

## 5. Costs and hard limits

### 5.1 GPU graphics — the blocker that closes the whole option space

Precisely: the problem is **shared GPU for _graphics_** (WebGL, the browser compositor,
VirtualGL). Not compute. Every stronger-isolation option fails at it, for a different
reason:

| approach | shared GPU *graphics*? | why |
|---|---|---|
| `runc` + namespaces (today) | **yes** | `/dev/dri` shared across sessions |
| kata + cloud-hypervisor | no | no virtio-gpu in its device model — the docs dir carries only `device_model.md`, `vfio.md`, `vfio-user.md` |
| VFIO passthrough | no | one physical GPU, one VM |
| gVisor + `nvproxy` | no | `/dev/nvidia-drm` and `/dev/nvidia-modeset` are **unsupported** |
| SandLock | no | and it breaks bwrap regardless (`sandlock-evaluation.md` §2.1) |

The gVisor case is worth stating exactly, because "gVisor has GPU support now" is true
and misleading. `nvproxy` **does** support CUDA, **Vulkan** and NVENC/NVDEC — but its
docs list `/dev/nvidia-drm` ("plugs into Linux's Direct Rendering Manager subsystem")
and `/dev/nvidia-modeset` as unsupported, and `ioctl` is allowlisted. Our render path is
GL/EGL → DRI → `nvidia-drm`, so headless Vulkan would work and **WebGL in a browser
would not**. Say "no DRM/modeset", not "no graphics" — the distinction matters if anyone
later wants offscreen Vulkan.

Consequence: an isolation tier is available for **software-rendered** workspaces, and
GPU-accelerated ones stay on `runc` + namespaces + seccomp/AppArmor with the detection
layer carrying the load. That is not a defeat for the *pluggable tier* framing (§3) —
it defines its scope. Worth checking against the catalogue before deciding how much it
costs us: Chrome/Chromium and the CEF/Electron apps need GPU graphics; much of the OSINT
and terminal-heavy set may not, and those are plausibly where a stronger boundary is
wanted anyway.

### 5.1a The thing actually worth waiting for: virtio-gpu + virglrenderer/venus

There is exactly one architecture that would give **both** a hardware isolation boundary
and a **shared** GPU for graphics: **virtio-gpu with a host-side renderer** —
`virglrenderer` for GL, **venus** for Vulkan. The guest gets a real DRI device; the host
renderer multiplexes one physical GPU across many guests. That is the property VFIO
cannot provide and `nvproxy` explicitly does not.

Where it exists today:

- **QEMU `virtio-gpu-gl`** — the mature-ish implementation, but it is built for desktop
  virtualisation, and pairing it with Kata's container flow is not a supported path.
- **libkrun** — carries virtio-gpu with venus, and its model is unusually well-suited to
  us: the workload *starts as a container and self-constructs a KVM around itself*, so it
  pays container-like startup (see §6b, where startup is the binding constraint) while
  still landing behind a hardware boundary. It is what MicroSandbox is built on.

**This is probably the right answer, and it is not ready.** The honest strategic
position: our stack has one requirement — many workspaces sharing one GPU for graphics —
that the microVM ecosystem is actively building toward and has not delivered in a form we
can adopt. Everything else we need already works (§6a: images unmodified, `container-init`
as PID 1, bwrap functional, ~5% memory). So the recommendation is **not** "microVMs don't
suit us"; it is:

1. ship the *mechanism* now, cheaply — the `runtimeClassName` plumbing (§3), which costs
   ~20 lines in `provisioner.py` and is useful regardless of which runtime wins;
2. offer the microVM tier to **software-rendered** workspaces where it already works;
3. **track virtio-gpu/venus maturity** (libkrun first, then Kata's virtio-gpu work) and
   revisit for GPU workspaces when a shared-graphics path lands. When it does, the
   catalogue is already runtime-selectable and nothing needs re-architecting.

Watch items: libkrun's venus support reaching a container runtime we can drive from
containerd; virtio-gpu support appearing in cloud-hypervisor's device model; Kata gaining
a supported virtio-gpu configuration. None of those is our work — which is exactly why
waiting, rather than building around the gap, is the cheap play.

### 5.2 Memory and density

Each microVM carries its own guest kernel and page tables. **Measured** (§6a): ~175 MB
per sandbox plus ~33 MB per GB of assigned guest RAM, which came out at ~5% on a matched
desktop — real, but far smaller than the first pass suggested, and small enough that it
does not by itself rule the approach out on a 30 GB node.

The sharp edge is not the microVM, it is **over-assignment**: you pay ~3% of the guest's
RAM ceiling whether the workspace uses it or not, where a container simply takes what it
needs. Size guests from container limits and rely on hotplug.

### 5.3 Operational friction

- **Alpine hosts.** The CIVO nodes are Alpine/musl. `kata-deploy` ships host binaries
  and a guest kernel/image; a musl host is not the well-trodden path. Moot while
  CIVO has no KVM, but it lands the moment the node question is reopened.
- **k3s containerd config.** Registering a runtime handler means managing k3s's
  containerd config template, which is a node-level change, not a manifest.
- **Snapshot/restore is not a stable interface** in cloud-hypervisor, so warm-pool
  tricks built on it would be version-pinned.

---

## 6. What it does *not* fix

Worth stating plainly, because "microVM" reads as a security answer to everything:

- it does not change the **in-workspace** picture — the user is still root-ish inside
  their own sandbox, and the per-app seccomp/AppArmor profiles still matter;
- it does not remove the need for the detection layer (Tetragon) — a stronger boundary
  reduces escape impact, it does not tell you what the session did;
- it **costs** start latency, and materially — see §6b. An earlier draft of this document
  claimed the opposite ("start is dominated by bringing up Xvnc + desktop + app, not by
  runtime setup"). That was wrong, and wrong in the direction that matters.

---

## 6a. PoC RESULT — it works, measured on forge 2026-08-12

Kata 4.0.0 static + bundled cloud-hypervisor, `/etc/kata-containers/configuration.toml`
= `configuration-clh.toml` (4 vCPU / 6144 MB), shim symlinked into `/usr/local/bin` so
**no containerd restart was needed**. `kata-runtime check`: *"System can currently
create Kata Containers"*.

**Workspace images run unmodified.** `kasm-core-ubuntu-resolute:nix` under
`--runtime io.containerd.kata.v2`:

- KasmVNC served: **401** unauthenticated, **200** authenticated — same as runc.
- guest kernel **6.18.35** (kata's own, host is 7.0.0) — a real VM.
- **PID 1 in the guest is `container-init`** — our supervisor works untouched. This was
  the central prediction in §2 and it holds.

**bwrap/FHS works — and, unexpectedly, works *better* than the container.**
`only-office:nix` under kata ran `bwrap` + `DesktopEditors` fine. The same image under
**runc on the same host failed**:

```
bwrap: No permissions to create a new namespace, likely because the kernel does
not allow non-privileged user namespaces
```

Cause: the host is Ubuntu 26.04 with `kernel.apparmor_restrict_unprivileged_userns = 1`;
inside the guest that sysctl does not exist. So the microVM **decouples the workload
from the host's AppArmor userns policy**. Our CIVO nodes are Alpine and unaffected, but
this is a concrete portability argument: on any Ubuntu 24.04+ host, FHS apps hit this in
a container and do not in a microVM.

### Measured memory overhead

> **Corrected.** A first pass reported "~370 MB fixed, desktop ≈2×". That was a
> measurement artifact: the floor test inherited the `default_memory = 6144` I had set
> for the desktop, so even `busybox sleep` got a 6 GB VM — and a guest kernel's baseline
> scales with *assigned* RAM. It also used RSS, which double-counts shared pages. The
> numbers below use PSS and matched sizing. The corrected conclusion is materially
> different and much closer to published figures.

**Methodology.** Two traps: the VMM lives **outside the container cgroup** (the kata
container's own cgroup reported 209 MB for a VM using ~1.5 GB, so cgroup accounting
alone is useless for kata), and RSS double-counts shared mappings. So: kata measured as
PSS summed over `cloud-hypervisor` + `virtiofsd` + shim per sandbox; runc from the
container cgroup, reported split into anon and file cache so the cache is visible on
both sides rather than hidden on one.

**Overhead scales with assigned guest RAM** — `busybox sleep`, one vCPU:

| assigned guest RAM | clh PSS | virtiofsd | shim | total |
|---|---|---|---|---|
| 512 MB | 129 | 4 | 42 | **175 MB** |
| 1024 MB | 140 | 4 | 43 | **187 MB** |
| 2048 MB | 160 | 4 | 42 | **206 MB** |
| 6144 MB | 316 | 4 | 42 | **362 MB** |

≈ **175 MB floor + ~33 MB per GB assigned** (consistent with guest `struct page` and
page-table overhead at ~2–3% of RAM). Against a container's ~3 MB. Note the shim is a
flat ~42 MB Go process — published microVM figures usually quote the VMM alone, which is
why "80–100 MB" and our 129 MB at 512 MB guest are the same ballpark.

**Matched sizing, real workload** — resolute desktop, 2048 MB / 2 vCPU, both serving
HTTP 200:

| | memory |
|---|---|
| kata | **790 MB PSS** (clh 485 + virtiofsd 264 + shim 41) |
| runc | **754 MB** (anon 165 + file cache 551) |
| delta | **+36 MB, ≈5%** |

So at honest sizing a microVM workspace costs **about the same as the container**. The
irreducible difference is the floor (~175 MB + ~33 MB/GB) — roughly **20–25% on top of a
desktop's own footprint**, not the 2× first reported. Most of both totals is reclaimable
cache, which is why over-assigning guest RAM is the thing to avoid: you pay ~3% of the
ceiling whether the workspace uses it or not.

Practical consequence: **do not pre-assign large guests.** Size from the container's
limits and let cloud-hypervisor hotplug memory on demand, rather than handing every
workspace 6 GB up front.

### DAX did not work out of the box

Setting `virtio_fs_cache_size = 2048` made the VM fail to boot (container stuck in
`Created`, shim cleanup, network teardown warnings). Reverted to `0`. So the shared-store
lever in §4 is **not a free toggle** on clh 4.0.0. It is now an *optimisation* rather than
a dependency: with memory measuring ≈5% at matched sizing, nothing rests on DAX. It would
still be worth having — virtiofsd was 264 MB of the 790 MB, and that is per-VM duplication
DAX should collapse across many workspaces on one node — but §4's framing of it as the
thing that decides "tolerable or hopeless" was overstated.

---

## 6b. Startup latency — the binding constraint (measured 2026-08-12)

This is where the real cost is, and where an earlier draft of this document was simply
wrong. It asserted that workspace start is dominated by the workload, so runtime overhead
is noise. Measured on `kasm-core-ubuntu-resolute:nix`, three runs each, forge (Xeon
E-2136), time from `nerdctl run` to KasmVNC answering HTTP:

| runtime | run → KasmVNC | sandbox floor (`busybox true`) |
|---|---|---|
| **runc** | **407 / 398 / 409 ms** | 413 / 369 / 385 ms |
| kata + cloud-hypervisor | 1114 / 1098 / 1137 ms | 954 / 884 / 898 ms |
| kata + qemu | 1307 / 1359 / 1303 ms | 1007 / 1073 / 1052 ms |

Two readings:

1. **The workload is no longer the bottleneck.** The runc *floor* is ~385 ms and the full
   workspace is ~400 ms — the desktop adds only ~20–30 ms over bare container creation.
   Startup optimisation work has already moved the cost onto the runtime, so runtime
   overhead is not noise, it is ~95% of the budget.
2. **A microVM costs +700 ms, ≈2.7×**, of which ~520 ms is VM creation. On a 400 ms
   baseline that is not a rounding error, it is the difference between "instant" and
   "visible wait".

### VM templating cannot fix it (with virtio-fs)

Kata's VM templating — pre-boot a template, clone per sandbox — is the textbook answer.
It is **qemu-only** (absent from the clh config), and enabling it fails outright:

```
VM templating has been enabled with virtio-fs and this configuration will not work
```

Templating is incompatible with virtio-fs, which is *how the OCI bundle reaches the
guest*. So templating means a devmapper block rootfs — and with it the shared-store/DAX
angle (§4) that made microVMs architecturally interesting for us. Qemu without effective
templating is worse than clh anyway (1307 vs 1098 ms).

### So how could ~400 ms and stronger isolation coexist?

- **Warm pools** — don't reduce the 700 ms, *pre-pay* it. A pool of booted, unassigned
  sandboxes takes VM creation off the request path entirely. Orchestration work, not
  runtime work; it is what ch-operator's `VMPool` is for. **The practical answer today.**
- **libkrun** — starts as a container and self-virtualises, so it pays container-like
  startup for a hardware boundary. Also the venus/virtio-gpu candidate (§5.1a). The most
  interesting option on both axes at once.
- **gVisor** — no guest kernel to boot, so structurally the closest to container startup.
  **Untested:** `runsc` installed fine (release-20260803.0) but the shim hung on
  `busybox true` — containerd needs explicit shim options for it, unlike kata's
  self-configuring shim. Not ruled out; ruled *unmeasured*. Note §5.1 rules it out for
  GPU graphics regardless.

### What this changes

§2's feasibility argument is now evidence. §5.2's memory cost is quantified and small.
The decision has moved off feasibility and onto two things: **startup** (fixable by
pre-paying, per above) and **shared GPU graphics** (not fixable today, §5.1a).

---

## 7. PoC — done. What is left, and in what order

The PoC this section originally proposed has been executed (§6a, §6b). Kata 4.0.0 is
installed on **forge** (`/opt/kata`, config `clh` @ 2048 MB / 2 vCPU, DAX off, shim
symlinked into `/usr/local/bin` so no containerd restart is needed), with
`kasm-core-ubuntu-resolute:nix` and `only-office:nix` pulled — so any of this is
repeatable without setup.

What remains, cheapest and most useful first:

1. **`runtimeClassName` plumbing** (~20 lines + test in `kasm-agent/agent/provisioner.py`,
   mirroring `build_apparmor_profile`). Do this **regardless of the microVM decision** —
   it is runtime-agnostic, it is what lets a workspace choose *any* tier, and the
   CRIU/checkpoint proposal in the Featureset-and-Scalability doc needs exactly the same
   hook. Cheapest thing here with the widest payoff.
2. **Measure gVisor properly** — configure the containerd shim options `runsc` needs and
   get a startup number (§6b). It is the only candidate that could approach 400 ms cold.
   Rules itself out for GPU graphics (§5.1) but not for the rest.
3. **Warm-pool spike** — prove that pre-booting sandboxes takes the +700 ms off the
   request path. This is the practical route to "stronger isolation at current startup".
4. **Track, do not build:** libkrun + venus, virtio-gpu in cloud-hypervisor, Kata's
   virtio-gpu configuration (§5.1a). Revisit GPU workspaces when one of them lands.

Explicitly **not** recommended: building around the GPU-graphics gap ourselves, adopting
ch-operator (§3), or migrating the catalogue wholesale. The gap is being closed upstream
by people whose job it is; our job is to be ready to select the runtime when it is.

---

## 8. Open questions

- Does CIVO offer **any** shape with nested virtualisation, or bare metal? If not,
  a microVM tier means a second provider (we already run an OCI CPU runner; OCI bare
  metal shapes would qualify) or our own hardware.
- Kata's `virtio-fs` sharing of a **29 GB** store: does DAX window sizing hold up at
  that scale, and what is the cost of the first-touch faulting?
- Does the Kasm platform need anything from a session beyond `exec` and the network
  path? (Under Kata `exec` works; anything that assumes a host-visible container
  filesystem — profile sync, uploads, recording — needs checking against virtio-fs.)
- Guest kernel: does it need our own build for anything the workspaces rely on?
  (User namespaces are confirmed working — bwrap ran. `overlayfs` inside the guest and
  `fuse` still unverified.)
- Does the audio path (websocket relay out of the session) survive unchanged? It
  should, being ordinary TCP inside the guest, but it is worth confirming early since
  audio has historically been the fragile one.
- **How much of the catalogue actually needs GPU *graphics*** (as opposed to benefiting
  from it)? This sizes the value of the software-rendered tier, and it is answerable from
  `nix-profiles.toml` plus the render-path notes rather than by experiment.
- Why does DAX (`virtio_fs_cache_size`) prevent the clh VM from booting (§6a)? Now an
  optimisation question rather than a blocking one.
- Does libkrun's venus/virtio-gpu path have a containerd-drivable runtime we could
  register as a `RuntimeClass`, or is it SDK-only today? This is the gating question for
  the "wait for virtio-gpu" strategy (§5.1a) — if the answer is SDK-only, the wait is
  longer than the feature's existence suggests.
