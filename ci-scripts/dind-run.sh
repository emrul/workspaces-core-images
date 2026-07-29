#!/usr/bin/env bash
# dind-run.sh — run a named privileged DinD (nerdctl) container, stream its
# output, return ITS exit code, and GUARANTEE teardown when this job process is
# signalled (GitLab cancel/timeout).
#
# Why a trap and not just after_script: GitLab does not reliably run after_script
# on cancel, and `sudo nerdctl run` is a root child that survives the runner
# killing the (gitlab-runner-user) job process group — so a cancelled build
# keeps running and holds the podman store lock, blocking the next pipeline.
# This wrapper IS the job's own shell (it receives SIGTERM on cancel), so its
# TERM/INT/EXIT trap fires and force-removes the container via sudo.
#
# Why detached + `nerdctl wait` rather than `nerdctl run --rm` in the background:
# observed 2026-07-29 on pipeline 2713557727 — the four-distro cold base build
# finished successfully at 122.8 min ("[base] OK — built: alpine fedora resolute
# ubuntu"), the container reported Exited (0), and yet the job hung for a further
# 57 min until GitLab's 3h timeout killed it, turning a completed build into a
# red pipeline with `build` skipped. The container was still present despite
# --rm, i.e. the nerdctl CLIENT never finished its cleanup, so the `wait` on it
# never returned. Under --privileged podman-in-podman, containerd task deletion
# can block on the inner runtime's leftovers (conmon, fuse-overlayfs mounts), and
# `run --rm` couples our exit path to that cleanup.
#
# So: the container's lifetime and the client's lifetime are now separated. We
# take the exit status from `nerdctl wait`, which reports the CONTAINER, and do
# the removal ourselves — the same removal the trap already performs, so cancel
# and success share one teardown path.
#
#   usage: dind-run.sh <container-name> <nerdctl run args...>
set -uo pipefail

name="${1:?usage: dind-run.sh <name> <nerdctl run args...>}"; shift

logs_pid=""
cleanup() {
    [ -n "${logs_pid}" ] && kill "${logs_pid}" 2>/dev/null || true
    sudo nerdctl rm -f "${name}" >/dev/null 2>&1 || true
}
trap 'cleanup; exit 143' INT TERM
trap cleanup EXIT

# Pre-clean any stale container of the same name from a prior interrupted run.
cleanup

# Detached: --rm is deliberately NOT passed. The container must survive its own
# exit long enough for `nerdctl wait` to report the status.
sudo nerdctl run -d --privileged --name "${name}" "$@" >/dev/null || exit 1

# Stream the log from the beginning, independently of the container's lifecycle.
sudo nerdctl logs -f "${name}" 2>&1 &
logs_pid=$!

# Authoritative status: the container's, not the client's. A missing/garbled
# value is treated as failure — never as success.
rc="$(sudo nerdctl wait "${name}" 2>/dev/null | tr -dc '0-9' | head -c 3)"
[ -n "${rc}" ] || rc=1

# Let the log tail drain before the EXIT trap removes the container underneath it.
sleep 1
exit "${rc}"
