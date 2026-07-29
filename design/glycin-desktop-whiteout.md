# The "white desktop, icon labels only" failure — root cause

**Status:** root-caused and reproduced 2026-07-29 (previous attempts failed to
reproduce; see § 6 for why). Applies to every Resolute-based desktop image
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
   `xfce4-panel`, `xfdesktop` and `xfwm4` die. The labels you see are what
   xfdesktop had already drawn before it aborted.

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

## 4. Why it breaks on the SaaS fleet and not on 192.168.1.140

**Not the host.** The obvious suspect was the Ubuntu 23.10+ sysctl:

| host | `kernel.apparmor_restrict_unprivileged_userns` |
|---|---|
| forge (Ubuntu 26.04) | 1 |
| OCI runner (Ubuntu 24.04) | 1 |
| 192.168.1.140 (Ubuntu 24.04) | **0** |

That difference is real but **causally irrelevant**: the 2×2 `unshare -U`
matrix is byte-identical on a `=1` host and the `=0` host (default seccomp
fails, `bwrap.json` succeeds, AppArmor unconfined changes nothing). Ubuntu's
`docker-default`/`nerdctl-default` profile already grants `userns`, so the
sysctl never bites. Do not chase it.

**The actual variable is the workspace record's `run_config` in that
deployment's own database.** The registry entry passed through three states in
a single day:

| commit | date | `security_opt` | icons | browsers |
|---|---|---|---|---|
| `4b84f6c` | 2026-07-20 | `chrome.json` only | **BROKEN** | ok |
| `9699619` | 2026-07-20 | *removed entirely* | ok (unsandboxed) | **broken** (need userns) |
| `4aa0d22` | 2026-07-20 | `apparmor=unconfined` + `bwrap.json` | ok | ok |

A deployment that imported TraceLabs while the entry was at `4b84f6c` holds a
permanently broken `run_config`. The registry does expose the change — the
per-workspace `sha` in `list.json` is a content hash of the workspace folder
(`processing/processjson.js`: `hashElement(folder)`), so it moved when
`workspace.json` did — but the *image tag never changes* (`:nix`), so nothing
about the running image signals it, and an existing workspace record is only
rewritten when someone applies the registry update.

The symptom set identifies which stale state a deployment is in:

- **white desktop, labels only** → `chrome.json` state, or `bwrap.json` without
  `apparmor=unconfined`
- **desktop fine, but Chromium/obsidian/Electron won't start** → the
  no-`security_opt` state

The field log is the first case: glycin chose the Bwrap mechanism (the bwrap
command line appears in the error and there is no "running without sandbox"
warning), which means userns *was* permitted — so that container had a Kasm
seccomp profile but not a working mount path.

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

**Fix, deployment side:** the workspace's `run_config.security_opt` must be
`["apparmor=unconfined", "seccomp=<bwrap.json>"]`. Apply the registry update, or
delete and re-add the workspace, or edit `run_config` directly. The registry has
published the correct value since `4aa0d22`.

## 6. Why this could not be fixed in the image, and why earlier attempts failed

Every image-side escape was tested and closed:

- **Remove the gdk-pixbuf↔glycin bridge.** Not possible on Resolute:
  `libgdk_pixbuf-2.0.so.0` links `libglycin-2.so.0` directly, and even
  librsvg2-common's `libpixbufloader_svg.so` links both librsvg *and* libglycin.
- **Remove `/usr/bin/bwrap` so glycin falls back.** Tested: it does **not**
  fall back. Detection probes userns, not the binary — the loader still tries to
  exec bwrap and dies. Icon decode still fails.
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
