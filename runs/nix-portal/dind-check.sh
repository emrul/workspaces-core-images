#!/usr/bin/env bash
# dind-check.sh — verify the Portal Nix build from OUTSIDE the build container.
# Run on the Portal host (or via ssh). Reports real artifacts (tars + images
# in the podman store), not just log text, so "is it actually building" has a
# truthful answer.
#
# Usage (on the Portal host):
#   runs/nix-portal/dind-check.sh            # one-shot report
#   runs/nix-portal/dind-check.sh --watch    # refresh every 20s until terminal
#   runs/nix-portal/dind-check.sh --watch 60 # custom interval
#
# Exit code: 0 = SUCCESS, 2 = still RUNNING, 1 = FAILED/unknown — scriptable.
set -uo pipefail

ROOT=/srv/nix-build
OUT="$ROOT/output"
NAME="${NAME:-nixbuild}"
IMG="${IMG:-quay.io/podman/stable}"
REPO="${REPO:-/home/ubuntu/dev/kasm/gitlab/workspaces-core-images}"

WATCH=0; INTERVAL=20
[ "${1:-}" = "--watch" ] && { WATCH=1; [ -n "${2:-}" ] && INTERVAL="$2"; }

container_state() { sudo nerdctl inspect -f '{{.State.Status}}|{{.State.ExitCode}}|{{.State.Running}}' "$NAME" 2>/dev/null; }

# Query the podman image store safely: exec into the running build container
# (one podman, no lock contention); fall back to a transient mount once it has
# exited (nothing else is touching the store then).
images_query() {
  local st; st="$(container_state)"
  if printf '%s' "$st" | grep -q '|true$'; then
    sudo nerdctl exec "$NAME" podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null
  else
    # --privileged: podman needs to set up its user namespace; without it the
    # transient query dies with "cannot clone: Operation not permitted".
    sudo nerdctl run --rm --privileged -v "$ROOT/containers:/var/lib/containers" "$IMG" \
      podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null
  fi
}

report() {
  local st status_line cstat cexit crun
  st="$(container_state)"; cstat="${st%%|*}"; crun="${st##*|}"; cexit="$(printf '%s' "$st" | cut -d'|' -f2)"
  status_line="$(cat "$OUT/STATUS" 2>/dev/null || echo '(no STATUS yet)')"

  # configured profile count (portal is amd64 → platform-restricted ones still
  # count here; treat as the upper bound of expected app images).
  local expected; expected="$(grep -cE '^\[profiles\.' "$REPO/bin/nix-profiles.toml" 2>/dev/null || echo '?')"

  echo "──────────────────────────────────────────────────────────────"
  echo "  $(date -u +%FT%TZ)   container: ${cstat:-absent} (running=${crun:-?} exit=${cexit:-?})"
  echo "  STATUS:   ${status_line}"
  echo "──────────────────────────────────────────────────────────────"

  # Images now build straight into the overlay store (no tars), so the store
  # query below IS the live progress signal — runnable nix-<app> count climbs
  # as the build loop runs.
  echo "  configured profiles: ${expected}"

  # actual images in the persistent podman store (the real verification)
  local imgs fat nstore nfinal
  imgs="$(images_query | grep -iE 'nix' | sort)"
  fat="$(printf '%s\n' "$imgs"   | grep -E 'nix-store-(amd64|arm64)' || true)"
  nstore="$(printf '%s\n' "$imgs" | grep -cE 'nix-store/' || true)"
  nfinal="$(printf '%s\n' "$imgs" | grep -E '/nix-[a-z0-9-]+:' | grep -vE 'nix-store|nix-ubuntu' | grep -c . || true)"
  echo "  in podman store:  fat=[${fat:-none}]  store-images=${nstore}  runnable nix-<app>=${nfinal}"
  if [ "${VERBOSE:-0}" = "1" ]; then printf '%s\n' "$imgs" | sed 's/^/      /'; fi

  echo "  ── last log lines ──"
  tail -n 12 "$OUT/build.log" 2>/dev/null | sed 's/^/    /' || echo "    (no log yet)"

  case "$status_line" in
    SUCCESS*) return 0 ;;
    FAILED*)  return 1 ;;
    RUNNING*) return 2 ;;
    *) [ "${cstat:-}" = "running" ] && return 2 || return 1 ;;
  esac
}

if [ "$WATCH" = 1 ]; then
  while :; do
    clear 2>/dev/null || true
    report; rc=$?
    [ "$rc" != 2 ] && { echo; echo "[check] terminal state (rc=$rc); stopping watch."; exit $rc; }
    sleep "$INTERVAL"
  done
else
  report
fi
