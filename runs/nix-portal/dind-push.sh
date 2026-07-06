#!/usr/bin/env bash
# dind-push.sh — push the built Nix images from the persistent DinD podman store
# to the Forgejo registry. Runs INSIDE a privileged podman/stable container with
# /var/lib/containers bind-mounted to the persistent store (same as the build).
#
# The push token is read from STDIN (never an argv/env, so it can't leak into
# `ps` or logs) and fed straight to `podman login --password-stdin`.
#
# Pushes: the fat store (nix-store-<arch>) + every runnable nix-<app>. The
# intermediate nix-store/<app> store-images are build artifacts and are skipped
# (the runnable images already carry the same layers).
#
# Target: forge.emrul.dev/beta/<name>:nix  (user: agents)
set -uo pipefail

REG="${REG:-forge.emrul.dev}"
NS="${NS:-beta}"
RUSER="${RUSER:-agents}"

TOK="$(cat)"   # token piped in on stdin
[ -n "${TOK}" ] || { echo "[push] no token on stdin"; exit 1; }
printf '%s' "${TOK}" | podman login "${REG}" -u "${RUSER}" --password-stdin || {
  echo "[push] login failed"; exit 1; }
unset TOK

mapfile -t imgs < <(podman images --format '{{.Repository}}:{{.Tag}}' \
  | grep -E '^localhost/nix-(store-(amd64|arm64)|[a-z0-9][a-z0-9-]*):' \
  | grep -vE 'nix-store/|nix-ubuntu' | sort -u)

echo "[push] ${#imgs[@]} image(s) to ${REG}/${NS}"
pushed=0; failed=()
for img in "${imgs[@]}"; do
  name="${img#localhost/}"             # e.g. nix-chrome:dev / nix-store-amd64:dev
  base="${name%:*}"                    # drop local :dev tag → nix-chrome
  dest="${REG}/${NS}/${base}:nix"      # publish as :nix
  echo "[push] ${img} → ${dest}"
  if podman tag "${img}" "${dest}" && podman push "${dest}"; then
    pushed=$((pushed+1))
  else
    echo "[push] WARN failed: ${img}"; failed+=("${name}")
  fi
done
echo "[push] done: pushed=${pushed} failed=${#failed[@]} ${failed[*]:-}"
