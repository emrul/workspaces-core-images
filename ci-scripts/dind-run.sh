#!/usr/bin/env bash
# dind-run.sh — run a named privileged DinD (nerdctl) container and GUARANTEE it
# is torn down when this job process is signalled (GitLab cancel/timeout).
#
# Why a trap and not just after_script: GitLab does not reliably run after_script
# on cancel, and `sudo nerdctl run` is a root child that survives the runner
# killing the (gitlab-runner-user) job process group — so a cancelled build
# keeps running and holds the podman store lock, blocking the next pipeline.
# This wrapper IS the job's own shell (it receives SIGTERM on cancel), so its
# TERM/INT/EXIT trap fires and force-removes the container via sudo. Running
# nerdctl in the background + `wait` keeps the trap responsive (a foreground
# nerdctl would defer the signal until it returns).
#
#   usage: dind-run.sh <container-name> <nerdctl run args...>
set -uo pipefail

name="${1:?usage: dind-run.sh <name> <nerdctl run args...>}"; shift

cleanup() { sudo nerdctl rm -f "${name}" >/dev/null 2>&1 || true; }
trap 'cleanup; exit 143' INT TERM
trap cleanup EXIT

# Pre-clean any stale container of the same name from a prior interrupted run.
cleanup

sudo nerdctl run --rm --privileged --name "${name}" "$@" &
pid=$!
wait "${pid}"
exit $?
