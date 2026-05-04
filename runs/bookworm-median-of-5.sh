#!/usr/bin/env bash
# Phase 5 5.x.1 + 5.x.2 (debian bookworm) — median-of-5 boot capture.
# Identical to runs/noble-median-of-5.sh but for kasm-bookworm-phase5.
exec env IMAGE=localhost/kasm-bookworm-phase6:latest \
         OUT=runs/bookworm \
         PREFIX=bookworm \
         N="${N:-5}" SOAK="${SOAK:-25}" \
    bash "$(dirname "$0")/noble-median-of-5.sh"
