#!/usr/bin/env bash
# Phase 6 — single-path median-of-N boot capture for ubuntu noble.
# (Phase 5 dual-path probe was retired when the bash chain was deleted;
# container-init is the only boot path post-Phase 6.)
# Captures per-run:
#   - boot trace JSONL (/tmp/container-init-trace.jsonl)
#   - cgroup memory + nproc N s after start
#   - TTFL_trace_ms: kasmvnc.service spawn dt_ms (supervisor exec time;
#       Xvnc bind ~10ms more, see noble before/after notes)
#   - TTFL_extern_ms: wall-clock host poll until `bash -c
#     'exec 3<>/dev/tcp/127.0.0.1/6901'` succeeds inside the container.
#     Conservative — adds podman-exec overhead per probe.
set -uo pipefail

IMAGE="${IMAGE:-localhost/kasm-noble-phase6:latest}"
OUT="${OUT:-runs/noble}"
N="${N:-5}"
SOAK="${SOAK:-25}"
PREFIX="${PREFIX:-noble}"
mkdir -p "$OUT"

run_one() {
    local i="$1"
    local name="${PREFIX}-ci-${i}"
    podman rm -f "$name" >/dev/null 2>&1 || true

    local t0_ms
    t0_ms=$(python3 -c 'import time; print(int(time.time()*1000))')

    local cid
    cid=$(podman run -d --name "$name" \
        -e CONTAINER_INIT_TRACE=1 \
        -e KASM_VNC=1 -e KASM_PROFILE_PULL=0 -e VNC_PW=vncpassword \
        "$IMAGE" 2>&1) || { echo "[ci-$i] run failed: $cid"; return 1; }

    # External TTFL poll. ~30s budget, 25 ms granularity.
    local ttfl_ext_ms="" t1_ms
    for _ in $(seq 1 1200); do
        if podman exec "$name" bash -c 'exec 3<>/dev/tcp/127.0.0.1/6901' >/dev/null 2>&1; then
            t1_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
            ttfl_ext_ms=$((t1_ms - t0_ms))
            break
        fi
        sleep 0.025
    done

    sleep "$SOAK"

    # Snapshot cgroup memory + nproc.
    local cgmem nproc
    cgmem=$(podman exec "$name" sh -c 'cat /sys/fs/cgroup/memory.current 2>/dev/null || cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null' 2>/dev/null | tr -d '\r\n')
    nproc=$(podman exec "$name" sh -c 'ps -e --no-headers 2>/dev/null | wc -l' 2>/dev/null | tr -d '\r\n ')

    podman exec "$name" cat /tmp/container-init-trace.jsonl > "$OUT/ci-${i}.trace.jsonl" 2>/dev/null

    podman stop -t 5 "$name" >/dev/null 2>&1
    podman rm -f "$name" >/dev/null 2>&1

    # Trace-derived TTFL.
    local ttfl_trace_ms
    ttfl_trace_ms=$(python3 -c '
import json,sys
boot=None; spawn=None
for ln in open("'"$OUT/ci-${i}.trace.jsonl"'"):
    try: d=json.loads(ln)
    except: continue
    if d.get("phase")=="boot_start": boot=d["t_start_ms"]
    if d.get("phase")=="spawn" and d.get("unit")=="kasmvnc.service": spawn=d["t_start_ms"]
print((spawn-boot) if (boot and spawn) else "")
' 2>/dev/null)
    ttfl_trace_ms=${ttfl_trace_ms:-NA}

    printf "[ci-%d] ttfl_trace=%sms ttfl_extern=%sms cgmem_MiB=%s nproc=%s\n" \
        "$i" "$ttfl_trace_ms" "${ttfl_ext_ms:-NA}" \
        "$([ -n "$cgmem" ] && echo $((cgmem/1024/1024)) || echo NA)" \
        "${nproc:-NA}"
    printf 'ci,%d,%s,%s,%s,%s\n' "$i" "$ttfl_trace_ms" "${ttfl_ext_ms:-}" "${cgmem:-}" "${nproc:-}" >> "$OUT/results.csv"
}

echo "path,i,ttfl_trace_ms,ttfl_extern_ms,cgmem_bytes,nproc" > "$OUT/results.csv"

echo "=== container-init path (the only path) ==="
for i in $(seq 1 "$N"); do run_one "$i"; done

echo
echo "=== summary ==="
column -ts, "$OUT/results.csv"
echo
echo "=== medians ==="
OUT="$OUT" python3 - <<'PY'
import csv, statistics, os
rows = list(csv.DictReader(open(os.path.join(os.environ["OUT"], "results.csv"))))
def med(rows, key, cast=int):
    vals = []
    for r in rows:
        v = r.get(key)
        if v in (None, "", "NA"): continue
        try: vals.append(cast(v))
        except: pass
    return statistics.median(vals) if vals else None
sub = [r for r in rows if r["path"]=="ci"]
cgmem = med(sub, "cgmem_bytes")
print(f"  ci  ttfl_trace_ms median={med(sub,'ttfl_trace_ms')}  "
      f"ttfl_extern_ms median={med(sub,'ttfl_extern_ms')}  "
      f"cgmem_MiB median={int(cgmem/1024/1024) if cgmem else None}  "
      f"nproc median={med(sub,'nproc')}")
PY
