#!/usr/bin/env bash
# nix-base-check.sh — report which distro bases are STALE relative to their
# upstream source image. For each distro, compare the current upstream digest of
# its source image (ubuntu:24.04 / fedora:42 / alpine:3.21) to the digest stamped
# on the local nix-<distro>:dev base by nix-base-build.sh. Stale = missing base,
# unstamped, or the upstream digest moved.
#
# Runs INSIDE the DIND podman container. Prints exactly one machine-readable line
# (for the CI dotenv):
#   NIX_BASES_STALE=<space list of distro names>
# plus human-readable [base-check] lines on stderr.
set -euo pipefail
WANT="${BASE_DISTROS:-ubuntu fedora alpine resolute}"

src_of() { case "$1" in ubuntu) echo ubuntu:24.04 ;; fedora) echo fedora:42 ;; alpine) echo alpine:3.21 ;; resolute) echo ubuntu:26.04 ;; esac; }
nix_of() { case "$1" in ubuntu) echo localhost/nix-ubuntu:dev ;; fedora) echo localhost/nix-fedora:dev ;; alpine) echo localhost/nix-alpine:dev ;; resolute) echo localhost/nix-ubuntu-resolute:dev ;; esac; }

stale=""
for d in ${WANT}; do
  src="$(src_of "$d")"; nix="$(nix_of "$d")"
  [ -n "${src}" ] || { echo "[base-check] ${d}: unknown distro — treating as stale" >&2; stale="${stale} ${d}"; continue; }
  podman pull -q "docker.io/library/${src}" >/dev/null 2>&1 || podman pull -q "${src}" >/dev/null 2>&1 || true
  up="$(podman image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "${src}" 2>/dev/null | sed 's/.*@//' || true)"
  if ! podman image exists "${nix}" 2>/dev/null; then
    echo "[base-check] ${d}: STALE (no local base)" >&2; stale="${stale} ${d}"; continue
  fi
  have="$(podman image inspect --format '{{index .Config.Labels "dev.kasm.base.src-digest"}}' "${nix}" 2>/dev/null || true)"
  if [ -z "${have}" ] || [ "${have}" = "<no value>" ]; then
    echo "[base-check] ${d}: STALE (base unstamped)" >&2; stale="${stale} ${d}"
  elif [ -n "${up}" ] && [ "${up}" != "${have}" ]; then
    echo "[base-check] ${d}: STALE (${src} moved: have=${have} upstream=${up})" >&2; stale="${stale} ${d}"
  elif [ -z "${up}" ]; then
    echo "[base-check] ${d}: upstream digest unresolved — leaving as-is (not forcing rebuild)" >&2
  else
    echo "[base-check] ${d}: fresh (${have})" >&2
  fi
done

# normalise: dedup + trim
stale="$(printf '%s\n' ${stale} | sort -u | tr '\n' ' ' | sed 's/ *$//' | sed 's/^ *//')"
echo "NIX_BASES_STALE=${stale}"
