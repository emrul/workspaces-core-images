#!/usr/bin/env sh
# post-build.sh — TraceLabs wiring baked into the per-app image by
# nix-crane-assemble (runs with DESTDIR = the wiring layer root).
#
# Marks this image as a DESKTOP profile so nix-activate keeps the full desktop
# session (panel/xfdesktop managed by the XFCE session) and runs the shell on
# the clean system environment — instead of the single-app no-panel layout +
# nix app-env that a lone active profile would otherwise trigger, which breaks
# desktop rendering (blank/white, broken icons). See
# design/tracelabs-osint-image.md §5.1 and src/ubuntu/install/nix/scripts/nix-activate.
# The marker is jq-free on purpose (nix-activate can't rely on jq at runtime).
set -eu
: "${DESTDIR:?post-build.sh must be run with DESTDIR set by nix-crane-assemble}"
mkdir -p "${DESTDIR}/etc"
: > "${DESTDIR}/etc/nix-desktop-mode"
echo "[tracelabs post-build] baked /etc/nix-desktop-mode (desktop profile)" >&2
