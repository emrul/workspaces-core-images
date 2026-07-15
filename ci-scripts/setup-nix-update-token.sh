#!/usr/bin/env bash
# setup-nix-update-token.sh — provision the NIX_UPDATE_TOKEN CI variable.
#
# Creates a scoped PROJECT access token and stores it as the masked CI variable
# the scheduled `nix-update` job uses to push its pin-bump audit commits (so the
# repo reflects what shipped). One-off operator setup; safe to re-run (rotates).
#
# Least privilege: the token's only scope is write_repository. Role defaults to
# Maintainer (40) because the target branch (kasm-nix) is protected to
# Maintainers — a Developer token could not push. Drop to --role 30 if your
# target branch is unprotected. The token has an expiry (rotation) and is piped
# straight into the CI variable via stdin — it is NEVER printed or placed in the
# process list. See design/nix-self-hosted-packages.md.
#
# Requires: glab (authenticated as a project Owner/Maintainer), jq.
#
# Usage:
#   ci-scripts/setup-nix-update-token.sh [-R group/project] [--role N]
#                                        [--expires YYYY-MM-DD] [--name NAME]
set -euo pipefail

PROJECT="kasm-technologies/labs-sandbox/kasm-nix"
VAR="NIX_UPDATE_TOKEN"
TOKEN_NAME="nix-update-bot"
ROLE=40                 # Maintainer (kasm-nix is Maintainer-protected). 30=Developer.
EXPIRES=""

while [ $# -gt 0 ]; do
  case "$1" in
    -R|--repo)  PROJECT="$2"; shift 2 ;;
    --role)     ROLE="$2"; shift 2 ;;
    --expires)  EXPIRES="$2"; shift 2 ;;
    --name)     TOKEN_NAME="$2"; shift 2 ;;
    -h|--help)  sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v glab >/dev/null || { echo "FATAL: glab not found" >&2; exit 1; }
command -v jq   >/dev/null || { echo "FATAL: jq not found"   >&2; exit 1; }

# GitLab requires an expiry (SaaS caps at ~365 days). Default ~1 year out.
[ -n "$EXPIRES" ] || EXPIRES="$(date -u -d '+1 year' +%F 2>/dev/null || date -u -v+1y +%F)"

ENC="$(printf '%s' "$PROJECT" | jq -sRr @uri)"

echo "[setup] project:  $PROJECT"
echo "[setup] token:    $TOKEN_NAME  (scope=write_repository, access_level=$ROLE, expires=$EXPIRES)"
echo "[setup] variable: $VAR (masked)"

# 0. Revoke any prior active token of the same name — clean rotation, no strays.
for old in $(glab api "projects/${ENC}/access_tokens" 2>/dev/null \
              | jq -r --arg n "$TOKEN_NAME" '.[]? | select(.name==$n and .active==true) | .id'); do
  glab api --method DELETE "projects/${ENC}/access_tokens/${old}" >/dev/null 2>&1 \
    && echo "[setup] revoked prior token id=${old}"
done

# 1. Create the project access token; capture the response but never print .token.
#    Send a JSON body so `scopes` is a real array (glab's scopes[]= form is not
#    parsed as an array by the API) and access_level is a number.
body="$(jq -n --arg n "$TOKEN_NAME" --argjson r "$ROLE" --arg e "$EXPIRES" \
          '{name:$n, scopes:["write_repository"], access_level:$r, expires_at:$e}')"
resp="$(printf '%s' "$body" | glab api --method POST "projects/${ENC}/access_tokens" \
          --header "Content-Type: application/json" --input -)" \
  || { echo "FATAL: token creation failed — need Owner/Maintainer on $PROJECT (and a tier that allows project access tokens)." >&2; exit 1; }

token="$(printf '%s' "$resp" | jq -r '.token // empty')"
tid="$(printf '%s'   "$resp" | jq -r '.id // empty')"
if [ -z "$token" ]; then
  echo "FATAL: no token in API response:" >&2
  printf '%s\n' "$resp" | jq 'del(.token)' >&2 2>/dev/null || true
  exit 1
fi
echo "[setup] created project access token id=${tid}"

# 2. Store as a masked + protected CI variable. Delete-then-set so a re-run
#    rotates cleanly and the value always arrives via stdin (never in argv /
#    shell history). Protected = exposed only to pipelines on protected refs;
#    the scheduled nix-update runs on kasm-nix (protected), so this withholds the
#    push token from any unprotected branch/MR pipeline (least privilege). If you
#    run nix-update on an UNPROTECTED ref, drop --protected or that ref won't see it.
glab variable delete "$VAR" -R "$PROJECT" >/dev/null 2>&1 || true
printf '%s' "$token" | glab variable set "$VAR" -R "$PROJECT" --masked --protected --scope '*' \
  --description "Push token for the scheduled nix-update audit commit (expires ${EXPIRES})"
echo "[setup] stored CI variable $VAR"

# 3. Scrub + confirm without revealing the value.
unset token resp
echo "[setup] verifying (value hidden):"
glab variable list -R "$PROJECT" | awk 'NR==1 || $1=="'"$VAR"'"'
echo "[setup] done. Token expires ${EXPIRES} — re-run to rotate before then."
echo "[setup] To revoke: glab api --method DELETE projects/${ENC}/access_tokens/${tid}"
