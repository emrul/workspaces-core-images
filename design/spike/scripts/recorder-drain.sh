#!/bin/sh
# Drain stand-in. Kasm's real recorder-drain runs the
# ensure_recorder_terminates_gracefully pgrep loop; here we just print
# a recognisable line and exit 0 — ExitContainerOnFailure=true on the
# unit causes container-init to begin reverse shutdown either way.
set -eu

echo "recorder-drain: drain complete (spike stub)"
exit 0
