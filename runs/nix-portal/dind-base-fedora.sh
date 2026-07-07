#!/usr/bin/env bash
# dind-base-fedora.sh — build the fedora core + nix-fedora base images INSIDE
# the privileged podman-in-podman container, into the persistent podman store,
# so a Nix desktop/app workspace can build FROM / mount onto nix-fedora.
#
# Fedora sibling of dind-base.sh. Unlike ubuntu there is no fedora "minimal"
# core (dockerfile-kasm-core-minimal is apt-only), so nix-fedora builds on the
# standard fedora core. The fat store is distro-independent, so the same
# nix-store image mounts here.
#
# Mounts (wired by the caller):
#   /work               → repo (ro)
#   /var/lib/containers → host /srv/nix-build/containers (persistent store)
set -euo pipefail
cd /work

CORE="localhost/kasm-core-fedora:dev"
NIXF="localhost/nix-fedora:dev"

echo "[dind-base-fedora] building ${CORE}"
podman build \
  --build-arg BASE_IMAGE=fedora:42 \
  --build-arg DISTRO=fedora42 \
  --build-arg BG_IMG=bg_fedora.png \
  -f dockerfile-kasm-core-fedora -t "${CORE}" .

echo "[dind-base-fedora] building ${NIXF}"
podman build \
  --build-arg BASE_IMAGE="${CORE}" \
  -f dockerfile-nix-fedora -t "${NIXF}" .

echo "[dind-base-fedora] done: nix-fedora = $(podman image inspect -f '{{.Id}}' "${NIXF}")"
