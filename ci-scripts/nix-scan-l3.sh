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
#                  semantics as nix-publish.sh); "" = every built app image
#                  (capped, see SCAN_MAX_APPS); "__none__" = exit 0.
#   SCAN_MAX_APPS  cap on app scans for NIX_PROFILES="" runs (default 8).
#                  Truncation is LOGGED — the fat store still L3-covers the
#                  union of all apps' store paths, so nothing is silently
#                  unscanned at the store-path level.
#   NIX_APP_REPO   local repo prefix (default localhost/nix)
#   ARCH           amd64|arm64 (default: uname -m mapping)
#   OUT_DIR        artifact dir (default /artifacts)
#   DOCKER         container CLI (default podman)
#   PARALLEL       concurrent app scans (default 2)
#   SKIP_VULNIX    1 = skip the advisory vulnix pass
#   SYFT_VERSION / GRYPE_VERSION  pinned scanner releases
#   NIX_IMAGE      inner nix container (default docker.io/nixos/nix:2.28.4)
#   HOST_UID/HOST_GID  chown artifacts back to the runner UID
set -euo pipefail

NIX_APP_REPO="${NIX_APP_REPO:-localhost/nix}"
DOCKER="${DOCKER:-podman}"
OUT_DIR="${OUT_DIR:-/artifacts}"
PARALLEL="${PARALLEL:-2}"
SCAN_MAX_APPS="${SCAN_MAX_APPS:-8}"
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
cleanup() { chmod -R u+w "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"; }
trap cleanup EXIT INT TERM

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

# ── target list: changed apps (or capped all) + fat store ────────────────────
in_filter() { [ -z "${FILTER}" ] && return 0; local x; for x in ${FILTER}; do [ "${x}" = "$1" ] && return 0; done; return 1; }
mapfile -t all_apps < <("${DOCKER}" images --format '{{.Repository}}:{{.Tag}}' \
  | grep -E "^${NIX_APP_REPO}-[a-z0-9][a-z0-9-]*:dev$" \
  | grep -vE "^${NIX_APP_REPO}-(ubuntu|store|fedora|alpine)" \
  | sed -E "s|^${NIX_APP_REPO}-||; s|:dev\$||" | sort)
apps=(); missing_requested=()
for a in "${all_apps[@]}"; do in_filter "${a}" && apps+=("${a}"); done
# Per-app :dev images are BUILD PRODUCTS — the eval-gate skips reassembling
# unchanged apps, so a requested profile with no image usually means "unchanged
# this run" (nix-publish.sh treats it the same way). Record it in the report
# (no silent skip) but do NOT fail: the fat store + the scheduled SBOM re-scan
# cover unchanged apps' store paths.
if [ -n "${FILTER}" ]; then
  for want in ${FILTER}; do
    found=0; for a in "${apps[@]}"; do [ "${a}" = "${want}" ] && found=1 && break; done
    if [ "${found}" = 0 ]; then
      log "WARN requested profile '${want}' has no ${NIX_APP_REPO}-${want}:dev image — not built this run (unchanged?)"
      missing_requested+=("${want}")
    fi
  done
fi
if [ -z "${FILTER}" ] && [ "${#apps[@]}" -gt "${SCAN_MAX_APPS}" ]; then
  log "CAP: ${#apps[@]} app images present, scanning first ${SCAN_MAX_APPS} per-app;"
  log "CAP: dropped: ${apps[*]:${SCAN_MAX_APPS}}"
  log "CAP: (fat store still covers the union; raise SCAN_MAX_APPS or set NIX_PROFILES to target)"
  apps=("${apps[@]:0:${SCAN_MAX_APPS}}")
fi
FAT_IMG="localhost/nix-store-${ARCH}:dev"
"${DOCKER}" image inspect "${FAT_IMG}" >/dev/null 2>&1 || FAT_IMG=""
log "scanning apps: ${apps[*]:-<none>}   fat store: ${FAT_IMG:-absent}"
if [ "${#apps[@]}" -eq 0 ] && [ -z "${FAT_IMG}" ] && [ "${#missing_requested[@]}" -eq 0 ]; then
  log "nothing to scan"; exit 0
fi

label() { "${DOCKER}" image inspect --format "{{ index .Config.Labels \"$2\" }}" "$1" 2>/dev/null || true; }

# ── one image: export → normalize → syft → grype → stats row ─────────────────
scan_one() {  # $1=name $2=image-ref $3=has-nix-symlinks(1|0)
  local name="$1" img="$2" symlinks="$3"
  local d="${WORK}/${name}" c
  mkdir -p "${d}/rootfs"
  c="$("${DOCKER}" create "${img}" true)" || return 1
  "${DOCKER}" export "${c}" | tar -C "${d}/rootfs" -xf - || { "${DOCKER}" rm "${c}" >/dev/null; return 1; }
  "${DOCKER}" rm "${c}" >/dev/null
  if [ "${symlinks}" = "1" ]; then rm -f "${d}/rootfs/nix/store" "${d}/rootfs/nix/var"; fi
  mkdir -p "${d}/rootfs/nix"
  mv "${d}/rootfs/store" "${d}/rootfs/nix/store"
  mv "${d}/rootfs/var"   "${d}/rootfs/nix/var"
  "${SYFT}" -q "dir:${d}/rootfs" \
      -o "syft-json=${d}/syft.json" \
      -o "cyclonedx-json=${SBOM_DIR}/${name}.cdx.json" || return 1
  "${GRYPE}" -q "sbom:${d}/syft.json" -o "json=${GRYPE_DIR}/${name}.grype.json" || return 1
  # stats row (dedup CVEs by id; severity sets are unique-by-id too)
  jq -n --arg name "${name}" \
        --arg image "${img}" \
        --arg image_id "$("${DOCKER}" image inspect --format '{{.Id}}' "${img}")" \
        --arg store_path "$(label "${img}" dev.kasm.nix.store-path)" \
        --arg rev "$(label "${img}" dev.kasm.nix.rev)" \
        --argjson pkgs_total "$(jq '.artifacts|length' "${d}/syft.json")" \
        --argjson pkgs_nix   "$(jq '[.artifacts[]|select(.type=="nix")]|length' "${d}/syft.json")" \
        --argjson cves "$(jq '[.matches[].vulnerability.id]|unique|length' "${GRYPE_DIR}/${name}.grype.json")" \
        --argjson crit "$(jq '[.matches[]|select(.vulnerability.severity=="Critical").vulnerability.id]|unique|length' "${GRYPE_DIR}/${name}.grype.json")" \
        --argjson high "$(jq '[.matches[]|select(.vulnerability.severity=="High").vulnerability.id]|unique|length' "${GRYPE_DIR}/${name}.grype.json")" \
        --argjson fixed_crit "$(jq '[.matches[]|select(.vulnerability.severity=="Critical" and .vulnerability.fix.state=="fixed").vulnerability.id]|unique|length' "${GRYPE_DIR}/${name}.grype.json")" \
        '{name:$name,image:$image,image_id:$image_id,store_path:$store_path,rev:$rev,
          packages:{total:$pkgs_total,nix:$pkgs_nix},
          cves:{unique:$cves,critical:$crit,high:$high,fixed_critical:$fixed_crit}}' \
        > "${WORK}/rows/${name}.json" || return 1
  gzip -f "${SBOM_DIR}/${name}.cdx.json" "${GRYPE_DIR}/${name}.grype.json"
  chmod -R u+w "${d}"; rm -rf "${d}"
}

# ── bounded-parallel app scans ────────────────────────────────────────────────
failed=()
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
if [ "${SKIP_VULNIX}" != "1" ] && [ "${#apps[@]}" -gt 0 ]; then
  log "vulnix advisory pass (${#apps[@]} apps; staging volume nix-build-stage-${ARCH})"
  if ! "${DOCKER}" volume inspect "nix-build-stage-${ARCH}" >/dev/null 2>&1; then
    log "WARN staging volume absent — vulnix skipped (advisory only)"
  else
    "${DOCKER}" run --rm \
      -e NIX_CONFIG="experimental-features = nix-command flakes" \
      -e APPS="${apps[*]}" \
      -v "nix-build-stage-${ARCH}:/nix" \
      -v "${VULNIX_DIR}:/out" \
      "${NIX_IMAGE}" bash -c '
        set -u
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
          if nix run nixpkgs#vulnix -- --no-requisites --json ${reqs} > "/out/${app}.raw.json" 2>"/out/${app}.err"; then rc=0; else rc=$?; fi
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
jq -s --arg syft "${SYFT_VERSION}" --arg grype "${GRYPE_VERSION}" \
      --arg db_built "${DB_BUILT}" --arg sha "${CI_COMMIT_SHA:-}" \
      --argjson failed "$(printf '%s\n' "${failed[@]:-}" | jq -R . | jq -s 'map(select(length>0))')" \
      --argjson not_built "$(printf '%s\n' "${missing_requested[@]:-}" | jq -R . | jq -s 'map(select(length>0))')" \
      '{scanners:{syft:$syft,grype:$grype,grype_db_built:$db_built},
        commit:$sha, failed:$failed, not_built:$not_built, images:.}' \
      "${WORK}/rows/"*.json > "${OUT_DIR}/nix-scan-report.json" 2>/dev/null \
  || echo '{"images":[],"failed":["<no rows produced>"]}' > "${OUT_DIR}/nix-scan-report.json"
{
  echo "# L3 nix scan — report-only"
  echo
  echo "syft ${SYFT_VERSION} · grype ${GRYPE_VERSION} (DB built ${DB_BUILT})"
  echo
  echo "| image | pkgs (nix) | CVEs | crit | fixed-crit |"
  echo "|---|---|---|---|---|"
  jq -r '.images[] | "| \(.name) | \(.packages.total) (\(.packages.nix)) | \(.cves.unique) | \(.cves.critical) | \(.cves.fixed_critical) |"' \
    "${OUT_DIR}/nix-scan-report.json"
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
