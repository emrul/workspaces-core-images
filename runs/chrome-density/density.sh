#!/usr/bin/env bash
# density.sh — Chrome-at-scale A/B density benchmark (arm A baseline vs arm B trio).
#
# Reproduces the method from design/data/perf-report.html so numbers stay
# comparable to the established baseline (nix Chrome = 321 sessions/100 GB,
# 319 MiB marginal/session):
#
#   * ramp 1 -> MAX concurrent sessions on the shared host (incremental fleet)
#   * REPS repeats, median reported
#   * per-container binding resident = memory.current - inactive_file (cgroup v2),
#     which is exactly what `docker stats` reports; fleet = sum over containers
#   * anon (memory.stat 'anon') tracked separately = the private working set /
#     packing floor
#   * direct `docker run` (NOT the Kasm platform), seccomp=chrome.json +
#     apparmor=unconfined, software render, no GPU
#
# The only variable between arms is CHROME_SCALE_PROFILE, injected purely via
# APP_ARGS (which flows custom_startup -> chrome-launch -> nix-launch "$@" ->
# chrome). No image rebuild, no bind-mounted scripts.
#
# Usage:
#   ./density.sh idle            # scenario 1 (near-idle, anchors arm A to 321)
#   ./density.sh heavy           # scenario 2 (heavy multi-tab, full trio)  [see NOTE]
#
# Env overrides:
#   IMAGE   full image ref (default: the labs-sandbox chrome:nix)
#   MAX     max concurrent sessions (default 8)
#   REPS    repeats for median (default 3)
#   SETTLE  seconds to settle after each fleet increment (default 15)
#   RLIM    --renderer-process-limit value for arm B (default 3)
#   ARMS    space list of arms to run (default "baseline trio")
set -euo pipefail

SCENARIO="${1:-idle}"
IMAGE="${IMAGE:-registry.gitlab.com/kasm-technologies/labs-sandbox/kasm-nix/chrome:nix}"
MAX="${MAX:-8}"
REPS="${REPS:-3}"
RLIM="${RLIM:-3}"
ARMS="${ARMS:-baseline trio}"
# heavy scenario: N distinct-hostname tabs (distinct SITES → distinct renderers)
# served by one local static server; --renderer-process-limit consolidates them.
HEAVY_SITES="${HEAVY_SITES:-8}"
HEAVY_PORT="${HEAVY_PORT:-8800}"
if [ "${SCENARIO}" = "heavy" ]; then SETTLE="${SETTLE:-25}"; else SETTLE="${SETTLE:-15}"; fi
SERVER_PID=""
ADDHOST=()   # --add-host siteK:GW args (heavy only)

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKLOAD_DIR="${HERE}/workload"
RESULTS="${HERE}/results"; mkdir -p "${RESULTS}"
TSV="${RESULTS}/${SCENARIO}.tsv"
SECCOMP="${SECCOMP:-$(cd "${HERE}/../../src/common/seccomp" && pwd)/chrome.json}"
PREFIX="cd_${SCENARIO}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-120}"

log(){ printf '[density] %s\n' "$*" >&2; }
fail(){ printf '[density] ERROR %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || fail "docker not found"
[ -f "${SECCOMP}" ] || fail "seccomp profile not found: ${SECCOMP}"
[ -d "${WORKLOAD_DIR}" ] || fail "workload dir missing: ${WORKLOAD_DIR}"

cleanup(){
  docker ps -aq --filter "name=^${PREFIX}_" | xargs -r docker rm -f >/dev/null 2>&1 || true
}
stop_server(){ [ -n "${SERVER_PID}" ] && kill "${SERVER_PID}" >/dev/null 2>&1 || true; SERVER_PID=""; }
trap 'cleanup; stop_server' EXIT INT TERM
cleanup

# ── heavy scenario setup: one static server + distinct-hostname site aliases ──
setup_heavy(){
  local gw
  gw="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null)"
  [ -n "${gw}" ] || gw="172.17.0.1"
  # single static server serves heavy.html; distinct SITES come from the Host
  # header (siteK), not the port — so one server on one port is enough.
  ( cd "${WORKLOAD_DIR}" && exec python3 -m http.server "${HEAVY_PORT}" --bind "${gw}" ) \
    >/dev/null 2>&1 &
  SERVER_PID="$!"
  sleep 1
  kill -0 "${SERVER_PID}" 2>/dev/null || fail "static server failed to start on ${gw}:${HEAVY_PORT}"
  local k
  for k in $(seq 1 "${HEAVY_SITES}"); do ADDHOST+=( --add-host "site${k}:${gw}" ); done
  log "heavy: server pid=${SERVER_PID} on ${gw}:${HEAVY_PORT}, ${HEAVY_SITES} site aliases"
}

# ── workload → APP_ARGS / LAUNCH_URL ────────────────────────────────────────
# Returns the URL args for the scenario. Scale flags are prepended per-arm.
workload_urls(){
  case "${SCENARIO}" in
    idle)  printf 'file:///workload/idle.html' ;;
    heavy)
      local k out=""
      for k in $(seq 1 "${HEAVY_SITES}"); do
        out="${out}${out:+ }http://site${k}:${HEAVY_PORT}/heavy.html"
      done
      printf '%s' "${out}" ;;
    *)     fail "unknown scenario: ${SCENARIO}" ;;
  esac
}

scale_flags(){
  case "$1" in
    baseline)   printf '' ;;
    trio)       printf -- '--enable-low-end-device-mode --renderer-process-limit=%s' "${RLIM}" ;;
    # site-isolation OFF, nothing else — isolates the pure isolation memory cost.
    # (Expected to consolidate little on its own: Chrome still uses process-per-
    # site-instance up to its default limit, which is high on a big-RAM host.)
    noiso)      printf -- '--disable-site-isolation-trials' ;;
    # the full "corner-cut" stack: low-end + a low process limit that finally
    # bites once isolation is off + isolation off.
    trio_noiso) printf -- '--enable-low-end-device-mode --renderer-process-limit=%s --disable-site-isolation-trials' "${RLIM}" ;;
  esac
}

launch_one(){  # launch_one <arm> <index>
  local arm="$1"
  local idx="$2"
  local name="${PREFIX}_${arm}_${idx}"
  local app_args="$(scale_flags "${arm}") $(workload_urls)"
  docker run -d --name "${name}" \
    --security-opt seccomp="${SECCOMP}" \
    --security-opt apparmor=unconfined \
    --shm-size=512m \
    "${ADDHOST[@]}" \
    -e VNC_PW=password \
    -e CHROME_SCALE_PROFILE="${arm}" \
    -e APP_ARGS="${app_args}" \
    -v "${WORKLOAD_DIR}:/workload:ro" \
    "${IMAGE}" >/dev/null
  printf '%s' "${name}"
}

chrome_up(){  # chrome_up <name> — wait until the real chrome process exists
  local name="$1" t=0
  while [ "${t}" -lt "${BOOT_TIMEOUT}" ]; do
    docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null | grep -q true || return 1
    if docker exec "${name}" pgrep -f 'share/google/chrome/chrome' >/dev/null 2>&1; then return 0; fi
    sleep 2; t=$((t+2))
  done
  return 1
}

# Read one container's binding (current - inactive_file) and anon, in bytes.
measure_one(){  # measure_one <name> -> "<binding_bytes> <anon_bytes>"
  local name="$1"
  docker exec "${name}" sh -c '
    cur=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo 0)
    inact=$(awk "/^inactive_file /{print \$2}" /sys/fs/cgroup/memory.stat 2>/dev/null || echo 0)
    anon=$(awk "/^anon /{print \$2}" /sys/fs/cgroup/memory.stat 2>/dev/null || echo 0)
    echo "$((cur - inact)) ${anon}"
  ' 2>/dev/null || echo "0 0"
}

bytes_to_mib(){ awk -v b="$1" 'BEGIN{printf "%.1f", b/1048576}'; }

[ "${SCENARIO}" = "heavy" ] && setup_heavy

printf 'scenario\tarm\tsessions\trep\tfleet_binding_mib\tfleet_anon_mib\n' > "${TSV}"

for arm in ${ARMS}; do
  log "=== arm: ${arm} | scenario: ${SCENARIO} | ramp 1..${MAX} | reps=${REPS} ==="
  for rep in $(seq 1 "${REPS}"); do
    cleanup
    names=()
    for n in $(seq 1 "${MAX}"); do
      nm="$(launch_one "${arm}" "${n}")"; names+=("${nm}")
      if ! chrome_up "${nm}"; then
        log "WARN ${nm} chrome did not come up within ${BOOT_TIMEOUT}s (rep ${rep}, n=${n})"
      fi
      sleep "${SETTLE}"
      fb=0; fa=0
      for c in "${names[@]}"; do
        read -r b a < <(measure_one "${c}")
        fb=$((fb + b)); fa=$((fa + a))
      done
      printf '%s\t%s\t%d\t%d\t%s\t%s\n' \
        "${SCENARIO}" "${arm}" "${n}" "${rep}" \
        "$(bytes_to_mib "${fb}")" "$(bytes_to_mib "${fa}")" >> "${TSV}"
      log "arm=${arm} rep=${rep} sessions=${n} fleet_binding=$(bytes_to_mib "${fb}")MiB fleet_anon=$(bytes_to_mib "${fa}")MiB"
    done
    cleanup
  done
done

log "raw results: ${TSV}"
log "analyzing…"
"${HERE}/analyze.sh" "${TSV}"
