#!/usr/bin/env bash
# Probe driver for Phase 2 spike. Runs probes D, E, F-native, F-proxy
# against fresh containers spawned from kasm-spike:latest. Each probe
# captures container stdout and the trace JSONL into design/spike/runs/
# for the spike-result write-up.
#
# Prereq: ./build.sh has produced the image.
#
# Usage: probe.sh [D|E|Fn|Fp|all]   (default: all)
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
runs_dir="$repo_root/design/spike/runs"
mkdir -p "$runs_dir"

want="${1:-all}"

# Lima's podman defaults logDriver=journald, which podman logs cannot
# read from the host. Force per-container k8s-file so probe.sh can
# read stdout/stderr via `podman logs`.
common_run_args=(--log-driver=k8s-file)

# Wait for the container's listener on $1 to start accepting.
wait_listen() {
    local cid=$1 port=$2 limit=${3:-50}
    for _ in $(seq 1 "$limit"); do
        if podman exec "$cid" sh -c "ss -tln | awk '{print \$4}' | grep -q :$port" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

# Wait until the container has logged a particular substring.
wait_log() {
    local cid=$1 needle=$2 limit=${3:-100}
    for _ in $(seq 1 "$limit"); do
        if podman logs "$cid" 2>&1 | grep -qF -- "$needle"; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

dump_artifacts() {
    local name=$1 cid=$2
    podman logs "$cid" > "$runs_dir/$name.stdout" 2>&1 || true
    # Prefer exec while the container is alive — podman cp hits a
    # symlink-loop error on macOS hosts when resolving /tmp paths.
    if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$(podman inspect -f '{{.Name}}' "$cid" 2>/dev/null | tr -d /)"; then
        podman exec "$cid" cat /tmp/container-init-trace.jsonl > "$runs_dir/$name.trace.jsonl" 2>/dev/null || true
    else
        # Container already exited — podman cp via stdout to bypass
        # the symlink path issue.
        podman cp "$cid:/tmp/container-init-trace.jsonl" - 2>/dev/null \
            | tar -xO 2>/dev/null > "$runs_dir/$name.trace.jsonl" || true
    fi
}

run_probe_D() {
    echo "==> Probe D: WM dies + recorder running -> drain + container exit"
    local name=probe-D cid
    podman rm -f "$name" >/dev/null 2>&1 || true
    cid=$(podman run -d --name "$name" --rm=false "${common_run_args[@]}" \
        -e KASM_SVC_RECORDER=1 \
        kasm-spike:latest)
    wait_log "$cid" "wm-stub: running indefinitely" 50 \
        || { echo "FAIL: wm did not reach steady state"; dump_artifacts $name $cid; return 1; }
    # Crash the WM via SIGUSR1 — wm-stub.sh's USR1 trap exits 1, so
    # the supervisor sees a failed exit, fires OnFailure=recorder-drain,
    # and recorder-drain's ExitContainerOnFailure=true triggers reverse
    # shutdown. timeout-bounded so probe.sh itself can never hang on
    # podman exec when the container tears down mid-exec.
    podman exec "$cid" pkill -USR1 -x wm-stub.sh >/dev/null 2>&1 || true
    sleep 0.5
    podman wait --condition stopped "$cid" >/dev/null
    local exit_code
    exit_code=$(podman inspect -f '{{.State.ExitCode}}' "$cid")
    dump_artifacts $name $cid
    podman rm -f "$cid" >/dev/null
    if [ "$exit_code" -eq 0 ] && grep -q "recorder-drain: drain complete" "$runs_dir/$name.stdout"; then
        echo "    PASS  exit=$exit_code drain observed"
    else
        echo "    FAIL  exit=$exit_code; check $runs_dir/$name.stdout"
        return 1
    fi
}

run_probe_E() {
    echo "==> Probe E: WM dies + no recorder -> Restart=on-failure restart loop"
    local name=probe-E cid
    podman rm -f "$name" >/dev/null 2>&1 || true
    # KASM_SVC_RECORDER unset -> recorder-watch.service is skipped.
    cid=$(podman run -d --name "$name" --rm=false "${common_run_args[@]}" \
        kasm-spike:latest)
    if ! wait_log "$cid" "wm-stub: running indefinitely" 50; then
        echo "FAIL: wm did not reach steady state"
        dump_artifacts $name $cid
        return 1
    fi
    # Crash the WM via SIGUSR1 (clean exit 1 trap). recorder-drain
    # has ConditionEnvironment=KASM_SVC_RECORDER=1, which is unset
    # for probe E, so the OnFailure target is skipped (no-op) and
    # the WM's Restart=on-failure fires.
    podman exec "$cid" pkill -USR1 -x wm-stub.sh >/dev/null 2>&1 || true
    sleep 1.0
    local n_running
    n_running=$(podman logs "$cid" 2>&1 | grep -c "wm-stub: running indefinitely" || true)
    # Check container is still up.
    local state
    state=$(podman inspect -f '{{.State.Status}}' "$cid")
    dump_artifacts $name $cid
    podman rm -f "$cid" >/dev/null 2>&1 || true
    if [ "$n_running" -ge 2 ] && [ "$state" = "running" ]; then
        echo "    PASS  restart observed ($n_running 'running indefinitely' lines), container still up"
    else
        echo "    FAIL  n_running=$n_running state=$state"
        return 1
    fi
}

run_probe_F_native() {
    echo "==> Probe F-native: cold-start on first connect + restart + cond-skip stays unbound"
    local name=probe-Fn cid
    podman rm -f "$name" >/dev/null 2>&1 || true
    cid=$(podman run -d --name "$name" --rm=false "${common_run_args[@]}" \
        -e SPIKE_HELPER_DIE_AFTER=1 \
        kasm-spike:latest)
    # Boot finishes when sockets are bound.
    wait_listen "$cid" 4902 50 \
        || { echo "FAIL: upload.socket never bound :4902"; dump_artifacts $name $cid; return 1; }
    # cond-skip should NOT have bound :4999.
    if podman exec "$cid" sh -c "ss -tln | awk '{print \$4}' | grep -q :4999"; then
        echo "FAIL: cond-skip.socket bound :4999 even though ConditionEnvironment was unset"
        dump_artifacts $name $cid; return 1
    fi
    # First connect — helper should be cold-started.
    local resp1
    resp1=$(podman exec "$cid" sh -c 'echo hello | timeout 2 nc -q1 127.0.0.1 4902' || true)
    # Helper dies after 1 conn; wait for restart.
    sleep 0.5
    # Second connect — new helper PID expected.
    local resp2
    resp2=$(podman exec "$cid" sh -c 'echo world | timeout 2 nc -q1 127.0.0.1 4902' || true)
    dump_artifacts $name $cid
    podman rm -f "$cid" >/dev/null 2>&1 || true
    if echo "$resp1" | grep -q "spike-helper pid=" && echo "$resp2" | grep -q "spike-helper pid="; then
        local pid1 pid2
        pid1=$(echo "$resp1" | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1)
        pid2=$(echo "$resp2" | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1)
        if [ -n "$pid1" ] && [ -n "$pid2" ] && [ "$pid1" != "$pid2" ]; then
            echo "    PASS  first pid=$pid1, restart pid=$pid2 (different => Restart=on-failure fired)"
        else
            echo "    FAIL  pids did not differ: pid1=$pid1 pid2=$pid2"
            return 1
        fi
    else
        echo "    FAIL  responses missing helper banner: r1=$resp1 r2=$resp2"
        return 1
    fi
}

run_probe_F_proxy() {
    echo "==> Probe F-proxy: cold-start on first connect + restart"
    local name=probe-Fp cid
    podman rm -f "$name" >/dev/null 2>&1 || true
    cid=$(podman run -d --name "$name" --rm=false "${common_run_args[@]}" \
        -e SPIKE_HELPER_DIE_AFTER=1 \
        kasm-spike:latest)
    wait_listen "$cid" 8081 50 \
        || { echo "FAIL: audio-out-ws.socket never bound :8081"; dump_artifacts $name $cid; return 1; }
    # Helper should NOT yet be running (lazy).
    if podman exec "$cid" sh -c 'ss -tln | awk "{print \$4}" | grep -q :14081'; then
        echo "FAIL: proxy helper bound 14081 before first public connect (not lazy)"
        dump_artifacts $name $cid; return 1
    fi
    local resp1 resp2
    resp1=$(podman exec "$cid" sh -c 'echo hello | timeout 3 nc -q1 127.0.0.1 8081' || true)
    sleep 0.5
    resp2=$(podman exec "$cid" sh -c 'echo world | timeout 3 nc -q1 127.0.0.1 8081' || true)
    dump_artifacts $name $cid
    podman rm -f "$cid" >/dev/null 2>&1 || true
    if echo "$resp1" | grep -q "spike-helper pid=" && echo "$resp2" | grep -q "spike-helper pid="; then
        local pid1 pid2
        pid1=$(echo "$resp1" | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1)
        pid2=$(echo "$resp2" | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1)
        if [ -n "$pid1" ] && [ -n "$pid2" ] && [ "$pid1" != "$pid2" ]; then
            echo "    PASS  first pid=$pid1, restart pid=$pid2 (different => Restart=on-failure fired)"
        else
            echo "    FAIL  pids did not differ: pid1=$pid1 pid2=$pid2"
            return 1
        fi
    else
        echo "    FAIL  responses missing helper banner: r1=$resp1 r2=$resp2"
        return 1
    fi
}

case "$want" in
    D)  run_probe_D ;;
    E)  run_probe_E ;;
    Fn) run_probe_F_native ;;
    Fp) run_probe_F_proxy ;;
    all)
        run_probe_D
        run_probe_E
        run_probe_F_native
        run_probe_F_proxy
        echo "==> all probes passed"
        ;;
    *)
        echo "usage: $0 [D|E|Fn|Fp|all]" >&2; exit 2 ;;
esac
