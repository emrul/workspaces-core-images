#!/usr/bin/env bash
# nix-publish.sh — tag the per-app Nix images produced by
# `build-nix-store-volume --emit-app-images` (localhost/nix-<profile>:dev) to
# their Kasm-convention names and push them to the target registry namespace.
#
# Naming: the published image is <REGISTRY_NS>/<kasm_name>:<KASM_TAG>, where
# kasm_name comes from the `kasm_name = "..."` field of the profile in
# nix-profiles.toml (falling back to the profile name). This matches Kasm's
# Docker Hub names — e.g. profile `vscode` → `vs-code`, `onlyoffice` →
# `only-office`, `libreoffice` → `libre-office`, `torbrowser` → `tor-browser`.
#
# Registry migration is a one-variable change:
#   REGISTRY_NS=$CI_REGISTRY_IMAGE   → registry.gitlab.com/.../kasm-nix (now)
#   REGISTRY_NS=docker.io/kasmweb    → docker.io/kasmweb/<name>:nix    (later)
#
# Env:
#   REGISTRY_NS   target namespace (default: $CI_REGISTRY_IMAGE)
#   KASM_TAG      published tag (default: nix)
#   NIX_APP_REPO  local repo prefix from the build (default: localhost/nix)
#   CONFIG        path to nix-profiles.toml (default: ../bin/nix-profiles.toml)
#   DOCKER        container CLI (default: docker)
#   DRY_RUN       1 = print tags/pushes without executing
#   NIX_PROFILES  space list to publish only those profiles (change-gating);
#                 empty = publish every built image; "__none__" = publish nothing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CONFIG:-${SCRIPT_DIR}/../bin/nix-profiles.toml}"
REGISTRY_NS="${REGISTRY_NS:-${CI_REGISTRY_IMAGE:?set REGISTRY_NS or CI_REGISTRY_IMAGE}}"
KASM_TAG="${KASM_TAG:-nix}"
NIX_APP_REPO="${NIX_APP_REPO:-localhost/nix}"
# Resolute multi-store desktop images (nix-crane-assemble RESOLUTE_REPO); published
# to their kasm_name like any app (tracelabs → tracelabs-osint).
RESOLUTE_REPO="${RESOLUTE_REPO:-localhost/nix-resolute}"
DOCKER="${DOCKER:-docker}"
DRY_RUN="${DRY_RUN:-0}"

[[ -f "${CONFIG}" ]] || { echo "[nix-publish] config not found: ${CONFIG}" >&2; exit 1; }

# Change-gating: restrict to specific profiles, everything, or nothing.
FILTER="${NIX_PROFILES:-}"
if [[ "${FILTER}" == "__none__" ]]; then
  echo "[nix-publish] NIX_PROFILES=__none__ — nothing to publish"; exit 0
fi
in_filter() {  # $1=profile → 0 if it should be published
  [[ -z "${FILTER}" ]] && return 0
  local x; for x in ${FILTER}; do [[ "${x}" == "$1" ]] && return 0; done; return 1
}

# profile -> kasm_name (kasm_name overrides; default = profile name).
kasm_name_for() {
  awk -v want="$1" '
    /^\[profiles\./ { cur=$0; sub(/^\[profiles\./,"",cur); sub(/\].*/,"",cur); name[cur]=cur }
    /^[[:space:]]*kasm_name[[:space:]]*=/ && cur!="" {
      v=$0; sub(/^[^"]*"/,"",v); sub(/".*/,"",v); name[cur]=v
    }
    END { print (want in name) ? name[want] : want }
  ' "${CONFIG}"
}

run() { if [[ "${DRY_RUN}" == 1 ]]; then echo "  DRY: $*"; else "$@"; fi; }

# ── build-run report ─────────────────────────────────────────────────────────
# Emits nix-build-report.{json,md} classifying each image new|updated|unchanged
# |failed|skipped, by comparing THIS build's dev.kasm.nix.store-path label (on
# the local image) to the currently-published image's same label (read from the
# registry with no layer pull). Folds in the build-side sidecars written to
# REPORT_DIR by the build stage (labels.json, closure-diffs.tsv, metrics.json).
# Must match dind-build.sh's OUT: same cache, same reason for $HOME over /root.
REPORT_DIR="${REPORT_DIR:-${XDG_CACHE_HOME:-${HOME:-/root}/.cache}/nix-build-output}"
RESULTS="${REPORT_DIR}/publish-results.tsv"        # profile\tkasm\tdest\tstatus\taction\trev\tver\tnewSP\tprevSP\tcandCfg\tmanifest\tremoteCfg\tequivBasis
mkdir -p "${REPORT_DIR}" 2>/dev/null || true
# Fall back to a temp dir if the output mount isn't writable (standalone runs),
# so a report-dir hiccup can never abort the publish under set -e.
if ! : > "${RESULTS}" 2>/dev/null; then
  REPORT_DIR="$(mktemp -d 2>/dev/null || echo /tmp)"
  RESULTS="${REPORT_DIR}/publish-results.tsv"; : > "${RESULTS}"
  echo "[nix-publish] output dir not writable — report → ${REPORT_DIR}" >&2
fi

# Read one label off a LOCAL image (podman/docker present) or a REMOTE ref
# (skopeo; absent → empty, handled gracefully). Go templates → no jq needed.
local_label()  { "${DOCKER}" image inspect --format "{{ index .Config.Labels \"$2\" }}" "$1" 2>/dev/null || true; }
remote_label() { command -v skopeo >/dev/null 2>&1 && skopeo inspect --format "{{ index .Labels \"$2\" }}" "docker://$1" 2>/dev/null || true; }

# Publication-mapping digests (design review round 5): scan-nix runs
# concurrently with publish and only ever describes the local candidate
# build, so THIS script is the sole source of truth for what actually
# landed on the registry. Every row records:
#   candidateConfigDigest  the local image ID (config digest) — the join key
#                          back to the scan row's artifact.config_digest
#   manifestDigest         the registry manifest digest (pushed: from
#                          podman push --digestfile; content-identical skip:
#                          resolved from the registry)
#   remoteConfigDigest     the registry image's config digest (skip rows —
#                          labels differ from the candidate even when the
#                          rootfs is identical)
#   equivalenceBasis       "pushed" (exact artifact) | "rootfs.diff_ids"
#                          (content-identical skip) | "" (not published:
#                          filtered out, failed, or partial)
# Consumers (sbom-publish, security page, the remediator) promote a scan
# row to "published" ONLY via this mapping — never from scan-side intent.
local_config_digest()    { "${DOCKER}" image inspect --format '{{.Id}}' "$1" 2>/dev/null || true; }
# Publish an image INDEX, not a bare manifest.
#
# A bare `podman push` of a single-arch image publishes
# application/vnd.oci.image.manifest.v1+json, which carries NO platform
# descriptor — architecture exists only inside the config blob. Clients that
# select a platform BEFORE pulling therefore cannot tell the image is amd64
# only: an arm64 host pulls it and dies at runtime with "exec format error"
# instead of failing fast, and `docker buildx imagetools inspect` shows no
# Platform line at all. Wrapping the manifest in an index
# (application/vnd.oci.image.index.v1+json) with one linux/amd64 descriptor
# makes the image self-describing. Adding arm64 later is one more
# `manifest add` against the same list — the shape does not change again.
#
# The recorded digest becomes the INDEX digest, which is what the tag resolves
# to and therefore what cosign attests/signs and what consumers verify.
# A registry push streams gigabytes of blobs over a long-lived HTTPS PATCH, so a
# single dropped TCP connection anywhere across ~36 apps used to fail the whole
# job — and with it sbom-publish, security-page and assess, which is how the
# remediator loses its assessment envelope. Observed 2026-07-29 (pipeline
# 2714340414): 35 of 36 pushed, inkscape died on
#   writing blob: Patch ".../blobs/uploads/...": use of closed network connection
# and the next app pushed fine on the same code path. Transient, so retry it.
# PUSH_ATTEMPTS=1 restores the old fail-fast behaviour.
# push_err carries the last failure's tail so the JUnit report can name a cause
# instead of just "failed". Output is TEE'd, not captured: a push moves gigabytes
# and swallowing its progress would leave the job silent for minutes, which is
# exactly the shape of the dind-run hang we just spent an afternoon on.
push_err=""
push_with_retry() { # $1=description $2...=command → sets $push_err on failure
  local what="$1"; shift
  if [[ "${DRY_RUN}" == 1 ]]; then echo "  DRY: $*"; push_err=""; return 0; fi
  local attempts="${PUSH_ATTEMPTS:-3}" n=1 rc log
  log="$(mktemp)"
  while :; do
    "$@" 2>&1 | tee "${log}"
    rc="${PIPESTATUS[0]}"
    if [ "${rc}" -eq 0 ]; then
      [ "${n}" -gt 1 ] && echo "[nix-publish] ${what}: succeeded on attempt ${n}"
      push_err=""; rm -f "${log}"; return 0
    fi
    # Keep the tail only — a full push log is megabytes and would bloat the XML.
    push_err="$(grep -iE 'error|fatal|denied|refused|timeout|EOF' "${log}" | tail -3)"
    [ -n "${push_err}" ] || push_err="$(tail -3 "${log}")"
    if [ "${n}" -ge "${attempts}" ]; then
      echo "[nix-publish] ${what}: FAILED after ${n} attempt(s) (rc=${rc})" >&2
      rm -f "${log}"; return 1
    fi
    echo "[nix-publish] ${what}: attempt ${n}/${attempts} failed (rc=${rc}), retrying in $((n*10))s" >&2
    sleep $((n*10))
    n=$((n+1))
  done
}

push_dig=""
# An index descriptor is copied from the image CONFIG, so an image whose config
# has no architecture publishes an index that matches no platform at all, and
# containerd rejects it before fetching a byte:
#   no match for platform in manifest: not found
# The tag then points at intact-but-unpullable data, and nothing in this job
# notices — `buildx imagetools create` and `podman manifest add` both copy the
# empty value through without complaint, so the image ships broken and the
# failure surfaces on a user's cluster days later. That is exactly how
# nix-store:nix shipped (crane's --oci-empty-base leaves architecture:"").
# Refuse BEFORE the push: an unpullable tag is strictly worse than a red job,
# because publishing it also overwrites the last-known-good one.
assert_platform() { # $1=local image ref → 1 if the config declares no architecture
  # DRY_RUN never ran the `docker tag`, so there is no local image under the dest
  # name to inspect — an empty answer there means "not tagged", not "no platform".
  [[ "${DRY_RUN}" == 1 ]] && return 0
  local a; a="$("${DOCKER}" image inspect --format '{{.Architecture}}' "$1" 2>/dev/null || true)"
  if [[ -z "${a//[[:space:]]/}" ]]; then
    echo "[nix-publish] FATAL ${1}: image config declares no architecture." >&2
    echo "[nix-publish]   Publishing it would produce an index that matches no platform" >&2
    echo "[nix-publish]   and cannot be pulled. Fix the assembly (crane mutate --set-platform)" >&2
    echo "[nix-publish]   rather than shipping over the last-known-good tag." >&2
    push_err="image config declares no architecture (would publish an unpullable index)"
    return 1
  fi
  return 0
}
push_and_digest() { # $1=dest → sets $push_dig (index digest when available)
  push_dig=""
  assert_platform "$1" || return 1
  if [[ "${DOCKER}" == *podman* ]]; then
    local list="${1}-idx"
    "${DOCKER}" manifest rm "${list}" >/dev/null 2>&1 || true
    run "${DOCKER}" manifest create "${list}" || return 1
    run "${DOCKER}" manifest add "${list}" "containers-storage:${1}" || return 1
    push_with_retry "push ${1}" "${DOCKER}" manifest push --all \
      --digestfile "${REPORT_DIR}/.push-digest" "${list}" "docker://${1}" || return 1
    push_dig="$(cat "${REPORT_DIR}/.push-digest" 2>/dev/null || true)"; rm -f "${REPORT_DIR}/.push-digest"
    "${DOCKER}" manifest rm "${list}" >/dev/null 2>&1 || true
  else
    # docker: buildx imagetools can wrap an already-pushed manifest in an index.
    push_with_retry "push ${1}" "${DOCKER}" push "$1" || return 1
    if command -v docker >/dev/null 2>&1 && docker buildx version >/dev/null 2>&1; then
      run docker buildx imagetools create -t "$1" "$1" || return 1
    else
      echo "[nix-publish] WARN no buildx: ${1} published as a bare manifest (no platform descriptor)" >&2
    fi
  fi
}
have_imagetools() { command -v docker >/dev/null 2>&1 && docker buildx version >/dev/null 2>&1; }
remote_manifest_digest() { # $1=ref → index digest, or empty
  # skopeo first (the DinD image has it), then buildx imagetools. The docker-on-host
  # runner has NO skopeo and its sudo is nerdctl-scoped, so we cannot install one --
  # without this fallback every pushed image records an empty manifestDigest and
  # assess fail()s with "pushed but no manifest digest recorded or resolvable".
  if command -v skopeo >/dev/null 2>&1; then
    skopeo inspect --format '{{.Digest}}' "docker://$1" 2>/dev/null && return 0
  fi
  # NOT `--format '{{.Manifest.Digest}}'`: buildx 0.12 ignores that template and
  # prints its default human block. A manifest digest IS the sha256 of the raw
  # manifest bytes, so hash them -- true by definition, immune to output changes.
  have_imagetools || return 0
  local raw; raw="$(raw_manifest "$1")"; [[ -n "${raw}" ]] || return 0
  printf '%s' "${raw}" | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print "sha256:"$1}'
}

# An index has no .config and no rootfs — the platform child manifest does.
# Both equivalence helpers below MUST descend into it, or they silently return
# empty for every index-published image, content_state() can never say "same",
# and every profile re-pushes forever (losing the rootfs.diff_ids equivalence
# basis the assessment envelope records).
PUB_ARCH="${PUB_ARCH:-amd64}"
# Strip the TAG only. `${ref%%:*}` is wrong: it cuts at the first colon, which
# for registry:5000/app:nix yields "registry" and produced
# docker://127.0.0.1@sha256:… in the prototype. A colon is a tag separator only
# when it appears after the last slash.
repo_of() { # $1=ref → ref without its :tag
  local name="${1##*/}"
  if [[ "${name}" == *:* ]]; then echo "${1%:*}"; else echo "$1"; fi
}
raw_manifest() { # $1=ref → raw manifest/index JSON, or empty
  # One place that knows how to read a manifest, so child_ref and
  # remote_config_digest degrade together rather than one silently winning.
  if command -v skopeo >/dev/null 2>&1; then
    skopeo inspect --raw "docker://$1" 2>/dev/null || true
    return 0
  fi
  have_imagetools || return 0
  docker buildx imagetools inspect --raw "$1" 2>/dev/null || true
}
child_ref() { # $1=ref → ref pinned to the platform child, or $1 if not an index
  command -v jq >/dev/null 2>&1 || { echo "$1"; return; }
  local raw mt child
  raw="$(raw_manifest "$1")"
  [[ -z "${raw}" ]] && { echo "$1"; return; }
  mt="$(printf '%s' "${raw}" | jq -r '.mediaType // empty' 2>/dev/null || true)"
  case "${mt}" in
    *image.index.v1+json|*manifest.list.v2+json)
      child="$(printf '%s' "${raw}" | jq -r --arg a "${PUB_ARCH}" \
        '[.manifests[] | select(.platform.architecture==$a and (.platform.os=="linux"))][0].digest // empty' 2>/dev/null || true)"
      if [[ -n "${child}" ]]; then echo "$(repo_of "$1")@${child}"; else echo "$1"; fi ;;
    *) echo "$1" ;;
  esac
}
remote_config_digest() {
  command -v jq >/dev/null 2>&1 || return 0
  if command -v skopeo >/dev/null 2>&1; then
    skopeo inspect --raw "docker://$(child_ref "$1")" 2>/dev/null | jq -r '.config.digest // empty' 2>/dev/null || true
    return 0
  fi
  # Without this, every image reports status=new on the docker-on-host runner and
  # the content-identical skip can never fire -- we would re-push all 37 each run.
  raw_manifest "$(child_ref "$1")" | jq -r '.config.digest // empty' 2>/dev/null || true
}

# Classify by comparing published (prev) store-path to this build's (new).
# Used for the human REPORT (which packages moved); the PUSH decision uses
# layer-content comparison below (content_state) so it can't miss non-store
# changes (nix-launch in the base layer, per-app wiring).
classify() { # $1=prevSP $2=newSP → new|updated|unchanged
  if   [[ -z "$1" ]];      then echo new
  elif [[ "$1" == "$2" ]]; then echo unchanged
  else                          echo updated
  fi
}

# Uncompressed layer hashes (rootfs.diff_ids) are the image's true content
# fingerprint: any layer change — nix store, base layer (nix-launch et al.),
# or the per-app wiring layer — changes a diff_id, while churning config labels
# (built-at, revision) and ENV do NOT. Comparing them against the published
# image catches every content change the store-path label alone would miss
# (e.g. the edge --password-store fix baked into the base, 2026-07-17).
# ── uncompressed size ────────────────────────────────────────────────────────
# What the registry advertises per workspace (it published 0 for everything until
# this landed). The number comes from the dev.kasm.image.uncompressed-bytes label
# that bin/nix-crane-assemble stamps, summed from the uncompressed layer tars it
# assembled the image out of. The label travels with the artifact, so it also
# answers for images this run never rebuilt — readable off the registry, no pull.
#
# DO NOT substitute `image inspect --format {{.Size}}`. Under podman that is the
# sum of the COMPRESSED layer sizes: on the first build that shipped this label
# (pipeline 2782199084) angelfish's .Size was 2187740110 against a manifest layer
# sum of 2187727884 — a 12 KB gap, exactly the config blob. Preferring it there
# published compressed figures in a field named uncompressed, understating images
# by 1.6-2.5x (the fat store: 20.6 GB recorded for a 51.3 GB image). docker's
# .Size IS the uncompressed total, which is exactly why this looks safe and isn't.
#
# .Size is still useful as a LOWER BOUND — an uncompressed figure can never be
# smaller than a compressed one under either CLI — so it catches a bad sum in the
# assembler without being trusted as the answer.
LBL_SIZE="dev.kasm.image.uncompressed-bytes"
local_size() { "${DOCKER}" image inspect --format '{{.Size}}' "$1" 2>/dev/null || true; }
resolve_size() { # $1=local image ("" if none) $2=remote ref → bytes, or empty
  local loc="" lbl=""
  if [[ -n "$1" ]]; then
    lbl="$(local_label "$1" "${LBL_SIZE}")"
    loc="$(local_size "$1")"
  fi
  # Not stamped locally (or no local image at all) → the published image's label.
  [[ "${lbl}" =~ ^[0-9]+$ ]] || lbl="$(remote_label "$2" "${LBL_SIZE}")"
  if [[ "${lbl}" =~ ^[0-9]+$ ]]; then
    if [[ "${loc}" =~ ^[0-9]+$ ]] && [[ "${lbl}" -lt "${loc}" ]]; then
      echo "[nix-publish] WARN $1: ${LBL_SIZE}=${lbl} is BELOW .Size=${loc} — an uncompressed" \
           "size cannot be smaller than a compressed one; the assembler's sum is wrong" >&2
    fi
    printf '%s' "${lbl}"; return 0
  fi
  # No label anywhere. Deliberately NOT falling back to .Size: under podman that
  # would silently publish a compressed number as an uncompressed one.
  [[ -n "$1" ]] && \
    echo "[nix-publish] WARN $1: no ${LBL_SIZE} label — recording no size (refusing to" \
         "substitute .Size, which is compressed under podman)" >&2
  return 0
}

# ── distro base/desktop sizes (kasm-core-*) ──────────────────────────────────
# The four distro desktop workspaces (Nix Alpine/Fedora/Ubuntu-Noble/Resolute)
# advertised 0 MB even after the app catalogue was fixed, because they are a
# different path end to end: built by nix-base-build.sh with `podman build` from
# the dockerfiles and pushed by nix-publish-base.sh, so they never pass through
# nix-crane-assemble (no staged layer tars to sum) and never appear here.
#
# They are measured, not labelled, and reported in a SIDECAR rather than in
# nix-build-report.json. Both are deliberate:
#
#   No label. Stamping one means rebuilding the base image to change its config,
#   which changes its image ID — and nix-crane-assemble reads
#   org.opencontainers.image.base.digest off APP_BASE_IMAGE while
#   nix-base-check.sh compares source-image digests for staleness. Risking that
#   provenance chain to record a number is a bad trade.
#
#   No report rows. assess joins scan rows against this report's publication
#   mapping and FAILS on an unmapped row or a published occurrence with no
#   verified attestation. Base images have neither a scan row nor an attestation
#   here, so adding them would break the assessment envelope.
#
# Measured by exporting the flattened rootfs of a throwaway container. NOT
# `.Size`: for a registry-pulled image podman reports the COMPRESSED total (see
# the note above), and for a locally BUILT image the semantics are simply not
# documented — so measure rather than ask. Cached per image ID, because an export
# streams the whole rootfs and these bases change rarely.
BASE_SIZES_JSON="${REPORT_DIR}/nix-base-sizes.json"
image_uncompressed_local() { # $1=local image ref → bytes, or empty
  local c n
  c="$("${DOCKER}" create "$1" /bin/true 2>/dev/null)" || return 0
  [[ -n "${c}" ]] || return 0
  n="$("${DOCKER}" export "${c}" 2>/dev/null | wc -c | tr -d ' ')"
  "${DOCKER}" rm -f "${c}" >/dev/null 2>&1 || true
  [[ "${n}" =~ ^[0-9]+$ ]] && [[ "${n}" -gt 0 ]] && printf '%s' "${n}"
  return 0
}
base_size_cached() { # $1=local image ref → bytes, or empty
  local id cache n
  id="$("${DOCKER}" image inspect --format '{{.Id}}' "$1" 2>/dev/null || true)"
  [[ -n "${id}" ]] || return 0
  cache="${REPORT_DIR}/.base-size-${id//[^A-Za-z0-9]/_}"
  if [[ -s "${cache}" ]]; then cat "${cache}"; return 0; fi
  n="$(image_uncompressed_local "$1")"
  [[ -n "${n}" ]] || return 0
  printf '%s' "${n}" > "${cache}" 2>/dev/null || true
  printf '%s' "${n}"
}
# Emit {"schema":"kasm-nix-sizes/v1","images":{"<dest>":bytes}} — the same shape
# the registry already serves, so ci/merge-sizes.js consumes it with no new
# parsing. Absent images are simply omitted: the registry upserts, so a base we
# cannot measure keeps whatever it already advertises.
write_base_sizes() {
  local map="${SCRIPT_DIR}/nix-base-map.sh" first=1 local_img repo dest n
  [[ -f "${map}" ]] || { echo "[nix-publish] WARN ${map} missing — no base sizes reported" >&2; return 0; }
  # shellcheck source=ci-scripts/nix-base-map.sh
  . "${map}"
  { printf '{\n  "schema": "kasm-nix-sizes/v1",\n  "images": {\n'
    while IFS='|' read -r local_img repo; do
      [[ -n "${local_img}" ]] || continue
      "${DOCKER}" image exists "${local_img}" 2>/dev/null \
        || "${DOCKER}" image inspect "${local_img}" >/dev/null 2>&1 \
        || { echo "[nix-publish] base ${repo}: local image absent — size not reported" >&2; continue; }
      n="$(base_size_cached "${local_img}")"
      if [[ -z "${n}" ]]; then
        echo "[nix-publish] base ${repo}: WARN could not measure ${local_img} — size not reported" >&2
        continue
      fi
      dest="${REGISTRY_NS}/${repo}:${KASM_TAG}"
      [[ "${first}" -eq 1 ]] || printf ',\n'
      printf '    "%s": %s' "${dest}" "${n}"
      first=0
      echo "[nix-publish] base ${repo}: ${n} bytes (~$(( n / 1000000 )) MB)" >&2
    done <<EOF
${NIX_BASES_MAP}
EOF
    printf '\n  }\n}\n'
  } > "${BASE_SIZES_JSON}"
  echo "[nix-publish] wrote ${BASE_SIZES_JSON}"
}

local_diffids()  { "${DOCKER}" image inspect --format '{{json .RootFS.Layers}}' "$1" 2>/dev/null | tr -d ' ' || true; }
remote_diffids() { # config blob carries rootfs.diff_ids; needs skopeo+jq
  command -v skopeo >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
  # …and the config lives under the platform child when the tag is an index.
  skopeo inspect --config "docker://$(child_ref "$1")" 2>/dev/null | jq -c '.rootfs.diff_ids' 2>/dev/null || true
}
# → same | changed | new | unknown  (unknown/new/changed all push; only same skips)
content_state() { # $1=local-img $2=remote-ref
  local lo re
  lo="$(local_diffids "$1")"
  [[ -z "${lo}" || "${lo}" == "null" ]] && { echo unknown; return; }
  re="$(remote_diffids "$2")"
  [[ -z "${re}" ]]        && { echo unknown; return; }   # no skopeo/jq → fail safe to push
  [[ "${re}" == "null" ]] && { echo new; return; }       # not yet published
  [[ "${lo}" == "${re}" ]] && echo same || echo changed
}

# record <profile> <kasm> <dest> <status> <action> <rev> <ver> <newSP> <prevSP> \
#        [candCfg] [manifestDigest] [remoteCfg] [equivBasis] [uncompressedBytes]
# (printf pads missing trailing args with empty fields — rows are always 14 cols)
record() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "${RESULTS}"; }

_pkg_install() { # $1 = package; best-effort across the common managers
  { command -v microdnf >/dev/null 2>&1 && microdnf install -y "$1" >/dev/null 2>&1; } \
    || { command -v dnf  >/dev/null 2>&1 && dnf  install -y "$1" >/dev/null 2>&1; } \
    || { command -v apk  >/dev/null 2>&1 && apk  add --no-cache "$1" >/dev/null 2>&1; } \
    || { command -v apt-get >/dev/null 2>&1 && apt-get update >/dev/null 2>&1 && apt-get install -y "$1" >/dev/null 2>&1; }
}
ensure_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  echo "[nix-publish] jq not found — attempting install" >&2
  _pkg_install jq; command -v jq >/dev/null 2>&1
}
# skopeo reads the PREVIOUS published image's labels (registry truth, no layer
# pull) so status can be updated/unchanged rather than always new. It is NOT in
# quay.io/podman/stable, so install it; it shares podman's login/auth file.
ensure_skopeo() {
  command -v skopeo >/dev/null 2>&1 && return 0
  echo "[nix-publish] skopeo not found — attempting install (needed for cross-run status)" >&2
  _pkg_install skopeo; command -v skopeo >/dev/null 2>&1
}

# Markdown summary — no jq (metrics scraped from flat JSON with sed).
gen_md() {
  local md="${REPORT_DIR}/nix-build-report.md" m="${REPORT_DIR}/metrics.json"
  local dur="?" dc="?"
  if [[ -f "${m}" ]]; then
    dur="$(sed -n 's/.*"durationSec": *\([0-9-]*\).*/\1/p' "${m}" | head -1)"
    dc="$( sed -n 's/.*"diskConsumedG": *\([0-9-]*\).*/\1/p' "${m}" | head -1)"
  fi
  {
    echo "# Nix build report"
    echo
    echo "- commit: \`${CI_COMMIT_SHA:-unknown}\`"
    echo "- scope: \`${NIX_PROFILES:-<all>}\`  · base-affected: \`${NIX_BASE_AFFECTED:-?}\`"
    echo "- build: ${dur:-?}s · disk consumed ${dc:-?} G"
    echo
    echo "| Image | Status | Version | Action | Uncompressed |"
    echo "|-------|--------|---------|--------|--------------|"
    # awk (not `read`): TSV fields can be empty, and read's whitespace IFS would
    # collapse an empty column and shift the rest (e.g. version→store-path).
    # Cols: 1 profile 2 kasm 3 dest 4 status 5 action 6 rev 7 version 8 newSP
    #       9 prevSP … 14 uncompressedBytes
    # MB with the same /1e6 divisor the registry publishes, so this table and the
    # site agree; en-dash where this run had no trustworthy number.
    awk -F'\t' 'NF{v=($7==""?"–":$7);
                   s=($14==""?"–":sprintf("%d MB", int($14/1000000)));
                   printf "| `%s` | %s | %s | %s | %s |\n", $2, $4, v, $5, s}' "${RESULTS}"
    if [[ -s "${REPORT_DIR}/closure-diffs.tsv" ]]; then
      echo; echo "## Changed closures (vs previous build)"
      # Cols: 1 app 2 status 3 prevSP 4 newSP 5 detail ("; "-joined)
      awk -F'\t' '$2=="changed" && $5!=""{gsub(/; /,"\n",$5); printf "\n### %s\n```\n%s\n```\n", $1, $5}' \
        "${REPORT_DIR}/closure-diffs.tsv"
    fi
  } > "${md}"
  echo "[nix-publish] wrote ${md}"
}

# Structured JSON — merges publish results + build sidecars (needs jq).
gen_json() {
  ensure_jq || { echo "[nix-publish] WARN jq unavailable — JSON report skipped (md written)" >&2; return 0; }
  local json="${REPORT_DIR}/nix-build-report.json"
  local diffs="${REPORT_DIR}/closure-diffs.json"; [[ -f "${diffs}" ]]   || echo '{}' > "${diffs}"
  local metrics="${REPORT_DIR}/metrics.json";     [[ -f "${metrics}" ]] || echo '{}' > "${metrics}"
  local labels="${REPORT_DIR}/labels.json";       [[ -f "${labels}" ]]  || echo '{}' > "${labels}"
  jq -n \
    --slurpfile diff "${diffs}" --slurpfile metrics "${metrics}" --slurpfile labels "${labels}" \
    --arg gitSha "${CI_COMMIT_SHA:-unknown}" --arg scope "${NIX_PROFILES:-}" \
    --arg baseAffected "${NIX_BASE_AFFECTED:-}" \
    --arg pipelineId "${CI_PIPELINE_ID:-}" --arg jobId "${CI_JOB_ID:-}" \
    --rawfile results "${RESULTS}" \
    '($diff[0]//{}) as $D | ($labels[0]//{}) as $L |
     ($results | split("\n") | map(select(length>0)|split("\t"))
       | map({profile:.[0], kasmName:.[1], dest:.[2], status:.[3], action:.[4],
              rev:.[5], version:.[6], storePath:.[7], prevStorePath:.[8],
              candidateConfigDigest:(.[9] // ""), manifestDigest:(.[10] // ""),
              remoteConfigDigest:(.[11] // ""), equivalenceBasis:(.[12] // ""),
              uncompressedBytes:((.[13] // "") | if . == "" then null else tonumber end),
              changedPackages: ($D[.[0]].detail // null)})) as $imgs |
     {run:{gitSha:$gitSha, baseRef:($L.base.ref//null), baseRev:($L.base.rev//null),
           scope:$scope, baseAffected:$baseAffected,
           pipelineId:$pipelineId, jobId:$jobId, metrics:($metrics[0]//{})},
      images:$imgs,
      summary:($imgs|group_by(.status)|map({key:.[0].status,value:length})|from_entries)}' \
    > "${json}" && echo "[nix-publish] wrote ${json}"
}

generate_report() { gen_md; gen_json; }

# All per-app images from the build: localhost/nix-<profile>:dev, excluding
# EVERY distro base (nix-ubuntu*, nix-fedora, nix-alpine — published separately
# by nix-publish-base under their kasm-core-* names), the fat store (nix-store*),
# and the resolute multi-store desktop images (nix-resolute-<app>*, published
# below under their kasm_name by the dedicated resolute loop). The prune
# keep-list (dind-build.sh/nix-gc.sh) preserves the bases in the store, so an
# incomplete exclusion here republishes them as fake "apps" (seen as alpine:nix /
# fedora:nix — pipeline 2683070693; and resolute-tracelabs:nix, a phantom double
# of tracelabs-osint — pipeline 2696494819). NB the resolute exclusion relies on
# RESOLUTE_REPO sharing the NIX_APP_REPO prefix (localhost/nix-resolute vs
# localhost/nix); it is anchored to the "resolute-" segment so a real app whose
# name merely contains "resolute" is unaffected.
mapfile -t imgs < <(
  "${DOCKER}" images --format '{{.Repository}}:{{.Tag}}' \
    | grep -E "^${NIX_APP_REPO}-[a-z0-9][a-z0-9-]*:dev$" \
    | grep -vE "^${NIX_APP_REPO}-(ubuntu|store|fedora|alpine|resolute-)" \
    | sort -u
)

# Zero per-app images is a LEGITIMATE outcome, not an error: on a warm store
# the eval-gate keeps every profile and crane's CHANGED_ONLY assembles nothing
# (unchanged apps keep their published image). Fall through — the fat-store
# guard below still FATALs when the build stage produced no fat store either,
# which is the actual "build broke" signal.
if [[ ${#imgs[@]} -eq 0 ]]; then
  echo "[nix-publish] no ${NIX_APP_REPO}-<app>:dev images from this build — all apps unchanged; fat store + report only"
fi

echo "[nix-publish] ${#imgs[@]} image(s) → ${REGISTRY_NS}/<kasm_name>:${KASM_TAG}"

# Fat-store consistency guard (dedup safety). The fat store shares its base +
# shared layers with the per-app images BY DIGEST — but only if both are pushed
# from the SAME build. Push per-app images while the registry keeps an OLDER fat
# store and the fat store's base/shared layers no longer match, so cross-image
# dedup silently breaks (clients re-pull the whole base). So when
# PUBLISH_FAT_STORE=1 (default), refuse to push ANYTHING unless this build's fat
# store is present to push alongside. Set PUBLISH_FAT_STORE=0 to opt out.
if [[ "${PUBLISH_FAT_STORE:-1}" == "1" ]]; then
  fat_present="$("${DOCKER}" images --format '{{.Repository}}:{{.Tag}}' \
    | grep -E "^localhost/nix-store-(amd64|arm64):dev$" | head -1 || true)"
  if [[ -z "${fat_present}" ]]; then
    echo "[nix-publish] FATAL: PUBLISH_FAT_STORE=1 but no localhost/nix-store-<arch>:dev from this build." >&2
    echo "[nix-publish] Publishing per-app images without the matching fat store breaks registry layer dedup." >&2
    echo "[nix-publish] Re-run 'build' (it emits the fat store), or set PUBLISH_FAT_STORE=0 to opt out." >&2
    exit 1
  fi
fi

if ! ensure_skopeo; then
  if have_imagetools; then
    echo "[nix-publish] skopeo unavailable — using buildx imagetools for registry reads" >&2
  else
    echo "[nix-publish] WARN no skopeo and no buildx — every image will show status=new" >&2
  fi
fi
# jq is needed for the content-based push decision (remote rootfs.diff_ids);
# without it content_state returns 'unknown' and every app is re-pushed (safe,
# but loses the dedup skip). ensure it up front so the skip stays effective.
ensure_jq || echo "[nix-publish] WARN jq unavailable — content compare degraded; images may re-push" >&2

pushed=0; failed=()
# Per-profile failure reasons for the JUnit report. push_err is overwritten by
# the next push, so it is captured here at the moment of failure.
PUSH_ERRORS="${REPORT_DIR}/push-errors.tsv"; : > "${PUSH_ERRORS}" 2>/dev/null || PUSH_ERRORS=""
note_failure() { # $1=profile $2=reason
  [[ -n "${PUSH_ERRORS}" ]] || return 0
  printf '%s\t%s\n' "$1" "$(printf '%s' "${2:-no error output captured}" | tr '\n\t' '  ')" >> "${PUSH_ERRORS}"
}
# Publish one local image to its kasm-named registry ref with a content-based push
# skip. Shared by the per-app images and the resolute multi-store desktop images.
# Mutates the globals pushed/failed; every other var is local.
publish_one() {
  local img="$1" profile="$2"
  local kn dest new_sp new_rev new_ver cand_cfg prev_sp status_ cstate action usz
  kn="$(kasm_name_for "${profile}")"
  dest="${REGISTRY_NS}/${kn}:${KASM_TAG}"
  # Provenance from THIS build's local image (labels stamped by nix-crane-assemble).
  new_sp="$(local_label "${img}" dev.kasm.nix.store-path)"
  new_rev="$(local_label "${img}" dev.kasm.nix.rev)"
  new_ver="$(local_label "${img}" org.opencontainers.image.version)"
  cand_cfg="$(local_config_digest "${img}")"
  usz="$(resolve_size "${img}" "${dest}")"
  if ! in_filter "${profile}"; then
    echo "[nix-publish] ${profile}: skip (not in NIX_PROFILES)"
    record "${profile}" "${kn}" "${dest}" skipped skipped "${new_rev}" "${new_ver}" "${new_sp}" "" \
           "${cand_cfg}" "" "" "" "${usz}"
    return 0
  fi
  # Compare against the currently-published image BEFORE we overwrite it.
  prev_sp="$(remote_label "${dest}" dev.kasm.nix.store-path)"
  status_="$(classify "${prev_sp}" "${new_sp}")"   # report label (store-path move)
  # PUSH DECISION is content-based, not store-path-based: skip only when the
  # assembled image's layers are byte-identical to what's published. A store-
  # path match with different layers (nix-launch fix in the base, changed
  # per-app wiring) MUST still push — the old store-path-only skip silently
  # dropped those (edge --password-store, 2026-07-17). Re-pushing identical
  # content would only churn labels (every layer already dedups), so skip that.
  cstate="$(content_state "${img}" "${dest}")"
  if [[ "${cstate}" == "same" ]]; then
    echo "[nix-publish] ${profile} → ${dest}  [unchanged: layers identical] — skip push"
    # The registry keeps its older manifest (labels differ even when the
    # rootfs is identical) — record the REMOTE digests so consumers can
    # promote the candidate scan row to it under the stated equivalence.
    record "${profile}" "${kn}" "${dest}" unchanged skipped "${new_rev}" "${new_ver}" "${new_sp}" "${prev_sp}" \
           "${cand_cfg}" "$(remote_manifest_digest "${dest}")" "$(remote_config_digest "${dest}")" "rootfs.diff_ids" "${usz}"
    return 0
  fi
  # Layers differ but store-path matched ⇒ a wiring/base-layer change; surface
  # it as "updated" rather than the misleading "unchanged".
  [[ "${status_}" == "unchanged" ]] && status_=updated
  echo "[nix-publish] ${profile} → ${dest}  [${status_}: content ${cstate}]"
  if run "${DOCKER}" tag "${img}" "${dest}" && push_and_digest "${dest}"; then
    pushed=$((pushed+1)); action=pushed
    record "${profile}" "${kn}" "${dest}" "${status_}" "${action}" "${new_rev}" "${new_ver}" "${new_sp}" "${prev_sp}" \
           "${cand_cfg}" "${push_dig}" "" "pushed" "${usz}"
  else
    echo "[nix-publish] WARN push failed: ${profile}" >&2; failed+=("${profile}"); action=failed; status_=failed
    note_failure "${profile}" "${push_err}"
    # No size on a failed push: nothing new is on the registry, so the registry
    # must keep advertising whatever it already has rather than adopt this build's
    # number for an image nobody can pull.
    record "${profile}" "${kn}" "${dest}" "${status_}" "${action}" "${new_rev}" "${new_ver}" "${new_sp}" "${prev_sp}" \
           "${cand_cfg}" "" "" "" ""
  fi
}

for img in "${imgs[@]}"; do
  profile="${img#"${NIX_APP_REPO}"-}"; profile="${profile%:dev}"
  publish_one "${img}" "${profile}"
done

# Resolute multi-store desktop images (localhost/nix-resolute-<app>:dev) →
# ${REGISTRY_NS}/<kasm_name>:<tag> (e.g. tracelabs → tracelabs-osint). Same
# content-compare + record path; nix-crane-assemble stamps their provenance labels.
mapfile -t rimgs < <(
  "${DOCKER}" images --format '{{.Repository}}:{{.Tag}}' \
    | grep -E "^${RESOLUTE_REPO}-[a-z0-9][a-z0-9-]*:dev$" | sort -u
)
[[ ${#rimgs[@]} -gt 0 ]] && echo "[nix-publish] ${#rimgs[@]} resolute desktop image(s) → ${REGISTRY_NS}/<kasm_name>:${KASM_TAG}"
for img in "${rimgs[@]:-}"; do
  [[ -n "${img}" ]] || continue
  profile="${img#"${RESOLUTE_REPO}"-}"; profile="${profile%:dev}"
  publish_one "${img}" "${profile}"
done

# Also publish the fat store-mount image (all profiles' Nix store in shared
# layers). Registry entry is marked enabled:false — it's for pre-caching the
# shared layers / runtime app-selection, not a runnable single-app workspace.
# DEFAULT ON (PUBLISH_FAT_STORE=1): the fat store MUST be published from the same
# build as the per-app images, or its store-partition layers drift and share
# nothing with them on the registry (see design/nix-dedup-gap.md). Set
# PUBLISH_FAT_STORE=0 to opt out. Image name is nix-store:<tag>.
if [[ "${PUBLISH_FAT_STORE:-1}" == "1" ]]; then
  fat_local="$("${DOCKER}" images --format '{{.Repository}}:{{.Tag}}' \
    | grep -E "^localhost/nix-store-(amd64|arm64):dev$" | sort -u | head -1)"
  if [[ -n "${fat_local}" ]]; then
    fat_dest="${REGISTRY_NS}/nix-store:${KASM_TAG}"
    # COMPLETENESS GUARD: a profile-scoped build (--profile via NIX_PROFILES)
    # stages ONLY the selected profiles, so its fat store is PARTIAL. Pushing
    # that overwrites the registry's full-catalog fat store — fat-store
    # desktops image-mount nix-store:<tag> and would lose every other app
    # (this happened 2026-07-18; two chrome-only pipelines shipped a
    # chrome-only fat store). Completeness signal: the build sidecar
    # labels.json lists every app staged into THIS build (the profile-refs
    # image label is NOT that — it only lists apps with explicit ref pins,
    # 12 of 47, which made the first guard skip a genuinely-full fat store).
    # Missing/unparsable sidecar → treated as partial (fail closed): keep the
    # last-known-good tag and record `skipped-partial`.
    # FORCE_FAT_PUSH=1 overrides (e.g. intentionally shrinking the catalog).
    fat_profiles="$(jq -r '.apps | keys[]' "${REPORT_DIR}/labels.json" 2>/dev/null | sort)"
    # EXCLUDE fat_store=false profiles (resolute desktop bundles like tracelabs):
    # they are DELIBERATELY absent from the fat store, so counting them as
    # "missing" would flag every full build as partial and skip the fat-store push.
    cfg_profiles="$(awk '
      /^\[profiles\./ { p=$0; sub(/^\[profiles\./,"",p); sub(/\].*/,"",p); keep[p]=1; ord[++n]=p }
      /^[[:space:]]*fat_store[[:space:]]*=[[:space:]]*false/ && p!="" { keep[p]=0 }
      END { for (i=1;i<=n;i++) if (keep[ord[i]]) print ord[i] }
    ' "${CONFIG}" | sort)"
    fat_missing="$(comm -23 <(printf '%s\n' "${cfg_profiles}") <(printf '%s\n' "${fat_profiles}") | tr '\n' ' ')"
    if [[ -n "${fat_missing// /}" && "${FORCE_FAT_PUSH:-0}" != "1" ]]; then
      echo "[nix-publish] SKIP fat store: PARTIAL build (missing: ${fat_missing})" >&2
      echo "[nix-publish]   registry keeps the last-known-good nix-store:${KASM_TAG};" >&2
      echo "[nix-publish]   run a full-catalog build to republish, or FORCE_FAT_PUSH=1 to override." >&2
      # Deliberately no size: a partial fat store is NOT what stays published, so
      # recording this build's (smaller) number would understate the live image.
      record "nix-store" "nix-store" "${fat_dest}" partial skipped-partial \
             "$(local_label "${fat_local}" dev.kasm.nix.base-rev)" "" "" "" "" "" "" "" ""
    else
    # Classify the fat store on its base-rev: "updated" = the base nixpkgs
    # commit moved (a world-rebuild); "unchanged" = base layers still dedupe.
    fnew="$(local_label "${fat_local}" dev.kasm.nix.base-rev)"
    fprev="$(remote_label "${fat_dest}" dev.kasm.nix.base-rev)"
    fstat="$(classify "${fprev}" "${fnew}")"
    fcfg="$(local_config_digest "${fat_local}")"
    fusz="$(resolve_size "${fat_local}" "${fat_dest}")"
    echo "[nix-publish] fat store: ${fat_local} → ${fat_dest}  [base ${fstat}]${fusz:+  uncompressed $(( fusz / 1000000 )) MB}"
    if run "${DOCKER}" tag "${fat_local}" "${fat_dest}" && push_and_digest "${fat_dest}"; then
      pushed=$((pushed+1)); faction=pushed; fbasis="pushed"
    else
      echo "[nix-publish] WARN fat store push failed" >&2; failed+=("nix-store"); faction=failed; fstat=failed
      note_failure "nix-store" "${push_err}"
      fbasis=""; push_dig=""; fusz=""
    fi
    record "nix-store" "nix-store" "${fat_dest}" "${fstat}" "${faction}" "${fnew}" "" "${fnew}" "${fprev}" \
           "${fcfg}" "${push_dig}" "" "${fbasis}" "${fusz}"
    fi
  else
    echo "[nix-publish] PUBLISH_FAT_STORE=1 but no localhost/nix-store-<arch>:dev found" >&2
  fi
fi

# JUnit report → GitLab's "Tests" tab (artifacts:reports:junit). One testcase per
# profile so a failure is a named, clickable row carrying the registry's own error
# text, instead of something you find by scrolling 20 minutes of push log.
# Every non-pushed outcome is a <skipped>, not a pass: a green row must mean
# "pushed", or a skip-everything run would read as a successful publish.
write_junit() {
  local xml="${REPORT_DIR}/publish-junit.xml"
  [[ -s "${RESULTS}" ]] || return 0
  local total=0 nfail=0 nskip=0
  # Attribute values are XML-escaped; & first, or it would re-escape the others.
  esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
  local body="" profile kn dest status_ action reason
  while IFS=$'\t' read -r profile kn dest status_ action _; do
    [[ -n "${profile}" ]] || continue
    total=$((total+1))
    case "${action}" in
      pushed)
        body+="    <testcase classname=\"nix-publish\" name=\"$(esc "${profile}") → $(esc "${dest}")\"/>"$'\n' ;;
      failed)
        nfail=$((nfail+1))
        reason=""
        [[ -n "${PUSH_ERRORS}" && -f "${PUSH_ERRORS}" ]] && \
          reason="$(awk -F'\t' -v p="${profile}" '$1==p {print $2}' "${PUSH_ERRORS}" | tail -1)"
        [[ -n "${reason}" ]] || reason="push failed (no error output captured)"
        body+="    <testcase classname=\"nix-publish\" name=\"$(esc "${profile}") → $(esc "${dest}")\">"$'\n'
        body+="      <failure message=\"$(esc "${reason}")\" type=\"push-failed\">$(esc "push to ${dest} failed after ${PUSH_ATTEMPTS:-3} attempt(s):
${reason}")</failure>"$'\n'
        body+="    </testcase>"$'\n' ;;
      *)
        nskip=$((nskip+1))
        body+="    <testcase classname=\"nix-publish\" name=\"$(esc "${profile}") → $(esc "${dest}")\">"$'\n'
        body+="      <skipped message=\"$(esc "${action:-skipped}") ($(esc "${status_}"))\"/>"$'\n'
        body+="    </testcase>"$'\n' ;;
    esac
  done < "${RESULTS}"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<testsuites>'
    printf '  <testsuite name="nix-publish" tests="%s" failures="%s" skipped="%s">\n' \
      "${total}" "${nfail}" "${nskip}"
    printf '%s' "${body}"
    echo '  </testsuite>'
    echo '</testsuites>'
  } > "${xml}"
  echo "[nix-publish] junit → ${xml} (${total} cases, ${nfail} failed, ${nskip} skipped)"
}

# Consolidated build-run report (never fails the publish result).
generate_report || echo "[nix-publish] WARN report generation failed" >&2
write_junit     || echo "[nix-publish] WARN junit generation failed" >&2
# Distro base/desktop sizes for the registry (sidecar; see the note above).
write_base_sizes || echo "[nix-publish] WARN base size sidecar failed" >&2

echo "[nix-publish] done: pushed=${pushed} failed=${#failed[@]} ${failed[*]:-}"
[[ ${#failed[@]} -eq 0 ]]
