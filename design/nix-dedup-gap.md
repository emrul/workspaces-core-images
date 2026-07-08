# Nix delivery: the fat-store ↔ per-app dedup gap

**Status:** investigated 2026-07-08. Root cause found; fix proposed, not yet applied.

## Goal (recap)

The crane content-addressed assembly (`bin/nix-crane-assemble`) was adopted so that
the **fat store** image (`nix-store:<tag>`, all apps' Nix store) and the **per-app**
images (`nix-<app>:<tag>`) share their store layers **by digest**. The intended
payoff: if you already have the fat store, pulling any single-app image should only
transfer that app's thin metadata/wiring — the multi-GB store layers are already
present.

## Symptom

Pulling `…/zoom:nix` onto a host that already had the fat store re-downloaded a
515 MB layer (`f16ef878`, Zoom's app payload). Inspecting the registry:

- `zoom:nix` shares **0 of 12** layers with `nix-store:nix` (the fat store) — not
  even the 1.17 GB / 539 MB base-store layers.

## What actually happens

Two independent facts, established by inspection:

### 1. In-build, dedup DOES work (the design is sound)

On the forge build host, comparing the **local** images from a single build run
(uncompressed layer diff-ids via `podman image inspect … .RootFS.Layers`):

- `localhost/nix-zoom:dev` shares **5 layers** with `localhost/nix-store-amd64:dev`.
- Those 5 are Zoom's **store partitions** — `base` + the shared `layer-*` +
  `profile-zoom` (which contains the 753 MB Zoom app). They are byte-identical
  because both the fat-store append and the per-app append tar the *same*
  `${STAGING}/{base,layer-*,profile-*}/store` dirs via the shared, cached `det_tar`,
  and `crane` compresses a given tar deterministically (verified: `crane append
  --oci-empty-base -f X.tar` and `crane append -b <img> -f X.tar` produce the
  **identical** layer digest).

Zoom's other 8 local layers, correctly NOT in the fat store:
- **5 OS-base layers** from `kasm-core-ubuntu-minimal` (~2.58 GB uncompressed) —
  the desktop/VNC/container-init userland. The fat store is `FROM scratch` (pure
  Nix store), so it never contains these.
- the `/nix/store → /store` **symlink** layer, the per-app **appmeta** layer, and
  the per-app **wiring** layer — all tiny, all per-app by construction.

### 2. On the registry, dedup does NOT work — because the fat store is STALE

- Registry `nix-store:nix` was pushed **2026-07-06 21:52**, ~4 h after and from a
  **different build** than the app images (pushed 18:00–18:10). Its partition tars
  were built from an older store state, so they share nothing with the current
  per-app images → 0 overlap → full re-pull.
- **The CI pipeline never publishes the fat store.** `ci-scripts/nix-publish.sh`
  gates it behind `PUBLISH_FAT_STORE=1` (default 0), and the `publish` job in
  `.gitlab-ci.yml` does not set it. So `nix-store:nix` only ever got onto the
  registry via a manual one-off push, and has drifted ever since.

**The build achieves cross-dedup; publishing throws it away.**

## Fix

### Primary — publish the fat store from every pipeline

Make the `publish` job push the fat store built in the **same** run as the per-app
images, so their store-partition blobs match on the registry:

- Set `PUBLISH_FAT_STORE=1` for the `publish` job (env), and ensure the fat store
  local tag (`localhost/nix-store-<arch>:dev`) is present when `nix-publish.sh`
  runs (it is — the build always assembles it).
- Result: a host holding the current `nix-store:nix` that pulls `nix-<app>:nix`
  transfers only the app's appmeta + wiring (a few MB) **plus** the OS base if it
  isn't already present — never the shared store layers.

### Nuance — per-app images always carry the OS base

Per-app images are self-contained: `FROM nix-ubuntu` (≈2.58 GB OS/desktop base) +
store partitions + wiring. The fat store has **no OS** (scratch). So:

- "Have the fat store ⇒ per-app pull is *only* metadata" is literally true **only**
  for the **image-mount model** (thin `nix-ubuntu` base + `--mount type=image` the
  fat store at `/nix` + runtime app selection — see the fat-store runtime-selection
  design). No per-app image is pulled there at all.
- For the **per-app image model**, the OS base is shared across all per-app images
  and with the published `kasm-core-ubuntu*` images — so it's pulled once per host,
  not per app. With a *fresh* fat store present, the incremental cost of each new
  app is: (OS base if not already local) + appmeta + wiring.

## Verification plan (after applying the fix)

1. Trigger a pipeline with `PUBLISH_FAT_STORE=1`; confirm `nix-store:nix` and the
   app images carry the **same** creation build.
2. On a clean host: `docker pull …/nix-store:nix`, then `docker pull …/zoom:nix` —
   the base/shared/`profile-zoom` layers must report `Already exists`; only appmeta
   + wiring (+ OS base once) should transfer.
3. Cross-check: `docker manifest inspect` both and confirm the store-partition
   digests are shared.

## Evidence appendix

- crane determinism test: `--oci-empty-base` vs `-b <image>` → identical appended
  layer digest (`386741d63e29…`).
- local (same build) `zoom:dev` ∩ `nix-store-amd64:dev` = 5 diff-ids (store
  partitions); registry `zoom:nix` ∩ `nix-store:nix` = 0.
- `nix-store:nix` created 2026-07-06T21:52Z; `zoom:nix` 2026-07-06T18:10Z.
- `PUBLISH_FAT_STORE` present only in `ci-scripts/nix-publish.sh` (gated), absent
  from `.gitlab-ci.yml`.
