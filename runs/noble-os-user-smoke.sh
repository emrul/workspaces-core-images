#!/usr/bin/env bash
# Phase 5 5.x.5 (noble) — KASM_OS_USER end-to-end smoke.
# Boots noble production image with KASM_OS_USER=alice/1500/1500 and
# /home/alice; asserts id, $HOME, KasmVNC port, no uid=1000 leftovers.
# Then a no-vars run for trace-equivalence diff vs default.
set -uo pipefail

IMAGE="${IMAGE:-localhost/kasm-noble-phase5:latest}"
OUT="${OUT:-runs/noble}"
mkdir -p "$OUT"

cleanup() { podman stop -t 5 "$1" >/dev/null 2>&1; podman rm -f "$1" >/dev/null 2>&1; }

#### Run 1: KASM_OS_USER=alice ####
NAME=${PREFIX:-noble}-osuser-alice
podman rm -f "$NAME" >/dev/null 2>&1 || true
echo "=== run 1: KASM_OS_USER=alice ==="
cid=$(podman run -d --name "$NAME" \
    -e CONTAINER_INIT_TRACE=1 \
    -e KASM_VNC=1 -e KASM_PROFILE_PULL=0 -e VNC_PW=vncpassword \
    -e KASM_OS_USER=alice -e KASM_OS_UID=1500 -e KASM_OS_GID=1500 \
    -e KASM_OS_HOME=/home/alice \
    "$IMAGE")

# Wait for kasmvnc port.
for _ in $(seq 1 600); do
    if podman exec --workdir / "$NAME" bash -c 'exec 3<>/dev/tcp/127.0.0.1/6901' >/dev/null 2>&1; then break; fi
    sleep 0.05
done
sleep 5

echo "--- id (as alice) ---"
podman exec --workdir / "$NAME" bash -c 'su -s /bin/sh alice -c id' 2>&1
echo "--- entry from /etc/passwd ---"
podman exec --workdir / "$NAME" grep -E '^alice:|^kasm-user:' /etc/passwd 2>&1
echo "--- HOME contents (top 5 entries) ---"
podman exec --workdir / "$NAME" bash -c 'ls -la /home/alice 2>&1 | head -8' 2>&1
echo "--- KasmVNC reachable? ---"
podman exec --workdir / "$NAME" bash -c 'exec 3<>/dev/tcp/127.0.0.1/6901 && echo OK' 2>&1
echo "--- count + sample of find / -mount -uid 1000 (should be 0) ---"
podman exec --workdir / "$NAME" bash -c 'count=$(find / -mount -uid 1000 2>/dev/null | wc -l); echo "count=$count"; find / -mount -uid 1000 2>/dev/null | head -5' 2>&1
echo "--- count + sample of find / -mount -uid 1500 ---"
podman exec --workdir / "$NAME" bash -c 'count=$(find / -mount -uid 1500 2>/dev/null | wc -l); echo "count=$count"; find / -mount -uid 1500 2>/dev/null | head -10' 2>&1

podman exec --workdir / "$NAME" cat /tmp/container-init-trace.jsonl > "$OUT/osuser-alice.trace.jsonl" 2>/dev/null
cleanup "$NAME"

#### Run 2: no KASM_OS_* env (default kasm-user) ####
NAME=${PREFIX:-noble}-osuser-default
podman rm -f "$NAME" >/dev/null 2>&1 || true
echo "=== run 2: defaults (no KASM_OS_*) ==="
cid=$(podman run -d --name "$NAME" \
    -e CONTAINER_INIT_TRACE=1 \
    -e KASM_VNC=1 -e KASM_PROFILE_PULL=0 -e VNC_PW=vncpassword \
    "$IMAGE")
for _ in $(seq 1 600); do
    if podman exec --workdir / "$NAME" bash -c 'exec 3<>/dev/tcp/127.0.0.1/6901' >/dev/null 2>&1; then break; fi
    sleep 0.05
done
sleep 5

echo "--- id (as kasm-user) ---"
podman exec --workdir / "$NAME" bash -c 'su -s /bin/sh kasm-user -c id' 2>&1
podman exec --workdir / "$NAME" cat /tmp/container-init-trace.jsonl > "$OUT/osuser-default.trace.jsonl" 2>/dev/null
cleanup "$NAME"

#### Trace diff (modulo timestamps + pids) ####
echo
echo "=== trace diff (alice vs default, modulo timestamps/pids) ==="
python3 - <<'PY'
import json, sys, difflib
def normalize(p):
    out = []
    for ln in open(p):
        try: d = json.loads(ln)
        except: continue
        for k in ("t_start_ms","wall_utc","dt_ms","pid"):
            d.pop(k, None)
        # Drop env-expansion args that legitimately differ.
        if "argv" in d and isinstance(d["argv"], list):
            d["argv"] = [a.replace("alice","<USER>").replace("/home/alice","<HOME>") for a in d["argv"]]
        out.append(json.dumps(d, sort_keys=True))
    return out
a = normalize("${OUT}/osuser-alice.trace.jsonl")
b = normalize("${OUT}/osuser-default.trace.jsonl")
diff = list(difflib.unified_diff(b, a, lineterm="", n=0))
if not diff:
    print("PASS  trace-equivalent modulo timestamps+pids")
else:
    print(f"DIFF  {len(diff)-2} hunks (default → alice):")
    for ln in diff[:60]: print(ln)
PY
echo
echo "DONE"
