#!/bin/sh
# post-build.sh — Chrome-specific build-time setup.
#
# Suppresses the "unsupported command-line flag: --no-sandbox" infobar via a
# managed enterprise policy. We launch with --no-sandbox (the GPU process must
# open the dri device nodes; mirrors kasmweb/chrome), and this hides the
# security-warning banner without further weakening the sandbox.
# nixpkgs google-chrome is the upstream binary, so it reads the stock
# /etc/opt/chrome/policies/managed path.
set -eu
mkdir -p /etc/opt/chrome/policies/managed
printf '%s\n' '{ "CommandLineFlagSecurityWarningsEnabled": false }' \
    > /etc/opt/chrome/policies/managed/kasm-flags.json
