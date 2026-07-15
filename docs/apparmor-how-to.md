# AppArmor for Kasm workspaces

This is a companion to [`seccomp-how-to.md`](seccomp-how-to.md). seccomp
filters **which syscalls** a process may make; AppArmor restricts **which
resources** it may touch (files, mounts, capabilities, ptrace, network
families). They are complementary layers — this doc adds the second one.

It assumes you have **not** used AppArmor before. Read §1 and §2 first.

---

## 1. What AppArmor is (in one minute)

AppArmor is a Linux kernel security module. You give an executable a
**profile** — a list of rules saying what it is allowed to do — and the
kernel enforces it, *even for root*. A profile can allow/deny:

- **files** — read/write/execute specific paths (`/home/**`, `/etc/shadow`…)
- **capabilities** — `sys_admin`, `sys_module`, `chown`… (the root powers)
- **mount / umount / pivot_root** — the classic container-escape primitives
- **ptrace / signals** — poking at other processes
- **network** — by family (tcp, udp, raw, packet…)

Two things make it different from the other controls you already ship:

| | seccomp (you have this) | AppArmor (this doc) | Linux perms (uid/gid) |
|---|---|---|---|
| Controls | syscall numbers + args | files, mounts, caps, ptrace, net | file ownership bits |
| Applies to root? | yes | **yes** | no (root bypasses) |
| Granularity | per syscall | per path / per resource | per file |

**The one fact that changes everything for us:** a seccomp profile is a
JSON file the container runtime reads at launch — Kasm even inlines the
whole JSON into `run_config` (see `design/data/runConfig.chrome.json`). You
**cannot** do that with AppArmor. An AppArmor profile must be **compiled
into the host kernel ahead of time** and then referenced *by name*. So
shipping AppArmor is two steps:

1. **Load** the profile on every agent host (once, at provisioning).
2. **Reference** it by name in the workspace's `run_config`
   (`"apparmor=kasm-app"`).

Miss step 1 and a workspace that names the profile in step 2 **fails to
start**. That host-side dependency is the main operational cost, and the
reason seccomp was the easy win and this is a bigger lift.

A profile runs in one of two modes: **complain** (allowed, but every
violation is logged — use this to author/tune) or **enforce** (violations
are blocked). Always start in complain mode.

---

## 2. Which profile for which workspace

We ship three profiles in `src/common/apparmor/`, matching the two Kasm
use cases:

| Profile | Use case | Posture |
|---|---|---|
| `kasm-desktop` | **Hosted desktop** — a developer with broad access inside the container | Broad inside the box; blocks host-escape (no mount, no dangerous caps, no raw kernel/mem). |
| `kasm-app` | **Single-app / RBI** — e.g. hardened Chrome; user may only browse | Same escape-hardening, **plus** no raw/packet sockets, plus an optional write-lockdown. |
| `kasm-app-bwrap` | **Single-app FHS** — OnlyOffice, Steam and other `buildFHSEnv`/bubblewrap apps | `kasm-app` **plus** the mount family bubblewrap needs. Replaces today's `apparmor=unconfined`. |

They parallel your seccomp split exactly:

- `kasm-desktop` / `kasm-app` ↔ `chrome.json` (userns, no mount)
- `kasm-app-bwrap` ↔ `bwrap.json` (chrome.json **+** the mount family)

### Why `kasm-app-bwrap` matters most

FHS single-app workspaces currently run with `--security-opt
apparmor=unconfined` (see `design/security-model.md` §5), which throws away
*all* of AppArmor. That is the same mistake as running Chrome with
`seccomp=unconfined` — and you already refused to do that on the seccomp
side by building the scoped `bwrap.json`. `kasm-app-bwrap` is the symmetric
fix: it re-opens **only** mount (which bubblewrap genuinely needs, and which
it performs inside its own user+mount namespace where it can't touch the
host mount table) and keeps every other escape denial in force. Even with a
permissive mount rule it is strictly better than `unconfined`.

---

## 3. Host prerequisites

### 3a. Is AppArmor even available on this host?

AppArmor ships on **Ubuntu / Debian / openSUSE**. **RHEL / CentOS / Fedora
/ Oracle / Rocky / Alma use SELinux instead** — these profiles do nothing
there, and `--security-opt apparmor=…` is silently ignored or errors. Gate
this feature on the agent host's distro. (Your core images span all these
families; AppArmor only helps on the Debian/SUSE-family hosts.)

Check on a host:

```sh
aa-enabled                 # prints "Yes" if AppArmor is active
cat /sys/module/apparmor/parameters/enabled   # "Y"
apparmor_parser --version  # need >= 4.0 for the userns rule (see 3b)
```

### 3b. The user-namespace wrinkle (Ubuntu 24.04+)

You already hit this: your Nix docs tell operators to run `sysctl
kernel.apparmor_restrict_unprivileged_userns=0`. That sysctl exists because
**AppArmor itself** (on Ubuntu 23.10+/24.04+) blocks the unprivileged user
namespaces that Chrome's and bubblewrap's sandboxes depend on. Setting it to
`0` turns the restriction off **for every process on the host** — a blunt
instrument.

Our profiles do it better. Each contains a single `userns,` rule that grants
userns creation **only to workspaces running under that profile**. So you can
leave the host restriction *on* (protecting everything else) and still let
the browser sandbox work. This is a genuine security improvement over the
global sysctl, and a good reason to adopt AppArmor even if you did nothing
else with it.

Caveat: the `userns,` rule (and the `abi <abi/4.0>` line) require **AppArmor
≥ 4.0**, which ships on Ubuntu 24.04 (your `core-ubuntu-noble` host target).
On older hosts (22.04 / AppArmor 3.x) the profile won't compile — delete the
`abi <abi/4.0>` and `userns,` lines from the profile and fall back to the
`sysctl …=0` approach on those hosts.

---

## 4. Loading the profiles on a host

Use the bundled loader (wrap it in your host provisioning):

```sh
# Load ALL profiles in COMPLAIN mode (log-only) — always do this first
sudo COMPLAIN=1 bin/load-apparmor.sh

# ...validate a full workspace session (see §6), then load in ENFORCE mode
sudo bin/load-apparmor.sh

# Or just one profile
sudo bin/load-apparmor.sh kasm-app
```

Under the hood this runs `apparmor_parser -r -W <profile>` (`-r` = replace if
already loaded). To do it by hand:

```sh
sudo apparmor_parser -r -W -C src/common/apparmor/kasm-app   # -C = complain
sudo apparmor_parser -r -W    src/common/apparmor/kasm-app   # enforce
```

Confirm what's loaded:

```sh
sudo aa-status | grep kasm-
```

**Provisioning:** because of the host dependency (§1), every agent host must
have the profiles loaded *before* a workspace referencing them lands there.
Wire `load-apparmor.sh` into cloud-init / Ansible / a oneshot systemd unit on
the agent image — the same class of work as the `userns-remap` reference
config tracked in `design/security-model.md` §8.

---

## 5. Applying a profile to a workspace

### Kasm run_config (the normal path)

Unlike seccomp, you pass the **name**, not the JSON:

```json
{
  "security_opt": [
    "seccomp={...chrome.json inlined as today...}",
    "apparmor=kasm-app"
  ]
}
```

seccomp and AppArmor stack — keep both. For a hosted desktop use
`apparmor=kasm-desktop`; for a bubblewrap FHS app use
`apparmor=kasm-app-bwrap` (and drop the `apparmor=unconfined` it has today).

### docker / docker-compose

```sh
docker run \
  --security-opt seccomp=/etc/docker/seccomp/chrome.json \
  --security-opt apparmor=kasm-app \
  -p 6901:6901 -e VNC_PW=password \
  kasmweb/core-ubuntu-noble:1.17.0
```

```yaml
services:
  workspace:
    image: kasmweb/core-ubuntu-noble:1.17.0
    security_opt:
      - seccomp=/etc/docker/seccomp/chrome.json
      - apparmor=kasm-app
```

### Podman

Identical flag (`--security-opt apparmor=kasm-app`). Podman loads profiles
via the same host `apparmor_parser`, so `load-apparmor.sh` applies unchanged.

### Kubernetes

Since 1.30 AppArmor is a first-class field; before that it was an annotation.
The profile must be loaded on **every node** (DaemonSet / node image):

```yaml
spec:
  securityContext:
    appArmorProfile:
      type: Localhost
      localhostProfile: kasm-app
```

---

## 6. Authoring & tuning (complain mode → enforce)

**Never** ship a profile straight to enforce — you will break boot. The loop:

1. Load in complain mode: `sudo COMPLAIN=1 bin/load-apparmor.sh <name>`.
2. Start a workspace with that profile and **exercise it fully** — launch the
   app, open/close windows, upload/download a file, audio, whatever the
   workspace does.
3. Read the denials the kernel logged:

   ```sh
   sudo journalctl -k | grep -i apparmor | grep -i denied
   # or, if auditd is running:
   sudo grep 'apparmor="DENIED"' /var/log/audit/audit.log
   # friendliest: aa-logprof walks you through each denial and edits the profile
   sudo aa-logprof
   ```

   A denial line names the `profile=`, the `operation=` (e.g. `mount`,
   `open`, `capable`) and the resource (`name="/path"` or `requested_mask=`).
4. Add an allow rule for anything **legitimate**, re-load, repeat until a full
   session is clean.
5. Switch to enforce: `sudo bin/load-apparmor.sh <name>`.

### The optional write-lockdown in `kasm-app`

`kasm-app` ships a commented "read-broad / write-narrow" block. Enabling it
forbids the app from writing anywhere except the runtime paths the stack
uses, so a compromised renderer can't tamper with binaries or drop
persistence. It is **off by default** because the exact write set is
image-specific and will break boot if wrong — adopt it only via the
complain-mode loop above. For RBI on ephemeral containers the incremental
value is modest (the container is destroyed at session end anyway), so treat
it as defense-in-depth, not a priority.

### A note on granularity

A container gets **one** AppArmor profile shared by *every* process in it
(container-init, KasmVNC, the window manager, the app…). You cannot give just
the browser a tighter profile without advanced per-executable profile
*transitions*, which are brittle inside a container — so these profiles are
written to accommodate the whole Kasm stack. That is why "lock it down to
only the Chrome binary" isn't a realistic single knob.

---

## 7. Verifying enforcement

```sh
# On the host: confirm the container is running under the profile
docker inspect <container> --format '{{ .AppArmorProfile }}'   # -> kasm-app

# Inside the container: escape primitives should now fail
mount -t tmpfs none /mnt        # expect: Permission denied
cat /proc/sysrq-trigger          # expect: Permission denied (write) 
cat /dev/mem                     # expect: Operation not permitted

# ...but the browser sandbox should still engage (userns granted)
unshare -U /bin/true && echo "userns ok"
```

If `unshare -U` fails under enforce on Ubuntu 24.04, your AppArmor is < 4.0
or the `userns,` line didn't load — see §3b.

---

## 8. Where AppArmor sits in the bigger picture

AppArmor is **defense-in-depth, not the primary boundary.** Per
`design/security-model.md`, the control that actually decides where an escape
*lands* is the runtime boundary: **user-namespace remapping** or **sysbox**
(§4 there). If container-uid-0 maps to host-uid-0, a good AppArmor profile
raises the bar but a kernel LPE still lands as host root. So:

1. First, close the host-uid mapping (userns-remap or sysbox).
2. Then these AppArmor profiles are a cheap, meaningful extra layer — and the
   `kasm-app-bwrap` profile is a clear win over the `apparmor=unconfined` in
   use today.

sysbox is the strongest answer for the hosted-desktop case where a developer
legitimately wants mount / docker-in-docker (which `kasm-desktop` denies) —
it makes container-root safe by construction, so you can relax the profile
without relaxing host isolation.
