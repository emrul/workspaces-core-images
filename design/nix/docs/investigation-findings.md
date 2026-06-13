# Investigation Findings

Research backing the design decisions in [`../REQUIREMENTS.md`](../REQUIREMENTS.md).
Investigation date: **2026-06-12**. Re-verify version-sensitive claims (CLI
flags, runtime image-volume support, nixpkgs release) before relying on them.

## 1. Image-build tooling decision

**Question.** Build N per-app images plus one fat image from a single Nix
store, with maximal cross-image layer sharing and fast nightly repush. What
emits the images?

### Options compared

These are **not interchangeable emitters** — they make opposite trades on
*build-output portability* vs *push incrementality* (see "Key distinction").

| Tool | Build output | Layering | Push / repush (small change) | Dep |
|---|---|---|---|---|
| **nix2container** ([nlewo](https://github.com/nlewo/nix2container)) | **archive-less**: JSON manifest referencing `/nix/store` paths — materialized only at copy time by skopeo `nix:` transport | automatic popularity-based, `maxLayers`, content-addressed | skips already-pushed layers; ~1.8 s | third-party flake input |
| **`dockerTools.buildLayeredImage`** (nixpkgs) | **self-contained tarball, stored in `/nix/store`** | popularity-based (shared lineage) | full image rebuild; store bloat | none (in-tree) |
| **`dockerTools.streamLayeredImage`** (nixpkgs) | **self-contained tarball, streamed on demand** (script, not stored) | popularity-based (shared lineage) | re-streams the tar; ~7.5–10 s | none (in-tree) |
| **current PoC** (`FROM scratch` + `COPY` + `buildah`) | self-contained image | coarse, **one layer per profile**; non-base shared paths **duplicated** across profiles (only deduped vs `[base]` via `comm -23`) | full rebuild | podman/buildah |
| `nixery` | registry service | on-demand by image name | n/a | service to run |

### Key distinction (corrects an earlier conflation)

`dockerTools.*LayeredImage` and `nix2container` are **different tools, not a
fallback pair.** The dockerTools functions emit a *self-contained* image (real
layer tarballs — `streamLayeredImage` just streams those bytes instead of
storing them). nix2container is *archive-less*: its output is a JSON manifest
that **references store paths**, and the layers are only realised at **copy
time** by skopeo. That copy-time property is the source of its advantages
(skip-already-pushed, no tarball-in-store) — and, importantly, it does **not**
prevent self-contained / offline export (see §1a). Choosing between them is a
real decision about CI/push workflow, not a swap of "emitter."

### Findings

- **nix2container is the best fit for the requirement combo**: many images from
  one store + maximal dedup + fast incremental repush. Its automatic layering
  isolates frequently-referenced closures into their own content-addressed
  layers ("pull fat → Chrome is near-free"); its skip-already-pushed copy is
  what makes nightly Chromium repush cheap.
- **dockerTools is the in-tree option with a *different* property** — a portable
  self-contained build output, no third-party input. We are **not** picking it
  for airgapped (nix2container covers that, §1a); the only reason to revisit it
  is if the third-party dependency or the `fromImage`-on-apt path fails the
  spike. It is not a drop-in: switching means a different image model and losing
  skip-already-pushed repush.
- **The current PoC partitioner is the thing being replaced.** It emits one
  coarse layer per profile and only deduplicates non-base paths against the
  `[base]` set, so store paths shared between two *non-base* profiles are
  duplicated in both layers. nix2container's reference-graph layering removes
  that duplication without hand-tuning.

### Decision

**Primary: nix2container.** In-tree `dockerTools.streamLayeredImage` is a
*contingency* only if the spike (M0) finds the third-party dep or
`fromImage`-on-apt unworkable — and switching is a genuine re-design, not an
emitter swap. Airgapped/offline does not change this (§1a).

## 1a. Airgapped / offline export

**Requirement.** Some customers run airgapped; images must be deliverable with
no network and no Nix on the destination.

**Finding: nix2container supports this.** Its `copyTo` passthru is literally
`skopeo --insecure-policy copy nix:${image} "$@"` (verified in
`nix2container/default.nix`), so the destination is anything skopeo accepts:

```bash
# On a build/CI host that HAS the Nix store — materialize a self-contained artifact:
nix run .#chrome.copyTo -- oci-archive:./kasm-chrome.tar:kasmweb/chrome:1.18.0
#   or docker-archive:./kasm-chrome.tar:kasmweb/chrome:1.18.0
#   or docker://offline-registry.internal/kasmweb/chrome:1.18.0   (populate a mirror)

# Inside the airgap — no Nix, no network:
podman load -i kasm-chrome.tar    # or docker load; or pull from the offline mirror
```

- The resulting `oci-archive`/`docker-archive` contains **real layer tarballs**,
  no `/nix/store` references — load needs neither Nix nor network.
- **Caveat (true of every Nix image tool):** the `copyTo`/materialize step must
  run where the store exists (the build/CI host), not in the airgap.
- For a fleet, populate an **offline mirror registry** once (`docker://…`)
  rather than `load`-ing tarballs per node; cross-image layer dedup then also
  benefits the airgapped pulls.
- This is why the airgapped need does **not** force dockerTools: dockerTools'
  self-contained output is one way to get a portable tarball, but nix2container
  produces the same portable `oci-archive`/`docker-archive` via skopeo while
  keeping its incremental-push advantage for the online path.

### Cost this introduces (flag, not blocker)

The pipeline moves from **imperative** (`nix-profiles.toml` →
`nix profile install` → partition → `buildah`) to **declarative Nix**
(a flake calling `buildImage`). This raises the Nix-fluency bar — a stated team
concern. **Mitigation: keep `nix-profiles.toml` as the authoring surface and
generate the Nix expression from it**, so app owners edit TOML, not `.nix`.

### Open spike items (must test live)

1. **`fromImage` on an apt base.** Per-app images are `FROM kasm-core`
   (apt-based Ubuntu + KasmVNC), not a Nix-built base. Confirm
   `buildImage { fromImage = pullImage/pullImageFromManifest …; }` layers the
   Nix store layers cleanly on top, and that the core layers keep identical
   digests across all per-app images (so they dedup).
2. **Store location.** We need store paths to stay at `/nix/store` (profile
   `bin/` symlinks point into `/nix/store`); do **not** use `copyToRoot` to
   relocate to `/`. Confirm default behavior keeps `/nix/store`.
3. **Nix DB.** Baked per-app images likely need **no** live Nix DB (app just
   needs PATH + `.desktop`). Only the mounted fat image needs the DB for
   `nix-app list` / closure queries → `initializeNixDatabase`. Confirm.
4. **Multi-arch.** nix2container builds per-system; assemble amd64+arm64 into a
   manifest with skopeo/`podman manifest` (same as today's matrix).

References: nix2container README (functions `buildImage`, `buildLayer`,
attrs `maxLayers`, `fromImage`, `copyToRoot`, `initializeNixDatabase`,
`copyToRegistry`/`copyToDockerDaemon`); Graham Christensen,
["Optimising Docker layers for better caching with Nix"](https://grahamc.com/blog/nix-and-layered-docker-images/)
(the popularity heuristic both tools use).

## 1b. M0 spike results — MEASURED (2026-06-12, x86_64 test host)

Built the 5-app set (chrome, chromium, vs-code, firefox, audacity) + a fat image
with nix2container on Ubuntu 24.04. Two layering strategies measured via
`skopeo inspect` of the compressed manifests:

**Finding 1 — automatic `maxLayers` does NOT dedup across images.**
With `buildImage { maxLayers = 100; }` per app (no explicit layers), pulling the
fat image then a per-app image still cost ~1.6 GB *extra* — the popularity
packer groups store paths differently per image, so identical store paths land
in non-identical layers (different digests). Auto-layering optimises *within* an
image, not *across a family*.

**Finding 2 — explicit shared `buildLayer`s give perfect cross-image dedup.**
Restructured to one reused `baseLayer` (the shared GUI closure:
gtk3/glib/pango/cairo/X11/nss/mesa/… ≈ 1.23 GB) + one reused `appLayer` per app,
composed into both the per-app and fat images:

```
per-image: chrome 2.4GB · chromium 2.3GB · vscode 1.6GB · firefox 2.5GB
           audacity 2.3GB · fat 6.3GB (6 layers: base + 5 app layers)
pull fat, then ANY per-app image  ->  0 B extra   (base + app layer already present)
chrome <-> chromium               ->  share the 1.23 GB base; app payloads differ
```

**Design consequence (folded into build-pipeline.md):** the pipeline must define
explicit, reused layer derivations — a shared base + per-app layers — **not**
rely on bare `maxLayers`. The same `appLayer` derivation must be referenced by
both the per-app image and the fat image so digests match.

**Architecture consequence:** because baked per-app + fat images dedup perfectly
at the layer level (pull-fat-then-app = 0 B), the runtime `/nix` *mount* (the
buildah-era mechanism) is **not required** for the "pull fat → next app is free"
goal. Layer sharing achieves it with self-contained images. The mount model
remains only if true arbitrary-runtime-composition is needed beyond the baked
fat superset.

**Caveat reconfirmed:** app-to-app payloads that aren't in the base layer are
*not* shared between sibling app layers (each carries its own copy). Promote
common heavy closures (e.g. a shared Electron) into the base to share them —
the design's auto-promote heuristic. Chrome vs Chromium don't share their
browser payloads because they are different upstream builds.

## 1c. Runnable baked-image findings — MEASURED (2026-06-12)

Building per-app + fat images `fromImage = nix-ubuntu` (core + container-init
+ nix-activate) and booting them in KasmVNC surfaced several concrete points:

- **`pullImageFromManifest` + `tlsVerify = false` consumes a local registry.**
  The apt-based core is pushed to a local `registry:2` on `localhost:5000`; the
  flake pulls it by manifest (`nix/base-manifest.json`) — no global FOD hash,
  no TOFU. This is the working answer to "nix2container on an apt base".
- **nix2container does NOT merge the base image's OCI config.** With `fromImage`
  set but `config` empty, the result had *no entrypoint* → `docker run` failed
  with "no command specified". Fix: restate the core's config (Entrypoint
  `/usr/local/bin/kasm-entrypoint`, Env, ExposedPorts, User, WorkingDir) in the
  flake's `config`. Captured from `docker inspect`.
- **`/nix` profile layout for activation** is generated with `buildEnv` (one
  symlink tree per app: `bin/` + `share/`) symlinked at
  `/nix/var/nix/profiles/<name>`, plus a generated `_meta.json`, placed via
  `copyToRoot`. `nix-activate` then wires PATH/menu exactly as for the
  mounted store. Confirmed: shims created, `nix-app list/activated` work.
- **Chromium/Chrome need TWO things to run headless here:**
  1. `--no-sandbox` on **argv** (the wrapper's `QTWEBENGINE_CHROMIUM_FLAGS` env
     only reaches Qt-embedded chromium). `chrome-sandbox` in the read-only Nix
     store can't be setuid-root → SUID-sandbox FATAL without it. Fixed in
     `nix-launch` (detects chrome/chromium/brave/electron/code on argv).
  2. **A seccomp exception on the container** (`--security-opt seccomp=unconfined`
     or `src/common/seccomp/chrome.json`). Docker's default profile SIGKILLs
     Chrome (exit 137); with it, Chrome is stable (~10 procs steady). This is an
     operator run-flag, documented in the demo script + how-to.
- **Web login user is `kasm-user`** (hyphen — `$KASM_OS_USER`), not `kasm_user`.
  The KasmVNC basic-auth file is keyed on the OS user.

## 1d. Runnable polish: sandbox, icons, Desktop, GPU (2026-06-12)

- **Chrome sandbox via seccomp (not `--no-sandbox`).** Dropped `--no-sandbox`
  from `nix-launch`. Chrome uses its **namespace sandbox** when the container
  runs with `src/common/seccomp/chrome.json` (permits unprivileged userns) AND
  the host allows userns. On Ubuntu 24.04 that also requires
  `kernel.apparmor_restrict_unprivileged_userns=0` — `apparmor=unconfined` on the
  container alone was **not** enough (verified: `unshare -U` blocked until the
  sysctl was flipped). With both, sandboxed headless Chrome renders (exit 0).
- **`.desktop` icons.** Nix apps ship icons inside their profile, which isn't on
  XFCE's icon-theme path → bare `Icon=chromium` shows no icon. `nix-activate` now
  rewrites `Icon=` to the absolute file under the profile's `share/icons`.
- **Desktop launchers.** `nix-activate` copies the shimmed launchers to
  `$HOME/Desktop` and gio-trusts them (toggle `NIX_APP_DESKTOP_ICONS=0`).
- **Hidden launchers skipped.** `.desktop` files with `NoDisplay=true` /
  `Hidden=true` are not shimmed — e.g. Chrome ships a `NoDisplay`
  `com.google.Chrome.desktop` alias next to `google-chrome.desktop` (shimming
  both = two identical icons), and VS Code ships a `code-url-handler` entry.
- **GPU (investigated in depth, not enabled).** Kasm's detection + flags
  (`--use-angle=vulkan`, independent of `vglrun`) **do** port over, and the GPU is
  reachable: `--gpus all -e NVIDIA_DRIVER_CAPABILITIES=all` injects the NVIDIA
  Vulkan ICD; Nix Chrome's own `vulkan-loader` finds it and tries ANGLE-Vulkan.
  Two **Nix-glibc-vs-system-stack** blockers stop it: (a) `vglrun` can't preload
  its system-glibc faker libs into the Nix binary; (b) ANGLE-Vulkan fails on
  `VK_KHR_surface`/`VK_KHR_xcb_surface` because Nix Chrome's `vulkan-loader` was
  built **without XCB WSI**, and forcing the system loader segfaults (glibc
  clash). Fix = `nixGL`/`nixglhost` or a Nix `vulkan-loader` with XCB WSI +
  NVIDIA ICD wiring; plus an open question of whether NVIDIA Vulkan can present
  to the **software Xvnc** server (Kasm uses VirtualGL/EGL readback for that).
  Dedicated spike, not a flag tweak. See [`handover.md`](handover.md).

## 2. OCI image-volume runtime support (ad-hoc / fat model)

The fat model mounts the store read-only at `/nix` via an OCI **image volume**.

| Runtime | Support | Notes |
|---|---|---|
| Podman | ≥ 4.0 | `--mount type=image,source=…,destination=/nix`; read-only by default. `readonly=true` rejected on 4.x (5.x synonym). |
| Docker | ≥ 28.0 | `--mount type=image,…,target=/nix,readonly` |
| Kubernetes | 1.33 beta, GA 1.36 | `volumes: [{image: {reference, pullPolicy}}]`; auth via pod `imagePullSecrets`. Older clusters: init-container `cp -a` into an `emptyDir` fallback. |

Confirmed against the existing PoC `docs/nix-how-to.md`; re-verify the k8s GA
version at implementation time.

## 3. nixpkgs pin / cadence

- Config pins `[nixpkgs].ref = nixos-25.05`. Current stable as of 2026-06 is
  **nixos-25.11**; bump as part of this work (Open Question 6).
- Two-tier pinning (slow base ref + per-profile rolling `ref`) is already
  designed and validated in the PoC — see
  [`../nix-package-process.md`](../nix-package-process.md#update-cadence).
- Chromium ships security updates roughly every 1–3 weeks → the per-profile
  `ref = nixos-unstable` override is what makes nightly cheap.

## 4. Custom-package landscape (preview; detail in packaging-apps.md)

- Most desktop apps Kasm ships are already in nixpkgs
  (search at <https://search.nixos.org/packages>). Spot-checked: chromium,
  vscode, obsidian, onlyoffice, claude-code, codex, opencode.
- Gaps that force a custom derivation: proprietary apps not in nixpkgs, a
  version nixpkgs doesn't carry, or a build with non-default flags. Decision
  tree in [`packaging-apps.md`](packaging-apps.md).
- A **private binary cache** (Cachix / attic / S3) is likely needed so CI and
  customer rebuilds don't depend on cache.nixos.org and don't recompile from
  source (Open Question 3).

## 5. Headless-GUI gotchas observed in the PoC

Captured from `bin/nix-profiles.toml` comments — real findings to preserve:

- **Electron/QtWebEngine apps** (vscode, obsidian, angelfish) need the Kasm
  baked `LD_LIBRARY_PATH` dropped + sandbox/zygote disabled →
  `nix-launch` wrapper.
- **Ptyxis** needs container-init's `org.freedesktop.systemd1` no-op shim
  (`--systemd1-shim`) so `systemd-run --user --scope` succeeds.
- **WezTerm** disabled: `wezterm-gui` calls `eglGetDisplay`; Xvnc has no native
  EGL. CLI-only works headless.
- **XFCE launcher trust**: `.desktop` shims must get
  `gio set metadata::xfce-exe-checksum` as the user before the WM enumerates
  them, else "untrusted launcher" warnings.
