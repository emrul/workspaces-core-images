#!/usr/bin/env bash
# Kasm Nix-images PoC — one-shot demo.
#
# Prerequisites (one-time): see design/nix/docs/demo-environment-setup.md
#   - Docker + Nix (flakes), big-disk relocation if needed
#   - core image:        localhost/kasm-core-ubuntu-noble:dev
#   - runtime base:       localhost/nix-ubuntu:dev, pushed to a local
#                         registry at localhost:5000, with the manifest
#                         captured to nix/base-manifest.json
#
# What this shows:
#   1. build the 5-app set as nix2container images (dedup-proof + runnable)
#   2. MEASURE cross-image layer sharing (pull fat -> any app is ~0 bytes)
#   3. run a self-contained single-app image (Chrome) in KasmVNC
#   4. run the fat image and select apps at runtime via NIX_APP_PROFILES
#
# Re-runnable. Uses host ports 6902 (single-app) and 6903 (fat) to avoid
# colliding with anything on 6901.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/../nix"
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true

APPS="chrome chromium vscode firefox audacity"
TAG=spike

echo "== 1. Build all images =="
nix build .#fat .#fat-run $(for a in $APPS; do printf '.#%s .#%s-run ' "$a" "$a"; done) -L

echo "== 2. Load into Docker =="
for a in $APPS fat; do
  nix run ".#${a}.copyToDockerDaemon"     >/dev/null 2>&1
  nix run ".#${a}-run.copyToDockerDaemon" >/dev/null 2>&1
done

echo "== 3. Cross-image layer sharing =="
IMGS="$APPS fat" TAG="$TAG" nix shell nixpkgs#skopeo --command bash "$here/nix-dedup.sh"

# Chromium/Chrome run WITH their namespace sandbox (no --no-sandbox) via the
# repo's tuned seccomp profile (permits unprivileged userns) — see
# docs/seccomp-how-to.md. apparmor=unconfined + the host sysctl below are
# needed on Ubuntu 23.10+ where AppArmor also restricts unprivileged userns.
#
# HOST PREREQUISITE (run once, see docs/seccomp-how-to.md):
#   sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
#
# Web login user is `kasm-user` (hyphen).
SECCOMP="--security-opt seccomp=$here/../src/common/seccomp/chrome.json --security-opt apparmor=unconfined"

echo "== 4. Self-contained single-app image: Chrome =="
docker rm -f kasm-chrome >/dev/null 2>&1 || true
docker run -d --name kasm-chrome --shm-size=1g $SECCOMP \
  -e VNC_PW=password -p 6902:6901 "nix-chrome-run:${TAG}" >/dev/null
echo "   -> https://<host>:6902   (kasm-user / password)"

echo "== 5. Fat image, apps selected at runtime =="
docker rm -f kasm-fat >/dev/null 2>&1 || true
docker run -d --name kasm-fat --shm-size=1g $SECCOMP \
  -e NIX_APP_PROFILES=chrome,vscode,firefox \
  -e VNC_PW=password -p 6903:6901 "nix-fat-run:${TAG}" >/dev/null
echo "   -> https://<host>:6903   (kasm-user / password)  [Chrome + VS Code + Firefox]"

cat <<'NOTE'

== CVE-cadence simulation (manual) ==
  Edit nix/flake.nix: give chrome a faster ref, e.g.
      chrome = { pkg = (import nixpkgsUnstable {...}).google-chrome; ... };
  then:
      nix build .#chrome-run && nix run .#chrome-run.copyToDockerDaemon
      IMGS="chrome chromium fat" nix shell nixpkgs#skopeo --command bash runs/nix-dedup.sh
  Observe: only chrome's app layer digest changes; the shared base layer and
  every other app's layer are untouched -> a Chrome security rebuild repushes
  just Chrome's delta.
NOTE
