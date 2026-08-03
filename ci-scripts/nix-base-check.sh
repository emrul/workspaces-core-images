#!/usr/bin/env bash
# nix-base-check.sh — report which distro bases are STALE relative to their
# upstream source image. For each distro, compare the current upstream digest of
# its source image (ubuntu:24.04 / fedora:42 / alpine:3.21 / ubuntu:26.04) to the
# digest stamped on the local nix-<distro>:dev base by nix-base-build.sh.
# Stale = missing base, unstamped, or the upstream digest moved.
#
# CHECK_UPSTREAM=0 runs the LOCAL half only: a base that is missing or unstamped
# is still reported stale, but the upstream digest is not fetched or compared.
# The two halves are separable on purpose — "does this base exist" is a cheap
# local question that must be answered on EVERY pipeline, or a fresh runner (or
# one whose store was reset by gc) never rebuilds the bases and the build job
# dies on a missing base instead. Only the network-touching digest comparison is
# reserved for publishing pipelines.
#
# Runs INSIDE the DIND podman container. Prints exactly one machine-readable line
# (for the CI dotenv):
#   NIX_BASES_STALE=<space list of distro names>
# plus human-readable [base-check] lines on stderr.
set -euo pipefail
WANT="${BASE_DISTROS:-ubuntu fedora alpine resolute}"
CHECK_UPSTREAM="${CHECK_UPSTREAM:-1}"

src_of() { case "$1" in ubuntu) echo ubuntu:24.04 ;; fedora) echo fedora:42 ;; alpine) echo alpine:3.21 ;; resolute) echo ubuntu:26.04 ;; esac; }
nix_of() { case "$1" in ubuntu) echo localhost/nix-ubuntu:dev ;; fedora) echo localhost/nix-fedora:dev ;; alpine) echo localhost/nix-alpine:dev ;; resolute) echo localhost/nix-ubuntu-resolute:dev ;; esac; }

# The nixpkgs rev the base SHOULD have been built from. A base is a nix store
# closure as much as it is a distro image, and the two go stale independently:
# the distro digest can sit still for weeks while nixpkgs ships CVE fixes daily.
# Comparing only the distro digest is what froze the catalogue's base at a
# three-month-old nixpkgs, shipping openssl 3.6.2 and an unpatched perl long
# after the branch had moved past both.
#
# Resolved from the same ref the build uses (bin/nix-profiles.toml [nixpkgs].ref)
# so the comparison is against what a rebuild would actually produce. Empty when
# it cannot be resolved — offline, or no ref configured — and an empty value
# never forces a rebuild, matching how an unresolved upstream digest is handled
# below.
#
# The CALLER resolves it and passes NIXPKGS_REV_WANT. This script runs inside
# DIND_IMG (quay.io/podman/stable), which has NO nix binary — resolving here
# exited 127 and, because of `set -o pipefail`, took the whole prepare stage
# down with it instead of degrading to "unresolved" as intended. The runner host
# does have nix, so that is where the lookup belongs (.gitlab-ci.yml base-check).
#
# The local lookup below is a fallback for running this script by hand on a host
# that does have nix. It is guarded on the binary existing and can never fail the
# script: nix is kept out of any pipeline so pipefail has nothing to trip on.
NIXPKGS_REF="${NIXPKGS_REF:-}"
WANT_REV="${NIXPKGS_REV_WANT:-}"
if [ -z "${WANT_REV}" ] && [ -n "${NIXPKGS_REF}" ] && command -v nix >/dev/null 2>&1; then
  _meta="$(nix --extra-experimental-features 'nix-command flakes' \
      flake metadata --refresh --json "${NIXPKGS_REF}" 2>/dev/null || true)"
  WANT_REV="$(printf '%s' "${_meta}" \
    | sed -n 's/.*"revision":"\([0-9a-f]\{40\}\)".*/\1/p' | head -1)"
fi
if [ -n "${WANT_REV}" ]; then
  echo "[base-check] nixpkgs ${NIXPKGS_REF:-<unset>} rev ${WANT_REV}" >&2
else
  echo "[base-check] nixpkgs rev unresolved — rev comparison skipped (ref='${NIXPKGS_REF:-}')" >&2
fi

stale=""
for d in ${WANT}; do
  src="$(src_of "$d")"; nix="$(nix_of "$d")"
  [ -n "${src}" ] || { echo "[base-check] ${d}: unknown distro — treating as stale" >&2; stale="${stale} ${d}"; continue; }

  # Existence first, and always: this is what makes a cold or gc-reset store
  # self-healing rather than a build failure.
  if ! podman image exists "${nix}" 2>/dev/null; then
    echo "[base-check] ${d}: STALE (no local base)" >&2; stale="${stale} ${d}"; continue
  fi
  have="$(podman image inspect --format '{{index .Config.Labels "dev.kasm.base.src-digest"}}' "${nix}" 2>/dev/null || true)"
  if [ -z "${have}" ] || [ "${have}" = "<no value>" ]; then
    echo "[base-check] ${d}: STALE (base unstamped)" >&2; stale="${stale} ${d}"; continue
  fi

  if [ "${CHECK_UPSTREAM}" != "1" ]; then
    echo "[base-check] ${d}: present and stamped (${have}); upstream comparison skipped" >&2
    continue
  fi

  podman pull -q "docker.io/library/${src}" >/dev/null 2>&1 || podman pull -q "${src}" >/dev/null 2>&1 || true
  up="$(podman image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "${src}" 2>/dev/null | sed 's/.*@//' || true)"
  if [ -n "${up}" ] && [ "${up}" != "${have}" ]; then
    echo "[base-check] ${d}: STALE (${src} moved: have=${have} upstream=${up})" >&2; stale="${stale} ${d}"
  elif [ -z "${up}" ]; then
    echo "[base-check] ${d}: upstream digest unresolved — leaving as-is (not forcing rebuild)" >&2
  else
    echo "[base-check] ${d}: distro image fresh (${have})" >&2
  fi

  # Distro digest says fresh; the nixpkgs rev may still have moved. Checked
  # after the digest so a base that is stale for BOTH reasons is only listed
  # once. An unstamped rev means the base predates this check — rebuild it, so
  # the stamp exists from then on.
  case " ${stale} " in *" ${d} "*) continue ;; esac
  [ -n "${WANT_REV}" ] || continue
  have_rev="$(podman image inspect --format '{{index .Config.Labels "dev.kasm.base.nixpkgs-rev"}}' "${nix}" 2>/dev/null || true)"
  if [ -z "${have_rev}" ] || [ "${have_rev}" = "<no value>" ]; then
    echo "[base-check] ${d}: STALE (no nixpkgs-rev stamp — predates the rev check)" >&2
    stale="${stale} ${d}"
  elif [ "${have_rev}" != "${WANT_REV}" ]; then
    echo "[base-check] ${d}: STALE (nixpkgs moved: have=${have_rev} want=${WANT_REV})" >&2
    stale="${stale} ${d}"
  else
    echo "[base-check] ${d}: fresh (distro ${have}, nixpkgs ${have_rev})" >&2
  fi
done

# normalise: dedup + trim
stale="$(printf '%s\n' ${stale} | sort -u | tr '\n' ' ' | sed 's/ *$//' | sed 's/^ *//')"
echo "NIX_BASES_STALE=${stale}"
# Hand the resolved rev to the base job so it stamps the SAME value this
# check will compare against next run. Resolving it twice could straddle a
# nixpkgs push and stamp a rev the base was not built from.
echo "NIXPKGS_REV_RESOLVED=${WANT_REV}"
