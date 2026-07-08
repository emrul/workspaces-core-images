#!/usr/bin/env bash
# nix-blender-gpu.sh — launch the single-app Nix Blender image WITH GPU for
# MANUAL testing (a real Kasm GPU session sets the same run-config via the agent).
#
# Mirrors the Kasm agent's GPU run config (nvidia runtime + dri device nodes +
# KASM_EGL_CARD/RENDERD). No manual chown is needed: the image's boot-time
# nix-gpu-setup.service re-chowns the dri nodes from root to the session user
# before Blender launches. blender-launch then detects the owned nodes and runs
# Blender under Nix VirtualGL (vglrun -d egl) on the real GPU.
#
# Unlike Chrome, Blender is a native-GL app (not a chromium sandbox), so it needs
# no custom seccomp profile — the default is fine.
#
# Usage:  runs/nix-blender-gpu.sh [IMAGE] [PORT]
#   IMAGE  default forge.emrul.dev/beta/nix-blender:nix (via kasm_image)
#   PORT   default 6903   (-> https://<host>:PORT, kasm-user / password)
#
# Requires: an NVIDIA host with the nvidia container runtime.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=runs/registry.conf
source "${here}/registry.conf"
IMAGE="${1:-$(kasm_image nix-blender)}"
PORT="${2:-6903}"
NAME=nix-blender-gpu

# Pick the render node + its matching card node (first NVIDIA-capable dri pair).
RENDERD="$(ls /dev/dri/renderD* 2>/dev/null | head -1)"
CARD="$(ls /dev/dri/card* 2>/dev/null | head -1)"
[ -n "$RENDERD" ] && [ -n "$CARD" ] || { echo "no /dev/dri render/card nodes found" >&2; exit 1; }

echo "image=$IMAGE port=$PORT card=$CARD renderD=$RENDERD"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" \
  --runtime=nvidia \
  -e NVIDIA_VISIBLE_DEVICES=all \
  -e NVIDIA_DRIVER_CAPABILITIES=graphics,display,utility,compute \
  --device "$CARD" --device "$RENDERD" \
  -e KASM_EGL_CARD="$CARD" -e KASM_RENDERD="$RENDERD" \
  -e VNC_PW=password --shm-size=1g \
  -p "${PORT}:6901" "$IMAGE" >/dev/null

echo "-> https://<host>:${PORT}   (kasm-user / password)"
echo "   Blender auto-launches; check the container log for"
echo "     'blender-launch: GPU allocated — handing off to nix-gpu-run (vglrun -d egl)'"
echo "   and 'nix-gpu-run: GPU path — vglrun -d egl ...'. In Blender, the System"
echo "   Console / Help > System Info should report the NVIDIA GL renderer, not"
echo "   llvmpipe. (nix-gpu-setup chowns the dri nodes at boot — no manual chown.)"
