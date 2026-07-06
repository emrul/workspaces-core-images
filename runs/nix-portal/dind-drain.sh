#!/usr/bin/env bash
# dind-drain.sh — load + finish + push the already-built artifacts to forge, ONE
# at a time, deleting each tar immediately so local disk stays bounded. Recovers
# a run that filled the disk during the all-tars-then-load phase, and relies on
# registry layer-dedup (base/shared layers upload once).
#
# Runs INSIDE a privileged podman/stable container (store + repo + output dirs
# mounted). Token piped on STDIN (never argv/log).
#   /work, /var/lib/containers, /root/.cache/nix-build-output mounted.
#
# Pushes fat store → forge.emrul.dev/beta/nix-store-amd64:nix and each runnable
# nix-<app> → forge.emrul.dev/beta/nix-<app>:nix. Apps with no wiring (finish
# build fails) are reported and skipped.
set -uo pipefail

REG="${REG:-forge.emrul.dev}"; NS="${NS:-beta}"; RUSER="${RUSER:-agents}"
LTAG="${LTAG:-dev}"   # local tag the build produced
OUT=/root/.cache/nix-build-output
cd /work

TOK="$(cat)"; [ -n "${TOK}" ] || { echo "[drain] no token on stdin"; exit 1; }
printf '%s' "${TOK}" | podman login "${REG}" -u "${RUSER}" --password-stdin || { echo "[drain] login failed"; exit 1; }
unset TOK

free() { df -h /var/lib/containers | awk 'NR==2{print "[drain] disk avail: "$4}'; }

# ── fat store (all profiles) ──────────────────────────────────────────────
if [ -f "${OUT}/image.tar" ]; then
  echo "[drain] fat store: load + push"; free
  if podman load -i "${OUT}/image.tar"; then
    podman tag "localhost/nix-store-amd64:${LTAG}" "${REG}/${NS}/nix-store-amd64:nix" \
      && podman push "${REG}/${NS}/nix-store-amd64:nix" \
      && { echo "[drain] pushed nix-store-amd64:nix"; rm -f "${OUT}/image.tar"; }
  fi
fi

# ── per-app store-images → finish → push runnable ─────────────────────────
pushed=0; nowire=(); failed=()
for tar in "${OUT}"/app-*.tar; do
  [ -e "${tar}" ] || continue
  p="$(basename "${tar}")"; p="${p#app-}"; p="${p%.tar}"
  store_img="localhost/nix-store/${p}:${LTAG}"
  final="localhost/nix-${p}:${LTAG}"
  echo "[drain] === ${p} ==="; free
  if ! podman load -i "${tar}"; then echo "[drain] load FAIL ${p}"; failed+=("${p}"); rm -f "${tar}"; continue; fi
  if podman build --build-arg "STORE_IMAGE=${store_img}" --build-arg "PROFILE_NAME=${p}" \
        -f dockerfile-nix-app-finish -t "${final}" . ; then
    if podman tag "${final}" "${REG}/${NS}/nix-${p}:nix" && podman push "${REG}/${NS}/nix-${p}:nix"; then
      echo "[drain] pushed nix-${p}:nix"; pushed=$((pushed+1))
    else
      echo "[drain] push FAIL ${p}"; failed+=("${p}")
    fi
    podman rmi -f "${final}" >/dev/null 2>&1 || true
  else
    echo "[drain] no wiring / finish FAILED: ${p} (store-image only)"; nowire+=("${p}")
  fi
  podman rmi -f "${store_img}" >/dev/null 2>&1 || true   # free the delta
  rm -f "${tar}"                                          # free ~6G
done

echo "[drain] DONE: pushed=${pushed}  no-wiring=${#nowire[@]} [${nowire[*]:-}]  failed=${#failed[@]} [${failed[*]:-}]"
free
