#!/usr/bin/env bash
# nix-sbom-attach.sh — attach + sign SBOMs for the images THIS pipeline pushed.
# Build order step 4 (design/cve-scanning.md): the assurance surface end users
# can verify themselves:
#
#   cosign download sbom <ref>                       # the attached syft-json
#   cosign verify --key cosign.pub \
#     --insecure-ignore-tlog=true <ref>              # key-based, no public tlog
#
# Flow (proven by the sbom-attach-test capability job, 2026-07-18):
#   nix-build-report.json (publish artifact) → rows with action=="pushed"
#   → for each: resolve the REGISTRY digest, `cosign attach sbom` the canonical
#   syft-json (scan-nix artifact), then key-sign BOTH the image digest and the
#   SBOM artifact digest with --tlog-upload=false (no public Rekor).
#
# Report-only degradations are NOT allowed here: a pushed image we cannot
# attach/sign fails the job (the assurance layer must not silently thin out).
# A pushed image with NO SBOM from this run (content-compare pushed an image
# assembled in an earlier run) is recorded as `no-sbom` and warned — its SBOM
# lands on the next run that reassembles it. See § Env for inputs.
#
# Env: REG / REG_USER / REG_PASS   registry + job-token creds
#      COSIGN_PRIVATE_KEY          PEM (CI variable; used via env:// ref)
#      COSIGN_PASSWORD             key passphrase (CI variable)
#      OUT_DIR                     artifact dir with sboms/ + nix-build-report.json
#      COSIGN_VERSION              pinned release (default v2.4.3)
#      HOST_UID / HOST_GID         chown report back to the runner UID
set -euo pipefail

REG="${REG:?}"; REG_USER="${REG_USER:?}"; REG_PASS="${REG_PASS:?}"
: "${COSIGN_PRIVATE_KEY:?COSIGN_PRIVATE_KEY CI variable missing}"
: "${COSIGN_PASSWORD:?COSIGN_PASSWORD CI variable missing}"
OUT_DIR="${OUT_DIR:-/artifacts}"
COSIGN_VERSION="${COSIGN_VERSION:-v2.4.3}"
REPORT="${OUT_DIR}/nix-build-report.json"
SBOM_DIR="${OUT_DIR}/sboms"

log() { printf '%s %s\n' "[nix-sbom-attach]" "$*" >&2; }

[ -f "${REPORT}" ] || { log "no nix-build-report.json — nothing was published"; exit 0; }

command -v curl >/dev/null || dnf install -y --setopt=install_weak_deps=False curl >/dev/null
command -v jq   >/dev/null || dnf install -y --setopt=install_weak_deps=False jq   >/dev/null

# SBOM_BACKFILL=1: also attach+sign images that were content-identical this run
# ("skipped" — already on the registry). One-off initial rollout / key-rotation
# mode: with a full-catalog scan (SCAN_ALL=1) this signs the whole catalog.
if [ "${SBOM_BACKFILL:-0}" = "1" ]; then
  sel='.action=="pushed" or .action=="skipped"'
  log "BACKFILL mode: covering pushed + already-published (skipped) images"
else
  sel='.action=="pushed"'
fi
# manifestDigest rides in from the publish mapping (nix-publish records it
# via podman push --digestfile / registry resolution) — attaching to THAT
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

rows=(); failed=(); nosbom=()
JROWS="$(mktemp)"; : > "${JROWS}"
jrow() {  # $1=profile $2=ref $3=manifest-digest $4=sbom-digest $5=result
  jq -nc --arg p "$1" --arg r "$2" --arg d "$3" --arg s "$4" --arg res "$5" \
    '{profile:$p, ref:$r, manifest_digest:$d, sbom_digest:$s, result:$res}' >> "${JROWS}"
}
for entry in "${pushed[@]}"; do
  IFS=$'\t' read -r profile dest rep_dig <<<"${entry}"
  repo_path="${dest#*/}"; repo_path="${repo_path%:*}"          # strip host + tag
  repo_ref="${dest%:*}"                                        # host/path (no tag)
  tag="${dest##*:}"
  sbom_gz="${SBOM_DIR}/${profile}.syft.json.gz"
  if [ ! -f "${sbom_gz}" ]; then
    log "WARN ${profile}: pushed but no SBOM artifact from this run (assembled earlier?) — skipping"
    nosbom+=("${profile}"); rows+=("| ${profile} | — | no-sbom |")
    jrow "${profile}" "${dest}" "${rep_dig}" "" "no-sbom"
    continue
  fi
  gunzip -kf "${sbom_gz}"; sbom="${sbom_gz%.gz}"
  dig="${rep_dig:-$(digest_of "${repo_path}" "${tag}")}"
  if [ -z "${dig}" ]; then
    log "ERROR ${profile}: cannot resolve digest for ${dest}"; failed+=("${profile}")
    jrow "${profile}" "${dest}" "" "" "no-digest"; continue
  fi
  log "${profile}: attach+sign @ ${dig}"
  if ! "${COSIGN}" attach sbom --sbom "${sbom}" --type syft "${repo_ref}@${dig}"; then
    log "ERROR ${profile}: cosign attach failed"; failed+=("${profile}")
    jrow "${profile}" "${dest}" "${dig}" "" "attach-failed"; continue
  fi
  hex="${dig#sha256:}"
  sbom_dig="$(digest_of "${repo_path}" "sha256-${hex}.sbom")"
  ok=1
  "${COSIGN}" sign --key env://COSIGN_PRIVATE_KEY --tlog-upload=false --yes "${repo_ref}@${dig}" || ok=0
  [ -n "${sbom_dig}" ] && { "${COSIGN}" sign --key env://COSIGN_PRIVATE_KEY --tlog-upload=false --yes "${repo_ref}@${sbom_dig}" || ok=0; }
  if [ "${ok}" = 1 ]; then
    rows+=("| ${profile} | \`${dig}\` | attached+signed |")
    jrow "${profile}" "${dest}" "${dig}" "${sbom_dig}" "attached+signed"
  else
    log "ERROR ${profile}: cosign sign failed"; failed+=("${profile}")
    jrow "${profile}" "${dest}" "${dig}" "${sbom_dig}" "sign-failed"
  fi
  rm -f "${sbom}"
done

{
  echo "# SBOM attach + sign — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "Verify: \`cosign verify --key security/cosign.pub --insecure-ignore-tlog=true <ref>\`"
  echo "SBOM:   \`cosign download sbom <ref>\`"
  echo
  echo "| image | digest | result |"; echo "|---|---|---|"
  for r in "${rows[@]}"; do echo "${r}"; done
  if [ "${#failed[@]}" -gt 0 ]; then echo; echo "**FAILED:** ${failed[*]}"; fi
} > "${OUT_DIR}/sbom-attach-report.md"

# Machine-readable companion (design review round 5): the per-image
# {profile, ref, manifest_digest, sbom_digest, result} mapping consumers
# join against — the Markdown above is for humans only.
jq -s --arg sha "${CI_COMMIT_SHA:-}" --arg pipeline "${CI_PIPELINE_ID:-}" --arg job "${CI_JOB_ID:-}" \
  '{source_commit:$sha, pipeline_id:$pipeline, job_id:$job, images:.}' \
  "${JROWS}" > "${OUT_DIR}/sbom-attach-report.json"
rm -f "${JROWS}"
[ -n "${HOST_UID:-}" ] && chown "${HOST_UID}:${HOST_GID:-$HOST_UID}" \
  "${OUT_DIR}/sbom-attach-report.md" "${OUT_DIR}/sbom-attach-report.json" 2>/dev/null || true

log "done: attached=$(( ${#pushed[@]} - ${#failed[@]} - ${#nosbom[@]} )) no-sbom=${#nosbom[@]} failed=${#failed[@]} ${failed[*]:-}"
[ "${#failed[@]}" -eq 0 ]
