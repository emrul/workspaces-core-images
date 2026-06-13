# Nix-store-as-OCI-volume + nix-ubuntu image

## Context

We want to ship heavyweight desktop apps (Chromium, Audacity, OnlyOffice,
Slack, VS Code, and future additions) without baking them into the kasm
core image. A core image with all of these would balloon past 5 GiB and
force a full re-pull on every app update. The alternative: build the apps
once into a content-addressed Nix store, publish that store as a
multi-layer OCI image (one layer per profile + base + meta), and mount it
read-only into a new `nix-ubuntu` image at runtime. Updating any
single app then means re-emitting one layer — registries and clients pull
only the delta.

The work is additive: it does not alter the existing 7
`dockerfile-kasm-core*` variants or their boot path. It adds one
top-level Dockerfile, one image-specific build script, and a per-image
extension-point unit under `/etc/container-init.d/`.

## Architecture (end-to-end)

```
                build-time (operator)                          runtime (per session)
   ┌────────────────────────────────────────┐      ┌──────────────────────────────────┐
   │  bin/build-nix-store-volume            │      │ kasmweb/nix-ubuntu:<tag>    │
   │                                        │      │   (FROM kasmweb/core-ubuntu-     │
   │  - reads bin/nix-profiles.toml         │      │      noble:<core-tag>)           │
   │  - spins up a nixos/nix builder        │      │                                  │
   │    container with $stage/nix mounted   │      │  + /etc/container-init.d/        │
   │  - nix profile install per profile     │      │      nix-activate.service   │
   │    into $stage/var/nix/profiles/       │      │  + /usr/local/bin/               │
   │  - partitions store across layers      │      │      nix-activate           │
   │    (base + per-profile + meta)         │      │      nix-app          (CLI)     │
   │  - emits multi-layer OCI image         │      │                                  │
   │      kasmweb/nix-store-<arch>:<tag>    │      │  no Nix install in image —       │
   └────────────────────────────────────────┘      │  PATH/desktop integration only   │
                       │                            └──────────────────────────────────┘
                       ▼                                            │
              registry / local store                                ▼
                       │                       --mount type=image,src=...:/nix,readonly
                       └────────────────────────────────────────────┘
```

### Runtime flow inside the container

1. `kasm-setup.service` runs (existing) — identity, dbus, cert, password.
2. **NEW** `nix-activate.service` runs as `$KASM_OS_USER`,
   `After=kasm-setup.service`, `Before=window-manager.service`. Reads
   `NIX_APP_PROFILES=chromium,onlyoffice` and:
   - Validates each profile name exists at `/nix/var/nix/profiles/<name>`.
   - Writes `/etc/profile.d/nix-app.sh` with PATH and XDG_DATA_DIRS prepends.
   - Symlinks each profile's `share/applications/*.desktop` to
     `/usr/share/applications/nix-<orig-name>.desktop` (`Exec=` rewritten
     to the absolute profile-bin path).
   - Symlinks `share/icons/`.
   - Sources `/tmp/kasm-dbus.env` and runs
     `gio set metadata::xfce-exe-checksum` for each shimmed `.desktop` so
     XFCE doesn't gate the launchers as "untrusted". `gvfsd-metadata`
     writes to `~/.local/share/gvfs-metadata/`, so the unit MUST run as
     the user (not root) and `Before=window-manager.service` so XFCE's
     `.desktop` enumeration sees the trust metadata.
3. `kasmvnc.service` and `window-manager.service` run (existing) — XFCE
   picks up the shimmed launchers; they appear in the menu/desktop, and
   `PATH` resolves their binaries via the activated profiles.

## Component 1 — `bin/build-nix-store-volume` (Bash, portable across podman/docker)

### Inputs

- `bin/nix-profiles.toml` (default location, override via `--config`).
- `--profile <name>` CLI args (additive override; if any are present,
  only those profiles are built).
- `--tag <repo:tag>` for the output OCI image (default
  `localhost/nix-store-<arch>:dev`).
- `--push <registry>` optional, uses `podman push` if present else
  `docker push`.
- `--prune-stage` deletes the cached named volume after a successful
  build (forces clean rebuild next run).
- `--keep-output` retains the small `~/.cache/nix-build-output/`
  directory (just the context tar + inner script) for forensics.
- `--arch <amd64|arm64>` default = host arch; cross-arch via qemu-user.

### Host requirements

Just `podman` (preferred) or `docker`. No Python, no jq, no APFS
sparseimage on macOS. All TOML parsing, closure analysis, and layer
partitioning runs inside the `nixos/nix` container.

### Staging

The Nix store stages into a persistent named podman volume,
`nix-build-stage-<arch>`, that lives in the container engine's
filesystem (ext4 on Linux and macOS+lima alike — case-sensitive).
The host filesystem only handles one build artifact: a context tar
produced by the inner container and fed back to `podman build` via
stdin. Because the tar is a single byte stream and the outer build
unpacks it inside the container engine, the host filesystem never
sees an extracted Nix store path — no APFS case-sensitivity bites,
no special-cased paths.

### Algorithm

```
0. host: parse args; detect podman/docker; ensure named volume exists;
   create ~/.cache/nix-build-output/ for the context tar.

1. host: $CONTAINER_CLI run \
        --volume $STAGE_VOL:/build:rw \                # named volume
        --volume $CONFIG:/config/profiles.toml:ro \    # bind: single file
        --volume $OUTPUT:/output:rw \                  # bind: tar output
        --volume $INNER_SCRIPT:/inner-build.sh:ro \    # bind: script
        nixos/nix:<pinned-tag> /inner-build.sh

   Inside the container:

2. ensure jq via `apk add` (fast) or `nix profile install` (fallback).

3. parse TOML → JSON via builtins.fromTOML — no host python needed:
      nix eval --raw --impure --expr \
          "builtins.toJSON (builtins.fromTOML (builtins.readFile /config/profiles.toml))" \
          > /build/profiles.json

4. for each profile, run nix profile install into a per-profile gcroot
   under /nix/var/nix/profiles/<name>. The volume is the
   container's /build, but profiles install to /nix (the live store),
   which dedups across profiles automatically.

5. compute closures via `nix-store -qR` (version-stable; works even
   when the JSON shape of `nix path-info` shifts across releases).

4. auto-promote heuristic:
      threshold = [promote].threshold_percent (default 80)
      for each path NOT in base_set:
          n_profiles = count of profiles whose closure contains it
          if n_profiles / total_profiles >= threshold:
              warn:  "Consider promoting <path> to [base] (in N/M profiles)"
      output on stderr; build continues.

6. partition store into layer-staging trees inside /build/layers/:
      /build/layers/base/store/      = paths in base_set
      /build/layers/profile-<X>/store/ = paths in closure(X) - base_set
   use `cp -al` (hardlinks; fast + no extra disk in the named volume).

7. extract meta:
      /build/layers/meta/var/nix/db/db.sqlite     ← copy verbatim
      /build/layers/meta/var/nix/profiles/<name>  ← profile symlinks (selectively
                                                    copied: bootstrap + _base +
                                                    every name in selected.txt)
      /build/layers/meta/var/nix/profiles/_meta.json (dep graph)

8. emit Dockerfile at /build/layers/Dockerfile:
      FROM scratch
      COPY base/store           /nix/store
      COPY profile-chromium/store /nix/store
      COPY profile-onlyoffice/store /nix/store
      ...
      COPY meta/var             /nix/var
   Each COPY emits a distinct OCI layer; identical paths across layers
   harmlessly shadow.

9. tar /build/layers into /output/context.tar.

   Back on host:

10. $CONTAINER_CLI build -t "$TAG" - < /output/context.tar
    Podman unpacks the tar inside its own (case-sensitive) filesystem
    and produces the multi-layer image in the local image store.

11. optional --push.
12. cleanup output dir (unless --keep-output).
```

### Output

An OCI image tagged `localhost/nix-store-<arch>:<tag>` (or the
explicit `--tag` value), `N+2` layers, ready for `--mount type=image,…`.

## Component 2 — `dockerfile-nix-ubuntu`

Top-level Dockerfile, sibling of `dockerfile-kasm-core*`. Adds nothing
to `/nix`; only adds the activation unit + scripts.

```dockerfile
ARG BASE_IMAGE="kasmweb/core-ubuntu-noble:develop"
FROM $BASE_IMAGE

ARG DISTRO=ubuntu
USER 0

# Per-image extension: activation unit + scripts.
RUN mkdir -p /etc/container-init.d
COPY src/ubuntu/install/nix/units/nix-activate.service \
     /etc/container-init.d/
COPY src/ubuntu/install/nix/scripts/nix-activate \
     src/ubuntu/install/nix/scripts/nix-app \
     /usr/local/bin/
RUN chmod 0755 /usr/local/bin/nix-activate /usr/local/bin/nix-app && \
    /usr/local/bin/container-init --units /etc/container-init/units \
        --drop-in /etc/container-init.d \
        --strict-units --validate
```

The final `--validate` line is the same gate `dockerfile-kasm-core` uses;
it fails the build if the new unit has any parse warning.

**Build args:** `BASE_IMAGE` defaults to the `develop` tag of the core
image; production builds override to a pinned core tag.

## Component 3 — boot-time activation

### `src/ubuntu/install/nix/units/nix-activate.service`

```ini
[Unit]
Description=Activate Kasm Nix profiles from NIX_APP_PROFILES
After=kasm-setup.service
Before=window-manager.service
Requires=kasm-setup.service
ConditionPathExists=/nix/var/nix/profiles/_meta.json

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/nix-activate
TimeoutStartSec=30s
```

- The unit is a **single root oneshot**. container-init parses
  `ExecStartPre` but the supervisor doesn't yet execute pre-hooks, so
  we collapse the state-setup and apply steps into one entrypoint and
  do the privilege drop internally via `su` (mirrors the pattern
  `kasm-setup.service` uses for `dbus-launch`).
- `ConditionPathExists` makes the unit a no-op when no Nix volume is
  mounted (so `nix-ubuntu` is still a usable thin wrapper for
  ad-hoc cases). container-init's supported subset only includes
  `ConditionPathExists` / `ConditionPathExistsGlob` /
  `ConditionEnvironment`, not the systemd `*IsDirectory` variants.
  The script's own early-exit (`[ -f "${META_JSON}" ] || exit 0`)
  is a belt-and-suspenders second check. Gating on `_meta.json` (rather
  than `${KASM_PROFILE_DIR}` itself) avoids a false positive when the
  base image happens to ship an empty `/nix/var/nix/profiles/` directory.

### `src/ubuntu/install/nix/scripts/nix-activate`

POSIX sh, single entrypoint, runs as root. Steps:

1. **State bootstrap.** Create `/run/nix-state/{db,temproots,gcroots,profiles}`,
   copy the read-only `db.sqlite` into `/run/nix-state/db/`, write
   `/etc/profile.d/nix-app-state.sh` exporting `NIX_STATE_DIR=/run/nix-state`
   and prepending `${KASM_PROFILE_DIR}/bootstrap/bin` to `PATH`. This
   is required because the read-only `/nix/var/` cannot host
   `temproots/` lockfiles or SQLite WAL files.
2. **Resolve active list.** `$KASM_OS_HOME/.config/nix-app/active`
   wins if present; otherwise parse `NIX_APP_PROFILES` (CSV). Filter
   names that don't resolve to a profile under
   `/nix/var/nix/profiles/`; log a warning for each skip.
3. **Write `/etc/profile.d/nix-app.sh`.** Exports `PATH` (each
   profile's `bin/` prepended) and `XDG_DATA_DIRS` (each profile's
   `share/` prepended). `NIX_APP_ACTIVE` is exported as the CSV for
   downstream inspection.
4. **Generate system-wide `.desktop` shims.** Copy each
   `$prof/share/applications/*.desktop` into
   `/usr/share/applications/nix-<basename>` with `Exec=` and
   `TryExec=` rewritten to absolute paths.
5. **Trust the shims as the user.** `su -s /bin/sh "$KASM_OS_USER"`
   sources `/tmp/kasm-dbus.env` (written earlier by
   `kasm-setup.service`) and runs `gio set metadata::xfce-exe-checksum`
   per shim. `gvfsd-metadata` writes to the user's
   `~/.local/share/gvfs-metadata/`. If the bus address is missing or
   `gio` fails, log a warning and continue — non-fatal.

The script is idempotent. Re-running it (manually after editing
`~/.config/nix-app/active`, for example) gives a consistent result.
The user-facing `nix-app` CLI does NOT re-invoke this; the CLI
manages a per-user view at `~/.local/share/applications/` so users
can activate/deactivate without `sudo`.

## Component 4 — `nix-app` CLI helper

POSIX sh, ~80 lines. Subcommands:

- `nix-app list` — enumerates `/nix/var/nix/profiles/*` (excluding
  `bootstrap`, `_base`, the bundled `default`/`per-user/`, `_meta.json`,
  and `<name>-<N>-link` generation symlinks), prints name + size +
  package count (parsed from `<prof>/share/...` enumeration). Read-only
  against /nix.
- `nix-app activated` — prints currently activated profile names by
  reading `~/.config/nix-app/active`.
- `nix-app activate <name>` — adds `<name>` to
  `~/.config/nix-app/active`, regenerates per-user shims at
  `~/.local/share/applications/nix-*.desktop`, and writes
  `~/.config/nix-app/profile.sh` so the user can `source` it to pick
  up PATH changes in the current shell. XFCE picks up the new shims
  from the per-user applications dir without needing root.
- `nix-app deactivate <name>` — reverse: removes `<name>` from
  `~/.config/nix-app/active`, removes matching per-user shims,
  regenerates `profile.sh`. The system-wide
  `/usr/share/applications/nix-*` shims (set at boot) stay until
  the next container restart — a minor wart documented in the readme.
- `nix-app info <name>` — `nix-store -qR` against the profile path,
  total closure size (via `du -sh`).

The CLI requires no root and no `sudo`. PATH for existing shells is
not updated automatically; users source `~/.config/nix-app/profile.sh`
when they want a CLI-activated profile to be on `PATH` in the current
shell. Next session inherits the boot-time set as before.

## Configuration — `bin/nix-profiles.toml`

```toml
# Pinned nixpkgs revision for reproducibility. Bump deliberately.
[nixpkgs]
ref = "github:NixOS/nixpkgs/nixos-25.05"

# Packages that go in the base OCI layer. Stable digest across
# profile-set churn — adding a new profile re-emits only that profile's
# layer, not the base.
[base]
pkgs = [
    "nixpkgs#glibc",
    "nixpkgs#openssl",
    "nixpkgs#zlib",
    "nixpkgs#libffi",
    "nixpkgs#xorg.libX11",
    "nixpkgs#xorg.libXi",
    "nixpkgs#fontconfig",
    "nixpkgs#freetype",
    "nixpkgs#gtk3",
    "nixpkgs#dbus",
    "nixpkgs#alsa-lib",
    "nixpkgs#nspr",
    "nixpkgs#nss",
]

# Build script warns when a non-base path appears in >= N% of profiles.
[promote]
threshold_percent = 80

# One section per profile. Profile names become directory names under
# /nix/var/nix/profiles/ in the final volume.
#
# Profiles can override [nixpkgs].ref to decouple their cadence from
# the base — see "Update cadence" below.

[profiles.chromium]
pkgs = ["nixpkgs#chromium"]
ref  = "github:NixOS/nixpkgs/nixos-unstable"

[profiles.onlyoffice]
pkgs = ["nixpkgs#onlyoffice-desktopeditors"]

[profiles.vscode]
pkgs = ["nixpkgs#vscode"]

[profiles.claude-code]
pkgs     = ["nixpkgs#claude-code"]
ref      = "github:NixOS/nixpkgs/nixos-unstable"
requires = ["node"]

[profiles.node]
pkgs = ["nixpkgs#nodejs_22", "nixpkgs#pnpm", "nixpkgs#corepack"]
```

The build script reads the TOML via `python3 -c 'import tomllib; …'`
(stdlib in Python 3.11+, present on Ubuntu 24.04 and inside `nixos/nix`)
and converts it to a transient JSON file. The Nix-side iteration in
the builder container is `jq`-driven; the closure capture uses
`nix-store -qR` for version-stable behaviour across Nix releases.

### Dependency graph (`requires`)

Profiles can declare `requires = [...]`. The build script writes a
small `_meta.json` into the meta layer recording the dep graph:

```json
{
  "profiles": {
    "claude-code": {"ref": "github:NixOS/nixpkgs/nixos-unstable", "requires": ["node"]},
    "opencode":    {"ref": "github:NixOS/nixpkgs/nixos-unstable", "requires": ["node"]},
    "codex":       {"ref": "github:NixOS/nixpkgs/nixos-unstable", "requires": ["node"]},
    "node":        {"ref": null, "requires": []}
  }
}
```

The activation script (and the `nix-app` CLI for live activations)
reads this and expands the user-requested set transitively via a
fixed-point loop (cycle-safe: the set is monotonically growing and
bounded). Activating `claude-code` therefore pulls `node` along.

Semantics mirror systemd's `Requires=`: deps are auto-added regardless
of whether the user listed them. `nix-app deactivate node` while
`claude-code` is active is a soft no-op — the CLI removes `node` from
the requested set but `expand_deps` puts it back, and the CLI prints a
clear "still active because claude-code requires it" message.

## Update cadence

**The concern.** Chromium ships a security update roughly every 1–3
weeks. A naive setup where `[nixpkgs].ref` is bumped to pull each new
Chromium revision would also pull a new glibc, openssl, libX11, etc. —
all the base-layer dependencies. The base-layer digest changes, every
client re-pulls the full base (~500 MiB) on every Chromium bump. That's
not workable.

**The mitigation, baked into the design.**

1. **Two-tier nixpkgs pinning.** `[nixpkgs].ref` is the *base* pin —
   bumped deliberately, ideally aligned to a nixpkgs stable release
   (every ~6 months). The base layer's content hash stays stable
   across normal cycles.

2. **Per-profile `ref` override.** Profiles that need a faster cadence
   set their own `ref =` (typically `nixpkgs-unstable`). When that
   profile's ref bumps:
   - Its closure rebuilds against the rolling ref's libs.
   - Its delta layer gets bigger (it carries its own glibc/libX11/etc
     because they no longer match the base ref's content hashes).
   - The base layer is unchanged — content hash identical → digest
     identical → registries and clients DO NOT re-pull it.
   - Other profile layers are also unchanged.

   Net: a Chromium update re-emits only Chromium's layer + the meta
   layer. Chromium's layer goes from ~80 MiB (with full base sharing)
   to maybe ~600 MiB (carrying its own X11/gtk/openssl). A ~600 MiB
   delta pulled by clients once per Chromium release is acceptable; a
   full-base re-pull is not.

3. **Layer split confirms the savings.** Concretely after a
   Chromium-only bump with this design:
   - Layer 0 (base): unchanged → no re-pull.
   - Layer N-chromium: new digest → clients pull ~600 MiB.
   - Layer N-audacity, N-onlyoffice, N-slack, N-vscode: unchanged → no re-pull.
   - Meta layer: changes (new sqlite registration) but is small (~50 MB).

   Total pull on a Chromium security update: ~650 MiB rather than
   ~3.5 GiB. Order of magnitude win.

### Operator policy

- Bump `[nixpkgs].ref` only at nixpkgs stable release boundaries
  (typically May and November). Accept that this re-emits all layers.
- Bump per-profile `ref` overrides whenever the profile owner deems
  necessary. For Chromium specifically, automate this in a separate
  ops workflow (out of scope for the initial PR — a watch on the
  nixpkgs chromium attribute, triggering
  `build-nix-store-volume --profile chromium`, re-tagging, re-pushing).
- The `--profile` CLI override lets ops run focused rebuilds without
  touching the config:
  ```
  ./bin/build-nix-store-volume --profile chromium \
      --tag kasmweb/nix-store-amd64:chromium-bump-2026-06-01
  ```

### Caveat

When Chromium uses a different ref from base, its delta layer carries
*near-duplicates* of base-layer libs (different store paths because
content-addressed against a different nixpkgs revision). The registry
stores both copies; the running container holds both in its read-only
mount. This is the cost of decoupling cadences. If we ever want to
fully eliminate the duplication, the path is Nix overlays — let
Chromium build against a specific newer version of just
chromium-related deps while linking against the base ref's
glibc/libX11. That's a substantial design escalation (per-profile Nix
expression authoring) and is parked as phase 2.

## CI integration

Add a row to `ci-scripts/template-vars.yaml` under `multiImages`:

```yaml
- name1: nix
  name2: ubuntu
  base: kasmweb/core-ubuntu-noble:develop
  bg: bg_noble.png
  distro: ubuntu
  dockerfile: dockerfile-nix-ubuntu
  changeFiles:
    - dockerfile-nix-ubuntu
    - src/ubuntu/install/nix/**
    - bin/build-nix-store-volume
    - bin/nix-profiles.toml
```

This gets amd64 + arm64 builds via the existing matrix. The
`build-nix-store-volume` script and the store OCI image are NOT part
of the core-images CI pipeline — they're operator tooling. Building
and publishing the store image is a separate ops workflow, documented
in `docs/core-nix-ubuntu/README.md` but not automated in the initial PR.

## Verification

1. **Build the store image (host-side):**
   ```
   ./bin/build-nix-store-volume --arch amd64 \
       --tag localhost/nix-store-amd64:smoke \
       --keep-staging
   ```
   Expected: ~4–5 GiB image, `N+2` layers — 1 base + 5 profile layers
   (chromium, audacity, onlyoffice, slack, vscode) + 1 meta = 7 layers.
   Verify with:
   ```
   podman image inspect localhost/nix-store-amd64:smoke \
       | jq '.[].RootFS.Layers | length'
   ```

2. **Verify cadence decoupling.** Re-build with only chromium changed
   (simulate by bumping `[profiles.chromium].ref`); confirm via
   `podman image inspect` that the base layer's `DiffID` is identical
   between the two builds, while chromium's layer `DiffID` changes.

3. **Validate auto-promote warning.** Intentionally remove `nspr` from
   `[base]` in the config, rebuild, expect a stderr warning like
   `Consider promoting /nix/store/<hash>-nspr-… to [base] (in 4/5 profiles)`.

4. **Build the image:**
   ```
   podman build -f dockerfile-nix-ubuntu \
       --build-arg BASE_IMAGE=kasmweb/core-ubuntu-noble:develop \
       -t nix-ubuntu:smoke .
   ```
   Expected: passes the `container-init --strict-units --validate` gate.
   Image is essentially `core-ubuntu-noble` + ~10 KiB of activation
   scripts (no Nix installed in the image itself).

5. **Run with the store mounted, three profiles activated:**
   ```
   podman run --rm -d --name nix-smoke \
       --mount type=image,source=localhost/nix-store-amd64:smoke,destination=/nix,readonly=true \
       -e NIX_APP_PROFILES=chromium,onlyoffice,vscode \
       -e VNC_PW=password -p 6901:6901 \
       nix-ubuntu:smoke

   podman exec nix-smoke ls /usr/share/applications/nix-*
   podman exec nix-smoke /nix/var/nix/profiles/chromium/bin/chromium --version
   podman exec nix-smoke /nix/var/nix/profiles/vscode/bin/code --version
   podman exec -u kasm-user nix-smoke nix-app list
   podman exec -u kasm-user nix-smoke nix-app activated
   ```
   Expected: chromium, onlyoffice, and vscode `.desktop` shims present;
   both binaries report their version; `nix-app activated` prints the
   three names.

6. **XFCE trust check.** Browse to `https://localhost:6901`, open the
   XFCE Whisker menu, confirm the Chromium, OnlyOffice, and VS Code
   launchers appear without the "untrusted launcher" warning dialog.

7. **Deactivation:**
   ```
   podman exec -u kasm-user nix-smoke nix-app deactivate onlyoffice
   podman exec nix-smoke sh -c 'ls /usr/share/applications/nix-* | grep -c onlyoffice'
   ```
   Expected: 0 matching shims; XFCE panel re-scan
   (`xfce4-panel --restart` from inside the session) removes the launcher.

8. **No-volume-mounted regression.** Running `nix-ubuntu:smoke`
   *without* the `/nix` mount should be functionally identical to
   `core-ubuntu-noble` (the `ConditionPathIsDirectory` on the unit
   makes it skip cleanly). Verify with
   `podman run --rm nix-ubuntu:smoke /usr/local/bin/container-init --validate`
   and a smoke desktop boot.

## Known limitations / future work

1. **`gio set metadata::xfce-exe-checksum` may still race XFCE startup**
   even with `Before=window-manager.service`. If XFCE caches the trust
   state at panel-load time and only reloads metadata on a debounce,
   we may still see a one-time "untrusted launcher" warning.
   Mitigation if it bites: pre-populate
   `~/.local/share/gvfs-keyfile/keyfile` directly from the activation
   script (session-bus-independent path).

2. **Pinned nixpkgs revision is a single point of staleness.** Bumping
   `[nixpkgs].ref` rebuilds every layer. Cadence policy is documented
   above and in the user-facing readme.

3. **Cross-arch builds via qemu are slow** (10×+ overhead for
   Chromium-class closures). The script supports `--arch arm64` on an
   amd64 host, but in practice each arch should be built on a native
   runner. CI will handle this naturally via the existing per-arch
   matrix once we wire the build-store-volume job in (ops follow-up).

4. **OCI registry storage cost.** A full closure for the five named
   profiles is ~4–5 GiB. With layer dedup across image versions this
   is bounded, but the registry needs space planning. Document
   expected size in the readme.

5. **Phase 2 — Nix overlays for cross-ref deduplication.** Eliminate
   the duplicate base libs in the Chromium delta layer by writing
   per-profile Nix expressions that pin chromium against a specific
   newer rev while inheriting glibc/X11 from the base ref. Skipped
   here to keep the initial design TOML-driven; revisit when the
   Chromium-delta footprint becomes a registry / pull-time concern.
