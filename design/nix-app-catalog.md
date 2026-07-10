# Nix-ifying the application catalog

Status: proposal / in progress
Scope: `workspaces-images` (the single-app + desktop image catalog) and a
boundary decision for `workspaces-core-images` (the core/distro layer).

This doc complements [`nix-package-process.md`](./nix-package-process.md)
(which covers the build orchestration, layer/dedup strategy, and pinning
cadence) and the user-facing [`../docs/nix-packaging-apps.md`](../docs/nix-packaging-apps.md)
(Option A binary repackaging vs Option B source build). Read those first
for the *how*; this doc is the *what* and *which*.

---

## TL;DR

- **The app catalog is the place Nix pays off — not the core image.** Today
  ~80 app/desktop images each re-install overlapping apps via apt/vendor
  repos. Nix collapses that into a shared store (or thin baked single-app
  images) with one pinned, reproducible package set.
- **Most apps are already in nixpkgs.** Of ~55 genuine applications in the
  catalog, ~45 map to an existing nixpkgs attribute — a one-line entry in
  `bin/nix-profiles.toml`, no Nix code. Only ~6 need a custom derivation
  (kasmvnc-style binary repackage); a handful are dropped or stay apt.
- **The core image stays apt-based.** Nix-ifying the desktop/VNC/X stack or
  the language-pack bloat is high-effort, high-risk, and would make the
  image *larger*, not smaller (Nix shares nothing with the base OS). The
  language-pack/locale bloat is a cleanup problem (drop unused locales,
  fonts, docs), not a packaging problem. See [Core image: out of scope](#core-image-out-of-scope).
- **Composition model already exists.** `nix-profiles.toml` is the "menu":
  flat `[profiles.<app>]` sections, a shared `[base]` layer, a `requires`
  dependency DAG, and per-profile `ref` pins. That is the import mechanism;
  true per-app Nix overlays remain a documented Phase-2 item.

---

## Why the app layer and not the core

Nix's size win is **cross-image deduplication via a shared `/nix` store**, not
shrinking any single image. A Nix `glibc` + GTK + X11 closure is usually
*larger* than the distro's apt packages because Nix deliberately shares
nothing with the base OS.

- A **core image** sits at the bottom of every tree with nothing to dedup
  against — Nix would only inflate it.
- The **app catalog** is ~80 images repeatedly installing the same ~55 apps.
  That repetition is exactly what a shared store amortizes. One pinned set,
  one rebuild path, registry-level layer reuse.

So the boundary the `nix-ubuntu` design already drew is the right one:

```
  distro + desktop + KasmVNC + container-init   →  apt, one chosen base (ubuntu)
  applications                                  →  Nix, layered on top
```

---

## The app catalog

The authoritative source is the `src/ubuntu/install/<app>/` tree in
`workspaces-images`. The table below classifies every app-bearing directory.
Pure infrastructure dirs (`certificates`, `cleanup`, `gtk`, `langpacks`,
`misc`, `mobile`, `smb`, `tools`, `vpn`, `dind*`, `lsyncd`,
`gamepad_utils`, `terminal`, `close_browser_breakout_*`) and base-distro /
toolkit images (`kali`, `parrot`, `remnux`, `tracelabs`, `forensic_osint`)
are **N/A** — they're not single applications and stay as-is.

### Plan legend

- **nixpkgs** — add a `[profiles.<name>]` entry pointing at an existing
  nixpkgs attribute. No Nix code.
- **nixpkgs (GPU)** — in nixpkgs, but needs a VirtualGL-aware launcher
  (the `angelfish-launch` pattern) for GPU acceleration.
- **nixpkgs (special)** — in nixpkgs but with runtime caveats (FHS env,
  i386 multilib, kernel features).
- **custom** — not in nixpkgs (or unusable form); needs a `nix/pkgs/<app>/`
  derivation, Option A binary repackage. Tracked in the flake.
- **keep apt / drop** — proprietary-licensed, EOL, or not worth Nix-ifying.

> Attribute names marked **(verify)** should be confirmed with
> `nix search nixpkgs <name>` against the pinned ref before wiring — package
> names drift between releases and a few are best-effort from memory.

| App (install dir) | Current install method | Plan | nixpkgs attribute | Notes |
|---|---|---|---|---|
| firefox | apt + Mozilla PPA | nixpkgs | `firefox` | |
| chromium | apt | nixpkgs | `chromium` | already in TOML; on unstable for cadence |
| chrome | vendor .deb/.rpm | nixpkgs | `google-chrome` | unfree |
| brave | vendor apt repo | nixpkgs | `brave` | unfree |
| vivaldi | vendor apt repo | nixpkgs | `vivaldi` | unfree |
| edge | vendor .deb | nixpkgs | `microsoft-edge` | unfree |
| torbrowser | tarball | nixpkgs | `tor-browser` | |
| thunderbird | apt | nixpkgs | `thunderbird` | |
| libre_office | LibreOffice PPA | nixpkgs | `libreoffice` | large closure |
| only_office | vendor .deb | nixpkgs | `onlyoffice-desktopeditors` | already in TOML; amd64-only |
| gimp | AppImage | nixpkgs | `gimp` | GIMP 3 |
| inkscape | inkscape PPA | nixpkgs | `inkscape` | |
| pinta | apt | nixpkgs | `pinta` | |
| blender | tarball | nixpkgs (GPU) | `blender` | VirtualGL |
| vlc | apt | nixpkgs | `vlc` | |
| audacity | apt | nixpkgs | `audacity` | |
| obs | apt | nixpkgs | `obs-studio` | GPU-adjacent |
| slack | vendor .deb | nixpkgs | `slack` | unfree |
| discord | vendor .deb | nixpkgs | `discord` | unfree |
| signal | vendor apt repo | nixpkgs | `signal-desktop` | |
| telegram | tarball | nixpkgs | `telegram-desktop` | |
| zoom | vendor .deb | nixpkgs | `zoom-us` | unfree; amd64-only |
| teams | vendor .deb | nixpkgs | `teams-for-linux` | MS discontinued native; teams-for-linux is the live option |
| vs_code | vendor .deb | nixpkgs | `vscode` | already in TOML; unfree (`vscodium` = free alt) |
| sublime_text | vendor apt repo | nixpkgs | `sublime4` | unfree |
| atom | PackageCloud PPA | drop | — | EOL since 2022; removed from nixpkgs. Recommend retiring the image |
| insomnia | vendor .deb | nixpkgs | `insomnia` | |
| postman | tarball | nixpkgs | `postman` | unfree |
| obsidian | AppImage | nixpkgs | `obsidian` | already in TOML; unfree |
| nextcloud | vendor | nixpkgs | `nextcloud-client` | |
| owncloud | vendor | nixpkgs | `owncloud-client` (verify) | |
| remmina | apt | nixpkgs | `remmina` | |
| filezilla | apt | nixpkgs | `filezilla` | |
| deluge | apt | nixpkgs | `deluge` | |
| qbittorrent | qbittorrent PPA | nixpkgs | `qbittorrent` | |
| ansible | apt/pip | nixpkgs | `ansible` | CLI |
| terraform | vendor | nixpkgs | `terraform` | unfree (`opentofu` = free alt) |
| eclipse | tarball | nixpkgs | `eclipses.eclipse-java` (verify) | |
| android_studio | vendor binary | nixpkgs | `android-studio` | unfree; large |
| spiderfoot | pip/source | nixpkgs | `spiderfoot` (verify) | OSINT |
| steam | `steam-installer` + i386 | nixpkgs (special) | `steam` | FHS env, GPU, i386 |
| wine | WineHQ repo + i386 | nixpkgs (special) | `wineWowPackages.stable` | i386 multilib |
| retroarch | PPA | nixpkgs (GPU) | `retroarch` | VirtualGL |
| minetest | apt | nixpkgs (GPU) | `luanti` (was `minetest`) | VirtualGL |
| super_tux_kart | GitHub tarball | nixpkgs (GPU) | `superTuxKart` | VirtualGL |
| zsnes | apt + i386 | nixpkgs (special) (verify) | `zsnes` | i386; may be dropped upstream |
| doom | varies | nixpkgs (verify) | `chocolate-doom` / `crispy-doom` | confirm which "doom" the image ships |
| unityhub | vendor apt repo | nixpkgs | `unityhub` | unfree |
| realvnc_vncviewer | proprietary | nixpkgs (verify) | `realvnc-vnc-viewer` | unfree; confirm attr exists |
| nessus | Tenable .deb (API) | custom | — | proprietary; binary repackage from pinned download |
| maltego | vendor .deb (API) | custom | — | proprietary; not in nixpkgs |
| hunchly | vendor .deb | custom | — | proprietary OSINT |
| keeper | proprietary | custom / keep apt | — | proprietary password manager |
| horizon (vmware) | proprietary client | keep apt | — | licensing + heavy system integration |
| zoho_email | electron wrapper | custom / drop | — | thin web wrapper; low value |
| cyberbro | Firefox-derived Kasm build | custom | — | derive from the `firefox` profile + config overlay |
| redroid | git clone + meson (scrcpy) | keep apt / special | — | needs host kernel modules (binder/ashmem); not a clean Nix target |

### Counts

| Bucket | Count |
|---|---|
| nixpkgs (incl. GPU/special) | ~45 |
| custom derivation | ~6 |
| keep apt / drop | ~4 |
| **Total genuine apps** | **~55** |

The takeaway: the bulk of the migration is **TOML entries, not Nix code**.
The custom-derivation work is a small, bounded tail that reuses the existing
`nix/pkgs/kasmvnc` pattern.

---

## Managing a set of apps (and the "imports" question)

The composition machinery already exists in `bin/nix-profiles.toml`; it is
the import/menu system. There is no Nix-expression `import` syntax by
design — operators edit TOML, not Nix.

```toml
[nixpkgs]
ref = "github:NixOS/nixpkgs/nixos-25.05"   # base pin; bump ~6-monthly

[base]
pkgs = [ "nixpkgs#glibc", "nixpkgs#gtk3", ... ]   # shared OCI layer

[profiles.slack]
pkgs = ["nixpkgs#slack"]

[profiles.claude-code]
pkgs     = ["nixpkgs#claude-code"]
ref      = "github:NixOS/nixpkgs/nixos-unstable"   # per-profile cadence
requires = ["node"]                                # dependency DAG
```

Three composition levers, all already implemented:

1. **`requires` DAG** — the closest thing to "imports": activating
   `claude-code` transitively pulls `node`. Resolved at boot by `nix-activate`
   and mid-session by `nix-app activate`.
2. **`[base]` shared layer** — common closure lives in one OCI layer,
   dedup'd across every profile.
3. **Per-profile `ref`** — fast-moving apps (browsers, AI CLIs) ride
   `nixos-unstable` while the base stays on a stable release; only that
   profile's delta layer churns.

For custom (non-nixpkgs) apps, the second composition layer is `nix/flake.nix`:
the derivation is exposed there and referenced from TOML as `path:./nix#name`
(dev) or `git+https://…#name` (prod) — see `docs/nix-packaging-apps.md`.

What does **not** exist yet: per-app Nix **overlays** to dedup libraries
*across* different nixpkgs refs (e.g. Chromium-on-unstable reusing the base
ref's glibc). That is the explicit Phase-2 item in `nix-package-process.md`.
It is an optimization, not a blocker — the catalog works without it.

### Image topology — the one real decision

Two viable models, not mutually exclusive:

- **Shared store + thin images** (store's design intent): one
  `nix-store-<arch>` volume mounted read-only across many thin
  `nix-ubuntu`-based images. Maximum dedup; one rebuild propagates
  everywhere. **Best for the multi-app desktop images** (`*-desktop`,
  `desktop-deluxe`) — those ~14-app bundles become "activate profiles
  X,Y,Z" instead of 14 apt installs.
- **Self-contained single-app baked image** (`dockerfile-nix-app` template):
  bake one profile's `/nix` into the image at build time, no runtime mount.
  **Best for the public single-app catalog** — matches Kasm's "one
  workspace = one image" UX and needs no orchestration changes.
  See `design/nix-package-process.md` § "Component 3" for the template
  build-arg reference and per-app file convention.

Recommendation: baked single-app images (`dockerfile-nix-app`) for the public
catalog; shared-store (`build-nix-store-volume` + thin `nix-ubuntu`) for
internal/desktop bundles where dedup pays off.

---

## Phasing

1. **Phase 1 — stock nixpkgs apps (days).** Add the ~45 in-nixpkgs apps as
   profiles (draft already in `bin/nix-profiles.toml`). Build the store and
   smoke-test a representative spread per runtime class: one Electron app
   (Slack), one Qt app (already have Angelfish), one GTK app (GIMP), one GPU
   app (Blender), one CLI (ansible), one FHS-special (Steam). This validates
   the activation/launch wiring at catalog scale, not just one app.
2. **Phase 2 — custom derivations (bounded).** The ~6 binary-repackage
   targets (Nessus, Maltego, Hunchly, etc.) under `nix/pkgs/<app>/`, reusing
   the kasmvnc pattern. Wire each into the flake + a TOML profile.
3. **Phase 3 — topology rollout.** Cut the multi-app desktop bundles over to
   the shared store; publish baked single-app images for the standalone
   catalog using `dockerfile-nix-app`. Build steps for both are in
   `docs/nix-how-to.md` §§ 1.3–1.4. Decide per-image based on the topology
   guidance above.
4. **Phase 4 (optional) — overlays.** Tackle cross-ref library dedup if
   registry footprint becomes a concern (per `nix-package-process.md`).

### Per-runtime-class caveats to carry forward

- **GPU apps** (Blender, RetroArch, Luanti, SuperTuxKart, OBS): need the
  `angelfish-launch`-style gate — `vglrun -d $KASM_EGL_CARD` when a GPU is
  allocated and the device nodes are user-owned, else software fallback.
- **i386 / multilib** (Steam, Wine, ZSNES): use `pkgsi686Linux` /
  `wineWowPackages`; Steam additionally needs its FHS env wrapper (nixpkgs
  provides `steam` as an FHS-wrapped derivation already).
- **Steam specifically does NOT need a GPU or VirtualGL** — despite living in the
  GPU/i386 buckets above. Its 32-bit VGUI2 client only needs a *software* GLX
  visual (llvmpipe), like stock apt steam. The launcher runs plain `steam` (no
  `vglrun`); 64-bit games get the GPU via pressure-vessel importing
  `/run/opengl-driver`. The one requirement is that `nix-gpu-setup` stage the full
  32-bit mesa software-driver closure (incl. `libLLVM`) into `/run/opengl-driver-32`
  — see the Steam worked example in `design/nix/docs/packaging-apps.md`.
- **arm64 gaps**: several vendor binaries are x86_64-only in nixpkgs
  (Zoom, OnlyOffice already flagged). Use the TOML `platforms = ["amd64"]`
  key to skip them on arm64 builds rather than failing.
- **Unfree**: Chrome, Edge, Brave, Vivaldi, Slack, Zoom, VS Code, Sublime,
  Postman, Obsidian, Terraform, Unity Hub, Android Studio. The build script
  already exports `NIXPKGS_ALLOW_UNFREE=1` — no per-app config needed.

---

## Core image: out of scope

Explicitly **not** part of this plan: Nix-ifying the core images or the
language-pack bloat. Reasoning:

1. **Nix doesn't shrink a single image.** A core image has nothing to dedup
   against; a Nix closure of the X/desktop stack would be larger than the
   apt equivalent.
2. **The DE/VNC/X stack is deeply system-integrated** (PAM, container-init
   units, `/etc` wiring). Nix-ifying it approaches "become NixOS" — large
   effort, high risk, fights the multi-distro abstraction.
3. **Language-pack bloat is a cleanup problem, not a packaging problem.**
   The win is *removing* unused locales, per-language fonts, and man/doc
   trees in the install/cleanup layer (`locale-gen` only the needed locales,
   prune `language-pack-*`). A few lines in the install scripts; Nix adds
   nothing here. Worth a separate, cheap pass — quantify with a
   `dive`/layer-size audit first.

A marginal future candidate is Nix-ifying Kasm's own fetched components
(`kasm_squid_adapter`, `profile-sync`, the Go helpers) for reproducibility,
but they're small and already pinned — low payoff, not prioritized.
