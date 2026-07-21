#!/usr/bin/env bash
# nix-scan-l3.sh — L3 (/nix/store) CVE scan of the assembled nix images.
# Report-only: findings NEVER fail the job; scanner/infra errors DO.
# Implements design/cve-scanning.md § 7 step 3.
#
# Runs INSIDE the forge DinD (quay.io/podman/stable) against the persistent
# podman store where the build left localhost/nix-<app>:dev + the fat store.
#
# Per image (changed apps + fat store):
#   podman export → rename store→nix/store, var→nix/var (Syft's nix cataloger
#   only sees paths spelled nix/store/*; the shipped symlink layout is invisible
#   to it — proven in the 2026-07-18 spike) → syft dir: (CycloneDX artifact +
#   syft-json for grype) → grype → per-image stats row → delete the export.
#   Bounded-parallel apps, fat store serial (~29 GB export). Every export is
#   trap-cleaned: they duplicate substantial data on the build host.
#
# vulnix runs ADVISORY-ONLY afterwards, per app, inside one inner nixos/nix
# container with the build staging volume at /nix (where db + drvs live), fed
# the exact runtime closure (--no-requisites, profile roots excluded). vulnix
# problems warn + are recorded, but never fail the job — it has no gate role.
# The fat store gets no vulnix pass (it is the union of the same profiles).
#
# Env:
#   NIX_PROFILES   space list of app profiles to scan (change-gating, same
#                  semantics as nix-publish.sh); "" = every built app image;
#                  "__none__" = exit 0.
#   SCAN_MAX_APPS  optional cap on app scans for NIX_PROFILES="" runs
#                  (default 0 = unlimited — step 4 needs an SBOM per image;
#                  a full-catalog run is ~1 min/app). Truncation is LOGGED.
#   BUILD_OUTPUT   the build's output/sidecar dir (labels.json,
#                  closure-diffs.json), mounted ro; used to classify a
#                  requested-but-unbuilt app as unchanged vs build-failed.
#   NIX_APP_REPO   local repo prefix (default localhost/nix)
#   ARCH           amd64|arm64 (default: uname -m mapping)
#   OUT_DIR        artifact dir (default /artifacts)
#   DOCKER         container CLI (default podman)
#   PARALLEL       concurrent app scans (default 2)
#   SCAN_ALL       1 = scan every built app image (ignore assembled.txt/filter)
#   SKIP_VULNIX    1 = skip the advisory vulnix pass
#   SKIP_FAT_SCAN  1 (DEFAULT) = skip the fat-store SBOM scan (~40G export; its
#                  closure is the per-app+resolute union, already scanned). The
#                  fat store is still built+published — only its scan is skipped.
#                  0 = also scan it (needs a disk-roomy runner).
#   VEX_FILE       OpenVEX statement file (default /work/security/vex/
#                  kasm-nix.openvex.json — the repo mount). Statements with
#                  status not_affected/false_positive are converted to grype
#                  ignore rules (vulnerability id + subcomponent package
#                  name). NOTE: grype's native --vex is NOT used — its product
#                  matching keys on OCI digests/purls that our dir-sourced
#                  SBOMs don't carry, so it would silently no-op. Suppressed
#                  matches land in grype's ignoredMatches and are reported as
#                  the "vexed" count; crit/fixed-crit are AFTER suppression.
#   SYFT_VERSION / GRYPE_VERSION  pinned scanner releases
#   VULNIX_NIXPKGS_REV  nixpkgs rev vulnix is run from (pinned; recorded)
#   NIX_IMAGE      inner nix container (default docker.io/nixos/nix:2.28.4)
#   HOST_UID/HOST_GID  chown artifacts back to the runner UID
set -euo pipefail

NIX_APP_REPO="${NIX_APP_REPO:-localhost/nix}"
DOCKER="${DOCKER:-podman}"
OUT_DIR="${OUT_DIR:-/artifacts}"
PARALLEL="${PARALLEL:-2}"
SCAN_MAX_APPS="${SCAN_MAX_APPS:-0}"
BUILD_OUTPUT="${BUILD_OUTPUT:-/build-output}"
VULNIX_NIXPKGS_REV="${VULNIX_NIXPKGS_REV:-753cc8a3a87467296ddd1fa93f0cc3e81120ee46}"
SYFT_VERSION="${SYFT_VERSION:-1.46.0}"
GRYPE_VERSION="${GRYPE_VERSION:-0.115.0}"
NIX_IMAGE="${NIX_IMAGE:-docker.io/nixos/nix:2.28.4}"
SKIP_VULNIX="${SKIP_VULNIX:-0}"
case "${ARCH:-$(uname -m)}" in amd64|x86_64) ARCH=amd64 ;; arm64|aarch64) ARCH=arm64 ;; esac

FILTER="${NIX_PROFILES:-}"
if [ "${FILTER}" = "__none__" ]; then
  echo "[nix-scan-l3] NIX_PROFILES=__none__ — nothing was built this run; skipping"; exit 0
fi

WORK="$(mktemp -d /tmp/l3-scan.XXXXXX)"
# Export containers get a predictable name prefix so a cancellation between
# `podman create` and `podman rm` can't leak them past the trap.
CTR_PREFIX="l3scan-$$"
cleanup() {
  "${DOCKER}" ps -aq --filter "name=^${CTR_PREFIX}-" 2>/dev/null \
    | xargs -r "${DOCKER}" rm -f >/dev/null 2>&1 || true
  chmod -R u+w "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"
}
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap cleanup EXIT

SBOM_DIR="${OUT_DIR}/sboms"; GRYPE_DIR="${OUT_DIR}/grype"; VULNIX_DIR="${OUT_DIR}/vulnix"
mkdir -p "${SBOM_DIR}" "${GRYPE_DIR}" "${VULNIX_DIR}" "${WORK}/rows" "${WORK}/logs"

log()  { printf '%s %s\n' "[nix-scan-l3]" "$*" >&2; }
fail() { printf '%s FATAL: %s\n' "[nix-scan-l3]" "$*" >&2; exit 1; }

# ── deps: jq + pinned syft/grype (checksum-verified) ─────────────────────────
command -v curl >/dev/null || dnf install -y --setopt=install_weak_deps=False curl >/dev/null
command -v jq   >/dev/null || dnf install -y --setopt=install_weak_deps=False jq   >/dev/null
fetch_anchore() {  # $1=name $2=version → /tmp/$1
  local n="$1" v="$2" tgz="/tmp/${1}.tgz"
  curl -fsSLo "${tgz}" "https://github.com/anchore/${n}/releases/download/v${v}/${n}_${v}_linux_${ARCH}.tar.gz"
  curl -fsSLo "/tmp/${n}.sums" "https://github.com/anchore/${n}/releases/download/v${v}/${n}_${v}_checksums.txt"
  (cd /tmp && grep " ${n}_${v}_linux_${ARCH}.tar.gz\$" "${n}.sums" | sed "s|${n}_${v}_linux_${ARCH}.tar.gz|${n}.tgz|" | sha256sum -c - >/dev/null)
  tar -C /tmp -xzf "${tgz}" "${n}"
}
log "fetching syft ${SYFT_VERSION} + grype ${GRYPE_VERSION} (${ARCH})"
fetch_anchore syft  "${SYFT_VERSION}";  SYFT=/tmp/syft
fetch_anchore grype "${GRYPE_VERSION}"; GRYPE=/tmp/grype
export SYFT_CHECK_FOR_APP_UPDATE=false GRYPE_CHECK_FOR_APP_UPDATE=false DO_NOT_TRACK=1
export GRYPE_DB_CACHE_DIR=/tmp/grype-db
log "updating grype vulnerability DB"
"${GRYPE}" db update -q || fail "grype db update failed"
DB_BUILT="$("${GRYPE}" db status -o json 2>/dev/null | jq -r '.built // .Built // "unknown"' 2>/dev/null || echo unknown)"

# ── OpenVEX → grype ignore rules ──────────────────────────────────────────────
# security/vex/kasm-nix.openvex.json is the canonical triage record (OpenVEX,
# portable). Grype consumes it as generated ignore rules — see the VEX_FILE
# note in the header for why --vex is not used. A malformed VEX file is a
# FATAL error: silently scanning without suppressions would misreport, and
# silently suppressing wrongly would be worse.
VEX_FILE="${VEX_FILE:-/work/security/vex/kasm-nix.openvex.json}"
# Grype ignore rules are CATALOG-WIDE (vulnerability id + package name) —
# they cannot express per-image scope. So only statements whose product is
# the whole-catalog IRI are representable; a statement scoped to anything
# narrower is REJECTED (fail-loud), not silently over-applied to every
# image. Suppression statuses per the OpenVEX spec: only not_affected (a
# scanner false positive is not_affected + justification; "false_positive"
# is not an OpenVEX status).
GRYPE_CFG=""; VEX_RULES=0
L3_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
if [ -f "${VEX_FILE}" ]; then
  # All validation + rule emission lives in nix-vex-lint.sh (single source
  # of truth, regression-tested against committed invalid fixtures by
  # ci-scripts/tests/vex-lint-test.sh — this code controls suppression).
  bash "${L3_DIR}/nix-vex-lint.sh" "${VEX_FILE}" > "${WORK}/grype-vex.yaml" \
    || fail "VEX lint rejected ${VEX_FILE} (reason above)"
  VEX_RULES="$(grep -c '^  - vulnerability:' "${WORK}/grype-vex.yaml" || true)"
  if [ "${VEX_RULES}" -gt 0 ]; then
    GRYPE_CFG="${WORK}/grype-vex.yaml"
    log "VEX: ${VEX_RULES} suppression rule(s) from ${VEX_FILE}"
  else
    log "VEX: file present but no suppressing statements"
  fi
else
  log "VEX: no statement file at ${VEX_FILE} (raw counts only)"
fi

# ── target list: changed apps (or capped all) + fat store ────────────────────
in_filter() { [ -z "${FILTER}" ] && return 0; local x; for x in ${FILTER}; do [ "${x}" = "$1" ] && return 0; done; return 1; }
# Resolute (multi-store DESKTOP) profiles ship no single-app :dev image — they
# are scanned by the dedicated resolute loop below (scan_one mode 2), never the
# per-app path. Compute the set early so the FILTER completeness check can
# exclude them (else a changed resolute profile like tracelabs, absent from the
# per-app image list, is misreported as a build failure).
PROFILES_TOML="${PROFILES_TOML:-/work/bin/nix-profiles.toml}"
resolute_profiles() {
  awk '
    /^\[profiles\./ { cur=$0; sub(/^\[profiles\./,"",cur); sub(/\].*/,"",cur) }
    /^[[:space:]]*app_base[[:space:]]*=/ && cur!="" {
      v=$0; sub(/^[^"]*"/,"",v); sub(/".*/,"",v); if (v=="resolute") print cur
    }
  ' "${PROFILES_TOML}" 2>/dev/null
}
is_resolute() { local p; for p in $(resolute_profiles); do [ "${p}" = "$1" ] && return 0; done; return 1; }
mapfile -t all_apps < <("${DOCKER}" images --format '{{.Repository}}:{{.Tag}}' \
  | grep -E "^${NIX_APP_REPO}-[a-z0-9][a-z0-9-]*:dev$" \
  | grep -vE "^${NIX_APP_REPO}-(ubuntu|store|fedora|alpine|resolute)" \
  | sed -E "s|^${NIX_APP_REPO}-||; s|:dev\$||" | sort)
# Scan scope, in priority order:
#   1. SCAN_ALL=1            → every built app image (manual baselines)
#   2. assembled.txt sidecar → exactly what THIS build reassembled (includes
#                              wiring/pin movers beyond the git-gated set;
#                              written by nix-crane-assemble)
#   3. NIX_PROFILES filter   → manual runs without the sidecar
#   4. everything present    → last resort
apps=(); missing_requested=(); scan_scope="all-images"
if [ "${SCAN_ALL:-0}" = "1" ]; then
  apps=("${all_apps[@]}"); scan_scope="SCAN_ALL"
elif [ -f "${BUILD_OUTPUT}/assembled.txt" ]; then
  scan_scope="assembled.txt"
  while IFS= read -r a; do
    [ -n "${a}" ] || continue
    for b in "${all_apps[@]}"; do [ "${b}" = "${a}" ] && { apps+=("${a}"); break; }; done
  done < "${BUILD_OUTPUT}/assembled.txt"
elif [ -n "${FILTER}" ]; then
  scan_scope="NIX_PROFILES"
  for a in "${all_apps[@]}"; do in_filter "${a}" && apps+=("${a}"); done
else
  apps=("${all_apps[@]}")
fi
log "scan scope: ${scan_scope} (${#apps[@]} apps)"
# Per-app :dev images are BUILD PRODUCTS — the eval-gate skips reassembling
# unchanged apps, so a requested profile that is not in scope can mean
# "unchanged this run" (normal; nix-publish treats zero images the same way)
# OR "its build failed" (an error). Disambiguate via the build sidecar
# closure-diffs.json (status: new|changed|unchanged): unchanged → recorded
# as not_built; anything else (or absent from the sidecar) → the image
# should exist → counted as a failure. Sidecar unavailable → not_built with
# a warning. Note: unchanged apps' store paths ARE in the fat-store scan,
# but per-app coverage for them only arrives with the scheduled re-scan
# (build order step 6) — until then this is a recorded coverage gap.
build_failed=()
if [ -n "${FILTER}" ]; then
  for want in ${FILTER}; do
    found=0; for a in "${apps[@]}"; do [ "${a}" = "${want}" ] && found=1 && break; done
    [ "${found}" = 1 ] && continue
    # resolute profiles are scanned by their own loop, not the per-app path —
    # never expected in apps[], so their absence here is not a build failure.
    if is_resolute "${want}"; then continue; fi
    st="sidecar-unavailable"
    if [ -f "${BUILD_OUTPUT}/closure-diffs.json" ]; then
      st="$(jq -r --arg a "${want}" '.[$a].status // "absent-from-sidecar"' "${BUILD_OUTPUT}/closure-diffs.json")"
    fi
    case "${st}" in
      unchanged|sidecar-unavailable)
        log "WARN requested profile '${want}' has no image — not built (${st})"
        missing_requested+=("${want}") ;;
      *)
        log "ERROR requested profile '${want}' has no image but sidecar status='${st}' — build failure?"
        build_failed+=("${want}") ;;
    esac
  done
fi
if { [ "${scan_scope}" = "SCAN_ALL" ] || [ "${scan_scope}" = "all-images" ]; } \
   && [ "${SCAN_MAX_APPS}" -gt 0 ] && [ "${#apps[@]}" -gt "${SCAN_MAX_APPS}" ]; then
  log "CAP: ${#apps[@]} app images present, scanning first ${SCAN_MAX_APPS} per-app;"
  log "CAP: dropped: ${apps[*]:${SCAN_MAX_APPS}}"
  log "CAP: (fat store still covers the union at store-path level, but dropped apps get NO per-image SBOM)"
  apps=("${apps[@]:0:${SCAN_MAX_APPS}}")
fi
# Fat-store SBOM scan. Its export needs ~40G transient scratch and its closure is
# the UNION of the per-app + resolute closures that already get scanned here (plus
# vulnix), so scanning it adds disk pressure for no new coverage. SKIPPED BY DEFAULT
# (SKIP_FAT_SCAN=1). This skips the SCAN only — the fat store is still built and
# published as normal. Set SKIP_FAT_SCAN=0 on a disk-roomy runner to also emit the
# fat store's own SBOM/attestation.
FAT_IMG="localhost/nix-store-${ARCH}:dev"
if [ "${SKIP_FAT_SCAN:-1}" = "1" ]; then
  FAT_IMG=""; log "fat-store SBOM scan skipped (SKIP_FAT_SCAN=1; its closure = the per-app+resolute union, already scanned)"
elif ! "${DOCKER}" image inspect "${FAT_IMG}" >/dev/null 2>&1; then
  # Not skipping, but absent — the PUBLISH_FAT_STORE contract says every build emits
  # it, so genuine absence during a requested scan is an infrastructure failure.
  log "ERROR fat store ${FAT_IMG} absent (every build emits it; set SKIP_FAT_SCAN=1 to opt out)"
  build_failed+=("nix-store"); FAT_IMG=""
fi
log "scanning apps: ${apps[*]:-<none>}   fat store: ${FAT_IMG:-absent}"
if [ "${#apps[@]}" -eq 0 ] && [ -z "${FAT_IMG}" ] \
   && [ "${#missing_requested[@]}" -eq 0 ] && [ "${#build_failed[@]}" -eq 0 ]; then
  log "nothing to scan"; exit 0
fi

label() { "${DOCKER}" image inspect --format "{{ index .Config.Labels \"$2\" }}" "$1" 2>/dev/null || true; }

# SBOM source identity — intent-aware, never publication-asserting (design
# review rounds 4+5). Round 4: an MR pipeline runs scan-nix but NOT publish,
# so naming its SBOM with the production ref would forge provenance for an
# image that never ships. Round 5: scan-nix runs CONCURRENTLY with publish
# (needs: [prepare, build]) and publish may skip or fail per image — so this
# script can never truthfully claim "published" either. What it scans is by
# definition the local candidate build; publication is proven downstream by
# joining nix-build-report.json's per-image publication mapping (action +
# digests) on intended_ref + config_digest.
#   SBOM_PUBLISH_INTENT=1  → this pipeline also runs publish; the SBOM's
#                            source-name is the intended registry ref
#                            ($REGISTRY_NS/<kasm_name>:<tag>, mirroring
#                            nix-publish's naming) so the SBOM that
#                            sbom-publish attaches AFTER a successful push
#                            wears the name users pull
#   SBOM_PUBLISH_INTENT=0  → (default; MR pipelines, local runs) unmistakable
#                            non-registry candidate identity from
#                            project + head SHA + profile
# Report rows always carry kind:"candidate" + ref (candidate id) +
# intended_ref (the publish join key, null without intent).
SBOM_PUBLISH_INTENT="${SBOM_PUBLISH_INTENT:-0}"
kasm_name_for() {
  awk -v want="$1" '
    /^\[profiles\./ { cur=$0; sub(/^\[profiles\./,"",cur); sub(/\].*/,"",cur); name[cur]=cur }
    /^[[:space:]]*kasm_name[[:space:]]*=/ && cur!="" {
      v=$0; sub(/^[^"]*"/,"",v); sub(/".*/,"",v); name[cur]=v
    }
    END { print (want in name) ? name[want] : want }
  ' "${PROFILES_TOML}" 2>/dev/null || echo "$1"
}
pub_ref() {  # $1=scan name → published ref ("" when unresolvable)
  [ -n "${REGISTRY_NS:-}" ] || { echo ""; return; }
  if [ "$1" = "nix-store" ]; then echo "${REGISTRY_NS}/nix-store:${KASM_TAG:-nix}"
  else echo "${REGISTRY_NS}/$(kasm_name_for "$1"):${KASM_TAG:-nix}"; fi
}
cand_ref() {  # $1=scan name → the always-true candidate identity
  local sha="${CI_COMMIT_SHA:-unknown}"
  echo "candidate/${CI_PROJECT_PATH:-local}@${sha:0:12}/nix-$1"
}
sbom_ref() {  # $1=scan name → SBOM source-name (intended ref only with intent)
  local r=""
  if [ "${SBOM_PUBLISH_INTENT}" = "1" ]; then r="$(pub_ref "$1")"; fi
  [ -n "${r}" ] || r="$(cand_ref "$1")"
  echo "${r}"
}
# Resolute (multi-store DESKTOP) profiles — app_base="resolute" in the TOML.
# They ship no single-app :dev image (no custom_startup), so they never appear
# in the image-derived app list above, yet their profile IS installed in the
# staging volume. resolute_profiles() (defined near the top, alongside the
# FILTER completeness check that also consumes it) lists them so the vulnix
# advisory pass and the dedicated resolute scan loop below can cover their
# desktop-unique closure (e.g. tracelabs' OSINT tools + maltego).

# ── one image: export → normalize → syft → grype → stats row ─────────────────
scan_one() {  # $1=name $2=image-ref $3=has-nix-symlinks(1|0)
  local name="$1" img="$2" symlinks="$3"
  local d="${WORK}/${name}" c image_id
  image_id="$("${DOCKER}" image inspect --format '{{.Id}}' "${img}")" || return 1
  mkdir -p "${d}/rootfs"
  c="$("${DOCKER}" create --name "${CTR_PREFIX}-${name}" "${img}" true)" || return 1
  "${DOCKER}" export "${c}" | tar -C "${d}/rootfs" -xf - || { "${DOCKER}" rm "${c}" >/dev/null; return 1; }
  "${DOCKER}" rm "${c}" >/dev/null
  local scan_root
  if [ "${symlinks}" = "2" ]; then
    # Resolute multi-store: at rest the closure is split across REAL store roots
    # (/store = app closure; /nix-stores/<svc>/store = base services), unioned into
    # /nix/store only at runtime by nix-compose. /nix-stores/<app>/{store,var} are
    # registration SYMLINKS back to /store,/var (skip them). Union every real store
    # root into a CLEAN tree whose store sits at <root>/nix/store — syft's nix
    # cataloger keys on the ".../nix/store/" path segment, so the store MUST be one
    # level under a "nix" dir (scan_root=<root>/nix would leave it at <root>/store,
    # which the cataloger misses → only incidental language pkgs, no closure). No
    # ubuntu OS layer here (that's scan-base's L1/L2 job). CA names never collide.
    mkdir -p "${d}/scan/nix/store"
    local sr
    for sr in "${d}/rootfs/store" "${d}/rootfs/nix-stores"/*/store; do
      { [ -d "${sr}" ] && [ ! -L "${sr}" ]; } || continue
      # -exec mv -t {} + batches (a store root can hold thousands of entries → ARG_MAX).
      find "${sr}" -mindepth 1 -maxdepth 1 -exec mv -t "${d}/scan/nix/store/" {} + 2>/dev/null || true
    done
    scan_root="${d}/scan"
  else
    mkdir -p "${d}/rootfs/nix"
    if [ "${symlinks}" = "1" ]; then rm -f "${d}/rootfs/nix/store" "${d}/rootfs/nix/var"; fi
    mv "${d}/rootfs/store" "${d}/rootfs/nix/store"
    mv "${d}/rootfs/var"   "${d}/rootfs/nix/var"
    # Drop the nix DB from the scan view: syft's nix cataloger catalogues every
    # path REGISTERED in db.sqlite, and the fat store ships the staging volume's
    # db — which registers old-generation paths whose store dirs are NOT in the
    # image → phantom packages/CVEs (2688148353's fat row showed 25.05 freerdp/
    # openssl "present" post-bump). Dir enumeration alone is full coverage. (Mode 2
    # moves no var, so has no db to drop.)
    rm -rf "${d}/rootfs/nix/var/nix/db"
    scan_root="${d}/rootfs"
  fi
  # IMAGE cataloger set, not the dir: defaults — directory scans enable
  # declared-dependency catalogers (lockfiles/manifests inside the rootfs
  # would inflate the inventory with software that isn't installed). The
  # nix cataloger is pinned by name so a tag-set change can't drop it.
  # Source identity: kind-aware (published ref vs unmistakable candidate
  # id) — provenance + VEX product matching depend on it.
  local src_name; src_name="$(sbom_ref "${name}")"
  "${SYFT}" -q "dir:${scan_root}" \
      --override-default-catalogers image \
      --select-catalogers "+nix-cataloger" \
      --source-name "${src_name}" \
      --source-version "${image_id}" \
      -o "syft-json=${SBOM_DIR}/${name}.syft.json" \
      -o "cyclonedx-json=${SBOM_DIR}/${name}.cdx.json" || return 1
  local pkgs_nix
  pkgs_nix="$(jq '[.artifacts[]|select(.type=="nix")]|length' "${SBOM_DIR}/${name}.syft.json")"
  if [ "${pkgs_nix}" -eq 0 ]; then
    echo "ASSERT FAILED: 0 nix packages catalogued for ${name} — cataloger set wrong?" >&2
    return 1
  fi
  # Grype scans the syft-json; that SAME file is kept as the canonical SBOM
  # artifact (CycloneDX is emitted alongside for interop/attachment, but the
  # re-scan input of record is the lossless syft-json). VEX suppressions ride
  # in as ignore rules; suppressed matches stay visible in ignoredMatches.
  local -a gargs=()
  [ -n "${GRYPE_CFG}" ] && gargs+=(-c "${GRYPE_CFG}")
  "${GRYPE}" -q "${gargs[@]}" "sbom:${SBOM_DIR}/${name}.syft.json" -o "json=${GRYPE_DIR}/${name}.grype.json" || return 1
  # stats row (dedup CVEs by id; severity sets are unique-by-id too).
  # artifact = the explicit identity contract (design review rounds 4+5):
  # kind is ALWAYS "candidate" — scan-nix runs concurrently with publish and
  # publish may skip/fail per image, so publication is never asserted here.
  # Promotion to "published" happens at consumers by joining nix-build-
  # report.json's publication mapping (dest==intended_ref, matching
  # candidateConfigDigest==config_digest, action pushed/skipped +
  # equivalence basis). intended_ref is null on no-intent (MR/local) runs.
  local iref=""
  [ "${SBOM_PUBLISH_INTENT}" = "1" ] && iref="$(pub_ref "${name}")"
  jq -n --arg name "${name}" \
        --arg image "${img}" \
        --arg image_id "${image_id}" \
        --arg cref "$(cand_ref "${name}")" \
        --arg iref "${iref}" \
        --arg src "${src_name}" \
        --arg sha_env "${CI_COMMIT_SHA:-}" \
        --arg pipeline "${CI_PIPELINE_ID:-}" \
        --arg job "${CI_JOB_ID:-}" \
        --arg store_path "$(label "${img}" dev.kasm.nix.store-path)" \
        --arg rev "$(label "${img}" dev.kasm.nix.rev)" \
        --argjson pkgs_total "$(jq '.artifacts|length' "${SBOM_DIR}/${name}.syft.json")" \
        --argjson pkgs_nix   "${pkgs_nix}" \
        --argjson cves "$(jq '[.matches[].vulnerability.id]|unique|length' "${GRYPE_DIR}/${name}.grype.json")" \
        --argjson crit "$(jq '[.matches[]|select(.vulnerability.severity=="Critical").vulnerability.id]|unique|length' "${GRYPE_DIR}/${name}.grype.json")" \
        --argjson high "$(jq '[.matches[]|select(.vulnerability.severity=="High").vulnerability.id]|unique|length' "${GRYPE_DIR}/${name}.grype.json")" \
        --argjson fixed_crit "$(jq '[.matches[]|select(.vulnerability.severity=="Critical" and .vulnerability.fix.state=="fixed").vulnerability.id]|unique|length' "${GRYPE_DIR}/${name}.grype.json")" \
        --argjson vexed "$(jq '[.ignoredMatches[]?.vulnerability.id]|unique|length' "${GRYPE_DIR}/${name}.grype.json")" \
        --argjson fixed_crit_raw "$(jq '[(.matches[],(.ignoredMatches[]?))|select(.vulnerability.severity=="Critical" and .vulnerability.fix.state=="fixed").vulnerability.id]|unique|length' "${GRYPE_DIR}/${name}.grype.json")" \
        '{name:$name,image:$image,image_id:$image_id,store_path:$store_path,rev:$rev,
          artifact:{kind:"candidate",ref:$cref,
                    intended_ref:(if $iref=="" then null else $iref end),
                    sbom_source_name:$src,config_digest:$image_id,
                    source_commit:$sha_env,pipeline_id:$pipeline,scan_job_id:$job},
          packages:{total:$pkgs_total,nix:$pkgs_nix},
          cves:{unique:$cves,critical:$crit,high:$high,fixed_critical:$fixed_crit,
                vexed:$vexed,fixed_critical_raw:$fixed_crit_raw}}' \
        > "${WORK}/rows/${name}.json" || return 1
  gzip -f "${SBOM_DIR}/${name}.syft.json" "${SBOM_DIR}/${name}.cdx.json" "${GRYPE_DIR}/${name}.grype.json"
  chmod -R u+w "${d}"; rm -rf "${d}"
}

# ── bounded-parallel app scans ────────────────────────────────────────────────
failed=("${build_failed[@]}")
for a in "${apps[@]}"; do
  while [ "$(jobs -rp | wc -l)" -ge "${PARALLEL}" ]; do
    if ! wait -n; then :; fi     # collect one; failure detected via rows below
  done
  log "scan app: ${a}"
  ( scan_one "${a}" "${NIX_APP_REPO}-${a}:dev" 1 ) > "${WORK}/logs/${a}.log" 2>&1 &
done
wait || true
for a in "${apps[@]}"; do
  if [ ! -s "${WORK}/rows/${a}.json" ]; then
    failed+=("${a}"); log "ERROR app scan failed: ${a} — log follows"; cat "${WORK}/logs/${a}.log" >&2 || true
  fi
done

# ── resolute multi-store desktop images: localhost/nix-resolute-<app>:dev ──────
# Excluded from all_apps (need the multi-store union, scan_one mode 2). Named by
# profile so pub_ref/attestation align. Scope mirrors apps[] (SCAN_ALL / NIX_PROFILES
# filter — assembled.txt lists per-app images only). Serial: each is a large export.
# The profile ALSO gets the vulnix advisory pass below (belt-and-braces).
for rp in $(resolute_profiles); do
  [ -n "${rp}" ] || continue
  { [ "${SCAN_ALL:-0}" = "1" ] || [ -z "${FILTER}" ] || in_filter "${rp}"; } || continue
  rimg="${NIX_APP_REPO}-resolute-${rp}:dev"
  if ! "${DOCKER}" image inspect "${rimg}" >/dev/null 2>&1; then
    log "resolute scan: no image ${rimg} (not assembled this run) — vulnix still covers the profile"
    continue
  fi
  log "scan resolute desktop: ${rp} (${rimg})"
  if ! scan_one "${rp}" "${rimg}" 2 > "${WORK}/logs/${rp}.log" 2>&1; then
    failed+=("${rp}"); log "ERROR resolute scan failed: ${rp} — log follows"; cat "${WORK}/logs/${rp}.log" >&2 || true
  fi
done

# ── fat store: serial (large export); needs ~35 GB free transiently ──────────
if [ -n "${FAT_IMG}" ]; then
  free_kb="$(df -k /tmp | awk 'NR==2{print $4}')"
  if [ "${free_kb}" -lt $((40 * 1024 * 1024)) ]; then
    log "ERROR: <40 GB free on /tmp — refusing the fat-store export"; failed+=("nix-store")
  else
    log "scan fat store: ${FAT_IMG}"
    if ! scan_one "nix-store" "${FAT_IMG}" 0 > "${WORK}/logs/nix-store.log" 2>&1; then
      failed+=("nix-store"); log "ERROR fat-store scan failed — log follows"; cat "${WORK}/logs/nix-store.log" >&2 || true
    fi
  fi
fi

# ── vulnix advisory pass (one inner container for all apps) ──────────────────
# Scanned set = the per-image apps PLUS any in-scope resolute desktop profile
# (no per-image row, but its profile is in the staging volume). Scope predicate
# mirrors the apps[] scoping: full/SCAN_ALL runs, or the NIX_PROFILES filter.
vulnix_apps=("${apps[@]}")
if [ "${SKIP_VULNIX}" != "1" ]; then
  while IFS= read -r rp; do
    [ -n "${rp}" ] || continue
    { [ "${SCAN_ALL:-0}" = "1" ] || [ -z "${FILTER}" ] || in_filter "${rp}"; } || continue
    dup=0; for a in "${vulnix_apps[@]}"; do [ "${a}" = "${rp}" ] && { dup=1; break; }; done
    [ "${dup}" = "0" ] && { vulnix_apps+=("${rp}"); log "vulnix: +resolute profile '${rp}' (advisory only — no per-image SBOM until the resolute build/publish path lands)"; }
  done < <(resolute_profiles)
fi
if [ "${SKIP_VULNIX}" != "1" ] && [ "${#vulnix_apps[@]}" -gt 0 ]; then
  log "vulnix advisory pass (${#vulnix_apps[@]} apps; staging volume nix-build-stage-${ARCH})"
  if ! "${DOCKER}" volume inspect "nix-build-stage-${ARCH}" >/dev/null 2>&1; then
    log "WARN staging volume absent — vulnix skipped (advisory only)"
  else
    "${DOCKER}" run --rm \
      -e NIX_CONFIG="experimental-features = nix-command flakes" \
      -e APPS="${vulnix_apps[*]}" \
      -e VULNIX_REF="github:NixOS/nixpkgs/${VULNIX_NIXPKGS_REV}#vulnix" \
      -v "nix-build-stage-${ARCH}:/nix" \
      -v "${VULNIX_DIR}:/out" \
      "${NIX_IMAGE}" bash -c '
        set -u
        nix eval "${VULNIX_REF}.version" --raw > /out/vulnix-version.txt 2>/dev/null || echo unknown > /out/vulnix-version.txt
        for app in ${APPS}; do
          prof="/nix/var/nix/profiles/${app}"
          if [ ! -e "${prof}" ]; then
            echo "{\"app\":\"${app}\",\"status\":\"profile-missing\"}" > "/out/${app}.vulnix.json"; continue
          fi
          sp="$(readlink -f "${prof}")"
          reqs="$(nix-store -qR "${sp}" 2>/dev/null | grep -vE -- "-profile$")"
          if [ -z "${reqs}" ]; then
            echo "{\"app\":\"${app}\",\"status\":\"closure-error\"}" > "/out/${app}.vulnix.json"; continue
          fi
          if nix run "${VULNIX_REF}" -- --no-requisites --json ${reqs} > "/out/${app}.raw.json" 2>"/out/${app}.err"; then rc=0; else rc=$?; fi
          # vulnix exit: 0 = clean, 2 = findings, else = error.
          # No jq in nixos/nix — the raw output is a JSON array, embed it verbatim
          # (app/store-path values are shell-safe: no quotes/backslashes possible).
          if [ "${rc}" = 0 ] || [ "${rc}" = 2 ]; then
            printf "{\"app\":\"%s\",\"status\":\"ok\",\"store_path\":\"%s\",\"findings\":%s}\n" \
              "${app}" "${sp}" "$(cat "/out/${app}.raw.json")" > "/out/${app}.vulnix.json"
            rm -f "/out/${app}.raw.json" "/out/${app}.err"
          else
            echo "{\"app\":\"${app}\",\"status\":\"vulnix-error-rc${rc}\"}" > "/out/${app}.vulnix.json"
            tail -3 "/out/${app}.err" >&2 || true
          fi
        done' || log "WARN vulnix container run failed (advisory — not fatal)"
  fi
fi

# ── report ────────────────────────────────────────────────────────────────────
# Zero rows despite attempted scans = every scan failed → an infra failure
# even if the per-scan bookkeeping somehow missed it.
attempted=$(( ${#apps[@]} + $([ -n "${FAT_IMG}" ] && echo 1 || echo 0) ))
rows_count="$(ls "${WORK}/rows/" 2>/dev/null | wc -l)"
if [ "${attempted}" -gt 0 ] && [ "${rows_count}" -eq 0 ]; then
  failed+=("no-result-rows")
fi
VULNIX_VER="$(cat "${VULNIX_DIR}/vulnix-version.txt" 2>/dev/null || echo n/a)"
jq -s --arg syft "${SYFT_VERSION}" --arg grype "${GRYPE_VERSION}" \
      --arg vulnix "${VULNIX_VER}" \
      --arg db_built "${DB_BUILT}" --arg sha "${CI_COMMIT_SHA:-}" \
      --arg vex_file "$([ -f "${VEX_FILE}" ] && basename "${VEX_FILE}" || echo "")" \
      --argjson vex_rules "${VEX_RULES}" \
      --argjson failed "$(printf '%s\n' "${failed[@]:-}" | jq -R . | jq -s 'map(select(length>0))')" \
      --argjson not_built "$(printf '%s\n' "${missing_requested[@]:-}" | jq -R . | jq -s 'map(select(length>0))')" \
      '{scanners:{syft:$syft,grype:$grype,vulnix:$vulnix,grype_db_built:$db_built},
        vex:{file:$vex_file,rules:$vex_rules},
        commit:$sha, failed:$failed, not_built:$not_built, images:.}' \
      "${WORK}/rows/"*.json > "${OUT_DIR}/nix-scan-report.json" 2>/dev/null \
  || echo "{\"images\":[],\"failed\":$(printf '%s\n' "${failed[@]:-}" | jq -R . | jq -s 'map(select(length>0))')}" \
       > "${OUT_DIR}/nix-scan-report.json"
{
  echo "# L3 nix scan — report-only"
  echo
  echo "syft ${SYFT_VERSION} · grype ${GRYPE_VERSION} (DB built ${DB_BUILT}) · VEX rules: ${VEX_RULES}"
  echo
  echo "| image | pkgs (nix) | CVEs | crit | fixed-crit | vexed |"
  echo "|---|---|---|---|---|---|"
  jq -r '.images[] | "| \(.name) | \(.packages.total) (\(.packages.nix)) | \(.cves.unique) | \(.cves.critical) | \(.cves.fixed_critical) | \(.cves.vexed // 0) |"' \
    "${OUT_DIR}/nix-scan-report.json"
  echo
  echo "Key: **pkgs (nix)** = catalogued packages (nix-store subset) · **CVEs** ="
  echo "unique CVE ids matched, all severities · **crit** = unique Critical-severity"
  echo "CVEs, fixable or not · **fixed-crit** = the subset of crit where the vuln DB"
  echo "records an upstream fixed version (Grype fix.state=fixed) — the actionable"
  echo "set a pin bump can remove, and the metric the future publication gate keys on."
  echo "**vexed** = unique CVE ids suppressed by the OpenVEX statement file"
  echo "(security/vex/kasm-nix.openvex.json — every suppression carries a written"
  echo "justification). CVEs/crit/fixed-crit are AFTER VEX suppression; the raw"
  echo "pre-VEX actionable count is kept as cves.fixed_critical_raw in the JSON."
  if [ "${#missing_requested[@]}" -gt 0 ]; then echo; echo "**Not built this run (unchanged):** ${missing_requested[*]}"; fi
  if [ "${#failed[@]}" -gt 0 ]; then echo; echo "**FAILED scans:** ${failed[*]}"; fi
} > "${OUT_DIR}/nix-scan-report.md"

if [ -n "${HOST_UID:-}" ]; then
  chown -R "${HOST_UID}:${HOST_GID:-$HOST_UID}" "${SBOM_DIR}" "${GRYPE_DIR}" "${VULNIX_DIR}" \
    "${OUT_DIR}/nix-scan-report.json" "${OUT_DIR}/nix-scan-report.md" 2>/dev/null || true
fi

log "done: scanned=$(jq '.images|length' "${OUT_DIR}/nix-scan-report.json") failed=${#failed[@]} ${failed[*]:-}"
cat "${OUT_DIR}/nix-scan-report.md"
# Report-only on findings; infra/scan errors fail the job.
[ "${#failed[@]}" -eq 0 ]
