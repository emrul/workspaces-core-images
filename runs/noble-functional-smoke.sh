#!/usr/bin/env bash
# Phase 6 (noble) — functional smoke beyond probe-D/E/F.
# (Bash-path arm was deleted with the bash chain in Phase 6.)
# Verifies on the production image:
#   - container-init: KasmVNC reachable, websocket upgrade replies
#   - container-init + KASM_VNC=0: VNC-stack units skipped, no Xvnc
#   - container-init: kasm-upload-server bound and replies on 4902
set -uo pipefail

IMAGE="${IMAGE:-localhost/kasm-noble-phase5:latest}"
OUT="${OUT:-runs/noble}"
mkdir -p "$OUT"

run_smoke() {
    local label="$1" name="noble-smoke-$1"
    shift
    podman rm -f "$name" >/dev/null 2>&1 || true
    podman run -d --name "$name" "$@" "$IMAGE" >/dev/null
    # Wait up to 30s for whatever this run is going to expose.
    sleep 18
    echo "=== $label ==="
    echo "--- ps inside container ---"
    podman exec "$name" sh -c 'ps -e --no-headers 2>/dev/null | awk "{print \$NF}" | sort -u | head -25' 2>&1
    echo "--- listeners ---"
    podman exec "$name" sh -c 'ss -ltnp 2>/dev/null | head -15' 2>&1
    echo "--- KasmVNC port :6901 (TCP-reach + 1s read) ---"
    podman exec "$name" timeout 3 bash -c '
        if exec 3<>/dev/tcp/127.0.0.1/6901; then
            echo "TCP_REACHABLE"
            printf "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n" >&3
            timeout 1 head -c 300 <&3 || true
        else
            echo "PORT NOT BOUND"
        fi
    ' 2>&1 | head -10
    echo "--- upload-server :4902 (TCP-reach + 1s read) ---"
    podman exec "$name" timeout 3 bash -c '
        if exec 3<>/dev/tcp/127.0.0.1/4902; then
            echo "TCP_REACHABLE"
            printf "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n" >&3
            timeout 1 head -c 200 <&3 || true
        else
            echo "PORT NOT BOUND"
        fi
    ' 2>&1 | head -10
    echo "--- VNC-stack units skipped (only meaningful for ci-headless) ---"
    podman exec "$name" sh -c 'grep "skipped" /tmp/container-init-trace.jsonl 2>/dev/null | grep -oE "\"unit\":\"[^\"]+\"" | sort -u | head -20' 2>&1
    echo

    podman stop -t 5 "$name" >/dev/null 2>&1
    podman rm -f "$name" >/dev/null 2>&1
}

run_smoke "ci-vnc"          -e CONTAINER_INIT_TRACE=1 -e KASM_VNC=1 -e KASM_PROFILE_PULL=0 -e VNC_PW=vncpassword
run_smoke "ci-headless"     -e CONTAINER_INIT_TRACE=1 -e KASM_VNC=0 -e KASM_PROFILE_PULL=0
echo "DONE"
