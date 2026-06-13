# Build & Publish Pipeline

How one pinned Nix store becomes a fat image + N per-app images, published
cache-efficiently and rebuilt nightly. Tooling rationale (why nix2container,
how it differs from `dockerTools`, and how airgapped export works) is in
[`investigation-findings.md`](investigation-findings.md#1-image-build-tooling-decision).

## Goals

1. **One store, many images.** Build every image from a single per-arch Nix
   store so identical store paths become identical OCI layers everywhere.
2. **Maximal cross-image dedup.** A client that pulled the fat image (or any
   one app) pulls only the new app's delta for the next.
3. **Cheap nightly repush.** A Chromium CVE bump re-emits Chromium's layer(s)
   + meta only; the base and every other app are untouched on the wire.
4. **Parallel + cache-efficient CI.** Profiles build in parallel against a
   shared, cached Nix store; the binary cache makes reruns fast.
5. **Per-arch, then manifest.** amd64 + arm64 built on native runners, joined
   into multi-arch manifests.

## Phase diagram

```
            ┌────────────────────────────────────────────────────────┐
  AUTHOR    │ bin/nix-profiles.toml   (human surface: apps, refs, deps)│
            └───────────────────────────┬────────────────────────────┘
                                         │ generate
            ┌────────────────────────────▼───────────────────────────┐
  EXPRESS   │ Nix flake: profiles → derivations + nix2container calls  │
            └───────────────────────────┬────────────────────────────┘
                  ┌──────────────────────┼──────────────────────┐
  REALISE         ▼ (shared Nix store + binary cache, per arch)  │
            ┌──────────────┐                                     │
            │ realise all  │  one store; closures computed once  │
            │ profiles     │                                     │
            └──────┬───────┘                                     │
  EMIT            │ nix2container.buildImage (parallel, per image)│
       ┌──────────┼───────────┬───────────────┬──────────────────┘
       ▼          ▼           ▼               ▼
   fat image   chrome img   vscode img   …   (all FROM kasm-core, shared base layers)
       │          │           │               │
  PUSH ▼          ▼           ▼               ▼  copyToRegistry / skopeo (skip pushed)
            ┌────────────────────────────────────────────────────────┐
            │ cache registry (branch) → DockerHub + Quay (develop/rel) │
            └───────────────────────────┬────────────────────────────┘
  MANIFEST                              ▼
            amd64 + arm64 → multi-arch manifest per image (existing pattern)
```

## Image taxonomy

| Image | Built by | Store delivery | Layers (base→top) | Published as |
|---|---|---|---|---|
| **fat store** `kasmweb/nix-store-<arch>` | nix2container (all profiles) | runtime mount at `/nix` | base + every profile delta + meta | per-arch tag + manifest |
| **thin runtime** `kasmweb/nix-ubuntu` | `dockerfile-nix-ubuntu` | n/a (mounts fat) | core + activation scripts | manifest |
| **per-app** `kasmweb/<app>` | nix2container (`fromImage=core`) | baked | core + shared Nix base + app delta | per-arch tag + manifest |
| **bundle** (optional) `kasmweb/<set>` | nix2container (fixed profile set) | baked | core + base + N app deltas | manifest |

The fat + thin pair is the existing PoC (ad-hoc combine). Per-app images are
the new self-contained, verified-publisher artifacts.

## Layer-sharing mechanics

**Use explicit, reused layers — not bare `maxLayers`.** The M0 spike measured
that nix2container's automatic popularity layering does **not** dedup across a
family of images (it repacks store paths per-image, so digests differ); pull-fat-
then-app cost ~1.6 GB. See
[`investigation-findings.md` §1b](investigation-findings.md#1b-m0-spike-results--measured-2026-06-12-x86_64-test-host).

The structure that works (measured: pull-fat-then-app = **0 B**):

- A shared **`baseLayer`** = `nix2container.buildLayer { deps = basePkgs; }` —
  the common closure (glibc, X11, gtk, glib, nss, mesa … the design's `[base]`).
  Built once, referenced by every image → one byte-identical base layer.
- One **`appLayer` per app** = `buildLayer { deps = [pkg]; layers = [baseLayer]; }`
  (the `layers =` arg makes it exclude base paths). Defined **once** and reused
  by both the per-app image and the fat image, so the digests match.
- Per-app image = `buildImage { layers = [ baseLayer appLayer ]; … }`.
  Fat image = `buildImage { layers = [ baseLayer ] ++ allAppLayers; … }`.
- The Kasm **core** layers are shared because every Nix image uses the same
  `fromImage` (one pinned `kasmweb/core-ubuntu-noble` digest).

Result: `pull fat` then `pull <app>` ⇒ 0 bytes (base + that app's layer already
present). `maxLayers` can still split the *base* internally for finer base-bump
granularity, but cross-image sharing comes from the explicit reused layers, not
from `maxLayers`.

Promote heavy closures shared by several apps (e.g. a common Electron) into
`basePkgs` so sibling app layers don't each carry a copy (auto-promote heuristic).

## CI integration (GitLab dynamic pipeline)

Reuse the existing pattern in both repos: `template-vars.yaml` +
`template-gitlab.py` render a child pipeline. Add:

```yaml
# ci-scripts/template-vars.yaml  (core-images) — store + thin runtime
nixImages:
  - name: nix-store
    builder: nix2container        # new builder type
    profiles: all
    changeFiles: [ bin/nix-profiles.toml, bin/build-nix-store-volume,
                   src/ubuntu/install/nix/** ]
  - name: nix-ubuntu
    dockerfile: dockerfile-nix-ubuntu
    base: core-ubuntu-noble
    changeFiles: [ dockerfile-nix-ubuntu, src/ubuntu/install/nix/** ]
```

Per-app images: one row per app, sharing the realised store. The build stage
fans out across the matrix; the realise step is shared (warm Nix store + binary
cache) so per-image work is just `buildImage` + push.

**Caching strategy** (the cache-efficiency requirement):

1. **Nix store / binary-cache layer.** A persistent per-arch Nix store
   (the named volume `nix-build-stage-<arch>` today; a CI cache mount or a
   private binary cache in CI). Realising profile N reuses profile M's shared
   deps for free.
2. **Private binary cache** (Cachix/attic/S3 — Open Question 3) so parallel
   runners and reruns don't recompile. Without it, a cold runner recompiles
   from source on a cache.nixos.org miss.
3. **Registry layer dedup.** `copyToRegistry`/skopeo skips already-present
   layers — only changed deltas are pushed.

**Branch behaviour** (mirror existing):

- Feature branches: build only images whose `changeFiles` matched; push to the
  internal cache registry.
- `develop` / `release/*`: build all; push to DockerHub + Quay.

## Nightly / scheduled rebuilds (Chrome CVE cadence)

A scheduled pipeline (`$PARENT_PIPELINE_SOURCE == "schedule"`, as the core repo
already uses for `oci-*-scheduled` runners) that:

1. Re-evaluates the rolling-`ref` profiles (chromium, AI CLIs) against the
   latest `nixos-unstable`.
2. Rebuilds **only** those profiles + their images.
3. Repushes — nix2container skips unchanged layers, so the base and other apps
   don't move. A Chromium bump pushes ~Chromium's delta + meta.
4. Re-tags rolling tags / updates the manifest.

This is the security-currency story: nightly `kasmweb/chrome` carries the
latest nixpkgs Chromium without a full-catalog rebuild.

## Visibility / SBOM (stated outcome)

Each published image must expose its Nix contents:

- Bake a `nix-app list`-style manifest (profile → packages → closure size)
  into the image and/or attach it as a build artifact.
- Generate the README package table (as `docs/nix-how-to.md` §4 does) from the
  TOML so per-image DockerHub/Quay READMEs stay accurate.
- Optional: emit a CycloneDX/SPDX SBOM from the Nix closure for scanning.

## Multi-arch & arch-restricted profiles

- Build amd64 on amd64 runners, arm64 on arm64 runners (Nix builds per-system;
  cross-build via qemu is 10×+ for Chromium-class closures — avoid).
- `platforms = ["amd64"]` in the TOML skips arch-less profiles at build time
  (e.g. `onlyoffice` has no upstream arm64 binary). The per-app image for such a
  profile is amd64-only; the manifest carries just that arch.

## Airgapped / offline delivery

nix2container being archive-less does **not** prevent offline delivery — it just
moves materialization to a `copyTo` step on the build host. Two delivery shapes:

- **Self-contained archive** per image — `nix run .#<app>.copyTo --
  oci-archive:./<app>.tar:<repo>:<tag>` (or `docker-archive:`), shipped into the
  airgap and `podman load`/`docker load`-ed. No Nix, no network on the
  destination.
- **Offline mirror registry** — `copyTo docker://offline-registry.internal/…`
  to populate an in-airgap registry once; nodes pull from it and still benefit
  from cross-image layer dedup.

The materialize step must run where the Nix store exists (build/CI host), not in
the airgap. Add an optional CI job that exports the offline artifacts for the
profiles/apps an airgapped customer needs. Mechanics + caveats in
[`investigation-findings.md`](investigation-findings.md#1a-airgapped--offline-export).

## What changes in code (no edits this pass)

- `bin/build-nix-store-volume`: replace the `FROM scratch` + `COPY` + `buildah`
  emit (lines ~462–507) with a nix2container expression, **or** add a sibling
  `bin/build-nix-images` that does both fat + per-app. Keep the TOML parsing and
  the staging/cache machinery.
- New: a Nix flake (`pkgs/` or `nix/`) generated from `nix-profiles.toml`,
  calling `buildImage` per image. See
  [`build_plan.md`](build_plan.md).
- CI: new `nixImages` matrix rows + a scheduled pipeline entry.
