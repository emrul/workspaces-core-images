#!/usr/bin/env bash
# Verify Tier A + Tier B opt-out impact on image size.
# Builds noble with all helpers excluded + KASM_LANG_PROFILE=en.
# Compare against kasm-noble-phase5:latest baseline.
set -uo pipefail

OUT=runs/lean
mkdir -p "$OUT"
LOG="$OUT/lean-noble.build.log"

# Build for the host arch by default; override with PLATFORM=linux/arm64
# (or amd64) to cross-build via qemu-user emulation.
case "$(uname -m)" in
    x86_64|amd64)  HOST_PLATFORM=linux/amd64 ;;
    aarch64|arm64) HOST_PLATFORM=linux/arm64 ;;
    *) echo "[lean-noble] unsupported arch: $(uname -m); pass PLATFORM=linux/<arch>" >&2; exit 1 ;;
esac
PLATFORM="${PLATFORM:-${HOST_PLATFORM}}"

echo "[lean-noble] building with all opt-outs + KASM_LANG_PROFILE=en (${PLATFORM})"
podman build --platform="${PLATFORM}" \
    --build-arg BASE_IMAGE=ubuntu:24.04 \
    --build-arg DISTRO=ubuntu \
    --build-arg LANG=en_US.UTF-8 --build-arg LANGUAGE=en_US:en --build-arg LC_ALL=en_US.UTF-8 \
    --build-arg START_PULSEAUDIO=1 --build-arg START_XFCE4=1 \
    --build-arg BG_IMG=bg_noble.png --build-arg EXTRA_SH=noop.sh \
    --build-arg INCLUDE_WEBCAM=0 \
    --build-arg INCLUDE_RECORDER=0 \
    --build-arg INCLUDE_GAMEPAD=0 \
    --build-arg INCLUDE_PRINTER=0 \
    --build-arg INCLUDE_SMARTCARD=0 \
    --build-arg INCLUDE_SQUID=0 \
    --build-arg KASM_LANG_PROFILE=en \
    -f dockerfile-kasm-core -t kasm-noble-lean:latest . > "$LOG" 2>&1

rc=$?
if [ $rc -ne 0 ]; then
    echo "[lean-noble] BUILD FAILED (rc=$rc) — last 40 lines:"
    tail -40 "$LOG"
    exit $rc
fi

echo "[lean-noble] build OK"
echo "--- size comparison ---"
podman images --format "{{.Repository}}:{{.Tag}}\t{{.Size}}" \
    | grep -E "kasm-noble-(phase5|lean)" \
    | tee "$OUT/sizes.tsv"
