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
#   5. (optional) teardown: delete the KasmWorkspace CRs for the launched ids
#
# This fork's /api/public has no destroy_kasm, so teardown is CR deletion
# (kubectl); Kasm reconciles the session records on the next agent heartbeat.
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

# ── 1. launch ────────────────────────────────────────────────────────────────
log "launching ${N} × ${IMAGE_ID} via ${KASM_API_URL}"
for i in $(seq 1 "$N"); do
  resp="$(api request_kasm "$(jq -cn --arg u "$KASM_USER_ID" --arg img "$IMAGE_ID" '{user_id:$u, image_id:$img}')")"
  kid="$(echo "$resp" | jq -r '.kasm_id // empty')"
  if [ -z "$kid" ]; then
    log "launch $i FAILED: $(echo "$resp" | jq -rc '.error_message // .' 2>/dev/null || echo "$resp")"
    continue
  fi
  LAUNCHED+=("$kid"); log "  [$i/$N] kasm_id=$kid"
done
[ "${#LAUNCHED[@]}" -gt 0 ] || { log "no sessions launched; aborting"; exit 1; }

# ── 2. correlate to pods + wait Running ───────────────────────────────────────
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
log "waiting for pods (label kasm.kasmid=<id>) to be Running..."
for kid in "${LAUNCHED[@]}"; do wait_pod "$kid" && log "  $kid -> ${POD[$kid]}"; done

# ── 3. drive browser workload ─────────────────────────────────────────────────
log "launching ${BROWSER} (${TABS// /|} tabs) in each session..."
for kid in "${LAUNCHED[@]}"; do
  p="${POD[$kid]:-}"; [ -n "$p" ] || continue
  kubectl exec -n "$NAMESPACE" "$p" -- su -l kasm-user \
    -c "DISPLAY=:1 setsid nix-launch ${BROWSER} ${TABS} >/tmp/loadtest-browser.log 2>&1 &" >/dev/null 2>&1 \
    && log "  driven: $p" || log "  WARN: exec failed on $p"
done
log "settling ${SETTLE}s for renderers to load..."
sleep "$SETTLE"

# ── 4. snapshot per-session cgroup metrics ────────────────────────────────────
log "sampling per-session metrics -> ${OUT}"
: > "$OUT"
snap_one(){ # snap_one <kasm_id> <pod>
  local kid="$1" p="$2"
  kubectl exec -n "$NAMESPACE" "$p" -- sh -c '
    mc=$(cat /sys/fs/cgroup/memory.current 2>/dev/null||echo 0)
    mmax=$(cat /sys/fs/cgroup/memory.max 2>/dev/null||echo 0)
    sc=$(cat /sys/fs/cgroup/memory.swap.current 2>/dev/null||echo 0)
    smax=$(cat /sys/fs/cgroup/memory.swap.max 2>/dev/null||echo 0)
    zc=$(cat /sys/fs/cgroup/memory.zswap.current 2>/dev/null||echo 0)
    anon=$(awk "/^anon /{print \$2}" /sys/fs/cgroup/memory.stat 2>/dev/null||echo 0)
    file=$(awk "/^file /{print \$2}" /sys/fs/cgroup/memory.stat 2>/dev/null||echo 0)
    pswpin=$(awk "/^pswpin /{print \$2}" /sys/fs/cgroup/memory.stat 2>/dev/null||echo 0)
    pswpout=$(awk "/^pswpout /{print \$2}" /sys/fs/cgroup/memory.stat 2>/dev/null||echo 0)
    zin=$(awk "/^zswpin /{print \$2}" /sys/fs/cgroup/memory.stat 2>/dev/null||echo 0)
    zout=$(awk "/^zswpout /{print \$2}" /sys/fs/cgroup/memory.stat 2>/dev/null||echo 0)
    cpu=$(awk "/^usage_usec/{print \$2}" /sys/fs/cgroup/cpu.stat 2>/dev/null||echo 0)
    printf "{\"mem_current\":%s,\"mem_max\":\"%s\",\"swap_current\":%s,\"swap_max\":%s,\"zswap_current\":%s,\"anon\":%s,\"file\":%s,\"pswpin\":%s,\"pswpout\":%s,\"zswpin\":%s,\"zswpout\":%s,\"cpu_usage_usec\":%s}" \
      "$mc" "$mmax" "$sc" "$smax" "$zc" "$anon" "$file" "$pswpin" "$pswpout" "$zin" "$zout" "$cpu"
  ' 2>/dev/null | jq -c --arg kid "$kid" --arg pod "$p" \
       --arg node "$(kubectl get pod -n "$NAMESPACE" "$p" -o jsonpath='{.spec.nodeName}' 2>/dev/null)" \
       '. + {kasm_id:$kid, pod:$pod, node:$node}' >> "$OUT" 2>/dev/null || true
}
for kid in "${LAUNCHED[@]}"; do [ -n "${POD[$kid]:-}" ] && snap_one "$kid" "${POD[$kid]}"; done

# node-level swap/zswap totals (one privileged read per node the sessions landed on)
NODES="$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.labels.kasm\.kasmid}{" "}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | awk 'NR>0 && $1!=""{print $2}' | sort -u)"

# ── 5. summary ────────────────────────────────────────────────────────────────
echo "================= load-test summary =================" >&2
jq -s -r '
  (map(.mem_current)|add // 0) as $mem |
  (map(.swap_current)|add // 0) as $swp |
  (map(.zswap_current)|add // 0) as $zsw |
  "sessions driven : \(length)",
  "browser         : '"$BROWSER"'",
  "total mem_current : \(($mem/1048576)|floor) MiB",
  "total swap used   : \(($swp/1048576)|floor) MiB",
  "total zswap pool  : \(($zsw/1048576)|floor) MiB",
  "per-session:",
  (.[] | "  \(.pod[0:42])  node=\(.node[-5:])  mem=\((.mem_current/1048576)|floor)Mi  swap=\((.swap_current/1048576)|floor)Mi  zswap=\((.zswap_current/1048576)|floor)Mi  zswpout=\(.zswpout)")
' "$OUT" >&2 || cat "$OUT" >&2
echo "raw JSONL: $OUT" >&2
echo "=====================================================" >&2

# ── 6. teardown (opt-in) ──────────────────────────────────────────────────────
if [ "$TEARDOWN" = "1" ]; then
  log "TEARDOWN=1 : deleting KasmWorkspace CRs for launched sessions"
  for kid in "${LAUNCHED[@]}"; do
    cr="$(kubectl get kasmworkspaces -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.labels.kasm\.kasmid}{"\n"}{end}' 2>/dev/null | awk -v k="$kid" '$2==k{print $1}')"
    [ -n "$cr" ] && kubectl delete kasmworkspace -n "$NAMESPACE" "$cr" --wait=false >/dev/null 2>&1 && log "  deleted CR $cr ($kid)"
  done
else
  log "sessions left running (set TEARDOWN=1 to auto-delete). To clean up:"
  log "  kubectl get kasmworkspaces -n $NAMESPACE   # then kubectl delete kasmworkspace <name>"
fi
