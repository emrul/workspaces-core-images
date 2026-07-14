# Nix workspace-as-code — customer-supplied stores + per-session composition

## Context

The fat store (`bin/build-nix-store-volume`, mounted at `/nix`) lets a Kasm
customer pick apps from *our* curated set at launch. The next operational step
is **workspace-as-code**: a customer — typically running a fleet of ephemeral
agents — declares *their own* package set, ships it alongside (or instead of)
our fat store, and either pre-activates those apps for their users or exposes
them for per-session selection. The apps must appear in the desktop menu, on
`PATH`, and on the Desktop, exactly like the curated ones do today.

Practically this reduces to: **mount one or more additional Nix stores and
present a single composed view of them at runtime.** We already built the seam
for a single store (`/nix/store → /store` symlink; `nix-bwrap-run` reconstitutes
a real store inside a bwrap user namespace). This document specifies the "more
than that" — composing *N* independent stores per session.

## Design decisions (locked)

These three forks were decided up front and drive the rest of the design:

| Fork | Decision | Consequence |
|------|----------|-------------|
| **Session granularity** | **Per-session composed store** — customer apps appear in the XFCE menu / Desktop / `PATH`, not only when launched | Composition happens once at boot, session-wide — not per-launch |
| **Dedup coupling** | **Independent customer stores** — a customer store is a full, self-contained closure; it may not reference (or even use) our fat store at all | No shared-base coordination; both stores can carry their own glibc/gtk. Composition must tolerate fully-disjoint stores |
| **Fleet distribution** | **Both k8s and docker agents** — operator owns getting store images onto each node | Distribution is a documented operator concern (§ Fleet distribution), not baked into the image |

## The one hard constraint

A Nix store is a single flat namespace: every path is `/nix/store/<hash>-name`,
and every binary's ELF interpreter + `RUNPATH` is an absolute path into it. You
cannot mount two `/nix/store` directories at the same point — one shadows the
other. So "add a customer store" *always* reduces to presenting a single
`/nix/store` that is the **union** of several read-only store dirs.

Content-addressing makes the union safe: a path `/nix/store/<hash>-x` has that
hash *because* of its exact byte content, so two stores can only ever collide on
byte-identical paths. Unioning is therefore never a merge conflict — at worst
it's a redundant entry (two independent stores each shipping their own glibc
under different hashes; both coexist). **This is a composition problem, not a
merge problem.**

## What already exists (the seam inventory)

The single-store machinery we're generalizing:

- **`/nix/store → /store` indirection** (`bin/nix-crane-assemble` `mk_symlink_tar`,
  per-app + fat-store images). Store content lives at `/store`, `/var` at `/var`;
  `/nix/store` is a redirection. The redirection is the hook that lets us
  reconstitute `/nix` however we like.
- **`nix-activate`** — reads `/nix/var/nix/profiles/*` + `_meta.json`, resolves an
  active list (`$HOME/.config/nix-app/active` → launch-form file →
  `NIX_APP_PROFILES`), writes `/etc/profile.d/nix-app.sh` (PATH/XDG), generates
  `/usr/share/applications/nix-*.desktop` shims with `Exec=` rewritten to
  **absolute** profile paths, drops Desktop icons, trusts them via `gio`.
  **Launch is by absolute `Exec=` path — the Nix db is not consulted to run an
  app** (per-app images ship no `db.sqlite` and still launch). This is what makes
  a multi-store union cheap: we union symlinks, not databases.
- **`nix-bwrap-run`** — for buildFHSEnv/bubblewrap apps (OnlyOffice, Steam),
  reconstitutes a *real* `/nix/store` inside a **bwrap user namespace**
  (`--tmpfs /nix` + `--bind /store /nix/store`). Its own note: *"bwrap supplies
  its own user namespace (CAP_SYS_ADMIN inside it), so this needs no container
  capabilities."*
- **The bwrap run_config** (`src/common/seccomp/bwrap.json`, applied to fat-store
  workspaces) **already unconditionally allows the full mount family**
  (`mount`, `move_mount`, `fsopen`, `mount_setattr`, `pivot_root`, …) plus
  `unshare`/`setns`. So userns-scoped mount operations are *already unblocked*.

The upshot: the capability question that would normally kill this ("Kasm
workspaces aren't privileged") is already answered — mount inside a user
namespace works with **no added container capability**.

## Architecture

```
   run_config.mounts (one type:image entry per store)
        │
        ▼
   /nix-stores/<id>/            each store image: FROM scratch, /store + /var
     ├── base/       (our fat store, optional)      store/  var/
     ├── acme-corp/  (customer store, independent)  store/  var/
     └── acme-labs/  (another customer store)       store/  var/
        │
        │  ┌──────────────────────── boot ────────────────────────┐
        ▼  ▼                                                        │
   ① nix-compose.service   ──►  materialize composed /nix          │
        (NEW, Before=nix-activate)    /nix/store/*        → farm    │
                                      /nix/var/nix/profiles/* → farm│
        ▼                                                           │
   ② nix-activate.service  ──►  union profiles + _meta + defaults, │
        (existing, extended)         shim .desktop, PATH, trust     │
        ▼                                                           │
   ③ window-manager / apps ──►  see one merged store               │
                                 FHS apps → nix-bwrap-run (N-store  │
                                 overlay), everything else → farm   │
                              └──────────────────────────────────────┘
```

### Store layout & discovery

Each store is published as an OCI image with the **same shape as today's fat
store**: `FROM scratch`, payload at `/store` (+ `/var/nix/{db,profiles}`). The
run_config mounts each at a distinct path under `/nix-stores/<id>` (read-only
image mount), **not** at `/nix`:

```json
{ "mounts": [
  { "Target": "/nix-stores/base",     "Source": "registry…/nix-store:nix",       "Type": "image", "ReadOnly": true },
  { "Target": "/nix-stores/acme-corp", "Source": "reg.acme.example/nix-store:v3", "Type": "image", "ReadOnly": true }
] }
```

`nix-compose` discovers stores by globbing `/nix-stores/*/store`. Order is
deterministic (sorted by `<id>`); a `/nix-stores/<id>/priority` file may override
ordering later if collisions on *non*-content-addressed metadata ever matter (they
don't for `/nix/store` itself — see the constraint above).

> **Why not keep mounting at `/nix`?** A store mounted directly at `/nix` is a
> read-only mount — we can't write the composed farm into it. Stores must mount at
> `/nix-stores/<id>` so `/nix` stays a writable image directory that `nix-compose`
> populates. Backward compat for the single-`/nix`-mount case is preserved (see
> § Backward compatibility).

### Component 1 — `nix-compose` (new boot step): the composed `/nix`

A new POSIX-sh script + `nix-compose.service`
(`After=kasm-setup.service`, `Before=nix-activate.service`,
`ConditionPathExistsGlob=/nix-stores/*/store`). It materializes `/nix` as a
**writable real directory whose `/nix/store` and `/nix/var/nix/profiles` are
symlink farms** unioning every mounted store. This is the direct generalization
of the existing single `/nix/store → /store` symlink into a farm over N stores.

```
/nix/store/<hash>-x        → /nix-stores/<id>/store/<hash>-x     (one symlink per top-level path)
/nix/var/nix/profiles/<p>  → /nix-stores/<id>/var/nix/profiles/<p>
/nix/var/nix/db/db.sqlite  → copied to /run/nix-state (writable), first store wins (best-effort)
```

Algorithm (idempotent):

1. `install -d /nix/store /nix/var/nix/profiles`.
2. For each `/nix-stores/<id>/store/*` entry, `ln -sfn` it into `/nix/store/`.
   Content-addressed ⇒ a repeated hash from another store is an identical
   relink (harmless). Independent stores contribute disjoint hashes; both land.
3. For each `/nix-stores/<id>/var/nix/profiles/<p>` (skipping generation
   `-link`s and `_meta.json`), `ln -sfn` into `/nix/var/nix/profiles/`. **Profile
   name collisions across stores are namespaced** `<id>:<p>` (or `<p>` when
   unique) so two customers can both ship a `vscode` profile. `nix-compose`
   writes a `/nix/var/nix/profiles/_stores.json` recording `id → [profiles]`.
4. Merge each store's `_meta.json` `profiles{}` map into a single
   `/nix/var/nix/profiles/_meta.json` (dep graphs unioned; names namespaced to
   match step 3). `nix-activate`'s existing `expand_deps` consumes it unchanged.

**Why a symlink farm, not a session-wide overlay mount?** A real overlay mount
visible to *every* session process (root services + the uid-1000 desktop user)
must be established in a mount namespace that is an ancestor of the whole session,
which in an unprivileged container requires either `CAP_SYS_ADMIN` or wrapping the
entire supervisor in a multi-uid user namespace (`newuidmap`/subuid) — both are
heavier and riskier than warranted. The symlink farm needs **no mount, no
capability, no userns**: `execve`/`open` follow the `/nix/store/<hash>` symlink to
the real file transparently, and every baked path (`/nix/store/...` interpreter +
`RUNPATH`) resolves. A store of ~5–8k top-level paths farms in a couple of seconds
at boot. The one case the farm can't serve — bwrap refusing to traverse a
symlinked store — is handled per-launch by Component 3, exactly as today. A real
session-wide overlay remains available as an opt-in for customers who need it
(§ Alternative).

### Component 2 — `nix-activate` changes

`nix-activate` already does everything needed *against a single* `/nix/var`. With
`nix-compose` having unioned the profile registry into `/nix/var`, the changes are
small:

- **No path changes** — it still reads `/nix/var/nix/profiles/*` and `_meta.json`,
  which are now the composed union. Existing `filter_existing`, `expand_deps`,
  `shim_profile`, `write_profile_d` work unchanged over the union.
- **Namespaced names** — profile names may now be `<id>:<p>`. Adjust the
  shim/`.desktop` basename sanitizer to accept `:` (map to `-` in filenames).
- **Defaults union** (see Component 4) — fold store-declared auto-activate sets
  into `resolve_active` when no explicit selection exists.

### Component 3 — FHS/bwrap apps across N stores

`nix-bwrap-run` today binds one `/store` onto `/nix/store` inside bwrap. For the
composed world it must present the **union** of all store dirs as one real
`/nix/store`. Use bwrap's read-only overlay (bwrap ≥ 0.9.0; Ubuntu noble ships
0.9.0 — **verify the bundled version in the spike**):

```sh
bwrap --dev-bind / / --proc /proc \
      --tmpfs /nix \
      --overlay-src /nix-stores/base/store \
      --overlay-src /nix-stores/acme-corp/store \
      --ro-overlay /nix/store \
      --bind /nix/var /nix/var \
      -- "$real" "$@"
```

Still inside bwrap's own user namespace ⇒ no container caps, same as today. The
store list is read from the same `/nix-stores/*` glob `nix-compose` uses.
**Fallback if `--overlay-src` is unavailable** (older bwrap): bind the single
store that actually contains the target app's closure (resolve via the app's
profile → store `id`), which suffices because an FHS app's closure is
self-contained within its own store.

### Component 4 — auto-activation / pre-configuration (defaults-in-store)

Kasm cannot set container env vars, so a customer's "these apps are on by default
for my users" cannot ride `NIX_APP_PROFILES`. Instead each store **ships its own
defaults**: a `/nix-stores/<id>/var/nix/profiles/_defaults.json`:

```json
{ "autostart": ["acme-corp:vscode", "acme-corp:internal-tool"] }
```

`resolve_active` precedence becomes:

1. `$HOME/.config/nix-app/active` (per-user override — highest)
2. Kasm launch-form selection file (per-session pick)
3. `NIX_APP_PROFILES` (run_config CSV, if any)
4. **union of every store's `_defaults.json` `autostart`** (new — customer
   pre-configuration)

So a customer publishes a store with `autostart` set and their users get those
apps automatically; a launch form (or per-user file) still lets an individual
session pick a different set.

## Runtime flow (boot sequence)

1. `kasm-setup.service` — identity, dbus, cert, password (existing).
2. **`nix-compose.service` (NEW)** — farm `/nix/store` + `/nix/var/nix/profiles`
   from all `/nix-stores/*`, merge `_meta.json`, write `_stores.json`.
3. `nix-activate.service` (existing, extended) — union profiles already present;
   resolve active set (incl. store defaults), shim `.desktop`, PATH/XDG, trust.
4. `window-manager.service` — XFCE enumerates the shims; customer apps appear in
   the menu / Desktop / `PATH` for the whole session.
5. App launch — non-FHS apps resolve straight through the farm; FHS/bwrap apps go
   through `nix-bwrap-run` (N-store overlay).

## The "as code" artifact (customer build + publish)

Workspace-as-code means the customer's package set is a checked-in, reproducible
spec that builds a store image:

- **Spec** — a `nix-profiles.toml` (same schema as `bin/nix-profiles.toml`) or a
  flake, listing the customer's profiles/packages + a pinned nixpkgs rev.
- **Build** — the customer runs `bin/build-nix-store-volume` (or a thinner
  customer wrapper) against *their* config, producing an independent OCI store
  image (full closure — no dependence on our base, per the locked decision).
- **Publish** — push to the customer's own registry.
- **Reference** — add a `mounts` entry to the workspace's `run_config` pointing at
  the store image + set `_defaults.json` in the store for auto-activation.

The declarative surface is therefore: **`nix-profiles.toml` (+ pinned rev) →
store image → `run_config` mount + defaults**. Everything else is derived. Because
stores are independent, a customer needs no coordination with our nixpkgs cadence;
the cost is image size (each store carries its own base libs), which the customer
accepts. (Dedup-against-our-base remains available later as an opt-in optimization
for customers who *do* build on our pin — explicitly out of scope here.)

## Customer extension model

"I want to add/change something" splits into four kinds, each with a different
mechanism, rebuild scope, and Nix-literacy cost. **Not everything should route
through the Nix store** — matching the intent to the cheapest sufficient
mechanism is the point.

| Intent | Mechanism | Rebuild scope | Nix knowledge |
|--------|-----------|---------------|---------------|
| **Run a script** (boot / shutdown / session events, or a supervised daemon) | Kasm hooks (`kasm_hook_scripts/*`), `custom_startup.sh`, or an `/etc/container-init.d/<n>.service` drop-in | none | none |
| **Pre-seed configuration** (policies, defaults, dotfiles, app settings) | well-known config paths on the writable rootfs, via a downstream image layer or a hook (see below) | downstream image (or none, via hook) | none |
| **Add a package in nixpkgs** | one line in `nix-profiles.toml` → rebuild store | store rebuild + redistribute | minimal |
| **Add a deb / rpm / AppImage / custom binary** | **fork** (see below) | store rebuild *or* downstream image | (a) yes / (b) none |

### "Add a package" is one pipeline, three authoring efforts

Cases 3 and 4 are the *same* pipeline — edit the store spec, rebuild,
redistribute — differing only in how much authoring the package needs:

- **In nixpkgs** → one line in the toml. (Covers more than expected; most desktop
  apps are already packaged.)
- **A deb/rpm/AppImage** → a small derivation, then one line in the toml.
  `appimageTools.wrapType2` is near-turnkey; `dpkg` + `autoPatchelfHook` or
  `buildFHSEnv` cover most well-behaved debs in ~20 lines; a gnarly proprietary
  deb becomes a missing-`.so` debugging session.
- **Fully custom** → a full derivation.

### The deb/rpm fork — don't force nixification

"Nixify your .deb" makes Nix literacy a *prerequisite* for the most basic ask
("install this vendor .deb"). That's the wrong default for a chunk of the
audience. There is already a zero-Nix path Kasm customers understand natively:

| Customer wants… | Path | Nix knowledge |
|-----------------|------|---------------|
| "just get this app installed" | conventional downstream image `FROM nix-ubuntu` + `apt`/`dnf install` | none |
| "this app in my *selectable / composable / reproducible* set" | nixify → custom store | yes |

Nixify is right **when the customer wants store semantics** (mountable,
dedup'd, per-session selectable). When they just want the binary present, the
conventional image is far lower friction — and because `nix-ubuntu` is an
ordinary OCI image, `FROM nix-ubuntu` + `RUN apt-get install …` Just Works,
inheriting all the activation machinery for any Nix stores that *are* mounted.

### Pre-seeding configuration

Configuration is neither a script nor a package: dotfiles, app settings, managed
browser policies, default profile contents. Two placement options:

- **Baked** — a downstream image layer copies config to its well-known path
  (`$HOME/kasm-default-profile/…` for per-user seed state, `/etc/…` for
  system/policy config). Deterministic, no runtime cost.
- **Runtime** — a `custom_startup.sh` / post-run hook writes/derives config at
  session start (for anything that depends on identity or per-session values).

The **guiding rule: configuration must land on a *writable rootfs path*, not the
read-only `/nix` store**, so a customer can override it. Anything the platform
ships to such a path is inherently an override point — but only if we (a) keep it
narrow and (b) document the path.

#### Worked example + finding: Chrome managed policies

Chrome/Chromium enterprise policy is the canonical "config as an override point,"
and it's a live example in this repo — so it doubles as a design check:

- **We use the standard mechanism, not a hardcoded compile-time override.**
  `src/ubuntu/install/nix/chrome/post-build.sh` writes the stock enterprise path
  `/etc/opt/chrome/policies/managed/kasm-flags.json` with a *single* narrow key,
  `{"CommandLineFlagSecurityWarningsEnabled": false}` (cosmetic — hides the
  `--no-sandbox` infobar). Chrome merges *all* JSON files in that dir, and the
  file is on the writable rootfs, so a customer can drop their own
  `/etc/opt/chrome/policies/managed/<name>.json` and it layers in. This is
  correct and override-friendly. ✅
- **Gap 1 — per-app-image only.** That wiring tar is baked into the single-app
  `nix-chrome` image. In the *fat-store desktop*, `chrome` is a selectable
  profile with no wiring layer, so the policy file is absent and there is no
  uniform policy override point across the desktop.
- **Gap 2 — `chromium`** (open-source) has no `post-build.sh`, so nothing occupies
  `/etc/chromium/policies/managed/` — a clean slate, but also no consistent
  managed-policy seam with Chrome.

**Recommendation.** Treat managed-policy dirs as a *first-class, documented
configuration override point* rather than an app-image implementation detail:

1. Seed the managed-policy dir(s) at the **desktop/base level** (a
   `nix-compose`-era config step or a base-image layer), not only in per-app
   wiring — so the override point exists whether Chrome comes from a per-app image
   or from a composed store.
2. Keep the platform's own policy footprint to the **minimum necessary** and
   documented (ideally reconsider whether we even need to force
   `CommandLineFlagSecurityWarningsEnabled` — it's an infobar, not security), so
   the customer's key space is maximally free.
3. Document both dirs (`/etc/opt/chrome/policies/managed/`,
   `/etc/chromium/policies/managed/`) in the customer config guide as *the* place
   to layer browser policy. Distinct keys merge; a customer only conflicts if they
   set a key the platform already sets — which we keep near-empty by (2).

The general pattern generalizes to any app with an FHS config/policy convention:
seed at base/desktop level, keep the platform footprint minimal, document the
path.

## Fleet distribution (operator-owned)

The known constraint carries over: **image-volume mounts are local-only — the
daemon will not pull a store image to satisfy a mount.** So every store image must
be present on each agent before a workspace using it launches.

- **k8s agents** — cleanest: image volumes + `imagePullSecrets` pull store images
  like any container image; a `pullPolicy: IfNotPresent` + node image GC policy
  covers it. (See `docs/nix-how-to.md` § k8s.)
- **docker agents** — needs a pre-pull step: node bootstrap / systemd unit that
  `docker pull`s the referenced store images, an AMI bake, or the Route-A fallback
  (`docker export` the store image to a host dir + bind-mount ro at
  `/nix-stores/<id>` with `skip_check:true`).

> Distribution mechanism is **operator-owned and deliberately not baked into the
> image**; the operator (Emrul) has a preferred approach in mind — this section is
> a placeholder to be filled once that lands. The image side only requires that
> the stores be visible under `/nix-stores/<id>` at container start.

## Backward compatibility / migration

- **Single store at `/nix` (today's model)** stays working: if `/nix-stores/*` is
  absent but `/nix/var/nix/profiles/_meta.json` exists (legacy direct mount),
  `nix-compose` is a no-op (its `ConditionPathExistsGlob` skips it) and
  `nix-activate` runs against the direct mount exactly as now.
- **New multi-store model** activates only when the run_config mounts stores under
  `/nix-stores/`. Migration for an existing fat-store workspace is purely a
  run_config edit (retarget the mount from `/nix` to `/nix-stores/base`) — no image
  rebuild required to *consume* it, though `nix-compose` must ship in the base
  image (a `nix-ubuntu` rebuild).

## Security posture / trust boundary

- **Composition adds no privilege.** The symlink farm needs no caps; FHS apps use
  the same bwrap-userns path already in production. No `CAP_SYS_ADMIN`, no
  userns-remap requirement for the base case.
- **Independent customer stores run customer-supplied binaries** in the workspace.
  That is inherent to the feature — the platform must treat a customer store image
  like any customer-supplied workspace image (customer-trusted, not
  platform-vetted). Document this explicitly so operators size the trust boundary
  correctly. No cross-customer exposure: each workspace mounts only its own
  customer's stores.
- **FHS apps still require** the bwrap run_config (`apparmor=unconfined` + mount
  seccomp) the fat store already uses — no *new* relaxation beyond what shipping.

## Alternative — real session-wide overlay mount (opt-in)

For customers who need a *real* `/nix/store` directory session-wide (e.g. tooling
that rejects a symlinked store, or in-session `nix` CLI operations), a real
overlay mount is available as an opt-in, at a privilege cost:

- **`CAP_SYS_ADMIN` path (simplest):** grant the workspace `cap_add: SYS_ADMIN`
  (run_config); `nix-compose` mounts `overlay` at `/nix/store` directly at boot,
  before the desktop starts. Clean, multi-uid works natively. Cost: the workspace
  holds `CAP_SYS_ADMIN`.
- **Unprivileged userns-wrap path (no added caps):** re-exec the supervisor inside
  a user namespace with a `newuidmap`/subuid **range** mapping (so both uid 0 and
  the desktop uid 1000 are valid), overlay-mount there, whole session inherits.
  Cost: engineering + subuid tooling in the image + files-owned-by-`nobody` edge
  cases. Kernel ≥ 5.11 for unprivileged overlay in a userns.

The symlink-farm default is recommended; this section is the escape hatch, not the
primary path.

## Known limitations / future work

1. **Merged Nix db is best-effort.** `nix-compose` copies one store's `db.sqlite`;
   the runtime `nix-app info` closure-size queries are only accurate for paths in
   that db. Launching is unaffected (absolute-path `Exec=`). A real merge needs
   `nix-store --load-db` per store into the writable `/run/nix-state` db — a later
   refinement if `nix-app info` accuracy across stores becomes wanted.
2. **Profile-name namespacing UX.** `<id>:<p>` names are unambiguous but ugly in
   the menu; a display-name mapping (from each store's `_meta.json`) can prettify
   the shim `Name=` while keeping the namespaced key.
3. **bwrap `--overlay-src` version floor.** Requires bwrap ≥ 0.9.0; verify on every
   base distro (noble ok; older/alt distros need the single-store-bind fallback).
4. **Farm rebuild cost scales with store size.** ~5–8k symlinks/store is trivial;
   a pathological store (tens of thousands of paths) would want the real overlay
   path instead. Measure in the spike.
5. **Distribution mechanism unspecified** (operator-owned; see § Fleet
   distribution) — pending Emrul's preferred approach.

## Verification plan (spike)

1. Build two **independent** small store images (different nixpkgs pins, each with
   a distinct GUI app + one shared app name to exercise namespacing).
2. Mount both under `/nix-stores/{a,b}`; boot; confirm `nix-compose` farms
   `/nix/store` + profiles and `_stores.json` lists both.
3. Confirm both apps appear in the XFCE menu, on the Desktop, and on `PATH`;
   launch each (non-FHS) — resolves through the farm.
4. Add an FHS app (OnlyOffice) to store B; launch via `nix-bwrap-run`; confirm the
   N-store `--overlay-src` overlay presents its glibc correctly.
5. Set `_defaults.json` `autostart` in store A; boot with no launch-form/env
   selection; confirm A's apps auto-activate and B's don't.
6. Regression: mount a single legacy store at `/nix` (no `/nix-stores`); confirm
   `nix-compose` no-ops and behavior is identical to today.
</content>
</invoke>
