#!/usr/bin/env bash
# nix-push-lib.sh — the registry-push hardening shared by nix-publish.sh and
# nix-publish-base.sh. Sourced, never executed (same pattern as nix-base-map.sh).
#
# Why this file exists: these two scripts push to the same registry over the same
# network with two independently-maintained copies of the push path, and the
# hardening only ever landed in one of them. On 2026-08-25 (pipeline 2790459309)
# `publish` pushed 37 images green while `publish-base` went red on a single
# dropped connection uploading a 283 MB blob — the SAME blob that `publish` had
# just uploaded successfully into another repo. Same conditions, same registry,
# opposite outcomes, and the only difference was three attempts with a backoff.
# One copy, sourced twice, is the fix for that class of drift.
#
# Callers must define: DOCKER, DRY_RUN. Callers should set PUSH_LOG_PREFIX to
# their own log tag. Both functions set `push_err` on failure so the caller can
# report a cause (nix-publish.sh puts it in the JUnit report).

PUSH_LOG_PREFIX="${PUSH_LOG_PREFIX:-[nix-push]}"
push_err=""

# A registry push streams gigabytes of blobs over a long-lived HTTPS PATCH, so a
# single dropped TCP connection anywhere across ~36 apps used to fail the whole
# job — and with it sbom-publish, security-page and assess, which is how the
# remediator loses its assessment envelope. Observed 2026-07-29 (pipeline
# 2714340414): 35 of 36 pushed, inkscape died on
#   writing blob: Patch ".../blobs/uploads/...": use of closed network connection
# and the next app pushed fine on the same code path. Transient, so retry it.
# PUSH_ATTEMPTS=1 restores the old fail-fast behaviour.
# push_err carries the last failure's tail so the JUnit report can name a cause
# instead of just "failed". Output is TEE'd, not captured: a push moves gigabytes
# and swallowing its progress would leave the job silent for minutes, which is
# exactly the shape of the dind-run hang we spent an afternoon on.
push_with_retry() { # $1=description $2...=command → sets $push_err on failure
  local what="$1"; shift
  if [[ "${DRY_RUN}" == 1 ]]; then echo "  DRY: $*"; push_err=""; return 0; fi
  local attempts="${PUSH_ATTEMPTS:-3}" n=1 rc log
  log="$(mktemp)"
  while :; do
    "$@" 2>&1 | tee "${log}"
    rc="${PIPESTATUS[0]}"
    if [ "${rc}" -eq 0 ]; then
      [ "${n}" -gt 1 ] && echo "${PUSH_LOG_PREFIX} ${what}: succeeded on attempt ${n}"
      push_err=""; rm -f "${log}"; return 0
    fi
    # Keep the tail only — a full push log is megabytes and would bloat the XML.
    push_err="$(grep -iE 'error|fatal|denied|refused|timeout|EOF|broken pipe' "${log}" | tail -3)"
    [ -n "${push_err}" ] || push_err="$(tail -3 "${log}")"
    if [ "${n}" -ge "${attempts}" ]; then
      echo "${PUSH_LOG_PREFIX} ${what}: FAILED after ${n} attempt(s) (rc=${rc})" >&2
      rm -f "${log}"; return 1
    fi
    echo "${PUSH_LOG_PREFIX} ${what}: attempt ${n}/${attempts} failed (rc=${rc}), retrying in $((n*10))s" >&2
    sleep $((n*10))
    n=$((n+1))
  done
}

# An index descriptor is copied from the image CONFIG, so an image whose config
# has no architecture publishes an index that matches no platform at all, and
# containerd rejects it before fetching a byte:
#   no match for platform in manifest: not found
# The tag then points at intact-but-unpullable data, and nothing in the job
# notices — `buildx imagetools create` and `podman manifest add` both copy the
# empty value through without complaint, so the image ships broken and the
# failure surfaces on a user's cluster days later. That is exactly how
# nix-store:nix shipped (crane's --oci-empty-base leaves architecture:"").
# Refuse BEFORE the push: an unpullable tag is strictly worse than a red job,
# because publishing it also overwrites the last-known-good one.
assert_platform() { # $1=local image ref → 1 if the config declares no architecture
  # DRY_RUN never ran the `docker tag`, so there is no local image under the dest
  # name to inspect — an empty answer there means "not tagged", not "no platform".
  [[ "${DRY_RUN}" == 1 ]] && return 0
  local a; a="$("${DOCKER}" image inspect --format '{{.Architecture}}' "$1" 2>/dev/null || true)"
  if [[ -z "${a//[[:space:]]/}" ]]; then
    echo "${PUSH_LOG_PREFIX} FATAL ${1}: image config declares no architecture." >&2
    echo "${PUSH_LOG_PREFIX}   Publishing it would produce an index that matches no platform" >&2
    echo "${PUSH_LOG_PREFIX}   and cannot be pulled. Fix the assembly (crane mutate --set-platform)" >&2
    echo "${PUSH_LOG_PREFIX}   rather than shipping over the last-known-good tag." >&2
    push_err="image config declares no architecture (would publish an unpullable index)"
    return 1
  fi
  return 0
}
