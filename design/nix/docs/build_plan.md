# Build Plan

Implementation sequencing for the full Nix PoC. Design source:
[`../REQUIREMENTS.md`](../REQUIREMENTS.md). No code is written in the current
(design) pass; this is the plan for the next pass(es).

**Target environment:** macOS dev host with podman+lima (per existing PoC) and
GitLab CI with `oci-amd-scheduled` / `oci-arm-scheduled` native runners.

## Build order / dependency graph

```
M0 spike (de-risk nix2container) ──► M1 store flake ──► M2 fat image
                                          │                  │
                                          ├──► M3 per-app images
                                          │
                                          └──► M4 binary cache (parallel)
M2,M3 ──► M5 CI wiring ──► M6 nightly schedule
M1.. (parallel, doc track) ──► M7 docs refresh + SBOM/visibility
```

## M0 — Spike: de-risk nix2container (do first, ~1–2 days)

**Goal:** prove the load-bearing assumptions before committing the pipeline.
Tests (from [`investigation-findings.md`](investigation-findings.md#open-spike-items-must-test-live)):

- `buildImage { fromImage = <kasm-core>; copyToRoot = …; }` on the apt-based
  core → Nix layers land on top, core layers keep identical digests across two
  different per-app images.
- Store paths stay at `/nix/store` (no `copyToRoot`-to-`/`); a profile binary
  runs from `/nix/var/nix/profiles/<name>/bin`.
- Baked per-app image works with **no** Nix DB; mounted fat image needs
  `initializeNixDatabase` for `nix-app list`.
- amd64+arm64 build on native runners → manifest assembles.
- `maxLayers` sweep: confirm shared base layers are byte-identical between two
  app images (cross-image dedup) via `skopeo inspect`.
- **Offline export:** `nix run .#<app>.copyTo -- oci-archive:./<app>.tar:…`
  produces a self-contained archive; `podman load` it on a Nix-free host and run.

**Exit criteria:** two per-app images that demonstrably share core + base layer
digests; a Chromium-only rebuild that leaves base digests unchanged; a loadable
offline `oci-archive` from a host with no live store mount.
**Contingency (not a drop-in):** if `fromImage`-on-apt or the third-party dep is
unworkable, re-design around `dockerTools.streamLayeredImage`. That is a
*different* image model (self-contained tarball, no skip-already-pushed repush),
not an emitter swap — see
[`investigation-findings.md`](investigation-findings.md#key-distinction-corrects-an-earlier-conflation).

## M1 — Store flake generated from TOML

Files: `nix/flake.nix` (or `pkgs/`), `nix/profiles.nix`,
extend `bin/build-nix-store-volume` (or add `bin/build-nix-images`).

- Keep `bin/nix-profiles.toml` as the authoring surface; generate the Nix
  profile/derivation set from it (the inner builder already does
  `builtins.fromTOML`).
- Realise all profiles into one per-arch store (reuse the named-volume cache).
- Output: closures + the data nix2container needs; no image yet.
- Checks: `nix flake check`; all current profiles realise on amd64; arch-gated
  profiles skip on arm64.

## M2 — Fat image via nix2container

- Replace the `FROM scratch`+`COPY`+`buildah` emit (`bin/build-nix-store-volume`
  ~462–507) with `nix2container.buildImage` producing the fat store image:
  base + per-profile + meta, `maxLayers` tuned from M0.
- Preserve runtime contract: store at `/nix`, `_meta.json` + profiles under
  `/nix/var/nix/profiles/`, DB initialized for `nix-app`.
- Checks: existing PoC verification steps (`design/nix-package-process.md`
  §Verification) pass against the nix2container-built image; `nix-app list`,
  activation, XFCE trust, deactivation all work; cadence-decoupling check.

## M3 — Per-app images

- For each profile, `buildImage { fromImage = kasm-core; … }` baking core + base
  + that app's delta. Add per-app desktop/single-app tweaks where the
  workspaces-images catalog expects them.
- Decide bundle images (optional fixed sets) — defer unless asked.
- Checks: `kasmweb/chrome` and `kasmweb/vscode` share core+base digests
  (`skopeo inspect`); each launches headless; self-contained `docker run` with
  no store mount works.

## M4 — Private binary cache (parallel, Open Question 3)

- Stand up Cachix / attic / S3 binary cache; point CI + dev builds at it.
- Push the realised store; confirm a cold runner pulls (not recompiles).
- Checks: cache hit on a fresh runner; cache.nixos.org outage doesn't block.

## M5 — CI wiring

- Add `nixImages` matrix rows (core-images: store + thin runtime; per-app rows).
- Shared realise step (warm store + binary cache); parallel `buildImage`+push
  fan-out.
- Branch behaviour: feature → cache registry (changed images only via
  `changeFiles`); develop/release → DockerHub + Quay; per-arch → manifest.
- Checks: feature-branch build builds only changed images; develop builds all;
  manifests assemble; registry push skips unchanged layers.

## M6 — Nightly schedule

- Scheduled pipeline (`$PARENT_PIPELINE_SOURCE == "schedule"`) rebuilding
  rolling-`ref` profiles (chromium, AI CLIs) + their images; repush deltas only.
- Checks: a scheduled run after a nixpkgs-unstable Chromium bump repushes
  ~Chromium delta + meta; base + other apps unchanged on the wire.

## M7 — Docs + visibility (parallel doc track)

- Refresh `docs/nix-how-to.md` for the nix2container pipeline + per-app images.
- Per-image README package tables generated from the TOML.
- Bake a `nix-app list` manifest / optional SBOM into each image.
- Promote `docs/packaging-apps.md` to a user-facing location if customers need
  it; keep the team copy in the bundle.

## Not doing in this pass

- Migrating the apt-based catalog off apt (Nix is additive).
- Base-image thinning / KasmVNC-as-Nix (see
  [`base-image-assessment.md`](base-image-assessment.md) — recommended *against*
  for now).
- Nix overlays for cross-`ref` dedup (phase 2 in `nix-package-process.md`).
- Signed images / attestations; profile-selection GUI.

## First live test sequence (after M2/M3)

```bash
# fat image, ad-hoc combine
./bin/build-nix-images --target fat --tag localhost/nix-store-amd64:spike
podman run --rm -d --mount type=image,source=localhost/nix-store-amd64:spike,destination=/nix \
  -e NIX_APP_PROFILES=chromium,vscode -e VNC_PW=password -p 6901:6901 \
  nix-ubuntu:spike

# per-app, self-contained
./bin/build-nix-images --target app:chrome --tag localhost/kasm-chrome:spike
docker run --rm -p 6902:6901 -e VNC_PW=password localhost/kasm-chrome:spike

# dedup proof
skopeo inspect docker-daemon:localhost/kasm-chrome:spike   | jq '.Layers'
skopeo inspect docker-daemon:localhost/kasm-vscode:spike   | jq '.Layers'   # shared prefix
```
