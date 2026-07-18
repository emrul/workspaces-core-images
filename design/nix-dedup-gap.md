# Nix delivery: the fat-store ↔ per-app dedup gap

**Status:** investigated 2026-07-08. TWO causes found and resolved: (1) the fat
store was stale on the registry — FIXED by publishing it every pipeline
(`PUBLISH_FAT_STORE=1`); (2) the client image store must be content-addressed —
the dedup only lands on Docker's **containerd snapshotter** (or containerd/CRI
directly), NOT the classic `overlay2` graph driver. Host requirement documented
in `docs/docker-setup.md` (Docker ≥ 28 + containerd snapshotter).

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

**The build achieves cross-dedup; publishing threw it away.** (Fixed:
`PUBLISH_FAT_STORE=1`, commit ac5a676.)

### 3. Even with a fresh, matched fat store, the CLIENT must be content-addressed

After the fat store is published from the same build (blobs byte-identical to the
per-app images — verified: zoom's 618 MB store layer `de8b47…` / diff-id
`62f5a779…` is present in *both* `nix-store:nix` and `zoom:nix`), a `docker pull`
of an app on a host that has the fat store STILL re-downloaded the store layer.

Root cause is the client image store's reuse model:

- **`overlay2`** (classic Docker graph driver) reuses layers by **chainID** — a
  layer *plus all its parents*. The fat store is `FROM scratch`; per-app images are
  on the OS base, so the identical `de8b47` blob sits on different chains → not
  reused → re-download. (The OS base *does* dedup across per-app images because
  they all share the same OS-based chain — which is why "the base is cached" but
  the app store layer isn't.)
- **containerd content store** (Docker's containerd snapshotter, or containerd/
  CRI-O directly) reuses by **content digest**, chain-independent → the blob is
  recognized.

**Proven** (nerdctl on the forge host, containerd): with `de8b47` already in the
content store, pulling the fat store reported `de8b47 … already exists` (deduped);
34/35 apps' unique content downloaded, `de8b47` did not. On `overlay2` the same
layer re-downloads. So the design is correct; the missing piece is the client
image store.

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

### Secondary — the client must use a content-addressed image store

Publishing a matched fat store is necessary but not sufficient: the consuming host
must reuse layers by content digest, not chainID. Require **Docker ≥ 28 with the
containerd snapshotter** (`features.containerd-snapshotter: true`), or a
containerd/CRI runtime. Full host setup + verification in `docs/docker-setup.md`.

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

---

## Incident 2026-07-18: partial fat store published (and the guard that now prevents it)

`PUBLISH_FAT_STORE=1` (the fix above) had a hole in the other direction: a
**profile-scoped build** (`NIX_PROFILES=<app>` → `dind-build.sh` passes
`--profile` → `build-nix-store-volume` stages ONLY the selected profiles)
emits a fat store containing just those profiles — and publish happily pushed
it. Two chrome-only pipelines (2687314252, 2687341067) overwrote the
registry's full-catalog `nix-store:nix` with a **chrome-only** fat store;
fat-store desktops image-mount that tag and lost every other app until a
full-catalog rebuild republished it.

Guard (in `nix-publish.sh`): before pushing, compare the **build sidecar
`labels.json` app set** (every app staged into this build) against the
`[profiles.*]` set in `bin/nix-profiles.toml`. Any missing profile → **skip
the push** (`skipped-partial` in the build report), keep the last-known-good
tag, and say how to republish (full build, or `FORCE_FAT_PUSH=1` for an
intentional catalog shrink). Missing sidecar = fail closed (skip).
NOTE: the first guard version compared the `dev.kasm.nix.profile-refs` image
label instead — that label only lists apps with explicit ref pins (12 of 47),
so it wrongly skipped a genuinely-full fat store (pipeline 2687365634);
labels.json is the ground truth. Detected by the L3 scan report, of all
things — the fat-store row's package count collapsed between two chrome-only
runs.

**Build-side fix (Option A, 2026-07-18):** builds are now **full-selection
always** — `dind-build.sh` no longer narrows via `--profile` (that was the
partial-fat source; `SCOPED_BUILD=1` keeps it for local dev). The eval-gate
scopes reinstalls, and per-app assembly is scoped by `changed.txt` **plus a
wiring-digest check** in `nix-crane-assemble` (deterministic wiring tars
sha256-compared against `wiring-digests.tsv` in the output dir) so wiring-only
changes still reassemble their app — the guarantee subset builds used to
provide. Crane also writes `assembled.txt` (what this build actually
reassembled): the scan stage scopes to it, and publish now runs unfiltered
(`NIX_PROFILES=""` — content compare decides), so pin-drift rebuilds beyond
the git-gated set are pushed and fat↔app dedup holds. The publish-side
completeness guard stays as the safety net.
