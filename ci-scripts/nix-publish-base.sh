#!/usr/bin/env bash
# nix-publish-base.sh — tag the Nix *base/core* images built by the `base`
# pipeline stage (ci-scripts/nix-base-build.sh) to their Kasm-convention names
# and push them to the target registry namespace.
#
# These are the base images app/desktop workspaces build FROM or mount, NOT the
# per-app catalog (that's nix-publish.sh). Naming is Kasm-consistent with a
# `kasm-core-<distro>` repo and the shared `:nix` tag, e.g. the Nix ubuntu core
# publishes as <NS>/kasm-core-ubuntu:nix.
#
# Registry migration is one variable (same as nix-publish.sh):
#   REGISTRY_NS = $CI_REGISTRY_IMAGE  → GitLab Container Registry (now)
#   REGISTRY_NS = docker.io/kasmweb   → Docker Hub (later)
#
# Env:
#   REGISTRY_NS  target namespace (default: $CI_REGISTRY_IMAGE)
#   KASM_TAG     published tag (default: nix)
#   DOCKER       container CLI (default: docker; CI uses podman)
#   DRY_RUN      1 = print tags/pushes without executing
#   NIX_BASES    space list of published names to restrict to (e.g.
#                "kasm-core-ubuntu"); empty = every base whose local image exists
set -euo pipefail

REGISTRY_NS="${REGISTRY_NS:-${CI_REGISTRY_IMAGE:?set REGISTRY_NS or CI_REGISTRY_IMAGE}}"
KASM_TAG="${KASM_TAG:-nix}"
DOCKER="${DOCKER:-docker}"
DRY_RUN="${DRY_RUN:-0}"
FILTER="${NIX_BASES:-}"

# ── base image map: local build tag  →  published kasm-core repo name ────────
# Now shared with nix-publish.sh (which measures these images' uncompressed size
# for the registry), so the list lives in one file rather than being copied.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci-scripts/nix-base-map.sh
. "${SCRIPT_DIR}/nix-base-map.sh"
BASES="${NIX_BASES_MAP}"

in_filter() { [ -z "${FILTER}" ] && return 0; local x; for x in ${FILTER}; do [ "${x}" = "$1" ] && return 0; done; return 1; }
run() { if [ "${DRY_RUN}" = 1 ]; then echo "  DRY: $*"; else "$@"; fi; }

echo "[nix-publish-base] target: ${REGISTRY_NS}/<kasm-core-*>:${KASM_TAG}"
# Publish an image INDEX rather than a bare manifest, so the platform is
# visible to clients that select before pulling (see nix-publish.sh for the
# full reasoning). One linux/amd64 descriptor today; arm64 is one more
# `manifest add` when it exists.
push_index() { # $1=dest
  if [[ "${DOCKER}" == *podman* ]]; then
    local list="${1}-idx"
    "${DOCKER}" manifest rm "${list}" >/dev/null 2>&1 || true
    run "${DOCKER}" manifest create "${list}" || return 1
    run "${DOCKER}" manifest add "${list}" "containers-storage:${1}" || return 1
    run "${DOCKER}" manifest push --all "${list}" "docker://${1}" || return 1
    "${DOCKER}" manifest rm "${list}" >/dev/null 2>&1 || true
  else
    run "${DOCKER}" push "$1" || return 1
    if command -v docker >/dev/null 2>&1 && docker buildx version >/dev/null 2>&1; then
      run docker buildx imagetools create -t "$1" "$1" || return 1
    else
      echo "[nix-publish-base] WARN no buildx: ${1} published as a bare manifest" >&2
    fi
  fi
}

pushed=0; skipped=0; missing=0; failed=()
while IFS='|' read -r local_img repo; do
  [ -n "${local_img}" ] || continue
  in_filter "${repo}" || { echo "[nix-publish-base] ${repo}: skip (not in NIX_BASES)"; skipped=$((skipped+1)); continue; }
  if ! "${DOCKER}" image exists "${local_img}" 2>/dev/null && \
     ! "${DOCKER}" image inspect "${local_img}" >/dev/null 2>&1; then
    echo "[nix-publish-base] ${repo}: local image absent (${local_img}) — run the base build first" >&2
    missing=$((missing+1)); continue
  fi
  dest="${REGISTRY_NS}/${repo}:${KASM_TAG}"
  echo "[nix-publish-base] ${local_img} → ${dest}"
  if run "${DOCKER}" tag "${local_img}" "${dest}" && push_index "${dest}"; then
    pushed=$((pushed+1))
  else
    echo "[nix-publish-base] WARN push failed: ${repo}" >&2; failed+=("${repo}")
  fi
done <<EOF
${BASES}
EOF

echo "[nix-publish-base] done: pushed=${pushed} skipped=${skipped} missing=${missing} failed=${#failed[@]} ${failed[*]:-}"
[ ${#failed[@]} -eq 0 ]
