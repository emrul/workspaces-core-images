#!/usr/bin/env bash
# custom_startup.sh for the PhotoDemon (Wine) single-app image. Same shape as the other
# nix profiles' scripts: keep the app running; --go/--assign exec it once for exec_config.
# PGREP matches wine's process name for the entrypoint (the Windows path of the exe).
set -ex
START_COMMAND="/usr/local/bin/wine-app-photodemon-launch"
PGREP='PhotoDemon\.exe$'
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
    /usr/bin/filter_ready
    /usr/bin/desktop_ready
    $START_COMMAND $ARGS
}
kasm_startup() {
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
                $START_COMMAND $ARGS
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
