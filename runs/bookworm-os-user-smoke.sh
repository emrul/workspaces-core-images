#!/usr/bin/env bash
exec env IMAGE=localhost/kasm-bookworm-phase6:latest \
         OUT=runs/bookworm \
         PREFIX=bookworm \
    bash "$(dirname "$0")/noble-os-user-smoke.sh"
