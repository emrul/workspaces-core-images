#!/usr/bin/env bash
# Phase 4.8 distro-matrix driver. Runs probes D/E/F against one or
# more images and aggregates pass/fail.
#
# Usage:
#   probe-matrix.sh <image-ref:label> [<image-ref:label> ...]
#
# Example:
#   probe-matrix.sh \
#     kasmweb/core-ubuntu-noble:dev:ubuntu-noble \
#     kasmweb/core-alpine-3:dev:alpine-3
#
# Without arguments runs against the local build of dockerfile-kasm-core
# (label "ubuntu-noble") only — useful for incremental dev.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
scripts="$repo_root/design/spike/scripts"

if [ "$#" -eq 0 ]; then
    set -- "kasm-prod-probe:latest:ubuntu-noble"
fi

overall=0
for entry in "$@"; do
    image="${entry%:*}"
    label="${entry##*:}"
    echo "==== matrix: $label ($image) ===="
    "$scripts/probe-D-boot.sh"     "$image" "$label" || overall=1
    "$scripts/probe-E-kasmvnc.sh"  "$image" "$label" || overall=1
    "$scripts/probe-F-shutdown.sh" "$image" "$label" || overall=1
done

if [ "$overall" -eq 0 ]; then
    echo "PASS  probe matrix green for: $*"
fi
exit "$overall"
