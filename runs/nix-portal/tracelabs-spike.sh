#!/usr/bin/env bash
# tracelabs-spike.sh — Phase-0 spike for the Trace Labs OSINT image
# (design/tracelabs-osint-image.md §9 Phase 0). Runs on the forge (DinD host).
#
# Proves, in isolation from the catalog, that:
#   (a) a minimal TraceLabs desktop assembles on the RESOLUTE base and emits a
#       standalone image (not skipped for want of custom_startup.sh), and
#   (b) the composed `profile-firefox` layer blob dedups byte-for-byte with the
#       already-published firefox:nix (the whole point of composition).
#
# It NEVER pushes and uses an ISOLATED config, so it cannot perturb the
# catalog fat store. firefox/torbrowser are pinned to the CURRENTLY-PUBLISHED
# resolved rev (not floating nixos-unstable) — otherwise a separate build
# resolves a different commit and the dedup digest would not match (design
# review round 3, F1).
#
# Env:
#   FIREFOX_REV     resolved nixpkgs rev of the published firefox:nix
#                   (dev.kasm.nix.rev label). Required — the dedup test is
#                   meaningless without it.
#   TORBROWSER_REV  likewise for torbrowser (default: base ref if unset).
#   RESOLUTE_BASE   app base image (default localhost/nix-ubuntu-resolute:dev)
#   REPO            repo root (default: two levels up from this script)
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC_TOML="${REPO}/bin/nix-profiles.toml"
SPIKE_TOML="${SPIKE_TOML:-${REPO}/bin/nix-profiles-tracelabs-spike.toml}"
RESOLUTE_BASE="${RESOLUTE_BASE:-localhost/nix-ubuntu-resolute:dev}"
: "${FIREFOX_REV:?set FIREFOX_REV to the published firefox:nix dev.kasm.nix.rev}"
TORBROWSER_REV="${TORBROWSER_REV:-}"

log() { printf '[spike] %s\n' "$*" >&2; }

# ── 1. generate the isolated config ───────────────────────────────────────
# Keep [base]/[gpu]/[promote]/[layers.*] VERBATIM from the catalog config (so
# the firefox delta is partitioned identically → identical blob), then append
# only the three spike profiles. Everything before the first [profiles.*] is
# the shared machinery.
log "generating ${SPIKE_TOML} from ${SRC_TOML}"
awk '/^\[profiles\./{exit} {print}' "${SRC_TOML}" > "${SPIKE_TOML}"

{
  echo ""
  echo "# ─── Trace Labs OSINT Phase-0 spike profiles (isolated; never pushed) ───"
  echo "[profiles.tracelabs]"
  echo 'kasm_name = "tracelabs-osint"'
  echo 'fat_store = false          # inert until Phase 1 (fatApps split) — this'
  echo '                           # build is --profile-scoped + never pushed anyway'
  echo 'platforms = ["amd64"]'
  echo 'app_base  = "resolute"     # inert here; the build passes --app-base-image'
  echo 'pkgs = ['
  echo '    "nixpkgs#sherlock",'
  echo '    "nixpkgs#sn0int",'
  echo '    "nixpkgs#maltego",     # unfree; allowUnfree already global (build:251)'
  echo ']'
  echo 'requires = ["firefox", "torbrowser"]'
  echo ""
  echo "[profiles.firefox]"
  echo 'pkgs = ["nixpkgs#firefox"]'
  echo "ref  = \"github:NixOS/nixpkgs/${FIREFOX_REV}\"   # PINNED to published rev"
  echo ""
  echo "[profiles.torbrowser]"
  echo 'pkgs = ["nixpkgs#tor-browser"]'
  echo 'kasm_name = "tor-browser"'
  if [ -n "${TORBROWSER_REV}" ]; then
    echo "ref = \"github:NixOS/nixpkgs/${TORBROWSER_REV}\""
  fi
} >> "${SPIKE_TOML}"

log "spike config profiles: $(grep -c '^\[profiles\.' "${SPIKE_TOML}") (expect 3)"

# ── 2. build (on the forge, via the DinD driver) ──────────────────────────
# APP_BASE_IMAGE + NIX_CONFIG_FILE overrides are honoured by dind-build.sh.
# SCOPED_BUILD=1 narrows to the 3 profiles; no PUSH.
log "building tracelabs+firefox+torbrowser + resolute desktop image (scoped, no push)"
# APP_BASE_IMAGE is used only to stage per-app partitions/Dockerfile.tracelabs;
# tracelabs has no custom_startup.sh so the per-app (single-store) loop SKIPS it
# — no broken /nix/store->/store image is emitted. The desktop image comes from
# RESOLUTE_APPS below (multi-store: /nix-stores/tracelabs on the Resolute base).
export APP_BASE_IMAGE="${RESOLUTE_BASE}"
export RESOLUTE_APPS="tracelabs"
export RESOLUTE_BASE_IMAGE="${RESOLUTE_BASE}"
export NIX_CONFIG_FILE="${SPIKE_TOML}"
export SCOPED_BUILD=1
export PROFILES="tracelabs,firefox,torbrowser"
export EMIT_APPS=1
unset PUSH || true
bash "${REPO}/runs/nix-portal/dind-build.sh"

log "build done — resolute desktop image: localhost/nix-resolute-tracelabs:dev"
log "next: verify /nix-stores/tracelabs unions + tools resolve, then push :nix"

log "build done — run the dedup digest check (§3) next"
