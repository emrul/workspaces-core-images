#!/usr/bin/env bash
# Install kasm-upload-server.
#
# Phase 3 of design/work_sequence.md replaced the PyInstaller-bundled
# Flask helper (~27 MiB binary, 47 MiB RSS, 200-500 ms cold start)
# with a Go drop-in (~6 MiB static binary, ~1 MiB RSS, <10 ms cold
# start). The Go binary is built from src/common/kasm-go/cmd/
# kasm-upload-server by the `kasmgo_builder` stage in each
# dockerfile-kasm-core* and dropped into $INST_SCRIPTS/kasm_upload_server/
# at `kasm-upload-server` before this script runs.
#
# This script's sole job is to put it at the path Phase 4's upload.service
# expects:
#     /dockerstartup/upload_server/kasm_upload_server  (mode 0755)
set -ex

SRC="$(dirname "$0")/kasm-upload-server"
DEST_DIR="$STARTUPDIR/upload_server"
DEST="$DEST_DIR/kasm_upload_server"

if [[ ! -f "$SRC" ]]; then
    echo "FATAL: $SRC not found." >&2
    echo "       The Dockerfile's kasmgo_builder stage must COPY the binary into" >&2
    echo "       \$INST_SCRIPTS/kasm_upload_server/kasm-upload-server before this" >&2
    echo "       script runs. See dockerfile-kasm-core's 'Install Kasm Upload" >&2
    echo "       Server' block for the canonical pattern." >&2
    exit 1
fi

mkdir -p "$DEST_DIR"
install -m 0755 "$SRC" "$DEST"

# Stamp the version (mirrors the previous behaviour for any tooling
# that greps the file). The binary itself is reproducible from the
# repo SHA, so we record it here for forensic value.
{
    echo "source: src/common/kasm-go/cmd/kasm-upload-server"
    echo "build:  go static, CGO_ENABLED=0"
    if [[ -n "${SOURCE_COMMIT:-}" ]]; then echo "commit: $SOURCE_COMMIT"; fi
} > "$DEST_DIR/kasm_upload_service.version"
