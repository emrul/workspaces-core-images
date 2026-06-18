# Building the Nix images

How the Nix app images are built **today** (manual / local-dev, the realised
PoC), and how that maps to the **CI/CD target**. This is the practical companion
to the design docs:

- [`build-pipeline.md`](docs/build-pipeline.md) — CI/CD target-state design (layer
  dedup, caching, nightly cadence, multi-arch).
- [`build_plan.md`](docs/build_plan.md) — milestone sequencing (M0–M7).
- [`docs/handover.md`](docs/handover.md) — current running state + GPU recipe.
- [`LIMITATIONS.md`](LIMITATIONS.md) — QtWebEngine WebGL / GPU caveats.
- [`docs/demo-environment-setup.md`](docs/demo-environment-setup.md) — one-time host setup.

> **Status:** PoC. Builds are run by hand on a dev/GPU host; images use `:dev` /
> `:spike` tags and a local registry (`localhost:5000`). None of this is wired
> into GitLab CI yet — that's the target state in the second half of this doc.

---

## Current state — building today

### The image stack

```
ubuntu:24.04
  └─ dockerfile-kasm-core            → kasm-core-ubuntu-noble:dev   (apt core: KasmVNC, container-init, XFCE)
       └─ dockerfile-nix-ubuntu      → nix-ubuntu:dev               (thin Nix runtime base: + nix-activate/launch/gpu-run)
            ├─ nix/flake.nix         → nix-<app>-run:spike, nix-fat-run:spike   (nix2container; chrome/chromium/vscode/firefox/audacity)
            └─ dockerfile-nix-angelfish → nix-angelfish:dev         (self-contained single-app, baked /nix store)

bin/build-nix-store-volume + bin/nix-profiles.toml → OCI /nix store image (the "fat / shared-store" model, mounted at /nix)
```

Two delivery shapes coexist:
- **Baked** — the app's `/nix` closure is inside the image (`nix-<app>-run`,
  `nix-angelfish`). Self-contained; no store mount needed.
- **Shared store** — one OCI store image mounted read-only at `/nix` across thin
  `nix-ubuntu` containers; apps selected at runtime via `NIX_APP_PROFILES`.

### Prerequisites (one-time, see demo-environment-setup.md)
- Docker + Nix (flakes enabled).
- `localhost/kasm-core-ubuntu-noble:dev` built (the apt core).
- A local registry at `localhost:5000` (the flake pulls the base from it).
- Host sysctl for Chrome's userns sandbox:
  `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`.
- For GPU: an NVIDIA host with the nvidia container runtime (see the GPU section).

### 1. The apt core (existing process)
Standard core build — unchanged by the Nix work:
```sh
docker build -f dockerfile-kasm-core \
  --build-arg BASE_IMAGE=ubuntu:24.04 --build-arg DISTRO=ubuntu \
  --build-arg BG_IMG=bg_kasm.png \
  -t localhost/kasm-core-ubuntu-noble:dev .
```

### 2. The thin Nix runtime base (`nix-ubuntu`)
Adds the container-init Nix units + `nix-activate` / `nix-launch` / `nix-gpu-run`
on top of the core. The flake's runnable images use this as `fromImage`, so it
must be pushed to the local registry and its manifest captured:
```sh
docker build -f dockerfile-nix-ubuntu \
  --build-arg BASE_IMAGE=localhost/kasm-core-ubuntu-noble:dev \
  -t localhost/nix-ubuntu:dev .
docker tag localhost/nix-ubuntu:dev localhost:5000/nix-ubuntu:dev
docker push localhost:5000/nix-ubuntu:dev
nix shell nixpkgs#skopeo --command \
  skopeo inspect --raw --tls-verify=false \
  docker://localhost:5000/nix-ubuntu:dev > nix/base-manifest.json
```
`nix/base-manifest.json` is a **generated, environment-specific** artifact
(gitignored — it pins *your* locally-built base). See "base image pinning" below.

### 3. Per-app + fat images (the flake / nix2container)
`nix/flake.nix` builds the 5-app demo set (chrome, chromium, vscode, firefox,
audacity) in two flavours:
- `.#<app>` / `.#fat` — dedup-proof images (no base; used to **measure** layer
  sharing).
- `.#<app>-run` / `.#fat-run` — **runnable** (`fromImage = nix-ubuntu`, generated
  `/nix/var/nix/profiles` tree, boots a KasmVNC desktop).

Because the runnable images read the base manifest path from an env var under
`--impure` (see below):
```sh
export NIX_UBUNTU_BASE_MANIFEST="$PWD/nix/base-manifest.json"   # absolute path
cd nix
nix build --impure .#chrome-run -L
nix run   --impure .#chrome-run.copyToDockerDaemon              # → nix-chrome-run:spike
```
Or the whole demo in one shot (build all + dedup proof + launch on 6902/6903):
```sh
bash runs/nix-demo.sh
```

### 4. Single-app baked image (`nix-angelfish`)
Self-contained: stage 1 builds the app profile into a `/nix` store with
`nix-env`; stage 2 (`FROM nix-ubuntu`) bakes it in and wires the single-app XFCE
profile. The model for a public single-app catalog entry:
```sh
docker build -f dockerfile-nix-angelfish -t nix-angelfish:dev .
```
(Angelfish is QtWebEngine → software-only, no WebGL — see `LIMITATIONS.md`. A
chromium-based single-app image would follow the same Dockerfile shape but gets
GPU WebGL.)

### 5. OCI `/nix` store image (shared-store model)
`bin/build-nix-store-volume` reads `bin/nix-profiles.toml` and emits a
multi-layer OCI image that is the Nix store (base layer + one delta layer per
profile + a meta layer with the `/nix/var/nix/profiles` tree and `_meta.json`):
```sh
bin/build-nix-store-volume                 # → the store image (per nix-profiles.toml)
```
Consume it by mounting at `/nix` and selecting apps:
```sh
docker run --mount type=image,source=<store-image>,target=/nix,readonly \
  -e NIX_APP_PROFILES=chrome,vscode -e VNC_PW=password -p 6901:6901 nix-ubuntu:dev
```

### GPU acceleration (what's baked, when it engages)
The runnable flake images and the OCI store carry a **`_gpu` support profile**
(`virtualgl` + `vulkan-loader`) at `/nix/var/nix/profiles/_gpu`, and the base
ships `/usr/local/bin/nix-gpu-run`. At launch, `nix-launch` routes
**standalone chromium-family** apps through `nix-gpu-run` (Nix VirtualGL
`vglrun -d egl` + Nix vulkan-loader + a narrow `/opt/nvgl`) **only when a GPU is
allocated** (nvidia runtime + `/dev/dri` nodes chowned to the session user +
`KASM_EGL_CARD`/`KASM_RENDERD`). Then `chrome://gpu` shows
`ANGLE (NVIDIA, Vulkan … RTX 3090)`; otherwise it falls back to SwiftShader.
Full recipe: team memory `nix-gpu-webgl-recipe` + `docs/handover.md`.

Run a baked image with a GPU (mirrors the Kasm agent's run config):
```sh
docker run -d --runtime=nvidia \
  -e NVIDIA_VISIBLE_DEVICES=<gpu-uuid> -e NVIDIA_DRIVER_CAPABILITIES=graphics,display,utility \
  --device /dev/dri/card1 --device /dev/dri/renderD128 --group-add 44 --group-add 992 \
  -e KASM_EGL_CARD=/dev/dri/card1 -e KASM_RENDERD=/dev/dri/renderD128 \
  -e VNC_PW=password --shm-size=512m \
  --security-opt seccomp=src/common/seccomp/chrome.json --security-opt apparmor=unconfined \
  -p 6901:6901 nix-chrome-run:spike
# the Kasm agent chowns the dri nodes to the session user; do that manually when testing.
```

### Base image pinning (today vs the footgun it replaced)
The flake needs the `nix-ubuntu` base as `fromImage`. It uses
`nix2container.pullImageFromManifest` with `nix/base-manifest.json` (avoids a
global FOD hash during fast iteration). Because that file is gitignored and a
pure flake eval only sees git-tracked/staged files, the flake reads its absolute
path from **`$NIX_UBUNTU_BASE_MANIFEST`** under **`--impure`** (in pure eval
`getEnv` returns `""`, so the no-base dedup-proof outputs still evaluate). This
removed the earlier `git add -f nix/base-manifest.json` workaround.

---

## CI/CD — target state

Detailed design: [`build-pipeline.md`](docs/build-pipeline.md) (layer mechanics,
caching, multi-arch, airgap, SBOM) and [`build_plan.md`](docs/build_plan.md)
(milestones). Summary of what changes from the manual flow above:

### What stays the same
- One pinned Nix store per arch → identical store paths become identical OCI
  layers across every image (the dedup property; proven `pull-fat-then-app = 0 B`).
- nix2container `buildImage` per image, fanned out in parallel; the shared
  `baseLayer` + per-app `appLayer` reused so digests match.
- `bin/nix-profiles.toml` stays the human surface (apps, refs, deps, `_gpu`).

### What changes for CI
1. **Pin the base by digest, not a loose file.** Replace
   `pullImageFromManifest` + the gitignored `base-manifest.json` with
   `nix2container.pullImage` using a **committed image digest**:
   ```nix
   baseImage = n2c.pullImage {
     imageName = "registry.../nix-ubuntu";
     imageDigest = "sha256:…";   # committed; bumped when the base is rebuilt
     sha256 = "…";               # FOD hash
   };
   ```
   CI flow: build `nix-ubuntu` → push to the registry → capture the digest →
   record it in-repo → app-image builds reference it. Reproducible, source-
   controlled, no `--impure`/`getEnv`, no per-host manifest file. (The
   `$NIX_UBUNTU_BASE_MANIFEST` env-var approach is the **local-dev** convenience;
   the digest pin is the **CI/production** answer.)
2. **Publish to real registries**, per-arch then manifest: amd64 on amd64
   runners, arm64 on arm64 runners (no qemu cross-build for Chromium-class
   closures); join into multi-arch manifests with the existing `manifest.sh`
   pattern. `platforms = ["amd64"]` profiles ship amd64-only manifests.
3. **Private binary cache** (Cachix / attic / S3) so parallel runners and reruns
   don't recompile closures on a `cache.nixos.org` miss.
4. **Dynamic pipeline integration** — add `nixImages` rows to
   `ci-scripts/template-vars.yaml` (rendered by `template-gitlab.py`), with
   `changeFiles` globs gating feature-branch builds; `develop`/`release/*` build
   all and push to DockerHub + Quay.
5. **Scheduled Chromium rebuild** (CVE cadence) — re-evaluate the rolling-`ref`
   profiles against latest `nixos-unstable`, rebuild only those, repush; nix2container
   skips unchanged layers so only Chrome's delta moves.
6. **Scan + SBOM** — Trivy scan (existing `ci-scripts/scan/`) + a CycloneDX/SPDX
   SBOM emitted from the Nix closure, plus a baked `nix-app list` manifest.

### Not yet wired
- No `nixImages` builder type in CI yet (design only).
- `bin/build-nix-store-volume` still emits via `buildah` `FROM scratch`; the plan
  is to move it (or a sibling `bin/build-nix-images`) to a nix2container
  expression, keeping the TOML parsing + staging/cache machinery.
