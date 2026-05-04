#!/usr/bin/env bash
# Phase 4.8 Probe E — KasmVNC reachability. Boots a target image with
# CONTAINER_INIT=1 (headed; KASM_VNC=1) and asserts that the websocket
# port (NO_VNC_PORT, default 6901) accepts a TCP connection within a
# bounded window. Does NOT speak the websocket upgrade — the listener
# being open under container-init is the load-bearing assertion.
#
# Args:
#   $1 image ref
#   $2 friendly label
set -euo pipefail

image="${1:?image ref required}"
label="${2:?run label required}"

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
runs_dir="$repo_root/design/spike/runs"
mkdir -p "$runs_dir"

trace="$runs_dir/probe-E.${label}.trace.jsonl"
stdout="$runs_dir/probe-E.${label}.stdout"
name="probe-E-$label"

podman rm -f "$name" >/dev/null 2>&1 || true
# Map host port :0 → :6901 so concurrent runs don't collide.
cid=$(podman run -d --name "$name" --rm=false --log-driver=k8s-file \
    -e CONTAINER_INIT=1 -e CONTAINER_INIT_TRACE=1 \
    -e KASM_VNC=1 -e KASM_PROFILE_PULL=0 \
    -p 6901 \
    "$image")

# Container-init's bound listener completes the TCP handshake
# immediately after `bound` for kasmvnc.socket. Poll for up to 15s.
host_port=$(podman port "$cid" 6901/tcp | awk -F: '{print $NF}' | head -n1 || true)
ok=0
for i in $(seq 1 30); do
    if [ -n "${host_port:-}" ] && (echo > /dev/tcp/127.0.0.1/"$host_port") 2>/dev/null; then
        ok=1
        break
    fi
    sleep 0.5
    host_port=$(podman port "$cid" 6901/tcp | awk -F: '{print $NF}' | head -n1 || true)
done

podman logs "$cid" > "$stdout" 2>&1 || true
podman exec "$cid" cat /tmp/container-init-trace.jsonl > "$trace" 2>/dev/null || true
podman stop -t 3 "$cid" >/dev/null 2>&1 || true
podman rm -f "$cid" >/dev/null 2>&1 || true

if [ "$ok" -ne 1 ]; then
    echo "[$label] FAIL  E/kasmvnc — :6901 never accepted TCP within 15s"
    echo "---- [$label] container stdout (last 30) ----"
    tail -30 "$stdout"
    exit 1
fi

# Cross-check: the trace shows kasmvnc.socket bound (not skipped).
if ! grep -qE '"phase":"bound".*"unit":"kasmvnc.socket"' "$trace"; then
    # Acceptable if the production unit set still binds kasmvnc.service
    # directly (no .socket). Fall back to checking spawn.
    if ! grep -qE '"phase":"spawn".*"unit":"kasmvnc.service"' "$trace"; then
        echo "[$label] FAIL  E/kasmvnc — neither bound nor spawn for kasmvnc.* in trace"
        echo "---- [$label] container stdout (last 30) ----"
        tail -30 "$stdout"
        exit 1
    fi
fi

echo "[$label] PASS  E/kasmvnc — :6901 reachable, kasmvnc unit started"
