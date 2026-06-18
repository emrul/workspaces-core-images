# Nix app images — known limitations

Scope: the Nix-packaged app images (`nix-ubuntu` + per-app, e.g.
`nix-angelfish`, `nix-chrome-run`) running under KasmVNC. See
[`docs/handover.md`](docs/handover.md) for the GPU investigation and the team
memory `nix-gpu-webgl-recipe` for the working GPU recipe.

---

## 1. QtWebEngine (Angelfish) cannot do WebGL under KasmVNC

**Status:** confirmed limitation, no fix. Affects any QtWebEngine app
(Angelfish, and any other Qt browser/embedded-web app), **not** standalone
Chromium/Chrome.

### Symptom

Angelfish launches and renders normal web pages correctly (UI, text, layout,
CSS — all fine in software). **WebGL specifically fails**: a WebGL test page
(e.g. `get.webgl.org`, `webglsamples.org/aquarium`) shows:

```
It does not appear your computer supports WebGL.
Status: Could not create a WebGL context,
        GL_VENDOR = Disabled, GL_RENDERER = Disabled,
        ErrorMessage = BindToCurrentSequence failed.
```

This holds **both** without a GPU and with a GPU allocated to the session.

### Root cause

Standalone Chrome/Chromium runs an **independent GPU process** that creates its
own GL/Vulkan context (SwiftShader in software, or ANGLE→GPU with hardware), so
WebGL works regardless of the host X server's GL capabilities.

QtWebEngine instead binds chromium's GL to **Qt's own GL integration**
(`SurfaceFactoryQt` / `QtWebEngineCore`). It needs a working Qt `QOpenGLContext`,
and on a headless KasmVNC `Xvnc` (no native GLX/EGL) it cannot reliably get one:

- We force Qt's software path (`QT_QUICK_BACKEND=software`,
  `QT_XCB_GL_INTEGRATION=none`) so the **UI** renders without crashing — but then
  Qt has **no GL context**, so QtWebEngine reports WebGL `Disabled`.
- Letting Qt use EGL (`QT_XCB_GL_INTEGRATION=xcb_egl`, Mesa llvmpipe) to give it
  a context **crashes** Angelfish at startup on this stack.
- Under a GPU (VirtualGL), QtWebEngine's GPU process **`qFatal`-aborts** with
  `ANGLE Display::initialize error: Invalid visual ID requested` — ANGLE's
  EGL-X11 front-end wants an X visual VGL's surfaceless EGL doesn't expose, and
  QtWebEngine **ignores `--use-angle=vulkan`** (the flag that makes standalone
  Chrome work), so it can't take the Vulkan path that does succeed for Chrome.

### What was tried (all on the RTX 3090 host, 2026-06-18)

| Attempt | Result |
|---|---|
| Software, default (`--disable-gpu --disable-software-rasterizer`) | WebGL `Disabled` |
| `--use-angle=swiftshader` + `--enable-unsafe-swiftshader` | ignored by QtWebEngine → still `Disabled` |
| Qt EGL integration (`xcb_egl`) + Mesa llvmpipe | Angelfish core-dumps at startup |
| GPU: `vglrun -d egl` + `--use-angle=vulkan` (the recipe that works for Chrome) | QtWebEngine ignores it, uses ANGLE-EGL-GL → `qFatal` "Invalid visual ID" |
| GPU: `vglrun` + `--use-angle=gl` | "Invalid visual ID" (same) |

The one remaining untried lead is `--in-process-gpu` (make QtWebEngine's GPU
work share Qt's context rather than spawn a separate, failing GPU process). It
was not pursued — QtWebEngine WebGL on a headless software X server is a
known-hard problem upstream, and the chromium-based path below already solves the
actual need.

### What works instead

**Standalone Chromium/Chrome get WebGL both ways** (proven, same host/session):

- **No GPU** → SwiftShader (CPU) WebGL — `ANGLE (Google, Vulkan ... SwiftShader)`
- **GPU allocated** → hardware WebGL —
  `ANGLE (NVIDIA, Vulkan 1.4.312 (NVIDIA GeForce RTX 3090), NVIDIA)`

via `/usr/local/bin/nix-gpu-run` + the GPU-aware `nix-launch` (see
`src/ubuntu/install/nix/scripts/`). The GPU path is deliberately restricted to
standalone chromium-family binaries for this reason.

### Recommendation

If WebGL / GPU acceleration matters for a lightweight single-app browser, use a
**Chromium-based** engine (a `nix-chromium` single-app image, mirroring
`dockerfile-nix-angelfish`), not QtWebEngine. Angelfish remains fine as a
lightweight browser for **non-WebGL** browsing.

---

## 2. GPU acceleration requires the Kasm GPU runtime contract

The `nix-gpu-run` GPU path only engages when the Kasm platform has actually
allocated a GPU to the session: the nvidia container runtime injects the driver
libs, and the agent **chowns** `/dev/dri/{card,renderD*}` to the session user.
The launcher gates on `[ -O $KASM_EGL_CARD ]` (device owned by us), exactly like
the core image's `kasm-window-manager` and the apt browser launchers. A bare
`docker run --gpus all` leaves the nodes root-owned, so even a GPU-capable image
takes the software path standalone — this is expected, not a bug.
