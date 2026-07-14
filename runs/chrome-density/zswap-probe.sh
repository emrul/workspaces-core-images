#!/usr/bin/env bash
# zswap-probe.sh — measure how compressible Chrome's anon is under zswap.
#
# Enables zswap (zstd) on the host, launches a memory-LIMITED heavy Chrome fleet
# (per-container --memory below the natural working set, so the kernel reclaims
# cold anon into the compressed pool), then reports:
#   * global compression ratio  = stored_pages*PAGE / pool_total_size
#   * per-container real-RAM split: resident anon vs compressed (memory.zswap.current)
#     vs written-back-to-disk (memory.swap.current)
#   * memory pressure (/proc/pressure/memory 'full') = the thrash guardrail
#
# Host-level change (zswap enable) — reversible: sudo tee 0 > .../enabled.
# Run as a user with passwordless sudo. Leaves zswap ENABLED (harmless cache).
set -euo pipefail

N="${N:-6}"                 # heavy sessions to launch
MEM="${MEM:-600m}"          # per-container hard RAM cap (forces reclaim → zswap)
MEMSWAP="${MEMSWAP:-3g}"    # memory+swap ceiling (headroom so it swaps, not OOMs)
SETTLE="${SETTLE:-40}"
COMP="${COMP:-zstd}"
HEAVY_PORT="${HEAVY_PORT:-8800}"
HEAVY_SITES="${HEAVY_SITES:-8}"

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKLOAD_DIR="${HERE}/workload"
IMAGE="${IMAGE:-registry.gitlab.com/kasm-technologies/labs-sandbox/kasm-nix/chrome:nix}"
SECCOMP="$(cd "${HERE}/../../src/common/seccomp" && pwd)/chrome.json"
PREFIX="zp"
Z=/sys/module/zswap/parameters
ZD=/sys/kernel/debug/zswap
log(){ printf '[zswap-probe] %s\n' "$*" >&2; }

SERVER_PID=""
cleanup(){
  docker ps -aq --filter "name=^${PREFIX}_" | xargs -r docker rm -f >/dev/null 2>&1 || true
  [ -n "${SERVER_PID}" ] && kill "${SERVER_PID}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── enable zswap ────────────────────────────────────────────────────────────
log "enabling zswap (compressor=${COMP})"
echo "${COMP}" | sudo tee "${Z}/compressor" >/dev/null 2>&1 || {
  sudo modprobe "${COMP}" 2>/dev/null || true
  echo "${COMP}" | sudo tee "${Z}/compressor" >/dev/null; }
echo 1 | sudo tee "${Z}/enabled" >/dev/null
log "zswap: enabled=$(cat ${Z}/enabled) compressor=$(cat ${Z}/compressor) zpool=$(cat ${Z}/zpool) max_pool_percent=$(cat ${Z}/max_pool_percent)"
sudo mount -t debugfs none /sys/kernel/debug 2>/dev/null || true

zstat(){ sudo cat "${ZD}/$1" 2>/dev/null || echo 0; }
psi_full(){ awk '/^full/{for(i=1;i<=NF;i++)if($i ~ /^avg10=/){sub("avg10=","",$i);print $i}}' /proc/pressure/memory; }

# ── static server + site aliases ────────────────────────────────────────────
GW="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo 172.17.0.1)"
( cd "${WORKLOAD_DIR}" && exec python3 -m http.server "${HEAVY_PORT}" --bind "${GW}" ) >/dev/null 2>&1 &
SERVER_PID="$!"; sleep 1
ah=(); urls=""
for k in $(seq 1 "${HEAVY_SITES}"); do ah+=( --add-host "site${k}:${GW}" ); urls="${urls} http://site${k}:${HEAVY_PORT}/heavy.html"; done

cleanup_containers_only(){ docker ps -aq --filter "name=^${PREFIX}_" | xargs -r docker rm -f >/dev/null 2>&1 || true; }
cleanup_containers_only

log "launching ${N} heavy sessions, --memory=${MEM} --memory-swap=${MEMSWAP}"
for i in $(seq 1 "${N}"); do
  docker run -d --name "${PREFIX}_${i}" "${ah[@]}" \
    --security-opt seccomp="${SECCOMP}" --security-opt apparmor=unconfined \
    --memory="${MEM}" --memory-swap="${MEMSWAP}" --shm-size=512m \
    -e VNC_PW=password -e APP_ARGS="${urls}" \
    -v "${WORKLOAD_DIR}:/workload:ro" "${IMAGE}" >/dev/null
done
log "settling ${SETTLE}s…"; sleep "${SETTLE}"

# ── global compression ratio ────────────────────────────────────────────────
PAGE=4096
stored="$(zstat stored_pages)"; pool="$(zstat pool_total_size)"; wb="$(zstat written_back_pages)"
if [ "${pool}" -gt 0 ] 2>/dev/null; then
  ratio="$(awk -v s="${stored}" -v p="${pool}" -v pg="${PAGE}" 'BEGIN{printf "%.2f", (s*pg)/p}')"
else ratio="n/a"; fi
log "GLOBAL zswap: stored_pages=${stored} ($(awk -v s=${stored} -v pg=${PAGE} 'BEGIN{printf "%.0f", s*pg/1048576}') MiB uncompressed) pool_total=$(awk -v p=${pool} 'BEGIN{printf "%.0f", p/1048576}') MiB → ratio=${ratio}:1  written_back=${wb} pages"
log "PSI memory full avg10=$(psi_full)"

# ── per-container real-RAM split ────────────────────────────────────────────
# cgPSI = this container's OWN memory pressure against its cap (the usability
# signal — host-wide PSI stays ~0 while the host has free RAM).
printf '%-8s %10s %10s %10s %10s %12s\n' container anon_MiB zswap_MiB swap_MiB curr_MiB cgPSIfull10
csum=0; cn=0
for i in $(seq 1 "${N}"); do
  c="${PREFIX}_${i}"
  docker inspect -f '{{.State.Running}}' "${c}" 2>/dev/null | grep -q true || { printf '%-8s %10s\n' "${c}" "DEAD/OOM"; continue; }
  read -r an zw sw cur ps < <(docker exec "${c}" sh -c '
    a=$(awk "/^anon /{print \$2}" /sys/fs/cgroup/memory.stat 2>/dev/null||echo 0)
    z=$(cat /sys/fs/cgroup/memory.zswap.current 2>/dev/null||echo 0)
    s=$(cat /sys/fs/cgroup/memory.swap.current 2>/dev/null||echo 0)
    c=$(cat /sys/fs/cgroup/memory.current 2>/dev/null||echo 0)
    p=$(awk "/^full/{for(i=1;i<=NF;i++)if(\$i ~ /^avg10=/){sub(\"avg10=\",\"\",\$i);print \$i}}" /sys/fs/cgroup/memory.pressure 2>/dev/null||echo 0)
    echo "$a $z $s $c $p"' 2>/dev/null || echo "0 0 0 0 0")
  printf '%-8s %10.0f %10.0f %10.0f %10.0f %12s\n' "${c}" \
    "$(awk -v x=$an 'BEGIN{print x/1048576}')" "$(awk -v x=$zw 'BEGIN{print x/1048576}')" \
    "$(awk -v x=$sw 'BEGIN{print x/1048576}')" "$(awk -v x=$cur 'BEGIN{print x/1048576}')" "${ps}"
  csum="$(awk -v a=$csum -v b=$ps 'BEGIN{print a+b}')"; cn=$((cn+1))
done
[ "${cn}" -gt 0 ] && log "mean per-container PSI full avg10 = $(awk -v s=$csum -v n=$cn 'BEGIN{printf "%.2f", s/n}')% (usability knee ~5-10%)"
log "done. (revert zswap: echo 0 | sudo tee ${Z}/enabled)"
