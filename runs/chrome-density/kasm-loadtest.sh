#!/usr/bin/env bash
# kasm-loadtest.sh — density/perception load harness driven through the Kasm
# Developer API (k8s deployment). The k8s analogue of density.sh (which uses
# raw `docker run` on .140). See design/workspace-density-zswap-k8s.md.
#
# Flow:
#   1. launch N sessions via POST /api/public/request_kasm  -> kasm_id each
#   2. correlate each kasm_id to its pod (label kasm.kasmid=<id>), wait Running
#   3. drive a browser workload inside each pod (nix-launch firefox|chromium
#      with TABS URLs), the k8s equivalent of the chrome-density workload
#   4. settle, then snapshot per-session cgroup metrics (memory / swap / zswap /
#      cpu, memory.stat reclaim counters) -> JSONL  (PSI is unavailable on CIVO,
#      so we use wall-clock + memory.stat, per the design doc §5 correction)
#   5. (optional) teardown: destroy each session via /api/public/destroy_kasm
#      (the Kasm-consistent path; never CR deletion, which orphans the record).
#
# Required env:
#   KASM_API_URL     e.g. https://tracelabs.kasm.com
#   KASM_API_KEY     Developer API key
#   KASM_API_SECRET  Developer API key secret
#   KUBECONFIG       pointing at the CIVO cluster
# Optional env (defaults in []):
#   KASM_USER_ID  [a3431b1e-1ca1-4873-8ebb-cb1749e619a5  = user@kasm.local]
#   IMAGE_ID      [8f54e7fb-3b95-4936-9334-62edb4d6ba85  = Trace Labs OSINT]
#   N             [6]    sessions to launch
#   BROWSER       [firefox]  firefox | chromium | brave
#   TABS          [8 distinct sites]  space-separated URLs (tabs)
#   SETTLE        [45]   seconds to settle after launching browsers
#   NAMESPACE     [kasm-system]
#   TEARDOWN      [0]    set 1 to delete the launched sessions at the end
#   RESULTS_DIR   [./results]
set -euo pipefail

: "${KASM_API_URL:?set KASM_API_URL (e.g. https://tracelabs.kasm.com)}"
: "${KASM_API_KEY:?set KASM_API_KEY}"
: "${KASM_API_SECRET:?set KASM_API_SECRET}"
KASM_USER_ID="${KASM_USER_ID:-a3431b1e-1ca1-4873-8ebb-cb1749e619a5}"
IMAGE_ID="${IMAGE_ID:-8f54e7fb-3b95-4936-9334-62edb4d6ba85}"
N="${N:-6}"
BROWSER="${BROWSER:-firefox}"
SETTLE="${SETTLE:-45}"
NAMESPACE="${NAMESPACE:-kasm-system}"
TEARDOWN="${TEARDOWN:-0}"
# Ramp: seconds between session arrivals (staggered, real-world), instead of a
# simultaneous slam. 0 = all-at-once. Each session is driven the moment its pod
# is Running, so load builds gradually and older sessions settle toward idle.
LAUNCH_INTERVAL="${LAUNCH_INTERVAL:-20}"
# Peak sampling: after the ramp completes, sample the whole fleet this many
# times, INTERVAL apart, to capture sustained peak behaviour.
PEAK_SAMPLES="${PEAK_SAMPLES:-5}"
PEAK_INTERVAL="${PEAK_INTERVAL:-20}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="${RESULTS_DIR:-${HERE}/results}"
mkdir -p "${RESULTS_DIR}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo run)"
OUT="${RESULTS_DIR}/loadtest-${BROWSER}-N${N}-${STAMP}.jsonl"

# 8 distinct hostnames = 8 renderers, mirrors chrome-density scenario 2.
DEFAULT_TABS="https://en.wikipedia.org/wiki/Kubernetes https://www.bbc.com https://news.ycombinator.com https://www.reddit.com https://github.com/explore https://www.nytimes.com https://stackoverflow.com https://www.wikipedia.org"
TABS="${TABS:-$DEFAULT_TABS}"

log(){ printf '[loadtest] %s\n' "$*" >&2; }
for bin in curl jq kubectl; do command -v "$bin" >/dev/null || { log "FATAL: need '$bin' on PATH"; exit 1; }; done

api(){ # api <endpoint> <json-extra>  -> merges auth + posts, echoes response body
  local ep="$1" extra="$2"
  local body; body="$(jq -cn --arg k "$KASM_API_KEY" --arg s "$KASM_API_SECRET" \
      --argjson x "$extra" '{api_key:$k, api_key_secret:$s} + $x')"
  curl -sk -X POST -H 'Content-Type: application/json' -d "$body" "${KASM_API_URL%/}/api/public/${ep}"
}

LAUNCHED=()   # kasm_ids
cleanup_note(){ [ "${#LAUNCHED[@]}" -gt 0 ] && log "launched kasm_ids: ${LAUNCHED[*]}"; }
trap cleanup_note EXIT

# ── helpers ───────────────────────────────────────────────────────────────────
declare -A POD
wait_pod(){ # wait_pod <kasm_id> -> sets POD[kid]
  local kid="$1" p="" t
  for t in $(seq 1 40); do
    p="$(kubectl get pods -n "$NAMESPACE" -l "kasm.kasmid=$kid" \
         -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' 2>/dev/null \
         | awk '$2=="Running"{print $1; exit}')"
    [ -n "$p" ] && { POD[$kid]="$p"; return 0; }
    sleep 6
  done
  log "  WARN: no Running pod for $kid after 240s"; return 1
}
drive(){ # drive <pod> — launch the browser workload (backgrounded inside the pod)
  kubectl exec -n "$NAMESPACE" "$1" -- su -l kasm-user \
    -c "DISPLAY=:1 setsid nix-launch ${BROWSER} ${TABS} >/tmp/loadtest-browser.log 2>&1 &" >/dev/null 2>&1
}
METRIC_SCRIPT='
  mc=$(cat /sys/fs/cgroup/memory.current 2>/dev/null||echo 0)
  sc=$(cat /sys/fs/cgroup/memory.swap.current 2>/dev/null||echo 0)
  smax=$(cat /sys/fs/cgroup/memory.swap.max 2>/dev/null||echo 0)
  zc=$(cat /sys/fs/cgroup/memory.zswap.current 2>/dev/null||echo 0)
  anon=$(awk "/^anon /{print \$2; f=1} END{if(!f)print 0}" /sys/fs/cgroup/memory.stat 2>/dev/null)
  file=$(awk "/^file /{print \$2; f=1} END{if(!f)print 0}" /sys/fs/cgroup/memory.stat 2>/dev/null)
  zout=$(awk "/^zswpout /{print \$2; f=1} END{if(!f)print 0}" /sys/fs/cgroup/memory.stat 2>/dev/null)
  cpu=$(awk "/^usage_usec/{print \$2; f=1} END{if(!f)print 0}" /sys/fs/cgroup/cpu.stat 2>/dev/null)
  printf "{\"mem_current\":%s,\"swap_current\":%s,\"swap_max\":%s,\"zswap_current\":%s,\"anon\":%s,\"file\":%s,\"zswpout\":%s,\"cpu_usage_usec\":%s}" \
    "${mc:-0}" "${sc:-0}" "${smax:-0}" "${zc:-0}" "${anon:-0}" "${file:-0}" "${zout:-0}" "${cpu:-0}"
'
T0=$(date +%s)
snap_one(){ # snap_one <kasm_id> <pod> <fleet_size> — one time-series row
  local kid="$1" p="$2" fleet="$3" node raw t; t=$(( $(date +%s) - T0 ))
  node="$(kubectl get pod -n "$NAMESPACE" "$p" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  raw="$(kubectl exec -n "$NAMESPACE" "$p" -- sh -c "$METRIC_SCRIPT" 2>/dev/null || true)"
  [ -n "$raw" ] || return 0
  echo "$raw" | jq -c --arg kid "$kid" --arg pod "$p" --arg node "$node" --argjson t "$t" --argjson fleet "$fleet" \
       '. + {kasm_id:$kid, pod:$pod, node:$node, t_s:$t, fleet:$fleet}' >> "$OUT" 2>/dev/null || true
}
sample_fleet(){ # snapshot every launched+Running session, tagged with current fleet size
  local n="${#LAUNCHED[@]}" kid
  for kid in "${LAUNCHED[@]}"; do [ -n "${POD[$kid]:-}" ] && snap_one "$kid" "${POD[$kid]}" "$n"; done
}

# ── 1. RAMP: staggered arrival, drive-on-arrival, sample after each ───────────
: > "$OUT"
log "ramping to ${N} sessions — one every ${LAUNCH_INTERVAL}s (staggered, real-world arrival)"
for i in $(seq 1 "$N"); do
  resp="$(api request_kasm "$(jq -cn --arg u "$KASM_USER_ID" --arg img "$IMAGE_ID" '{user_id:$u, image_id:$img}')")"
  kid="$(echo "$resp" | jq -r '.kasm_id // empty')"
  if [ -z "$kid" ]; then
    log "  [$i/$N] launch FAILED: $(echo "$resp" | jq -rc '.error_message // .' 2>/dev/null || echo "$resp")"
    [ "$i" -lt "$N" ] && sleep "$LAUNCH_INTERVAL"; continue
  fi
  LAUNCHED+=("$kid"); log "  [$i/$N] launched $kid — waiting for pod..."
  if wait_pod "$kid"; then drive "${POD[$kid]}" && log "    up + ${BROWSER} driven on ${POD[$kid]} (node ${POD[$kid]##*-38df-})"; fi
  sample_fleet   # time-series row for a fleet of size ${#LAUNCHED[@]}
  [ "$i" -lt "$N" ] && sleep "$LAUNCH_INTERVAL"
done
[ "${#LAUNCHED[@]}" -gt 0 ] || { log "no sessions launched; aborting"; exit 1; }

# ── 2. sustained PEAK sampling ────────────────────────────────────────────────
log "ramp complete: ${#LAUNCHED[@]} sessions. ${PEAK_SAMPLES} peak samples @ ${PEAK_INTERVAL}s..."
for s in $(seq 1 "$PEAK_SAMPLES"); do sleep "$PEAK_INTERVAL"; sample_fleet; log "  peak sample ${s}/${PEAK_SAMPLES}"; done

# ── 3. summary — the final (peak) sample ──────────────────────────────────────
echo "================= load-test summary (peak) =================" >&2
jq -s -r '
  (max_by(.t_s).t_s) as $tmax | map(select(.t_s==$tmax)) as $peak |
  ($peak|map(.mem_current)|add // 0) as $mem |
  ($peak|map(.swap_current)|add // 0) as $swp |
  ($peak|map(.zswap_current)|add // 0) as $zsw |
  "browser         : '"$BROWSER"'",
  "peak fleet      : \($peak|length) sessions (t=\($tmax)s)",
  "total mem_current : \(($mem/1048576)|floor) MiB",
  "total swap used   : \(($swp/1048576)|floor) MiB  (compressed spill)",
  "total zswap pool  : \(($zsw/1048576)|floor) MiB",
  "per-node fleet    : \([$peak[].node|.[length-5:]]|group_by(.)|map("\(.[0])×\(length)")|join(", "))",
  "per-session (peak):",
  ($peak[] | "  node=\(.node[-5:])  mem=\((.mem_current/1048576)|floor)Mi  anon=\((.anon/1048576)|floor)Mi  swap=\((.swap_current/1048576)|floor)Mi  zswap=\((.zswap_current/1048576)|floor)Mi  zswpout=\(.zswpout)")
' "$OUT" >&2 || cat "$OUT" >&2
echo "raw time-series JSONL: $OUT" >&2
echo "============================================================" >&2

# ── 6. teardown (opt-in) — via the Kasm destroy_kasm API, not CR deletion ─────
if [ "$TEARDOWN" = "1" ]; then
  log "TEARDOWN=1 : destroying sessions via /api/public/destroy_kasm"
  for kid in "${LAUNCHED[@]}"; do
    resp="$(api destroy_kasm "$(jq -cn --arg u "$KASM_USER_ID" --arg kid "$kid" '{user_id:$u, kasm_id:$kid}')")"
    err="$(echo "$resp" | jq -rc '.error_message // empty' 2>/dev/null || true)"
    if [ -n "$err" ]; then log "  WARN destroy $kid: $err"; else log "  destroyed $kid"; fi
  done
else
  log "sessions left running (set TEARDOWN=1 to destroy via API). To clean up manually:"
  log "  curl -sk -X POST $KASM_API_URL/api/public/destroy_kasm -d '{api_key,api_key_secret,user_id,kasm_id}'"
fi
