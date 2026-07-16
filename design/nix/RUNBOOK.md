# Nix pipeline runbook — operations & troubleshooting

Operational guide for the Nix app-image pipeline: what runs where, how to drive
it, and the non-obvious failure modes we've hit (so you don't re-debug them).
For the *design* rationale see `design/nix-package-process.md`,
`design/nix-self-hosted-packages.md`, `design/nix-dedup-gap.md`, and the
operator-flow docs `docs/ci_cd_flow.md` / `docs/nix-ci.md`.

CI project: `labs-sandbox/kasm-nix` on gitlab.com, self-hosted **`nix-builder`**
runner (forge box, podman-in-podman against a persistent store at
`/srv/nix-build`). `kasm-nix` is that project's **default branch**.

---

## 1. Where things live

| Concern | Files |
| --- | --- |
| Pipeline definition | `.gitlab-ci.yml` |
| Store build (fat store + per-app) | `bin/build-nix-store-volume`, `bin/nix-crane-assemble` |
| App catalog (what to build) | `bin/nix-profiles.toml` |
| Self-hosted packages (Chrome, …) | `bin/nix-kasm-overlay/` + updater `bin/nix-kasm-update` |
| Base images (per distro) | `ci-scripts/nix-base-build.sh`, `ci-scripts/nix-base-check.sh`, `dockerfile-nix-{ubuntu,fedora,alpine}`, `dockerfile-kasm-core-*` |
| Change-gating | `ci-scripts/nix-changed-profiles.sh` |
| Publish | `ci-scripts/nix-publish.sh` (apps + fat store), `ci-scripts/nix-publish-base.sh` (bases) |
| Runtime app-launch hooks | `src/ubuntu/install/nix/scripts/{nix-activate,nix-launch,nix-bwrap-run,nix-app,nix-gpu-run,nix-gpu-setup}` (shared by all 3 distros) |
| CI token setup | `ci-scripts/setup-nix-update-token.sh` |

---

## 2. Pipeline & schedules

Stages: `prepare → base → build → publish → maintenance`. Jobs:

- **prepare** — `nix-changed-profiles.sh` → `NIX_PROFILES` + `NIX_BASE_AFFECTED`
  + `NIX_BASES_AFFECTED` (dotenv).
- **base-check** (prepare stage) — unions changed base inputs with upstream
  source-image digest staleness → `NIX_BASES_REBUILD`.
- **nix-update** (prepare stage, only when `NIX_UPDATE` set) — refreshes
  self-hosted pins, hands them to `build` via artifact.
- **base** — rebuilds the stale/affected distro bases (parallel, then serial
  retry). Skips fast when all fresh.
- **build** — `build-nix-store-volume --emit-app-images` → fat store + per-app
  images. `needs: base` (waits for a fresh base).
- **publish** / **publish-base** — push apps+fat store / rebuilt bases.
- **gc** (maintenance, only when `NIX_GC=1`).

**Schedules** (GitLab → Settings → CI/CD → Schedules; manage with `glab schedule`):

| Purpose | Cron (UTC) | Variables |
| --- | --- | --- |
| Chrome + unstable refresh | `0 6,18 * * *` | `NIX_UPDATE=twice-daily` |
| Store GC | (weekly) | `NIX_GC=1` |

The twice-daily run is whole-catalog: `nix-update` bumps the Chrome pin, `build`
advances `nixos-unstable` and rebuilds only what changed (eval-gate), `base-check`
catches upstream base-image drift. Most runs are near-noops.

---

## 3. The four gating layers (why builds stay cheap)

Each is fail-safe (uncertainty → do the work). Full detail:
`design/nix-self-hosted-packages.md` § "Build decision flow".

1. **Change-gate** (`nix-changed-profiles.sh`) — git diff → which profiles/bases
   enter the build. Schedule / shared-file change → whole catalog.
2. **Eval-gate** (`NIX_EVAL_GATE=1`, **on by default**) — skips *reinstalling* a
   profile whose input key (resolved rev + pkg attrs + overlay sources) is
   unchanged; keeps the warm profile. Fat store stays complete.
3. **Assembly-gate** (`CHANGED_ONLY`) — on full builds, crane assembles per-app
   images only for profiles that actually rebuilt (`changed.txt`); fat store is
   always assembled in full.
4. **Publish-gate** (`nix-publish.sh`) — push-skips an image whose
   `dev.kasm.nix.store-path` already matches the registry.

---

## 4. Self-hosted packages (Chrome, and apps not in nixpkgs)

Design: `design/nix-self-hosted-packages.md`. In short: `bin/nix-kasm-overlay/`
overrides a nixpkgs package (or defines a new one) with a committed `pin.json`;
the build passes `--override-input nixpkgs <rev>` so it shares its ref-class
peers' glibc (one glibc). Chrome tracks Google's stable channel ~12h behind.

**Refresh a pin manually:**
```sh
bin/nix-kasm-update [--cadence twice-daily|weekly] [--commit] [app…]
```
Requires `curl`, `jq`, `openssl` (no nix). Verifies the artifact against the
vendor's signed index before pinning.

**Audit-commit push token:** the scheduled `nix-update` job pushes the pin bump
so git reflects what shipped. It needs a masked+protected CI var
`NIX_UPDATE_TOKEN`. Provision/rotate:
```sh
ci-scripts/setup-nix-update-token.sh          # project token, write_repository, 1y
```
Without it the pin still ships (artifact) but isn't pushed — the job warns.

**Add a new self-hosted app:** `bin/nix-kasm-overlay/pkgs/<profile>/{package.nix,pin.json}`,
add it to `overlay.nix` + `flake.nix` packages + `manifest.toml`, point
`[profiles.<profile>]` in `nix-profiles.toml` at `path:/config/kasm-overlay#<profile>`.
See the overlay's `README.md`.

### 4.1 What an `overlay.nix` / `flake.*` change rebuilds (change-gate scoping)

The overlay feeds exactly two kinds of consumer, so the change-gate scopes an
overlay-**shared** change (`overlay.nix`, `flake.nix`, `flake.lock`, `lib/*`) to
*those consumers only* — **never the whole catalog** (the other ~49 apps use
plain nixpkgs and cannot be affected):

1. **Overlay-backed catalog apps** — profiles whose `pkgs` reference
   `path:/config/kasm-overlay#…` in `bin/nix-profiles.toml`. **Today: `chrome`.**
2. **Distro bases that bake overlay components** — bases whose recipe in
   `ci-scripts/nix-base-build.sh` runs `nix-bake-closure --pkg …`. **Today:
   `resolute`** (KasmVNC, profile-sync, audio-input, recorder, webcam, gamepad).

So the current value, in the `overlay.nix|flake.*|lib/*` arm of
`nix-changed-profiles.sh`, is `apps="chrome"` + `BASES_AFFECTED="resolute"`
(eval-gate no-ops chrome if its inputs didn't actually change).

> **This is not a dev-vs-prod toggle — it is the real consumer set, and it grows
> with adoption.** It is driven by two product decisions, not by environment:
> - **Self-host another app** (fast-cadence, or not-in-nixpkgs, like chrome) →
>   add it to the app side.
> - **Migrate another distro off its per-distro service artifacts** onto the
>   Nix-baked services (the cross-distro goal) → that distro gains `--pkg` bake
>   lines in `nix-base-build.sh`, so add it to the base side. If noble/fedora/
>   alpine adopt the Nix KasmVNC/profile-sync/etc., the base side becomes
>   `resolute ubuntu fedora alpine`.
> - If chrome stays the only self-hosted app **and** resolute the only
>   Nix-services base, then **`chrome + resolute` is the correct, permanent
>   production value** — nothing to change.

Whole-catalog is never right for an overlay change: it was the old behaviour and
is what filled the forge build disk (every overlay edit rebuilt all ~50 apps +
republished the fat store, then starved the next pipeline's checkout).

**Keep it from drifting:**
- **App side is derivable** — `grep -oE 'kasm-overlay#[a-z0-9_-]+' bin/nix-profiles.toml`.
  Prefer deriving over a hardcoded list.
- **Base side** must match exactly the bases with `nix-bake-closure --pkg` lines
  in `nix-base-build.sh`. Adding a base to the bake is a deliberate multi-file
  edit — update this arm in the same change (or derive it from there).

---

## 5. Base images (auto-rebuild)

`base-check` decides which distro bases (ubuntu/fedora/alpine) need rebuilding —
union of **changed base inputs** (`src/common`, `src/<distro>`, base dockerfiles)
and **upstream source-image digest drift** (`ubuntu:24.04` / `fedora:42` /
`alpine:3.21`, checked on publishing pipelines). `base` rebuilds only those, in
**parallel then serial-retry**; `publish-base` republishes them.

**Force a rebuild of specific distros** (web pipeline or `glab ci run`):
```
BASE_DISTROS="ubuntu fedora alpine"   # pipeline variable
```

> ### ⚠️ INVARIANT: keep `dockerfile-nix-{ubuntu,fedora,alpine}` in lockstep
> They must COPY the **same** `src/ubuntu/install/nix/scripts/*` set and install
> the **same host deps**. `nix-launch` execs `nix-bwrap-run` for *every* app, and
> buildFHSEnv apps need a host `/usr/bin/bwrap`. If a distro's dockerfile omits a
> script or dep that another has, apps break **only on that distro** — see §6.
> When you touch the nix scripts a dockerfile copies, update all three.

---

## 6. Troubleshooting (symptom → cause → fix)

### Apps don't launch on fedora/alpine, but Chrome does (ubuntu fine)
**Cause:** that distro's `dockerfile-nix-<distro>` is missing `nix-bwrap-run`
(and/or `bubblewrap`). `nix-launch` does `exec nix-bwrap-run "$@"` for every app →
`nix-bwrap-run: not found` → all launches fail. Chrome uses its own launcher, so
it's unaffected (that's the tell).
**Fix:** COPY+chmod `nix-bwrap-run` and self-heal `bubblewrap` in that dockerfile
(mirror `dockerfile-nix-ubuntu`), then rebuild+publish that base (`BASE_DISTROS`).
This is the §5 invariant; fixed in commit `9e6030f`.

### buildFHSEnv app (OnlyOffice, Steam) fails: `bwrap: Can't mkdir parents for /nix/store/<glibc>/etc`
**Cause:** the assembled image keeps the store at `/store` with `/nix/store` a
symlink; bwrap won't traverse it. `nix-bwrap-run` fixes this by running the app in
an outer bwrap that presents a real `/nix/store` — but only if host
`/usr/bin/bwrap` exists.
**Fix:** ensure `bubblewrap` is installed in the base (§5 invariant).

### Alpine base build fails: `temporary error (try again later)` → cascade of `no such package` for packages that exist
**Cause:** NOT the alpine dockerfiles. Building distros in **parallel** rate-limits
alpine's `apk` against `dl-cdn.alpinelinux.org` (it re-fetches main+community+edge
indexes on every `apk add --no-cache`); a failed index fetch → bogus
"no such package". Proven: alpine builds cleanly **alone**.
**Fix (already in place):** `nix-base-build.sh` builds parallel, then **serial-retries**
failures (`BASE_BUILD_ATTEMPTS`, backoff `BASE_BUILD_BACKOFF`) once contention
clears. If dl-cdn is having a sustained bad window, re-run, or force just that
distro: `BASE_DISTROS=alpine`. `cups-pdf` isn't in alpine v3.21 (only edge) — the
printer install pulls it from `@edge-community`, an inherent extra failure point.

### `base` job fails with `execution took longer than 1h0m0s`
**Cause:** GitLab's default 1h job timeout; a full 3-distro rebuild + retries
exceeds it.
**Fix (in place):** the `base` job has `timeout: 3h`.

### Only critical distro failures should block the app build
Non-critical distro failures (fedora/alpine) are **tolerated** — `base` exits 0
and `build` proceeds on the fresh ubuntu base. Only `ubuntu` (the app base,
`CRITICAL_DISTROS`) failing fails the job. Check the `[base] ... tolerated
failures: …` summary line.

### Fat store / per-app registry dedup drift
The fat store MUST publish from the same build as the per-app images
(`PUBLISH_FAT_STORE=1`, default). See `design/nix-dedup-gap.md`.

### Chrome not updating
Check: the twice-daily schedule ran (`glab ci list`), `nix-update` job logs
(`chrome: up to date` vs a bump), and `NIX_UPDATE_TOKEN` is set (else the pin
ships but isn't committed). Nixpkgs stable == unstable for Chrome (~weekly);
self-hosting is what gets us to ~12h.

### App launch: GL / GPU issues on musl (alpine)
Expected — `nix-activate` skips the system-GL compat dir on musl; apps use their
bundled (glibc) mesa/llvmpipe (software render). See `design/nix/LIMITATIONS.md`
and `[[nix-app-gpu-and-launch]]` notes.

---

## 7. glab cheat-sheet (project `-R kasm-technologies/labs-sandbox/kasm-nix`)

```sh
# Trigger a scoped app build
glab ci run -b kasm-nix --variables NIX_PROFILES:chrome

# Force a base rebuild of specific distros (no app rebuild)
glab ci run -b kasm-nix --variables 'BASE_DISTROS:ubuntu fedora alpine' \
                        --variables NIX_PROFILES:__none__

# Run a schedule now / list / manage
glab schedule list ; glab schedule run <id>

# Watch a pipeline / read a job log
glab ci get -p <pipeline-id>
glab api "projects/<enc-path>/jobs/<job-id>/trace"

# Provision/rotate the pin-push token
ci-scripts/setup-nix-update-token.sh
```

> Note: base rebuilds and app changes are automatic on push (change-gated). Any
> push touching `bin/build-nix-store-volume`, `bin/nix-crane-assemble`, or
> `bin/nix-profiles.toml` triggers a whole-catalog build on its own — don't also
> trigger one manually. Use `git push -o ci.skip` for config/doc-only pushes.
