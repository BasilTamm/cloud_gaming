#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /usr/bin/common-functions.sh

: "${DISPLAY:?DISPLAY is required}"
: "${PORT_VNC:?PORT_VNC is required}"
: "${USER_PASSWORD:?USER_PASSWORD is required for VNC authentication}"

# The VNC protocol authenticates with at most eight bytes, and
# "x11vnc -storepasswd" rejects a longer secret with
# "** password exceeds maximum 8 bytes." instead of truncating it.
# steam-headless.sh already requires the first eight characters of the two
# instance passwords to differ, so truncating here matches the documented
# contract in .env.example rather than weakening it.
vnc_password="${USER_PASSWORD:0:8}"

passwd_file=/run/viking-rise-x11vnc.passwd
umask 077

# Feed the prompts from a here-document instead of a pipe. A here-document is
# a regular file, so x11vnc exiting before it consumes every line cannot raise
# SIGPIPE in a writer and trip "pipefail". The trailing "y" answers the
# write-confirmation prompt when x11vnc asks for it and is ignored otherwise.
# Both streams stay attached to the supervisor log files: swallowing them hid
# this failure completely and left x11vnc.err.log empty at zero bytes.
/usr/bin/x11vnc -storepasswd "$passwd_file" <<EOF
$vnc_password
$vnc_password
y
EOF

# Fail loudly and early if the secret was not written, rather than letting
# x11vnc start without usable authentication.
test -s "$passwd_file"

wait_for_x
exec /usr/bin/x11vnc \
  -display "$DISPLAY" \
  -rfbport "$PORT_VNC" \
  -rfbauth "$passwd_file" \
  -shared \
  -forever
