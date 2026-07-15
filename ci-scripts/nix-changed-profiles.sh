#!/usr/bin/env bash
# nix-changed-profiles.sh — change-gating for the Nix app pipeline.
#
# Emits a dotenv line `NIX_PROFILES=<value>` (consumed by the build/publish jobs
# via artifacts:reports:dotenv), computed from the commit diff:
#
#   ""          build the whole catalog — a shared/base file changed, this is a
#               schedule, or the diff can't be determined (new branch / force).
#   "a b c"     build only these app profiles — only their
#               src/ubuntu/install/nix/<app>/ trees changed.
#   "__none__"  nothing image-relevant changed (docs / CI only) — build+publish
#               skip.
#
# A manual/trigger `NIX_PROFILES` pipeline variable has higher precedence than
# dotenv, so it always overrides this.
#
# Reuse outside CI (e.g. runs/nix-portal/dind-launch.sh): set NIX_CHANGED_FILES
# to a newline-separated list of changed paths and the git/SHA logic is skipped
# — the same path→profile mapping is applied. An explicitly-empty list means
# "genuinely nothing changed" → __none__ (unlike the CI no-diff-base case, which
# conservatively builds everything).
set -euo pipefail

# BASE_AFFECTED tracks whether the commit changed files baked INTO the nix-ubuntu
# base image (as opposed to build/assembly-only shared files). Emitted as a second
# dotenv line so the build job can refuse to run on a stale base — see the
# base-freshness guard in runs/nix-portal/dind-build.sh. Only set on a computable
# diff; the "can't tell" early exits (schedule / new branch) leave it 0 so they
# don't block routine whole-catalog rebuilds.
BASE_AFFECTED=0
emit() { echo "NIX_PROFILES=$1"; echo "NIX_BASE_AFFECTED=${BASE_AFFECTED}"; }

if [ -n "${NIX_CHANGED_FILES+x}" ]; then
  # Caller supplied the file list explicitly (manual / non-CI path).
  changed="${NIX_CHANGED_FILES}"
  [ -n "${changed}" ] || { emit "__none__"; exit 0; }
else
  # CI path: derive the file list from the commit range.
  # Whole catalog on schedules or when there's no usable diff base.
  [ "${CI_PIPELINE_SOURCE:-}" = "schedule" ] && { emit ""; exit 0; }
  before="${CI_COMMIT_BEFORE_SHA:-}"
  case "${before}" in
    ""|0000000000000000000000000000000000000000) emit ""; exit 0 ;;
  esac
  git rev-parse --quiet --verify "${before}^{commit}" >/dev/null 2>&1 || { emit ""; exit 0; }

  changed="$(git diff --name-only "${before}" "${CI_COMMIT_SHA}" 2>/dev/null || true)"
  [ -n "${changed}" ] || { emit ""; exit 0; }
fi

apps=""
all=0
while IFS= read -r f; do
  [ -n "${f}" ] || continue
  case "${f}" in
    # Base-IMAGE inputs — baked into nix-ubuntu (the two base dockerfiles + the
    # shared kasm-go/container-init tree + the nix activation scripts/units).
    # Changing these needs a base rebuild, so → whole catalog AND base-affected.
    dockerfile-kasm-core-minimal|dockerfile-nix-ubuntu|src/common/*|\
    src/ubuntu/install/nix/scripts/*|src/ubuntu/install/nix/units/*)
      all=1; BASE_AFFECTED=1 ;;
    # Build/assembly-only shared files — whole catalog, but the base image
    # content is unchanged, so NOT base-affected.
    bin/build-nix-store-volume|bin/nix-crane-assemble|bin/nix-profiles.toml|\
    dockerfile-nix-app-finish|runs/nix-portal/*)
      all=1 ;;
    # Per-app wiring — src/ubuntu/install/nix/<app>/...
    src/ubuntu/install/nix/*/*)
      a="${f#src/ubuntu/install/nix/}"; a="${a%%/*}"
      case "${a}" in scripts|units) all=1; BASE_AFFECTED=1 ;; *) apps="${apps} ${a}" ;; esac ;;
    # Self-hosted overlay (bin/nix-kasm-overlay). Shared machinery affects every
    # overlay-backed app → whole catalog; a per-app dir (pin.json/package.nix)
    # rebuilds only that app (dir name == profile name). The updater/manifest/docs
    # are not image content. See design/nix-self-hosted-packages.md.
    bin/nix-kasm-overlay/flake.nix|bin/nix-kasm-overlay/flake.lock|\
    bin/nix-kasm-overlay/overlay.nix|bin/nix-kasm-overlay/lib/*)
      all=1 ;;
    bin/nix-kasm-overlay/pkgs/*/*)
      a="${f#bin/nix-kasm-overlay/pkgs/}"; a="${a%%/*}"; apps="${apps} ${a}" ;;
    # Everything else (docs, .gitlab-ci.yml, other ci-scripts, the updater,
    # overlay manifest/README) — not image content.
    *) : ;;
  esac
done <<EOF
${changed}
EOF

[ "${all}" = 1 ] && { emit ""; exit 0; }
# Dedup + normalise without grep (grep -v on empty input exits 1, which would
# trip set -e/pipefail on the no-app-changes case).
uniq_apps=""
for a in $(printf '%s\n' ${apps} | sort -u); do uniq_apps="${uniq_apps}${a} "; done
uniq_apps="${uniq_apps% }"
[ -z "${uniq_apps}" ] && emit "__none__" || emit "${uniq_apps}"
