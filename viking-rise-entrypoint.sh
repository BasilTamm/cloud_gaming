#!/usr/bin/env bash
# Entrypoint for the Viking Rise Steam-client container (MVP proof of concept).
#
# On first start: initializes /etc/machine-id (containers cloned from the
# same image must not share one - see machine-id(5) / systemd-machine-id-setup(1)),
# starts a virtual X display (Xvfb), exposes it over x11vnc, then launches
# Steam under an unprivileged user so the operator can log in by hand.
#
# RED LINE: this script never touches Steam credentials, tokens, or 2FA in
# any way. There is no automated login here, by design - the operator logs
# into Steam manually through the VNC session after the container starts.
set -euo pipefail

STEAM_USER="steamuser"
STEAM_HOME="/home/steamuser"
DISPLAY_NUM="${VIKING_RISE_DISPLAY:-:1}"
SCREEN_RES="${VIKING_RISE_SCREEN:-1280x800x24}"
VNC_PORT="${VIKING_RISE_VNC_INTERNAL_PORT:-5900}"
RENDER_DEVICE="${VIKING_RISE_RENDER_DEVICE:-/dev/dri/renderD128}"
# Path *inside the container* to an x11vnc password file.
VNC_AUTH="${VIKING_RISE_VNC_AUTH:-password}"
VNC_PASSWD_FILE="${VIKING_RISE_VNC_PASSWD_FILE:-}"
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
passwd_home="$(cut -d: -f6 <<<"$passwd_entry")"
if [[ "$passwd_home" != "$STEAM_HOME" ]]; then
  echo "Unexpected home for '$STEAM_USER': '$passwd_home' (expected '$STEAM_HOME')." >&2
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
elif ! runuser -u "$STEAM_USER" -- test -r "$RENDER_DEVICE" -a -w "$RENDER_DEVICE"; then
  # Root can reach the device even when the unprivileged user cannot, and
  # Steam runs as that user - so check access from its point of view.
  # Otherwise the only symptom is an unexplained llvmpipe-slow game.
  echo "Warning: $RENDER_DEVICE is not readable/writable by '$STEAM_USER'." >&2
  echo "Steam drops to this user, so rendering will fall back to software (llvmpipe)." >&2
  echo "On the host the render node is expected to be world-readable/writable (crw-rw-rw-)." >&2
fi

# Machine-id must be unique per container instance, not baked into the
# image and reused by every container started from it. Keep it stable when
# the same container is restarted; a recreated container gets a new ID.
mkdir -p /var/lib/dbus
if [[ ! -s /etc/machine-id ]]; then
  rm -f /etc/machine-id
  dbus-uuidgen --ensure=/etc/machine-id
fi
ln -sfn /etc/machine-id /var/lib/dbus/machine-id

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

# Authentication mode is explicit. Password mode fails closed if the bind
# mount is absent or unreadable; unauthenticated mode must be requested by
# the deploy script and is restricted to a host-loopback publish there.
case "$VNC_AUTH" in
password)
  if [[ ! -f "$VNC_PASSWD_FILE" || ! -r "$VNC_PASSWD_FILE" ]]; then
    echo "VNC password file configured but not readable: $VNC_PASSWD_FILE" >&2
    echo "Refusing to start an unauthenticated VNC session instead." >&2
    kill "$XVFB_PID" 2>/dev/null || true
    exit 1
  fi
  vnc_auth=(-rfbauth "$VNC_PASSWD_FILE")
  ;;
none)
  echo "Warning: VNC has no password (-nopw)." >&2
  echo "Access control is the loopback publish plus this container's own network." >&2
  echo "Any local process on the host can take over the Steam session." >&2
  echo "See 'VNC authentication' in deploy/viking-rise-podman.md." >&2
  vnc_auth=(-nopw)
  ;;
*)
  echo "Invalid VIKING_RISE_VNC_AUTH: $VNC_AUTH (expected password or none)." >&2
  kill "$XVFB_PID" 2>/dev/null || true
  exit 1
  ;;
esac

x11vnc -display "$DISPLAY_NUM" -forever -shared -rfbport "$VNC_PORT" \
  "${vnc_auth[@]}" -quiet &
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
