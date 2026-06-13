# nix-ubuntu

A Kasm Workspaces core image (Ubuntu noble) with hooks to mount a
pre-built Nix store at `/nix` and activate one or more app profiles
(Chromium, OnlyOffice, VS Code, …) at session start.

For step-by-step build / run / extend instructions see
[`docs/nix-how-to.md`](../nix-how-to.md). For the architecture
rationale see [`design/nix-package-process.md`](../../design/nix-package-process.md).

The store itself ships as a **multi-layer OCI image** built by
`bin/build-nix-store-volume`. The runtime image is essentially
`kasmweb/core-ubuntu-noble` plus ~10 KiB of activation scripts; no
Nix is installed in the image. All apps live in the read-only `/nix`
volume.

## Quick start

```bash
# 1. Build the core image FIRST from this fork's dockerfile-kasm-core.
#    The upstream kasmweb/core-ubuntu-noble:develop is the bash-supervisor
#    flavour and is NOT compatible — see docs/nix-how-to.md for detail.
podman build -f dockerfile-kasm-core \
    --build-arg BASE_IMAGE=ubuntu:24.04 \
    --build-arg DISTRO=ubuntu --build-arg BG_IMG=bg_noble.png \
    -t localhost/kasm-core-ubuntu-noble:dev .

# 2. Build the store image (one-time, takes a while). Host arch is
#    detected automatically; pass --arch <amd64|arm64> to cross-build.
#    The default --tag interpolates the arch, so two parallel hosts
#    produce nix-store-amd64:dev and nix-store-arm64:dev
#    without colliding.
./bin/build-nix-store-volume --tag localhost/nix-store:v1

# 3. Build the runtime image:
podman build -f dockerfile-nix-ubuntu \
    --build-arg BASE_IMAGE=localhost/kasm-core-ubuntu-noble:dev \
    -t nix-ubuntu:v1 .

# 4. Run with two profiles activated (type=image mounts are RO by default):
podman run --rm -d --name nix-app \
    --mount type=image,source=localhost/nix-store:v1,destination=/nix \
    -e NIX_APP_PROFILES=chromium,onlyoffice \
    -e VNC_PW=password \
    -p 6901:6901 \
    nix-ubuntu:v1

# Open https://localhost:6901 (user: kasm_user, password: password).
```

The XFCE Whisker menu shows the activated apps under their normal
names (Chromium, OnlyOffice Document Editor, …). PATH includes each
activated profile's `bin/`, so `chromium` works in any terminal.

## Configuration

| Variable | Type | Description |
|---|---|---|
| `NIX_APP_PROFILES` | CSV | Profiles to activate at boot. Default empty. |

A per-user override file at `$HOME/.config/nix-app/active`
(one profile name per line) takes precedence over `NIX_APP_PROFILES`.
The user-facing `nix-app` CLI writes this file.

### Auto-activated dependencies

Profiles can declare `requires = [...]` in `bin/nix-profiles.toml`.
Activating a profile transitively activates anything in its `requires`
list. The current set:

| Profile | Requires |
|---|---|
| claude-code | node |
| opencode | node |
| codex | node |

So `-e NIX_APP_PROFILES=claude-code` is equivalent to
`-e NIX_APP_PROFILES=claude-code,node`. `nix-app activated` prints
auto-pulled profiles with a `(auto: required by another active profile)`
suffix; `nix-app deactivate node` while an AI CLI is active will leave
`node` in the effective set and tell you which profile is holding it.

## Volume mount syntax

| Runtime | Mount syntax |
|---|---|
| **Podman ≥ 4.0** | `--mount type=image,source=<ref>,destination=/nix` (read-only is the default; pass `rw=true` to override). |
| **Docker ≥ 28.0** | `--mount type=image,source=<ref>,target=/nix,readonly`. Note: Docker spells the optional subpath option `image-subpath`, podman calls it `subpath`. |
| **Kubernetes ≥ 1.33 (beta), GA in 1.36** | `volumes: [{ name: nix, image: { reference: <ref>, pullPolicy: IfNotPresent } }]` — auth uses the pod's `imagePullSecrets`. |
| **Older runtimes** | Use an init container that pulls the image and `cp -a`s `/nix/*` into an `emptyDir` or `hostPath`; the workspace container then bind-mounts that path. Sample manifest in `examples/k8s-extract-initcontainer.yaml` (TBD). |

## The `nix-app` CLI

Inside a running session:

```bash
nix-app list                     # profiles in the mounted /nix volume
nix-app activated                # currently-activated profile names
nix-app activate chromium        # add chromium (user view)
nix-app deactivate chromium      # remove chromium (user view)
nix-app info chromium            # closure paths and size
```

The CLI manages a per-user view at
`$HOME/.local/share/applications/nix-*.desktop` — no `sudo`
required. XFCE picks up the new shims without a restart. The
system-wide shims at `/usr/share/applications/nix-*` (set at
boot from `NIX_APP_PROFILES`) stay until next container restart.

To pick up CLI activations on `PATH` in the current shell:

```bash
source $HOME/.config/nix-app/profile.sh
```

New sessions inherit whatever `$HOME/.config/nix-app/active` contains
(via the boot-time activation), so user changes survive container
restarts when the home volume is persisted by Kasm's profile sync.

## Update cadence

The Nix store image is content-addressed, multi-layer:

```
Layer 0 (base):   common libs (glibc, openssl, X11, gtk, …)
Layer N-<prof>:   per-profile delta (one layer per profile)
Layer meta:       /nix/var/nix/db/db.sqlite + profile symlinks
```

Bumping the base nixpkgs ref re-emits every layer. Operator policy:

- **Base ref bumps** happen at nixpkgs stable release boundaries
  (~6 months). Document in `bin/nix-profiles.toml`'s `[nixpkgs].ref`.
- **Per-profile ref bumps** (e.g., Chromium tracks
  `nixpkgs-unstable`) re-emit only that profile's delta layer plus
  the meta layer. Set via `ref =` inside the
  `[profiles.<name>]` block.

Focused rebuilds (no config edit needed):

```bash
ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
./bin/build-nix-store-volume \
    --profile chromium \
    --tag kasmweb/nix-store-${ARCH}:chromium-2026-06-01
```

See `design/nix-package-process.md` for the rationale (why we don't
just bump the base ref on every Chromium release).

## Registry storage

Expected sizes (rough, varies with nixpkgs revision):

| Layer | Size (approx) |
|---|---|
| base | ~500 MiB |
| chromium | ~600 MiB (carries own libs due to `ref` override) |
| onlyoffice | ~600 MiB |
| vscode | ~400 MiB |
| obsidian | ~120 MiB (delta — Electron base shared with vscode) |
| angelfish | ~300 MiB (QtWebEngine closure) |
| claude-code | ~200 MiB (unstable ref) |
| opencode | ~200 MiB (unstable ref) |
| codex | ~50 MiB (unstable ref; Rust binary) |
| node (nodejs_22, pnpm, corepack) | ~80 MiB |
| python (python3, uv, pipx) | ~120 MiB |
| meta | ~50 MiB |
| **total** | ~2.9 GiB |

The AI CLIs (claude-code, opencode, codex) each carry a slice of
nixos-unstable's Node toolchain in their delta. Their closures share
those store paths via Nix content-addressing, but the layer-split
partitioning emits each unstable-Node copy into the profile that owns
it first — net result: ~150 MiB of duplication across the three AI
profiles. The auto-promote analyzer will flag this on every build
(see `nix-package-process.md` for the "unstable base" workaround).

User-installed packages (`npm i -g …`, `pipx install …`, `pip install --user …`)
land in `~/.local/share/{npm,pipx,python}/` — these paths are exported by
the activation script regardless of which profiles are active, so they
survive container restarts under Kasm's profile sync.

Layer dedup across image versions bounds the registry footprint over
time — bumping Chromium re-emits ~600 MiB rather than the whole image.

## Building without a /nix volume

The image is functional without the volume mounted. The activation
unit has `ConditionPathExists=/nix/var/nix/profiles/_meta.json`, so it
no-ops cleanly. The result is equivalent to `kasmweb/core-ubuntu-noble`
plus the unused activation tooling.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Activated app not in XFCE menu | gio trust failed; XFCE shows nothing for "untrusted" launchers | Check `/tmp/kasm-dbus.env` exists; ensure unit ordering puts `nix-activate.service` `Before=window-manager.service`. |
| `nix-app list` says `/nix volume not mounted` | Image volume not attached, or attached at the wrong destination | Confirm `--mount type=image,…,destination=/nix` not e.g. `/opt/nix`. |
| `nix` CLI on PATH but commands hang | `/nix/var` is read-only; SQLite WAL needs writable space | `nix-activate` should bootstrap `/run/nix-state`; check `/etc/profile.d/nix-app-state.sh` exists. |
| New profile in volume not visible via `nix-app list` | Stale container; mounted image hasn't been re-resolved | Restart the container. Image volume mounts don't update live. |
| Chromium update pulled the entire base layer | Forgot per-profile `ref` override; bumped `[nixpkgs].ref` instead | Set `ref = "github:NixOS/nixpkgs/nixos-unstable"` in `[profiles.chromium]`. |
