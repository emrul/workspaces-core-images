#!/usr/bin/env bash
# Phase 3.2 — parity tests for kasm-upload-server.
#
# Boots two containers from the same Kasm core image:
#   - py:  the existing PyInstaller-bundled Flask helper at
#          /dockerstartup/upload_server/kasm_upload_server
#   - go:  the new Go drop-in built by `make upload`, bind-mounted
#          over the path the bash startup chain expects.
#
# Sends the same upload(s) to each, then asserts both produced
# byte-identical HTTP responses (status + body + Content-Type) and
# byte-identical on-disk state (path, permissions, owner, contents).
#
# Tooling: bash + curl + podman 4.8.2 + lima (per the Phase 0/1/2
# harness pattern). No Go test runtime needed; this exists so CI
# can validate the swap with the same primitives a human would use.
#
# Exit code: 0 on full parity; 1 on any divergence.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../../.." && pwd)"
CI_DIR="${REPO_ROOT}/src/common/container-init"
GO_BIN_HOST="${CI_DIR}/bin/kasm-upload-server.linux-arm64"
GO_BIN_ALT="${CI_DIR}/bin/kasm-upload-server.linux-amd64"

# lima's podman defaults to journald; force k8s-file so `podman logs`
# returns container stdout (per design/work_sequence.md Phase 3 brief).
PODMAN_RUN_FLAGS=(--log-driver=k8s-file --user root)

IMAGE="${KASM_PARITY_IMAGE:-docker.io/kasmweb/core-ubuntu-noble:1.18.0-rolling-daily}"
PYTHON_PORT=15901
GO_PORT=15902
TOKEN="kasm_user:parityPW"
PY_CID=""
GO_CID=""
WORKDIR="$(mktemp -d -t kasm-parity-XXXXXX)"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

cleanup() {
  [[ -n "${PY_CID}" ]] && podman rm -f "${PY_CID}" >/dev/null 2>&1 || true
  [[ -n "${GO_CID}" ]] && podman rm -f "${GO_CID}" >/dev/null 2>&1 || true
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

# Pick the right Go binary for the image arch.
img_arch="$(podman inspect --format '{{.Architecture}}' "${IMAGE}" 2>/dev/null || echo unknown)"
case "${img_arch}" in
  arm64) GO_BIN="${GO_BIN_HOST}";;
  amd64) GO_BIN="${GO_BIN_ALT}";;
  *)     GO_BIN="${GO_BIN_HOST}";;
esac

if [[ ! -x "${GO_BIN}" ]]; then
  red "Go binary not built: ${GO_BIN}"
  yellow "Run: make -C ${CI_DIR} upload"
  exit 2
fi

yellow "image:    ${IMAGE} (${img_arch})"
yellow "go bin:   ${GO_BIN}"
yellow "workdir:  ${WORKDIR}"

# Boot helpers. Both run as kasm-user (uid 1000) like the bash startup
# chain does — file ownership parity depends on it.
boot() {
  local name="$1" port="$2" extra_mount="$3" exec_cmd="$4"
  podman run -d --name "${name}" "${PODMAN_RUN_FLAGS[@]}" \
    -p "${port}:4902" \
    ${extra_mount} \
    --entrypoint /bin/bash "${IMAGE}" -c "
      set -e
      mkdir -p /home/kasm-user/Uploads
      chown -R 1000:1000 /home/kasm-user
      exec runuser -u kasm-user -- ${exec_cmd}
    "
}

PY_CID="$(boot "kasm-parity-py" "${PYTHON_PORT}" "" \
  "/dockerstartup/upload_server/kasm_upload_server --ssl --auth-token '${TOKEN}' --port 4902 --upload-dir /home/kasm-user/Uploads")"

GO_CID="$(boot "kasm-parity-go" "${GO_PORT}" \
  "-v ${GO_BIN}:/usr/local/bin/kasm-upload-server:ro" \
  "/usr/local/bin/kasm-upload-server --ssl --auth-token '${TOKEN}' --port 4902 --upload-dir /home/kasm-user/Uploads")"

# Wait for both to listen.
wait_listen() {
  local cid="$1"
  for i in $(seq 1 100); do
    if podman exec "${cid}" ss -tln 2>/dev/null | grep -q ':4902 '; then return 0; fi
    sleep 0.1
  done
  red "${cid}: listener never came up"
  podman logs "${cid}" 2>&1 | tail -20
  return 1
}
wait_listen "${PY_CID}"
wait_listen "${GO_CID}"

PASS_COUNT=0
FAIL_COUNT=0

# Helpers that hit each backend via curl with identical payload, then
# compare response status, body bytes, Content-Type header, and the
# resulting on-disk file (path, mode, owner, contents).

curl_to() {
  # $1=baseurl  rest=curl args
  local url="$1"; shift
  curl -sk --http1.1 -D "${WORKDIR}/.hdr" -o "${WORKDIR}/.body" -w '%{http_code}' \
    "$@" "${url}"
}

assert_equal() {
  local label="$1" want="$2" got="$3"
  if [[ "${want}" == "${got}" ]]; then
    return 0
  fi
  red "  FAIL ${label}: want=${want@Q} got=${got@Q}"
  return 1
}

case_compare() {
  # Asserts both backends return identical status, body, content-type.
  _case_compare full "$@"
}

case_compare_status_only() {
  # Asserts only matching status code. Use for malformed-request paths
  # where Werkzeug's generic 400 HTML page is an implementation detail
  # the noVNC client never sees (it never sends bad requests).
  _case_compare status "$@"
}

_case_compare() {
  local mode="$1" label="$2"
  shift 2
  local args=("$@")

  # Request both backends.
  local py_status py_body py_ct
  py_status="$(curl_to "https://127.0.0.1:${PYTHON_PORT}/upload" "${args[@]}")"
  py_body="$(<"${WORKDIR}/.body")"
  py_ct="$(awk -F': ' 'tolower($1)=="content-type"{print $2}' "${WORKDIR}/.hdr" | tr -d '\r' | head -1)"

  local go_status go_body go_ct
  go_status="$(curl_to "https://127.0.0.1:${GO_PORT}/upload" "${args[@]}")"
  go_body="$(<"${WORKDIR}/.body")"
  go_ct="$(awk -F': ' 'tolower($1)=="content-type"{print $2}' "${WORKDIR}/.hdr" | tr -d '\r' | head -1)"

  local ok=0
  assert_equal "${label} status" "${py_status}" "${go_status}" || ok=1
  if [[ "${mode}" == "full" ]]; then
    assert_equal "${label} body"         "${py_body}" "${go_body}" || ok=1
    assert_equal "${label} content-type" "${py_ct}"   "${go_ct}"   || ok=1
  fi

  if (( ok == 0 )); then
    PASS_COUNT=$((PASS_COUNT + 1))
    green "  OK  ${label} (HTTP ${py_status})"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# === Test cases ===

# Stage a tiny fixture file on the host (Linux container's /etc/hostname
# isn't reachable from the macOS host that runs curl).
TINY="${WORKDIR}/tiny.txt"
printf 'parity-tiny-fixture\n' > "${TINY}"
TINY_SZ="$(wc -c < "${TINY}" | tr -d ' ')"

echo
yellow "[1/8] auth: missing Authorization header"
case_compare "missing auth" -X POST \
  -F "file=@${TINY};filename=auth1.txt" \
  -F "dzchunkindex=0" -F "dzchunkbyteoffset=0" \
  -F "dztotalfilesize=${TINY_SZ}" -F "dztotalchunkcount=1"

yellow "[2/8] auth: wrong credentials"
case_compare "wrong creds" -X POST -u "kasm_user:wrong" \
  -F "file=@${TINY};filename=auth2.txt" \
  -F "dzchunkindex=0" -F "dzchunkbyteoffset=0" \
  -F "dztotalfilesize=${TINY_SZ}" -F "dztotalchunkcount=1"

yellow "[3/8] auth: bearer token (not basic)"
case_compare "bearer-not-basic" -X POST -H "Authorization: Bearer xyz" \
  -F "file=@${TINY};filename=auth3.txt" \
  -F "dzchunkindex=0" -F "dzchunkbyteoffset=0" \
  -F "dztotalfilesize=${TINY_SZ}" -F "dztotalchunkcount=1"

yellow "[4/8] auth: malformed Authorization (garbage)"
case_compare "garbage-auth" -X POST -H "Authorization: garbage" \
  -F "file=@${TINY};filename=auth4.txt" \
  -F "dzchunkindex=0" -F "dzchunkbyteoffset=0" \
  -F "dztotalfilesize=${TINY_SZ}" -F "dztotalchunkcount=1"

yellow "[5/8] missing dzchunkindex (status-only: Werkzeug's HTML page is opaque)"
case_compare_status_only "missing field" -X POST -u "${TOKEN}" \
  -F "file=@${TINY};filename=missing-field.txt" \
  -F "dztotalfilesize=${TINY_SZ}" -F "dztotalchunkcount=1" -F "dzchunkbyteoffset=0"

# Disk-state parity: send identical happy-path uploads and compare the
# resulting files byte-for-byte.

PAYLOAD="${WORKDIR}/payload.bin"
python3 -c "import sys, os; sys.stdout.buffer.write(os.urandom(1024))" > "${PAYLOAD}"
PSZ="$(wc -c < "${PAYLOAD}" | tr -d ' ')"

upload_to() {
  local port="$1" filename="$2"
  curl -sk --http1.1 -X POST -u "${TOKEN}" -o /dev/null -w '%{http_code}' \
    -F "file=@${PAYLOAD};filename=${filename}" \
    -F "dzchunkindex=0" -F "dzchunkbyteoffset=0" \
    -F "dztotalfilesize=${PSZ}" -F "dztotalchunkcount=1" \
    -F "dzchunksize=${PSZ}" -F "dzuuid=parity" \
    "https://127.0.0.1:${port}/upload"
}

yellow "[6/8] disk parity: single-chunk happy path"
py_st="$(upload_to "${PYTHON_PORT}" disk1.bin)"
go_st="$(upload_to "${GO_PORT}"     disk1.bin)"
ok=0
assert_equal "single-chunk status py"  "200"  "${py_st}" || ok=1
assert_equal "single-chunk status go"  "200"  "${go_st}" || ok=1
py_meta="$(podman exec "${PY_CID}" stat -c '%a %U:%G %s' /home/kasm-user/Uploads/disk1.bin)"
go_meta="$(podman exec "${GO_CID}" stat -c '%a %U:%G %s' /home/kasm-user/Uploads/disk1.bin)"
assert_equal "single-chunk stat" "${py_meta}" "${go_meta}" || ok=1
py_md5="$(podman exec "${PY_CID}" md5sum /home/kasm-user/Uploads/disk1.bin | awk '{print $1}')"
go_md5="$(podman exec "${GO_CID}" md5sum /home/kasm-user/Uploads/disk1.bin | awk '{print $1}')"
assert_equal "single-chunk md5"  "${py_md5}"  "${go_md5}"  || ok=1
host_md5="$(md5 -q "${PAYLOAD}" 2>/dev/null || md5sum "${PAYLOAD}" | awk '{print $1}')"
assert_equal "single-chunk md5 vs host" "${host_md5}" "${go_md5}" || ok=1
if (( ok == 0 )); then
  PASS_COUNT=$((PASS_COUNT + 1))
  green "  OK  single-chunk disk parity (mode/owner/size/md5)"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

yellow "[7/8] disk parity: re-upload same name → 400 + 'File already exists'"
py_st="$(upload_to "${PYTHON_PORT}" disk1.bin)"
go_st="$(upload_to "${GO_PORT}"     disk1.bin)"
ok=0
assert_equal "reupload status py" "400" "${py_st}" || ok=1
assert_equal "reupload status go" "400" "${go_st}" || ok=1
if (( ok == 0 )); then
  PASS_COUNT=$((PASS_COUNT + 1))
  green "  OK  re-upload returns identical 400 on both backends"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

yellow "[8/8] disk parity: multi-chunk reassembly"
PAYLOAD2="${WORKDIR}/multi.bin"
python3 -c "import sys, os; sys.stdout.buffer.write(os.urandom(2048))" > "${PAYLOAD2}"
TSZ="$(wc -c < "${PAYLOAD2}" | tr -d ' ')"
HALF=$((TSZ / 2))
dd if="${PAYLOAD2}" of="${WORKDIR}/multi.c0" bs="${HALF}" count=1 2>/dev/null
dd if="${PAYLOAD2}" of="${WORKDIR}/multi.c1" bs="${HALF}" skip=1 count=1 2>/dev/null

upload_chunk() {
  local port="$1" name="$2" chunk_file="$3" idx="$4" off="$5"
  curl -sk --http1.1 -X POST -u "${TOKEN}" -o /dev/null -w '%{http_code}' \
    -F "file=@${chunk_file};filename=${name}" \
    -F "dzchunkindex=${idx}" -F "dzchunkbyteoffset=${off}" \
    -F "dztotalfilesize=${TSZ}" -F "dztotalchunkcount=2" \
    -F "dzchunksize=${HALF}" -F "dzuuid=multi" \
    "https://127.0.0.1:${port}/upload"
}

ok=0
for port in "${PYTHON_PORT}" "${GO_PORT}"; do
  s0="$(upload_chunk "${port}" multi.bin "${WORKDIR}/multi.c0" 0 0)"
  s1="$(upload_chunk "${port}" multi.bin "${WORKDIR}/multi.c1" 1 "${HALF}")"
  assert_equal "multi chunk0 :${port}" "200" "${s0}" || ok=1
  assert_equal "multi chunk1 :${port}" "200" "${s1}" || ok=1
done
py_md5="$(podman exec "${PY_CID}" md5sum /home/kasm-user/Uploads/multi.bin | awk '{print $1}')"
go_md5="$(podman exec "${GO_CID}" md5sum /home/kasm-user/Uploads/multi.bin | awk '{print $1}')"
host_md5="$(md5 -q "${PAYLOAD2}" 2>/dev/null || md5sum "${PAYLOAD2}" | awk '{print $1}')"
assert_equal "multi md5 py vs host" "${host_md5}" "${py_md5}" || ok=1
assert_equal "multi md5 go vs host" "${host_md5}" "${go_md5}" || ok=1
py_meta="$(podman exec "${PY_CID}" stat -c '%a %U:%G %s' /home/kasm-user/Uploads/multi.bin)"
go_meta="$(podman exec "${GO_CID}" stat -c '%a %U:%G %s' /home/kasm-user/Uploads/multi.bin)"
assert_equal "multi stat" "${py_meta}" "${go_meta}" || ok=1
if (( ok == 0 )); then
  PASS_COUNT=$((PASS_COUNT + 1))
  green "  OK  multi-chunk reassembly identical (md5 + stat)"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

echo
echo "================================="
echo "  parity results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "================================="

if (( FAIL_COUNT > 0 )); then
  red "FAIL"
  exit 1
fi
green "PASS — Go drop-in is wire-compatible with the Python helper"
