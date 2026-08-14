#!/usr/bin/env bash
# sbom-signing-demo.sh — guided walkthrough of the kasm-nix assurance layer:
# what we publish alongside every image, how a consumer verifies it, what an
# SBOM actually contains, and what a signature does and does not prove.
#
# This is the CONSUMER side. It runs on public information plus a registry
# PULL credential, touches no signing key, and mutates nothing in the
# registry. The producer side lives in ci-scripts/nix-sbom-attach.sh (cosign
# attest + cosign sign) and ci-scripts/nix-scan-l3.sh (syft → grype).
#
# Acts:
#   1  preflight — tools, public key, registry credential
#   2  what is published — image digest + .sig / .att sidecar tags
#   3  verify the image signature (with two negative controls)
#   4  verify the attestation and extract the SBOM
#   5  read the SBOM — inventory, Nix store paths, provenance labels
#   6  use the SBOM — scan it yourself with grype, then apply our VEX
#   7  what this proves, what it does not
#
# Requirements: cosign (v2.x), curl, jq, base64. grype only for act 6.
#
# Credentials — a read_registry deploy token for the private sandbox registry:
#   export REG_USER='gitlab+deploy-token-NNNNNNNN' REG_PASS='<secret>'
# A GitLab username + personal access token with read_registry also works. The
# script writes a throwaway DOCKER_CONFIG inside its own work dir, so
# ~/.docker/config.json is never touched. If you are already logged in to the
# registry, pass --use-docker-login instead (acts that call the registry API
# directly are then skipped).
set -euo pipefail

usage() {
  cat <<'EOF'
usage: sbom-signing-demo.sh [options]

  --app NAME            image to walk through (default: chrome)
  --tag TAG             tag to verify (default: nix)
  --from N              start at act N (1-7)
  --only N              run only act N
  --no-pause            do not wait for Enter between acts
  --keep                keep the work dir (SBOM, envelope, scan output)
  --work DIR            use DIR as the work dir
  --use-docker-login    use your existing docker/podman login instead of
                        REG_USER / REG_PASS
  -h, --help            this help

env: REG_USER, REG_PASS (read_registry deploy token) — see header comment.
EOF
  exit "${1:-0}"
}

# ── configuration ────────────────────────────────────────────────────────────
REG="${REG:-registry.gitlab.com}"
NS="${NS:-kasm-technologies/labs-sandbox/kasm-nix}"
APP="${APP:-chrome}"
TAG="${TAG:-nix}"
# An image in the same registry that never went through the publish pipeline —
# used as a negative control in act 3.
#
# chrome-rf-poc was the RapidFort hardened-base spike. Its workspace has been
# retired from the registry catalogue and it has no build path (no nix profile,
# no CI job), but the pushed image is deliberately KEPT in the container registry
# because this demo needs something unsigned to fail against. Do not garbage-
# collect it without pointing UNSIGNED_APP at another never-published image.
UNSIGNED_APP="${UNSIGNED_APP:-chrome-rf-poc}"
KEY_URL="${KEY_URL:-https://kasm-nix-registry.emrul.dev/1.1/cosign.pub}"
SECURITY_PAGE="https://kasm-nix-registry.emrul.dev/1.1/security"
WORK="${WORK:-}"
PAUSE=1; KEEP=0; USE_DOCKER_LOGIN=0; FROM=1; ONLY=""
ACCEPT_MANIFESTS='application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json'

while [ $# -gt 0 ]; do
  case "$1" in
    --app)   APP="${2:?}"; shift 2 ;;
    --tag)   TAG="${2:?}"; shift 2 ;;
    --work)  WORK="${2:?}"; shift 2 ;;
    --from)  FROM="${2:?}"; shift 2 ;;
    --only)  ONLY="${2:?}"; shift 2 ;;
    --no-pause) PAUSE=0; shift ;;
    --keep)  KEEP=1; shift ;;
    --use-docker-login) USE_DOCKER_LOGIN=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

REPO_PATH="${NS}/${APP}"            # registry path, no host
REF="${REG}/${REPO_PATH}:${TAG}"    # what a user would docker pull

# ── presentation helpers ─────────────────────────────────────────────────────
if [ -t 1 ]; then B=$'\033[1m'; D=$'\033[2m'; C=$'\033[36m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else B=""; D=""; C=""; G=""; Y=""; R=""; N=""; fi
HR="════════════════════════════════════════════════════════════════════════"

act()  { printf '\n%s%s\n ACT %s — %s\n%s%s\n' "${B}" "${HR}" "$1" "$2" "${HR}" "${N}"; }
say()  { printf '%s\n' "$*" | fold -s -w 76 | sed 's/^/  /'; }        # plain text only
bul()  { printf '%s\n' "$*" | fold -s -w 70 | sed '1s/^/  • /;1!s/^/    /'; }
note() { printf '%s\n' "$*" | fold -s -w 74 | sed "s/^/  ${D}· /;s/\$/${N}/"; }
gap()  { printf '\n'; }
ok()   { printf '  %s✔%s %s\n' "${G}" "${N}" "$*"; }
warn() { printf '  %s!%s %s\n' "${Y}" "${N}" "$*"; }
bad()  { printf '  %s✘%s %s\n' "${R}" "${N}" "$*"; }
cmd()  { printf '\n  %s$ %s%s\n' "${C}" "$*" "${N}"; }               # echo only
# show() prints a shell one-liner verbatim, then runs it — for steps whose
# teaching value IS the pipeline (jq chains, base64 -d, cosign flags).
show() { cmd "$1"; bash -c "$1"; }
pause() {
  [ "${PAUSE}" = 1 ] || return 0
  [ -r /dev/tty ] || return 0
  printf '\n  %s— press Enter to continue —%s' "${D}" "${N}"; read -r _ </dev/tty || true; printf '\n'
}
skipping() {
  if [ -n "${ONLY}" ]; then [ "${ONLY}" != "$1" ]; return; fi
  [ "$1" -lt "${FROM}" ]
}
die()  { bad "$*"; exit 1; }

# ── work dir ─────────────────────────────────────────────────────────────────
REPO_ROOT="$(git -C "$(cd "$(dirname "$0")" && pwd)" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "${WORK}" ] || WORK="$(mktemp -d "${TMPDIR:-/tmp}/sbom-demo.XXXXXX")"
mkdir -p "${WORK}"; WORK="$(cd "${WORK}" && pwd)"
cleanup() { cd /; [ "${KEEP}" = 1 ] || rm -rf "${WORK}"; }
trap cleanup EXIT
export DOCKER_CONFIG="${WORK}/.docker"
mkdir -p "${DOCKER_CONFIG}"
# Everything below runs inside the work dir, so the commands we echo are short
# and copy-pasteable rather than carrying a mktemp path.
cd "${WORK}"

KEY="cosign.pub"
SBOM="${APP}.cdx.json"
STMT="${APP}.statement.json"
ENVELOPE="${APP}.dsse.json"
DIGEST=""
HAVE_REG_API=0

fetch_key() { curl -fsS -o "${KEY}" "${KEY_URL}" 2>/dev/null \
  || { [ -n "${REPO_ROOT}" ] && cp "${REPO_ROOT}/security/cosign.pub" "${KEY}"; }; }

# Credential setup runs for every act, not just act 1, so --only/--from work
# standalone. Act 1 narrates it; other entry points call it quietly.
setup_auth() {
  if [ "${USE_DOCKER_LOGIN}" = 1 ]; then
    unset DOCKER_CONFIG
    return 1
  elif [ -n "${REG_USER:-}" ] && [ -n "${REG_PASS:-}" ]; then
    printf '{"auths":{"%s":{"auth":"%s"}}}\n' "${REG}" \
      "$(printf '%s:%s' "${REG_USER}" "${REG_PASS}" | base64 | tr -d '\n')" > "${DOCKER_CONFIG}/config.json"
    chmod 600 "${DOCKER_CONFIG}/config.json"
    reg_token "${REPO_PATH}" >/dev/null 2>&1 || return 2
    HAVE_REG_API=1
    return 0
  fi
  return 3
}

# ── registry helpers (GitLab's token endpoint; other registries differ) ──────
_tok=""
reg_token() {
  if [ -z "${_tok}" ]; then
    _tok="$(curl -fsS -u "${REG_USER:-}:${REG_PASS:-}" \
      "https://gitlab.com/jwt/auth?service=container_registry&scope=repository:${1}:pull" \
      | jq -r '.token')" || return 1
    { [ -n "${_tok}" ] && [ "${_tok}" != "null" ]; } || { _tok=""; return 1; }
  fi
  printf '%s' "${_tok}"
}
reg_get() {  # $1=repo $2=path under /v2/<repo>/
  local t; t="$(reg_token "$1")"
  curl -fsS -L -H "Authorization: Bearer ${t}" -H "Accept: ${ACCEPT_MANIFESTS}" \
    "https://${REG}/v2/${1}/$2"
}
reg_digest() {  # $1=repo $2=tag or sha256-….att ; prints sha256:…
  local t; t="$(reg_token "$1")"
  curl -fsS -o /dev/null -D - -H "Authorization: Bearer ${t}" -H "Accept: ${ACCEPT_MANIFESTS}" \
    "https://${REG}/v2/${1}/manifests/$2" | tr -d '\r' \
    | awk 'tolower($1)=="docker-content-digest:"{print $2}'
}
# Acts can be run standalone (--only N); make sure the digest is known either
# way — from the registry if we can talk to it, else from cosign's own output.
ensure_digest() {
  [ -n "${DIGEST}" ] && return 0
  [ -f "${KEY}" ] || fetch_key
  if [ "${HAVE_REG_API}" = 1 ]; then DIGEST="$(reg_digest "${REPO_PATH}" "${TAG}")"; fi
  if [ -z "${DIGEST}" ]; then
    DIGEST="$(cosign verify --key "${KEY}" --insecure-ignore-tlog=true "${REF}" 2>/dev/null \
      | jq -rs 'flatten | .[0].critical.image."docker-manifest-digest"' 2>/dev/null || true)"
  fi
  [ -n "${DIGEST}" ] && [ "${DIGEST}" != "null" ] || die "could not resolve a digest for ${REF}"
}

if skipping 1; then   # entering mid-walkthrough: set up quietly
  set +e; setup_auth; auth_rc=$?; set -e
  case "${auth_rc}" in
    2) die "credential rejected by ${REG} — check REG_USER / REG_PASS" ;;
    3) die "set REG_USER and REG_PASS (read_registry deploy token), or pass --use-docker-login" ;;
  esac
  fetch_key
fi

# ═══════════════════════════════════════════════════════════════════════════
# ACT 1 — preflight
# ═══════════════════════════════════════════════════════════════════════════
if ! skipping 1; then
act 1 "Preflight — the three things a verifier needs"
say "Verifying a kasm-nix image takes exactly three inputs: the cosign binary, our public key, and a registry pull credential. No access to our CI, no trust in this script."
command -v cosign >/dev/null || die "cosign not found — install from github.com/sigstore/cosign (CI pins v2.4.3)"
command -v jq     >/dev/null || die "jq not found"
command -v curl   >/dev/null || die "curl not found"
show "cosign version --json | jq -r '\"  cosign \" + .gitVersion'"

gap
say "The public key is served from the registry's security page — the same page that publishes scan results. For a third party that URL, not this git repo, is the authoritative source."
fetch_key
[ -s "${KEY}" ] || die "no public key available (tried ${KEY_URL} and security/cosign.pub)"
show "cat ${KEY}"
if [ -n "${REPO_ROOT}" ] && [ -f "${REPO_ROOT}/security/cosign.pub" ]; then
  if diff -q "${KEY}" "${REPO_ROOT}/security/cosign.pub" >/dev/null 2>&1; then
    ok "published key is byte-identical to security/cosign.pub in this checkout"
  else
    warn "published key DIFFERS from security/cosign.pub in this checkout — key rotation in flight?"
  fi
fi
note "P-256 ECDSA, one keypair for the whole catalogue. The private half exists only as CI variables (COSIGN_PRIVATE_KEY / COSIGN_PASSWORD); rotation is announced on the security page."

gap
say "Registry credential. The sandbox registry is private, so a verifier needs a read-only pull token. cosign reads it from a docker config; we point DOCKER_CONFIG at this run's work dir so nothing outside it changes."
set +e; setup_auth; auth_rc=$?; set -e
case "${auth_rc}" in
  0) ok "credential accepted by ${REG} (pull scope on ${REPO_PATH})"
     note "Throwaway DOCKER_CONFIG at ${DOCKER_CONFIG}, removed on exit unless --keep." ;;
  1) warn "using your existing docker/podman login; registry-API steps will be skipped" ;;
  2) die "credential rejected by ${REG} — check REG_USER / REG_PASS" ;;
  *) die "set REG_USER and REG_PASS (read_registry deploy token), or pass --use-docker-login" ;;
esac
gap
say "Target image for this walkthrough:"
printf '      %s%s%s\n' "${B}" "${REF}" "${N}"
pause
fi

# ═══════════════════════════════════════════════════════════════════════════
# ACT 2 — what is published next to the image
# ═══════════════════════════════════════════════════════════════════════════
if ! skipping 2; then
act 2 "What is published alongside the image"
say "Every publish run emits three artifacts per image, all keyed to the image's manifest DIGEST — never to the tag, which can move:"
gap
say "  1. the image           → tag :${TAG}"
say "  2. a signature         → tag sha256-<digest>.sig"
say "  3. an SBOM attestation → tag sha256-<digest>.att   (signed DSSE envelope)"
gap
note "Registries can also link artifacts through the OCI 1.1 Referrers API. GitLab does not implement it (bare 404), so cosign's tag-fallback naming above IS the discovery mechanism here. Any OCI client — oras, crane, skopeo — can fetch these tags."
if [ "${HAVE_REG_API}" = 1 ]; then
  gap
  say "Resolve the tag to the digest the signature is bound to:"
  ensure_digest
  cmd "curl -sI .../v2/${APP}/manifests/${TAG} | grep docker-content-digest"
  printf '      %s%s@%s%s\n' "${B}" "${REG}/${REPO_PATH}" "${DIGEST}" "${N}"
  hex="${DIGEST#sha256:}"
  gap
  say "The sidecar tags that exist for exactly this digest:"
  reg_get "${REPO_PATH}" "tags/list" | jq -r '.tags[]' > "tags.txt"
  cmd "curl -s .../v2/${APP}/tags/list | jq -r '.tags[]' | grep ${hex:0:12}"
  grep -E "^sha256-${hex}\.(sig|att|sbom)$" "tags.txt" | sed 's/^/      /' \
    || warn "no sidecar tags for this digest — was it published before signing went live?"
  gap
  ok "repository totals: $(grep -c '\.sig$' "tags.txt" || echo 0) signature tags, $(grep -c '\.att$' "tags.txt" || echo 0) attestation tags (one pair per digest ever published)"
  note "A .sbom tag, if you see one, is a pre-2026-07-19 attached SBOM (cosign attach sbom, deprecated upstream). The .att attestation replaced it: one signed artifact instead of three registry operations, and verification that hands back verified bytes rather than raw ones."
else
  warn "registry-API listing skipped (--use-docker-login)"
fi
pause
fi

# ═══════════════════════════════════════════════════════════════════════════
# ACT 3 — verify the image signature
# ═══════════════════════════════════════════════════════════════════════════
if ! skipping 3; then
act 3 "Verify the image signature"
say "One command. The --insecure-ignore-tlog=true flag is required and deliberate: we sign with a plain keypair and do NOT publish to the public Rekor transparency log, because image names in a private sandbox registry are not public information. The flag means 'no transparency log', not 'no verification'."
ensure_digest
cmd "cosign verify --key cosign.pub --insecure-ignore-tlog=true ${REF}"
set +e
cosign verify --key "${KEY}" --insecure-ignore-tlog=true "${REF}" \
  > "verify.json" 2> "verify.err"
rc=$?
set -e
sed 's/^/      /' "verify.err"
[ "${rc}" -eq 0 ] || die "verification failed — see above"
ok "signature verified"
gap
say "The payload cosign checked binds the key to a digest, not to a tag:"
show "jq -rs 'flatten | .[0].critical | {image: .image.\"docker-manifest-digest\", ref: .identity.\"docker-reference\"}' verify.json"
note "cosign resolved :${TAG} to ${DIGEST} and found a signature over that digest. Retag a different image as :${TAG} and this step fails — there is no signature for the new digest."

gap
say "Negative control 1 — the same image, verified against a keypair we generate right here. If this passed, the signature would prove nothing."
mkdir -p "bogus"
( cd "bogus" && COSIGN_PASSWORD="" cosign generate-key-pair >/dev/null 2>&1 ) \
  || warn "could not generate a throwaway keypair; skipping control 1"
if [ -f "bogus/cosign.pub" ]; then
  cmd "cosign verify --key <freshly-generated-key> ${REF}"
  set +e
  cosign verify --key "bogus/cosign.pub" --insecure-ignore-tlog=true "${REF}" \
    >/dev/null 2> "neg1.err"
  rc=$?
  set -e
  sed 's/^/      /' "neg1.err" | head -6
  [ "${rc}" -ne 0 ] && ok "rejected, as it must be" || bad "UNEXPECTED: verified with the wrong key"
fi

gap
say "Negative control 2 — a real image in the same registry that never went through the publish pipeline (${UNSIGNED_APP}, a hand-pushed proof of concept). Nothing signed it, so there is nothing to verify."
cmd "cosign verify --key cosign.pub ${REG}/${NS}/${UNSIGNED_APP}:${TAG}"
set +e
cosign verify --key "${KEY}" --insecure-ignore-tlog=true "${REG}/${NS}/${UNSIGNED_APP}:${TAG}" \
  >/dev/null 2> "neg2.err"
rc=$?
set -e
sed 's/^/      /' "neg2.err" | head -6
[ "${rc}" -ne 0 ] && ok "rejected — this is what an unsigned image looks like" \
  || warn "that image is signed now; pick another with UNSIGNED_APP=<name>"
note "That is the practical value to a consumer: 'this came from the kasm-nix pipeline' becomes something they check, not something they take on faith."
pause
fi

# ═══════════════════════════════════════════════════════════════════════════
# ACT 4 — verify the attestation, extract the SBOM
# ═══════════════════════════════════════════════════════════════════════════
if ! skipping 4; then
act 4 "Verify the attestation and extract the SBOM"
say "The SBOM is not a file you download and hope for. It ships as an in-toto ATTESTATION: a DSSE envelope whose payload is a signed statement saying 'subject = this image digest, predicate = this CycloneDX document'. Verification and extraction are one command."
ensure_digest
gap
say "First the unverified view — what is literally stored in the registry:"
cmd "cosign download attestation ${REG}/${APP}@${DIGEST:0:19}… > ${APP}.dsse.json"
cosign download attestation "${REG}/${REPO_PATH}@${DIGEST}" > "${ENVELOPE}"
show "jq '{payloadType, signatures: [.signatures[] | {keyid, sig: (.sig[0:24] + \"…\")}], payload_bytes: (.payload|length)}' ${ENVELOPE}"
note "A base64 payload plus a detached signature over it. 'download' returns these bytes without checking anything — never parse an SBOM you obtained this way."
gap
say "Now the verified path: cosign checks the signature over the envelope and only then hands you the payload."
cmd "cosign verify-attestation --key cosign.pub --insecure-ignore-tlog=true --type cyclonedx ${REG}/${APP}@${DIGEST:0:19}…"
set +e
cosign verify-attestation --key "${KEY}" --insecure-ignore-tlog=true --type cyclonedx \
  "${REG}/${REPO_PATH}@${DIGEST}" > "att.json" 2> "att.err"
rc=$?
set -e
sed 's/^/      /' "att.err" | head -12
[ "${rc}" -eq 0 ] || die "attestation verification failed"
ok "attestation verified"
gap
say "Decode the verified payload into the in-toto statement:"
show "jq -r '.payload' att.json | head -n1 | base64 -d > ${STMT}; jq '{_type, predicateType, subject}' ${STMT}"
gap
say "That subject digest is the whole point. Compare it with the image you verified in act 3:"
sub="$(jq -r '.subject[0].digest.sha256' "${STMT}")"
printf '      attested subject : sha256:%s\n      verified image   : %s\n' "${sub}" "${DIGEST}"
if [ "sha256:${sub}" = "${DIGEST}" ]; then
  ok "match — this SBOM describes this image, and both facts are signed"
else
  bad "MISMATCH — this SBOM belongs to a different image"
fi
gap
say "The predicate is the SBOM. Extract it:"
show "jq '.predicate' ${STMT} > ${SBOM}; ls -lh ${SBOM} | awk '{print \"      \" \$5, \$NF}'"
note "So a stale or doctored SBOM cannot be passed off as ours: the format, the bytes and the digest binding all live inside one signed envelope."
pause
fi

# ═══════════════════════════════════════════════════════════════════════════
# ACT 5 — read the SBOM
# ═══════════════════════════════════════════════════════════════════════════
if ! skipping 5; then
act 5 "What is actually in an SBOM"
[ -f "${SBOM}" ] || die "no SBOM at ${SBOM} — run act 4 first (use --from 4, not --only 5)"
say "CycloneDX, generated by syft. The header alone answers who made this, when, and from what:"
show "jq '{bomFormat, specVersion, serialNumber, generated: .metadata.timestamp, tool: .metadata.tools.components[0], subject: .metadata.component}' ${SBOM}"
note "metadata.component.version is the image ID the scan actually ran against, so the SBOM records which build it inspected independently of any tag."
gap
say "Everything it found, by component type:"
show "jq -r '.components | group_by(.type)[] | \"      \\(.[0].type)\\t\\(length)\"' ${SBOM} | sort -k2 -nr"
note "The 'file' rows are per-file hash evidence — that is why the document runs to tens of megabytes. The inventory a security team acts on is the packages: library + application + operating-system."
gap
say "The package inventory by ecosystem. This is the line that matters most for these images:"
show "jq -r '[.components[] | select(.purl) | .purl | split(\"/\")[0]] | group_by(.)[] | \"      \\(.[0])\\t\\(length)\"' ${SBOM} | sort -k2 -nr"
gap
say "Why pkg:nix matters. These images carry their applications in a Nix store, not in dpkg. Point a stock scanner at the shipped image and it sees an Ubuntu base with almost nothing installed — the app, its libraries and their CVEs are invisible. Our pipeline normalises the store layout before scanning and pins syft's nix cataloger by name, so the whole closure is inventoried:"
show "jq -r '[.components[] | select(.purl // \"\" | startswith(\"pkg:nix\"))] | \"      \\(length) Nix store packages catalogued\"' ${SBOM}"
gap
say "A Nix component is unusually precise: the store path is a hash over the entire build recipe, so this is not 'openssl 3.x-ish', it is one exact set of bytes."
show "jq '[.components[] | select(.purl // \"\" | startswith(\"pkg:nix\")) | select(.name==\"openssl\")][0] | {name, version, purl, cpe, store_path: (.properties[] | select(.name==\"syft:location:0:path\") | .value)}' ${SBOM}"
gap
say "The applications, and the base OS they ride on:"
show "jq -r '[.components[] | select(.type==\"application\")] | map(\"      \\(.name) \\(.version)\")[]' ${SBOM}"
show "jq -r '.components[] | select(.type==\"operating-system\") | \"      base OS: \\(.name) \\(.version)\"' ${SBOM}"
gap
say "Answer an audit question straight from the document — 'which zlib do you ship, anywhere in this image?':"
show "jq -r '[.components[] | select(.name|test(\"^zlib\")) | \"      \\(.name)\\t\\(.version)\\t\\(.purl // \"-\")\"] | unique[]' ${SBOM}"
if [ "${HAVE_REG_API}" = 1 ]; then
  gap
  say "The image's own labels carry the build provenance the SBOM does not: which nixpkgs revision, which pipeline commit, which store path the app came from."
  ensure_digest
  man="$(reg_get "${REPO_PATH}" "manifests/${DIGEST}")"
  if [ "$(jq -r 'has("manifests")' <<<"${man}")" = "true" ]; then
    child="$(jq -r '.manifests[0].digest' <<<"${man}")"
    man="$(reg_get "${REPO_PATH}" "manifests/${child}")"
  fi
  cfgd="$(jq -r '.config.digest' <<<"${man}")"
  reg_get "${REPO_PATH}" "blobs/${cfgd}" > "config.json"
  show "jq '(.config.Labels // .container_config.Labels) | with_entries(select(.key|test(\"^(dev.kasm|org.opencontainers)\")))' config.json"
  note "dev.kasm.nix.rev is the nixpkgs revision the closure was built from. With it, anyone can rebuild the same derivation and get the same store paths the SBOM lists."
fi
pause
fi

# ═══════════════════════════════════════════════════════════════════════════
# ACT 6 — use the SBOM
# ═══════════════════════════════════════════════════════════════════════════
if ! skipping 6; then
act 6 "Use the SBOM — scan it yourself, then apply our VEX"
[ -f "${SBOM}" ] || die "no SBOM at ${SBOM} — run act 4 first (use --from 4)"
say "An SBOM's real job is to let someone who does not trust our scan results reproduce them. No image pull, no access to our tooling, no shared database — just the verified document from act 4."
if ! command -v grype >/dev/null; then
  warn "grype not installed — skipping the live scan (github.com/anchore/grype)"
  note "The one-liner once installed:  grype sbom:${APP}.cdx.json"
else
  note "First run downloads grype's vulnerability database (hundreds of MB). CI pins both scanner and DB versions so numbers stay comparable between runs; yours may differ from the security page by a day of DB drift."
  cmd "grype sbom:${APP}.cdx.json -o json > grype.json"
  grype -q "sbom:${SBOM}" -o json > "grype.json"
  gap
  say "Findings by severity — your scanner, your database:"
  show "jq -r '[.matches[].vulnerability.severity] | group_by(.)[] | \"      \\(.[0])\\t\\(length)\"' grype.json"
  gap
  say "Deduplicated by CVE id, then the actionable subset: criticals with an upstream fix. That last number is the one we drive toward zero — unfixed criticals wait on nixpkgs."
  show "jq -r '[.matches[].vulnerability.id] | unique | \"      \\(length) unique vulnerability ids\"' grype.json"
  show "jq -r '[.matches[] | select(.vulnerability.severity==\"Critical\")] as \$c | \"      \\(\$c|length) critical, \\([\$c[] | select(.vulnerability.fix.state==\"fixed\")] | length) with a fix available\"' grype.json"
  gap
  say "Where the findings live — note how many come from the Nix store rather than the Ubuntu base:"
  show "jq -r '[.matches[].artifact.type] | group_by(.)[] | \"      \\(.[0])\\t\\(length)\"' grype.json | sort -k2 -nr | head -6"
fi
gap
say "VEX is the other half of an honest number. A raw match is not automatically a real exposure: nixpkgs back-ports fixes without bumping a version, and CPE matching produces name collisions. Every suppression we apply is published as an OpenVEX statement with a written justification, so you can inspect it and disagree."
VEXF=""
if [ -n "${REPO_ROOT}" ] && [ -f "${REPO_ROOT}/security/vex/kasm-nix.openvex.json" ]; then
  cp "${REPO_ROOT}/security/vex/kasm-nix.openvex.json" ./kasm-nix.openvex.json
  VEXF="kasm-nix.openvex.json"
fi
if [ -n "${VEXF}" ]; then
  show "jq -r '\"      author: \\(.author)\\n      version: \\(.version)   statements: \\(.statements|length)\"' ${VEXF}"
  show "jq -r '.statements[] | \"      \\(.vulnerability.name)  \\(.status)  \\(.justification // \"see impact_statement\")\"' ${VEXF}"
  if [ -f "grype.json" ]; then
    gap
    say "Which of those statements actually bite on the image you just scanned:"
    show "jq -r --slurpfile vex ${VEXF} '[.matches[].vulnerability.id] | unique as \$ids | \$vex[0].statements[] | select(.vulnerability.name as \$v | \$ids | index(\$v)) | \"      \\(.vulnerability.name) → \\(.status)\"' grype.json"
  fi
  note "Grype's native --vex silently no-ops on our directory-sourced SBOMs (its product matching wants OCI digests), so the pipeline converts OpenVEX into grype ignore rules instead. Suppressed findings land in ignoredMatches and are shown as a 'suppressed (VEX)' column on the security page rather than quietly disappearing."
else
  warn "run from a repo checkout to show security/vex/kasm-nix.openvex.json"
fi
pause
fi

# ═══════════════════════════════════════════════════════════════════════════
# ACT 7 — what this proves
# ═══════════════════════════════════════════════════════════════════════════
if ! skipping 7; then
act 7 "What this proves — and what it does not"
say "PROVEN by what we just ran:"
bul "The image you pulled is byte-for-byte the one our pipeline published. Any retag, rebuild or layer edit changes the digest and breaks the signature."
bul "The SBOM is bound to that exact digest and signed with the same key, so its inventory cannot be swapped, staled or edited undetected."
bul "The inventory reaches inside the Nix store, where a stock image scanner sees nothing, and names exact derivations rather than fuzzy versions."
bul "Anyone can re-derive our published CVE counts with their own scanner and database, and audit every suppression we applied."
gap
say "NOT proven — and we say so on the security page:"
bul "Not 'free of vulnerabilities'. Scanning is point-in-time and currently report-only; publication is not yet gated on unpatched criticals."
bul "Not an endorsement, certification, warranty or support commitment."
bul "Not transparency-log backed: signing is key-based with --tlog-upload=false, so trust in the key rests on the published cosign.pub, not on Rekor."
bul "Not build provenance (SLSA). We attest what is IN the image, not yet the full record of HOW it was built."
gap
say "Where to look next:"
say "  security page   ${SECURITY_PAGE}"
say "  producer side   ci-scripts/nix-sbom-attach.sh   (cosign attest + sign, bounded-parallel)"
say "  scanner side    ci-scripts/nix-scan-l3.sh       (export → normalise → syft → grype)"
say "  design record   design/cve-scanning.md, design/cve-triage-playbook.md"
say "  suppressions    security/vex/kasm-nix.openvex.json, security/evidence/"
gap
if [ "${KEEP}" = 1 ]; then ok "artifacts kept in ${WORK}"; else note "artifacts in ${WORK} are deleted on exit; re-run with --keep to keep them."; fi
fi
