# Known issues

Tracked, understood problems in the Nix workspace images that are NOT yet fixed
in the shipped images — with the diagnosis and the intended fix, so we don't
re-investigate them from scratch. Each entry: symptom → root cause (evidence) →
why it's not fixed yet → the fix. Mostly surfaced by the app-assurance testbench
(`kasm-nix-testbench`).

---

## 1. Steam: ~100 s blank screen on first launch (client self-download)

**Symptom.** Launching the Steam workspace shows a blank desktop for ~100 s
before the sign-in window appears. It reads as "broken" and will generate
support tickets. Every *fresh* session hits it, not just the first ever.

**Root cause — it is NOT slow CEF; it's Steam downloading its own client.**
Timeline captured on `.140` (fresh profile, sign-in window at +71 s):

| Phase | Duration | Note |
|-------|----------|------|
| Download client (482 MB) | 34 s | from `client-update.steamstatic.com` |
| Extract package | 21 s | LZMA `.vz` archives |
| Restart + steamwebhelper → window | ~16 s | CEF itself ≈ 6 s |

nixpkgs' `steam` ships only the **bootstrap** (`steam.sh` + `steam-run` FHS),
not the ~482 MB client payload (`ubuntu12_32/steam`, `steamui`, `tenfoot`,
`resources`). On a fresh profile Steam reports `installed version 0`, then pulls
and extracts the whole client before it can draw anything. steamwebhelper (CEF)
itself starts in ~6 s once the client is present — as fast as our Chrome / VS
Code images. **So the fix is to pre-stage the client, not to speed up CEF.**

**Why persistence is not the answer (for shipping).** A persistent profile
(`persistent_profile_path`) would make the download a one-time cost per user,
but profile persistence is a per-deployment / per-customer choice — we can't
enable it as a default in the shipped image or registry entry. It also wouldn't
help brand-new users or ephemeral sessions.

### Spike results (2026-07-17, measured on `.140`)

Pre-staging the client into `~/.local/share/Steam` and relaunching, vs. today:

| What is pre-staged | Time to sign-in | Re-downloads? | Payload |
|--------------------|-----------------|---------------|---------|
| nothing (today)    | ~103 s          | yes (full)    | —       |
| `package/` only    | **38 s**        | **yes (delta)** + still extracts | ~484 MB |
| the **extracted** client (`ubuntu12_*`, `steamui`, `package/`, …) | **8 s** | **no** | ~1.3 GB compressed / ~2.4 GB on disk |

So the clean win (8 s, zero download) needs the **extracted** client baked. The
pure chrome-analog (fetch `package/` by hash, no execution) only reaches ~38 s
and still fetches a delta + extracts — not worth it. This is where "identical to
Chrome" breaks down: Chrome is one self-contained `.deb` nixpkgs builds; Steam's
usable client is a ~1.3 GB extracted runtime payload.

### Where it lives determines who it helps — and what it bloats

- **Single-app `steam:nix` image** launches Steam from its own baked home seed
  (`$HOME/kasm-default-profile`). Baking the client there helps this workspace
  and bloats only this image.
- **Select-apps desktops** mount the shared **fat store** (`nix-store:nix`) and
  activate Steam from it — they do NOT get the single-app image's home seed. To
  fix Steam *there*, the client would have to live in the nix store → the fat
  store → **every desktop mounts the ~1.3 GB, even users who never launch
  Steam.** That is the expensive path.

### Options (pick per appetite for bloat)

- **A — home-seed the extracted client into `steam:nix` only.** 8 s on the
  single-app workspace; ~1.3 GB on that image alone; **no fat-store bloat.**
  Select-apps desktops still download (rarer path; splash covers them). Produced
  by running Steam once under xvfb at build (it does the download+extract), then
  capturing `~/.local/share/Steam` (minus `logs`/`dumps`/`config`/`userdata`/
  `steamapps`/`appcache`) into the default profile. **Recommended** — best
  win-per-byte, contains the cost to the app that needs it.
- **B — bake into the nix store (fat store).** 8 s for single-app AND desktops,
  but ~1.3 GB in the shared store every desktop mounts regardless of use. Only
  justified if select-apps Steam becomes a first-class path. Worst bloat.
- **C — `package/`-only, chrome-style fetch (no execution).** ~484 MB, no xvfb
  step, but only ~38 s and still downloads a delta. Weakest; not recommended.
- **D — splash only (interim, already written).** Masks the blank; no speedup,
  no bloat. Ships regardless of A/B/C.

Any bake option needs a **frequent rebuild cadence** (twice-daily, like
chrome/discord) or the baked client goes stale and Steam re-downloads the delta.
For A/B the build step is the cost (run-at-build under xvfb, or a `.vz`
extractor); for C it's a manifest discoverer + N `fetchurl`s pinned by `sha2vz`
(`https://client-update.steamstatic.com/steam_client_ubuntu12` is a
machine-readable VDF of packages + hashes).

**Interim mitigation (written, not yet committed).** A lightweight "Steam is
starting…" splash (`src/ubuntu/install/nix/steam/launch`, zenity pulse that
auto-closes when Steam's window appears) so the blank period reads as progress,
not a hang. Does not make Steam faster — only removes the "looks broken"
perception until a bake option lands.

**Evidence / how to reproduce.** Run the steam image with
`--security-opt apparmor=unconfined --security-opt seccomp=<bwrap profile>
--gpus all`, then read `~/.local/share/Steam/logs/console-linux.txt` — the
`Downloading Update` → `Extracting package` → `Update complete, launching…`
sequence is the ~55 s. (testbench catch, 2026-07-17.)

---

## 2. FHS/bubblewrap apps (only-office, steam) don't start on hardened hosts

**Symptom.** On a host with `kernel.apparmor_restrict_unprivileged_userns=1`, a
buildFHSEnv app workspace never draws a window. The session comes up, the desktop
works, but the app is simply absent. Log fills with:

```
[custom-startup] bwrap: setting up uid map: Permission denied
```

Measured on a throwaway built from the SaaS host image
(`Kasm-Ubuntu 24.04 x86_64 - CIS Level 2 Hardened - Ver 2.2.4`), stock
`only-office:nix`, `security_opt = ["apparmor=unconfined", "seccomp=<bwrap.json>"]`:

| host sysctl | uid-map errors | app processes |
|---|---|---|
| `restrict_unprivileged_userns=1` (hardened default) | 98 | **0 — never starts** |
| `restrict_unprivileged_userns=0` | 0 | **9 — works** |

Nothing else changed between those two rows.

**Root cause.** nixpkgs wraps these apps in `buildFHSEnv`, so `nix-launch` →
`nix-bwrap-run` runs them under a **real** bubblewrap to give them a real
`/nix/store` under their FHS root. Ubuntu 23.10+ transitions any process that
creates an unprivileged user namespace *without an explicit AppArmor `userns`
grant* into a restricted profile, so bwrap does not hold the capabilities it needs
inside the namespace it just created — it fails at the uid map. `apparmor=unconfined`
does **not** exempt it: the transition still happens (this is the same host-level
mechanism that breaks glycin's icon loader, see `design/glycin-whiteout-tldr.md`).

**Not the same bug as the desktop whiteout, and not fixed by the same change.**
`bwrap_dispatch.sh` deliberately routes FHS apps to the real bwrap (a passthrough
would silently strip their FHS mount namespace, which is worse). Verified: with the
dispatcher installed the app still fails, with **0 dispatcher refusals** — dispatch
was correct, the real bwrap simply cannot run there.

**Why it's not fixed yet.** Both candidate fixes are host- or profile-side, not
image-side:

- **`kernel.apparmor_restrict_unprivileged_userns=0` on workspace hosts** (via
  `sysctl.d`). Measured working. Cost: re-enables unprivileged userns host-wide,
  which is the protection CIS added — needs sign-off, and it is a fleet-wide
  posture change we cannot make from an image.
- **An AppArmor profile carrying a working `userns` grant**, applied as
  `apparmor=kasm-app-bwrap` instead of `unconfined`. This is the right long-term
  answer and would also clear the `workspaces-stigs` V-235812 false positive
  (it greps `SecurityOpt` for the string `unconfined`). **Our current profiles do
  not achieve it** — measured on the hardened host: `kasm-app-bwrap` still fails
  EACCES at `make / slave`, and `kasm-desktop` denies namespace creation outright.
  Unfinished work, not a setting.

**Scope.** Every `seccomp = "bwrap"` profile in `bin/nix-profiles.toml` that is an
FHS wrapper — `only-office`, `steam` (`steam-run`), and anything else built with
`buildFHSEnv`. Chromium/Electron apps are unaffected: `nix-launch` runs them with
`--no-sandbox`, so they need no userns.

**Evidence / how to reproduce.** On a `restrict=1` host:

```sh
sysctl kernel.apparmor_restrict_unprivileged_userns          # expect 1
docker run -d --name oo --shm-size=1g -p 6901:6901 \
  --security-opt seccomp=src/common/seccomp/bwrap.json \
  --security-opt apparmor=unconfined -e VNC_PW=password \
  registry.gitlab.com/.../only-office:nix
docker logs oo 2>&1 | grep -c "setting up uid map"           # expect >0
docker exec oo pgrep -fc DesktopEditors                      # expect 0
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 # then relaunch: works
```

(Found 2026-07-29 while validating the glycin desktop fix on the real SaaS host
image.)
