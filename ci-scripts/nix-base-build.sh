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
#   BASE_BUILD_ATTEMPTS  SERIAL retry attempts (default 2) for a distro that failed
#                   the parallel pass — parallel builds contend on distro package
#                   mirrors (alpine's apk is the usual victim; dl-cdn rate-limits
#                   under concurrent load), and a serial rebuild afterwards clears
#                   it. Build proceeds in two passes: parallel, then serial retry.
#   BASE_BUILT_SHA  commit sha, stamped as kasm.base.builtsha (the app-build
#                   freshness guard in dind-build.sh reads it).
set -euo pipefail
cd /work

PAR="${BUILD_PARALLEL:-3}"
WANT="${BASE_DISTROS:-ubuntu fedora alpine resolute}"

# Per-distro build recipe:
#   src_image | core_dockerfile | core_tag | DISTRO arg | BG_IMG | nix_dockerfile | nix_tag
base_row() {
  case "$1" in
    ubuntu) echo "ubuntu:24.04|dockerfile-kasm-core-minimal|localhost/kasm-core-ubuntu-noble-minimal:dev|ubuntu|bg_noble.png|dockerfile-nix-ubuntu|localhost/nix-ubuntu:dev" ;;
    fedora) echo "fedora:42|dockerfile-kasm-core-fedora|localhost/kasm-core-fedora:dev|fedora42|bg_fedora.png|dockerfile-nix-fedora|localhost/nix-fedora:dev" ;;
    alpine) echo "alpine:3.21|dockerfile-kasm-core-alpine|localhost/kasm-core-alpine:dev|alpine|bg_alpine.png|dockerfile-nix-alpine|localhost/nix-alpine:dev" ;;
    # Resolute (26.04): Kasm publishes no per-distro KasmVNC .deb, so its core is
    # built INCLUDE_KASMVNC=0 and the nix finish BAKES the Nix KasmVNC closure in
    # (see the resolute branch in build_one). DISTRO=ubuntu (shares src/ubuntu).
    resolute) echo "ubuntu:26.04|dockerfile-kasm-core-ubuntu-resolute|localhost/kasm-core-ubuntu-resolute:dev|ubuntu|bg_kasm.png|dockerfile-nix-ubuntu-resolute|localhost/nix-ubuntu-resolute:dev" ;;
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
  # resolute gets KasmVNC, profile-sync and audio-input from the Nix overlay
  # (baked below) → build the core without their per-distro artifacts.
  core_extra=()
  [ "${d}" = resolute ] && core_extra=(--build-arg INCLUDE_KASMVNC=0 --build-arg INCLUDE_PROFILE_SYNC=0 --build-arg INCLUDE_AUDIO_INPUT=0)
  # Explicit `|| return 1` so a failed build propagates even under the caller's
  # `set +e` (the retry subshell) — otherwise a core-build failure would fall
  # through to the nix build and be masked as success.
  podman build --build-arg BASE_IMAGE="${src}" --build-arg DISTRO="${distarg}" \
    --build-arg BG_IMG="${bg}" "${core_extra[@]}" -f "${coredf}" -t "${coretag}" . || return 1
  echo "[base:${d}] building ${nixtag}"
  # Stamp: builtsha (freshness guard) + the source image ref/digest (staleness check).
  if [ "${d}" = resolute ]; then
    # resolute's nix finish BAKES the Nix KasmVNC closure into the core (no
    # per-distro .deb). nix-bake-closure runs nix in a nixos/nix container (DIND
    # has no host nix), staging the closure into a WRITABLE tmp context (/work is
    # ro). NIX_STAGE_VOLUME (a persistent /nix podman volume) warms the cache if set.
    ctx="$(mktemp -d)"
    bin/nix-bake-closure \
      --base "${coretag}" --tag "${nixtag}" \
      --pkg kasmvnc --pkg profile_sync --pkg audio_input \
      --dockerfile /work/dockerfile-nix-ubuntu-resolute \
      --overlay /work/bin/nix-kasm-overlay \
      --context "${ctx}" \
      --docker podman --nix-runner container \
      --nix-image "${NIX_STAGE_IMAGE:-nixos/nix:latest}" \
      ${NIX_STAGE_VOLUME:+--nix-volume "${NIX_STAGE_VOLUME}"} \
      --label "kasm.base.builtsha=${BASE_BUILT_SHA:-unknown}" \
      --label "dev.kasm.base.src-image=${src}" \
      --label "dev.kasm.base.src-digest=${digest}" \
      && rc=0 || rc=1
    rm -rf "${ctx}"
    [ "${rc}" = 0 ] || return 1
  else
    podman build --build-arg BASE_IMAGE="${coretag}" \
      --label "kasm.base.builtsha=${BASE_BUILT_SHA:-unknown}" \
      --label "dev.kasm.base.src-image=${src}" \
      --label "dev.kasm.base.src-digest=${digest}" \
      -f "${nixdf}" -t "${nixtag}" . || return 1
  fi
  echo "[base:${d}] done: $(podman image inspect -f '{{.Id}}' "${nixtag}") src-digest=${digest:-unknown}"
  return 0
}

# Parallel fan-out, capped at PAR (semaphore over background jobs). Each distro
# writes its own log + rc so a failure of one doesn't abort the others; the whole
# job fails if any distro failed.
sem() { while [ "$(jobs -rp | wc -l)" -ge "${PAR}" ]; do wait -n 2>/dev/null || break; done; }

# Pass 1 — build all requested distros in PARALLEL (the fast path).
echo "[base] pass 1 (parallel=${PAR}): ${WANT}"
for d in ${WANT}; do
  sem
  # set +e so a failed build_one still records its real exit code.
  ( set +e; build_one "$d"; echo $? > "/tmp/base-${d}.rc" ) >"/tmp/base-${d}.log" 2>&1 &
done
wait

# Pass 2 — SERIAL retry of anything that failed. Root cause of parallel-only
# failures: building distros concurrently contends on their package mirrors, and
# alpine's apk (re-fetching main+community+edge indexes on every `apk add
# --no-cache`) gets rate-limited by dl-cdn under that load → transient
# "temporary error" → bogus "no such package". Once the parallel batch is done
# the contention is gone, so a serial rebuild succeeds (verified: alpine builds
# cleanly on its own). A genuinely-broken build still fails here. Serial retries
# append to the same per-distro log.
# Retries do a full build_one, but podman's layer cache resumes from the failed
# step, so a retry mostly re-runs just the failing package install with a fresh
# index fetch. Several attempts with backoff ride out dl-cdn's flaky windows
# (alpine's apk is intermittently rate-limited even serially).
ATTEMPTS="${BASE_BUILD_ATTEMPTS:-3}"
BACKOFF="${BASE_BUILD_BACKOFF:-30}"
for d in ${WANT}; do
  [ "$(cat "/tmp/base-${d}.rc" 2>/dev/null || echo 1)" = 0 ] && continue
  echo "[base:${d}] pass-1 failed — serial retry (mirror contention now cleared)" >&2
  for attempt in $(seq 1 "${ATTEMPTS}"); do
    ( set +e; build_one "$d"; echo $? > "/tmp/base-${d}.rc" ) >>"/tmp/base-${d}.log" 2>&1
    if [ "$(cat "/tmp/base-${d}.rc" 2>/dev/null || echo 1)" = 0 ]; then
      echo "[base:${d}] serial retry ${attempt} succeeded" >&2; break
    fi
    echo "[base:${d}] serial retry ${attempt}/${ATTEMPTS} failed" >&2
    [ "${attempt}" -lt "${ATTEMPTS}" ] && sleep "${BACKOFF}"
  done
done

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
