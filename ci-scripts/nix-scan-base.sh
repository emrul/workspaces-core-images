#!/usr/bin/env bash
# nix-scan-base.sh — Trivy-scan the Nix base/core images built by the `base`
# stage, for OS-package CVEs. Runs INSIDE the forge DinD (quay.io/podman/stable)
# against the persistent podman store where nix-base-build.sh left the local
# `localhost/<base>:dev` images.
#
# Scope: covers layer L1 (distro base) + L2 (KasmVNC / upload / squid / … the
# Kasm core additions) — the nix bases ARE core-minimal + nix activation, and
# per-app images inherit this same OS layer (dockerfile-nix-app-finish is
# wiring-only). The fat store is FROM scratch (no OS layer; its L1/L2 exposure
# is the consuming desktop's base image, covered here). Nothing here sees
# /nix/store (L3): Trivy has no nix analyzer; that needs Syft/vulnix. See
# design/cve-scanning.md.
#
# Report-only: writes one JUnit trivy-report-<repo>.xml per base to $OUT_DIR
# (GitLab captures them as reports.junit → pipeline Tests tab) and prints a CVE
# table to the log. Never fails on findings — only on a scan that errored out
# (infra failure). Gating (fixed-CRITICAL / skipped-security) is a later step.
#
# Env:
#   NIX_BASES   space list of published repo names to restrict to (same filter
#               as nix-publish-base.sh); empty = every base whose local image
#               exists. Set it explicitly on a web/manual pipeline to scan all
#               current bases without a rebuild (the store is persistent).
#   DOCKER      container CLI (default: podman) — also the trivy --image-src
#   OUT_DIR     where to drop the JUnit XML (default: /artifacts)
#   TRIVY_HOME  writable trivy binary dir (default: /tmp/trivy; /work is ro)
#   S3_BUCKET   trivy download bucket (consumed by ci-scripts/download-trivy);
#               UNSET in this sandbox project → pinned GitHub release instead
#   TRIVY_VERSION  release used by the GitHub fallback (checksum-verified)
#   HOST_UID/HOST_GID  chown reports back to the runner UID (root writes them)
set -uo pipefail

DOCKER="${DOCKER:-podman}"
FILTER="${NIX_BASES:-}"
OUT_DIR="${OUT_DIR:-/artifacts}"
export TRIVY_HOME="${TRIVY_HOME:-/tmp/trivy}"
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Base image map — keep in sync with nix-publish-base.sh
# (local build tag | published kasm-core repo name).
BASES="
localhost/nix-ubuntu:dev|kasm-core-ubuntu
localhost/kasm-core-ubuntu-noble-minimal:dev|kasm-core-ubuntu-minimal
localhost/nix-fedora:dev|kasm-core-fedora
localhost/nix-alpine:dev|kasm-core-alpine
localhost/nix-ubuntu-resolute:dev|kasm-core-ubuntu-resolute
"

in_filter() { [ -z "${FILTER}" ] && return 0; local x; for x in ${FILTER}; do [ "${x}" = "$1" ] && return 0; done; return 1; }

command -v curl >/dev/null 2>&1 || { echo "[nix-scan-base] installing curl"; dnf install -y --setopt=install_weak_deps=False curl >/dev/null 2>&1 || true; }

mkdir -p "${OUT_DIR}"
# Trivy binary in a writable home (/work is ro). Two sources:
#   S3_BUCKET set   → upstream Kasm mirror via ci-scripts/download-trivy
#   S3_BUCKET unset → pinned, checksum-verified official GitHub release
#                     (this sandbox project defines no S3_BUCKET CI variable —
#                     the first non-empty run died on it, pipeline 2688148353)
TRIVY_VERSION="${TRIVY_VERSION:-0.72.0}"
if [ ! -x "${TRIVY_HOME}/trivy" ]; then
  if [ -n "${S3_BUCKET:-}" ]; then
    ( cd "${SCRIPT_DIR}" && bash download-trivy )
  else
    echo "[nix-scan-base] fetching trivy ${TRIVY_VERSION} from GitHub releases (no S3_BUCKET)"
    case "$(uname -m)" in
      x86_64)  t_arch="64bit" ;;
      aarch64) t_arch="ARM64" ;;
      *) echo "[nix-scan-base] unsupported arch $(uname -m)" >&2; exit 1 ;;
    esac
    t_tgz="trivy_${TRIVY_VERSION}_Linux-${t_arch}.tar.gz"
    t_url="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}"
    curl -fsSLo "/tmp/${t_tgz}" "${t_url}/${t_tgz}" || exit 1
    curl -fsSLo /tmp/trivy_checksums.txt "${t_url}/trivy_${TRIVY_VERSION}_checksums.txt" || exit 1
    ( cd /tmp && grep " ${t_tgz}\$" trivy_checksums.txt | sha256sum -c - >/dev/null ) || {
      echo "[nix-scan-base] trivy checksum verification FAILED" >&2; exit 1; }
    mkdir -p "${TRIVY_HOME}/contrib"
    tar -C "${TRIVY_HOME}" -xzf "/tmp/${t_tgz}" trivy
    # The scan wrapper expects the JUnit template at $TRIVY_HOME/contrib/;
    # download-trivy stages the in-repo copy the same way.
    cp "${SCRIPT_DIR}/junit.tpl" "${TRIVY_HOME}/contrib/"
    echo "[nix-scan-base] using trivy $("${TRIVY_HOME}/trivy" --version | head -1)"
  fi
fi

scanned=0; missing=0; failed=()
while IFS='|' read -r local_img repo; do
  [ -n "${local_img}" ] || continue
  in_filter "${repo}" || continue
  if ! "${DOCKER}" image inspect "${local_img}" >/dev/null 2>&1; then
    # With an explicit NIX_BASES filter (CI always sets one), a requested base
    # that is absent from the store is a failure, not a skip — otherwise a
    # baseline run can go green having scanned nothing.
    if [ -n "${FILTER}" ]; then
      echo "[nix-scan-base] ERROR ${repo}: requested but local image absent (${local_img})" >&2
      failed+=("${repo}")
    else
      echo "[nix-scan-base] ${repo}: local image absent (${local_img}) — skip" >&2
      missing=$((missing+1))
    fi
    continue
  fi
  echo "[nix-scan-base] ===== scanning ${local_img}  (${repo}) ====="
  # Save to a tar (socket-independent) and scan via trivy --input — the DinD
  # container has no podman API socket for trivy's --image-src podman path.
  tar="$(mktemp -d)/img.tar"
  if ! "${DOCKER}" save -o "${tar}" "${local_img}"; then
    echo "[nix-scan-base] WARN save failed: ${repo}" >&2; failed+=("${repo}"); rm -rf "$(dirname "${tar}")"; continue
  fi
  if TRIVY_REPORT="${OUT_DIR}/trivy-report-${repo}.xml" TRIVY_INPUT="${tar}" \
       bash "${SCRIPT_DIR}/scan" image "${local_img}"; then
    scanned=$((scanned+1))
  else
    echo "[nix-scan-base] WARN scan errored: ${repo}" >&2; failed+=("${repo}")
  fi
  rm -rf "$(dirname "${tar}")"
done <<EOF
${BASES}
EOF

# Reports are written as root; hand ownership back to the runner UID so GitLab
# can capture them and the next checkout can clean them (mirrors nix-publish).
if [ -n "${HOST_UID:-}" ]; then
  chown "${HOST_UID}:${HOST_GID:-$HOST_UID}" "${OUT_DIR}"/trivy-report-*.xml 2>/dev/null || true
fi

echo "[nix-scan-base] done: scanned=${scanned} missing=${missing} failed=${#failed[@]} ${failed[*]:-}"
# Report-only: findings do NOT fail the job; only a scan command that errored does.
[ ${#failed[@]} -eq 0 ]
