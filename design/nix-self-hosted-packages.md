# Self-hosted Nix packages (fast-cadence + not-in-nixpkgs apps)

Status: design + phased rollout. Companion to `design/nix-package-process.md`
(the store/build pipeline) and `design/nix-dedup-gap.md` (layer dedup).

## Problem

The Nix app catalog (`bin/nix-profiles.toml`) is built entirely from upstream
nixpkgs attributes. Two needs are not served by that:

1. **CVE cadence.** For security-critical apps (Chrome first) we need patches
   faster than nixpkgs commits them. Measured cadence of `google-chrome` on
   nixpkgs (both `nixos-unstable` and the `release-25.05` *stable* branch — they
   carry identical, backported bumps) is **~weekly, worst-case ~2 weeks**, plus a
   1–3 day channel-advance lag, plus our own build cadence on top. nixpkgs also
   does not reliably fast-track Google's out-of-band 0-day patches. Kasm's own
   Chrome workspace consumes Google's `.deb` directly and rebuilds twice daily
   (~12h behind Google). We want to match that for the Nix images.

2. **Apps nixpkgs doesn't have at all.** Some target apps (e.g. nessus,
   maltego, hunchly, cyberbro — see `nix-package-process.md`) need a derivation
   we write and maintain ourselves.

Both are the same underlying capability: **owning the version pin and/or the
derivation for selected apps, on a per-app cadence, without breaking the
single-store dedup guarantees.**

## Non-goals

- Per-package rev pinning of the *whole* catalog. The catalog stays on floating
  refs resolved once per build (`nix-profiles.toml` `[nixpkgs].ref` +
  per-profile `ref`). Self-hosting is opt-in per app.
- Forking nixpkgs packaging. Where nixpkgs already packages an app well
  (Chrome), we reuse its derivation and override only version+src.

## The three-layer model

The scaling mistake is fusing "how to build", "how to find the latest version",
and "the pinned answer" into one per-app script. Keep them separate — this is
how nixpkgs itself operates (`nix-update` + `passthru.updateScript`):

| Layer        | What                                              | Per-app artifact                         |
| ------------ | ------------------------------------------------- | ---------------------------------------- |
| **Build**    | derivation: source → store path                   | `pkgs/<profile>/package.nix`             |
| **Pin**      | reproducible answer: exact version + SRI hash(es) | `pkgs/<profile>/pin.json` (committed)    |
| **Discover** | how to find the newest version + fetch URL        | `pkgs/<profile>/update` (or nix-update)  |

Flow: an updater runs **Discover** → writes **Pin** → commits. The build only
ever reads the committed **Pin**, so every build is reproducible and every bump
is a reviewable diff with a supply-chain-auditable hash. The updater's commit
trips the change-gate and rebuilds only that app.

## One overlay flake, following the caller's nixpkgs

All self-hosted packages live in a single overlay flake at
`bin/nix-kasm-overlay/`, mounted into the inner build at `/config/kasm-overlay`
(same mechanism as `nix-gpu-overlay` / `nix-steam-overlay`, see
`build-nix-store-volume` ~line 1061). Layout:

```
bin/nix-kasm-overlay/
├── flake.nix          # inputs.nixpkgs (default ref); outputs packages.<system>.<profile>
├── flake.lock         # committed so the read-only (:ro) mount never needs a write
├── overlay.nix        # final: prev: { <profile> = import ./pkgs/<profile> {...}; ... }
├── lib/
│   └── loadPin.nix    # builtins.fromJSON (readFile ./pin.json) helper
├── pkgs/
│   └── chrome/        # dir named after the PROFILE (not the nixpkgs attr)
│       ├── package.nix
│       ├── pin.json   # { version, hashes: { x86_64-linux: "sha256-…" } }
│       └── update     # discoverer (writes pin.json)
└── README.md
```

### The single-glibc rule (critical)

A self-hosted app must build against **the same nixpkgs rev as its ref-class
peers**, or it ships a second glibc and defeats store dedup. The
`nix-gpu-overlay` solves this by manually re-pinning its `flake.lock` to the
branch HEAD — viable at the base's ~6-month cadence, **not** viable for an app
tracking `nixos-unstable` that bumps twice a week.

Instead, the build **overrides the overlay's nixpkgs input at install time**:

```sh
nix profile install --impure \
    --override-input nixpkgs "github:NixOS/nixpkgs/<resolved-rev>" \
    "path:/config/kasm-overlay#chrome"
```

`<resolved-rev>` is the profile's already-resolved concrete rev (`p_ref`,
`build-nix-store-volume` ~line 487) — the same rev its peer browsers use. Result:

- Chrome's runtime deps (glibc, gtk, nss, …) are byte-identical to firefox /
  brave / vivaldi → one glibc, full dedup.
- **No manual re-pin.** The committed `flake.lock` exists only so the `:ro`
  mount never triggers a lockfile write; its nixpkgs entry is always overridden.

The overlay's own `[nixpkgs].url` default should be `nixos-unstable` (matches the
browser ref-class) so local `nix build` without an override still resolves sanely.

## Two package kinds

**Kind A — override** (nixpkgs has it; we want it fresher). Reuse 100% of
upstream packaging, swap only version+src from the pin. nixpkgs' `google-chrome`
*is* Google's official `.deb` repackaged, so this is a two-field override:

```nix
# pkgs/chrome/package.nix
{ prev, pin }:            # pin = fromJSON (readFile ./pin.json)
prev.google-chrome.overrideAttrs (o: {
  version = pin.version;
  src = prev.fetchurl {
    url = "https://dl.google.com/linux/chrome/deb/pool/main/g/"
        + "google-chrome-stable/google-chrome-stable_${pin.version}-1_amd64.deb";
    hash = pin.hashes.x86_64-linux;
  };
})
```

**Kind B — from scratch** (nixpkgs lacks it). Full derivation; deps drawn from
`prev`/`final` (the overridden nixpkgs) so it still dedups. Pick the technique by
source shape, same as nixpkgs:

- prebuilt binary / `.deb` / AppImage → `stdenvNoCC.mkDerivation` +
  `autoPatchelfHook`, or `buildFHSEnv`, or `appimageTools`
- from source → the language builder (`buildGoModule`, `buildNpmPackage`, …)

Both kinds are driven by an identical `pin.json` shape, so the updater and the
eval-gate treat every self-hosted app uniformly.

## Discover / updater

Prefer **`nix-update`** (the standard nixpkgs tool) wherever the app has a
regular version source (GitHub releases, an apt pool, a version API). Only write
a custom `update` script for irregular discovery.

Chrome's discoverer (custom, because version comes from an API and the artifact
is an apt-pool `.deb`):

1. `GET https://versionhistory.googleapis.com/v1/chrome/platforms/linux/channels/stable/versions`
   → newest stable `version`.
2. Construct the `.deb` URL from `version`.
3. `nix store prefetch-file --json <url>` → SRI `hash`.
4. **Supply-chain check** (per org security policy): verify the artifact against
   Google's signed apt `Release`/`Packages` (GPG) before trusting the hash — the
   SRI pin guarantees reproducibility, the signature check guarantees provenance.
5. Write `pkgs/chrome/pin.json`, `git commit` (message `chrome: <old> -> <new>`).

Arm64 caveat: Google ships **no** arm64 Linux Chrome (`.deb` is amd64-only;
nixpkgs marks `platforms = darwin ++ x86_64-linux`). On arm64 the `chrome`
profile falls back to `chromium` (existing behaviour — the overlay package is
`platforms = ["amd64"]` and arm64 builds simply skip it).

## Manifest (adding an app is data, not code)

`bin/nix-kasm-overlay/manifest.toml` lists each self-hosted app so the updater
and schedules are data-driven:

```toml
[apps.chrome]
kind      = "override"           # override | binary | source
discover  = "chrome-version-api" # or "github-releases:owner/repo", "nix-update"
cadence   = "twice-daily"        # drives which schedule runs its updater
platforms = ["x86_64-linux"]
```

Adding an app = one manifest entry + one `pkgs/<profile>/` dir. The updater
iterates the manifest filtered by `cadence`.

## Integration with the existing pipeline

- **`nix-profiles.toml`**: a self-hosted profile references the overlay instead
  of `nixpkgs#…`:
  ```toml
  [profiles.chrome]
  pkgs = ["path:/config/kasm-overlay#chrome"]
  ref  = "github:NixOS/nixpkgs/nixos-unstable"   # the rev the overlay follows
  platforms = ["amd64"]
  ```
  The profile's `ref` is what gets passed as `--override-input nixpkgs`.

- **Install loop** (`build-nix-store-volume` ~line 497): when a profile's pkgs
  include a `path:/config/kasm-overlay#…` entry, add
  `--override-input nixpkgs "$p_ref"` to that profile's `nix profile install`.
  (Chrome's profile is overlay-only, so the global override is unambiguous.)

- **Overlay mount** (~line 1061): add, mirroring gpu/steam —
  ```sh
  [[ -d "${SCRIPT_DIR}/nix-kasm-overlay" ]] && \
    inner_run_args+=( --volume "${SCRIPT_DIR}/nix-kasm-overlay:/config/kasm-overlay:ro" )
  ```

- **Change-gate** (`ci-scripts/nix-changed-profiles.sh`): add a rule mapping
  `bin/nix-kasm-overlay/pkgs/<app>/*` → app `<app>` (per-app granularity, so a
  pin bump rebuilds only that app), and `bin/nix-kasm-overlay/{flake.*,overlay.nix,lib/*}`
  → whole catalog (shared overlay machinery changed).

- **Eval-gate** (new, `NIX_EVAL_GATE=1`): a pre-pass before the install loop.
  For each selected profile, `nix eval` every pkg's `.outPath` (with the same
  `--override-input` for overlay pkgs), sort, hash → `pkgHash`. Compare to
  `apps[p].pkgHash` in `labels.prev.json`. If equal, the profile is unchanged —
  drop it from `selected.txt` so it is not re-realized or re-assembled. `pkgHash`
  is added to the label schema (`APPLABELS` ~line 514 and `labels.json` ~line
  746). Missing `pkgHash` (first run after deploy) ⇒ treat as changed (safe).
  Rationale: `nix eval outPath` is evaluation-only (seconds, no realize); it
  replaces a full `profile install` (evaluate closure + substitute) for every
  unchanged app, which is the bulk of a scheduled full build's cost. The
  publish-side push-skip (registry `store-path` label compare in
  `nix-publish.sh:classify`) remains the backstop against build-vs-published
  drift.

## Cadence: schedules

Create two GitLab pipeline schedules (Settings → CI/CD → Schedules), alongside
the existing GC schedule, each just a schedule variable:

1. **Chrome / fast-cadence** — every 12h, variable `NIX_UPDATE=twice-daily`.
   The `nix-update` job refreshes `cadence=twice-daily` pins (Chrome), exports
   the bumped `pin.json` as an artifact that `build` consumes, and ships it in
   the same pipeline. The twice-daily schedule sets `NIX_PROFILES=chrome`, so
   the run is surgical: when Chrome released, the pin bumps and chrome rebuilds
   + publishes; when it hasn't, `NIX_EVAL_GATE` (on by default) skips the
   reinstall and it's a near-noop. ~12h behind Google's stable.
2. **Browser ref-class advance** — weekly, variable `NIX_UPDATE=weekly` (or just
   an empty scheduled run). Re-resolves the floating `nixos-unstable` ref; the
   eval-gate's input key includes the resolved rev, so all browsers on that ref
   rebuild together (shared glibc, deduped) while base-pinned apps stay warm.

Both are ordinary `schedule`-source pipelines (no `NIX_GC`). The `nix-update`
job's audit commit + push (repo reflects what shipped) needs a masked CI
variable **`NIX_UPDATE_TOKEN`** = a project/group access token with
`write_repository`. Without it the pin still ships (via artifact) but is not
pushed to git — a warning is logged. The push uses `-o ci.skip` so it never
triggers a redundant pipeline.

## Rollout (this change set)

1. **This doc.**
2. **Overlay skeleton + Chrome** (Kind A reference): `bin/nix-kasm-overlay/`
   with `pkgs/chrome`, wired into `nix-profiles.toml` + the install loop +
   the overlay mount.
3. **Eval-gate** in `build-nix-store-volume` (`NIX_EVAL_GATE=1`).
4. **Chrome updater** + supply-chain check.
5. **CI schedules** + change-gate rules for the overlay tree.
6. *(Later)* first **Kind B** app to prove the not-in-nixpkgs path end-to-end.

Each step is independently testable; Chrome earns its keep immediately.

## Security / governance notes

- Always pin `src` by SRI hash (`fetchurl { hash = … }`) — never a floating URL.
- Verify upstream signatures/provenance where the vendor provides them (Google's
  signed apt repo for Chrome) in addition to the SRI pin. Do not fabricate CVE
  IDs in updater output; reference Google's release notes URL for the version.
- Auto-committed pin bumps still pass the existing Trivy scan
  (`ci-scripts/scan/`) and the build report (`nix-build-report.{json,md}`)
  records the store-path change, giving a full audit trail.
