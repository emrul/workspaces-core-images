#!/usr/bin/env bash
# nix-base-src.sh — the single source of truth for each distro's UPSTREAM source
# image, plus the registry auth needed to pull it.
#
# SOURCED (not executed) by nix-base-build.sh and nix-base-check.sh, both of which
# run inside the DIND podman container. It exists because the src image used to be
# written out twice — `base_row` in the builder and `src_of` in the checker — so a
# base could be BUILT from one image while staleness was CHECKED against another.
#
# ── RapidFort ───────────────────────────────────────────────────────────────
# The ubuntu base is a RapidFort *curated* image (patched drop-in Noble, full
# apt/dpkg — not their runtime-hardened line). It lives in a PRIVATE registry.
#
# RapidFort issues no static registry credential: RF_ACCESS_ID/RF_SECRET_ACCESS_KEY
# are PLATFORM credentials that quay rejects outright. The credential that works is
# a ~1h quay robot token minted by RF's Docker credential helper, so it is minted
# per job — see rf-credhelper-login.sh for the mechanism and the tradeoff.
#
# The auth file is written to the container's /tmp (see registry_auth_setup), so
# it dies with the ephemeral DIND container. It must never land in the PERSISTENT
# store (/var/lib/containers) or in an image layer.
#
# Env:
#   NIX_BASE_SRC_UBUNTU / _FEDORA / _ALPINE / _RESOLUTE
#                       override any distro's source image. Set _UBUNTU to
#                       `ubuntu:24.04` to fall back off RapidFort.
#   RF_REGISTRY         registry to authenticate against (default quay.io)
#   RF_ROOT_URL         set  -> mint a token via RF's credential helper (the real
#                       RapidFort path). unset -> plain username/password login.
#   RF_ACCESS_ID/RF_SECRET_ACCESS_KEY   RapidFort platform credentials
#   RF_USERNAME/RF_PASSWORD             a STATIC registry credential, if one ever
#                       exists (a quay robot token, our own registry, a mirror)
#   REGISTRY_AUTH_FILE  where podman keeps the login (default /tmp/kasm-nix-auth.json)

# The RapidFort curated Noble image the single-app catalogue is built on.
# One line to revert: set NIX_BASE_SRC_UBUNTU=ubuntu:24.04.
: "${RF_UBUNTU_IMAGE:=quay.io/rfcurated/rfubu:24.04-rfcurated}"

base_src_image() {
  case "$1" in
    ubuntu)   echo "${NIX_BASE_SRC_UBUNTU:-${RF_UBUNTU_IMAGE}}" ;;
    fedora)   echo "${NIX_BASE_SRC_FEDORA:-fedora:42}" ;;
    alpine)   echo "${NIX_BASE_SRC_ALPINE:-alpine:3.21}" ;;
    resolute) echo "${NIX_BASE_SRC_RESOLUTE:-ubuntu:26.04}" ;;
    *) return 1 ;;
  esac
}

# True when the image is not a bare docker.io/library name — i.e. it names a
# registry and may need credentials.
src_is_private_registry() {
  case "$1" in
    */*/*|*.*/*) return 0 ;;   # quay.io/rfcurated/rfubu, registry.example.com/x
    *) return 1 ;;
  esac
}

# Log in to the credentialed registry, if credentials were provided. Safe to call
# more than once, and a no-op when no creds are set (public-only builds).
#
# Two routes, in order:
#   1. RapidFort credential helper (RF_ROOT_URL set) — REQUIRED for quay.io/rfcurated:
#      RF's platform creds are NOT registry creds (quay rejects them); the helper
#      exchanges them for a ~1h robot token. See rf-credhelper-login.sh.
#   2. a plain username/password login — for any registry that issues a static
#      credential (a quay robot token, our own GitLab registry, a mirror).
registry_auth_setup() {
  export REGISTRY_AUTH_FILE="${REGISTRY_AUTH_FILE:-/tmp/kasm-nix-auth.json}"

  local reg user pass
  reg="${RF_REGISTRY:-quay.io}"

  if [ -n "${RF_ROOT_URL:-}" ]; then
    bash "${NIX_CI_SCRIPTS:-/work/ci-scripts}/rf-credhelper-login.sh" || return 1
    return 0
  fi

  # Accept either naming: a static registry credential may arrive under RF's
  # ACCESS_ID/SECRET_ACCESS_KEY names or as USERNAME/PASSWORD.
  user="${RF_USERNAME:-${RF_ACCESS_ID:-}}"
  pass="${RF_PASSWORD:-${RF_SECRET_ACCESS_KEY:-}}"

  if [ -z "${user}" ] || [ -z "${pass}" ]; then
    echo "[base-src] no registry credentials in env — public images only" >&2
    return 0
  fi
  if printf '%s' "${pass}" | podman login "${reg}" -u "${user}" --password-stdin >/dev/null 2>&1; then
    echo "[base-src] authenticated to ${reg} as ${user%%+*}+… (auth file: ${REGISTRY_AUTH_FILE})" >&2
    return 0
  fi
  # Do not print the response: it can echo the credential back.
  echo "[base-src] ERROR: podman login ${reg} FAILED for the supplied credentials" >&2
  return 1
}

# Pull a source image with the right namespace semantics, and say something useful
# when it fails. Returns non-zero on failure — the CALLER decides whether that is
# fatal (the builder: yes; the staleness checker: no).
pull_src() {
  local img="$1"
  if src_is_private_registry "${img}"; then
    podman pull -q "${img}" >/dev/null 2>&1 && return 0
  else
    podman pull -q "docker.io/library/${img}" >/dev/null 2>&1 && return 0
    podman pull -q "${img}" >/dev/null 2>&1 && return 0
  fi

  if src_is_private_registry "${img}" && [ -z "${RF_USERNAME:-${RF_ACCESS_ID:-}}" ]; then
    cat >&2 <<EOF
[base-src] ERROR: cannot pull ${img} and no credentials were provided.
  ${img%%/*} needs a service account. Set these as MASKED, PROTECTED CI/CD
  variables on this project (Settings -> CI/CD -> Variables):
    RF_REGISTRY            ${img%%/*}
    RF_ACCESS_ID           service-account username
    RF_SECRET_ACCESS_KEY   service-account token
  Verify them before a long build with:  bash ci-scripts/rf-auth-check.sh
  Or fall back off RapidFort with:       NIX_BASE_SRC_UBUNTU=ubuntu:24.04
EOF
  else
    echo "[base-src] ERROR: cannot pull ${img} (credentials present — wrong scope, or the tag moved?)" >&2
  fi
  return 1
}

# The digest podman recorded for a tag (manifest-list digest → arch-stable).
src_digest_of() {
  podman image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$1" 2>/dev/null \
    | sed 's/.*@//'
}

# A one-word answer to "what is this built on?", for at-a-glance validation of a
# published image. The exact source ref and digest are recorded too (as the
# standard OCI base annotations) — this is the cheap check, not the truth.
src_flavor_of() {
  case "$1" in
    *rfcurated*|*rapidfort*) echo "rapidfort-curated" ;;
    *) echo "upstream" ;;
  esac
}
