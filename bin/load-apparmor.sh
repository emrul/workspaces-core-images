#!/usr/bin/env bash
# load-apparmor.sh — load (or reload) the Kasm AppArmor profiles into the
# HOST kernel so workspaces can reference them by name via
# `--security-opt apparmor=<name>`.
#
# Unlike seccomp (a JSON file the container runtime reads at launch, or that
# Kasm inlines into run_config), an AppArmor profile MUST be compiled into
# the running kernel ahead of time. Run this once per agent host, and again
# whenever the profiles change. Wire it into host provisioning (Ansible /
# cloud-init / a systemd unit) so every agent has the profiles before a
# workspace that names them is scheduled there.
#
# Usage:
#   sudo bin/load-apparmor.sh                 # load all profiles (enforce)
#   sudo COMPLAIN=1 bin/load-apparmor.sh      # load in COMPLAIN mode (log-only)
#   sudo bin/load-apparmor.sh kasm-app        # load just one profile
#
# ALWAYS load in complain mode first on a new image/host, run a full
# workspace session, check `journalctl -k | grep apparmor` (or
# /var/log/audit/audit.log) for DENIED lines, fix the profile, then reload
# in enforce mode. See docs/apparmor-how-to.md.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="${PROFILE_DIR:-$SCRIPT_DIR/../src/common/apparmor}"
COMPLAIN="${COMPLAIN:-0}"

if ! command -v apparmor_parser >/dev/null 2>&1; then
  echo "error: apparmor_parser not found. This host does not have AppArmor" >&2
  echo "       (expected on RHEL/CentOS/Fedora/Oracle, which use SELinux)." >&2
  echo "       Install with: apt-get install apparmor apparmor-utils" >&2
  exit 1
fi

if [[ ! -d /sys/kernel/security/apparmor ]]; then
  echo "error: AppArmor is not enabled in the running kernel." >&2
  echo "       Check: aa-enabled ; and the 'apparmor=1 security=apparmor' boot args." >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: must run as root (loading kernel policy). Re-run with sudo." >&2
  exit 1
fi

# Which profiles to load: args if given, else all files in the profile dir.
if [[ "$#" -gt 0 ]]; then
  profiles=("$@")
else
  profiles=()
  for f in "$PROFILE_DIR"/kasm-*; do
    [[ -f "$f" ]] && profiles+=("$(basename "$f")")
  done
fi

parser_flags=(-r -W)   # -r replace-if-exists, -W write cache
mode="enforce"
if [[ "$COMPLAIN" == "1" ]]; then
  parser_flags+=(-C)   # -C load in complain mode
  mode="complain"
fi

for name in "${profiles[@]}"; do
  path="$PROFILE_DIR/$name"
  if [[ ! -f "$path" ]]; then
    echo "error: profile not found: $path" >&2
    exit 1
  fi
  echo "loading $name ($mode) ..."
  apparmor_parser "${parser_flags[@]}" "$path"
done

echo "done. loaded profiles:"
aa-status 2>/dev/null | grep -E 'kasm-' || \
  grep -h '^profile ' "${profiles[@]/#/$PROFILE_DIR/}" | awk '{print "  "$2}'
