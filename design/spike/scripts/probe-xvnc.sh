#!/usr/bin/env bash
# Phase 4.4 smoke test: kasm-xvnc launcher exec()s real Xvnc with the
# same argv vector vnc_startup.sh's start_kasmvnc would build via the
# perl wrapper. PASS when the websocket port (6901) is listening
# inside the container.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
runs_dir="$repo_root/design/spike/runs"
mkdir -p "$runs_dir"

stage="$(mktemp -d -t kasm-xvnc-probe.XXXXXX)"
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/units" "$stage/bin"
arch=$(uname -m); case "$arch" in aarch64|arm64) arch=arm64 ;; x86_64) arch=amd64 ;; esac
cp "$repo_root/src/common/container-init/bin/kasm-xvnc.linux-$arch" "$stage/bin/kasm-xvnc"

cat > "$stage/units/kasm-setup.service" <<'EOF'
[Unit]
Description=Kasm session setup (probe stub)
[Service]
Type=oneshot
ExecStart=/bin/sh -c "mkdir -p /home/kasm-user/.vnc && cp -f /etc/kasm/self-default.pem /home/kasm-user/.vnc/self.pem 2>/dev/null || true; chmod 600 /home/kasm-user/.vnc/self.pem 2>/dev/null || true; printf 'password\\npassword\\n\\n' | kasmvncpasswd -u kasm_user -wo; chmod 600 /home/kasm-user/.kasmpasswd; rm -rf /tmp/.X1-lock /tmp/.X11-unix/X1"
RemainAfterExit=yes
EOF

cat > "$stage/units/kasmvnc.service" <<'EOF'
[Unit]
Description=KasmVNC via kasm-xvnc launcher
After=kasm-setup.service
Requires=kasm-setup.service
[Service]
Type=simple
Environment=DISPLAY=:1
Environment=VNC_RESOLUTION=1280x800
Environment=VNC_COL_DEPTH=24
Environment=NO_VNC_PORT=6901
Environment=MAX_FRAME_RATE=24
Environment=KASM_VNC_PATH=/usr/share/kasmvnc
Environment=KASM_SVC_PRINTER=0
Environment=KASM_SVC_SMARTCARD=0
ExecStart=/usr/local/bin/kasm-xvnc
Restart=on-failure
RestartSec=200ms
[Install]
WantedBy=multi-user.target
EOF

cat > "$stage/Containerfile" <<'EOF'
FROM kasm-spike:latest
USER 0
RUN rm -rf /etc/container-init/units/* && mkdir -p /etc/container-init/units
COPY units/   /etc/container-init/units/
COPY bin/kasm-xvnc /usr/local/bin/kasm-xvnc
RUN chmod +x /usr/local/bin/kasm-xvnc \
 && mkdir -p /etc/kasm \
 && (test -f /etc/kasm/self-default.pem || openssl req -x509 -newkey rsa:2048 -keyout /etc/kasm/self-default.pem -out /etc/kasm/self-default.pem -days 30 -nodes -subj '/CN=kasm') \
 && id kasm-user >/dev/null 2>&1 || useradd -m -d /home/kasm-user -s /bin/bash kasm-user
EOF

podman build -t kasm-xvnc-probe:latest "$stage" >/dev/null

name=xvnc-probe
podman rm -f "$name" >/dev/null 2>&1 || true
cid=$(podman run -d --name "$name" --rm=false --log-driver=k8s-file kasm-xvnc-probe:latest)

# Wait for the websocket port to listen.
ok=0
for _ in $(seq 1 100); do
    if podman exec "$cid" sh -c "ss -tln | awk '{print \$4}' | grep -q :6901" 2>/dev/null; then
        ok=1
        break
    fi
    sleep 0.1
done

podman logs "$cid" > "$runs_dir/probe-xvnc.stdout" 2>&1 || true
podman exec "$cid" cat /tmp/container-init-trace.jsonl > "$runs_dir/probe-xvnc.trace.jsonl" 2>/dev/null || true

if [ "$ok" -eq 1 ]; then
    echo "PASS  Xvnc websocket port 6901 listening"
    podman rm -f "$name" >/dev/null 2>&1 || true
    exit 0
fi

echo "FAIL  websocket port 6901 not listening after 10s"
echo "---- container stdout (last 30 lines) ----"
tail -30 "$runs_dir/probe-xvnc.stdout"
podman rm -f "$name" >/dev/null 2>&1 || true
exit 1
