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
  pin.json               # { version, hashes.<system>, … } — the updater writes this
manifest.toml            # kind / discover / cadence / platforms per app
```

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
