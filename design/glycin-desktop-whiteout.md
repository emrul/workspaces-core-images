# The "white desktop, icon labels only" failure — root cause

**Status:** root-caused and reproduced 2026-07-29, on both an unhardened host
(by reconstructing the broken config) and on the real CIS L2 hardened SaaS host
image (where the config we ship is *itself* broken — § 4). Previous attempts
failed to reproduce; see § 6 for why. Applies to every Resolute-based desktop image
(tracelabs-osint, the fat-store desktops), and to any Ubuntu 25.10+ base.

**Symptom:** the session comes up with a blank/white desktop showing desktop
*icon labels* but no icons, no panel, no theming. Field report 2026-07-28,
`nix.log`, TraceLabs OSINT on the SaaS fleet.

## 1. The mechanism

Icon decoding on Ubuntu 26.04 goes through **glycin**, which runs its image
loaders in a `bwrap --unshare-all` sandbox. From the field log:

```
(xfce4-panel:1063): Gtk-WARNING: Could not load a pixbuf from icon theme.
Gtk:ERROR:../../../gtk/gtkiconhelper.c:495:ensure_surface_for_gicon:
  assertion failed (error == NULL): Failed to load
  /usr/share/icons/Adwaita/scalable/status/image-missing.svg:
  Loader process exited early with status '1'
  Command: "bwrap" "--unshare-all" … "/usr/libexec/glycin-loaders/2+/glycin-svg"
Bail out!
```

Three links in the chain, and the third is what makes it catastrophic:

1. `bwrap` cannot complete its sandbox setup, so the loader process exits 1.
2. gdk-pixbuf returns a `gdk-pixbuf-error-quark` error for the icon.
3. **GTK treats a failed icon load as a fatal assertion** (`Bail out!`) — so
   whichever process hit it dies. Measured (§ 3b): `xfce4-panel` dies;
   `xfdesktop` and `xfwm4` survive, having already drawn the icon *labels* —
   which is why the screen shows labels, no panel, no icons.

The trigger is the *fallback icon*: any missing icon resolves to
`image-missing.svg`, which is an SVG, which goes to `glycin-svg`, which aborts
the process. One unreadable icon takes down the whole desktop.

## 2. glycin only falls back when userns creation itself is denied

This is the crux, and it is why the failure is bistable rather than
proportional. glycin picks its sandbox mechanism by probing whether it can
create a user namespace:

- **userns denied** → mechanism `NotSandboxed`. It logs
  `WARNING: Glycin running without sandbox.` and **decodes the image
  successfully**. Icons work.
- **userns permitted** → mechanism `Bwrap`. It commits, and any *later* bwrap
  failure (the mount setup) is fatal. No fallback. Desktop dies.

So the broken configurations are the *middle* ones: userns allowed, mounts
denied. A container with **no** custom seccomp at all is fine (icons load
unsandboxed); a container with a partial profile is broken.

## 3. Measured truth table

`docker run` against `tracelabs-osint:nix` on 192.168.1.140, probing
`bwrap --unshare-all … /bin/true` and a real
`GdkPixbuf.Pixbuf.new_from_file(image-missing.svg)`:

| seccomp | apparmor | bwrap result | icon decode |
|---|---|---|---|
| docker default | docker-default | `No permissions to create a new namespace` | **OK** — glycin runs unsandboxed |
| docker default | `unconfined` | same | **OK** — glycin runs unsandboxed |
| `chrome.json` | docker-default | `Failed to make / slave: Operation not permitted` (EPERM = seccomp) | **FAIL** |
| `chrome.json` | `unconfined` | `Failed to make / slave: Operation not permitted` | **FAIL** |
| `bwrap.json` | docker-default | `Failed to make / slave: Permission denied` (EACCES = AppArmor) | **FAIL** |
| `bwrap.json` | `unconfined` | namespace + mounts set up | **OK** — sandboxed |

Read the errno: **EPERM is seccomp, EACCES is AppArmor.** Both must be lifted,
and they are two independent gates:

- Docker's default seccomp gates `unshare`/`clone` *and* the whole mount family
  behind `CAP_SYS_ADMIN`. `chrome.json` lifts only the first, which is precisely
  what puts glycin on the bwrap path and then breaks it. `bwrap.json` adds the
  unconditional mount family + `pivot_root`.
- Docker's default AppArmor profile denies bwrap's mount operations, so
  `bwrap.json` alone still fails with EACCES. `apparmor=unconfined` is required
  *as well*.

**`chrome.json` is not a partial fix — it is the worst option**, because it
converts a working unsandboxed decode into a desktop crash.

## 3b. Full-session A/B (the actual desktop, not just the loader)

The table above probes the loader. This is the whole desktop: same host
(192.168.1.140), same image, two `docker run` sessions differing only in
`--security-opt`.

| run | `Bail out!` | "Could not load a pixbuf" | xfce4-panel | xfdesktop / xfwm4 |
|---|---|---|---|---|
| `seccomp=chrome.json`, no apparmor opt | **3** | many | **0 — dead** | 1 / 1 |
| `seccomp=bwrap.json` + `apparmor=unconfined` | 0 | 0 | 1 — alive | 1 / 1 |

The broken run reproduces the field log line for line, including the same
`Failed to load image "/usr/share/extra/icons/icon_default.png"` sequence. Note
which processes die: the **panel** is gone while xfdesktop and xfwm4 survive —
i.e. a desktop with icon labels, no panel, no icons. Exactly the screenshot.

Note this was reproduced on the host where the bug "doesn't happen". It doesn't
happen *through Kasm* there because Kasm applies the correct `run_config`; the
host is not what protects it. Bypass Kasm and pass the broken option set and the
same host fails identically.

## 4. Why it breaks on the SaaS fleet and not on 192.168.1.140

**It IS the host — via a mechanism the first test missed.** Measured on a
throwaway instance built from the SaaS host image itself
(`Kasm-Ubuntu 24.04 x86_64 - CIS Level 2 Hardened - Ver 2.2.4`, docker 29.6.1,
same version as 192.168.1.140):

| config | .140 (`restrict_unprivileged_userns=0`) | CIS L2 host (`=1`) |
|---|---|---|
| docker default seccomp | OK (glycin falls back) | OK (glycin falls back) |
| `chrome.json` | FAIL — EPERM at `make / slave` | FAIL — EPERM at `make / slave` |
| `bwrap.json`, docker-default apparmor | FAIL — EACCES at `make / slave` | FAIL — EACCES at `make / slave` |
| **`bwrap.json` + `apparmor=unconfined`** | **OK** | **FAIL — `bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted`** |
| `bwrap.json` + `apparmor=kasm-app-bwrap` | — | FAIL — EACCES at `make / slave` |
| `bwrap.json` + `apparmor=kasm-desktop` | — | OK, but only because userns creation is *denied* → fallback |

**The configuration we ship as correct does not work on the hardened host.** On
`=1`, bwrap now gets *past* namespace creation and the mount setup and dies later
bringing up loopback in its new network namespace — i.e. it lacks
`CAP_NET_ADMIN` inside the namespace it just created. That is Ubuntu's
`apparmor_restrict_unprivileged_userns` behaviour: a process that creates an
unprivileged userns without an explicit `userns` grant is transitioned into a
restricted profile, so it does *not* hold full capabilities inside its own
namespace. No AppArmor AVC is logged, which is why it looks like a plain EPERM.

Proven by flipping one bit on that host and changing nothing else:

```
sysctl kernel.apparmor_restrict_unprivileged_userns=0
  bwrap.json + apparmor=unconfined → bwrap reaches execvp; pixbuf OK 128x128
sysctl kernel.apparmor_restrict_unprivileged_userns=1   (hardened default)
  bwrap.json + apparmor=unconfined → bwrap: loopback: Failed RTM_NEWADDR; pixbuf FAIL
```

**CORRECTION to an earlier version of this document**, which claimed the sysctl
was "real but causally irrelevant — do not chase it". That was wrong, and the
error is instructive: the test behind it was `unshare -U true`, which only proves
a namespace can be *created*. The restriction does not block creation — it strips
capabilities *inside* the namespace, which only shows up at a later bwrap step.
Testing namespace creation and calling the question closed was the mistake.

### 4.1 The STIG makes this worse, mechanically

`workspaces-stigs` (release/1.18.1) `apply_docker_stigs.sh`, control V-235812:

```sh
docker inspect --format '{{ .Id }}: SecurityOpt={{ .HostConfig.SecurityOpt }}' \
  | grep -i --quiet unconfined   &&  log_failure "V-235812" "found container with seccomp unconfined."
```

It greps for the *string* `unconfined` anywhere in `SecurityOpt`. Our required
`apparmor=unconfined` matches, so a correctly-configured Nix desktop is reported
as **V-235812 FAIL — "seccomp unconfined"** even though seccomp is a custom
profile. An operator remediating that finding removes `apparmor=unconfined`,
which lands the workspace in the row above it: EACCES at `make / slave`, white
desktop. A STIG-audited fleet is pushed into the bug; an unaudited box is not.

Otherwise the docker STIG is benign here: it only mutates daemon.json
ownership/permissions, `userland-proxy`, `ip`, and log driver/opts — no seccomp
override, no userns-remap, no AppArmor changes. `apply_kasm_stigs.sh` adds
`no-new-privileges` to the *Kasm service* containers via docker-compose, not to
workspace containers.

### 4.2 Registry history is a second, independent way to land in a broken state

The registry entry passed through three states on 2026-07-20:

| commit | `security_opt` | icons | browsers |
|---|---|---|---|
| `4b84f6c` | `chrome.json` only | **BROKEN** | ok |
| `9699619` | *removed entirely* | ok (unsandboxed) | **broken** (need userns) |
| `4aa0d22` | `apparmor=unconfined` + `bwrap.json` | ok on `=0` hosts | ok |

A deployment that imported at `4b84f6c` holds a broken `run_config`
independently of the host. The `sha` in `list.json` is a content hash of the
workspace folder, so the registry does expose the change — but the image tag
never moves (`:nix`), so nothing about the running image signals it.

## 5. Diagnosis and fix

Decisive check, on the host running a broken session:

```sh
docker inspect <session-container> --format '{{json .HostConfig.SecurityOpt}}' \
  | tr ',' '\n' | grep -cE 'pivot_root'      # 1 = bwrap.json, 0 = chrome.json/default
docker inspect <session-container> --format '{{json .HostConfig.SecurityOpt}}' \
  | grep -c 'apparmor=unconfined'           # must be 1
```

Both must be non-zero. In-container equivalent (works in any session):

```sh
bwrap --unshare-all --die-with-parent --chdir / --ro-bind /usr /usr --dev /dev /bin/true
#   "No permissions to create a new namespace" → default seccomp (icons will still work)
#   "Failed to make / slave: Operation not permitted" → chrome.json  (icons BROKEN)
#   "Failed to make / slave: Permission denied"       → missing apparmor=unconfined (BROKEN)
#   "execvp … No such file or directory"              → sandbox OK (probe bound no /bin)
```

**Fix depends on the host's `apparmor_restrict_unprivileged_userns`:**

- **Host at `0`** (192.168.1.140, and any pre-23.10 host): the workspace's
  `run_config.security_opt` must be
  `["apparmor=unconfined", "seccomp=<bwrap.json>"]`. The registry has published
  this since `4aa0d22`; apply the registry update, or delete and re-add the
  workspace, or edit `run_config` directly.
- **Host at `1`** (the CIS L2 hardened image, i.e. the SaaS fleet): **no
  `run_config` alone fixes it.** Options, in order of preference:
  1. Set `kernel.apparmor_restrict_unprivileged_userns=0` on workspace hosts
     (persist via sysctl.d). Works — measured. Cost: it re-enables unprivileged
     userns host-wide, which is the protection CIS added. Defensible on a host
     whose *only* job is running workspace containers that already need userns
     for Chromium/Electron sandboxes, but it is a real posture change and needs
     sign-off.
  2. An AppArmor profile carrying an explicit `userns` grant so no restrictive
     transition happens, used as `apparmor=kasm-app-bwrap` instead of
     `unconfined` — which would ALSO clear the V-235812 false positive in § 4.1.
     **Our current profiles do not achieve this** (measured: `kasm-app-bwrap`
     still fails EACCES at `make / slave`; `kasm-desktop` denies namespace
     creation outright). This is the right long-term fix and it is unfinished
     work, not a setting.
  3. Accept unsandboxed image decode: any configuration where userns creation is
     *denied* makes glycin fall back and icons work (that is why the
     default-seccomp row is healthy). But Chromium/Electron then lose their
     namespace sandbox, so this trades one breakage for another.

Whichever route, **verify with the § 5 probe rather than by reading config** —
three different layers can produce the same white screen.

## 5b. THE FIX: upstream's bwrap passthrough wrapper (KASM-8257)

A second-opinion review (codex) found what this document previously got wrong.
Upstream Kasm already hit this bug and wrote the fix in April 2026 —
`ba4b118 KASM-8257 Convert bwrap to optional passthrough`,
`src/ubuntu/install/xfce/bwrap_wrapper.sh`. Its own comment names the cause:

> bwrap wrapper: bypass bubblewrap sandboxing. Privileged containers
> (seccomp=unconfined, sysbox) allow bwrap to fully enforce namespace/seccomp
> isolation, which breaks glycin's image loaders. This wrapper strips all
> bwrap-specific flags and exec's the target command directly.

**It never reaches our images.** `install_xfce_ui.sh` stages it only in the
`DISTRO == "kali"` branch, installs it as `/usr/bin/bwrap.wrapper` (not `bwrap`),
and **nothing ever activates it** — no runtime code references
`bwrap.wrapper` anywhere in the tree. Confirmed absent from the running
tracelabs image: `/usr/bin/bwrap.wrapper: No such file or directory`.

Baked in as `/usr/bin/bwrap`, it fixes the desktop on the hardened host, in the
configuration that otherwise fails:

| hardened host (`restrict=1`), `bwrap.json` + `apparmor=unconfined` | xfce4-panel | `Bail out!` | pixbuf warnings | icon failures |
|---|---|---|---|---|
| stock image | **0 — dead** | 758 (crash loop) | 3 | 4 |
| + passthrough `bwrap` | **1 — alive** | **0** | **0** | **0** |

This is host-independent: no sysctl change, no `run_config` change, no AppArmor
profile work. It also supersedes the § 5 decision tree for the desktop symptom.

**Trade-off:** image decode then runs unsandboxed. That is the same posture the
default-seccomp row already has (glycin's own fallback), so it is not a new
exposure for those hosts — but it does remove a sandbox that *works* on
`restrict=0` hosts. Untrusted-image decode is a real attack surface; upstream
accepted this trade for the same reason.

**Do NOT blanket-replace `/usr/bin/bwrap` in the Nix images.**
`src/ubuntu/install/nix/scripts/nix-bwrap-run` sets `BWRAP=/usr/bin/bwrap` and
needs a REAL bwrap (`--overlay-src`) to give buildFHSEnv apps (steam,
onlyoffice) a real `/nix/store` under their FHS root; every nix dockerfile
installs bubblewrap specifically for that. A passthrough would silently strip
those apps' FHS namespace. tracelabs has no FHS app, which is why the session
above is clean.

**Proposed shape (not yet implemented):** a *dispatching* wrapper —
keep the real binary at `/usr/bin/bwrap.real`, and have `/usr/bin/bwrap`
passthrough only when the target is a glycin loader
(`/usr/libexec/glycin-loaders/`), else `exec /usr/bin/bwrap.real "$@"`. Point
`nix-bwrap-run` at `bwrap.real` explicitly. That keeps the FHS apps' sandbox and
fixes the desktop everywhere.

### Test-method traps (both bit this investigation)

- **`/tmp` is `noexec` on the CIS host.** A wrapper bind-mounted from `/tmp`
  cannot be executed inside the container; the error changes from "Loader
  process exited early" to "Could not spawn", which looks like a different bug.
  Two full-session runs were invalidated this way. Bake the file into a layer.
- **`bridge: none` in the hardened daemon.json** means `docker build` `RUN`
  steps have no network (`network bridge not found`). Use `COPY` with the source
  file already mode 0755 instead of `RUN chmod`.

## 6. Earlier claim that the image cannot fix this — WITHDRAWN

**This section previously claimed no image-side fix existed. That was wrong —
see § 5b.** The three escapes below are genuinely closed, but they are not the
only options; the passthrough wrapper works and was already written upstream.
The error was concluding "impossible" from three failed attempts instead of
searching the tree for prior art:

- **Remove the gdk-pixbuf↔glycin bridge.** Not possible on Resolute:
  `libgdk_pixbuf-2.0.so.0` links `libglycin-2.so.0` directly, and even
  librsvg2-common's `libpixbufloader_svg.so` links both librsvg *and* libglycin.
- **Remove `/usr/bin/bwrap` so glycin falls back.** Tested: it does **not**
  fall back. Detection probes userns, not the binary — the loader still tries to
  exec bwrap and dies. Icon decode still fails. (The fix is to *replace* bwrap
  with a passthrough, not remove it — § 5b. Testing removal and stopping there
  was the mistake.)
- **Env-var override.** glycin 2.1.1 references exactly two variables
  (`GLYCIN_DATA_DIR`, `GLYCIN_SECCOMP_DEFAULT_ACTION`). `NotSandboxed` exists as
  a mechanism but cannot be selected from outside.

**Why four earlier hypotheses were disproven and the bug looked
unreproducible:** the reproduction attempts ran inside the privileged DinD build
container on forge, which is `--privileged` — no seccomp filter and AppArmor
unconfined. In that environment bwrap always works, so *every* variant looked
healthy. A plain `docker run` with no `--security-opt` is equally useless: it
lands in the "default seccomp" row, where glycin silently falls back and icons
work. Reproducing this bug **requires** passing a Kasm seccomp profile and
withholding `apparmor=unconfined` — i.e. you have to reconstruct the failing
configuration deliberately.

## 7. Recommended durable mitigation

The image cannot make glycin robust, but it can stop the failure from being
mute. Proposed: a container-init unit that runs the § 5 bwrap probe at boot and,
when it detects the middle state (userns permitted, mounts denied), logs one
actionable line, e.g.

```
[icon-sandbox] FATAL-FOR-DESKTOP: bwrap mount setup denied (EACCES) — this
  session's security_opt is missing apparmor=unconfined; the XFCE panel and
  desktop icons WILL crash. See design/glycin-desktop-whiteout.md § 5.
```

That converts a white screen with no explanation into a one-line diagnosis in
the session log, for every deployment, without depending on anyone's run_config
being right. Not yet implemented.
