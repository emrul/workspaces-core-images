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
set -euo pipefail

emit() { echo "NIX_PROFILES=$1"; }

# Whole catalog on schedules or when there's no usable diff base.
[ "${CI_PIPELINE_SOURCE:-}" = "schedule" ] && { emit ""; exit 0; }
before="${CI_COMMIT_BEFORE_SHA:-}"
case "${before}" in
  ""|0000000000000000000000000000000000000000) emit ""; exit 0 ;;
esac
git rev-parse --quiet --verify "${before}^{commit}" >/dev/null 2>&1 || { emit ""; exit 0; }

changed="$(git diff --name-only "${before}" "${CI_COMMIT_SHA}" 2>/dev/null || true)"
[ -n "${changed}" ] || { emit ""; exit 0; }

apps=""
all=0
while IFS= read -r f; do
  [ -n "${f}" ] || continue
  case "${f}" in
    # Shared / base — anything that changes image content for every app.
    bin/build-nix-store-volume|bin/nix-profiles.toml|\
    dockerfile-kasm-core-minimal|dockerfile-nix-ubuntu|dockerfile-nix-app-finish|\
    runs/nix-portal/*|src/common/*|\
    src/ubuntu/install/nix/scripts/*|src/ubuntu/install/nix/units/*)
      all=1 ;;
    # Per-app wiring — src/ubuntu/install/nix/<app>/...
    src/ubuntu/install/nix/*/*)
      a="${f#src/ubuntu/install/nix/}"; a="${a%%/*}"
      case "${a}" in scripts|units) all=1 ;; *) apps="${apps} ${a}" ;; esac ;;
    # Everything else (docs, .gitlab-ci.yml, other ci-scripts) — not image content.
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
