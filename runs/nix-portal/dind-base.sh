#!/usr/bin/env bash
# dind-base.sh — build the core-minimal + nix-ubuntu base images INSIDE the
# privileged podman-in-podman container, into the persistent podman store, so
# dind-build.sh finds localhost/nix-ubuntu:dev.
#
# nix-portal historically treated nix-ubuntu:dev as a preloaded prereq (a tar
# copied from the LAN box). This builds it in-place instead, so CI can refresh
# the base without an out-of-band copy. Normal app builds reuse the warm base;
# run this only when the base dockerfiles / core install tree change.
#
# Mounts (wired by the caller / .gitlab-ci.yml):
#   /work               → repo (ro)
#   /var/lib/containers → host /srv/nix-build/containers (persistent store)
set -euo pipefail
cd /work

CORE="localhost/kasm-core-ubuntu-noble-minimal:dev"
NIXU="localhost/nix-ubuntu:dev"

echo "[dind-base] building ${CORE}"
podman build \
  --build-arg BASE_IMAGE=ubuntu:24.04 \
  --build-arg DISTRO=ubuntu \
  --build-arg BG_IMG=bg_noble.png \
  -f dockerfile-kasm-core-minimal -t "${CORE}" .

echo "[dind-base] building ${NIXU}"
# Stamp the commit this base was built from (BASE_BUILT_SHA, passed by CI =
# CI_COMMIT_SHA). The app-build's freshness guard (dind-build.sh) reads this
# label and refuses to build on a base that predates a base-affecting commit.
podman build \
  --build-arg BASE_IMAGE="${CORE}" \
  --label "kasm.base.builtsha=${BASE_BUILT_SHA:-unknown}" \
  -f dockerfile-nix-ubuntu -t "${NIXU}" .

echo "[dind-base] done: nix-ubuntu = $(podman image inspect -f '{{.Id}}' "${NIXU}") builtsha=${BASE_BUILT_SHA:-unknown}"
