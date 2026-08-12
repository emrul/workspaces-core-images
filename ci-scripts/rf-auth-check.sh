#!/usr/bin/env bash
# rf-auth-check.sh — verify the RapidFort registry credentials BEFORE a long build.
#
# The base build is measured in hours; discovering bad credentials at the pull is
# an expensive way to learn it. This asks the registry directly, with curl only —
# no podman, no RapidFort CLI — so it also runs on a laptop or any runner.
#
# It distinguishes the three failures that look alike from a build log:
#   * credentials rejected            -> wrong values, or not registry credentials
#   * authenticated but no such repo  -> wrong image/namespace, or scope too narrow
#   * authenticated but no such tag   -> tag moved or was withdrawn
#
# Usage:
#   bash ci-scripts/rf-auth-check.sh                      # uses env + the default image
#   bash ci-scripts/rf-auth-check.sh quay.io/rfcurated/rfubu:24.04-rfcurated
#
# Env: RF_REGISTRY, RF_USERNAME|RF_ACCESS_ID, RF_PASSWORD|RF_SECRET_ACCESS_KEY,
#      NIX_BASE_SRC_UBUNTU (the image to check, if no argument is given).
set -uo pipefail

IMAGE="${1:-${NIX_BASE_SRC_UBUNTU:-quay.io/rfcurated/rfubu:24.04-rfcurated}}"

USER_="${RF_USERNAME:-${RF_ACCESS_ID:-}}"
PASS_="${RF_PASSWORD:-${RF_SECRET_ACCESS_KEY:-}}"

# quay.io/rfcurated/rfubu:24.04-rfcurated -> registry / repo / tag
reg="${IMAGE%%/*}"
rest="${IMAGE#*/}"
case "${IMAGE}" in */*) ;; *) reg="registry-1.docker.io"; rest="library/${IMAGE}" ;; esac
tag="latest"
case "${rest}" in *:*) tag="${rest##*:}"; repo="${rest%:*}" ;; *) repo="${rest}" ;; esac
[ "${reg}" = "quay.io" ] || true
REG_HOST="${RF_REGISTRY:-${reg}}"

say() { printf '[rf-auth] %s\n' "$*"; }
die() { printf '[rf-auth] FAIL: %s\n' "$*" >&2; exit 1; }

say "registry : ${REG_HOST}"
say "repository: ${repo}"
say "tag       : ${tag}"
if [ -n "${USER_}" ]; then
  say "credentials: present (user ${USER_%%+*}+…)"   # never print the secret
else
  say "credentials: NONE in env — checking anonymous access only"
fi

# 1. Token. The Docker registry v2 flow: ask the realm for a pull-scoped token,
#    with basic auth if we have credentials.
realm="https://${REG_HOST}/v2/auth"
[ "${REG_HOST}" = "registry-1.docker.io" ] && realm="https://auth.docker.io/token"

auth_args=()
[ -n "${USER_}" ] && [ -n "${PASS_}" ] && auth_args=(-u "${USER_}:${PASS_}")

tok_body="$(curl -sS --max-time 30 "${auth_args[@]+"${auth_args[@]}"}" \
  "${realm}?service=${REG_HOST}&scope=repository:${repo}:pull" 2>&1)"
token="$(printf '%s' "${tok_body}" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("token") or "")
except Exception: print("")' 2>/dev/null)"

if [ -z "${token}" ]; then
  say "token response: $(printf '%s' "${tok_body}" | head -c 200)"
  die "could not obtain a pull token. If the credentials are RapidFort PLATFORM credentials (the RF_ROOT_URL/rflogin kind) rather than registry credentials, they will not work here — ask RapidFort for a registry service account (robot) for ${REG_HOST}."
fi
say "token     : obtained"

# 2. Manifest. 200 = we can pull it; 401/403 = token lacks scope; 404 = wrong
#    repo or tag.
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 \
  -H "Authorization: Bearer ${token}" \
  -H 'Accept: application/vnd.oci.image.index.v1+json' \
  -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
  -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
  "https://${REG_HOST}/v2/${repo}/manifests/${tag}")"

case "${code}" in
  200)
    say "manifest  : 200 OK"
    say "PASS — ${IMAGE} is pullable with these credentials."
    ;;
  401|403)
    [ -n "${USER_}" ] \
      && die "manifest ${code}: authenticated, but not authorised for ${repo}. The service account probably lacks read access to that namespace." \
      || die "manifest ${code}: this repository is private — credentials are required (none were set)."
    ;;
  404)
    die "manifest 404: authenticated, but ${repo}:${tag} does not exist. Check the namespace and whether the tag was withdrawn (curl the tags list to see what is offered)."
    ;;
  *)
    die "manifest ${code}: unexpected response from ${REG_HOST}."
    ;;
esac
