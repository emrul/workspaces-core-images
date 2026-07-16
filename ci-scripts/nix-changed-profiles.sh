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
# BASES_AFFECTED: which distro bases' INPUTS changed in this diff (space list of
# ubuntu|fedora|alpine). Unioned with nix-base-check.sh's upstream-digest staleness
# by the base-check job → NIX_BASES_REBUILD. NIX_BASE_AFFECTED stays ubuntu-only
# (the app base) for the dind-build.sh freshness guard.
BASES_AFFECTED=""
norm() { printf '%s\n' $1 | sort -u | tr '\n' ' ' | sed 's/^ *//;s/ *$//'; }
emit() {
  echo "NIX_PROFILES=$1"
  echo "NIX_BASE_AFFECTED=${BASE_AFFECTED}"
  echo "NIX_BASES_AFFECTED=$(norm "${BASES_AFFECTED}")"
}

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
    # Shared base inputs (src/common tree + shared nix activation scripts/units)
    # feed EVERY distro core/nix base. ubuntu is the app base → apps rebuild +
    # freshness guard. Matched before the general src/ubuntu/* case below.
    src/common/*|src/ubuntu/install/nix/scripts/*|src/ubuntu/install/nix/units/*)
      all=1; BASE_AFFECTED=1; BASES_AFFECTED="${BASES_AFFECTED} ubuntu fedora alpine resolute" ;;
    # ubuntu base dockerfiles → ubuntu base + apps rebuild.
    dockerfile-kasm-core-minimal|dockerfile-nix-ubuntu)
      all=1; BASE_AFFECTED=1; BASES_AFFECTED="${BASES_AFFECTED} ubuntu" ;;
    # fedora / alpine base inputs → ONLY that distro's base (apps are ubuntu-based,
    # so no app rebuild / no ubuntu freshness-guard trip).
    dockerfile-kasm-core-fedora|dockerfile-nix-fedora|src/fedora/*|src/fedora42/*)
      BASES_AFFECTED="${BASES_AFFECTED} fedora" ;;
    dockerfile-kasm-core-alpine|dockerfile-nix-alpine|src/alpine/*)
      BASES_AFFECTED="${BASES_AFFECTED} alpine" ;;
    # resolute base dockerfiles → ONLY the resolute base (apps are noble-based).
    # The bake helper itself is a resolute-base input too.
    dockerfile-kasm-core-ubuntu-resolute|dockerfile-nix-ubuntu-resolute|bin/nix-bake-closure)
      BASES_AFFECTED="${BASES_AFFECTED} resolute" ;;
    # Build/assembly-only shared files — whole catalog, but the base image
    # content is unchanged, so NOT base-affected.
    bin/build-nix-store-volume|bin/nix-crane-assemble|bin/nix-profiles.toml|\
    dockerfile-nix-app-finish|runs/nix-portal/*)
      all=1 ;;
    # Per-app wiring — src/ubuntu/install/nix/<app>/... (scripts|units handled above)
    src/ubuntu/install/nix/*/*)
      a="${f#src/ubuntu/install/nix/}"; a="${a%%/*}"; apps="${apps} ${a}" ;;
    # Self-hosted overlay shared machinery (loadPin, flake inputs, lib). It only
    # feeds consumers that reference path:/config/kasm-overlay# — i.e. the
    # overlay-backed CATALOG app(s) + the baked base components — NOT the whole
    # catalog (the other ~49 apps use plain nixpkgs and are unaffected). So scope
    # to those: currently `chrome` is the only overlay-backed app (grep
    # bin/nix-profiles.toml for kasm-overlay# — extend this list if that changes),
    # plus the resolute base (kasmvnc/profile_sync/audio_input/recorder/webcam/
    # gamepad are baked from the overlay). eval-gate no-ops chrome if unchanged.
    # A per-app dir (pkgs/<x>/pin.json|package.nix) is handled by the arms below.
    bin/nix-kasm-overlay/flake.nix|bin/nix-kasm-overlay/flake.lock|\
    bin/nix-kasm-overlay/overlay.nix|bin/nix-kasm-overlay/lib/*)
      apps="${apps} chrome"; BASES_AFFECTED="${BASES_AFFECTED} resolute" ;;
    # These Nix-packaged services are BASE components (baked into the resolute
    # base via nix-bake-closure), NOT catalog apps — a pin/package change
    # rebuilds the resolute base, not an app profile. Matched before the generic
    # pkgs case.
    bin/nix-kasm-overlay/pkgs/kasmvnc/*|bin/nix-kasm-overlay/pkgs/profile_sync/*|\
    bin/nix-kasm-overlay/pkgs/audio_input/*|bin/nix-kasm-overlay/pkgs/recorder/*|\
    bin/nix-kasm-overlay/pkgs/webcam/*|bin/nix-kasm-overlay/pkgs/gamepad/*)
      BASES_AFFECTED="${BASES_AFFECTED} resolute" ;;
    bin/nix-kasm-overlay/pkgs/*/*)
      a="${f#bin/nix-kasm-overlay/pkgs/}"; a="${a%%/*}"; apps="${apps} ${a}" ;;
    # Any OTHER src/ubuntu path (fonts, xfce, kasm_vnc, audio, printer, …) is
    # baked into the nix-ubuntu base via dockerfile-kasm-core-minimal, so it needs
    # an ubuntu base rebuild + app rebuild. Comes AFTER the nix/<app> case above so
    # per-app wiring stays app-scoped.
    src/ubuntu/*)
      all=1; BASE_AFFECTED=1; BASES_AFFECTED="${BASES_AFFECTED} ubuntu resolute" ;;
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
