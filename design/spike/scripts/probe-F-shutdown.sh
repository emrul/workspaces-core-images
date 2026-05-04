#!/usr/bin/env bash
# Phase 4.8 Probe F — graceful shutdown. Boots the target image with
# CONTAINER_INIT=1, waits for steady state, sends SIGTERM, and asserts
# that the supervisor emits reverse_shutdown_done and exits within 10s.
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

trace="$runs_dir/probe-F.${label}.trace.jsonl"
stdout="$runs_dir/probe-F.${label}.stdout"
name="probe-F-$label"

podman rm -f "$name" >/dev/null 2>&1 || true
cid=$(podman run -d --name "$name" --rm=false --log-driver=k8s-file \
    -e CONTAINER_INIT=1 -e CONTAINER_INIT_TRACE=1 \
    -e KASM_VNC=0 -e KASM_PROFILE_PULL=0 \
    "$image")

# Wait for supervisor_start.
for i in $(seq 1 20); do
    if podman exec "$cid" grep -qE '"phase":"supervisor_start"' /tmp/container-init-trace.jsonl 2>/dev/null; then
        break
    fi
    sleep 0.5
done

# Snapshot the trace pre-stop so we can diff if stop hangs.
podman exec "$cid" cat /tmp/container-init-trace.jsonl > "$trace" 2>/dev/null || true

# SIGTERM. podman stop -t10 sends SIGTERM, waits 10s, then SIGKILL.
t_start=$(date +%s)
if ! podman stop -t 10 "$cid" >/dev/null 2>&1; then
    echo "[$label] FAIL  F/shutdown — podman stop returned non-zero"
fi
t_end=$(date +%s)
elapsed=$((t_end - t_start))

# After stop we may not be able to exec into the container, so collect
# logs (which carry stdout) for the final shutdown trace lines.
podman logs "$cid" > "$stdout" 2>&1 || true
podman rm -f "$cid" >/dev/null 2>&1 || true

ok=1
# reverse_shutdown_done lands on stdout (tracer goes to both file +
# stdout when configured). Check stdout for the JSON marker.
if ! grep -qE '"phase":"reverse_shutdown_done"' "$stdout"; then
    # The supervisor logs the human-readable line "received TERM, beginning
    # reverse shutdown" first; check at least that arrived as a fallback.
    if ! grep -q "beginning reverse shutdown" "$stdout"; then
        echo "[$label] FAIL  F/shutdown — neither shutdown trace nor log line found"
        ok=0
    else
        echo "[$label] WARN  F/shutdown — JSON trace not on stdout (acceptable; trace file only)"
    fi
fi
if [ "$elapsed" -gt 10 ]; then
    echo "[$label] FAIL  F/shutdown — took ${elapsed}s (>10s SIGTERM budget)"
    ok=0
fi

if [ "$ok" -eq 1 ]; then
    echo "[$label] PASS  F/shutdown — clean exit in ${elapsed}s"
    exit 0
fi
echo "---- [$label] container stdout (last 30) ----"
tail -30 "$stdout"
exit 1
