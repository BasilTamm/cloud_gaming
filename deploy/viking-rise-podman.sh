#!/usr/bin/env bash
# Build and run the Viking Rise Steam-client container under Podman.
#
# Proof-of-concept: a virtual X display (Xvfb) hosts the Steam client, and
# x11vnc exposes that display so the operator can log into Steam manually
# over VNC. No Steam credentials are read, stored, or automated anywhere in
# this script or the image.
#
# Run from the repository root. Optional overrides live in
# deploy/viking-rise.env (see deploy/viking-rise.env.example); plain
# exported environment variables work the same way and take the same
# defaults. None of these values are secrets.
set -euo pipefail

ENV_FILE="${VIKING_RISE_ENV_FILE:-deploy/viking-rise.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

NETWORK="${VIKING_RISE_NETWORK:-yolostaff-net}"
CONTAINER="${VIKING_RISE_CONTAINER:-viking-rise-steam}"
IMAGE="${VIKING_RISE_IMAGE:-yolostaff-viking-rise:latest}"
BIND_ADDRESS="${VIKING_RISE_VNC_BIND:-127.0.0.1}"
VNC_PORT="${VIKING_RISE_VNC_PORT:-15900}"
DATA_VOLUME="${VIKING_RISE_DATA_VOLUME:-viking-rise-steam-data}"
# The entrypoint lets VIKING_RISE_STEAM_USER choose the account Steam runs
# as, and Steam's session state lives in that account's home. Derive the
# mount point from the same value so the volume can never land on a path
# nobody writes to, silently losing the login on every restart.
#
# Overriding the user only works if the image actually contains it; the
# stock Dockerfile.viking-rise creates 'steamuser' and nothing else.
STEAM_USER="${VIKING_RISE_STEAM_USER:-steamuser}"
STEAM_HOME="${VIKING_RISE_STEAM_HOME:-/home/${STEAM_USER}}"
RENDER_DEVICE="${VIKING_RISE_RENDER_DEVICE:-/dev/dri/renderD128}"
SCREEN_RES="${VIKING_RISE_SCREEN:-1280x800x24}"

if [[ ! -e "$RENDER_DEVICE" ]]; then
  echo "GPU render device not found: $RENDER_DEVICE" >&2
  echo "Expected the host's amdgpu render node to exist (see deploy/viking-rise-podman.md)." >&2
  exit 1
fi
if [[ ! -c "$RENDER_DEVICE" ]]; then
  echo "$RENDER_DEVICE exists but is not a character device." >&2
  exit 1
fi
if [[ ! -r "$RENDER_DEVICE" || ! -w "$RENDER_DEVICE" ]]; then
  echo "Current user cannot read/write $RENDER_DEVICE." >&2
  echo "Expected world-readable/writable permissions (crw-rw-rw-)." >&2
  exit 1
fi

podman network exists "$NETWORK" || podman network create "$NETWORK"
podman volume exists "$DATA_VOLUME" || podman volume create "$DATA_VOLUME"

podman build -f Dockerfile.viking-rise -t "$IMAGE" .

podman rm -f "$CONTAINER" 2>/dev/null || true

# VNC is published to the host loopback interface only, by design - never
# change BIND_ADDRESS to 0.0.0.0 without adding real VNC authentication
# first (x11vnc runs with -nopw here).
podman run -d \
  --name "$CONTAINER" \
  --network "$NETWORK" \
  --device "${RENDER_DEVICE}:${RENDER_DEVICE}" \
  --publish "${BIND_ADDRESS}:${VNC_PORT}:5900" \
  --volume "${DATA_VOLUME}:${STEAM_HOME}:Z" \
  --env "VIKING_RISE_SCREEN=${SCREEN_RES}" \
  --env "VIKING_RISE_RENDER_DEVICE=${RENDER_DEVICE}" \
  --env "VIKING_RISE_STEAM_USER=${STEAM_USER}" \
  --restart unless-stopped \
  "$IMAGE"

echo
echo "Started '$CONTAINER'."
echo "Connect a VNC client to ${BIND_ADDRESS}:${VNC_PORT} and log into Steam manually."
echo "Session data persists in volume '${DATA_VOLUME}' mounted at ${STEAM_HOME}."
echo "Logs: podman logs -f $CONTAINER"
