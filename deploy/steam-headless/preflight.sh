#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${STEAM_HEADLESS_ENV_FILE:-${SCRIPT_DIR}/.env}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$(uname -m)" == "x86_64" ]] || die "Steam Headless image is amd64-only; host is $(uname -m)."
command -v podman >/dev/null 2>&1 || die "podman is not installed or not on PATH."
[[ -f "$ENV_FILE" ]] || die "Missing $ENV_FILE; copy .env.example and fill it in."
permissions="$(stat -c '%a' "$ENV_FILE")"
[[ "$permissions" == "600" ]] || die "$ENV_FILE must have mode 600, not $permissions."

# Parse KEY=VALUE lines as data instead of sourcing shell code on the host.
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  [[ "$line" == *=* ]] || die "Invalid line in $ENV_FILE: expected KEY=VALUE."
  key="${line%%=*}"
  value="${line#*=}"
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Invalid variable name in $ENV_FILE: $key"
  declare -gx "$key=$value"
done < "$ENV_FILE"

: "${INSTANCE_1_OS_PASSWORD:?set INSTANCE_1_OS_PASSWORD in $ENV_FILE}"
: "${INSTANCE_2_OS_PASSWORD:?set INSTANCE_2_OS_PASSWORD in $ENV_FILE}"

[[ "${PUID:-}" == "$(id -u)" ]] || die "PUID must equal the invoking user ID: $(id -u)."
[[ "${PGID:-}" == "$(id -g)" ]] || die "PGID must equal the invoking primary group ID: $(id -g)."

[[ "$INSTANCE_1_OS_PASSWORD" != "$INSTANCE_2_OS_PASSWORD" ]] || \
  die "Use different local OS passwords for the two containers."

render_device="${RENDER_DEVICE:-/dev/dri/renderD128}"
[[ -c "$render_device" ]] || die "$render_device is not a character device."
[[ -r "$render_device" && -w "$render_device" ]] || \
  die "Current user cannot read/write $render_device."

rootless="$(podman info --format '{{.Host.Security.Rootless}}')"
[[ "$rootless" == "true" ]] || die "Run this spike with rootless Podman, not sudo/rootful Podman."

podman compose version >/dev/null 2>&1 || \
  die "No Compose provider is available through 'podman compose'."

port_1="${STEAM_1_WEB_PORT:-15901}"
port_2="${STEAM_2_WEB_PORT:-15902}"
[[ "$port_1" =~ ^[0-9]+$ && "$port_1" -ge 1024 && "$port_1" -le 65535 ]] || \
  die "Invalid STEAM_1_WEB_PORT: $port_1"
[[ "$port_2" =~ ^[0-9]+$ && "$port_2" -ge 1024 && "$port_2" -le 65535 ]] || \
  die "Invalid STEAM_2_WEB_PORT: $port_2"
[[ "$port_1" != "$port_2" ]] || die "The two browser ports must differ."

for port in "$port_1" "$port_2"; do
  if command -v ss >/dev/null 2>&1 && ss -H -ltn "sport = :$port" | grep -q .; then
    die "TCP port $port is already listening on the host."
  fi
done

if ! (cd "$SCRIPT_DIR" && podman compose -f compose.yaml config >/dev/null); then
  die "The installed Podman Compose provider cannot render compose.yaml."
fi

echo "Preflight passed. This proves host prerequisites only; it does not prove the image runs."
