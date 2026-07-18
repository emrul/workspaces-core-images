#!/usr/bin/env bash
# sbom-attach-test.sh — THROWAWAY registry capability test (design/cve-scanning.md
# § 7 step 2 item 4). Exercises, against THIS project's GitLab registry using the
# job token, the full SBOM-as-OCI-artifact write path we intend to productionize:
#
#   push scratch image → cosign attach sbom → discover (tag fallback + cosign
#   tree) → download + content-compare → key-based sign (image + SBOM artifact,
#   --tlog-upload=false) → verify (--insecure-ignore-tlog) → enumerate tags
#
# Runs INSIDE the forge DinD (quay.io/podman/stable). Writes everything to a
# scratch repo ($REGISTRY_NS/sbom-spike) — NO app repos are touched. The signing
# keypair is generated fresh in-container and destroyed with it; nothing here is
# a production key or a production SBOM (contents are synthetic).
#
# Env: REG / REG_USER / REG_PASS   registry + job-token creds (from CI)
#      REGISTRY_NS                 e.g. registry.gitlab.com/.../kasm-nix
#      OUT_DIR                     report dir (default /artifacts)
#      HOST_UID / HOST_GID         chown the report back to the runner UID
#      COSIGN_VERSION              pinned cosign release (default v2.4.3)
#
# Remove this script + the sbom-attach-test job once the real SBOM pipeline lands.
set -euo pipefail

REG="${REG:?REG required}"
REG_USER="${REG_USER:?REG_USER required}"
REG_PASS="${REG_PASS:?REG_PASS required}"
REGISTRY_NS="${REGISTRY_NS:?REGISTRY_NS required}"
OUT_DIR="${OUT_DIR:-/artifacts}"
COSIGN_VERSION="${COSIGN_VERSION:-v2.4.3}"

REPO_PATH="${REGISTRY_NS#*/}/sbom-spike"          # <group>/.../kasm-nix/sbom-spike
REF="${REGISTRY_NS}/sbom-spike:test"
REPORT="${OUT_DIR}/sbom-attach-test.md"
mkdir -p "${OUT_DIR}"

PASS=(); FAIL=()
step() { echo "[sbom-attach-test] === $*"; }
ok()   { echo "[sbom-attach-test] OK   $*"; PASS+=("$*"); }
bad()  { echo "[sbom-attach-test] FAIL $*" >&2; FAIL+=("$*"); }

# ── deps: jq/curl (podman/stable ships neither jq nor skopeo), cosign ────────
command -v curl >/dev/null || dnf install -y --setopt=install_weak_deps=False curl >/dev/null
command -v jq   >/dev/null || dnf install -y --setopt=install_weak_deps=False jq   >/dev/null
arch="$(uname -m)"; case "${arch}" in x86_64) carch=amd64 ;; aarch64) carch=arm64 ;; *) echo "unsupported arch ${arch}" >&2; exit 1 ;; esac
step "fetch cosign ${COSIGN_VERSION} (${carch}, checksum-verified)"
curl -fsSLo /tmp/cosign        "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-${carch}"
curl -fsSLo /tmp/cosign.sums   "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign_checksums.txt"
(cd /tmp && grep " cosign-linux-${carch}\$" cosign.sums | sed 's/cosign-linux-'"${carch}"'/cosign/' | sha256sum -c -)
chmod +x /tmp/cosign; COSIGN=/tmp/cosign

# ── auth: one docker-style config served to podman AND cosign ────────────────
export DOCKER_CONFIG=/tmp/.docker
mkdir -p "${DOCKER_CONFIG}"
printf '{"auths":{"%s":{"auth":"%s"}}}\n' "${REG}" \
  "$(printf '%s:%s' "${REG_USER}" "${REG_PASS}" | base64 -w0)" > "${DOCKER_CONFIG}/config.json"
export REGISTRY_AUTH_FILE="${DOCKER_CONFIG}/config.json"

# ── 1. scratch image (synthetic content only) ────────────────────────────────
step "push scratch image ${REF}"
ctx="$(mktemp -d)"
echo "sbom-attach capability test — synthetic content, safe to delete" > "${ctx}/README"
printf 'FROM scratch\nCOPY README /README\n' > "${ctx}/Containerfile"
podman build -q -t "${REF}" -f "${ctx}/Containerfile" "${ctx}" >/dev/null
podman push --digestfile /tmp/digest "${REF}"
DIGEST="$(cat /tmp/digest)"; HEX="${DIGEST#sha256:}"
ok "pushed ${REF} @ ${DIGEST}"

# ── 2. synthetic CycloneDX SBOM + cosign attach ──────────────────────────────
step "attach SBOM"
cat > /tmp/sbom.cdx.json <<EOF
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "version": 1,
  "components": [
    { "type": "library", "name": "sbom-attach-capability-test", "version": "0.0.0",
      "purl": "pkg:generic/sbom-attach-capability-test@0.0.0" }
  ]
}
EOF
if "${COSIGN}" attach sbom --sbom /tmp/sbom.cdx.json --type cyclonedx "${REGISTRY_NS}/sbom-spike@${DIGEST}"; then
  ok "cosign attach sbom"
else bad "cosign attach sbom"; fi

# ── 3. discover: fallback tag exists? cosign tree sees it? ───────────────────
step "discover"
tok="$(curl -fsS -u "${REG_USER}:${REG_PASS}" \
  "https://gitlab.com/jwt/auth?service=container_registry&scope=repository:${REPO_PATH}:pull" | jq -r .token)"
if curl -fsS -o /dev/null -H "Authorization: Bearer ${tok}" \
     -H "Accept: application/vnd.oci.image.manifest.v1+json" \
     "https://${REG}/v2/${REPO_PATH}/manifests/sha256-${HEX}.sbom"; then
  ok "fallback tag sha256-${HEX}.sbom resolvable"
else bad "fallback tag not found"; fi
"${COSIGN}" tree "${REGISTRY_NS}/sbom-spike@${DIGEST}" || true

# ── 4. download + content round-trip ─────────────────────────────────────────
step "download + compare"
if "${COSIGN}" download sbom "${REGISTRY_NS}/sbom-spike@${DIGEST}" > /tmp/sbom.fetched.json \
   && jq -e '.components[0].name == "sbom-attach-capability-test"' /tmp/sbom.fetched.json >/dev/null; then
  ok "SBOM round-trip content matches"
else bad "SBOM round-trip mismatch"; fi

# ── 5. key-based sign (ephemeral key, NO public tlog) + verify ───────────────
step "sign + verify (key-based, --tlog-upload=false)"
export COSIGN_PASSWORD="$(head -c24 /dev/urandom | base64)"
(cd /tmp && "${COSIGN}" generate-key-pair)
if "${COSIGN}" sign --key /tmp/cosign.key --tlog-upload=false --yes "${REGISTRY_NS}/sbom-spike@${DIGEST}"; then
  ok "cosign sign (image)"
else bad "cosign sign (image)"; fi
# sign the SBOM artifact itself (tamper-evidence for scheme (a) in the design)
SBOM_DIG="$(curl -fsS -H "Authorization: Bearer ${tok}" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json" -o /dev/null -D - \
  "https://${REG}/v2/${REPO_PATH}/manifests/sha256-${HEX}.sbom" \
  | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}')"
if [ -n "${SBOM_DIG}" ] && "${COSIGN}" sign --key /tmp/cosign.key --tlog-upload=false --yes \
     "${REGISTRY_NS}/sbom-spike@${SBOM_DIG}"; then
  ok "cosign sign (SBOM artifact @ ${SBOM_DIG})"
else bad "cosign sign (SBOM artifact)"; fi
if "${COSIGN}" verify --key /tmp/cosign.pub --insecure-ignore-tlog=true \
     "${REGISTRY_NS}/sbom-spike@${DIGEST}" >/dev/null 2>&1; then
  ok "cosign verify (image, no tlog)"
else bad "cosign verify (image)"; fi
if [ -n "${SBOM_DIG}" ] && "${COSIGN}" verify --key /tmp/cosign.pub --insecure-ignore-tlog=true \
     "${REGISTRY_NS}/sbom-spike@${SBOM_DIG}" >/dev/null 2>&1; then
  ok "cosign verify (SBOM artifact, no tlog)"
else bad "cosign verify (SBOM artifact)"; fi

# ── 6. enumerate (the scheduled-re-scan discovery path) ──────────────────────
step "enumerate tags"
TAGS="$(curl -fsS -H "Authorization: Bearer ${tok}" "https://${REG}/v2/${REPO_PATH}/tags/list" | jq -r '.tags[]')"
echo "${TAGS}" | sed 's/^/[sbom-attach-test]   tag: /'
echo "${TAGS}" | grep -q "^sha256-${HEX}.sbom\$" && ok "enumeration finds .sbom tag" || bad "enumeration missing .sbom tag"

rm -f /tmp/cosign.key   # ephemeral; never leaves the container

# ── report ────────────────────────────────────────────────────────────────────
{
  echo "# sbom-attach-test — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "Target: \`${REF}\` @ \`${DIGEST}\` (scratch repo; synthetic content)"
  echo
  echo "| check | result |"; echo "|---|---|"
  for p in "${PASS[@]}"; do echo "| $p | ✅ |"; done
  for f in "${FAIL[@]}"; do echo "| $f | ❌ |"; done
  echo
  echo "Cleanup: delete the \`sbom-spike\` repo in the GitLab container-registry UI when done."
} > "${REPORT}"
[ -n "${HOST_UID:-}" ] && chown "${HOST_UID}:${HOST_GID:-$HOST_UID}" "${REPORT}" || true

echo "[sbom-attach-test] done: pass=${#PASS[@]} fail=${#FAIL[@]}"
[ "${#FAIL[@]}" -eq 0 ]
