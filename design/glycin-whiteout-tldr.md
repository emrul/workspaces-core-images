# TL;DR — "desktop with icon labels but no icons/panel"

One page. Full detail: `design/glycin-desktop-whiteout.md`.

## What you see

Session comes up: desktop icon *labels*, no icons, no panel, no theming.
**Applications still work** — that is part of the signature, not evidence against
it. Measured: `xfce4-panel` dies, `xfdesktop` / `xfwm4` / `Xvnc` survive.

## Why

Ubuntu 25.10+ (Resolute) decodes images via **glycin**, which runs its loaders
in `bwrap --unshare-all`. GTK treats a failed icon load as a **fatal assertion**
(`Bail out!`), so one unreadable icon kills the panel. Every missing icon falls
back to `image-missing.svg`, which is an SVG, which goes through glycin.

It is **bistable, not proportional** — glycin picks its sandbox by probing userns:

- **userns denied** → runs unsandboxed, decodes fine. Icons OK.
- **userns permitted** → commits to bwrap; any *later* bwrap failure is fatal.

So no custom seccomp = fine, and a *partial* profile = dead desktop.

## The three ways bwrap fails (read the errno!)

| symptom | cause | fix |
|---|---|---|
| `Failed to make / slave: Operation not permitted` (EPERM) | seccomp allows `unshare` but not the mount family — i.e. `chrome.json` | use `bwrap.json` |
| `Failed to make / slave: Permission denied` (EACCES) | docker-default AppArmor denies bwrap's mounts | add `apparmor=unconfined` |
| `loopback: Failed RTM_NEWADDR: Operation not permitted` | **host** `kernel.apparmor_restrict_unprivileged_userns=1` strips caps *inside* the new userns | **no run_config can fix this** — see below |

`chrome.json` is the *worst* option: it turns a healthy unsandboxed decode into a
crash.

## The fix (image side, host-independent)

`src/ubuntu/install/xfce/bwrap_dispatch.sh`, installed by `install_xfce_ui.sh` as
`/usr/bin/bwrap` with the real binary at `/usr/bin/bwrap.real`:

- target under `/usr/libexec/glycin-loaders/` → **passthrough** (strip flags, exec)
- anything else → **exec the real bubblewrap**
- `bwrap.real` missing → refuse, exit 127 (never silently downgrade a sandbox)

Origin: upstream wrote a blanket passthrough (`bwrap_wrapper.sh`, KASM-8257) but
staged it only in the `kali` branch and never activated it. Blanket passthrough is
wrong for us — `nix-bwrap-run` needs a REAL bwrap (`--overlay-src`) for
buildFHSEnv apps (onlyoffice, steam) — hence the dispatcher.

Measured on the CIS-hardened host (`restrict=1`), `bwrap.json + apparmor=unconfined`:

| | xfce4-panel | `Bail out!` | pixbuf warnings |
|---|---|---|---|
| stock | 0 — dead | 758 (crash loop) | 3 |
| + dispatcher | **1 — alive** | **0** | **0** |

**Trade-off:** glycin image decode runs unsandboxed. Same posture as any host
where userns is denied, but a real loss where the sandbox would have worked.

## What the dispatcher does NOT fix

On `restrict_unprivileged_userns=1` hosts, **FHS apps are broken regardless** —
they need genuine userns capabilities. Stock `only-office:nix` on the hardened
host: `bwrap: setting up uid map: Permission denied` ×98, app never starts. Flip
the sysctl to 0 and it starts (9 processes). Pre-existing, unrelated to the
dispatcher.

So for a hardened fleet you need **both**: the dispatcher (desktop) *and* one of
— `kernel.apparmor_restrict_unprivileged_userns=0`, or an AppArmor profile with a
working `userns` grant (our `kasm-app-bwrap` / `kasm-desktop` do **not** achieve
this yet).

## STIG gotcha

`workspaces-stigs` V-235812 greps `SecurityOpt` for the string `unconfined`, so a
correct `apparmor=unconfined` is reported as "seccomp unconfined". Remediating
that finding removes the option and lands you in the EACCES row. A named AppArmor
profile would clear this — unfinished work.

## Diagnosing in 10 seconds

```sh
# in any session:
bwrap --unshare-all --die-with-parent --chdir / --ro-bind /usr /usr --dev /dev /bin/true
# on the host:
sysctl kernel.apparmor_restrict_unprivileged_userns
docker inspect <c> --format '{{.HostConfig.SecurityOpt}}'   # want pivot_root + apparmor=unconfined
```

## Traps that wasted time here

- **Privileged DinD reproduces nothing** — no seccomp, AppArmor unconfined, so
  every variant looks healthy. Four hypotheses died this way.
- **Bare `docker run` reproduces nothing** — lands in the "default seccomp" row
  where glycin falls back.
- **`unshare -U true` is not a sufficient test.** It proves a namespace can be
  *created*; the restriction strips capabilities *inside* it. This is what made an
  earlier version of the analysis wrongly dismiss the host sysctl.
- **`/tmp` is `noexec` on the CIS host** — a bind-mounted wrapper cannot execute
  and the error mutates to "Could not spawn". Bake it into a layer.
- **`bridge: none` on the hardened daemon** — `docker build` `RUN` has no network;
  use `--network none`.
