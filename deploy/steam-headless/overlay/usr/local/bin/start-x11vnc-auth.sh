#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /usr/bin/common-functions.sh

: "${DISPLAY:?DISPLAY is required}"
: "${PORT_VNC:?PORT_VNC is required}"
: "${USER_PASSWORD:?USER_PASSWORD is required for VNC authentication}"

passwd_file=/run/viking-rise-x11vnc.passwd
umask 077
printf '%s\n%s\n' "$USER_PASSWORD" "$USER_PASSWORD" | \
  /usr/bin/x11vnc -storepasswd "$passwd_file" >/dev/null 2>&1

wait_for_x
exec /usr/bin/x11vnc \
  -display "$DISPLAY" \
  -rfbport "$PORT_VNC" \
  -rfbauth "$passwd_file" \
  -shared \
  -forever
