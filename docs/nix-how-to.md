# How to build, run, and extend nix-ubuntu

A practical guide. For the design rationale (why two-tier nixpkgs
pinning, multi-layer OCI image, etc.) see
[`design/nix-package-process.md`](../design/nix-package-process.md).
For the per-image Dockerhub-style description, see
[`docs/core-nix-ubuntu/README.md`](core-nix-ubuntu/README.md).

Three images make up the system. You always need the first two; the third
is for the single-app public catalog (optional, depending on topology):

| Image | Purpose | Built by |
|---|---|---|
| `nix-ubuntu` | Runtime base — ubuntu core + activation hooks | `dockerfile-nix-ubuntu` |
| `nix-store-<arch>` | Shared read-only Nix store (all profiles) | `bin/build-nix-store-volume` |
| `nix-<app>` (e.g. `nix-chrome`) | Self-contained single-app image | `bin/build-nix-store-volume --emit-app-images` |

**One pipeline, two topologies.** `bin/build-nix-store-volume` builds a single
partitioned Nix store and emits both shapes below from it — the base and shared
layers dedupe across the fat store and every per-app image. You run one build,
not two.

- **Shared store + thin images** (`nix-ubuntu` + mounted `nix-store-<arch>`):
  one store image mounted read-only at `/nix` across many thin `nix-ubuntu`
  containers. `NIX_APP_PROFILES` selects which apps activate at runtime.
  Best for multi-app desktop bundles. (Default output of the script.)

- **Baked per-app images** (`nix-<app>`): the app's store is baked in — no
  runtime mount. `FROM nix-ubuntu`, so the activation machinery is inherited.
  Best for the single-app public catalog; matches Kasm's one-image-per-workspace
  UX. (Emitted by `--emit-app-images`; see §1.4.)

> The standalone `dockerfile-nix-app` was the chrome/angelfish proof of
> concept. It still builds a single app, but bakes the whole closure as one
> un-shareable layer with no dedup — superseded by `--emit-app-images`. Use it
> only for a quick one-off outside the store pipeline.

---

## 1. Build for podman / docker / k8s

### 1.1 Build the core image first (the container-init base)

`nix-ubuntu` extends the core ubuntu image and drops a unit into
`/etc/container-init.d/` — a directory that only exists in core
images built from **this fork**'s `dockerfile-kasm-core` (which uses
the `container-init` PID 1 supervisor). The upstream
`kasmweb/core-ubuntu-noble:develop` from Dockerhub is the bash-
supervisor flavour and is **not** compatible. You must build the
core image locally first:

```bash
podman build -f dockerfile-kasm-core \
    --build-arg BASE_IMAGE=ubuntu:24.04 \
    --build-arg DISTRO=ubuntu \
    --build-arg BG_IMG=bg_noble.png \
    -t localhost/kasm-core-ubuntu-noble:dev .
```

This takes ~5–15 minutes depending on your runner (it pulls and
installs the whole desktop stack — KasmVNC, audio, webcam, etc.).
You only do this once per upstream sync.

For a faster smoke build that disables the heaviest install scripts,
the existing `runs/lean-noble-build.sh` does the same thing in ~5
minutes and tags as `localhost/kasm-noble-lean:latest`. Useful while
iterating; not what you'd ship.

### 1.2 Build the runtime image (nix-ubuntu)

```bash
# Same command works under podman or docker. Thin layer on top of the
# core image, finishes in seconds.
podman build -f dockerfile-nix-ubuntu \
    --build-arg BASE_IMAGE=localhost/kasm-core-ubuntu-noble:dev \
    -t nix-ubuntu:v1 .
```

For docker, substitute `docker` — the syntax is identical.

### 1.3 Build the store volume image

```bash
# Default tag interpolates the target arch automatically:
#   localhost/nix-store-amd64:dev   on x86_64 hosts
#   localhost/nix-store-arm64:dev   on aarch64 hosts (lima on macOS)
# So you can usually just run the script without --tag during dev:
./bin/build-nix-store-volume

# For a versioned tag, include the arch yourself so amd64 and arm64
# builds don't collide in your local store:
ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
./bin/build-nix-store-volume --tag localhost/nix-store-${ARCH}:v1
```

What this does, end-to-end:
1. Ensures a named podman volume `nix-build-stage-<arch>` exists
   (created on first run, cached between runs for Nix dedup speed-up).
2. Spins up a `nixos/nix:2.28.4` container with:
   - the named volume mounted at `/build` (where Nix stages everything)
   - your `bin/nix-profiles.toml` bind-mounted read-only at `/config/`
   - a small output dir bind-mounted at `/output/`
3. Inside the container: parses the TOML via `builtins.fromTOML`, runs
   `nix profile install` per profile into the named volume, partitions
   the resulting store into base + per-profile + meta layer-staging
   trees, and tars them into `/output/context.tar`.
4. Back on the host: feeds that context tar to `podman build -t $TAG -`
   over stdin. Podman unpacks and builds INSIDE its own filesystem
   (ext4 / case-sensitive on macOS+lima), producing the multi-layer
   OCI image in the host's local image store.

**Host requirements collapse to one thing: `podman` (or `docker`).** No
Python, no jq, no APFS sparseimage. The host filesystem only ever
touches one file related to the build — the context tar — and that's
a single byte stream, immune to case-sensitivity quirks. All Nix store
paths live inside the named volume (lima's ext4) throughout the build.

Expect ~30–60 minutes on the first build (Nix compiles a lot from the
binary cache; Chromium and the AI CLIs are the long poles). Subsequent
builds reuse the named volume's Nix store + binary cache and finish in
single-digit minutes for incremental changes.

Useful flags:

| Flag | Purpose |
|---|---|
| `--config FILE` | Use a custom TOML instead of `bin/nix-profiles.toml` |
| `--profile NAME` | Build only the named profile(s); ad-hoc bumps |
| `--arch amd64\|arm64` | Cross-arch via qemu-user (slow; prefer a native runner) |
| `--push REGISTRY` | After build, push the image to `<registry>/<tag>` |
| `--nix-image REF` | Override the `nixos/nix:<tag>` builder image |
| `--prune-stage` | Delete the cached `nix-build-stage-<arch>` volume after a successful build. Forces a clean rebuild next run. |
| `--keep-output` | Keep `~/.cache/nix-build-output/` after the build for forensics (the context tar etc.). Default behaviour deletes it. |

To wipe the cache without running a build:
```bash
podman volume rm nix-build-stage-arm64   # or -amd64
```

### 1.4 Build per-app baked images (`--emit-app-images`)

Per-app images are emitted from the store pipeline. They are self-contained (no
runtime `/nix` mount) and drop into the Kasm workspace catalog exactly like the
apt-based `kasmweb/chrome` image — but their base and shared layers dedupe with
the fat store and every other app, and they come from the *same* Nix store
(one fetch, not one per app).

Profiles come from `bin/nix-profiles.toml`. The base image (`nix-ubuntu`) must
already exist in your container store. The script builds each image directly
into the container engine's overlay store (copy-on-write, shared layer cache —
the base/shared layers are built once and reused), so no per-app tar is written.

> On a **containerd/nerdctl host** (no podman/docker engine — e.g. the Portal
> dev box), run the whole thing inside a privileged podman-in-podman container.
> The ready-made harness + runbook is in [`runs/nix-portal/`](../runs/nix-portal/README.md)
> (`dind-launch.sh` / `dind-check.sh` / `dind-push.sh`).

```bash
# Emit one image per selected profile (and the fat store as a side effect).
bin/build-nix-store-volume --emit-app-images --profile chrome --profile vlc
#  → localhost/nix-store/chrome:dev, localhost/nix-store/vlc:dev   (store-images)
#  → localhost/nix-chrome:dev,        localhost/nix-vlc:dev          (runnable)

# All profiles in the toml:
bin/build-nix-store-volume --emit-app-images
```

Useful flags: `--app-base-image REF` (default `localhost/nix-ubuntu:dev`),
`--app-repo REPO` (default `localhost/nix`), `--push REGISTRY`, `--arch`.

> **`requires` must be in the build set.** A profile with `requires = ["node"]`
> (e.g. the AI CLIs) needs `node` built too. `--profile claude-code --profile node`,
> or a full build (all profiles selected). Otherwise the app image is emitted
> *without* its required profile and the script warns.

**Per-app wiring** lives under `src/ubuntu/install/nix/<PROFILE_NAME>/`:

```
launch            — launcher: sets PROFILE path, execs nix-launch (maximise here)
custom_startup.sh — Kasm startup loop (LAUNCH_URL, APP_ARGS, DISABLE_CUSTOM_STARTUP,
                    and the docker-exec open contract -g/-a/-u)
post-build.sh     — optional: app-specific build step (managed policies, etc.)
```

The host finish build (`dockerfile-nix-app-finish`) copies these onto the
store-image. `chrome` and `angelfish` ship bespoke versions (browser URL
contract, QtWebEngine GPU quirks, maximise strategy); other apps fall back to a
generic template. Note the extension-point contract:

> **CEF / Electron apps** (OnlyOffice, Slack, VS Code, Discord, …) render in
> **software** on headless Xvnc via their bundled SwiftShader. Their launcher
> must keep the GPU *process* alive but point ANGLE at SwiftShader —
> `--use-gl=angle --use-angle=swiftshader` (NOT `--disable-gpu`, which kills the
> renderer so nothing paints), plus `QT_XCB_GL_INTEGRATION=none QT_OPENGL=software`
> for any Qt shell. See `src/ubuntu/install/nix/onlyoffice/launch` for the
> reference. Apps wrapped in a **bubblewrap FHS env** (`buildFHSEnv`: OnlyOffice,
> Steam) additionally require the **`bwrap.json`** seccomp profile, not
> `chrome.json` — see `docs/seccomp-how-to.md` § "FHS / bubblewrap apps".

- The **base** `nix-ubuntu` ships **no** `custom_startup.sh` — it stays the
  user's documented extension point (container-init runs it iff present).
- A **leaf** single-app image's `custom_startup.sh` *is* its launcher, and the
  Kasm agent invokes that path for `docker exec` opens — so single-app images
  occupy it (overriding it downstream = taking over the app, same as upstream).
- To add a background service without touching the launcher, drop a
  container-init unit at `/etc/container-init.d/<name>.service` (the advanced
  extension point).

**Adding to CI** — list the profile under the store-volume job's
`--emit-app-images` selection (no per-app dockerfile entry needed); add the
app's `changeFiles` for `src/ubuntu/install/nix/<name>/**` and the shared
launcher scripts.

#### Escape hatch: `dockerfile-nix-app` (one-off, no dedup)

For a quick standalone build of a single app *outside* the store pipeline — the
original chrome/angelfish PoC path. Bakes the whole closure as one un-shareable
layer; **not** for the catalog.

```bash
docker build -f dockerfile-nix-app \
    --build-arg NIX_ATTR=google-chrome \
    --build-arg PROFILE_NAME=chrome \
    --build-arg NIXPKGS_REV=ac62194c3917d5f474c1a844b6fd6da2db95077d \
    --build-arg GPU_SUPPORT=1 \
    --build-arg BASE_IMAGE=localhost/nix-ubuntu:dev \
    -t localhost/nix-chrome:dev .
```

### 1.5 Push to a registry (required for k8s, optional for local podman/docker)

```bash
ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
podman push localhost/nix-ubuntu:v1            registry.example.com/nix-ubuntu:v1
podman push localhost/nix-store-${ARCH}:v1     registry.example.com/nix-store-${ARCH}:v1
```

The store image is per-arch (separate amd64 and arm64 tags) — either
push two separate tags or set up a multi-arch manifest with
`podman manifest`. K8s pods can then reference whichever the node
supports.

The store image is hefty (~3 GiB total); the first push takes a while.
Subsequent pushes only emit changed layers — bump Chromium alone and
only its ~600 MiB layer crosses the wire.

### 1.6 Build a k8s deployment manifest

K8s 1.33+ supports OCI `image` volumes natively (GA in 1.36). For
older clusters, see [§5 troubleshooting](#5-troubleshooting) for the
init-container extraction fallback.

```yaml
# nix-demo.yaml
apiVersion: v1
kind: Pod
metadata:
  name: nix-demo
spec:
  containers:
    - name: kasm
      image: registry.example.com/nix-ubuntu:v1
      env:
        - name: NIX_APP_PROFILES
          value: "claude-code,vscode"
        - name: VNC_PW
          value: "password"
      ports:
        - containerPort: 6901
      volumeMounts:
        - name: nix-store
          mountPath: /nix
          readOnly: true
  volumes:
    - name: nix-store
      image:
        # Match the node's arch: -amd64 or -arm64 (or a multi-arch
        # manifest that points at both).
        reference: registry.example.com/nix-store-amd64:v1
        pullPolicy: IfNotPresent
```

`kubectl apply -f nix-demo.yaml` and connect to
`https://<node-ip>:6901`. Auth for private registries uses the pod's
`imagePullSecrets` — the same secret used to pull container images is
used for image-volume references too.

---

## 2. Run the image

The runtime image expects two things:
1. A read-only mount at `/nix` (any OCI image whose payload is a Nix store).
2. A list of profiles to activate, via env var or per-user file.

### 2.1 podman

```bash
ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
podman run --rm -d --name nix-app \
    --mount type=image,source=localhost/nix-store-${ARCH}:v1,destination=/nix \
    # If using chrome/chromium be sure to copy seccomp profile from [chrome.json](../src/common/seccomp/chrome.json)
    # to a location on host (e.g. `/etc/containers/seccomp/chrome.json`)
    # --security-opt seccomp=/etc/containers/seccomp/chrome.json \
    # For bubblewrap-FHS apps (OnlyOffice, Steam) use bwrap.json instead of
    # chrome.json (it also allows the mount family bubblewrap needs):
    # --security-opt seccomp=/etc/containers/seccomp/bwrap.json --security-opt apparmor=unconfined \
    -e NIX_APP_PROFILES=claude-code,vscode,angelfish,node,python,obsidian,chromium \
    -e VNC_PW=password \
    -p 6901:6901 \
    nix-ubuntu:v1
```

Note: `type=image` mounts are read-only by default; no need for an
explicit `readonly=true` or `rw=false`. (Podman 4.x rejects
`readonly=true` as an invalid option — the synonym was added in 5.x.)

Open `https://localhost:6901`, log in as `kasm_user` / `password`.
The activated apps appear in the XFCE Whisker menu, on the desktop,
and on `PATH` in any terminal.

### 2.2 docker

```bash
ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
docker run --rm -d --name nix-app \
    --mount type=image,source=localhost/nix-store-${ARCH}:v1,target=/nix,readonly \
    -e NIX_APP_PROFILES=claude-code,vscode,angelfish,node,python,obsidian \
    -e VNC_PW=password \
    -p 6901:6901 \
    nix-ubuntu:v1
```

Note: docker uses bare `readonly` (no `=true`) where podman uses `rw=false`
or just omits the flag (image mounts are read-only by default).

Note: docker uses `target=` where podman accepts both `destination=`
and `target=`. The two CLIs are otherwise interchangeable for this
workflow.

### 2.3 Specifying profiles via env vs config file

Two ways to declare which profiles are active at session start:

**Env var** (the simple path — set per-session by the orchestrator):

```bash
-e NIX_APP_PROFILES=claude-code,vscode
```

**Per-user config file** (the persistent path — survives container
restarts when Kasm's profile sync preserves the user's home):

```bash
# Inside the running container:
mkdir -p ~/.config/nix-app
printf 'claude-code\nvscode\n' > ~/.config/nix-app/active
# Re-apply (or restart the container):
sudo /usr/local/bin/nix-activate   # if running as kasm-user with sudo
```

The config file wins over `NIX_APP_PROFILES` when present. The
user-facing `nix-app` CLI writes this file:

```bash
$ nix-app activate claude-code
nix-app: activated claude-code.
  Also activated (transitive deps):
    - node
  Per-user .desktop shims dropped at $HOME/.local/share/applications/nix-*.
  PATH for the current shell: source $HOME/.config/nix-app/profile.sh

$ nix-app activated
claude-code
node   (auto: required by another active profile)
```

The CLI updates per-user `.desktop` files under
`~/.local/share/applications/` so XFCE picks them up without a
container restart. `PATH` updates require either a new shell or
sourcing `~/.config/nix-app/profile.sh` in the current one.

### 2.4 Running without a `/nix` mount

The image is functional with no volume — the activation unit's
`ConditionPathExists=/nix/var/nix/profiles/_meta.json` no-ops, and you get
a `kasmweb/core-ubuntu-noble` experience with unused activation
tooling sitting idle. Handy for `nix-app list` smoke checks before
attaching a real store image.

---

## 3. Build your own volume images

Two paths: edit the in-tree config, or use a custom config file.

### 3.1 Edit `bin/nix-profiles.toml`

Add a new section:

```toml
[profiles.my-tool]
pkgs = ["nixpkgs#my-tool", "nixpkgs#my-tool-extras"]
```

Then rebuild:

```bash
ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
./bin/build-nix-store-volume \
    --profile my-tool \
    --tag localhost/nix-store-${ARCH}:my-tool-v1
```

The `--profile my-tool` flag tells the build script to *only* build that
profile (plus the always-built `_base` and `bootstrap`). To rebuild
everything including the new profile, drop the `--profile` flag.

### 3.2 Use a custom config file

Useful when you don't want to commit your profile set to the repo:

```bash
./bin/build-nix-store-volume \
    --config /path/to/my-profiles.toml \
    --tag registry.example.com/team/nix-store:v1 \
    --push registry.example.com
```

Config schema:

```toml
[nixpkgs]
ref = "github:NixOS/nixpkgs/nixos-25.05"      # base nixpkgs pin

[base]
pkgs = [                                       # packages in the base layer
    "nixpkgs#glibc",
    "nixpkgs#openssl",
    ...
]

[promote]
threshold_percent = 80                          # auto-promote heuristic threshold

[profiles.<name>]
pkgs      = ["nixpkgs#package1", "nixpkgs#package2"]
ref       = "github:NixOS/nixpkgs/nixos-unstable"   # optional; overrides [nixpkgs].ref
requires  = ["other-profile"]                       # optional; transitive activation
platforms = ["amd64", "arm64"]                       # optional; restrict the arches built
```

### 3.3 Declaring dependencies

A profile can declare `requires = [...]` to pull in other profiles
automatically:

```toml
[profiles.my-cli]
pkgs     = ["nixpkgs#my-cli"]
requires = ["node", "python"]
```

When a user activates `my-cli`, both `node` and `python` get activated
too — they show up on `PATH`, in the launcher menu, and in the
`nix-app activated` output marked `(auto: required by another active
profile)`. Semantics mirror systemd's `Requires=`: deps are added
regardless of whether the user listed them. `nix-app deactivate node`
while `my-cli` is active is a soft no-op (the CLI tells you which
profile is still holding it).

The dep graph ships with the volume in `_meta.json`, so the consuming
image needs no recompile to learn about new dependencies.

### 3.3a Declaring platform support

Some nixpkgs packages ship only an x86_64-linux binary (no aarch64
upstream). The default policy is "build on every arch"; opt out for a
profile with the `platforms = [...]` field:

```toml
[profiles.onlyoffice]
pkgs      = ["nixpkgs#onlyoffice-desktopeditors"]
platforms = ["amd64"]    # arm64 has no upstream binary
```

When the build target is an arch not in the list, the inner script
logs `SKIP profile '<name>' — platforms=[…] does not include <arch>`
and proceeds without it. The other profiles still build normally. An
empty/missing list means "no restriction" (the default).

This is a build-time filter, not a runtime one — profiles skipped at
build time aren't in the volume at all. Users on an arm64 host don't
see onlyoffice in `nix-app list`.

### 3.4 Finding nixpkgs attribute names

The canonical search is at https://search.nixos.org/packages. For
top-level attributes you can also probe the repo directly:

```bash
gh api -X GET "/repos/NixOS/nixpkgs/contents/pkgs/by-name/${name:0:2}" \
    --jq "map(.name) | .[] | select(. == \"${name}\")"
```

(Two-letter prefix directory.) Packages defined in
`pkgs/top-level/all-packages.nix` aren't in `pkgs/by-name/`; the
search UI is the safer bet for those.

### 3.5 Per-profile `ref` override (update cadence)

By default a profile inherits `[nixpkgs].ref` (the slow-bumped base
pin, aligned to nixpkgs stable releases). For apps that ship faster —
Chromium and AI CLIs in this PoC — override to `nixos-unstable`:

```toml
[profiles.chromium]
pkgs = ["nixpkgs#chromium"]
ref  = "github:NixOS/nixpkgs/nixos-unstable"
```

Bumping the override re-emits only that profile's layer + the meta
layer — the base layer's digest stays stable across the bump. See
[`design/nix-package-process.md`](../design/nix-package-process.md)
§ "Update cadence" for the storage-vs-cadence trade-off.

---

## 4. Available profiles in the demo

Defined in `bin/nix-profiles.toml`. Activate any subset via
`NIX_APP_PROFILES=<csv>` or `nix-app activate <name>`.

| Profile | Packages | Ref | Requires | Platforms | Approx delta |
|---|---|---|---|---|---|
| `chromium` | `chromium` | nixos-unstable | — | any | ~600 MiB |
| `onlyoffice` | `onlyoffice-desktopeditors` | base | — | **amd64 only** | ~600 MiB |
| `vscode` | `vscode` | base | — | any | ~400 MiB |
| `obsidian` | `obsidian` | base | — | any | ~120 MiB (shares Electron base with vscode) |
| `angelfish` | `kdePackages.angelfish` | base | — | any | ~300 MiB (QtWebEngine closure) |
| `claude-code` | `claude-code` | nixos-unstable | `node` | any | ~200 MiB |
| `opencode` | `opencode` | nixos-unstable | `node` | any | ~200 MiB |
| `codex` | `codex` | nixos-unstable | `node` | any | ~50 MiB (Rust binary) |
| `node` | `nodejs_22`, `pnpm`, `corepack` | base | — | any | ~80 MiB |
| `python` | `python3`, `uv`, `pipx` | base | — | any | ~120 MiB |

Two internal profiles also ship in the volume but aren't user-selectable:
- `_base` — the common closure declared in `[base].pkgs`.
- `bootstrap` — the bundled `nix` CLI (so the image needs no Nix install).

---

## 5. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `nix-app list` says `/nix volume not mounted` | Mount destination wrong or image missing | Confirm `--mount type=image,…,destination=/nix` (podman) or `target=/nix` (docker). |
| Image volume mount not recognised | Runtime predates support | Podman ≥ 4.0, Docker ≥ 28.0, k8s ≥ 1.33 (beta). For older, use an init-container that `cp -a /nix/* /shared/` from the store image into an emptyDir, then bind-mount that. |
| Activated app missing from XFCE menu | gio trust race with WM startup | Restart the container, or run `xfce4-panel --restart` from a terminal. The activation script writes trust metadata via `gio set`; if `gvfsd-metadata` isn't ready, XFCE shows nothing for "untrusted" launchers. |
| `nix profile install` hangs in builder | macOS APFS case-insensitive store | If you're building on macOS host directly, use a case-sensitive APFS sparseimage for the staging dir (Nix ncurses paths collide). Or build inside a Linux VM (lima, etc.) — the script already runs Nix inside a Linux container, so this only bites if `--keep-staging` is on. |
| Auto-promote warnings on every build | Same store paths appear across many profiles | Edit `[base]` in your config to include them. Trade-off: bigger base layer for thinner profile deltas. See design doc § "Update cadence" caveat for the unstable-vs-base ref interaction. |
| `nix-app deactivate node` doesn't actually remove node | Another active profile `requires` it | Deactivate the parent first (e.g., `nix-app deactivate claude-code`). The CLI prints this when it happens. |
| Chromium update pulled the whole image | Bumped `[nixpkgs].ref` instead of `[profiles.chromium].ref` | Use the per-profile ref override; base ref only at nixpkgs stable releases. |
| `bwrap: Failed to make / slave: Operation not permitted` | FHS/bubblewrap app under `chrome.json` (mount family gated on `CAP_SYS_ADMIN`) | Run with `bwrap.json` seccomp instead — see `docs/seccomp-how-to.md` § "FHS / bubblewrap apps". |
| CEF/Electron app window stays 10×10 / blank, no content | Launcher passes `--disable-gpu`, killing the renderer process | Use `--use-gl=angle --use-angle=swiftshader` (keep the GPU process, software backend); see `src/ubuntu/install/nix/onlyoffice/launch`. |
| CEF app crash-loops at `gtk_init` (SIGSEGV / `int3 in libcef`) | Upstream app bug at the pinned version (e.g. OnlyOffice 9.0.0.172 null-derefs on an empty doc path) | Bump the per-profile `ref` to `nixos-unstable` for a newer build (OnlyOffice 9.1.0 fixed it); re-run the build once if it hits a nix profile file-collision (stale profile is pruned on the failed run). |

---

## See also

- [`design/nix-package-process.md`](../design/nix-package-process.md) — full architecture, update-cadence rationale, layer split mechanics.
- [`docs/core-nix-ubuntu/README.md`](core-nix-ubuntu/README.md) — Dockerhub-style per-image readme.
- [`bin/nix-profiles.toml`](../bin/nix-profiles.toml) — the canonical profile set.
- Nix package search: https://search.nixos.org/packages
- OCI image volumes: [Podman `--mount type=image`](https://docs.podman.io/en/latest/markdown/podman-run.1.html), [Docker 28+](https://docs.docker.com/engine/release-notes/28/), [k8s image volumes](https://kubernetes.io/docs/tasks/configure-pod-container/image-volumes/).
