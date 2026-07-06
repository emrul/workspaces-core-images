#!/usr/bin/env bash
# nix-publish.sh — tag the per-app Nix images produced by
# `build-nix-store-volume --emit-app-images` (localhost/nix-<profile>:dev) to
# their Kasm-convention names and push them to the target registry namespace.
#
# Naming: the published image is <REGISTRY_NS>/<kasm_name>:<KASM_TAG>, where
# kasm_name comes from the `kasm_name = "..."` field of the profile in
# nix-profiles.toml (falling back to the profile name). This matches Kasm's
# Docker Hub names — e.g. profile `vscode` → `vs-code`, `onlyoffice` →
# `only-office`, `libreoffice` → `libre-office`, `torbrowser` → `tor-browser`.
#
# Registry migration is a one-variable change:
#   REGISTRY_NS=$CI_REGISTRY_IMAGE   → registry.gitlab.com/.../kasm-nix (now)
#   REGISTRY_NS=docker.io/kasmweb    → docker.io/kasmweb/<name>:nix    (later)
#
# Env:
#   REGISTRY_NS   target namespace (default: $CI_REGISTRY_IMAGE)
#   KASM_TAG      published tag (default: nix)
#   NIX_APP_REPO  local repo prefix from the build (default: localhost/nix)
#   CONFIG        path to nix-profiles.toml (default: ../bin/nix-profiles.toml)
#   DOCKER        container CLI (default: docker)
#   DRY_RUN       1 = print tags/pushes without executing
#   NIX_PROFILES  space list to publish only those profiles (change-gating);
#                 empty = publish every built image; "__none__" = publish nothing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CONFIG:-${SCRIPT_DIR}/../bin/nix-profiles.toml}"
REGISTRY_NS="${REGISTRY_NS:-${CI_REGISTRY_IMAGE:?set REGISTRY_NS or CI_REGISTRY_IMAGE}}"
KASM_TAG="${KASM_TAG:-nix}"
NIX_APP_REPO="${NIX_APP_REPO:-localhost/nix}"
DOCKER="${DOCKER:-docker}"
DRY_RUN="${DRY_RUN:-0}"

[[ -f "${CONFIG}" ]] || { echo "[nix-publish] config not found: ${CONFIG}" >&2; exit 1; }

# Change-gating: restrict to specific profiles, everything, or nothing.
FILTER="${NIX_PROFILES:-}"
if [[ "${FILTER}" == "__none__" ]]; then
  echo "[nix-publish] NIX_PROFILES=__none__ — nothing to publish"; exit 0
fi
in_filter() {  # $1=profile → 0 if it should be published
  [[ -z "${FILTER}" ]] && return 0
  local x; for x in ${FILTER}; do [[ "${x}" == "$1" ]] && return 0; done; return 1
}

# profile -> kasm_name (kasm_name overrides; default = profile name).
kasm_name_for() {
  awk -v want="$1" '
    /^\[profiles\./ { cur=$0; sub(/^\[profiles\./,"",cur); sub(/\].*/,"",cur); name[cur]=cur }
    /^[[:space:]]*kasm_name[[:space:]]*=/ && cur!="" {
      v=$0; sub(/^[^"]*"/,"",v); sub(/".*/,"",v); name[cur]=v
    }
    END { print (want in name) ? name[want] : want }
  ' "${CONFIG}"
}

run() { if [[ "${DRY_RUN}" == 1 ]]; then echo "  DRY: $*"; else "$@"; fi; }

# All per-app images from the build: localhost/nix-<profile>:dev, excluding the
# base (nix-ubuntu) and the fat store (nix-store*).
mapfile -t imgs < <(
  "${DOCKER}" images --format '{{.Repository}}:{{.Tag}}' \
    | grep -E "^${NIX_APP_REPO}-[a-z0-9][a-z0-9-]*:dev$" \
    | grep -vE "^${NIX_APP_REPO}-(ubuntu|store)" \
    | sort -u
)

[[ ${#imgs[@]} -gt 0 ]] || { echo "[nix-publish] no ${NIX_APP_REPO}-<app>:dev images found — nothing to publish" >&2; exit 1; }

echo "[nix-publish] ${#imgs[@]} image(s) → ${REGISTRY_NS}/<kasm_name>:${KASM_TAG}"
pushed=0; failed=()
for img in "${imgs[@]}"; do
  profile="${img#"${NIX_APP_REPO}"-}"; profile="${profile%:dev}"
  in_filter "${profile}" || { echo "[nix-publish] ${profile}: skip (not in NIX_PROFILES)"; continue; }
  kn="$(kasm_name_for "${profile}")"
  dest="${REGISTRY_NS}/${kn}:${KASM_TAG}"
  echo "[nix-publish] ${profile} → ${dest}"
  if run "${DOCKER}" tag "${img}" "${dest}" && run "${DOCKER}" push "${dest}"; then
    pushed=$((pushed+1))
  else
    echo "[nix-publish] WARN push failed: ${profile}" >&2; failed+=("${profile}")
  fi
done

echo "[nix-publish] done: pushed=${pushed} failed=${#failed[@]} ${failed[*]:-}"
[[ ${#failed[@]} -eq 0 ]]
