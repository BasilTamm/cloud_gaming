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

# This container must not share a network with anything else. The script
# verifies that an existing network is a bridge with no attached container
# other than the one it is about to replace.
NETWORK="${VIKING_RISE_NETWORK:-viking-rise-net}"
CONTAINER="${VIKING_RISE_CONTAINER:-viking-rise-steam}"
IMAGE="${VIKING_RISE_IMAGE:-viking-rise-steam:latest}"
BIND_ADDRESS="${VIKING_RISE_VNC_BIND:-127.0.0.1}"
VNC_PORT="${VIKING_RISE_VNC_PORT:-15900}"
DATA_VOLUME="${VIKING_RISE_DATA_VOLUME:-viking-rise-steam-data}"
# Dockerfile.viking-rise creates exactly this account and home directory.
# Keeping these values fixed prevents the persistent volume from being
# mounted somewhere other than the HOME Steam actually uses.
STEAM_HOME="/home/steamuser"
RENDER_DEVICE="${VIKING_RISE_RENDER_DEVICE:-/dev/dri/renderD128}"
SCREEN_RES="${VIKING_RISE_SCREEN:-1280x800x24}"
# VNC authentication is required by default. Explicit auth=none remains
# available for loopback-only local testing, but can never be combined with
# a non-loopback publish.
VNC_AUTH="${VIKING_RISE_VNC_AUTH:-password}"
# x11vnc password file on the host. Create it with:
#   x11vnc -storepasswd <password> deploy/viking-rise-vnc.passwd
# It is gitignored. This is a VNC password only - never a Steam credential.
VNC_PASSWD_FILE="${VIKING_RISE_VNC_PASSWD_FILE:-deploy/viking-rise-vnc.passwd}"
VNC_PASSWD_IN_CONTAINER="/run/viking-rise/vnc.passwd"

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

vnc_auth_args=(--env "VIKING_RISE_VNC_AUTH=${VNC_AUTH}")
case "$VNC_AUTH" in
password)
  if [[ ! -f "$VNC_PASSWD_FILE" || ! -r "$VNC_PASSWD_FILE" ]]; then
    echo "VNC authentication is enabled, but the password file is not a readable regular file:" >&2
    echo "  $VNC_PASSWD_FILE" >&2
    echo "Create it with x11vnc -storepasswd and chmod it to mode 600." >&2
    exit 1
  fi
  if ! permissions="$(stat -c '%a' "$VNC_PASSWD_FILE" 2>/dev/null)"; then
    echo "Cannot determine permissions for $VNC_PASSWD_FILE." >&2
    exit 1
  fi
  if [[ "$permissions" != "600" ]]; then
    echo "Refusing to start: $VNC_PASSWD_FILE is a password file but is mode $permissions." >&2
    echo "Run: chmod 600 $VNC_PASSWD_FILE" >&2
    exit 1
  fi
  vnc_auth_args=(
    --env "VIKING_RISE_VNC_AUTH=password"
    --volume "$(realpath "$VNC_PASSWD_FILE"):${VNC_PASSWD_IN_CONTAINER}:ro,Z"
    --env "VIKING_RISE_VNC_PASSWD_FILE=${VNC_PASSWD_IN_CONTAINER}"
  )
  ;;
none)
  if [[ "$BIND_ADDRESS" != "127.0.0.1" ]]; then
    echo "Refusing unauthenticated VNC on non-loopback bind: $BIND_ADDRESS" >&2
    echo "Use VIKING_RISE_VNC_AUTH=password or bind to 127.0.0.1." >&2
    exit 1
  fi
  echo "Warning: VNC authentication is explicitly disabled." >&2
  echo "Only the loopback publish and dedicated network restrict access." >&2
  ;;
*)
  echo "Invalid VIKING_RISE_VNC_AUTH: $VNC_AUTH (expected password or none)." >&2
  exit 1
  ;;
esac

if podman network exists "$NETWORK"; then
  if ! network_driver="$(podman network inspect --format '{{.Driver}}' "$NETWORK")"; then
    echo "Cannot inspect Podman network: $NETWORK" >&2
    exit 1
  fi
  if [[ "$network_driver" != "bridge" ]]; then
    echo "Refusing network '$NETWORK': expected bridge driver, got '$network_driver'." >&2
    exit 1
  fi
  if ! attached_containers="$(podman ps -a --filter "network=$NETWORK" --format '{{.Names}}')"; then
    echo "Cannot inspect containers attached to Podman network: $NETWORK" >&2
    exit 1
  fi
  while IFS= read -r attached_container; do
    [[ -z "$attached_container" || "$attached_container" == "$CONTAINER" ]] && continue
    echo "Refusing shared network '$NETWORK': container '$attached_container' is attached." >&2
    echo "Choose an empty dedicated network for Viking Rise." >&2
    exit 1
  done <<<"$attached_containers"
else
  podman network create --label io.viking-rise.network=dedicated "$NETWORK"
fi
podman volume exists "$DATA_VOLUME" || podman volume create "$DATA_VOLUME"

podman build -f Dockerfile.viking-rise -t "$IMAGE" .

podman rm -f "$CONTAINER" 2>/dev/null || true

# VNC is published to host loopback by default, uses password authentication
# by default, and always gets a dedicated network. Password mode is still an
# unencrypted VNC transport, so widening the bind requires a trusted path.
podman run -d \
  --name "$CONTAINER" \
  --network "$NETWORK" \
  --device "${RENDER_DEVICE}:${RENDER_DEVICE}" \
  --publish "${BIND_ADDRESS}:${VNC_PORT}:5900" \
  --volume "${DATA_VOLUME}:${STEAM_HOME}:Z" \
  --env "VIKING_RISE_SCREEN=${SCREEN_RES}" \
  --env "VIKING_RISE_RENDER_DEVICE=${RENDER_DEVICE}" \
  "${vnc_auth_args[@]}" \
  --restart unless-stopped \
  "$IMAGE"

echo
echo "Started '$CONTAINER'."
echo "Connect a VNC client to ${BIND_ADDRESS}:${VNC_PORT} and log into Steam manually."
echo "Session data persists in volume '${DATA_VOLUME}' mounted at ${STEAM_HOME}."
echo "Logs: podman logs -f $CONTAINER"
