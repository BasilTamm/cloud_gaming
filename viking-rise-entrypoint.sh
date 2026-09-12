#!/usr/bin/env bash
# Entrypoint for the Viking Rise Steam-client container (MVP proof of concept).
#
# On every start: regenerates /etc/machine-id (containers cloned from the
# same image must not share one - see machine-id(5) / systemd-machine-id-setup(1)),
# starts a virtual X display (Xvfb), exposes it over x11vnc, then launches
# Steam under an unprivileged user so the operator can log in by hand.
#
# RED LINE: this script never touches Steam credentials, tokens, or 2FA in
# any way. There is no automated login here, by design - the operator logs
# into Steam manually through the VNC session after the container starts.
set -euo pipefail

STEAM_USER="${VIKING_RISE_STEAM_USER:-steamuser}"
DISPLAY_NUM="${VIKING_RISE_DISPLAY:-:1}"
SCREEN_RES="${VIKING_RISE_SCREEN:-1280x800x24}"
VNC_PORT="${VIKING_RISE_VNC_INTERNAL_PORT:-5900}"
RENDER_DEVICE="${VIKING_RISE_RENDER_DEVICE:-/dev/dri/renderD128}"
# Debian/Ubuntu ship the Steam launcher in /usr/games (see the steam
# package's debian/steam.install), which is NOT on the default container
# PATH. It must be invoked by absolute path.
STEAM_BIN="${VIKING_RISE_STEAM_BIN:-/usr/games/steam}"

# Resolved in two steps on purpose: under `set -e` with pipefail, a failing
# `getent` inside a command substitution would abort the script before the
# diagnostic below could run.
if ! passwd_entry="$(getent passwd "$STEAM_USER")"; then
  echo "No such user inside the container: '$STEAM_USER'." >&2
  exit 1
fi
STEAM_HOME="$(cut -d: -f6 <<<"$passwd_entry")"

if [[ -z "$STEAM_HOME" ]]; then
  echo "Cannot resolve home directory for user '$STEAM_USER'." >&2
  exit 1
fi

if [[ ! -x "$STEAM_BIN" ]]; then
  echo "Steam launcher not found or not executable: $STEAM_BIN" >&2
  echo "The image is expected to install it via the 'steam-installer' package." >&2
  exit 1
fi

if [[ ! -c "$RENDER_DEVICE" ]]; then
  echo "Warning: $RENDER_DEVICE not present inside the container." >&2
  echo "Rendering will fall back to software (llvmpipe) and be very slow." >&2
  echo "Check that the container was started with --device $RENDER_DEVICE:$RENDER_DEVICE." >&2
fi

# Machine-id must be unique per container instance, not baked into the
# image and reused by every container started from it.
rm -f /etc/machine-id /var/lib/dbus/machine-id
mkdir -p /var/lib/dbus
dbus-uuidgen --ensure=/etc/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# Give the unprivileged user ownership of its persisted home volume. Only
# pay for the recursive chown once - a volume that already belongs to
# $STEAM_USER (every start after the first) skips straight through.
if [[ "$(stat -c '%U' "$STEAM_HOME")" != "$STEAM_USER" ]]; then
  chown -R "${STEAM_USER}:${STEAM_USER}" "$STEAM_HOME"
fi

Xvfb "$DISPLAY_NUM" -screen 0 "$SCREEN_RES" &
XVFB_PID=$!

X_SOCKET="/tmp/.X11-unix/X${DISPLAY_NUM#:}"
for _ in $(seq 1 50); do
  [[ -e "$X_SOCKET" ]] && break
  sleep 0.2
done
if [[ ! -e "$X_SOCKET" ]]; then
  echo "Xvfb did not start on display $DISPLAY_NUM in time." >&2
  kill "$XVFB_PID" 2>/dev/null || true
  exit 1
fi

x11vnc -display "$DISPLAY_NUM" -forever -shared -rfbport "$VNC_PORT" -nopw -quiet &
X11VNC_PID=$!

# VNC is the only way in: manual Steam login happens there by design. A
# silently dead x11vnc would leave an unreachable container running Steam,
# so treat it as a fatal startup error instead.
sleep 1
if ! kill -0 "$X11VNC_PID" 2>/dev/null; then
  echo "x11vnc failed to stay up on port $VNC_PORT (display $DISPLAY_NUM)." >&2
  kill "$XVFB_PID" 2>/dev/null || true
  exit 1
fi

# Steam refuses to run as root anyway; runuser also keeps GPU-device access
# scoped to the unprivileged app user instead of root.
#
# runuser (without -l) hands the caller's environment to the target user, so
# PATH is set explicitly here: /usr/games holds the Steam launcher and is
# absent from the default container PATH.
exec runuser -u "$STEAM_USER" -- env \
  DISPLAY="$DISPLAY_NUM" \
  HOME="$STEAM_HOME" \
  PATH="/usr/games:/usr/local/bin:/usr/bin:/bin" \
  "$STEAM_BIN"
