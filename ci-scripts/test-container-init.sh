#!/usr/bin/env bash
# CI boot smoke for container-init. Mirrors design/spike/scripts/probe-D-boot.sh
# but uses docker (not podman) so it can run inside the docker:29.4.0-dind
# GitLab runner. Post-Phase 6 container-init is the only boot path; we just
# enable the trace so we can confirm supervisor_start.
#
# Args (positional, matching ci-scripts/test-unit.sh):
#   $1 NAME1 (image first segment, e.g. "core-ubuntu")
#   $2 NAME2 (image second segment, e.g. "noble")
#   $3 ARCH  (e.g. "x86_64", "aarch64")
set -euo pipefail

NAME1="${1:?NAME1 required}"
NAME2="${2:?NAME2 required}"
ARCH="${3:?ARCH required}"

image_uri="${ORG_NAME}/image-cache-private:${ARCH}-core-${NAME1}-${NAME2}-${SANITIZED_BRANCH}-${CI_PIPELINE_ID}"
echo "container-init boot-smoke: $image_uri"

cid=$(docker run -d \
    -e CONTAINER_INIT_TRACE=1 \
    -e KASM_VNC=0 -e KASM_PROFILE_PULL=0 \
    "$image_uri")

# Give container-init up to 15s to reach supervisor_start.
ok=0
for i in $(seq 1 30); do
    if docker exec "$cid" grep -qE '"phase":"supervisor_start"' /tmp/container-init-trace.jsonl 2>/dev/null; then
        ok=1
        break
    fi
    sleep 0.5
done

# Capture artefacts before tearing down.
mkdir -p artifacts
docker logs "$cid" > "artifacts/container-init.${NAME1}.${NAME2}.${ARCH}.stdout" 2>&1 || true
docker exec "$cid" cat /tmp/container-init-trace.jsonl \
    > "artifacts/container-init.${NAME1}.${NAME2}.${ARCH}.trace.jsonl" 2>/dev/null || true
docker stop -t 5 "$cid" >/dev/null 2>&1 || true
docker rm -f "$cid" >/dev/null 2>&1 || true

if [ "$ok" -ne 1 ]; then
    echo "FAIL  container-init boot smoke — supervisor_start not seen within 15s"
    tail -50 "artifacts/container-init.${NAME1}.${NAME2}.${ARCH}.stdout" || true
    exit 1
fi
echo "PASS  container-init boot smoke for ${NAME1}-${NAME2} ${ARCH}"
