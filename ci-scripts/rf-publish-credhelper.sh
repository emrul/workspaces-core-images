#!/usr/bin/env bash
# rf-publish-credhelper.sh — publish RapidFort's credential-helper binary to this
# project's GitLab generic package registry, so CI can fetch it with a job token
# instead of the repo carrying a 10 MB vendor blob.
#
# Run this ONCE per RapidFort CLI version, from a host that has the binary (it
# ships with their installer, e.g. ~/rapidfort/rapidfort-linux-amd64).
#
# Needs a token with write_package_registry. Follow this repo's convention: mint a
# SHORT-LIVED token, use it, revoke it immediately (see docs — the same pattern the
# one-off image pushes use). Do not leave a write-scoped token lying around.
#
# Usage:
#   RF_PACKAGE_TOKEN=<write_package_registry token> \
#     bash ci-scripts/rf-publish-credhelper.sh /path/to/rapidfort-linux-amd64 [version]
#
# Then set RF_CLI_VERSION in .gitlab-ci.yml to the version published here.
set -euo pipefail

SRC="${1:-}"
VERSION="${2:-${RF_CLI_VERSION:-1.0.0}}"
PKG_NAME="${RF_CLI_PACKAGE:-rapidfort-cli}"
FILE_NAME="${RF_CLI_FILE:-rapidfort-linux-amd64}"
PROJ="${RF_PACKAGE_PROJECT:-kasm-technologies%2Flabs-sandbox%2Fkasm-nix}"
API="${CI_API_V4_URL:-https://gitlab.com/api/v4}"

die() { printf '[rf-publish] ERROR: %s\n' "$*" >&2; exit 1; }

[ -n "${SRC}" ] || die "usage: rf-publish-credhelper.sh <binary> [version]"
[ -f "${SRC}" ] || die "no such file: ${SRC}"
[ -n "${RF_PACKAGE_TOKEN:-}" ] || die "RF_PACKAGE_TOKEN (write_package_registry) is required"
head -c 4 "${SRC}" | od -An -c | grep -q 'E   L   F' || die "${SRC} is not an ELF binary"

url="${API}/projects/${PROJ}/packages/generic/${PKG_NAME}/${VERSION}/${FILE_NAME}"
printf '[rf-publish] PUT %s (%s bytes)\n' "${url}" "$(wc -c < "${SRC}")" >&2

code="$(curl -sS -o /tmp/rf-publish-out -w '%{http_code}' \
  --header "PRIVATE-TOKEN: ${RF_PACKAGE_TOKEN}" \
  --upload-file "${SRC}" "${url}")"

case "${code}" in
  200|201) printf '[rf-publish] OK — published %s %s\n' "${PKG_NAME}" "${VERSION}" >&2 ;;
  *) printf '[rf-publish] HTTP %s: %s\n' "${code}" "$(head -c 300 /tmp/rf-publish-out)" >&2
     die "upload failed" ;;
esac
rm -f /tmp/rf-publish-out

cat >&2 <<EOF
[rf-publish] Next:
  1. set RF_CLI_VERSION: "${VERSION}" in .gitlab-ci.yml
  2. REVOKE the write_package_registry token you just used
EOF
