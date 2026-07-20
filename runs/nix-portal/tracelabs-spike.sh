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
# Published nixpkgs revs (dev.kasm.nix.rev) of the catalog browsers, so the
# composed requires-deltas dedup byte-for-byte with the standalone images.
# Read from the registry 2026-07-20; override via env for a later re-pin.
REV_A="${REV_A:-61b7c44c4073f0b827768aff0049561b5110ea5a}"  # chromium, brave, firefox
REV_B="${REV_B:-fd1462031fdee08f65fd0b4c6b64e22239a77870}"  # obsidian, tor-browser
# nixpkgs rev the TraceLabs pkgs (nixpkgs tools + overlay derivations) build
# against — matches bin/nix-kasm-overlay's flake pin, where the 4 overlay tools
# were validated. TraceLabs pkgs are profile-unique (no dedup constraint).
OVERLAY_REV="${OVERLAY_REV:-d407951447dcd00442e97087bf374aad70c04cea}"

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
  echo "# ─── Trace Labs OSINT v1 profiles (isolated config; design §2/§3) ───"
  echo "[profiles.tracelabs]"
  echo 'kasm_name = "tracelabs-osint"'
  echo 'fat_store = false          # OSINT desktop, not a single-app launch'
  echo 'platforms = ["amd64"]'
  echo 'app_base  = "resolute"     # inert here; the build passes --app-base-image'
  echo "ref       = \"github:NixOS/nixpkgs/${OVERLAY_REV}\""
  echo 'pkgs = ['
  echo '    # nixpkgs, unique to TraceLabs (design §3)'
  echo '    "nixpkgs#sherlock",'
  echo '    "nixpkgs#sn0int",'
  echo '    "nixpkgs#translate-shell",'
  echo '    "nixpkgs#exiftool",'
  echo '    "nixpkgs#steghide",'
  echo '    "nixpkgs#stegseek",'
  echo '    "nixpkgs#tor",                       # CLI only; not auto-started'
  echo '    "nixpkgs#python3Packages.shodan",    # needs API key at runtime'
  echo '    # Maltego CE, keyring-disabled wrapper (overlay); unfree (allowUnfree global)'
  echo '    "path:/config/kasm-overlay#maltego",'
  echo '    # overlay derivations — not in nixpkgs (design §4)'
  echo '    "path:/config/kasm-overlay#spiderfoot",'
  echo '    "path:/config/kasm-overlay#phoneinfoga",'
  echo '    "path:/config/kasm-overlay#sublist3r",'
  echo '    "path:/config/kasm-overlay#metagoofil",'
  echo ']'
  echo '# composed via requires → three-way blob dedup with the standalone apps + fat store'
  echo 'requires = ["obsidian", "chromium", "firefox", "brave", "torbrowser"]'
  echo ""
  echo "# requires profiles, each PINNED to its published rev so the deltas dedup."
  echo "[profiles.firefox]"
  echo 'pkgs = ["nixpkgs#firefox"]'
  echo "ref  = \"github:NixOS/nixpkgs/${REV_A}\""
  echo ""
  echo "[profiles.chromium]"
  echo 'pkgs = ["nixpkgs#chromium"]'
  echo "ref  = \"github:NixOS/nixpkgs/${REV_A}\""
  echo ""
  echo "[profiles.brave]"
  echo 'pkgs = ["nixpkgs#brave"]'
  echo "ref  = \"github:NixOS/nixpkgs/${REV_A}\""
  echo ""
  echo "[profiles.obsidian]"
  echo 'pkgs = ["nixpkgs#obsidian"]'
  echo "ref  = \"github:NixOS/nixpkgs/${REV_B}\""
  echo ""
  echo "[profiles.torbrowser]"
  echo 'pkgs = ["nixpkgs#tor-browser"]'
  echo 'kasm_name = "tor-browser"'
  echo "ref  = \"github:NixOS/nixpkgs/${REV_B}\""
} >> "${SPIKE_TOML}"

log "v1 config profiles: $(grep -c '^\[profiles\.' "${SPIKE_TOML}") (expect 6: tracelabs + 5 requires)"

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
export PROFILES="tracelabs,obsidian,chromium,firefox,brave,torbrowser"
export EMIT_APPS=1
unset PUSH || true
bash "${REPO}/runs/nix-portal/dind-build.sh"

log "build done — resolute desktop image: localhost/nix-resolute-tracelabs:dev"
log "next: verify /nix-stores/tracelabs unions + tools resolve, then push :nix"

log "build done — run the dedup digest check (§3) next"
