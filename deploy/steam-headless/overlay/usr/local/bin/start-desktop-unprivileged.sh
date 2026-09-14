#!/usr/bin/env bash
set -euo pipefail

: "${RENDER_DEVICE:?RENDER_DEVICE is required}"
: "${DISPLAY:?DISPLAY is required}"
: "${DISPLAY_SIZEW:?DISPLAY_SIZEW is required}"
: "${DISPLAY_SIZEH:?DISPLAY_SIZEH is required}"
: "${XAUTHORITY:?XAUTHORITY is required}"
: "${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is required}"

if [[ ! -r "$RENDER_DEVICE" || ! -w "$RENDER_DEVICE" ]]; then
  echo "ERROR: desktop user cannot read/write $RENDER_DEVICE after privilege drop." >&2
  exit 1
fi

display_number="${DISPLAY#:}"
[[ "$DISPLAY" == ":$display_number" && "$display_number" =~ ^[0-9]+$ ]] || {
  echo "ERROR: DISPLAY must be a local numeric display such as :55." >&2
  exit 1
}
[[ "$DISPLAY_SIZEW" =~ ^[0-9]+$ && "$DISPLAY_SIZEH" =~ ^[0-9]+$ ]] || {
  echo "ERROR: display dimensions must be integers." >&2
  exit 1
}
[[ -d "$XDG_RUNTIME_DIR" && -w "$XDG_RUNTIME_DIR" ]] || {
  echo "ERROR: desktop user cannot write XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR." >&2
  exit 1
}

display_socket="/tmp/.X11-unix/X$display_number"
display_lock="/tmp/.X${display_number}-lock"
if DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" /usr/bin/xdpyinfo >/dev/null 2>&1; then
  echo "ERROR: $DISPLAY is already served by another live X server." >&2
  exit 1
fi
rm -f -- "$display_socket" "$display_lock"

# xwfb-run owns the whole display lifetime: Weston provides a headless EGL
# compositor on the passed render node, Xwayland provides a rootful X11 screen
# with DRI3, and the upstream script starts Xfce as its long-lived client.
# The fixed display and authority paths let separately supervised Steam and
# x11vnc processes connect to the same X server.
exec /usr/bin/xwfb-run \
  --compositor weston \
  --server-num "$display_number" \
  --auth-file "$XAUTHORITY" \
  --error-file /home/default/.cache/log/xwayland.err.log \
  --wait 1 \
  --server-args '\-geometry' \
  --server-args "${DISPLAY_SIZEW}x${DISPLAY_SIZEH}" \
  --compositor-args '\--renderer=gl' \
  --compositor-args "\--width=$DISPLAY_SIZEW" \
  --compositor-args "\--height=$DISPLAY_SIZEH" \
  -- /usr/bin/start-desktop.sh
