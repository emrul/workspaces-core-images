#!/usr/bin/env bash
# zswap-probe-k8s.sh — snapshot compressed-memory density on a CIVO k3s node.
#
# The k8s analogue of zswap-probe.sh (which drives Docker on .140). This one does
# NOT launch workloads — sessions are launched through Kasm (the KasmWorkspace
# operator) with memory requests/limits set per design/workspace-density-zswap-k8s.md
# §3.3. This script only MEASURES: it lands a transient privileged pod on the
# target node and, for every workspace session cgroup, emits one JSONL line with
# the per-cgroup memory / zswap / swap / PSI split, plus node-level totals.
#
# Usage:
#   KUBECONFIG=... ./zswap-probe-k8s.sh <node-name> [samples] [interval_s]
# Output: JSONL to stdout (one object per session per sample) + a node summary
# line per sample. Redirect to a file per (workload,cap,zswap) cell for §6.
#
# Read-only w.r.t. the node (reads /sys, /proc). Safe to run repeatedly.
set -euo pipefail

NODE="${1:?usage: zswap-probe-k8s.sh <node-name> [samples] [interval_s]}"
SAMPLES="${2:-6}"
INTERVAL="${3:-10}"
NS="${NS:-kube-system}"
POD="zswap-probe-${NODE##*-}"
KUBECTL="${KUBECTL:-kubectl}"

log(){ printf '[zswap-probe-k8s] %s\n' "$*" >&2; }

cleanup(){ $KUBECTL delete pod "$POD" -n "$NS" --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

log "landing probe pod $POD on $NODE"
cat <<EOF | $KUBECTL apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: $POD, namespace: $NS, labels: {app: zswap-probe}}
spec:
  nodeName: $NODE
  hostPID: true
  restartPolicy: Never
  tolerations: [{operator: Exists}]
  containers:
  - name: p
    image: busybox:1.36
    command: ["sleep","900"]
    securityContext: {privileged: true}
    volumeMounts: [{name: host, mountPath: /host}]
  volumes: [{name: host, hostPath: {path: /}}]
EOF
$KUBECTL wait --for=condition=Ready "pod/$POD" -n "$NS" --timeout=60s >/dev/null

# The remote collector. For each sample: walk kubepods.slice for session cgroups
# (workspace pods carry app.kubernetes.io/component=workspace; on the node we
# match cgroup dirs that contain a container whose memory.current is non-trivial
# and that live under a kubepods burstable slice). We emit raw cgroup numbers and
# let analyze.sh derive ratios, matching the .140 pipeline.
REMOTE='
PAGE=4096
now(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
zparam(){ cat /host/sys/module/zswap/parameters/$1 2>/dev/null; }
# node-level line
node_line(){
  ma=$(awk "/MemAvailable/{print \$2*1024}" /host/proc/meminfo)
  mt=$(awk "/MemTotal/{print \$2*1024}" /host/proc/meminfo)
  st=$(awk "/SwapTotal/{print \$2*1024}" /host/proc/meminfo)
  sf=$(awk "/SwapFree/{print \$2*1024}" /host/proc/meminfo)
  psi=$(awk "/^full/{print \$0}" /host/proc/pressure/memory 2>/dev/null | tr " " ",")
  zpool=$(cat /host/sys/kernel/debug/zswap/pool_total_size 2>/dev/null || echo 0)
  zstored=$(cat /host/sys/kernel/debug/zswap/stored_pages 2>/dev/null || echo 0)
  printf "{\"t\":\"%s\",\"kind\":\"node\",\"mem_total\":%s,\"mem_avail\":%s,\"swap_total\":%s,\"swap_free\":%s,\"zswap_enabled\":\"%s\",\"zswap_compressor\":\"%s\",\"zswap_pool_bytes\":%s,\"zswap_stored_pages\":%s,\"node_psi_full\":\"%s\"}\n" \
    "$(now)" "$mt" "$ma" "$st" "$sf" "$(zparam enabled)" "$(zparam compressor)" "$zpool" "$zstored" "$psi"
}
# per-session cgroup lines
sess_lines(){
  base=/host/sys/fs/cgroup/kubepods.slice
  [ -d "$base" ] || return 0
  # burstable session pods live under kubepods-burstable.slice/<pod>/<container>
  find "$base" -type d -name "memory.current" -prune 2>/dev/null >/dev/null
  for cur in $(find "$base" -name memory.current 2>/dev/null); do
    d=$(dirname "$cur")
    # only leaf container cgroups (have a memory.swap.current and a cgroup.procs with pids)
    [ -f "$d/memory.swap.max" ] || continue
    procs=$(wc -l < "$d/cgroup.procs" 2>/dev/null || echo 0)
    [ "$procs" -gt 0 ] || continue
    mc=$(cat "$d/memory.current" 2>/dev/null || echo 0)
    # skip tiny infra cgroups (< 64 MiB) to focus on session containers
    [ "$mc" -ge 67108864 ] || continue
    zc=$(cat "$d/memory.zswap.current" 2>/dev/null || echo 0)
    sc=$(cat "$d/memory.swap.current" 2>/dev/null || echo 0)
    sm=$(cat "$d/memory.swap.max" 2>/dev/null || echo 0)
    psi=$(awk "/^full/{print \$0}" "$d/memory.pressure" 2>/dev/null | tr " " ",")
    cpsi=$(awk "/^some/{print \$0}" "$d/cpu.pressure" 2>/dev/null | tr " " ",")
    id=$(echo "$d" | sed "s#.*/kubepods##; s#/# #g" | awk "{print \$(NF-1)\"/\"\$NF}")
    printf "{\"t\":\"%s\",\"kind\":\"session\",\"cgroup\":\"%s\",\"mem_current\":%s,\"zswap_current\":%s,\"swap_current\":%s,\"swap_max\":\"%s\",\"mem_psi_full\":\"%s\",\"cpu_psi_some\":\"%s\"}\n" \
      "$(now)" "$id" "$mc" "$zc" "$sc" "$sm" "$psi" "$cpsi"
  done
}
i=0
while [ "$i" -lt "'$SAMPLES'" ]; do
  node_line
  sess_lines
  i=$((i+1))
  [ "$i" -lt "'$SAMPLES'" ] && sleep "'$INTERVAL'"
done
'
log "collecting $SAMPLES samples @ ${INTERVAL}s"
$KUBECTL exec -n "$NS" "$POD" -- sh -c "$REMOTE"
log "done"
