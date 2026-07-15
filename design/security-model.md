# Security model — container-init, seccomp, and the escape boundary

Audience: engineers and reviewers evaluating the security posture of this fork's
core images (the container-init boot supervisor, the Nix app variant, and the
seccomp profiles). This doc states the design choices, the honest trade-offs
against stock Kasm, and the deployment controls that make the posture sound.

> TL;DR — Two choices in this fork draw scrutiny: (1) enabling Chrome/Electron's
> in-process sandbox via a loosened seccomp profile, and (2) a root PID 1
> (container-init) where stock Kasm runs everything as `kasm-user` (uid 1000).
> Both are **in-container** decisions whose residual risk is resolved at the
> **runtime/host boundary** (user-namespace remapping, or the sysbox runtime,
> plus capability dropping). With that boundary in place, this fork's posture is
> a *superset* of stock: same-or-better host isolation, more capability. Without
> it, the caution is legitimate. So the boundary is the control that matters.

---

## 1. Threat models

Security here is not a single scalar; it depends on **who the attacker is**. Two
distinct models, defended by different controls:

- **Model A — "the web is hostile" (attacker = remote content).** The user is
  authenticated/semi-trusted; the danger is a malicious web page or document
  exploiting the browser/renderer. This is the *primary* threat for a browsing
  workspace — isolation of risky content is the whole reason to use one.
- **Model B — "the user is hostile" (attacker = the session user).** The logged-in
  user actively tries to escape the container to the host. The danger is Linux
  kernel attack surface reachable from inside the container.

A control that helps one model can cost the other. Stating which model a
deployment is in is a prerequisite to choosing a posture (§6).

---

## 2. Choice 1 — Chrome/Electron sandbox ON via loosened seccomp

**What stock does:** runs Chrome with `--no-sandbox`, because the default
container seccomp denies the unprivileged `clone/clone3/unshare/setns` that
Chrome's user-namespace sandbox needs.

**What this fork does:** ships `src/common/seccomp/chrome.json` — the Moby
v25.0.6 default profile, patched to allow `clone/clone3/unshare/setns`
unconditionally so the browser can build its own sandbox — and
`src/common/seccomp/bwrap.json` (chrome.json **+** the mount family:
`mount/umount/umount2/pivot_root/move_mount/open_tree/fs*/mount_setattr`) for
`buildFHSEnv`/bubblewrap apps (OnlyOffice, Steam). Regenerate with
`bin/regen-seccomp.sh`. The delta from the Docker default is **specifically
unprivileged user namespaces** (+ the mount family for bwrap workspaces) — the
genuinely dangerous syscalls the Docker default blocks stay blocked.

### Analysis

The claim "Chrome's sandbox hasn't prevented a vulnerability in a long time" is
**not accurate** and should be checked against primary sources (Chrome release
notes, Google Project Zero, the CISA Known-Exploited-Vulnerabilities catalog —
do not rely on remembered CVE numbers). The sandbox is not a bug-catcher; it is
the *containment boundary* for the renderer, where most of Chrome's critical
memory-safety bugs live and are exploited in the wild multiple times per year.
The steady stream of dedicated **"sandbox escape" CVEs** is direct evidence the
sandbox is load-bearing: attackers must spend a *second* bug to get past it.

The trade is **asymmetric**:

| | Defends | Attack frequency | Cost if removed |
|---|---|---|---|
| Sandbox ON (looser seccomp) | Model A: web pops the renderer | High | — |
| Tight seccomp (userns off) | Model B: user attacks the kernel | Lower; needs a kernel LPE | — |

- `--no-sandbox`: a single common renderer bug → **immediate code execution as
  the session user in the container**, no further work. Cheap, frequent.
- Looser seccomp: adds kernel surface (unprivileged userns — a real, named LPE
  risk class, which is why distros ship `kernel.unprivileged_userns_clone=0`).
  But exploiting it requires a kernel LPE, and a hostile authenticated user
  already has a shell + hundreds of syscalls; `--no-sandbox` would not stop them.

Note the same primitive that is the risk (userns) is what *powers* the defense
(the browser sandboxes its renderers with it). Turning the sandbox off to keep
seccomp tight optimizes the wrong layer: it weakens the high-frequency defense
to marginally reduce a surface that runtime isolation (§4) should own anyway.

**Position:** keep the sandbox on for browser/Electron workspaces; keep the
loosening **scoped** — chrome.json (no mount) for Chromium/native, bwrap.json
(with mount) only for the FHS apps that need it, never a blanket profile — and
pair it with the runtime boundary in §4. For genuinely-untrusted-user tenancy
without runtime isolation, prefer a locked-down profile (§6).

---

## 3. Choice 2 — root PID 1 (container-init) vs stock's uid-1000

**Stock Kasm** runs the whole container as `kasm-user` (uid 1000): no root.
**This fork** runs container-init as root (uid 0), then drops privilege for
everything it supervises.

### The privilege model (measured, not asserted)

Of the 19 core **service** units in `src/common/kasm-go/units/` (`.service`
files; the `.socket` units are just listeners), only **5 run as root**, and they
are infrastructure/setup, not user-facing:

| Runs as root (uid 0) | Why |
|---|---|
| `kasm-setup.service` | per-session identity (`KASM_OS_USER/UID/GID`), profile seed, ownership/symlinks — needs root |
| `pcscd.service` | smartcard daemon requires root |
| `network-wait.service` | boot ordering helper |
| `recorder-drain` / `recorder-watch` | session-recording plumbing |

Every user-facing service drops to the session user via `User=${KASM_OS_USER}`:
**kasmvnc, window-manager, custom-startup (the actual app/browser), audio in/out,
upload, webcam, gamepad, smartcard, printer, profile-\*, systemd1-shim** (14
units). So the desktop, the browser, and the app the user interacts with all run
as `kasm-user` — identical to stock. Root is confined to PID 1 plus the setup
phase and a few daemons that genuinely require it.

### The real regression is the *mapping*, not the uid

The precise downgrade vs stock is **not** "root inside the container" — it is:

- stock: container-uid-1000 → **host uid 1000** (unprivileged) — an escape lands unprivileged.
- this fork *without userns-remap*: container-uid-0 → **host uid 0** — an escape lands as **host root**.

Name it precisely, because it points at the fix (§4).

### Why root exists here (stock's rootless model has real costs)

Running everything as 1000 buys a clean story by giving up capability:

- **No per-session identity** — `KASM_OS_UID`/`USER` remap needs root.
- **Can't fix mounted-volume ownership at runtime** — a non-root container can't
  `chown` a bind-mounted home/profile to the session user; volumes must be
  pre-owned as 1000 (brittle), and profile-sync restores hit ownership friction.
- **Constrained privileged service setup** — CUPS, pcscd, webcam/audio device
  perms want root or specific caps.
- **Nix activation (this fork)** — `nix-activate` writes `/etc/profile.d`,
  `/usr/share/applications`, runs `ldconfig`, bootstraps `/run/nix-state`, and
  creates `/run/user/<uid>` owned by the session user. As 1000 this degrades to
  user-scoped-only.

Running as root PID 1 that immediately drops privilege is the standard init
pattern (tini, s6, systemd all do it), and is why Kasm itself ships a sysbox
path. The residual root surface is PID 1 + the setup phase; minimize it (§4).

---

## 4. The unifying control: the runtime/host boundary

Both §2 and §3 concerns collapse to **one** mitigation. Apply it and both stop
being escape paths:

### 4a. User-namespace remapping (or rootless runtime)

With daemon `userns-remap` (or per-container `--userns`, or rootless
docker/podman):

- container-init runs as root **inside the container user namespace** — keeps
  every capability it needs (chown volumes, remap the user, nix-activate).
- container-uid-0 maps to a **high, isolated, unprivileged host uid** (e.g.
  100000) — an escape lands *at least* as unprivileged as stock's 1000, and
  better (stock's host-1000 can collide with a real host account; a remapped
  root cannot).
- an escape *through* the looser Chrome seccomp (unprivileged userns) also lands
  remapped-unprivileged.

Net: with userns-remap, this fork's root PID 1 is a **strict superset** of stock
— same-or-better host isolation *plus* the setup capabilities stock lacks.

### 4b. sysbox (preferred where available)

`src/ubuntu/install/sysbox/install_systemd.sh` provides the sysbox path: real
systemd, container-init runs as a system unit (`kasm.service`) rather than PID 1.
Sysbox exists precisely to run root/systemd-style workloads in a strongly
isolated container (container-root is safe by design) — it resolves the
root-PID-1 debate *and* the chrome-seccomp surface at once. This is the cleanest
answer for high-risk workspaces.

### 4c. Capability + privilege hardening (always)

Independent of the above:

- Drop PID 1 capabilities to the minimal set it needs — roughly `CAP_CHOWN`,
  `CAP_SETUID`, `CAP_SETGID`, `CAP_DAC_OVERRIDE` — and drop the rest.
- `no-new-privileges` on the container.
- read-only rootfs where feasible; tmpfs for writable paths.
- keep the seccomp delta minimal and scoped per workspace (§2).

---

## 5. What this fork does NOT change

- The user-facing desktop/browser/app still runs as `kasm-user`, as in stock.
- The seccomp baseline is still the Moby default minus a *scoped* delta — not
  `--privileged`, not seccomp `unconfined`. AppArmor on bwrap workspaces was
  historically run `unconfined` for FHS mount setup; the scoped
  `src/common/apparmor/kasm-app-bwrap` profile now replaces that (re-opens only
  the mount family, keeps every other escape denial). See `docs/apparmor-how-to.md`.
- Capabilities are not broadly added; container-init needs a small set for setup.

---

## 6. Recommended posture by deployment

| Deployment | Model | Chrome sandbox | seccomp | Runtime boundary |
|---|---|---|---|---|
| Browsing workspace, authenticated users | A | **ON** | chrome.json (scoped) | userns-remap **or** sysbox + cap-drop |
| FHS app (OnlyOffice/Steam), authenticated | A | n/a | bwrap.json (scoped) | sysbox preferred; else userns-remap + apparmor |
| Untrusted / multi-tenant users | B | ON only under sysbox | locked-down profile if no runtime isolation | **sysbox required**; else minimize surface |
| Air-gapped / low-risk internal | A | ON | chrome.json | userns-remap + cap-drop |

The single most important line: **decide the threat model, then ensure the
runtime boundary (userns-remap or sysbox) is present.** With it, keep the browser
sandbox on and container-init as-is. Without it, in Model B, the caution about
both the seccomp loosening and the root PID 1 is warranted — and the answer is to
add the boundary, not to disable the browser sandbox or lose setup capability.

---

## 7. How to audit

- **Which units run as root:** `grep -L '^User=' src/common/kasm-go/units/*.service`.
- **seccomp delta:** diff `src/common/seccomp/chrome.json` against the Moby
  v25.0.6 default; the intended delta is the unconditional
  `clone/clone3/unshare/setns` allow (and the mount family in `bwrap.json`).
  `_patch`/`_regen` fields in the JSON document it; regenerate via
  `bin/regen-seccomp.sh`.
- **Effective host uid of container-root:** with userns-remap, inspect
  `/proc/self/uid_map` inside the container (0 should map to a high host uid).
- **Boot privilege trace:** `CONTAINER_INIT_TRACE=1` → `/tmp/container-init-trace.jsonl`
  shows unit start order; cross-reference with the root/user table above.
- **Verify CVE/exploit claims** (e.g. §2) against Chrome release notes, Project
  Zero, and the CISA KEV catalog — not from memory.

---

## 8. Open follow-ups

- Ship a documented `userns-remap` + cap-drop reference config (daemon and
  per-workspace `run_config`) alongside this doc.
- Confirm container-init runs correctly under sysbox end-to-end (the
  `kasm.service` path) and document it as the recommended high-risk posture.
- Make the sandbox/seccomp choice a **per-workspace policy** knob rather than a
  global default, so Model A and Model B deployments can coexist.
- Roll out the AppArmor profiles (`src/common/apparmor/{kasm-desktop,kasm-app,
  kasm-app-bwrap}`, loaded via `bin/load-apparmor.sh`; see
  `docs/apparmor-how-to.md`) as the complementary MAC layer: replaces the bwrap
  `apparmor=unconfined`, and their scoped `userns` grant lets Ubuntu 24.04+ hosts
  keep `apparmor_restrict_unprivileged_userns=1` on globally. Host-load
  dependency + Debian/SUSE-only (RHEL family uses SELinux) are the caveats.
- Nix alpine variant: software-render only today; GPU is future work and must
  feed glibc GL (nix mesa, or host-injected glibc nvidia libs) to glibc apps —
  never the host's musl mesa. See the nix design notes.
