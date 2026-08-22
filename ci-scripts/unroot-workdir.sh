#!/usr/bin/env bash
# unroot-workdir.sh — give the runner user back ownership of anything a root
# container left in the CI checkout. Runs from `after_script`, so it executes on
# success, failure, timeout AND cancellation.
#
# Why this exists
# ───────────────
# Our heavy jobs write into $CI_PROJECT_DIR from containers running as root
# (scan-nix's vulnix/ and sboms/, publish's report copy, assess's envelope). On a
# normal exit each one chowns its own output back to $HOST_UID. A CANCELLED job
# never reaches that step, so the files stay root-owned — and the runner user
# cannot delete them, which fails the NEXT pipeline's `git clean` during
# get_sources. GitLab does not run after_script when a job dies in get_sources,
# so that state cannot heal itself: it needs a human with sudo. With
# `concurrent = 1` on this runner there is exactly one build dir, so one
# cancelled job blocks every subsequent pipeline.
#
# Observed 2026-08-22: cancelling pipeline 2782199084 (auto-cancel on push) left
# 38 root-owned paths under vulnix/, and 2782293492 then failed build,
# publish-base and scan-base at checkout with "failed to remove
# vulnix/…: Permission denied".
#
# An after_script guard for this already existed and DID run on that cancel — but
# it was gated on `NIX_RUNNER_SHIM = dind-run.sh`, and the global default is
# host-run.sh, so it skipped itself. The premise of that gate ("host-run.sh runs
# as the runner user, so there is nothing to chown") does not hold: host-run.sh
# jobs still launch root containers that write into the checkout. Hence NO shim
# gate here — the only precondition is having a container runtime to borrow root
# from, since the runner's sudo is nerdctl-scoped.
#
# find|xargs rather than `chown -R`: only the offending paths are touched, so
# this stays well inside the cancellation grace window even on a large checkout.
#
# Best-effort by design — this must never turn a passing job red. But it does
# WARN on failure rather than swallowing the error: the previous guard's
# `>/dev/null 2>&1 || true` is why a no-op looked exactly like a success.
set -uo pipefail

DIR="${1:-${CI_PROJECT_DIR:-$PWD}}"
NERDCTL="${NERDCTL:-nerdctl}"
IMG="${UNROOT_IMAGE:-quay.io/podman/stable}"
uid="$(id -u)"; gid="$(id -g)"

log() { printf '[unroot-workdir] %s\n' "$*" >&2; }

[[ -d "${DIR}" ]] || { log "no such directory: ${DIR} — nothing to do"; exit 0; }

# Cheap pre-check as the runner user: if nothing is foreign-owned we skip the
# container entirely, which is the common case on a clean exit.
foreign="$(find "${DIR}" ! -user "${uid}" -print -quit 2>/dev/null || true)"
if [[ -z "${foreign}" ]]; then
  exit 0
fi

if ! command -v "${NERDCTL}" >/dev/null 2>&1; then
  log "WARN ${DIR} holds files not owned by uid ${uid} (e.g. ${foreign}) and ${NERDCTL} is not available"
  log "WARN the next pipeline's checkout will FAIL on these — un-root them by hand"
  exit 0
fi

log "un-rooting ${DIR} (found at least one path not owned by uid ${uid})"
if sudo "${NERDCTL}" run --rm -v "${DIR}:/w" "${IMG}" \
     sh -c "find /w ! -user ${uid} -print0 | xargs -0r chown ${uid}:${gid}"; then
  left="$(find "${DIR}" ! -user "${uid}" -print -quit 2>/dev/null || true)"
  if [[ -n "${left}" ]]; then
    log "WARN still not owned by uid ${uid}: ${left} — the next checkout may fail"
  else
    log "done — ${DIR} is fully owned by uid ${uid}"
  fi
else
  log "WARN could not un-root ${DIR}; the next pipeline's checkout may fail on it"
fi
exit 0
