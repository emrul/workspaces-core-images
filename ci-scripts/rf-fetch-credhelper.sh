#!/usr/bin/env bash
# rf-fetch-credhelper.sh — put RapidFort's Docker credential helper where the DIND
# build can exec it. Runs on the RUNNER (not inside DIND), before the base job
# enters the container.
#
# The binary is ~10 MB of vendor code. It is deliberately NOT committed to this
# repo — it is versioned in the project's GitLab **generic package registry** and
# fetched with CI_JOB_TOKEN, so:
#   * git history stays free of a vendor blob that changes on their schedule
#   * the build has no dependency on RapidFort's servers being up
#   * the version in use is explicit (RF_CLI_VERSION) and auditable
#
# Publish a new version with ci-scripts/rf-publish-credhelper.sh.
#
# Lands at $CI_PROJECT_DIR/.rf/docker-credential-rfcurated, which the base job
# mounts read-only into DIND at /work/.rf/ (see RF_CRED_HELPER).
#
# Env:
#   RF_CLI_VERSION      package version to fetch          (default 1.0.0)
#   RF_CRED_HELPER_URL  fetch from this URL instead (an RF installer mirror, say)
#   CI_API_V4_URL, CI_PROJECT_ID, CI_JOB_TOKEN   supplied by GitLab
#   RF_PACKAGE_TOKEN    PRIVATE-TOKEN to use when running outside CI
set -euo pipefail

DEST_DIR="${DEST_DIR:-${CI_PROJECT_DIR:-$PWD}/.rf}"
DEST="${DEST_DIR}/docker-credential-rfcurated"
VERSION="${RF_CLI_VERSION:-1.0.0}"
PKG_NAME="${RF_CLI_PACKAGE:-rapidfort-cli}"
FILE_NAME="${RF_CLI_FILE:-rapidfort-linux-amd64}"

log() { printf '[rf-fetch] %s\n' "$*" >&2; }
die() { printf '[rf-fetch] ERROR: %s\n' "$*" >&2; exit 1; }

mkdir -p "${DEST_DIR}"

if [ -n "${RF_CRED_HELPER_URL:-}" ]; then
  log "fetching ${RF_CRED_HELPER_URL}"
  curl -fsSL -o "${DEST}" "${RF_CRED_HELPER_URL}" || die "download failed"
else
  api="${CI_API_V4_URL:-https://gitlab.com/api/v4}"
  proj="${CI_PROJECT_ID:-kasm-technologies%2Flabs-sandbox%2Fkasm-nix}"
  url="${api}/projects/${proj}/packages/generic/${PKG_NAME}/${VERSION}/${FILE_NAME}"
  auth=()
  if [ -n "${RF_PACKAGE_TOKEN:-}" ]; then
    auth=(--header "PRIVATE-TOKEN: ${RF_PACKAGE_TOKEN}")
  elif [ -n "${CI_JOB_TOKEN:-}" ]; then
    auth=(--header "JOB-TOKEN: ${CI_JOB_TOKEN}")
  else
    die "no CI_JOB_TOKEN or RF_PACKAGE_TOKEN to authenticate the package download"
  fi
  log "fetching ${PKG_NAME} ${VERSION} (${FILE_NAME}) from the package registry"
  curl -fsSL "${auth[@]}" -o "${DEST}" "${url}" \
    || die "download failed. Has the helper been published? See ci-scripts/rf-publish-credhelper.sh"
fi

chmod 0755 "${DEST}"

# A 404 body or an HTML error page would happily land as a "binary" — check.
if ! head -c 4 "${DEST}" | od -An -c | grep -q 'E   L   F'; then
  rm -f "${DEST}"
  die "downloaded file is not an ELF binary (an error page?). Nothing installed."
fi

log "installed ${DEST} ($(wc -c < "${DEST}") bytes)"
