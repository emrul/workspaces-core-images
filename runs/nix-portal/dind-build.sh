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

# ── 1. ensure the nix-ubuntu base is present in the podman store ──────────
if ! podman image exists localhost/nix-ubuntu:dev; then
  if [ -f "$OUT/nix-ubuntu.tar" ]; then
    echo "[driver] loading nix-ubuntu:dev from $OUT/nix-ubuntu.tar"
    podman load -i "$OUT/nix-ubuntu.tar"
  else
    echo "[driver] FATAL: localhost/nix-ubuntu:dev absent and no $OUT/nix-ubuntu.tar to load"
    status "FAILED no-base $(date -u +%FT%TZ)"
    exit 1
  fi
fi
echo "[driver] base image OK: $(podman image inspect -f '{{.Id}}' localhost/nix-ubuntu:dev)"

# ── 1b. reclaim churn before building (KEEP the Nix cache + base images) ────
# The persistent podman store accumulates transient artifacts each run:
# superseded localhost/nix-<app>:dev + nix-store:dev tags, dangling layers, and
# stale anonymous registry volumes. Prune them so the store stays bounded — WITHOUT
# touching the nix-build-stage-* volume (the Nix build cache that avoids
# re-realizing unchanged packages) or the base images. See design/nix-ci-disk.md.
freeG() { df -PBG /var/lib/containers 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4); print $4+0}'; }
echo "[driver] free before prune: $(freeG)G"
podman image prune -f >/dev/null 2>&1 || true
podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
  | grep -E '^localhost/nix-' | grep -vE 'nix-ubuntu|nixbase' \
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

# ── 2. assemble args ──────────────────────────────────────────────────────
# --keep-output preserves app-*.tar after the run so the checker can verify
# per-app artifacts post-build (the script otherwise cleans them on exit).
args=(--keep-output --app-base-image localhost/nix-ubuntu:dev)
# EMIT_APPS=0 → fat store only (don't re-assemble per-app images we already have).
[ "${EMIT_APPS:-1}" = "0" ] || args=(--emit-app-images "${args[@]}")
if [ -n "${PROFILES:-}" ]; then
  for p in $(printf '%s' "$PROFILES" | tr ',' ' '); do
    [ -n "$p" ] && args+=(--profile "$p")
  done
fi
[ -n "${PUSH:-}" ] && args+=(--push "$PUSH")

# ── 3. run the real build ─────────────────────────────────────────────────
status "RUNNING build $(date -u +%FT%TZ)"
echo "[driver] exec: bin/build-nix-store-volume ${args[*]}"
bash bin/build-nix-store-volume "${args[@]}"

# ── 4. final summary ──────────────────────────────────────────────────────
# Count runnable nix-<app> images in the store (the refactor builds straight
# into the overlay store — there are no app-*.tar to count). `|| true` keeps a
# zero match from tripping `set -e`/pipefail.
app_count=$(podman images --format '{{.Repository}}' 2>/dev/null \
  | grep -E '/nix-[a-z0-9-]+$' | grep -vE 'nix-store|nix-ubuntu' | sort -u | wc -l | tr -d ' ' || true)
echo "[driver] done $(date -u +%FT%TZ): fat store + ${app_count} runnable app image(s) in store"
status "SUCCESS apps=${app_count} $(date -u +%FT%TZ)"
