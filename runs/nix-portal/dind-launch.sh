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

# Build knobs forwarded into the container:
#   BUILD_PARALLEL  per-app concurrency (default min(nproc,4) in build script)
#   EMIT_APPS       1 (default) emit per-app images; 0 = fat store only
#   FORCE_ALL       1 = skip change-gating, build the whole catalog
#   NIX_GATE_BASE   git ref to diff against for gating (default HEAD~1)
BUILD_PARALLEL="${BUILD_PARALLEL:-}"
EMIT_APPS="${EMIT_APPS:-1}"
FORCE_ALL="${FORCE_ALL:-0}"
NIX_GATE_BASE="${NIX_GATE_BASE:-HEAD~1}"

[ -d "$REPO" ] || { echo "repo not found: $REPO" >&2; exit 1; }

# ── change-gating (host-side, where git history lives) ──────────────────────
# No reason this should be CI-only: when no explicit PROFILES arg is given and
# FORCE_ALL!=1, compute the profile set from what changed since NIX_GATE_BASE
# (committed + uncommitted, since /work is the live checkout) using the SAME
# mapping as CI (ci-scripts/nix-changed-profiles.sh). Result:
#   ""          shared/base file changed → build all
#   "a b c"     only these app profiles changed
#   "__none__"  nothing image-relevant changed → dind-build.sh no-ops
if [ -z "$PROFILES" ] && [ "$FORCE_ALL" != "1" ]; then
  if base_sha="$(git -C "$REPO" rev-parse --verify --quiet "${NIX_GATE_BASE}^{commit}" 2>/dev/null)"; then
    changed="$(git -C "$REPO" diff --name-only "$base_sha" 2>/dev/null || true)"
    gated="$(NIX_CHANGED_FILES="$changed" bash "$REPO/ci-scripts/nix-changed-profiles.sh" | sed -n 's/^NIX_PROFILES=//p')"
    PROFILES="$gated"
    echo "[launch] change-gating vs ${NIX_GATE_BASE} (${base_sha}): PROFILES='${PROFILES:-<all>}'"
    echo "[launch]   (override with an explicit PROFILES arg, FORCE_ALL=1, or NIX_GATE_BASE=<ref>)"
  else
    echo "[launch] gating base '${NIX_GATE_BASE}' not resolvable — building all"
  fi
fi

sudo mkdir -p "$ROOT/containers" "$ROOT/output"

# Reset any prior run's container (the persistent store under containers/ is
# kept, so the Nix cache and base image survive).
sudo nerdctl rm -f "$NAME" 2>/dev/null || true
: > /tmp/dind-prelaunch || true

if [ "$PROFILES" = "__none__" ]; then
  echo "[launch] change-gating: no image-relevant changes since ${NIX_GATE_BASE} — nothing to build."
  echo "[launch] (use FORCE_ALL=1 or pass an explicit PROFILES arg to build anyway)"
  exit 0
fi

echo "[launch] starting detached build container '$NAME'"
echo "[launch]   profiles: ${PROFILES:-<all>}   push: ${PUSH:-<none>}   emit_apps: ${EMIT_APPS}   parallel: ${BUILD_PARALLEL:-<default>}"
sudo nerdctl run -d --name "$NAME" --privileged \
  -v "$ROOT/containers:/var/lib/containers" \
  -v "$ROOT/output:/root/.cache/nix-build-output" \
  -v "$REPO:/work:ro" \
  -e "PROFILES=$PROFILES" \
  -e "PUSH=$PUSH" \
  -e "EMIT_APPS=$EMIT_APPS" \
  -e "BUILD_PARALLEL=$BUILD_PARALLEL" \
  "$IMG" /work/runs/nix-portal/dind-build.sh

echo "[launch] started. Watch with:  runs/nix-portal/dind-check.sh"
echo "[launch] live log:             sudo nerdctl logs -f $NAME"
