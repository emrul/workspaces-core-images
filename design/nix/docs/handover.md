# Session Handover — Nix-packaging PoC (2026-06-12 → 06-13)

What was built/tested, the current running state, and where to pick up.
Source of truth for the effort: [`../REQUIREMENTS.md`](../REQUIREMENTS.md).

## TL;DR

From a single-image PoC to a **working nix2container PoC on a real GPU test
server**: per-app + fat images built from one Nix store, **proven 0-byte
cross-image dedup**, and **runnable Kasm/KasmVNC desktops** (Chrome, VS Code,
Firefox) launching from the menu + Desktop, sandboxed. GPU/WebGL: hardware GL is
**proven for Nix apps** via VirtualGL (`glxinfo` → RTX 3090), but **Chrome
hardware WebGL was not achieved** in bare docker — see the GPU section.

## Test server (192.168.1.140, `emrul@`)

- Ubuntu 24.04, x86_64, 20 cores / 125 GiB RAM, **NVIDIA RTX 3090** + `nvidia`
  docker runtime, Docker 29.5.3.
- Heavy data on the 1.8 TB `/mnt/data`: Docker data-root already there; **Nix
  store relocated to `/mnt/data/nix`** (bind mount, in `/etc/fstab`).
- Nix (Determinate 3.21.1, flakes on). Host sysctl set:
  `kernel.apparmor_restrict_unprivileged_userns=0` (persisted in
  `/etc/sysctl.d/99-nix-app-userns.conf`) — needed for Chrome's namespace sandbox.
- Local registry `localhost:5000` holds `nix-ubuntu:dev` (runtime base);
  `nix/base-manifest.json` captured from it for `pullImageFromManifest`.
- Repo at `~/workspaces-core-images` (no `.git`; rsync'd from the Mac).

Reproducible via [`demo-environment-setup.md`](demo-environment-setup.md).

## Currently running

| Port | Container | Image | Notes |
|---|---|---|---|
| 6902 | `chrome-run` | `nix-chrome-run:spike` | self-contained single-app Chrome |
| 6903 | `fat-run` | `nix-fat-run:spike` | `NIX_APP_PROFILES=chrome,vscode,firefox` |

Login **`kasm-user` / `password`** (hyphen, keyed on `$KASM_OS_USER`). Both run
with `--security-opt seccomp=src/common/seccomp/chrome.json --security-opt apparmor=unconfined`.
Software-rendered (no GPU args).

## Artifacts produced (in the repo)

- **`nix/flake.nix`** — nix2container PoC. `.#<app>` / `.#fat` (dedup-proof, no
  base) and `.#<app>-run` / `.#fat-run` (runnable, `fromImage = nix-ubuntu`,
  generated `/nix/var/nix/profiles` tree).
- **`runs/nix-demo.sh`**, **`runs/nix-dedup.sh`** — one-shot demo + dedup measure.
- **`dockerfile-nix-ubuntu`** — thin runtime base (core + activation hooks).
- **`src/ubuntu/install/nix/scripts/{nix-activate,nix-launch,nix-app}`** +
  **`units/nix-activate.service`** — activation / launch wrapper / CLI.
- Design bundle: this `design/nix/` tree (REQUIREMENTS + docs/).

## What works (verified)

- **Cross-image dedup** — `nix-chrome-run` shares all heavy layers with
  `nix-fat-run`; pulling one after the other transfers **~11 KB** (only the
  per-image `_meta.json`/profile-symlink layer differs). Verify by comparing
  layer DiffIDs (`docker image inspect … .RootFS.Layers`), NOT `docker image ls`
  or `docker system df` (its "unique" column is misleading).
- **Runnable in KasmVNC** — `chrome-run`/`fat-run` boot a desktop; apps appear
  in the XFCE menu + Desktop and launch, sandboxed.
- **`.desktop` icons** — `Icon=` rewritten to an absolute path in the profile
  (Nix icons aren't on XFCE's theme path otherwise).
- **Desktop launchers** — activated apps copied to `$HOME/Desktop` + gio-trusted
  (toggle `NIX_APP_DESKTOP_ICONS=0`); `NoDisplay=true`/`Hidden=true` entries
  skipped (avoids the duplicate Chrome icon + VS Code's url-handler entry).
- **VS Code** — fixed `EACCES` crash by creating `/run/user/<uid>` (no logind in
  the container) in `nix-activate`.
- **Chrome launch** — needs `--password-store=basic` (else hangs on the absent
  dbus secret service) + a seccomp exception (default Docker profile SIGKILLs it,
  exit 137). Runs with its **namespace sandbox** (no `--no-sandbox`) via
  `chrome.json` + the host userns sysctl.

## Key nix2container findings

1. **Dedup needs EXPLICIT shared layers**, not auto `maxLayers` (which repacks
   per-image → no cross-image sharing). One reused `baseLayer` + one reused
   `appLayer` per app, referenced by every image.
2. **Runnable images** pull the apt-based core via `pullImageFromManifest`
   (`tlsVerify=false`, local registry). nix2container does **not** merge the base
   image's OCI config — the flake restates entrypoint/env/ports.
3. Store stays at `/nix/store`; profiles + `_meta.json` placed via `copyToRoot`.

(Detail + measured numbers in [`investigation-findings.md`](investigation-findings.md).)

## Naming

All `kasm-nix*` → `nix*`, with the four Nix-namespace-colliding names →
`nix-app*`: CLI `nix-app`, env `NIX_APP_PROFILES`/`NIX_APP_ACTIVE`/
`NIX_APP_DESKTOP_ICONS`, `~/.config/nix-app/`, `/etc/profile.d/nix-app.sh`.
Helpers/units/shims/images are `nix-*`.

---

# GPU / hardware WebGL — full investigation

## How Kasm does GPU (decoded from the server run-config + `kasm-window-manager`)

The Kasm server selects a method per host and sets env;
`/usr/local/bin/kasm-window-manager` (inherited by the Nix core) acts on it:

| Method | Env set | What the WM does | GPU |
|---|---|---|---|
| **DRI3** | `KVNC_DESKTOP_GPU_HW3D=true`, `KVNC_DESKTOP_GPU_DRINODE` | KasmVNC Xvnc HW3D via **mesa glamor** | AMD/Intel (not NVIDIA) |
| **VULKAN** | `KASM_ENABLE_ZINK=true`, `KASM_EGL_CARD`, `KASM_RENDERD` | export `GALLIUM_DRIVER=zink LIBGL_KOPPER_DRI2=1 MESA_LOADER_DRIVER_OVERRIDE=zink` **and** `exec vglrun -d $KASM_EGL_CARD startxfce4` | **NVIDIA** |
| **EGL** | `KASM_EGL_CARD`, `KASM_RENDERD` | `exec vglrun -d $KASM_EGL_CARD startxfce4` | generic |
| VAAPI/NVENC | `KVNC_DESKTOP_GPU_DRINODE` | KasmVNC hardware video decode/encode | — |

Key points:
- For NVIDIA the whole **XFCE session runs under VirtualGL + Zink**; menu-launched
  apps inherit the VGL faker + GL env.
- All `vglrun` paths are gated on `[ -O $KASM_EGL_CARD ]` — **the session user
  must OWN the dri devices**, which the **Kasm agent** provisions. A bare
  `docker run --gpus all` leaves them `root:video/render`, so even Kasm's own
  Chrome would take the software path standalone.
- KasmVNC HW3D config *is* honoured by the Nix core (Xvnc ran `-hw3d -dri3
  -drinode`); the env blocker we hit was device **ownership**
  (`libEGL: failed to open /dev/dri/card1: Permission denied`).

## What we tested (every path) and the result

Container: `--gpus all -e NVIDIA_DRIVER_CAPABILITIES=all` (injects the NVIDIA
Vulkan ICD + `libGLX_nvidia`/`libEGL_nvidia`, 580.159.03). `/dev/dri` = `card1`
(grp `video`/44) + `renderD128` (grp `render`/992).

| # | Approach | Result |
|---|---|---|
| 1 | Chrome `--use-angle=vulkan`, no VGL | `VK_KHR_surface` *not supported* (Xvnc has no Vulkan WSI) |
| 2 | Chrome `--use-angle=gl`, no VGL | `glXQueryExtensionsString returned NULL` (Xvnc has no GLX) |
| 3 | Chrome `--disable-gpu` (SwiftShader) | software WebGL works, but CPU-heavy — **declined** per direction |
| 4 | **system** `/opt/VirtualGL` + Nix Chrome | `libvglfaker.so cannot be preloaded` (system-glibc faker vs Nix glibc) |
| 5 | nixpkgs **registry** VGL (glibc 2.42) `glxinfo` | **hardware works** (RTX 3090) — but Chrome → `GLIBC_ABI_DT_X86_64_PLT` (2.42 vs Chrome's 2.40) |
| 6 | **nixpkgs 25.05** VGL (glibc 2.40) + narrow `/opt/nvgl`, `glxinfo` | ✅ **`OpenGL renderer: NVIDIA GeForce RTX 3090, 4.6.0 NVIDIA 580.159.03`** |
| 7 | Chrome under VGL (25.05) `--use-angle=gl` | `Invalid visual ID requested` (ANGLE EGL-X11 wants a visual VGL's surfaceless EGL device lacks) |
| 8 | Chrome under VGL `--use-angle=vulkan` (Kasm's recipe) | `VK_KHR_surface not supported` (VGL is GLX/EGL, not Vulkan) |
| 9 | KasmVNC **DRI3** (`KVNC_DESKTOP_GPU_HW3D`) | Xvnc runs `-hw3d -dri3`; `libEGL permission denied` → after device chmod, Chrome still `dri3 not supported` (mesa glamor ≠ NVIDIA) |
| 10 | KasmVNC **Zink** (`KASM_ENABLE_ZINK`) | handled by `kasm-window-manager`; Chrome via `docker exec` still `Invalid visual ID` |
| 11 | **Full combo**: Nix VGL + Zink env + owned devices, Chrome `--use-angle=gl` | `Invalid visual ID requested` |

## The two real results

**PROVEN — hardware GL works for Nix apps via VirtualGL** (row 6). The recipe:
1. **Version-matched VGL** — build `virtualgl` from the *same* nixpkgs as Chrome
   (25.05/glibc 2.40); registry VGL (2.42) clashes with Chrome's 2.40.
2. **Narrow nvidia-only lib dir** (`/opt/nvgl`): symlink ONLY the NVIDIA vendor
   libs (`libnvidia-*`, `libEGL_nvidia`, `libGLX_nvidia`, glvnd dispatch) from
   the `--gpus`-injected `/usr/lib/x86_64-linux-gnu` — **excluding glibc** so
   Nix's glibc stays authoritative (the `nixglhost` principle).
3. `LD_LIBRARY_PATH=/opt/nvgl:<nix gcc-lib>/lib` + `vglrun -d egl <app>`.

**NOT achieved — Chrome-143 hardware WebGL** (rows 7–11). Persistent blockers via
`docker exec`:
- `--use-angle=gl`: `Invalid visual ID` — ANGLE's **EGL-X11** front-end requests
  an X visual that VGL's surfaceless `-d egl` backend doesn't expose. (`glxinfo`
  works because it uses pure **GLX**, which VGL fakes; ANGLE uses EGL.)
- `--use-angle=vulkan`: `VK_KHR_surface not supported` (no Xvnc Vulkan WSI).
- The core's `kasm-window-manager` uses **system** `/opt/VirtualGL`; its faker
  reintroduces the glibc clash with Nix Chrome. The Nix-VGL fix works standalone
  (glxinfo) but isn't what the inherited WM runs.

## Why bare-docker testing is inconclusive for Chrome

Two differences from a real Kasm GPU deployment may be exactly why Kasm's Chrome
works and ours didn't:
1. **Agent device provisioning** — Kasm chowns the dri devices to the session
   user (`-O` gate); bare `docker --gpus` doesn't, and the GPU X environment the
   agent sets up may differ from plain `--gpus`.
2. **Session inheritance** — Kasm launches Chrome from the **vglrun'd XFCE
   session** (menu); our `docker exec` launches don't inherit that faker/env/X
   visual. This likely matters for the ANGLE visual issue.

## Recommended next steps (focused follow-up, not bare-docker)

1. Make **`nix-launch` GPU-aware**: when `KASM_EGL_CARD` is set, do NOT add
   `--disable-gpu`, do NOT unset `LD_LIBRARY_PATH`, add `--ignore-gpu-blocklist`
   (and `--use-angle=vulkan` per Kasm) so a session-launched Chrome inherits the
   vglrun'd GPU env.
2. Decide whether the Nix images' window-manager should use **Nix** VirtualGL
   for Nix apps (avoids the system-VGL glibc clash) vs the core's system VGL.
3. Bake version-matched `pkgs.virtualgl` + a `nix-activate` step that builds the
   narrow `/opt/nvgl` and chowns the dri devices when `/dev/dri/renderD128`
   exists.
4. **Verify on a real Kasm GPU deployment** with a **menu-launched** Chrome +
   `chrome://gpu` — that's the environment Kasm's "works on any host" assumes.

Software WebGL stays **off** (CPU cost) per direction. Hardware video decode
(VAAPI/NVENC via `KVNC_DESKTOP_GPU_DRINODE`) is untested and a separate item.

---

## Open follow-ups (not done this session)

- **GPU / hardware WebGL** — per the GPU section above (the biggest open item).
- **CI / nightly pipeline** (build-plan M5/M6): per-arch matrix, scheduled
  Chromium rebuild, per-app + fat images, registry dedup. Not started.
- **Private binary cache** (Open Q1), **custom-packages home** (Open Q2),
  **nixpkgs bump 25.05→25.11** (Open Q4) — still open.
- Per-app `vscode-run` / `firefox-run` / `audacity-run` images are **built** but
  only `chrome-run` + `fat-run` are running.
- A pre-existing container `trusting_jennings` (on 6901) was removed during an
  early cleanup — flagged in case it mattered.

## How to resume

```bash
ssh emrul@192.168.1.140
cd ~/workspaces-core-images && . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
bash runs/nix-demo.sh        # build + dedup proof + launch (6902/6903)
```

Rebuild the base after editing activation scripts, then the run images:
```bash
docker build -f dockerfile-nix-ubuntu --build-arg BASE_IMAGE=localhost/kasm-core-ubuntu-noble:dev -t localhost/nix-ubuntu:dev .
docker tag localhost/nix-ubuntu:dev localhost:5000/nix-ubuntu:dev && docker push localhost:5000/nix-ubuntu:dev
nix shell nixpkgs#skopeo --command skopeo inspect --raw --tls-verify=false docker://localhost:5000/nix-ubuntu:dev > nix/base-manifest.json
cd nix && nix build .#chrome-run .#fat-run && for i in chrome-run fat-run; do nix run .#$i.copyToDockerDaemon; done
```
