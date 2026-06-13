# Kasm Nix Packaging — Requirements

> Source of truth for the Nix-packaging effort. Companion docs live in
> [`docs/`](docs/). The original single-image PoC design is preserved in
> [`../nix-package-process.md`](../nix-package-process.md) and is referenced
> below where its mechanics still hold.

Status: **design / pre-full-PoC.** A working single-image PoC exists on
`feat/nix`. This bundle defines what a *full* PoC must add and why.

## Scope

Evaluate the feasibility, benefits, and disadvantages of using
[Nix](https://nixos.org/) to package the applications that ship in Kasm
Workspaces images, and design a build/publish pipeline that delivers those
apps with minimal duplication and minimal client download.

The work spans two repos:

- **`workspaces-core-images`** (this repo) — the OS + KasmVNC core images and
  the Nix store/runtime tooling. Primary working dir for this effort.
- **`workspaces-images`** — the per-application catalog (Chrome, Firefox,
  VS Code, …) published to DockerHub/Quay as a verified publisher.

Two consumption models must coexist:

1. **Ad-hoc combination** — a user picks any subset of apps at session start
   (`NIX_APP_PROFILES=chromium,vscode,node`) against a shared store. This is
   the existing PoC.
2. **Per-application images** — self-contained, individually published images
   (`kasmweb/chrome`, `kasmweb/vscode`, …) that *share OCI layers* with each
   other and with the fat store image, so a client that already pulled one
   image pulls almost nothing for the next. This is the main new requirement.

### In scope

- A cache-efficient, parallel build pipeline producing, from one Nix store:
  - one **fat** image containing all profiles, and
  - **N per-app** images (`core` + shared Nix base + that app's layer).
- Adoption of [`nix2container`](https://github.com/nlewo/nix2container) for
  fine-grained, content-addressed, cross-image-deduplicated layers.
- Nightly/scheduled rebuilds (e.g. Chromium CVE cadence) via GitLab CI.
- Team documentation: how to package an app in Nix, and how to decide when a
  custom Nix package is required.
- An assessment of whether the Kasm base image should be thinned, with some of
  its own components (KasmVNC, profile-sync, …) delivered as Nix packages bound
  at runtime.
- End-user docs: selecting apps, choosing language-runtime versions
  (Python/Node), installing their own packages, and persisting state via the
  Kasm storage mount.
- End-user customization parity with today (e.g. injecting a Chrome managed
  policy at runtime or in a derived image).
- **Airgapped / offline delivery** — images deliverable to environments with no
  network and no Nix on the destination, as self-contained archives and/or an
  offline mirror registry. (Solvable with nix2container via skopeo
  `copyTo oci-archive:`/`docker://`; the materialize step runs on the build host
  — see [`docs/investigation-findings.md`](docs/investigation-findings.md#1a-airgapped--offline-export).)

### Out of scope (this pass)

- Migrating the existing `dockerfile-kasm-*` catalog *off* apt onto Nix
  wholesale. Nix is additive; the apt path stays.
- Nix overlays for cross-`ref` deduplication (parked as phase 2 in the
  original design doc).
- Building/operating a private Nix binary cache (noted as a follow-up).

## User / Operator Model

| Actor | Needs | Touchpoint |
|---|---|---|
| **End user** (workspace session) | Launch the apps they were given; optionally combine apps ad-hoc; install their own pip/npm packages; keep state between sessions | `NIX_APP_PROFILES`, `nix-app` CLI, XFCE menu, persisted `$HOME` |
| **App owner / engineer** | Add an app to the catalog; pick its update cadence; know when a custom package is needed | `bin/nix-profiles.toml`, [`docs/packaging-apps.md`](docs/packaging-apps.md) |
| **Release operator** | Build + publish the fat image and per-app images; run nightly security rebuilds; manage registry storage | `bin/build-nix-store-volume`, CI pipeline, [`docs/build-pipeline.md`](docs/build-pipeline.md) |
| **Customer / downstream builder** | Extend a published image (e.g. bake a managed policy, add a package) | `FROM kasmweb/<app>`, runtime host mounts |

## Component Or Capability Model

```
                        one pinned Nix store (per arch)
                                    │
        ┌───────────────────────────┼───────────────────────────┐
        ▼                           ▼                           ▼
  nix2container               nix2container               nix2container
  buildImage (fat)            buildImage (chrome)         buildImage (vscode) ...
        │                           │                           │
   all profile layers         core + base + chrome        core + base + vscode
        │                           │                           │
        └─────────── shared, content-addressed OCI layers ──────┘
                                    │
                              registry (DockerHub / Quay)
                                    │
        ┌───────────────────────────┼───────────────────────────┐
        ▼                           ▼                           ▼
  fat: runtime /nix mount     per-app: self-contained     per-app pulled after
  + NIX_APP_PROFILES         `docker run kasmweb/chrome` fat → near-zero delta
```

Layers an image is composed of, base → top:

1. **Kasm core** image layers (`kasmweb/core-ubuntu-noble` from this fork).
2. **Shared Nix base** — the common closure (glibc, openssl, X11, gtk, nss…),
   one stable set of content-addressed layers shared by *every* Nix image.
3. **Per-app delta** — only that app's store paths not already in the base.
4. (fat image only) every app's delta, plus the meta/profile registration.

Because layers 1–2 are byte-identical across all images, a client that pulled
any one Nix image already holds them; the next image is just layer 3.

## Supported Profiles / Modes

Existing profile set lives in [`bin/nix-profiles.toml`](../../bin/nix-profiles.toml):
chromium, onlyoffice, vscode, obsidian, angelfish, claude-code, opencode,
codex, ptyxis, node, python. Internal: `_base`, `bootstrap`.

| Mode | Image | Store delivery | Selection |
|---|---|---|---|
| Ad-hoc combine | `nix-ubuntu` (thin) | runtime `--mount type=image …:/nix` | `NIX_APP_PROFILES` / `nix-app` |
| Single app | `kasmweb/<app>` (self-contained) | baked layers | implicit (one app) |
| Multi-app baked | `kasmweb/<bundle>` (optional) | baked layers | implicit (fixed set) |

Per-profile **update cadence** is a first-class concept: the base nixpkgs `ref`
is bumped slowly (nixpkgs stable boundaries, ~6 months); fast-moving apps
(Chromium, AI CLIs) override `ref` to a rolling branch so their bumps re-emit
only their own layers. See cadence section of
[`../nix-package-process.md`](../nix-package-process.md#update-cadence).

## Example Workflows

```bash
# End user — ad-hoc combination against the fat store
podman run --rm -d --name nix-app \
  --mount type=image,source=kasmweb/nix-store-amd64:prod,destination=/nix \
  -e NIX_APP_PROFILES=chromium,vscode,python \
  -e VNC_PW=password -p 6901:6901 \
  kasmweb/nix-ubuntu:prod

# End user — self-contained single app (verified-publisher pull)
docker run --rm -p 6901:6901 -e VNC_PW=password kasmweb/chrome:1.18.0

# App owner — add an app, build only its image + the fat image
$EDITOR bin/nix-profiles.toml          # add [profiles.my-tool]
./bin/build-nix-store-volume --profile my-tool   # incremental

# Operator — nightly Chromium security rebuild (CI-driven)
./bin/build-nix-store-volume --profile chromium \
  --tag kasmweb/nix-store-amd64:chromium-$(date +%F)

# Customer — bake a Chrome managed policy into a derived image
FROM kasmweb/chrome:1.18.0
COPY my-policy.json /etc/opt/chrome/policies/managed/policy.json
```

## Architecture Constraints

- **Multi-arch.** Every image builds for `amd64` and `arm64`. Some nixpkgs
  packages are amd64-only (`onlyoffice`); the `platforms` field gates those.
- **container-init base only.** The Nix runtime image drops a unit into
  `/etc/container-init.d/`, which exists only in this fork's
  `container-init`-based core images — not upstream Dockerhub cores.
- **No Nix in the runtime image.** The runtime image carries activation
  scripts only (~tens of KiB); Nix store content is mounted or baked, never
  installed at runtime.
- **Layer identity must be stable across images and across rebuilds.** This is
  the load-bearing constraint: it's why `nix2container` (content-addressed,
  popularity-layered) replaces the current `FROM scratch` + `COPY` partitioner,
  which produces coarse per-profile layers that duplicate shared non-base paths.
- **Downstream images inherit everything.** Conservative footprint; per-app
  images must not regress on size vs. today's apt-based images without a clear
  win (dedup, update cadence).
- **No secrets in images.** Anything in `$HOME/kasm-default-profile` ships
  publicly.

## Configuration And Secrets

- `bin/nix-profiles.toml` — the profile/base/cadence config (committed).
- `NIX_APP_PROFILES` (CSV) — runtime selection for the ad-hoc mode.
- `$KASM_OS_HOME/.config/nix-app/active` — per-user persistent selection
  (wins over the env var); survives sessions when the home dir is persisted.
- Registry auth: existing CI `DOCKER_AUTH_CONFIG`; k8s image-volume pulls reuse
  the pod `imagePullSecrets`.
- No credentials baked into store paths or images.

## Operations, Diagnostics, And Support

- **Visibility** of Nix contents per image is a stated outcome: each published
  image must expose what Nix packages/closures it contains (e.g. an SBOM or a
  `nix-app list`-style manifest, and a per-image README table).
- **Registry storage planning** — full closure of the profile set is ~4–5 GiB;
  layer dedup bounds growth but needs a documented budget.
- **Boot/runtime diagnostics** reuse container-init's trace + per-unit log
  tagging (see repo `CLAUDE.md`). Nix activation is `nix-activate.service`.

## Documentation Deliverables

| Doc | Audience | Status |
|---|---|---|
| [`docs/build-pipeline.md`](docs/build-pipeline.md) | operators | this bundle |
| [`docs/packaging-apps.md`](docs/packaging-apps.md) | engineers | this bundle |
| [`docs/base-image-assessment.md`](docs/base-image-assessment.md) | architects | this bundle |
| [`docs/investigation-findings.md`](docs/investigation-findings.md) | all | this bundle |
| [`docs/build_plan.md`](docs/build_plan.md) | implementers | this bundle |
| [`../../docs/nix-how-to.md`](../../docs/nix-how-to.md) | end users / operators | exists (PoC-era; to refresh) |

Docs must link to authoritative Nix documentation (nix.dev, NixOS manual,
search.nixos.org, nix2container README) rather than restate it — many Kasm
engineers do not know Nix well.

## Testing And CI

- Per-arch build matrix (reuse the existing GitLab dynamic-pipeline pattern).
- Cadence-decoupling check: a Chromium-only bump must leave the base-layer
  `DiffID` byte-identical (verify with `skopeo inspect` / `podman image inspect`).
- Cross-image dedup check: `kasmweb/chrome` and `kasmweb/vscode` must share the
  core + base layer digests.
- Per-app smoke: app launches headless in KasmVNC; `.desktop` shim trusted by
  XFCE; binary `--version` works.
- No-volume regression for the thin image (activation no-ops cleanly).

## Implementation Approach

Build everything from a single, pinned, per-arch Nix store, then emit images
with `nix2container`:

1. Replace the `FROM scratch` + `COPY` partitioner in `bin/build-nix-store-volume`
   (or add a sibling builder) with a `nix2container` expression that produces
   the fat image and one image per profile from the same store, with automatic
   popularity-based layering capped by `maxLayers`.
2. Keep the runtime thin image + `nix-activate` path for the ad-hoc model.
3. Wire CI: a build stage producing all images in parallel from a shared,
   cached Nix store; a scheduled pipeline for nightly app rebuilds.
4. Write the team + end-user docs in parallel with the pipeline.

Sequencing detail in [`docs/build_plan.md`](docs/build_plan.md).

## Out Of Scope

(See Scope § "Out of scope" above.) Additionally not in this pass: GUI for
profile selection; signed images / attestations; Nix flakes-based per-app
expression authoring beyond what packaging custom apps requires.

## Decisions

- **Both delivery models ship.** A **fat** image (runtime-mounted store +
  `NIX_APP_PROFILES`, for ad-hoc combination) **and** **N per-app** images
  (baked, self-contained, for verified-publisher `docker run`). No per-app
  *mounted* variant — per-app = baked, ad-hoc = fat/mounted. (Was Open Q1.)
- **Registry footprint is not a gating concern.** We expect the Nix approach to
  be *more* space-efficient than today's apt-per-image catalog (cross-image
  layer dedup). No budget ceiling to define now. (Was Open Q5.)

## Open / Deferred

Decide during implementation, not in this design pass:

1. **Private binary cache** (Cachix / attic / S3). Whether to stand one up for
   CI + customer rebuild speed and independence from cache.nixos.org —
   **discuss & decide during impl** (affects M4 in the build plan).
2. **Custom packages home.** In-repo `pkgs/` flake vs a separate `nix-apppkgs`
   overlay repo — **needs a pros/cons discussion** before deciding. Options laid
   out in [`docs/packaging-apps.md`](docs/packaging-apps.md#where-custom-packages-live-decision-pending).
3. **KasmVNC / components as Nix.** Whether to thin the base by delivering Kasm's
   own components as Nix packages — **scope what it involves** first; the
   assessment ([`docs/base-image-assessment.md`](docs/base-image-assessment.md))
   recommends *not* in this PoC and treats it as a separate future spike.
4. **nixpkgs base pin.** Config pins `nixos-25.05`; bump to current stable
   (`nixos-25.11`) — **TBD** (today: 2026-06).
