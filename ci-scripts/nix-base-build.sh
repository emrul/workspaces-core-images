#!/usr/bin/env bash
# nix-base-build.sh — build the Nix distro base images (core + nix-<distro>) into
# the persistent podman store, for one or more distros IN PARALLEL, stamping each
# with the upstream source-image digest so nix-base-check.sh can later detect when
# that source image (e.g. ubuntu:24.04) has moved.
#
# Runs INSIDE the DIND podman container (mounts: /work=repo ro,
# /var/lib/containers=persistent store). Replaces the per-distro dind-base*.sh.
#
# Env:
#   BASE_DISTROS    space list to build (default: all). e.g. "ubuntu fedora"
#   BUILD_PARALLEL  max concurrent distro builds (default 3) — same knob the
#                   per-app build uses.
#   BASE_BUILD_ATTEMPTS  retries per distro on transient failure (default 3) —
#                   parallel builds contend on distro package mirrors, so an
#                   index fetch can hit a transient CDN error; a retry clears it.
#   BASE_BUILT_SHA  commit sha, stamped as kasm.base.builtsha (the app-build
#                   freshness guard in dind-build.sh reads it).
set -euo pipefail
cd /work

PAR="${BUILD_PARALLEL:-3}"
WANT="${BASE_DISTROS:-ubuntu fedora alpine}"

# Per-distro build recipe:
#   src_image | core_dockerfile | core_tag | DISTRO arg | BG_IMG | nix_dockerfile | nix_tag
base_row() {
  case "$1" in
    ubuntu) echo "ubuntu:24.04|dockerfile-kasm-core-minimal|localhost/kasm-core-ubuntu-noble-minimal:dev|ubuntu|bg_noble.png|dockerfile-nix-ubuntu|localhost/nix-ubuntu:dev" ;;
    fedora) echo "fedora:42|dockerfile-kasm-core-fedora|localhost/kasm-core-fedora:dev|fedora42|bg_fedora.png|dockerfile-nix-fedora|localhost/nix-fedora:dev" ;;
    alpine) echo "alpine:3.21|dockerfile-kasm-core-alpine|localhost/kasm-core-alpine:dev|alpine|bg_alpine.png|dockerfile-nix-alpine|localhost/nix-alpine:dev" ;;
    *) return 1 ;;
  esac
}

# Resolve the digest podman pulled for a tag (manifest-list digest → arch-stable),
# matching what nix-base-check.sh compares against.
src_digest() {
  podman image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$1" 2>/dev/null \
    | sed 's/.*@//'
}

build_one() {
  d="$1"
  row="$(base_row "$d")" || { echo "[base:${d}] unknown distro" >&2; return 2; }
  IFS='|' read -r src coredf coretag distarg bg nixdf nixtag <<EOF
$row
EOF
  echo "[base:${d}] pull ${src}"
  podman pull -q "docker.io/library/${src}" >/dev/null 2>&1 || podman pull -q "${src}" >/dev/null 2>&1 || true
  digest="$(src_digest "${src}")"
  echo "[base:${d}] building ${coretag} (from ${src} @ ${digest:-unknown})"
  # Explicit `|| return 1` so a failed build propagates even under the caller's
  # `set +e` (the retry subshell) — otherwise a core-build failure would fall
  # through to the nix build and be masked as success.
  podman build --build-arg BASE_IMAGE="${src}" --build-arg DISTRO="${distarg}" \
    --build-arg BG_IMG="${bg}" -f "${coredf}" -t "${coretag}" . || return 1
  echo "[base:${d}] building ${nixtag}"
  # Stamp: builtsha (freshness guard) + the source image ref/digest (staleness check).
  podman build --build-arg BASE_IMAGE="${coretag}" \
    --label "kasm.base.builtsha=${BASE_BUILT_SHA:-unknown}" \
    --label "dev.kasm.base.src-image=${src}" \
    --label "dev.kasm.base.src-digest=${digest}" \
    -f "${nixdf}" -t "${nixtag}" . || return 1
  echo "[base:${d}] done: $(podman image inspect -f '{{.Id}}' "${nixtag}") src-digest=${digest:-unknown}"
  return 0
}

# Parallel fan-out, capped at PAR (semaphore over background jobs). Each distro
# writes its own log + rc so a failure of one doesn't abort the others; the whole
# job fails if any distro failed.
sem() { while [ "$(jobs -rp | wc -l)" -ge "${PAR}" ]; do wait -n 2>/dev/null || break; done; }

echo "[base] building: ${WANT}  (parallel=${PAR})"
ATTEMPTS="${BASE_BUILD_ATTEMPTS:-3}"
for d in ${WANT}; do
  sem
  # Retry each distro build: base builds pull from distro package mirrors
  # (apt/dnf/apk), and building distros in PARALLEL contends on those mirrors,
  # making transient index-fetch failures ("temporary error (try again later)")
  # likely — which cascade into bogus "no such package" errors for packages that
  # do exist. A retry (podman's layer cache resumes from the failed step, with a
  # fresh index fetch) clears the transient case; a genuine failure exhausts the
  # attempts and records a non-zero rc. set +e so the real exit code is recorded.
  (
    set +e
    rc=1
    for attempt in $(seq 1 "${ATTEMPTS}"); do
      build_one "$d"; rc=$?
      [ "${rc}" = 0 ] && break
      if [ "${attempt}" -lt "${ATTEMPTS}" ]; then
        echo "[base:${d}] attempt ${attempt}/${ATTEMPTS} failed (rc=${rc}) — transient? retrying in 15s" >&2
        sleep 15
      fi
    done
    echo "${rc}" > "/tmp/base-${d}.rc"
  ) >"/tmp/base-${d}.log" 2>&1 &
done
wait

# A secondary distro's failure must NOT block the ubuntu app pipeline. Fail the
# job only when a CRITICAL distro (default: ubuntu, the app base) failed; other
# distros' failures are surfaced loudly but tolerated (their base just isn't
# refreshed this run, and publish-base skips a missing image).
CRIT="${CRITICAL_DISTROS:-ubuntu}"
failed=""; crit_fail=0
for d in ${WANT}; do
  echo "===== base:${d} ====="
  cat "/tmp/base-${d}.log" 2>/dev/null || echo "(no log)"
  r="$(cat "/tmp/base-${d}.rc" 2>/dev/null || echo 1)"
  if [ "${r}" != 0 ]; then
    failed="${failed} ${d}"
    case " ${CRIT} " in *" ${d} "*) crit_fail=1 ;; esac
  fi
done
if [ -n "${failed}" ]; then
  echo "[base] WARNING: base build FAILED for:${failed}" >&2
fi
if [ "${crit_fail}" = 1 ]; then
  echo "[base] a CRITICAL distro (${CRIT}) failed — failing the job" >&2
  exit 1
fi
echo "[base] OK — built: ${WANT}; tolerated failures:${failed:- none}"
exit 0
