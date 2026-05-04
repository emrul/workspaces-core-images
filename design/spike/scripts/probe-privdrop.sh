#!/usr/bin/env bash
# Phase 4.3 smoke test: spawn a unit with User=alice / Group=alice /
# WorkingDirectory=/home/alice and verify `id` inside the unit
# reports uid=1500(alice) gid=1500(alice). Runs against a podman
# container layered on the spike image.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
runs_dir="$repo_root/design/spike/runs"
mkdir -p "$runs_dir"

stage="$(mktemp -d -t kasm-privdrop.XXXXXX)"
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/units"
cat > "$stage/units/whoami.service" <<'EOF'
[Unit]
Description=privilege-drop smoke test
[Service]
Type=oneshot
User=alice
Group=alice
WorkingDirectory=/home/alice
ExecStart=/bin/sh -c "id; pwd; echo HOME=$HOME"
ExitContainerOnFailure=true
EOF

cat > "$stage/Containerfile" <<'EOF'
FROM kasm-spike:latest
USER 0
RUN groupadd -g 1500 alice && useradd -m -d /home/alice -s /bin/bash -u 1500 -g 1500 alice
RUN rm -rf /etc/container-init/units/* && mkdir -p /etc/container-init/units
COPY units/whoami.service /etc/container-init/units/whoami.service
EOF

podman build -t kasm-privdrop:latest "$stage" >/dev/null

name=privdrop
podman rm -f "$name" >/dev/null 2>&1 || true
podman run --name "$name" --rm=false --log-driver=k8s-file kasm-privdrop:latest \
    > "$runs_dir/probe-privdrop.stdout" 2>&1 || true
podman logs "$name" >> "$runs_dir/probe-privdrop.stdout" 2>&1 || true
podman rm -f "$name" >/dev/null 2>&1 || true

echo "== container stdout =="
cat "$runs_dir/probe-privdrop.stdout"
echo "== checks =="
ok=1
if ! grep -qE 'uid=1500\(alice\)' "$runs_dir/probe-privdrop.stdout"; then
    echo "FAIL: id did not report uid=1500(alice)"
    ok=0
fi
if ! grep -qE 'gid=1500\(alice\)' "$runs_dir/probe-privdrop.stdout"; then
    echo "FAIL: id did not report gid=1500(alice)"
    ok=0
fi
if ! grep -q '^/home/alice$' "$runs_dir/probe-privdrop.stdout"; then
    echo "FAIL: pwd did not report /home/alice"
    ok=0
fi
if ! grep -q '^HOME=/home/alice$' "$runs_dir/probe-privdrop.stdout"; then
    echo "FAIL: HOME not seeded as /home/alice"
    ok=0
fi
if [ $ok -eq 1 ]; then
    echo "PASS"
    exit 0
fi
exit 1
