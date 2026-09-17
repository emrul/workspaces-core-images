#!/bin/sh
# In-container milestone probe. Same readiness definition as upstream's
# wait_for_desktop.py (VNC-574): EWMH WM present, a DESKTOP and a DOCK client
# window both mapped+viewable, and the X server answering xdpyinfo.
# Prints "listen <epoch>" when KasmVNC's websocket port is listening and
# "desktop <epoch>" at the desktop milestone. Identical cost in every variant.
export DISPLAY="${DISPLAY:-:1}" LC_ALL=C
PORT_HEX=$(printf '%04X' "${NO_VNC_PORT:-6901}")
deadline=$(( $(date +%s) + ${1:-90} ))
listen=
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -z "$listen" ] && cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk -v p=":$PORT_HEX" '$2 ~ p"$" && $4=="0A"{f=1} END{exit !f}'; then
    listen=$(date +%s.%N); echo "listen $listen"
  fi
  props=$(xprop -root _NET_SUPPORTING_WM_CHECK _NET_CLIENT_LIST 2>/dev/null)
  if echo "$props" | grep -Eq '_NET_SUPPORTING_WM_CHECK.*window id # 0x[1-9a-f]'; then
    desk= dock=
    for w in $(echo "$props" | sed -n 's/.*_NET_CLIENT_LIST[^#]*# //p' | tr -d ',' ); do
      kind=$(xprop -id "$w" _NET_WM_WINDOW_TYPE 2>/dev/null)
      case "$kind" in
        *_NET_WM_WINDOW_TYPE_DESKTOP*) xwininfo -id "$w" 2>/dev/null | grep -q 'Map State: IsViewable' && desk=1 ;;
        *_NET_WM_WINDOW_TYPE_DOCK*)    xwininfo -id "$w" 2>/dev/null | grep -q 'Map State: IsViewable' && dock=1 ;;
      esac
    done
    if [ -n "$desk" ] && [ -n "$dock" ] && xdpyinfo >/dev/null 2>&1; then
      echo "desktop $(date +%s.%N)"; exit 0
    fi
  fi
  sleep 0.1
done
echo "timeout"; exit 1
