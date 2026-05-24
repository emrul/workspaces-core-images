#!/usr/bin/env bash
# Phase 6 batch — build + median + smoke for the 9 distros.
# Single-path harness (the bash arm of the dual-path probe was retired
# when the bash chain was deleted in Phase 6).
# Each row: <tag>:<dockerfile>:<base>:<bg>:<DISTRO>
# (TSV-separated — base/tag values may contain ':')
set -uo pipefail

# DISTRO column matches `distro:` in ci-scripts/template-vars.yaml — the
# install scripts (package_rules.sh etc.) gate on the *versioned* form
# (fedora43, oracle9, rockylinux9, almalinux9, parrotos7, ...) so the
# arg cannot be just the family name.
# kali/parrotos bases need the docker.io/ prefix because podman's
# short-name resolution refuses the unqualified name without a TTY.
PHASE_TARGETS=$(cat <<'EOF'
kali	dockerfile-kasm-core	docker.io/kalilinux/kali-rolling:latest	bg_kasm.png	kali
fedora43	dockerfile-kasm-core-fedora	fedora:43	bg_fedora.png	fedora43
opensuse	dockerfile-kasm-core-suse	opensuse/leap:16.0	bg_opensuse.png	opensuse
oracle9	dockerfile-kasm-core-oracle	oraclelinux:9	bg_oracle.png	oracle9
rockylinux9	dockerfile-kasm-core-oracle	rockylinux:9	bg_rocky.png	rockylinux9
rockylinux8	dockerfile-kasm-core-oracle	rockylinux:8	bg_rocky.png	rockylinux8
almalinux9	dockerfile-kasm-core-oracle	almalinux:9	bg_almalinux.png	almalinux9
parrotos7	dockerfile-kasm-core	docker.io/parrotsec/core:7.1	bg_parrotos6.jpg	parrotos7
alpine	dockerfile-kasm-core-alpine	alpine:3.22	bg_alpine.png	alpine
EOF
)

OUT=runs/phase6
mkdir -p "$OUT"
: > "$OUT/summary.tsv"

# Build for the host arch by default; override with PLATFORM=linux/<arch>
# to cross-build via qemu-user emulation.
case "$(uname -m)" in
    x86_64|amd64)  HOST_PLATFORM=linux/amd64 ;;
    aarch64|arm64) HOST_PLATFORM=linux/arm64 ;;
    *) echo "all-distros: unsupported arch: $(uname -m); pass PLATFORM=linux/<arch>" >&2; exit 1 ;;
esac
PLATFORM="${PLATFORM:-${HOST_PLATFORM}}"
echo "all-distros: building for ${PLATFORM}"

echo -e "distro\tbuild\tttfl_trace_ci_median\tcgmem_ci_MiB\taudio_out_ws_fails\tos_user_uid_correct\tfind_uid1000_count" >> "$OUT/summary.tsv"

while IFS=$'\t' read -r tag df base bg distro; do
    [ -z "$tag" ] && continue
    img="localhost/kasm-${tag}-phase6:latest"
    runs_dir="runs/${tag}"
    mkdir -p "$runs_dir"
    echo "############################"
    echo "###  $tag — building"
    echo "###    df=$df base=$base bg=$bg DISTRO=$distro"
    echo "############################"
    build_out="$OUT/${tag}.build.log"
    if ! podman build --platform="${PLATFORM}" \
            --build-arg BASE_IMAGE="$base" \
            --build-arg DISTRO="$distro" \
            --build-arg LANG=en_US.UTF-8 --build-arg LANGUAGE=en_US:en --build-arg LC_ALL=en_US.UTF-8 \
            --build-arg START_PULSEAUDIO=1 --build-arg START_XFCE4=1 \
            --build-arg BG_IMG="$bg" --build-arg EXTRA_SH=noop.sh \
            -f "$df" -t "kasm-${tag}-phase6:latest" . > "$build_out" 2>&1; then
        echo "[$tag] BUILD FAILED — last 30 lines:"
        tail -30 "$build_out"
        echo -e "${tag}\tFAIL_BUILD\t-\t-\t-\t-\t-" >> "$OUT/summary.tsv"
        continue
    fi
    echo "[$tag] build OK"
    sha=$(podman inspect --format '{{.Id}}' "$img")

    # Median-of-3 (faster than 5; same script with N=3 to fit 9 distros in session).
    echo "[$tag] median-of-3 single-path probe"
    IMAGE="$sha" OUT="$runs_dir" PREFIX="$tag" N=3 SOAK=20 \
        bash runs/noble-median-of-5.sh > "$runs_dir/median.log" 2>&1
    medians=$(tail -3 "$runs_dir/median.log")

    # Functional smoke
    echo "[$tag] functional smoke"
    IMAGE="$sha" OUT="$runs_dir" PREFIX="$tag" \
        bash runs/noble-functional-smoke.sh > "$runs_dir/functional-smoke.log" 2>&1

    # OS-user smoke (alice + default)
    echo "[$tag] OS-user smoke"
    IMAGE="$sha" OUT="$runs_dir" PREFIX="$tag" \
        bash runs/noble-os-user-smoke.sh > "$runs_dir/os-user-smoke.log" 2>&1

    # Extract summary metrics for the row.
    ttfl_ci=$(grep -oE "^  ci  ttfl_trace_ms median=[0-9.]*" "$runs_dir/median.log" | head -1 | awk -F= '{print $2}')
    cgmem_ci=$(grep -oE "^  ci  ttfl_trace_ms.*cgmem_MiB median=[0-9]*" "$runs_dir/median.log" | head -1 | grep -oE "cgmem_MiB median=[0-9]*" | awk -F= '{print $2}')
    aof=$(python3 -c "
import json, glob
fails=0
for p in glob.glob('${runs_dir}/ci-*.trace.jsonl'):
    for ln in open(p):
        try: d=json.loads(ln)
        except: continue
        if d.get('unit')=='audio-out-ws.service' and d.get('phase')=='exited' and d.get('failed'):
            fails += 1
print(fails)
" 2>/dev/null)
    uid_ok=$(grep -c "uid=1500(alice)" "$runs_dir/os-user-smoke.log" 2>/dev/null)
    uid1000_count=$(grep -oE "count=[0-9]+" "$runs_dir/os-user-smoke.log" | head -1 | awk -F= '{print $2}')
    echo -e "${tag}\tOK\t${ttfl_ci:-?}\t${cgmem_ci:-?}\t${aof:-?}\t${uid_ok:-0}\t${uid1000_count:-?}" >> "$OUT/summary.tsv"
    echo "[$tag] DONE: $medians  audio-out-ws-fails=$aof  uid1000=$uid1000_count"
    echo
done <<< "$PHASE_TARGETS"

echo
echo "==== ALL DISTROS DONE ===="
column -ts$'\t' "$OUT/summary.tsv"
