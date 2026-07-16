# nix-kasm-overlay

Self-hosted Nix packages for the Kasm app catalog: apps we want to patch faster
than nixpkgs commits them (Chrome), and apps nixpkgs doesn't package at all.

Full design: [`design/nix-self-hosted-packages.md`](../../design/nix-self-hosted-packages.md).

## How it plugs in

- Mounted into the inner build at `/config/kasm-overlay` (see
  `bin/build-nix-store-volume`, alongside `nix-gpu-overlay` / `nix-steam-overlay`).
- A profile in `bin/nix-profiles.toml` references a package here:
  ```toml
  [profiles.chrome]
  pkgs = ["path:/config/kasm-overlay#chrome"]
  ref  = "github:NixOS/nixpkgs/nixos-unstable"   # rev the overlay follows
  platforms = ["amd64"]
  ```
- The build passes `--override-input nixpkgs github:NixOS/nixpkgs/<rev>` so the
  package builds against the profile's ref-class rev → **one glibc, full dedup**.
  No manual `flake.lock` re-pin (unlike the gpu/steam overlays).

## Layout

```
flake.nix / flake.lock   # nixpkgs input (always overridden by the build)
overlay.nix              # final: prev: { <profile> = …; }
pkgs/<profile>/
  package.nix            # the derivation (override or from-scratch)
  pin.json               # the committed pin (source of truth) — see below
manifest.toml            # kind / discover / cadence / platforms per app
```

## Pin config & private builds

`pkgs/<app>/pin.json` is the committed source of truth for what each package
builds. Its shape depends on the package:

- **Chrome** (`kind A`, repackage an upstream release): `{ version,
  hashes.<system>, … }` — the twice-daily updater writes this.
- **KasmVNC** (`kind B`, repackage a Kasm S3 build artifact): `{ kasmvnc_ver,
  branch, commit_id, codename, arch, hash }` — KasmVNC has no public git, so the
  pin references a specific `commit_id` Kasm published to the public S3, plus its
  SRI `hash`. `codename` stays `noble` no matter the target distro (we take the
  noble `.deb` and autoPatchelf it → distro-independent).

**Testing a private build without editing the committed pin.** Any top-level
string field is overridable from the environment as `KASM_PIN_<APP>_<FIELD>`
(both upper-cased), honored **only** under `nix build --impure`:

| want to test | env |
|---|---|
| a private KasmVNC commit | `KASM_PIN_KASMVNC_COMMIT_ID=<sha>` |
| …on a private branch | `KASM_PIN_KASMVNC_BRANCH=<branch>` |
| …with the matching hash | `KASM_PIN_KASMVNC_HASH=sha256-…` |
| a specific Chrome version | `KASM_PIN_CHROME_VERSION=<ver>` |

```bash
# 1. compute the hash of your artifact URL (printed url = nix eval .#kasmvnc.src.url)
nix store prefetch-file "https://kasmweb-build-artifacts.s3.amazonaws.com/kasmvnc/<sha>/kasmvncserver_noble_<ver>_<branch>_<sha6>_amd64.deb"
# 2. build against your override (‑‑impure is required for env to be read)
KASM_PIN_KASMVNC_COMMIT_ID=<sha> KASM_PIN_KASMVNC_BRANCH=<branch> \
KASM_PIN_KASMVNC_HASH=sha256-… nix build --impure .#kasmvnc
```

In normal (pure) evaluation `builtins.getEnv` returns `""`, so the committed pin
always wins — **CI and production builds ignore the environment entirely and stay
deterministic**. Nested objects (Chrome's per-system `hashes`) aren't
overridable; edit the pin for those.

## Version / tracking policy

- **Chrome** — floats with Google's stable channel via `bin/nix-kasm-update`
  (twice daily); pins are auto-bumped and committed. No manual policy needed.
- **KasmVNC** — a **manual, reproducible pin** (the S3 URL is keyed by
  `commit_id`, so there is no floating ref to follow). Production should track a
  **`release`-branch** commit; use a feature branch only when a specific feature
  is required. The current pin is `feature_touch-device-support` @ `a4b74a8` — a
  spike for touch support; move it to a release commit before productionizing.
  Bump by updating `pin.json` (or env-override first to test), mirroring the
  `COMMIT_ID` bump in `src/ubuntu/install/kasm_vnc/install_kasm_vnc.sh`.

## Adding an app

1. `pkgs/<profile>/package.nix` — override a nixpkgs attr, or a full derivation.
2. `pkgs/<profile>/pin.json` — seed version + SRI hash(es).
3. Add the attribute to `overlay.nix` and `flake.nix` `packages`.
4. Add a `[apps.<profile>]` block to `manifest.toml`.
5. Add `[profiles.<profile>]` to `bin/nix-profiles.toml` pointing at the overlay.

The change-gate (`ci-scripts/nix-changed-profiles.sh`) maps
`bin/nix-kasm-overlay/pkgs/<app>/*` → that app, so a pin bump rebuilds only it.

## Updating pins

`bin/nix-kasm-update [--cadence twice-daily|weekly] [app…]` refreshes pins from
each app's `discover` source and commits `<app>: <old> -> <new>`. Run twice
daily for Chrome; the commit trips the change-gate and rebuilds only that app.
