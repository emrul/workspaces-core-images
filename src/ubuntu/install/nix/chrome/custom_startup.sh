#!/usr/bin/env bash
# custom_startup.sh — single-application startup for the Nix Chrome image.
#
# Modeled on the kasmweb/chrome image's custom_startup.sh
# (workspaces-images/src/ubuntu/install/chrome/custom_startup.sh) and the Nix
# Angelfish image. Invoked by container-init's custom-startup.service after the
# window manager starts.
#
# Honours the same Kasm contract as the browser images:
#   LAUNCH_URL / KASM_URL    — page to open on startup
#   APP_ARGS                 — extra args passed to the launcher
#   DISABLE_CUSTOM_STARTUP   — skip the auto-launch loop
#   -g/--go, -a/--assign, -u/--url  — kasm_exec mode for `docker exec` opens
#
# GPU vs software rendering is handled downstream by chrome-launch -> nix-launch.
set -ex
START_COMMAND="/usr/local/bin/chrome-launch"
# Match the real browser process, NOT the launcher chain: nixpkgs' Chrome wrapper
# (bin/google-chrome-stable) execs the actual binary at
# .../share/google/chrome/chrome. Matching that path avoids a false "already
# running" from chrome-launch/nix-launch (which carry bin/google-chrome-stable
# in their argv) relaunching nothing — and a `pgrep -x chrome` would miss it.
PGREP="share/google/chrome/chrome"
PGREP_OPTS="-f"
DEFAULT_ARGS=""
ARGS=${APP_ARGS:-$DEFAULT_ARGS}

options=$(getopt -o gau: -l go,assign,url: -n "$0" -- "$@") || exit
eval set -- "$options"

while [[ $1 != -- ]]; do
    case $1 in
        -g|--go) GO='true'; shift 1;;
        -a|--assign) ASSIGN='true'; shift 1;;
        -u|--url) OPT_URL=$2; shift 2;;
        *) echo "bad option: $1" >&2; exit 1;;
    esac
done
shift

FORCE=$2

kasm_exec() {
    if [ -n "$OPT_URL" ] ; then
        URL=$OPT_URL
    elif [ -n "$1" ] ; then
        URL=$1
    fi

    # We exec into a container that already has the browser running from
    # startup, so with no URL we do nothing (avoids a second instance).
    if [ -n "$URL" ] ; then
        /usr/bin/filter_ready
        /usr/bin/desktop_ready
        $START_COMMAND $ARGS "$OPT_URL"
    else
        echo "No URL specified for exec command. Doing nothing."
    fi
}

kasm_startup() {
    if [ -n "$KASM_URL" ] ; then
        URL=$KASM_URL
    elif [ -z "$URL" ] ; then
        URL=$LAUNCH_URL
    fi

    if [ -z "$DISABLE_CUSTOM_STARTUP" ] || [ -n "$FORCE" ] ; then

        echo "Entering process startup loop"
        set +x
        while true
        do
            if ! pgrep $PGREP_OPTS "$PGREP" > /dev/null
            then
                /usr/bin/filter_ready
                /usr/bin/desktop_ready
                set +e
                $START_COMMAND $ARGS $URL
                set -e
            fi
            sleep 1
        done
        set -x

    fi

}

if [ -n "$GO" ] || [ -n "$ASSIGN" ] ; then
    kasm_exec
else
    kasm_startup
fi
