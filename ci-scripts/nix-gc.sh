#!/bin/sh
# nix-gc.sh — bound the persistent podman build store on the nix-builder runner.
#
# Runs inside a privileged podman-in-podman container (the CI `gc` job, or by
# hand) with the persistent store mounted at /var/lib/containers. Reclaims the
# transient churn that accumulates across builds WITHOUT throwing away the caches
# that keep builds fast:
#
#   KEEP  nix-build-stage-*  — the Nix build cache (avoids re-realizing unchanged
#                              packages); base images (nix-ubuntu, kasm-core-*).
#   DROP  dangling layers; superseded localhost/nix-<app>:dev + nix-store:dev
#         tags (rebuilt each run, real copies live on the registry); stale
#         anonymous volumes (old crane-registry staging).
#
# The Nix cache only grows slowly (old generations after nixpkgs bumps). Rather
# than a risky in-place generation GC, we RESET it only if it exceeds CAP_G — a
# full reset means one slow re-seed, acceptable when it's genuinely oversized.
# See design/nix-ci-disk.md.
set -u

# podman under the DinD harness, docker on a docker-only host. Every subcommand
# used below exists in both (images / rmi / image prune / builder prune /
# volume ls|rm|inspect / system df) — checked before swapping, because
# `image exists` does NOT exist in docker, and a blanket rename would have
# broken base-staleness checking elsewhere in this tree.
CONTAINER_CLI="${CONTAINER_CLI:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}"

CAP_G="${NIX_STAGE_CAP_G:-250}"
# Free space on the ENGINE'S OWN store, not a hardcoded path. /var/lib/containers
# is where the DinD harness mounted it; on a docker host the data-root is
# elsewhere (e.g. /srv/nix-build/docker). df on a missing path prints nothing,
# which this function would have reported as 0 G free — i.e. "disk full" — so the
# fallback chain matters more than it looks.
STORE_DIR="${STORE_DIR:-$(
  "${CONTAINER_CLI}" info --format '{{.DockerRootDir}}' 2>/dev/null \
    || "${CONTAINER_CLI}" info --format '{{.Store.GraphRoot}}' 2>/dev/null
)}"
[ -d "${STORE_DIR:-}" ] || STORE_DIR=/var/lib/containers
[ -d "${STORE_DIR}" ] || STORE_DIR=/
echo "[gc] store dir: ${STORE_DIR}"
freeG() { df -PBG "${STORE_DIR}" 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4); print $4+0}'; }

echo "[gc] free before: $(freeG)G"

# 0. reclaim local copies of PUSHED images + throwaway staging tags — the single
# biggest accumulator (~130 G/run) that image-prune (dangling-only) leaves behind:
#   • registry.gitlab.com/<ns>/…:nix — per-app + fat-store + base images we
#     already pushed; the authoritative copies live in the GitLab registry, and
#     the next build rebuilds localhost/…:dev + re-pushes, so the local pushed
#     copies are pure cache.
#   • 127.0.0.1:<port>/… — the crane staging registry tags; nix-crane-assemble
#     recreates its staging registry every run, so these are throwaway.
# Deliberately NOT `image prune -a`: that would also evict the docker.io/library
# base images (ubuntu/fedora/alpine/golang/nixos-nix) and the localhost
# nix-<distro>/kasm-core bases, forcing slow re-pulls/rebuilds. Removing the tags
# here turns their layers dangling so step 1 reclaims them.
"${CONTAINER_CLI}" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
  | grep -E '^(registry\.gitlab\.com/|127\.0\.0\.1:[0-9]+/)' \
  | sort -u | xargs -r -n1 "${CONTAINER_CLI}" rmi -f >/dev/null 2>&1 || true

# 1. dangling image layers
"${CONTAINER_CLI}" image prune -f >/dev/null 2>&1 || true

# 1b. dangling BUILD CACHE — intermediate layers left by past `podman build`
# runs (base + fat-store + per-app finish). This is the single biggest churn
# source (~89 G, measured on the retired forge host) and `image prune` does NOT
# touch it.
# Use -f (dangling/unused only), NEVER -a: `builder prune -a` also drops the
# cache backing live images and cascades into removing the tagged base images.
"${CONTAINER_CLI}" builder prune -f >/dev/null 2>&1 || true

# 2. superseded per-app / fat-store dev tags (keep ALL distro base images —
# nix-ubuntu*, nix-fedora, nix-alpine — which publish-base pushes from this store)
"${CONTAINER_CLI}" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
  | grep -E '^localhost/nix-' | grep -vE 'nix-ubuntu|nix-fedora|nix-alpine|nixbase' \
  | sort -u | xargs -r -n1 "${CONTAINER_CLI}" rmi -f >/dev/null 2>&1 || true

# 3. stale anonymous volumes (old registry staging etc.) — never the Nix cache
for v in $("${CONTAINER_CLI}" volume ls --format '{{.Name}}' 2>/dev/null | grep -vE '^nix-build-stage-'); do
  "${CONTAINER_CLI}" volume rm "$v" >/dev/null 2>&1 || true
done

# NOTE — in-place `nix-store --gc` on the staging volume is FORBIDDEN.
# Attempted 2026-07-19 (pipeline 2688324030): the volume mounts at /nix in
# every nixos/nix build container, so it IS that container's toolchain —
# sh/rm/nix are store paths — and the seed image's tool closure is NOT
# gc-rooted inside the volume. GC deleted coreutils out from under itself
# and bricked the volume (`rm: command not found` in every later build;
# repaired by volume delete + reseed). Reclaiming orphaned closures (each
# nixpkgs bump strands a full catalog's worth, plus the db registrations
# that pollute SBOMs) therefore goes through RESEED, not in-place GC:
# delete the volume and let the next build re-seed + reinstall against the
# current pins. Step 4's cap reset is exactly that; to reclaim after a
# base-ref bump without waiting for the cap, run this job with
# NIX_STAGE_CAP_G=0 (forces the reset). If in-place GC is ever revisited,
# it must first register the seed image's full runtime closure as a gcroot.

# 4. size-guarded reset of the Nix cache (rare; next build re-seeds)
for sv in $("${CONTAINER_CLI}" volume ls --format '{{.Name}}' 2>/dev/null | grep -E '^nix-build-stage-'); do
  mp=$("${CONTAINER_CLI}" volume inspect "$sv" --format '{{.Mountpoint}}' 2>/dev/null) || continue
  [ -n "$mp" ] || continue
  szg=$(du -sBG "$mp" 2>/dev/null | awk '{gsub(/G/,"",$1); print $1+0}')
  echo "[gc] ${sv} = ${szg:-?}G (cap ${CAP_G}G)"
  if [ "${szg:-0}" -gt "$CAP_G" ]; then
    echo "[gc] ${sv} over cap — removing (next build re-seeds the Nix store)"
    "${CONTAINER_CLI}" volume rm -f "$sv" >/dev/null 2>&1 || true
  fi
done

echo "[gc] free after:  $(freeG)G"
"${CONTAINER_CLI}" system df 2>/dev/null || true
