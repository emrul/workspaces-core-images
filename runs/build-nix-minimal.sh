#!/usr/bin/env bash
# Build and push the nix-on-minimal stack:
#   1. core-ubuntu-noble-minimal  (hardened base)
#   2. nix-ubuntu                 (activation layer on top of minimal)
#   3. per-app nix images         (optional, pass app names as args)
#
# Usage:
#   runs/build-nix-minimal.sh                    # builds + pushes 1 + 2
#   runs/build-nix-minimal.sh chrome             # builds + pushes 1 + 2 + nix-chrome
#   runs/build-nix-minimal.sh chrome angelfish
#
# Skip push with --no-push:
#   runs/build-nix-minimal.sh --no-push chrome
#
# Override registry/namespace/tag:
#   KASM_REGISTRY=registry.kasm.com KASM_NAMESPACE=prod runs/build-nix-minimal.sh chrome
#
# Requires: docker login $KASM_REGISTRY (once per session)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=runs/registry.conf
source "${SCRIPT_DIR}/registry.conf"

DOCKER="${DOCKER:-docker}"
PUSH=1

# Parse flags
APPS=()
for arg in "$@"; do
    case "$arg" in
        --no-push) PUSH=0 ;;
        *)         APPS+=("$arg") ;;
    esac
done

case "$(uname -m)" in
    x86_64|amd64)  HOST_PLATFORM=linux/amd64 ;;
    aarch64|arm64) HOST_PLATFORM=linux/arm64 ;;
    *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac
PLATFORM="${PLATFORM:-${HOST_PLATFORM}}"

CORE_MINIMAL_IMG="$(kasm_image core-ubuntu-noble-minimal)"
NIX_UBUNTU_IMG="$(kasm_image nix-ubuntu)"

log() { echo "[build-nix-minimal] $*"; }

push_image() {
    if [ "$PUSH" = "1" ]; then
        log "pushing $1"
        "${DOCKER}" push "$1"
    fi
}

# NIX_ATTR lookup table: app-name → "NIX_ATTR [GPU_SUPPORT]"
# GPU_SUPPORT=1 enables the VirtualGL+vulkan-loader profile in dockerfile-nix-app.
nix_attr_for() {
    case "$1" in
        chrome)      echo "google-chrome 1" ;;
        chromium)    echo "chromium 1" ;;
        angelfish)   echo "kdePackages.angelfish 0" ;;
        firefox)     echo "firefox 0" ;;
        vscode)      echo "vscode 0" ;;
        brave)       echo "brave 1" ;;
        edge)        echo "microsoft-edge 1" ;;
        *)
            echo "unknown app '$1' — add it to nix_attr_for() in $0" >&2
            exit 1
            ;;
    esac
}

# ── Step 1: core-ubuntu-noble-minimal ────────────────────────────────────────
log "building ${CORE_MINIMAL_IMG}"
"${DOCKER}" build \
    --platform="${PLATFORM}" \
    --build-arg BASE_IMAGE=ubuntu:24.04 \
    --build-arg DISTRO=ubuntu \
    --build-arg BG_IMG=bg_noble.png \
    -f "${REPO_ROOT}/dockerfile-kasm-core-minimal" \
    -t "${CORE_MINIMAL_IMG}" \
    "${REPO_ROOT}"
log "built ${CORE_MINIMAL_IMG}"
push_image "${CORE_MINIMAL_IMG}"

# ── Step 2: nix-ubuntu (activation layer) ────────────────────────────────────
log "building ${NIX_UBUNTU_IMG}"
"${DOCKER}" build \
    --platform="${PLATFORM}" \
    --build-arg BASE_IMAGE="${CORE_MINIMAL_IMG}" \
    -f "${REPO_ROOT}/dockerfile-nix-ubuntu" \
    -t "${NIX_UBUNTU_IMG}" \
    "${REPO_ROOT}"
log "built ${NIX_UBUNTU_IMG}"
push_image "${NIX_UBUNTU_IMG}"

# ── Step 3: per-app images ────────────────────────────────────────────────────
for APP in "${APPS[@]}"; do
    read -r NIX_ATTR GPU_SUPPORT <<< "$(nix_attr_for "$APP")"
    APP_IMG="$(kasm_image "nix-${APP}")"
    log "building ${APP_IMG} (NIX_ATTR=${NIX_ATTR} GPU_SUPPORT=${GPU_SUPPORT})"
    "${DOCKER}" build \
        --platform="${PLATFORM}" \
        --build-arg BASE_IMAGE="${NIX_UBUNTU_IMG}" \
        --build-arg NIX_ATTR="${NIX_ATTR}" \
        --build-arg PROFILE_NAME="${APP}" \
        --build-arg NIXPKGS_REV="${KASM_NIXPKGS_REV}" \
        --build-arg GPU_SUPPORT="${GPU_SUPPORT}" \
        -f "${REPO_ROOT}/dockerfile-nix-app" \
        -t "${APP_IMG}" \
        "${REPO_ROOT}"
    log "built ${APP_IMG}"
    push_image "${APP_IMG}"
done

log "done."
echo
echo "Images built$([ "$PUSH" = "1" ] && echo " and pushed" || echo " (not pushed)"):"
echo "  ${CORE_MINIMAL_IMG}"
echo "  ${NIX_UBUNTU_IMG}"
for APP in "${APPS[@]}"; do
    echo "  $(kasm_image "nix-${APP}")"
done
