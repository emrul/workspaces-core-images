# Nix image delivery model — per-app images reuse the fat store's `/store` layers

Status: **proposed** (refinement of `design/nix-package-process.md`). Delivers the
cross-image layer dedup the original design promised, **without giving up the
mountable fat store and without giving up self-contained per-app images.**

Audience: engineers working on `bin/build-nix-store-volume`, the Nix base
images, and the kasm-nix registry.

> TL;DR — Today the fat store (`FROM scratch`, store at `/store`, mounted at
> `/nix`) and the per-app images (store *baked* at `/nix/store`) share **zero**
> OCI layers, because identical store content is copied to *different paths* →
> different layer digests. Fix: build the per-app images from the **same
> `/store` layers the fat store already produces**, and add a build-time symlink
> `/nix/store → /store` (and `/nix/var → /var`) so they stay self-contained.
> Then every per-app store layer is byte-identical to a fat-store layer →
> deduped by digest. The fat store is unchanged (still mountable); per-app
> images are still self-contained (no runtime mount). A host that has the fat
> store pulls any app for ≈ 0. **All three properties held; no trade.**

---

## 1. Problem (measured)

On the .140 host, with several app images present:

| Comparison | Shared layers |
|---|---|
| fat store (`nix-store:nix`) ↔ `chrome:nix` | **0** |
| `chrome:nix` ↔ `vs-code`/`firefox`/`gimp` | 7–8 |

Per-app byte split (gimp, 2.49 GB compressed): 1.92 GB base+shared,
0.56 GB app-unique. gimp's closure is physically inside the 28 GB fat store on
the host, yet contributes 0 to the pull. `design/nix-package-process.md` (lines
27, 55) promised dedup "across the fat store and every per-app" — unmet.

## 2. Root cause — path, not granularity

A layer's digest is the hash of its tar **including member paths**. The build
copies the *same* partitioned store dirs to *different* destinations:

```dockerfile
# fat store (build-nix-store-volume §10)      # per-app TODAY (§11b)
FROM scratch                                   FROM nix-<distro>
COPY base/store          /store                COPY base/store          /nix/store
COPY layer-<n>/store     /store                COPY layer-<n>/store     /nix/store
COPY profile-<app>/store /store                COPY profile-<app>/store /nix/store
COPY meta/var            /var                  COPY meta/var            /nix/var
```

`store/…` vs `nix/store/…` tar members → different diff_id → different blob
digest → no dedup. Each app is *already* its own layer (fat store = 51 layers:
base + shared + one per profile). **Per-app layering is not the gap — the
destination path is.** The `/store` layout exists so the fat store can
`--mount type=image,dst=/nix` (its `/store` → the consumer's `/nix/store`);
baking a mountable image at `/nix/store` would nest to `/nix/nix/store`.

## 3. The fix — per-app images use `/store` + a `/nix/store` symlink

Build the per-app image from the **identical `/store` layers the fat store
already produces**, then symlink so the store resolves at its canonical path:

```dockerfile
FROM nix-<distro>
USER 0
COPY base/store          /store        # ← same source + same dest as the fat store
COPY layer-<n>/store     /store        #    → byte-identical layer → deduped
COPY profile-<app>/store /store
COPY meta/var            /var
RUN ln -sfn /store /nix/store && ln -sfn /var /nix/var   # self-contained: no mount
ENV NIX_APP_PROFILES=<app>
```

Because the COPY source dirs *and* destinations now match the fat store exactly,
`base/store`, each `layer-<n>/store`, and `profile-<app>/store` produce the
**same blob digest** in both images. The per-app image's store layers are a
**subset of the fat store's** → full dedup.

### Why the symlink is safe (validated)

Nix binaries reference the store by absolute path (`/nix/store/<hash>/…`) and
carry their own glibc + loader inside the closure. Path resolution — for the ELF
interpreter, `RUNPATH`, and `dlopen` — follows the `/nix/store → /store` symlink
transparently. Verified on the .140 host (Docker 29):

```
# store mounted at /mnt/fat, /nix/store -> /mnt/fat/store, plain ubuntu:24.04 base
$ /nix/var/nix/profiles/vlc/bin/vlc --version   → runs ("… not supposed to run as root")
```

This is the same kind of indirection the current mount model already relies on
(`/nix` is a read-only mount, not a "real" NixOS store), so it is not a new class
of risk. **Build gotcha:** do not `rm -rf /nix` on the base at build time — set
up the symlink over whatever the base ships (see §7); an earlier test that wiped
`/nix` on `nix-ubuntu` broke its bootstrap and produced a spurious glibc crash.

## 4. Result — all three properties held

| Property | Status |
|---|---|
| Fat store stays **mountable** (`/store`, `--mount dst=/nix`) | **unchanged** |
| Per-app images stay **self-contained** (run with no mount) | **kept** (symlink) |
| Fat ↔ per-app **layer dedup** | **now full** |

Dedup that results:
- **fat ↔ per-app: full** — every per-app store layer is one of the fat store's.
- **per-app ↔ per-app: full** — shared base/shared layers (as today, but now at
  `/store`), plus each app's own profile layer.
- **across distro bases** — a COPY layer's diff_id is independent of its parent,
  so the `/store` layers are identical whether the base is `nix-ubuntu`,
  `-fedora`, or `-alpine` (we proved the store runs on all three). Docker stores
  each store layer **once per host** regardless of base.

**Consequence:** a host holding the fat store pulls **any per-app image for ≈ 0
bytes** of store content — only the thin distro OS base (shared with the desktop
workspaces and every other app) and a few-byte symlink layer are ever unique.
That is the benefit the original design promised.

## 5. Consumption model (unchanged for users)

| Workspace | Image | run_config | app selection |
|---|---|---|---|
| Single app | `nix-<app>:nix` (self-contained, `/store` + symlink) | seccomp only | `ENV NIX_APP_PROFILES=<app>` |
| Desktop, pick apps | `nix-<distro>` + **mount** `nix-store:nix` at `/nix` | seccomp + image `mounts` | launch form → `nix-activate` |

The fat store and the three desktop entries are **unchanged**. Only the per-app
image *build* changes (destination `/store` + symlink instead of `/nix/store`).
`nix-activate` reads `/nix/var/nix/profiles/_meta.json` and resolves store paths
identically whether `/nix` is a mount or a symlink, so **no `nix-activate`
change is required** — but the symlink path should be smoke-tested with
`nix-activate` (menu shims, desktop launch), not just a bare binary (§10).

## 6. What we do NOT change

- The fat store: `FROM scratch`, `/store`, mountable. Byte-for-byte as today.
- The desktop workspaces: still mount the fat store; launch-form selection.
- `nix-activate` / `nix-launch`.
- Per-app images remain single self-contained images (plain Kasm one-image UX).

## 7. Build changes (`bin/build-nix-store-volume` §11b)

Change the per-app Dockerfile emission (currently lines 738–752):

1. `COPY base/store /store` / `COPY layer-<n>/store /store` /
   `COPY profile-<app>/store /store` — **`/store`, not `/nix/store`**, using the
   exact same source dirs and COPY form as the fat-store Dockerfile (§10) so the
   digests match.
2. `COPY meta/var /var` — `/var`, not `/nix/var` (matches the fat store; keeps
   the option of deduping the meta layer if a full meta is used instead of the
   current thin per-app meta).
3. Add `RUN ln -sfn /store /nix/store && ln -sfn /var /nix/var`, tolerant of an
   existing `/nix` in the base (create `/nix` if absent; replace only
   `/nix/store` and `/nix/var`, never wipe `/nix`).
4. Keep `ENV NIX_APP_PROFILES=<app>`.

The finish build (`dockerfile-nix-app-finish`) that adds wiring stays; it just
operates over a symlinked store — verify its shim generation resolves through the
symlink (it uses absolute `/nix/store/…` paths, which resolve).

## 8. Registry changes (kasm-nix-registry)

None required for the model. Per-app entries are unchanged (still self-contained
images with seccomp `run_config`). The desktop/fat-store entries are unchanged.
The only observable difference is that installing a per-app workspace on a host
that already has the fat store (e.g. from a desktop workspace) pulls ≈ 0.

## 9. Migration / rollout

1. **Prototype (one app):** change the per-app emit to `/store` + symlink; build
   `nix-gimp` this way on forge.
2. **Measure dedup:** `docker manifest inspect` — its `/store` layers must match
   the fat store's digests; on the .140 host (fat store present) a fresh pull
   should be ≈ 0 store bytes.
3. **Function:** run it standalone (self-contained, no mount) — desktop boots,
   `nix-activate` wires the app, it launches. Also confirm nothing regressed vs
   the current baked image.
4. Roll to the full per-app catalog; republish.
5. Update `design/nix-package-process.md` to reference this model and correct the
   old cross-dedup claim.

## 10. Verification checklist

- **Digest match:** every `/store` layer of `nix-<app>:nix` appears in
  `nix-store:nix` (`docker manifest inspect` set intersection > 0, ideally = all
  store layers).
- **Pull cost:** with the fat store present, `docker pull nix-<newapp>:nix` shows
  all store layers "Already exists"; only the OS base (if absent) + symlink layer
  download.
- **Runtime (self-contained):** the app runs with no `/nix` mount — validated for
  `vlc` (§3); extend to `nix-activate` menu shims + a full desktop launch, and to
  an FHS/bwrap app (OnlyOffice) and an Electron app (VS Code).
- **Cross-distro:** `/store` layer digests match across `nix-<app>` built on
  ubuntu/fedora/alpine bases.

---

## 11. Composability — bring-your-own package images

The same indirection that lets per-app images be self-contained also makes
`/nix/store` a **composable assembly point** rather than a fixed monolith. A
Nix store is content-addressed and immutable (every path is `/nix/store/<hash>`),
so multiple independent store sources can be merged with no conflicts.

- **One source** → symlink `/nix/store → /store` (§3).
- **Many sources** → an **OverlayFS union** at `/nix/store` with read-only
  lowerdirs, one per mounted store image:
  ```
  mount -t overlay overlay -o lowerdir=/stores/base:/stores/user-pkgs:… /nix/store
  ```
  Because paths are unique hashes, there are no path collisions (a package shared
  by two sources is byte-identical — the overlay just sees one). Read-only lowers
  mean no write conflicts. `nix-activate` then activates any selected profile
  regardless of which source provides it.

This turns the platform into an **extensible app catalog**:

- A user (or third party) builds their own package image with the *same*
  `bin/build-nix-store-volume` tooling and `/store` layout, and ships it as an
  independent OCI artifact.
- At launch, their image is mounted alongside our base fat store; the runtime
  overlays both into `/nix/store` and `nix-activate` surfaces the union.
- **No base or fat-store rebuild** is needed to add apps — you compose the exact
  set you want from separately-versioned, independently-published store images.
- **Dedup carries across publishers:** a custom image built on the same nixpkgs
  pin shares its base/shared `/store` layers (glibc, common runtimes) with our
  fat store by digest — so a user's custom app image is *also* a near-free pull
  on a host that already has our base.

Requirements / caveats to design out during implementation:

- **Profile metadata merge.** Each source carries its own
  `/var/nix/profiles/*` + `_meta.json`; the runtime must union these (overlay
  `/var/nix/profiles` too, or have `nix-activate` scan multiple profile roots) so
  profiles from any source are discoverable.
- **Closure completeness per source.** Each store image must ship the *complete*
  closure of the profiles it declares (self-contained), so the union is coherent
  even if only a subset of sources is mounted.
- **nixpkgs alignment for dedup.** Different nixpkgs revisions still work (unique
  hashes, no conflict) but dedup less; publishing against a shared pin maximizes
  layer reuse across publishers.
- **Trust.** A mounted third-party store image executes code as the session
  user — treat custom package images with the same trust/seccomp posture as any
  other workspace image (see `design/security-model.md`).

This is a natural extension, not a prerequisite — the single-source symlink model
(§3) ships first; overlay-based composition is a follow-on that reuses the exact
same build output and runtime primitives.

## Appendix — alternatives considered

- **Bake everything at `/nix/store`, drop the mount** (make the fat store a
  runnable all-apps image): also dedups, but sacrifices the mountable fat store
  and needs per-distro fat images. Rejected — the symlink keeps the mount.
- **Make per-app images mount the store at runtime** (per-app = thin base +
  mount): dedups, but per-app images stop being self-contained (need an
  image-mount `run_config`), losing the plain one-image UX. Rejected.

The `/store` + symlink approach is the only one that keeps the fat store
mountable **and** per-app images self-contained **and** gets full dedup.
