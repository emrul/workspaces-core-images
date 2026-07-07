#!/usr/bin/env bash
# dind-base-alpine.sh — build the alpine (musl) core + nix-alpine base images
# INSIDE the privileged podman-in-podman container, into the persistent podman
# store. Alpine sibling of dind-base.sh / dind-base-fedora.sh.
#
# Nix apps are glibc but run on musl (own loader from /nix/store); the fat store
# is distro-independent, so the same nix-store image mounts here. No alpine
# "minimal" core (dockerfile-kasm-core-minimal is apt-only) — build on the
# standard alpine core. Graphics is software-only on musl (see dockerfile-nix-alpine).
#
# Mounts (wired by the caller):
#   /work               → repo (ro)
#   /var/lib/containers → host /srv/nix-build/containers (persistent store)
set -euo pipefail
cd /work

CORE="localhost/kasm-core-alpine:dev"
NIXA="localhost/nix-alpine:dev"

echo "[dind-base-alpine] building ${CORE}"
podman build \
  --build-arg BASE_IMAGE=alpine:3.21 \
  --build-arg DISTRO=alpine \
  --build-arg BG_IMG=bg_alpine.png \
  -f dockerfile-kasm-core-alpine -t "${CORE}" .

echo "[dind-base-alpine] building ${NIXA}"
podman build \
  --build-arg BASE_IMAGE="${CORE}" \
  -f dockerfile-nix-alpine -t "${NIXA}" .

echo "[dind-base-alpine] done: nix-alpine = $(podman image inspect -f '{{.Id}}' "${NIXA}")"
