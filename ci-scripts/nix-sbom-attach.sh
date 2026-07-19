#!/usr/bin/env bash
# nix-sbom-attach.sh — attest + sign SBOMs for the images THIS pipeline pushed.
# Build order step 4 (design/cve-scanning.md): the assurance surface end users
# can verify themselves:
#
#   cosign verify-attestation --key security/cosign.pub \
#     --insecure-ignore-tlog=true --type cyclonedx <ref> \
#     | jq -r '.payload' | base64 -d | jq '.predicate'   # the CycloneDX SBOM,
#                                                        #   verified + extracted
#   cosign verify --key security/cosign.pub \
#     --insecure-ignore-tlog=true <ref>                  # image signature
#
# Scheme (supersedes `cosign attach sbom`, 2026-07-19): the SBOM ships as an
# in-toto ATTESTATION (`cosign attest --type cyclonedx`) — a DSSE envelope
# that is signed by construction, stored under the registry tag-fallback
# `sha256-<digest>.att` (GitLab has no OCI referrers API; same discovery as
# the old `.sbom` tag). Attach was deprecated upstream (cosign #2755), needed
# THREE registry ops per image (attach + sign image + sign SBOM artifact) and
# returned unverified bytes on download; attest folds SBOM upload + signature
# into one op and verification into one command. `--replace` keeps re-runs
# (backfills) from accumulating stale attestations on the same tag.
#
# Flow: nix-build-report.json (publish artifact) → rows with action=="pushed"
# → for each, bounded-parallel (ATTEST_PARALLEL): pin the digest from the
# publish mapping's manifestDigest (fallback: resolve from the registry),
# `cosign attest` the CycloneDX SBOM (scan-nix artifact), `cosign sign` the
# image digest — both with --tlog-upload=false (no public Rekor).
#
# Report-only degradations are NOT allowed here: a pushed image we cannot
# attest/sign fails the job (the assurance layer must not silently thin out).
# A pushed image with NO SBOM from this run (content-compare pushed an image
# assembled in an earlier run) is recorded as `no-sbom` and warned — its SBOM
# lands on the next run that reassembles it. See § Env for inputs.
#
# Env: REG / REG_USER / REG_PASS   registry + job-token creds
#      COSIGN_PRIVATE_KEY          PEM (CI variable; used via env:// ref)
#      COSIGN_PASSWORD             key passphrase (CI variable)
#      OUT_DIR                     artifact dir with sboms/ + nix-build-report.json
#      COSIGN_VERSION              pinned release (default v2.4.3)
#      ATTEST_PARALLEL             concurrent attest workers (default 4)
#      HOST_UID / HOST_GID         chown report back to the runner UID
set -euo pipefail

REG="${REG:?}"; REG_USER="${REG_USER:?}"; REG_PASS="${REG_PASS:?}"
: "${COSIGN_PRIVATE_KEY:?COSIGN_PRIVATE_KEY CI variable missing}"
: "${COSIGN_PASSWORD:?COSIGN_PASSWORD CI variable missing}"
OUT_DIR="${OUT_DIR:-/artifacts}"
COSIGN_VERSION="${COSIGN_VERSION:-v2.4.3}"
ATTEST_PARALLEL="${ATTEST_PARALLEL:-4}"
REPORT="${OUT_DIR}/nix-build-report.json"
SBOM_DIR="${OUT_DIR}/sboms"

log() { printf '%s %s\n' "[nix-sbom-attach]" "$*" >&2; }

[ -f "${REPORT}" ] || { log "no nix-build-report.json — nothing was published"; exit 0; }

command -v curl >/dev/null || dnf install -y --setopt=install_weak_deps=False curl >/dev/null
command -v jq   >/dev/null || dnf install -y --setopt=install_weak_deps=False jq   >/dev/null

# SBOM_BACKFILL=1: also attest+sign images that were content-identical this run
# ("skipped" — already on the registry). One-off initial rollout / key-rotation
# mode: with a full-catalog scan (SCAN_ALL=1) this signs the whole catalog.
if [ "${SBOM_BACKFILL:-0}" = "1" ]; then
  sel='.action=="pushed" or .action=="skipped"'
  log "BACKFILL mode: covering pushed + already-published (skipped) images"
else
  sel='.action=="pushed"'
fi
# manifestDigest rides in from the publish mapping (nix-publish records it
# via podman push --digestfile / registry resolution) — attesting at THAT
# digest pins the exact artifact publish shipped, immune to the tag moving
# between publish and this job. Empty (older reports, docker fallback,
# backfill-skipped rows without one) → resolve from the registry below.
mapfile -t pushed < <(jq -r ".images[] | select(${sel}) | \"\(.profile)\t\(.dest)\t\(.manifestDigest // \"\")\"" "${REPORT}")
if [ "${#pushed[@]}" -eq 0 ]; then log "no images were pushed this run — nothing to attach"; exit 0; fi

# pinned cosign (checksum-verified)
arch="$(uname -m)"; case "${arch}" in x86_64) carch=amd64 ;; aarch64) carch=arm64 ;; *) log "unsupported arch"; exit 1 ;; esac
curl -fsSLo /tmp/cosign      "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-${carch}"
curl -fsSLo /tmp/cosign.sums "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign_checksums.txt"
(cd /tmp && grep " cosign-linux-${carch}\$" cosign.sums | sed "s/cosign-linux-${carch}/cosign/" | sha256sum -c - >/dev/null)
chmod +x /tmp/cosign; COSIGN=/tmp/cosign

export DOCKER_CONFIG=/tmp/.docker
mkdir -p "${DOCKER_CONFIG}"
printf '{"auths":{"%s":{"auth":"%s"}}}\n' "${REG}" \
  "$(printf '%s:%s' "${REG_USER}" "${REG_PASS}" | base64 -w0)" > "${DOCKER_CONFIG}/config.json"

digest_of() {  # $1=repo-path $2=ref(tag or sha256-…) → sha256:… on stdout
  local repo="$1" ref="$2" tok
  tok="$(curl -fsS -u "${REG_USER}:${REG_PASS}" \
    "https://gitlab.com/jwt/auth?service=container_registry&scope=repository:${repo}:pull" | jq -r .token)"
  curl -fsS -o /dev/null -D - \
    -H "Authorization: Bearer ${tok}" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
    "https://${REG}/v2/${repo}/manifests/${ref}" \
    | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}'
}

# ── attest + sign, bounded-parallel ─────────────────────────────────────────
# Workers never share state: each writes <profile>.{md,json,status} into
# WORKD; aggregation below the pool is single-threaded (same pattern as
# nix-scan-l3's per-app scan pool).
WORKD="$(mktemp -d)"
jrow() {  # $1=out-prefix $2=profile $3=ref $4=manifest-digest $5=att-digest $6=result
  jq -nc --arg p "$2" --arg r "$3" --arg d "$4" --arg a "$5" --arg res "$6" \
    '{profile:$p, ref:$r, manifest_digest:$d, attestation_digest:$a, result:$res}' > "$1.json"
}

attest_one() {  # $1=profile $2=dest $3=mapping-manifest-digest
  local profile="$1" dest="$2" rep_dig="$3"
  local out="${WORKD}/${profile}"
  local repo_path="${dest#*/}"; repo_path="${repo_path%:*}"   # strip host + tag
  local repo_ref="${dest%:*}"                                 # host/path (no tag)
  local tag="${dest##*:}"
  local sbom_gz="${SBOM_DIR}/${profile}.cdx.json.gz"
  if [ ! -f "${sbom_gz}" ]; then
    log "WARN ${profile}: pushed but no SBOM artifact from this run (assembled earlier?) — skipping"
    printf 'no-sbom' > "${out}.status"
    printf '| %s | — | no-sbom |\n' "${profile}" > "${out}.md"
    jrow "${out}" "${profile}" "${dest}" "${rep_dig}" "" "no-sbom"
    return 0
  fi
  gunzip -kf "${sbom_gz}"; local sbom="${sbom_gz%.gz}"
  local dig="${rep_dig:-$(digest_of "${repo_path}" "${tag}")}"
  if [ -z "${dig}" ]; then
    log "ERROR ${profile}: cannot resolve digest for ${dest}"
    printf 'failed' > "${out}.status"
    jrow "${out}" "${profile}" "${dest}" "" "" "no-digest"
    return 0
  fi
  log "${profile}: attest+sign @ ${dig}"
  if ! "${COSIGN}" attest --key env://COSIGN_PRIVATE_KEY --tlog-upload=false --yes \
         --replace --type cyclonedx --predicate "${sbom}" "${repo_ref}@${dig}"; then
    log "ERROR ${profile}: cosign attest failed"
    printf 'failed' > "${out}.status"
    jrow "${out}" "${profile}" "${dest}" "${dig}" "" "attest-failed"
    rm -f "${sbom}"; return 0
  fi
  if ! "${COSIGN}" sign --key env://COSIGN_PRIVATE_KEY --tlog-upload=false --yes "${repo_ref}@${dig}"; then
    log "ERROR ${profile}: cosign sign failed"
    printf 'failed' > "${out}.status"
    jrow "${out}" "${profile}" "${dest}" "${dig}" "" "sign-failed"
    rm -f "${sbom}"; return 0
  fi
  local hex="${dig#sha256:}"
  local att_dig; att_dig="$(digest_of "${repo_path}" "sha256-${hex}.att" || true)"
  printf 'ok' > "${out}.status"
  printf '| %s | `%s` | attested+signed |\n' "${profile}" "${dig}" > "${out}.md"
  jrow "${out}" "${profile}" "${dest}" "${dig}" "${att_dig}" "attested+signed"
  rm -f "${sbom}"
}

for entry in "${pushed[@]}"; do
  IFS=$'\t' read -r profile dest rep_dig <<<"${entry}"
  while [ "$(jobs -rp | wc -l)" -ge "${ATTEST_PARALLEL}" ]; do
    if ! wait -n; then :; fi     # collect one; failures detected via status files
  done
  attest_one "${profile}" "${dest}" "${rep_dig}" &
done
wait || true

# ── aggregate worker results (single-threaded from here) ────────────────────
failed=(); nosbom=()
for entry in "${pushed[@]}"; do
  profile="${entry%%$'\t'*}"
  case "$(cat "${WORKD}/${profile}.status" 2>/dev/null || echo failed)" in
    ok) ;;
    no-sbom) nosbom+=("${profile}") ;;
    *) failed+=("${profile}") ;;
  esac
done

{
  echo "# SBOM attest + sign — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "Verify + extract: \`cosign verify-attestation --key security/cosign.pub --insecure-ignore-tlog=true --type cyclonedx <ref> | jq -r '.payload' | base64 -d | jq '.predicate'\`"
  echo "Image signature:  \`cosign verify --key security/cosign.pub --insecure-ignore-tlog=true <ref>\`"
  echo
  echo "| image | digest | result |"; echo "|---|---|---|"
  for entry in "${pushed[@]}"; do
    profile="${entry%%$'\t'*}"
    cat "${WORKD}/${profile}.md" 2>/dev/null || true
  done
  if [ "${#failed[@]}" -gt 0 ]; then echo; echo "**FAILED:** ${failed[*]}"; fi
} > "${OUT_DIR}/sbom-attach-report.md"

# Machine-readable companion (design review round 5): the per-image
# {profile, ref, manifest_digest, attestation_digest, result} mapping
# consumers join against — the Markdown above is for humans only.
jq -s --arg sha "${CI_COMMIT_SHA:-}" --arg pipeline "${CI_PIPELINE_ID:-}" --arg job "${CI_JOB_ID:-}" \
  '{source_commit:$sha, pipeline_id:$pipeline, job_id:$job, images:.}' \
  "${WORKD}"/*.json > "${OUT_DIR}/sbom-attach-report.json"
rm -rf "${WORKD}"
[ -n "${HOST_UID:-}" ] && chown "${HOST_UID}:${HOST_GID:-$HOST_UID}" \
  "${OUT_DIR}/sbom-attach-report.md" "${OUT_DIR}/sbom-attach-report.json" 2>/dev/null || true

log "done: attested=$(( ${#pushed[@]} - ${#failed[@]} - ${#nosbom[@]} )) no-sbom=${#nosbom[@]} failed=${#failed[@]} ${failed[*]:-}"
[ "${#failed[@]}" -eq 0 ]
