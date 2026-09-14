#!/usr/bin/env bash
set -euo pipefail

has_process() {
  local expected="$1" process comm
  for process in /proc/[0-9]*; do
    [[ -r "$process/comm" ]] || continue
    IFS= read -r comm <"$process/comm" || continue
    [[ "$comm" == "$expected" ]] && return 0
  done
  return 1
}

has_process weston
has_process Xwayland
has_process x11vnc
has_process xfce4-session

x_display="$(DISPLAY="${DISPLAY:-:55}" XAUTHORITY="${XAUTHORITY:-}" /usr/bin/xdpyinfo 2>/dev/null)"
grep -Eq '^[[:space:]]*DRI3$' <<<"$x_display"
grep -Eq '^[[:space:]]*Present$' <<<"$x_display"

curl --fail --silent --show-error --max-time 2 "http://127.0.0.1:${PORT_NOVNC_WEB:-8083}/" >/dev/null
