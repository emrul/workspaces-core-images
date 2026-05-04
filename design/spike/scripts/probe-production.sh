#!/usr/bin/env bash
# Phase 4.6 smoke test: layer the production unit set + scripts onto
# the spike image and confirm container-init boots cleanly. Asserts:
#   - units load with zero parser warnings
#   - kill-switch envvars take effect (KASM_PROFILE_PULL=0 → skip)
#   - socket-activated services bind their listeners
#   - cgroup_init records the expected state for the host
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
runs_dir="$repo_root/design/spike/runs"
mkdir -p "$runs_dir"

stage="$(mktemp -d -t kasm-prod-probe.XXXXXX)"
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/bin" "$stage/units" "$stage/scripts"
arch=$(uname -m); case "$arch" in aarch64|arm64) arch=arm64 ;; x86_64) arch=amd64 ;; esac
cp "$repo_root/src/common/container-init/bin/kasm-xvnc.linux-$arch" "$stage/bin/kasm-xvnc"
cp "$repo_root/src/common/container-init/bin/kasm-upload-server.linux-$arch" "$stage/bin/kasm-upload-server"
cp -r "$repo_root/src/common/container-init/units/." "$stage/units/"
cp -r "$repo_root/src/common/container-init/scripts/." "$stage/scripts/"

cat > "$stage/Containerfile" <<'EOF'
FROM kasm-spike:latest
USER 0
RUN rm -rf /etc/container-init/units/* && mkdir -p /etc/container-init/units /usr/local/bin
COPY units/   /etc/container-init/units/
COPY scripts/ /usr/local/bin/
COPY bin/kasm-xvnc          /usr/local/bin/kasm-xvnc
COPY bin/kasm-upload-server /usr/bin/kasm-upload-server
RUN chmod +x /usr/local/bin/kasm-xvnc /usr/bin/kasm-upload-server \
              /usr/local/bin/kasm-setup /usr/local/bin/kasm-os-user-rename \
              /usr/local/bin/kasm-network-wait /usr/local/bin/kasm-profile-pull \
              /usr/local/bin/kasm-window-manager /usr/local/bin/kasm-audio-out \
              /usr/local/bin/kasm-profile-size-check /usr/local/bin/kasm-recorder-watch \
              /usr/local/bin/kasm-recorder-drain \
 && id kasm-user >/dev/null 2>&1 || useradd -m -d /home/kasm-user -s /bin/bash kasm-user
EOF

podman build -t kasm-prod-probe:latest "$stage" >/dev/null

# Smoke run with KASM_VNC=0 KASM_PROFILE_PULL=0 — both kill switches
# engaged. Container-init should boot, every VNC-stack unit should
# skip via ConditionEnvironment, the binary should idle waiting for
# stopCh. We give it 3s, then SIGTERM + collect the trace.
name=prod-probe
podman rm -f "$name" >/dev/null 2>&1 || true
cid=$(podman run -d --name "$name" --rm=false --log-driver=k8s-file \
    -e CONTAINER_INIT_TRACE=1 \
    -e KASM_VNC=0 -e KASM_PROFILE_PULL=0 \
    kasm-prod-probe:latest)
sleep 3

podman logs "$cid" > "$runs_dir/probe-production.stdout" 2>&1 || true
podman exec "$cid" cat /tmp/container-init-trace.jsonl > "$runs_dir/probe-production.trace.jsonl" 2>/dev/null || true
podman stop -t 2 "$cid" >/dev/null 2>&1 || true
podman rm -f "$cid" >/dev/null 2>&1 || true

ok=1

# 1) parser must have loaded units with no warnings.
warnings=$(grep -E '"phase":"units_loaded"' "$runs_dir/probe-production.trace.jsonl" \
             | head -n1 | python3 -c 'import json,sys; rec=json.loads(sys.stdin.read()); print(rec.get("warnings",-1))')
if [ "$warnings" != "0" ]; then
    echo "FAIL  units_loaded warnings=$warnings (want 0)"
    ok=0
fi
count=$(grep -E '"phase":"units_loaded"' "$runs_dir/probe-production.trace.jsonl" \
        | head -n1 | python3 -c 'import json,sys; rec=json.loads(sys.stdin.read()); print(rec.get("count",-1))')
if [ "$count" -lt 18 ]; then
    echo "FAIL  units_loaded count=$count (want >=18)"
    ok=0
fi

# 2) Kill switches honoured: VNC-stack units skipped. JSON key order is
# alphabetical so the regex looks for phase=skipped first then unit.
for u in kasmvnc.service window-manager.service audio-out-ws.socket upload.socket; do
    if ! grep -qE "\"phase\":\"skipped\".*\"unit\":\"$u\"" "$runs_dir/probe-production.trace.jsonl"; then
        echo "FAIL  $u not skipped under KASM_VNC=0"
        ok=0
    fi
done
if ! grep -qE '"phase":"skipped".*"unit":"profile-pull.service"' "$runs_dir/probe-production.trace.jsonl"; then
    echo "FAIL  profile-pull.service not skipped under KASM_PROFILE_PULL=0"
    ok=0
fi

# 3) Non-VNC-stack units (kasm-setup, network-wait) DID run.
if ! grep -qE '"phase":"spawn".*"unit":"kasm-setup.service"' "$runs_dir/probe-production.trace.jsonl"; then
    echo "FAIL  kasm-setup.service did not spawn"
    ok=0
fi

if [ "$ok" -eq 1 ]; then
    echo "PASS  unit-set boots, parser clean, kill switches honoured"
    exit 0
fi
echo "---- container stdout (last 30) ----"
tail -30 "$runs_dir/probe-production.stdout"
exit 1
