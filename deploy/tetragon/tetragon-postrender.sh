#!/bin/sh
# Helm post-renderer for the Tetragon chart.
#
# The chart HARD-CODES `terminationGracePeriodSeconds: 1` in the DaemonSet
# (templates/daemonset.yaml) with no values key, so it cannot be set via
# values.yaml or --set. One second is not enough for a busy agent to unload its
# BPF sensors on shutdown, which the §2.6 kill switch depends on: a SIGKILLed
# agent leaves its programs attached after the pods are gone.
#
# Do NOT substitute `kubectl patch` for this. Patching makes kubectl the field
# manager for that path and every later `helm upgrade` then fails with a
# server-side-apply conflict.
#
# The chart's operator Deployment uses 10, and the DaemonSet is the only object
# rendering the literal `: 1`, so this anchored match is unambiguous. If a chart
# bump changes that, the guard below fails the render rather than silently
# no-op'ing.
set -eu

GRACE="${TETRAGON_GRACE_SECONDS:-30}"
in=$(cat)

n=$(printf '%s\n' "$in" | grep -c '^      terminationGracePeriodSeconds: 1$' || true)
if [ "$n" -ne 1 ]; then
    echo "tetragon-postrender: expected exactly 1 hard-coded grace period, found $n." >&2
    echo "The chart layout changed -- re-verify against the new template before deploying." >&2
    exit 1
fi

printf '%s\n' "$in" | sed "s/^      terminationGracePeriodSeconds: 1$/      terminationGracePeriodSeconds: ${GRACE}/"
