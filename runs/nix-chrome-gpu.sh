#!/usr/bin/env bash
# nix-chrome-gpu.sh — launch the single-app Nix Chrome image WITH GPU for
# MANUAL testing (a real Kasm GPU session sets the same run-config via the agent).
#
# Just mirrors the Kasm agent's GPU run config (nvidia runtime + dri device nodes
# + KASM_EGL_CARD/RENDERD). No manual chown is needed: the image's boot-time
# nix-gpu-setup.service re-chowns the dri nodes from root to the session user
# before Chrome launches (this fork runs container-init as PID 1/root, so the
# nodes arrive root-owned). Chrome then auto-launches on the GPU path.
#
# Usage:  runs/nix-chrome-gpu.sh [IMAGE] [PORT]
#   IMAGE  default nix-chrome:dev
#   PORT   default 6902   (-> https://<host>:PORT, kasm-user / password)
#
# Requires: an NVIDIA host with the nvidia container runtime, and (for Chrome's
# namespace sandbox on the software path) the host sysctl
# kernel.apparmor_restrict_unprivileged_userns=0.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${1:-nix-chrome:dev}"
PORT="${2:-6902}"
NAME=nix-chrome-gpu
SECCOMP="$here/../src/common/seccomp/chrome.json"

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
  --security-opt "seccomp=$SECCOMP" --security-opt apparmor=unconfined \
  -p "${PORT}:6901" "$IMAGE" >/dev/null

echo "-> https://<host>:${PORT}   (kasm-user / password)"
echo "   Chrome auto-launches; chrome://gpu should show ANGLE (NVIDIA, Vulkan ... RTX 3090)."
echo "   (nix-gpu-setup chowns the dri nodes at boot — no manual chown needed.)"
