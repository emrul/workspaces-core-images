#!/usr/bin/env bash
# Phase 4.8 Probe D — boot smoke. Boots a target image with
# CONTAINER_INIT=1 and asserts that container-init reaches
# supervisor_start with no parser warnings and >=18 units loaded.
#
# Args:
#   $1 image ref (e.g., kasmweb/core-ubuntu-noble:develop)
#   $2 friendly label for the run (e.g., ubuntu-noble)
set -euo pipefail

image="${1:?image ref required}"
label="${2:?run label required}"

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
runs_dir="$repo_root/design/spike/runs"
mkdir -p "$runs_dir"

trace="$runs_dir/probe-D.${label}.trace.jsonl"
stdout="$runs_dir/probe-D.${label}.stdout"
name="probe-D-$label"

podman rm -f "$name" >/dev/null 2>&1 || true
cid=$(podman run -d --name "$name" --rm=false --log-driver=k8s-file \
    -e CONTAINER_INIT=1 -e CONTAINER_INIT_TRACE=1 \
    -e KASM_VNC=0 -e KASM_PROFILE_PULL=0 \
    "$image")
sleep 4

podman logs "$cid" > "$stdout" 2>&1 || true
podman exec "$cid" cat /tmp/container-init-trace.jsonl > "$trace" 2>/dev/null || true
podman stop -t 3 "$cid" >/dev/null 2>&1 || true
podman rm -f "$cid" >/dev/null 2>&1 || true

ok=1

if ! grep -qE '"phase":"supervisor_start"' "$trace"; then
    echo "[$label] FAIL  supervisor_start trace event missing"
    ok=0
fi

warnings=$(grep -E '"phase":"units_loaded"' "$trace" \
             | head -n1 | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("warnings",-1))' 2>/dev/null || echo -1)
if [ "$warnings" != "0" ]; then
    echo "[$label] FAIL  units_loaded warnings=$warnings (want 0)"
    ok=0
fi

count=$(grep -E '"phase":"units_loaded"' "$trace" \
             | head -n1 | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("count",-1))' 2>/dev/null || echo -1)
if [ "$count" -lt 18 ]; then
    echo "[$label] FAIL  units_loaded count=$count (want >=18)"
    ok=0
fi

if [ "$ok" -eq 1 ]; then
    echo "[$label] PASS  D/boot — supervisor_start, $count units, $warnings warnings"
    exit 0
fi
echo "---- [$label] container stdout (last 30) ----"
tail -30 "$stdout"
exit 1
