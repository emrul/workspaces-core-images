#!/usr/bin/env bash
# dind-build.sh — driver that runs INSIDE the privileged podman-in-podman
# container on the Portal box. Builds the Nix per-app catalog and writes
# human- + machine-readable progress to the host-mounted output dir so the
# build is observable from outside the container (see dind-check.sh).
#
# Mounts expected (wired by dind-launch.sh):
#   /work                          → repo (ro)
#   /var/lib/containers            → host /srv/nix-build/containers (persistent
#                                    podman store: warm cache + built images)
#   /root/.cache/nix-build-output  → host /srv/nix-build/output (logs, STATUS,
#                                    app-*.tar — all visible on the host)
#
# Env:
#   PROFILES      optional CSV/space list of profiles; empty = all in the toml.
#                 "__none__" = change-gating found nothing image-relevant → no-op.
#   PUSH          optional registry to push final images to (e.g. forge.emrul.dev)
#   EMIT_APPS     1 (default) = also emit the per-app images; 0 = fat store only
#                 (skip re-assembling per-app images that already exist).
#   BUILD_PARALLEL  per-app build concurrency (read directly by
#                 build-nix-store-volume; default min(nproc,4)).
set -euo pipefail

cd /work
OUT=/root/.cache/nix-build-output
mkdir -p "$OUT"
LOG="$OUT/build.log"

# STATUS is the single source of truth an external checker polls.
status() { printf '%s\n' "$*" > "$OUT/STATUS"; }
on_err() { local rc=$?; status "FAILED rc=${rc} at $(date -u +%FT%TZ)"; exit "$rc"; }
trap on_err ERR

# Mirror everything to the host-visible logfile.
exec > >(tee -a "$LOG") 2>&1

echo "=================================================================="
echo "[driver] start $(date -u +%FT%TZ)  PROFILES='${PROFILES:-<all>}'  PUSH='${PUSH:-<none>}'  EMIT_APPS='${EMIT_APPS:-1}'  BUILD_PARALLEL='${BUILD_PARALLEL:-<default>}'"
status "RUNNING setup $(date -u +%FT%TZ)"

# Change-gating: nothing image-relevant changed — build nothing, exit clean.
if [ "${PROFILES:-}" = "__none__" ]; then
  echo "[driver] PROFILES=__none__ — no image-relevant changes; nothing to build"
  status "SUCCESS apps=0 (no changes) $(date -u +%FT%TZ)"
  exit 0
fi

# ── 1. ensure the app base is present in the podman store ─────────────────
# APP_BASE_IMAGE overrides the default Noble base — used by the TraceLabs
# Phase-0 spike to build on localhost/nix-ubuntu-resolute:dev (the reviewer-
# sanctioned "separate invocation"; per-profile app_base is later work). The
# tar-load fallback only applies to the default Noble base (that's the only
# one staged to $OUT/nix-ubuntu.tar).
APP_BASE_IMAGE="${APP_BASE_IMAGE:-localhost/nix-ubuntu:dev}"
if ! podman image exists "$APP_BASE_IMAGE"; then
  if [ "$APP_BASE_IMAGE" = "localhost/nix-ubuntu:dev" ] && [ -f "$OUT/nix-ubuntu.tar" ]; then
    echo "[driver] loading nix-ubuntu:dev from $OUT/nix-ubuntu.tar"
    podman load -i "$OUT/nix-ubuntu.tar"
  else
    echo "[driver] FATAL: app base '$APP_BASE_IMAGE' absent (and no tar fallback)"
    status "FAILED no-base $(date -u +%FT%TZ)"
    exit 1
  fi
fi
echo "[driver] base image OK: $APP_BASE_IMAGE $(podman image inspect -f '{{.Id}}' "$APP_BASE_IMAGE")"

# ── 1a. base-freshness guard ──────────────────────────────────────────────
# If this commit changed files baked INTO the base image (NIX_BASE_AFFECTED=1,
# from change-gating) but the nix-ubuntu base in the store was NOT rebuilt for
# this commit, building now would silently ship a STALE base (the classic
# footgun: `base`/`publish-base` are manual and `build` doesn't depend on them).
# Compare the base's kasm.base.builtsha label to this commit and fail with
# instructions. Only enforced in CI (CI_COMMIT_SHA set); override ALLOW_STALE_BASE=1.
if [ "${NIX_BASE_AFFECTED:-0}" = "1" ] && [ "${ALLOW_STALE_BASE:-0}" != "1" ] && [ -n "${CI_COMMIT_SHA:-}" ]; then
  base_sha="$(podman image inspect -f '{{ index .Config.Labels "kasm.base.builtsha" }}' localhost/nix-ubuntu:dev 2>/dev/null || true)"
  if [ "${base_sha}" != "${CI_COMMIT_SHA}" ]; then
    echo "[driver] FATAL: base-affecting files changed in this commit, but the nix-ubuntu"
    echo "[driver]   base in the store was built from '${base_sha:-<unstamped>}', not this"
    echo "[driver]   commit '${CI_COMMIT_SHA}'. Building now would ship a STALE base."
    echo "[driver]   → Run the 'base' job (then 'publish-base') for this commit first."
    echo "[driver]   → Or set ALLOW_STALE_BASE=1 to override (you accept a stale base)."
    status "FAILED stale-base $(date -u +%FT%TZ)"
    exit 1
  fi
  echo "[driver] base-freshness OK: base built from this commit (${CI_COMMIT_SHA})"
fi

# ── 1b. reclaim churn before building (KEEP the Nix cache + base images) ────
# The persistent podman store accumulates transient artifacts each run:
# superseded localhost/nix-<app>:dev + nix-store:dev tags, dangling layers, and
# stale anonymous registry volumes. Prune them so the store stays bounded — WITHOUT
# touching the nix-build-stage-* volume (the Nix build cache that avoids
# re-realizing unchanged packages) or the base images. See design/nix-ci-disk.md.
freeG() { df -PBG /var/lib/containers 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4); print $4+0}'; }
echo "[driver] free before prune: $(freeG)G"
podman image prune -f >/dev/null 2>&1 || true
# Dangling build cache — the biggest churn source (intermediate layers from past
# `podman build` runs), which `image prune` misses. -f only (NEVER -a: that drops
# live images' cache and cascades into removing the tagged base images).
podman builder prune -f >/dev/null 2>&1 || true
# Keep ALL distro bases (nix-ubuntu*, nix-fedora, nix-alpine) — publish-base
# pushes them from this same store, and the base job may have just rebuilt them.
# (A keep list of only nix-ubuntu silently deleted the freshly-built alpine and
# fedora bases here, so publish-base reported them "missing" — pipeline 2682481145.)
podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
  | grep -E '^localhost/nix-' | grep -vE 'nix-ubuntu|nix-fedora|nix-alpine|nixbase' \
  | sort -u | xargs -r -n1 podman rmi -f >/dev/null 2>&1 || true
# Backstop: if still tight, drop stale anonymous volumes (old registry staging,
# etc.) — but NEVER the nix-build-stage-* Nix cache.
if [ "$(freeG)" -lt 80 ]; then
  echo "[driver] low disk ($(freeG)G) — pruning stale volumes (keeping nix-build-stage-*)"
  for v in $(podman volume ls --format '{{.Name}}' 2>/dev/null | grep -vE '^nix-build-stage-'); do
    podman volume rm "$v" >/dev/null 2>&1 || true
  done
fi
echo "[driver] free after prune: $(freeG)G"

# ── 1c. disk pre-flight gate — live within the runner's disk budget ────────
# The catalog build is large; if it starts with too little headroom it ENOSPCs
# mid-run (corrupting the warm store). Enforce a floor of DISK_MIN_GB free,
# escalating reclaim before giving up:
#   1. standard GC (stale vols + Nix-cache reset only if it exceeds NIX_STAGE_CAP_G)
#   2. still short → nuke the Nix cache entirely (next build re-seeds, slow)
#   3. still short → FAIL: the image working set alone exceeds the budget; a human
#      must free space / grow the disk (or lower DISK_MIN_GB for a one-off).
# This is the enforcement side of the runner disk budget — see docs/ci_cd_flow.md.
DISK_MIN_GB="${DISK_MIN_GB:-120}"
CAP_G="${NIX_STAGE_CAP_G:-150}"
if [ "$(freeG)" -lt "${DISK_MIN_GB}" ]; then
  echo "[driver] low disk $(freeG)G < ${DISK_MIN_GB}G floor — GC (Nix-cache cap ${CAP_G}G)"
  NIX_STAGE_CAP_G="${CAP_G}" sh /work/ci-scripts/nix-gc.sh || true
fi
if [ "$(freeG)" -lt "${DISK_MIN_GB}" ]; then
  echo "[driver] still low $(freeG)G < ${DISK_MIN_GB}G — nuking the Nix build cache (next build re-seeds)"
  NIX_STAGE_CAP_G=0 sh /work/ci-scripts/nix-gc.sh || true
fi
free_final="$(freeG)"
if [ "${free_final}" -lt "${DISK_MIN_GB}" ]; then
  echo "[driver] FATAL: ${free_final}G free < ${DISK_MIN_GB}G floor, even after full GC + cache nuke."
  echo "[driver]   The image working set alone exceeds the disk budget — grow the runner disk"
  echo "[driver]   ($DIND_ROOT) or free space, then retry. One-off override: lower DISK_MIN_GB."
  status "FAILED disk ${free_final}G<${DISK_MIN_GB}G $(date -u +%FT%TZ)"
  exit 1
fi
echo "[driver] disk OK: ${free_final}G free (floor ${DISK_MIN_GB}G, cache cap ${CAP_G}G)"

# ── 2. assemble args ──────────────────────────────────────────────────────
# --keep-output preserves app-*.tar after the run so the checker can verify
# per-app artifacts post-build (the script otherwise cleans them on exit).
args=(--keep-output --app-base-image "$APP_BASE_IMAGE")
# NIX_CONFIG_FILE overrides the profiles TOML (default: build-nix-store-volume's
# own bin/nix-profiles.toml). The TraceLabs spike points this at an isolated
# config so a scoped, non-pushed build can't perturb the catalog fat store.
[ -n "${NIX_CONFIG_FILE:-}" ] && args+=(--config "$NIX_CONFIG_FILE")
# EMIT_APPS=0 → fat store only (don't re-assemble per-app images we already have).
[ "${EMIT_APPS:-1}" = "0" ] || args=(--emit-app-images "${args[@]}")
# FULL-SELECTION builds (2026-07-18): PROFILES no longer narrows the build.
# A subset-selected build stages a PARTIAL fat store; publishing that overwrote
# the registry's full-catalog nix-store tag (see design/nix-dedup-gap.md
# incident). Every build now selects the whole catalog: the eval-gate keeps
# unchanged profiles cheap (skips reinstall), changed.txt + the wiring-digest
# check (nix-crane-assemble) scope per-app assembly, and the fat store is
# complete every run — an app update swaps just its layer in the fat store.
# PROFILES still short-circuits no-op runs (__none__, handled by the caller)
# and scopes the scan stage downstream. SCOPED_BUILD=1 restores the old
# narrowing for local single-app dev builds ONLY — a scoped build's fat store
# must never be published (nix-publish's completeness guard will skip it).
if [ "${SCOPED_BUILD:-0}" = "1" ] && [ -n "${PROFILES:-}" ]; then
  echo "[driver] SCOPED_BUILD=1: narrowing to PROFILES='${PROFILES}' (dev only — partial fat store)"
  for p in $(printf '%s' "$PROFILES" | tr ',' ' '); do
    [ -n "$p" ] && args+=(--profile "$p")
  done
elif [ -n "${PROFILES:-}" ]; then
  echo "[driver] PROFILES='${PROFILES}' noted (gating/scan scope) — building FULL selection"
fi
[ -n "${PUSH:-}" ] && args+=(--push "$PUSH")

# ── 3. run the real build (bracketed for the disk/timing report) ───────────
# freeG() is free GB on /var/lib/containers; consumed = before - after (a
# GC mid-build can make this negative → net reclaim, which is fine to report).
disk_before="$(freeG)"
podman system df 2>/dev/null > "$OUT/podman-df-before.txt" || true
t_start="$(date +%s 2>/dev/null || echo 0)"
started_at="$(date -u +%FT%TZ)"

status "RUNNING build ${started_at}"
echo "[driver] exec: bin/build-nix-store-volume ${args[*]}"
bash bin/build-nix-store-volume "${args[@]}"

t_end="$(date +%s 2>/dev/null || echo 0)"
disk_after="$(freeG)"
podman system df 2>/dev/null > "$OUT/podman-df-after.txt" || true
# metrics.json — folded into nix-build-report.json by the publish stage. Written
# with printf (no jq): the DIND image is not guaranteed to ship jq, and every
# value here is a controlled number or timestamp.
dur=$(( t_end - t_start )); consumed=$(( disk_before - disk_after ))
{
  printf '{\n'
  printf '  "startedAt": "%s",\n'      "${started_at}"
  printf '  "endedAt": "%s",\n'        "$(date -u +%FT%TZ)"
  printf '  "durationSec": %s,\n'      "${dur}"
  printf '  "diskFreeBeforeG": %s,\n'  "${disk_before:-0}"
  printf '  "diskFreeAfterG": %s,\n'   "${disk_after:-0}"
  printf '  "diskConsumedG": %s,\n'    "${consumed}"
  printf '  "profiles": "%s"\n'        "${PROFILES:-<all>}"
  printf '}\n'
} > "$OUT/metrics.json" 2>/dev/null || echo "[driver] WARN could not write metrics.json" >&2
echo "[driver] metrics: ${dur}s, disk consumed ${consumed}G (free ${disk_before}G→${disk_after}G)"

# ── 4. final summary ──────────────────────────────────────────────────────
# Count runnable nix-<app> images in the store (the refactor builds straight
# into the overlay store — there are no app-*.tar to count). `|| true` keeps a
# zero match from tripping `set -e`/pipefail.
app_count=$(podman images --format '{{.Repository}}' 2>/dev/null \
  | grep -E '/nix-[a-z0-9-]+$' | grep -vE 'nix-store|nix-ubuntu' | sort -u | wc -l | tr -d ' ' || true)
echo "[driver] done $(date -u +%FT%TZ): fat store + ${app_count} runnable app image(s) in store"
status "SUCCESS apps=${app_count} $(date -u +%FT%TZ)"
