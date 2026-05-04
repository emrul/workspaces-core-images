#!/bin/sh
# WM stand-in for probes D and E.
#
# - SIGUSR1 → exit 1 (probes D + E use this to "crash" the WM)
# - SIGTERM → exit 0 (clean shutdown from container-init reverse path)
# - Otherwise blocks on a sentinel sleep so it shows up in ps/pgrep
#   without being confused with kasmvnc / recorder-watch's plain
#   `sleep 3600`.
set -eu

echo "wm-stub: running indefinitely"

sleep 3601 &
sleep_pid=$!

# Use a single trap that takes a parameter so SIGTERM exits 0 (clean)
# and SIGUSR1 exits 1 (failure path that triggers Restart=on-failure
# and OnFailure= chains).
on_term() { echo "wm-stub: SIGTERM -> exit 0"; kill $sleep_pid 2>/dev/null || true; exit 0; }
on_usr1() { echo "wm-stub: SIGUSR1 -> exit 1"; kill $sleep_pid 2>/dev/null || true; exit 1; }
trap on_term TERM INT
trap on_usr1 USR1

wait $sleep_pid
echo "wm-stub: sleep returned naturally; exit 0"
exit 0
