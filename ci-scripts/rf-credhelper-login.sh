#!/usr/bin/env bash
# rf-credhelper-login.sh — log podman in to the RapidFort registry using RF's
# Docker credential helper. Runs INSIDE the DIND container.
#
# WHY A HELPER AND NOT A PLAIN LOGIN. RapidFort does not issue a static registry
# credential. The account it hands out (RF_ACCESS_ID/RF_SECRET_ACCESS_KEY, with
# RF_ROOT_URL) is a *platform* account — quay rejects it outright ("Invalid
# Username or Password"). What actually authenticates is a quay robot token that
# RapidFort's helper mints on demand:
#
#   platform creds ──▶ docker-credential-rfcurated get ──▶ {rfcurated+<org>, token}
#                                                            expires_in: 3600
#
# One hour. So the token cannot be a CI variable either — it has to be minted per
# job, which is what this script does.
#
# We call the helper's `get` ourselves and pipe the result into `podman login`,
# rather than registering it as a `credHelpers` entry: the exchange then happens
# once, at a known point, with our own error messages, instead of implicitly on
# first pull inside whatever command happens to need it.
#
# Env (from MASKED, PROTECTED CI variables):
#   RF_ROOT_URL             RapidFort platform URL (https://…)
#   RF_ACCESS_ID            platform access id
#   RF_SECRET_ACCESS_KEY    platform secret
#   RF_REGISTRY             registry to log in to        (default quay.io)
#   RF_CRED_HELPER          path to the helper binary
#                           (default /work/.rf/docker-credential-rfcurated)
set -euo pipefail

REG="${RF_REGISTRY:-quay.io}"
# podman under DinD, docker on a docker-only host.
CONTAINER_CLI="${CONTAINER_CLI:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}"
# ${KASM_REPO}, not a literal /work: under DinD that IS /work, and on a host
# run it is the checkout. A hardcoded /work here failed the first host-run
# pipeline (2755399951) with "credential helper not found".
HELPER="${RF_CRED_HELPER:-${KASM_REPO:-/work}/.rf/docker-credential-rfcurated}"
export REGISTRY_AUTH_FILE="${REGISTRY_AUTH_FILE:-/tmp/kasm-nix-auth.json}"

log() { printf '[rf-login] %s\n' "$*" >&2; }
die() { printf '[rf-login] ERROR: %s\n' "$*" >&2; exit 1; }

[ -x "${HELPER}" ] || die "credential helper not found or not executable: ${HELPER} (fetch it with ci-scripts/rf-fetch-credhelper.sh)"
[ -n "${RF_ROOT_URL:-}" ] || die "RF_ROOT_URL is empty — set it as a CI variable (the helper refuses to run without it)"
[ -n "${RF_ACCESS_ID:-}" ] && [ -n "${RF_SECRET_ACCESS_KEY:-}" ] \
  || die "RF_ACCESS_ID / RF_SECRET_ACCESS_KEY are empty — set them as MASKED, PROTECTED CI variables"

export RF_ROOT_URL RF_ACCESS_ID RF_SECRET_ACCESS_KEY

# The helper inspects PATH for a container runtime and REFUSES to run if it finds
# more than one: "ERROR: Both Docker and Podman are available in PATH." The DIND
# builder is podman-only so this never fires there, but it does on a developer box
# with both installed — and the failure otherwise surfaces as a generic "could not
# mint a token", which sends you looking at your credentials instead.
if command -v docker >/dev/null 2>&1 && command -v podman >/dev/null 2>&1; then
  die "RapidFort's credential helper refuses to run with BOTH docker and podman on PATH. Re-run with a PATH that exposes only one (whichever CONTAINER_CLI resolves to)."
fi

# The helper reads env, but also looks for ~/.rapidfort/credentials. Write it too:
# verified working from env alone, and this costs nothing if it goes unread. Lives
# in the EPHEMERAL container's HOME — it must never be written into /work (the
# repo) or into the persistent store.
creds_dir="${HOME:-/root}/.rapidfort"
mkdir -p "${creds_dir}"
chmod 700 "${creds_dir}"
umask 077
cat > "${creds_dir}/credentials" <<EOF
[rapidfort-user]
rf_root_url=${RF_ROOT_URL}
access_id=${RF_ACCESS_ID}
secret_key=${RF_SECRET_ACCESS_KEY}
EOF

log "minting a registry token for ${REG} via ${HELPER##*/}"
# stderr is dropped: the helper is chatty and its diagnostics have no reason to
# quote a credential into a CI log. On failure we re-run it with stderr shown.
if ! out="$(printf '%s' "${REG}" | "${HELPER}" get 2>/dev/null)"; then
  log "helper failed; re-running with its diagnostics visible:"
  printf '%s' "${REG}" | "${HELPER}" get >/dev/null || true
  die "credential helper could not mint a token for ${REG} (platform creds rejected, or ${RF_ROOT_URL} unreachable)"
fi

user="$(printf '%s' "${out}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("Username",""))' 2>/dev/null || true)"
secret="$(printf '%s' "${out}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("Secret",""))' 2>/dev/null || true)"
[ -n "${user}" ] && [ -n "${secret}" ] || die "helper returned no usable credential for ${REG}"

printf '%s' "${secret}" | "${CONTAINER_CLI}" login "${REG}" -u "${user}" --password-stdin >/dev/null \
  || die "${CONTAINER_CLI} login ${REG} failed with the minted token"

# The minted token is short-lived (RF issues ~3600s). Fine for a base build: the
# source-image pull happens in the first minute. If a later stage ever needs the
# RF registry again, re-run this script rather than assuming the login still holds.
log "authenticated to ${REG} as ${user} (token is short-lived — re-run if a later stage needs it)"
