# Nix CI disk management

**Problem (2026-07-08):** the `nix-builder` runner's persistent podman store
(`/srv/nix-build/containers`, 465 G) filled up after a day of full-catalog
rebuilds, failing builds with `no space left on device` (rc=125).

## What grows vs. what's cache

The design principle is to **separate the cache we keep from the churn we prune.**

**KEEP — this is what avoids rebuilding unchanged work:**
- **`nix-build-stage-*` volume** — the Nix store. Nix will not re-realize a
  derivation whose output path already lives here, so keeping it *is* the
  "don't rebuild unchanged packages" mechanism.
- **Base images** (`localhost/nix-ubuntu:dev`, `kasm-core-ubuntu*`) — required by
  `--emit-app-images`, built by the manual `base*` jobs, rarely change.
- Registry-side dedup on GitLab: crane's content-addressed layers mean unchanged
  app images report "already exists" on push — no re-upload — independent of any
  local pruning.

**PRUNE — cheaply regenerated from the cache each build:**
- **crane staging registry (`nix-crane-registry`, registry:2)** — pure transit
  for the crane→podman handoff; crane re-pushes every blob each run. Its
  anonymous volume was the worst offender (~25–35 G accumulated *per build*, and
  orphaned volumes piled up whenever the container was recreated).
- **superseded `localhost/nix-<app>:dev` / `nix-store:dev` tags** — re-tagged
  each build; real copies live on the GitLab registry.
- **dangling image layers.**

## The fixes (all landed)

1. **`bin/nix-crane-assemble` `ensure_registry`** — recreate the staging registry
   fresh each run (`podman rm -f -v` drops the previous anonymous volume), so it
   can never accumulate. Bounds it to one build's blobs.
2. **`runs/nix-portal/dind-build.sh`** — before each build, `podman image prune`
   + drop superseded `nix-<app>:dev`/`nix-store:dev` tags (keeping base images),
   and a disk-guard that removes stale anonymous volumes if free < 80 G — never
   the `nix-build-stage-*` cache.
3. **`ci-scripts/nix-gc.sh` + `.gitlab-ci.yml` `gc` job** — a scheduled cleanup
   (runs only when a pipeline schedule sets `NIX_GC=1`; `prepare`/`build`/
   `publish` skip on that run). Does the same safe prune, and **resets** the Nix
   cache volume only if it exceeds `NIX_STAGE_CAP_G` (default 250 G) — a rare full
   re-seed, the one thing the per-build prune deliberately never touches.

## Operating it

Create a **weekly pipeline schedule** on `kasm-nix` with variable `NIX_GC=1`
(nothing else). It runs only the `gc` job. Bump `NIX_STAGE_CAP_G` if you want the
Nix cache to grow larger before a reset. A full manual reset is still
`build-nix-store-volume --prune-stage` (wipes `nix-build-stage-*`).

## Net effect
Routine builds stay fast (warm Nix store + registry dedup + change-gating), while
the local store no longer grows unbounded. The only slow-growth item (old Nix
generations) is bounded by the size-capped reset rather than a risky in-place GC.
