#!/usr/bin/env bash
# dind-launch.sh — start the Nix per-app build as a DETACHED privileged
# podman-in-podman container on the Portal box. Run this ON the Portal host
# (or via ssh). The build then survives your SSH session; observe it with
# dind-check.sh.
#
# Usage (on the Portal host):
#   runs/nix-portal/dind-launch.sh [PROFILES] [PUSH_REGISTRY]
#     PROFILES        optional CSV/space list (e.g. "chrome" or "chrome,vlc");
#                     empty = every profile in bin/nix-profiles.toml
#     PUSH_REGISTRY   optional; e.g. forge.emrul.dev (requires the container to
#                     be logged in — see notes). Empty = build locally only.
#
# Everything heavy lives under /srv/nix-build on the host:
#   containers/  persistent podman store (warm cache + built images)
#   output/      logs, STATUS, app-*.tar, fat-store image.tar
set -euo pipefail

ROOT=/srv/nix-build
REPO="${REPO:-/home/ubuntu/dev/kasm/gitlab/workspaces-core-images}"
IMG="${IMG:-quay.io/podman/stable}"
NAME="${NAME:-nixbuild}"
PROFILES="${1:-}"
PUSH="${2:-}"

[ -d "$REPO" ] || { echo "repo not found: $REPO" >&2; exit 1; }

sudo mkdir -p "$ROOT/containers" "$ROOT/output"

# Reset any prior run's container (the persistent store under containers/ is
# kept, so the Nix cache and base image survive).
sudo nerdctl rm -f "$NAME" 2>/dev/null || true
: > /tmp/dind-prelaunch || true

echo "[launch] starting detached build container '$NAME'"
echo "[launch]   profiles: ${PROFILES:-<all>}   push: ${PUSH:-<none>}"
sudo nerdctl run -d --name "$NAME" --privileged \
  -v "$ROOT/containers:/var/lib/containers" \
  -v "$ROOT/output:/root/.cache/nix-build-output" \
  -v "$REPO:/work:ro" \
  -e "PROFILES=$PROFILES" \
  -e "PUSH=$PUSH" \
  "$IMG" /work/runs/nix-portal/dind-build.sh

echo "[launch] started. Watch with:  runs/nix-portal/dind-check.sh"
echo "[launch] live log:             sudo nerdctl logs -f $NAME"
