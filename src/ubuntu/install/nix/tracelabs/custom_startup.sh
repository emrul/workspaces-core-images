#!/usr/bin/env bash
# custom_startup.sh — FULL-DESKTOP startup for the Nix Trace Labs OSINT image.
#
# Unlike the single-application images (chrome, angelfish, …) whose
# custom_startup.sh is a respawn loop around one binary, Trace Labs ships a
# whole desktop of OSINT tools. The user opens them from the XFCE menu /
# desktop icons — there is NO single app to launch or keep alive. This script
# therefore launches nothing on connect; the window manager and desktop are
# already up (container-init's window-manager + custom-startup services).
#
# It still honours the Kasm contract so `docker exec` opens work:
#   -g/--go, -a/--assign, -u/--url  → kasm_exec: open a URL in the default
#                                     browser (Firefox) when one is supplied
#   LAUNCH_URL / KASM_URL           → opened once on first startup if set
#   DISABLE_CUSTOM_STARTUP          → honoured (no-op here anyway)
#
# See design/tracelabs-osint-image.md §5.1.
set -e

BROWSER="/usr/local/bin/firefox-launch"   # composed in via requires=[…firefox…]
[ -x "${BROWSER}" ] || BROWSER="firefox"

options=$(getopt -o gau: -l go,assign,url: -n "$0" -- "$@") || exit
eval set -- "$options"
GO=''; ASSIGN=''; OPT_URL=''
while [[ $1 != -- ]]; do
    case $1 in
        -g|--go)     GO='true'; shift 1;;
        -a|--assign) ASSIGN='true'; shift 1;;
        -u|--url)    OPT_URL=$2; shift 2;;
        *) echo "bad option: $1" >&2; exit 1;;
    esac
done
shift

kasm_exec() {
    local url="${OPT_URL:-$1}"
    if [ -n "$url" ]; then
        /usr/bin/filter_ready
        /usr/bin/desktop_ready
        "${BROWSER}" "$url" &
    else
        echo "[tracelabs] exec with no URL — desktop is a full OSINT toolset; nothing to launch."
    fi
}

kasm_startup() {
    # Full desktop: launch nothing. Optionally open a landing URL once.
    local url="${KASM_URL:-$LAUNCH_URL}"
    if [ -z "$DISABLE_CUSTOM_STARTUP" ] && [ -n "$url" ]; then
        /usr/bin/filter_ready
        /usr/bin/desktop_ready
        "${BROWSER}" "$url" &
    fi
    echo "[tracelabs] full-desktop startup: tools are launched from the XFCE menu / desktop icons."
    # Return cleanly — the desktop keeps running independently of this shim.
}

if [ -n "$GO" ] || [ -n "$ASSIGN" ]; then
    kasm_exec "$@"
else
    kasm_startup
fi
