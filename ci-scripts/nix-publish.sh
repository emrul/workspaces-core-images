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
REPORT_DIR="${REPORT_DIR:-/root/.cache/nix-build-output}"
RESULTS="${REPORT_DIR}/publish-results.tsv"        # profile\tkasm\tdest\tstatus\taction\trev\tver\tnewSP\tprevSP
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
local_diffids()  { "${DOCKER}" image inspect --format '{{json .RootFS.Layers}}' "$1" 2>/dev/null | tr -d ' ' || true; }
remote_diffids() { # config blob carries rootfs.diff_ids; needs skopeo+jq
  command -v skopeo >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
  skopeo inspect --config "docker://$1" 2>/dev/null | jq -c '.rootfs.diff_ids' 2>/dev/null || true
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

# record <profile> <kasm> <dest> <status> <action> <rev> <ver> <newSP> <prevSP>
record() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "${RESULTS}"; }

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
    echo "| Image | Status | Version | Action |"
    echo "|-------|--------|---------|--------|"
    # awk (not `read`): TSV fields can be empty, and read's whitespace IFS would
    # collapse an empty column and shift the rest (e.g. version→store-path).
    # Cols: 1 profile 2 kasm 3 dest 4 status 5 action 6 rev 7 version 8 newSP 9 prevSP
    awk -F'\t' 'NF{v=($7==""?"–":$7); printf "| `%s` | %s | %s | %s |\n", $2, $4, v, $5}' "${RESULTS}"
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
    --rawfile results "${RESULTS}" \
    '($diff[0]//{}) as $D | ($labels[0]//{}) as $L |
     ($results | split("\n") | map(select(length>0)|split("\t"))
       | map({profile:.[0], kasmName:.[1], dest:.[2], status:.[3], action:.[4],
              rev:.[5], version:.[6], storePath:.[7], prevStorePath:.[8],
              changedPackages: ($D[.[0]].detail // null)})) as $imgs |
     {run:{gitSha:$gitSha, baseRef:($L.base.ref//null), baseRev:($L.base.rev//null),
           scope:$scope, baseAffected:$baseAffected, metrics:($metrics[0]//{})},
      images:$imgs,
      summary:($imgs|group_by(.status)|map({key:.[0].status,value:length})|from_entries)}' \
    > "${json}" && echo "[nix-publish] wrote ${json}"
}

generate_report() { gen_md; gen_json; }

# All per-app images from the build: localhost/nix-<profile>:dev, excluding
# EVERY distro base (nix-ubuntu*, nix-fedora, nix-alpine — published separately
# by nix-publish-base under their kasm-core-* names) and the fat store
# (nix-store*). The prune keep-list (dind-build.sh/nix-gc.sh) preserves the
# bases in the store, so an incomplete exclusion here republishes them as fake
# "apps" (seen as alpine:nix / fedora:nix — pipeline 2683070693).
mapfile -t imgs < <(
  "${DOCKER}" images --format '{{.Repository}}:{{.Tag}}' \
    | grep -E "^${NIX_APP_REPO}-[a-z0-9][a-z0-9-]*:dev$" \
    | grep -vE "^${NIX_APP_REPO}-(ubuntu|store|fedora|alpine)" \
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

ensure_skopeo || echo "[nix-publish] WARN skopeo unavailable — every image will show status=new" >&2
# jq is needed for the content-based push decision (remote rootfs.diff_ids);
# without it content_state returns 'unknown' and every app is re-pushed (safe,
# but loses the dedup skip). ensure it up front so the skip stays effective.
ensure_jq || echo "[nix-publish] WARN jq unavailable — content compare degraded; images may re-push" >&2

pushed=0; failed=()
for img in "${imgs[@]}"; do
  profile="${img#"${NIX_APP_REPO}"-}"; profile="${profile%:dev}"
  kn="$(kasm_name_for "${profile}")"
  dest="${REGISTRY_NS}/${kn}:${KASM_TAG}"
  # Provenance from THIS build's local image (labels stamped by nix-crane-assemble).
  new_sp="$(local_label "${img}" dev.kasm.nix.store-path)"
  new_rev="$(local_label "${img}" dev.kasm.nix.rev)"
  new_ver="$(local_label "${img}" org.opencontainers.image.version)"
  if ! in_filter "${profile}"; then
    echo "[nix-publish] ${profile}: skip (not in NIX_PROFILES)"
    record "${profile}" "${kn}" "${dest}" skipped skipped "${new_rev}" "${new_ver}" "${new_sp}" ""
    continue
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
    record "${profile}" "${kn}" "${dest}" unchanged skipped "${new_rev}" "${new_ver}" "${new_sp}" "${prev_sp}"
    continue
  fi
  # Layers differ but store-path matched ⇒ a wiring/base-layer change; surface
  # it as "updated" rather than the misleading "unchanged".
  [[ "${status_}" == "unchanged" ]] && status_=updated
  echo "[nix-publish] ${profile} → ${dest}  [${status_}: content ${cstate}]"
  if run "${DOCKER}" tag "${img}" "${dest}" && run "${DOCKER}" push "${dest}"; then
    pushed=$((pushed+1)); action=pushed
  else
    echo "[nix-publish] WARN push failed: ${profile}" >&2; failed+=("${profile}"); action=failed; status_=failed
  fi
  record "${profile}" "${kn}" "${dest}" "${status_}" "${action}" "${new_rev}" "${new_ver}" "${new_sp}" "${prev_sp}"
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
    cfg_profiles="$(grep -E '^\[profiles\.[a-z0-9-]+\]' "${CONFIG}" \
                     | sed -E 's/^\[profiles\.([a-z0-9-]+)\]/\1/' | sort)"
    fat_missing="$(comm -23 <(printf '%s\n' "${cfg_profiles}") <(printf '%s\n' "${fat_profiles}") | tr '\n' ' ')"
    if [[ -n "${fat_missing// /}" && "${FORCE_FAT_PUSH:-0}" != "1" ]]; then
      echo "[nix-publish] SKIP fat store: PARTIAL build (missing: ${fat_missing})" >&2
      echo "[nix-publish]   registry keeps the last-known-good nix-store:${KASM_TAG};" >&2
      echo "[nix-publish]   run a full-catalog build to republish, or FORCE_FAT_PUSH=1 to override." >&2
      record "nix-store" "nix-store" "${fat_dest}" partial skipped-partial \
             "$(local_label "${fat_local}" dev.kasm.nix.base-rev)" "" "" ""
    else
    # Classify the fat store on its base-rev: "updated" = the base nixpkgs
    # commit moved (a world-rebuild); "unchanged" = base layers still dedupe.
    fnew="$(local_label "${fat_local}" dev.kasm.nix.base-rev)"
    fprev="$(remote_label "${fat_dest}" dev.kasm.nix.base-rev)"
    fstat="$(classify "${fprev}" "${fnew}")"
    echo "[nix-publish] fat store: ${fat_local} → ${fat_dest}  [base ${fstat}]"
    if run "${DOCKER}" tag "${fat_local}" "${fat_dest}" && run "${DOCKER}" push "${fat_dest}"; then
      pushed=$((pushed+1)); faction=pushed
    else
      echo "[nix-publish] WARN fat store push failed" >&2; failed+=("nix-store"); faction=failed; fstat=failed
    fi
    record "nix-store" "nix-store" "${fat_dest}" "${fstat}" "${faction}" "${fnew}" "" "${fnew}" "${fprev}"
    fi
  else
    echo "[nix-publish] PUBLISH_FAT_STORE=1 but no localhost/nix-store-<arch>:dev found" >&2
  fi
fi

# Consolidated build-run report (never fails the publish result).
generate_report || echo "[nix-publish] WARN report generation failed" >&2

echo "[nix-publish] done: pushed=${pushed} failed=${#failed[@]} ${failed[*]:-}"
[[ ${#failed[@]} -eq 0 ]]
