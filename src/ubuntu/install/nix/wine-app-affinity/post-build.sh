#!/bin/sh
# Wine single-app image wiring: seed the desktop with compositing ON.
#
# Run by bin/nix-crane-assemble (stage_wiring_tar) with DESTDIR = the wiring-layer
# root, so everything staged here lands at the image root.
#
# Why: a Wine app that renders through DXVK/Vulkan presents straight to its X client
# window, and Wine keeps no pixel copy of such a window — `expose_window_surface` can
# only invalidate and hope the app repaints, which apps written for DWM (which always
# composites) do not do. With the base's `use_compositing=false` every menu popup or
# overlapping window therefore leaves a permanent stale/blank rectangle. Turning the
# compositor on fixes it outright; measured cost on llvmpipe is roughly +0.5 core of
# Xvnc during continuous redraw. See wine-assess OI-055 and
# docs/wine-debugging-playbook.md §14.
#
# kasm-setup copies /home/kasm-default-profile into a new user's $HOME on the first
# session, so this seeds every fresh session. A profile created before this change
# keeps its own copy with compositing off.
set -eu
D="${DESTDIR:?DESTDIR must be set}"
HERE="$(cd "$(dirname "$0")" && pwd)"

seed="${D}/home/kasm-default-profile/.config/xfce4/xfconf/xfce-perchannel-xml"
mkdir -p "${seed}"
cp "${HERE}/../scripts/wine-xfwm4-compositing.xml" "${seed}/xfwm4.xml"
