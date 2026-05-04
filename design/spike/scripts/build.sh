#!/usr/bin/env bash
# Build container-init + spike-helper for linux/arm64 (lima host
# default) and the probe container image. Run from anywhere.
#
# The repo's root .dockerignore filters everything except src/, so we
# stage a small build context under /tmp instead of pulling design/
# in directly. Containerfile paths are written relative to the staged
# context.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$repo_root"

echo "==> building container-init + spike-helper"
make -C src/common/container-init clean build helper

stage="$(mktemp -d -t kasm-spike-ctx.XXXXXX)"
trap 'rm -rf "$stage"' EXIT

echo "==> staging build context at $stage"
mkdir -p "$stage/bin" "$stage/units" "$stage/scripts"
cp src/common/container-init/bin/container-init.linux-arm64 "$stage/bin/container-init"
cp src/common/container-init/bin/spike-helper.linux-arm64    "$stage/bin/spike-helper"
cp design/spike/units/*       "$stage/units/"
cp design/spike/scripts/wm-stub.sh design/spike/scripts/recorder-drain.sh "$stage/scripts/"

cat > "$stage/Containerfile" <<'EOF'
FROM docker.io/kasmweb/core-ubuntu-noble:1.18.0-rolling-daily

USER 0

COPY bin/container-init /usr/local/bin/container-init
COPY bin/spike-helper   /usr/local/bin/spike-helper

RUN mkdir -p /etc/container-init/units
COPY units/   /etc/container-init/units/
COPY scripts/ /usr/local/bin/

RUN chmod +x /usr/local/bin/container-init \
             /usr/local/bin/spike-helper \
             /usr/local/bin/wm-stub.sh \
             /usr/local/bin/recorder-drain.sh \
 && apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends netcat-openbsd iproute2 procps \
 && rm -rf /var/lib/apt/lists/*

USER 0

ENV CONTAINER_INIT_TRACE=1 \
    CONTAINER_INIT_TRACE_FILE=/tmp/container-init-trace.jsonl

ENTRYPOINT ["/usr/local/bin/container-init", "--units", "/etc/container-init/units"]
EOF

echo "==> building probe image kasm-spike:latest"
podman build -t kasm-spike:latest "$stage"

echo "==> done"
