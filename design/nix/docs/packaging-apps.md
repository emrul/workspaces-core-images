# Packaging Apps in Nix — Team Guide

For Kasm engineers who don't (yet) know Nix. The goal is to get you from "I
want app X in a workspace" to a working profile, and to make the
**custom-package decision** explicit.

> **Learn Nix, in order:** [nix.dev — first steps](https://nix.dev/),
> [package search](https://search.nixos.org/packages),
> [nixpkgs manual](https://nixos.org/manual/nixpkgs/stable/),
> [Nix language basics](https://nix.dev/tutorials/nix-language).
> You do **not** need to learn flakes to *add* an app — only to write a custom
> derivation. Most additions are a one-line TOML edit.

## Mental model (the 30-second version)

- A **package** in Nix is a *derivation* — a pure recipe producing an immutable
  output in `/nix/store/<hash>-<name>`. Same inputs ⇒ same hash ⇒ shareable.
- **nixpkgs** is the giant collection of these recipes. You refer to one by its
  *attribute path*, e.g. `chromium`, `vscode`, `kdePackages.angelfish`,
  `python3`, `nodejs_22`.
- A **profile** (Kasm sense, in `nix-profiles.toml`) is a named set of packages
  that become one selectable unit in a workspace.
- A package's **closure** is it + everything it transitively needs. That closure
  is what ships in a layer.

## The common case: add an app (no Nix authoring)

1. Find the attribute on <https://search.nixos.org/packages>. Note the exact
   attribute path (e.g. `obsidian`, `kdePackages.angelfish`).
2. Add a profile to [`bin/nix-profiles.toml`](../../bin/nix-profiles.toml):

   ```toml
   [profiles.my-app]
   pkgs = ["nixpkgs#my-app"]
   ```

3. Optional fields:

   ```toml
   ref       = "github:NixOS/nixpkgs/nixos-unstable"  # faster cadence than base
   requires  = ["node"]                                # transitive activation
   platforms = ["amd64"]                               # arch restriction
   ```

4. Build it:

   ```bash
   ./bin/build-nix-store-volume --profile my-app
   ```

5. Smoke-test headless (see [Headless GUI checklist](#headless-gui-checklist)).

That's the whole flow for ~90% of apps, because they're already in nixpkgs.

## When do you need a *custom* package?

Decision tree:

```
Is the exact app+version in nixpkgs (search.nixos.org)?
├─ yes → use the attribute. Done.
└─ no
   ├─ Is it in nixpkgs but the wrong version?
   │   ├─ A different channel/ref has the version → set per-profile `ref`. Done.
   │   └─ No channel has it → override the derivation's version/src (small custom).
   ├─ Is it a generic prebuilt Linux binary/AppImage/.deb?
   │   └─ Wrap it: `dockerTools`-style or `buildFHSEnv`/`autoPatchelfHook`
   │       /`appimageTools` (medium custom).
   └─ Is it proprietary / built from source with special flags?
       └─ Write a derivation (`stdenv.mkDerivation` or language builder)
           (full custom).
```

Rules of thumb:

- **Prefer nixpkgs + a `ref` override** over writing anything. A version you
  need is often one channel away.
- **Pinned versions**: nixpkgs gives you *a* version per channel. If you must
  hold an app at an exact version independent of the channel, that's a custom
  derivation overriding `version` + `src` (and its hash).
- **Closed-source / vendor binaries**: usually `autoPatchelfHook` (ELF) or
  `appimageTools.wrapType2` (AppImage) — you're patching an existing binary,
  not compiling.
- **FHS-assuming apps** (expect `/usr/lib/...`): `buildFHSEnv` gives them a fake
  FHS sandbox.

References:
[nixpkgs `mkDerivation`](https://nixos.org/manual/nixpkgs/stable/#sec-using-stdenv),
[overriding packages](https://nixos.org/manual/nixpkgs/stable/#chap-overrides),
[`autoPatchelfHook`](https://nixos.org/manual/nixpkgs/stable/#setup-hook-autopatchelfhook),
[`appimageTools`](https://nixos.org/manual/nixpkgs/stable/#sec-pkgs-appimageTools),
[`buildFHSEnv`](https://nixos.org/manual/nixpkgs/stable/#sec-fhs-environments).

## Where custom packages live (decision pending)

Deferred for a pros/cons discussion (see REQUIREMENTS "Open / Deferred" #2).
Two options:

| | **In-repo `pkgs/` flake** | **Separate `nix-apppkgs` overlay repo** |
|---|---|---|
| Pros | Lowest friction; one repo to clone/PR; derivation + image build reviewed together; simplest for a handful of packages | Reusable across products (core-images *and* workspaces-images, future repos); independent versioning/pinning; cleaner separation of "our packages" from build tooling |
| Cons | Couples package defs to *this* repo; harder to reuse from workspaces-images; grows clutter as the set expands | Extra repo + flake-input pinning to manage; cross-repo PR coordination; more Nix machinery for a team new to Nix |
| Best when | Custom set is small (≤ ~handful) and only this repo needs it | Custom set grows, or multiple repos consume it |

Leaning (not decided): **start in-repo `pkgs/`**, promote to an overlay repo if
the set grows or workspaces-images needs to consume it. Either way the TOML
stays the authoring surface — a custom package is referenced the same way
(`pkgs = ["kasm#my-app"]` vs `nixpkgs#…`), so migrating later is a reference
change, not a rewrite.

## Language runtimes & user package installs (Python/Node/…)

Users want a specific runtime version and the ability to install their *own*
packages at runtime. Design:

- **Runtime version selection** = profile choice. nixpkgs carries versioned
  attributes: `python311`/`python312`, `nodejs_20`/`nodejs_22`. Offer profiles
  per version (e.g. `python` → `python312`, or `python311` as its own profile).
- **User installs land in `$HOME`**, not the read-only store. The activation
  script exports prefixes so `npm i -g` / `pip install --user` / `uv` /
  `pipx` write under `~/.local`:
  - `NPM_CONFIG_PREFIX=$HOME/.local/share/npm`
  - `PIPX_HOME=$HOME/.local/share/pipx`
  - `PATH` includes `~/.local/bin`
- This pairs with **state persistence** (next section): a user's globally
  installed npm/pip tools survive sessions because `$HOME` is persisted.

Document for end users: "the runtime is provided by Nix (immutable, pinned);
your project/global packages install into your home and persist." See
`bin/nix-profiles.toml` `[profiles.node]` / `[profiles.python]` comments for the
current wiring.

## State persistence (Kasm storage mount)

Kasm can persist container paths via a storage mount — typically the user home
(`$KASM_OS_HOME`, default `/home/kasm-user`). Implications for Nix:

- **Persist `$HOME`**, not `/nix`. The store is immutable and re-supplied by the
  image/volume each session; persisting it would be wasteful and fight updates.
- Persisted across sessions: user-installed pip/npm packages (`~/.local`), app
  config/profiles (`~/.config`), and the per-user profile selection
  (`~/.config/nix-app/active`, which wins over `NIX_APP_PROFILES`).
- **Don't** persist absolute `/nix/store/...` paths into user config that a
  later store update invalidates; rely on the stable profile paths
  (`/nix/var/nix/profiles/<name>/bin`) the activation layer sets up.

## Headless GUI checklist

Apps that render to KasmVNC (no real GPU/EGL, no systemd) hit predictable
issues — preserve these (from PoC findings):

- **Electron / Chromium-based / QtWebEngine** (vscode, obsidian, angelfish,
  chromium): use the `nix-launch` wrapper — it drops Kasm's baked
  `LD_LIBRARY_PATH`, sets Qt/Chromium software-render env, disables the
  zygote/sandbox.
- **systemd probes** (e.g. Ptyxis `systemd-run --user --scope`): rely on
  container-init's `--systemd1-shim` no-op surface.
- **EGL-only apps** (e.g. `wezterm-gui`): won't work until KasmVNC exposes EGL;
  ship the CLI variant only.
- **FHS/bwrap apps that use OpenGL** (Steam, and any buildFHSEnv app that opens a
  GLX/GL context): the FHS rebinds `/usr`, so it can't see the host's GL driver.
  The driver reaches them the NixOS-standard way, via `/run/opengl-driver{,-32}`
  — see the Steam worked example below.
- **`.desktop` trust**: the activation layer must `gio set
  metadata::xfce-exe-checksum` the shims as the user before the WM enumerates
  them, or XFCE shows "untrusted launcher."

## Headless GPU / GLX for FHS apps — the Steam worked example

Getting Steam to run headless under KasmVNC took real digging; the mechanism and
the pitfalls generalise to any FHS/bwrap app that touches OpenGL, so they're
written down here rather than buried in the launcher.

**How the GL driver reaches a nix FHS app.** nixpkgs GL/Vulkan apps (including the
`steam` buildFHSEnv) resolve their driver from `/run/opengl-driver/lib` (64-bit) and
`/run/opengl-driver-32/lib` (32-bit) — on NixOS `hardware.graphics` populates that;
off NixOS it's what nixGL / nix-gl-host do. Our boot service
`src/ubuntu/install/nix/scripts/nix-gpu-setup` (unit `nix-gpu-setup.service`, baked
in `dockerfile-nix-ubuntu`) publishes it from the Kasm-injected host driver:
64-bit NVIDIA when a GPU is allocated, plus 32-bit **mesa (software llvmpipe)**
because the host has no 32-bit NVIDIA driver. It copies **real files** (`cp -Lf`),
not symlinks — the FHS rebinds `/usr`, so host-path symlinks would dangle, whereas
`/run` is bind-mounted through so real files there stay valid. The 32-bit block is
guarded by `[ -d /usr/lib/i386-linux-gnu/dri ]`, so it only fires on images that
installed i386 mesa (VGL images like Steam); 64-bit-only workspaces skip it.

**Steam does NOT need a GPU or VirtualGL to launch.** Steam's top-level client is
the legacy 32-bit VGUI2 process. It hard-requires a GLX visual at startup
(`glXChooseVisual` → fatal assert if none), but a **software** visual (llvmpipe) is
enough — exactly what stock apt steam uses on the same headless Xvnc. So the
launcher (`src/ubuntu/install/nix/steam/launch`) runs **plain `steam`, no `vglrun`**.
64-bit games still get real GPU acceleration the standard way: Steam's
pressure-vessel imports `/run/opengl-driver` as its graphics provider. (An earlier
approach that wrapped all of Steam in `vglrun` was a dead end — the VGL faker
mismatches the 32-bit client's ELF class and can't enable OpenGL on the software
backend. That whole saga was the wrong problem.)

**The actual bug we fixed** (commit 53c7c8f). Publishing the 32-bit mesa libs was
not enough: mesa's software megadriver (`libgallium`, the llvmpipe backend) needs
out-of-tree deps — chiefly `libLLVM`, plus `libsensors`, `libxshmfence`, and
libLLVM's own chain (`libstdc++`, `libedit`, `libffi`, `libtinfo`, `libxml2`,
`libz`, `libzstd`). Without them the 32-bit driver can't `dlopen`, so the client
still gets no visual and asserts. `nix-gpu-setup` now stages the megadriver's whole
recursive `.so` closure into `/run/opengl-driver-32/lib` (which is on the FHS's
`LD_LIBRARY_PATH`), **excluding the glibc family** — copying the base's glibc over
the FHS's nixpkgs glibc mixes ABIs and crashes (`__nptl_change_stack_perm` / vdso).

**Non-obvious debugging trap.** You cannot diagnose the missing deps with `ldd` run
on the host: there every dep resolves via the system i386 path, so `ldd` reports
"all resolved". Inside the FHS that system path is gone — run
`nix-bwrap-run <steam-run> ldd /run/opengl-driver-32/lib/libgallium-*.so` to see the
real `=> not found` list. That host-vs-FHS blind spot is why the fix stages the
whole closure rather than diffing what `ldd` claims is missing.

**Runtime cost / delay.** On first launch Steam downloads a ~500 MB client update
(Valve ships the client out-of-band into `~/.local/share/Steam`). It runs the
updater in windowless *console* mode, then self-restarts into the graphical UI — so
the screen looks blank for ~1 minute before the login window appears. This is
inherent Steam behaviour, unrelated to the GL fix. Mitigation: persist
`~/.local/share/Steam` via Kasm profile-sync (scope to `ubuntu12_32/` + `package/`,
exclude `steamapps/`) so the update happens once, not every session.

## Checklist for a new profile

- [ ] Attribute exists (search.nixos.org) or custom derivation written.
- [ ] `[profiles.<name>]` added; `ref`/`requires`/`platforms` set as needed.
- [ ] Builds on amd64 (and arm64 unless `platforms`-gated).
- [ ] Launches headless; `.desktop` shim trusted; binary `--version` works.
- [ ] README package table regenerated; `changeFiles` glob covers the new paths.
- [ ] If fast-moving (CVE cadence): `ref = nixos-unstable` + added to the
      nightly schedule.
