#!/bin/sh
# Trace Labs OSINT — desktop-asset wiring. Run by the Resolute assembly
# (bin/nix-crane-assemble stage_resolute_wiring_tar) with DESTDIR = the
# wiring-layer root; everything staged under $DESTDIR lands at the image root.
# See design/tracelabs-osint-image.md §5 and design/tracelabs-build-runbook.md.
set -eu
D="${DESTDIR:?DESTDIR must be set}"
HERE="$(cd "$(dirname "$0")" && pwd)"
A="${HERE}/assets"

# 1. TL Vault + CTF guides + desktop launchers → the Kasm default-profile
#    Desktop seed. kasm-setup copies /home/kasm-default-profile into each NEW
#    user's home on first session and never clobbers a returning profile
#    (design §5.3), so the vault seeds exactly once per user.
seed="${D}/home/kasm-default-profile/Desktop"
mkdir -p "${seed}"
cp -a "${A}/desktop-seed/." "${seed}/"

# 2. TraceLabs wallpaper. The baked XFCE backdrop already points at
#    /usr/share/backgrounds/bg_default.png, so overriding that file rebrands the
#    desktop with no xfconf edit; ship the full resolution set too.
mkdir -p "${D}/usr/share/backgrounds/tracelabs"
cp -a "${A}/backgrounds-tracelabs/." "${D}/usr/share/backgrounds/tracelabs/"
cp -a "${A}/backgrounds-tracelabs/tracelabs-1920x1080.png" \
      "${D}/usr/share/backgrounds/bg_default.png"

# 3. Firefox OSINT security/UX policy (nixpkgs firefox reads /etc/firefox/policies).
mkdir -p "${D}/etc/firefox/policies"
cp -a "${A}/firefox-policies.json" "${D}/etc/firefox/policies/policies.json"

# 4. TraceLabs category icon (for the OSINT app-menu categories, Phase-1).
mkdir -p "${D}/usr/share/icons/hicolor/scalable/categories"
cp -a "${A}/tracelabs.svg" \
      "${D}/usr/share/icons/hicolor/scalable/categories/tracelabs.svg"

# Force world-read: the asset source may be 0600 on a mutagen-synced build host
# (same reason the core dockerfiles chmod backgrounds/extra). The default-profile
# Desktop must be readable so kasm-setup can seed it per user.
chmod -R a+rX \
    "${D}/home/kasm-default-profile" \
    "${D}/usr/share/backgrounds" \
    "${D}/etc/firefox" \
    "${D}/usr/share/icons/hicolor/scalable/categories" 2>/dev/null || true

echo "tracelabs post-build: staged vault + wallpaper + firefox policy under ${D}" >&2
