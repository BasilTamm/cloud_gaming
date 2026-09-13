#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-}"
shift || true

ENV_FILE="${SCRIPT_DIR}/.env"
if [[ "${1:-}" == "--env-file" ]]; then
  [[ $# -ge 2 ]] || { echo "ERROR: --env-file requires a path." >&2; exit 1; }
  ENV_FILE="$2"
  shift 2
fi
[[ $# -eq 0 ]] || { echo "ERROR: unexpected arguments: $*" >&2; exit 1; }

die() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./steam-headless.sh ACTION [--env-file PATH]

Actions:
  check     Validate the exact configuration without pulling or starting.
  build     Build the pinned derivative image containing Xvfb.
  up-one    Build/start only steam-1 and wait for container health.
  up-two    Build/start steam-2 after steam-1 has been accepted physically.
  down      Stop containers while preserving named volumes.
EOF
}

case "$ACTION" in
  check|build|up-one|up-two|down) ;;
  -h|--help|"") usage; exit 0 ;;
  *) usage >&2; die "unknown action: $ACTION" ;;
esac

[[ "$(uname -m)" == "x86_64" ]] || die "Steam Headless image is amd64-only; host is $(uname -m)."
command -v podman >/dev/null 2>&1 || die "podman is not installed or not on PATH."
[[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || die "$ENV_FILE must be a regular file, not a symlink."
owner_uid="$(stat -c '%u' "$ENV_FILE")"
permissions="$(stat -c '%a' "$ENV_FILE")"
[[ "$owner_uid" == "$(id -u)" ]] || die "$ENV_FILE must be owned by UID $(id -u), not $owner_uid."
[[ "$permissions" == "600" ]] || die "$ENV_FILE must have mode 600, not $permissions."

declare -A allowed=(
  [TZ]=1 [PUID]=1 [PGID]=1 [RENDER_DEVICE]=1 [SHM_SIZE]=1 [PIDS_LIMIT]=1
  [STEAM_1_WEB_PORT]=1 [INSTANCE_1_OS_PASSWORD]=1 [STEAM_1_CPUS]=1 [STEAM_1_MEM_LIMIT]=1
  [STEAM_2_WEB_PORT]=1 [INSTANCE_2_OS_PASSWORD]=1 [STEAM_2_CPUS]=1 [STEAM_2_MEM_LIMIT]=1
)
declare -A values=(
  [TZ]="Etc/UTC" [PUID]="$(id -u)" [PGID]="$(id -g)"
  [RENDER_DEVICE]="/dev/dri/renderD128" [SHM_SIZE]="1g" [PIDS_LIMIT]="2048"
  [STEAM_1_WEB_PORT]="15901" [INSTANCE_1_OS_PASSWORD]="" [STEAM_1_CPUS]="3.0" [STEAM_1_MEM_LIMIT]="5g"
  [STEAM_2_WEB_PORT]="15902" [INSTANCE_2_OS_PASSWORD]="" [STEAM_2_CPUS]="3.0" [STEAM_2_MEM_LIMIT]="5g"
)
declare -A seen=()

# Parse a deliberately small KEY=VALUE format. Values are exported explicitly,
# so inherited shell variables cannot override what is validated and launched.
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  [[ -z "$line" || "$line" == \#* ]] && continue
  [[ "$line" == *=* ]] || die "Invalid line in $ENV_FILE: expected KEY=VALUE."
  key="${line%%=*}"
  value="${line#*=}"
  [[ -n "${allowed[$key]:-}" ]] || die "Unsupported variable in $ENV_FILE: $key"
  [[ -z "${seen[$key]:-}" ]] || die "Duplicate variable in $ENV_FILE: $key"
  seen[$key]=1
  values[$key]="$value"
done < "$ENV_FILE"

for key in "${!values[@]}"; do
  declare -gx "$key=${values[$key]}"
done

: "${INSTANCE_1_OS_PASSWORD:?set INSTANCE_1_OS_PASSWORD in $ENV_FILE}"
: "${INSTANCE_2_OS_PASSWORD:?set INSTANCE_2_OS_PASSWORD in $ENV_FILE}"
[[ "$INSTANCE_1_OS_PASSWORD" =~ ^[[:xdigit:]]{16,}$ ]] || \
  die "INSTANCE_1_OS_PASSWORD must be at least 16 hexadecimal characters."
[[ "$INSTANCE_2_OS_PASSWORD" =~ ^[[:xdigit:]]{16,}$ ]] || \
  die "INSTANCE_2_OS_PASSWORD must be at least 16 hexadecimal characters."
[[ "$INSTANCE_1_OS_PASSWORD" != "$INSTANCE_2_OS_PASSWORD" ]] || die "Use different local passwords."
[[ "${INSTANCE_1_OS_PASSWORD:0:8}" != "${INSTANCE_2_OS_PASSWORD:0:8}" ]] || \
  die "The first eight password characters must differ because VNC truncates there."

[[ "$PUID" == "$(id -u)" ]] || die "PUID must equal the invoking user ID: $(id -u)."
[[ "$PGID" == "$(id -g)" ]] || die "PGID must equal the invoking primary group ID: $(id -g)."

canonical_device="$(readlink -f -- "$RENDER_DEVICE")" || die "Cannot resolve $RENDER_DEVICE."
[[ "$canonical_device" == "$RENDER_DEVICE" ]] || die "RENDER_DEVICE must be a canonical path, not a symlink."
[[ "$RENDER_DEVICE" =~ ^/dev/dri/renderD[0-9]+$ ]] || \
  die "RENDER_DEVICE must be /dev/dri/renderD<number>, not $RENDER_DEVICE."
[[ -c "$RENDER_DEVICE" ]] || die "$RENDER_DEVICE is not a character device."
device_hex="$(stat -c '%t:%T' "$RENDER_DEVICE")"
major_hex="${device_hex%%:*}"
minor_hex="${device_hex##*:}"
(( 16#$major_hex == 226 && 16#$minor_hex >= 128 )) || die "$RENDER_DEVICE is not a DRM render node."
[[ -d "/sys/class/drm/$(basename -- "$RENDER_DEVICE")/device" ]] || die "$RENDER_DEVICE has no DRM sysfs device."
[[ -r "$RENDER_DEVICE" && -w "$RENDER_DEVICE" ]] || die "Current user cannot read/write $RENDER_DEVICE."

for remote_var in CONTAINER_HOST CONTAINER_CONNECTION DOCKER_HOST; do
  [[ -z "${!remote_var:-}" ]] || die "$remote_var must be unset; this spike targets the local Podman service."
done

rootless="$(podman info --format '{{.Host.Security.Rootless}}')"
[[ "$rootless" == "true" ]] || die "Run with rootless Podman, not sudo/rootful Podman."
oci_runtime="$(podman info --format '{{.Host.OCIRuntime.Name}}')"
[[ "$oci_runtime" == "crun" ]] || die "group_add: keep-groups requires crun; selected runtime is $oci_runtime."
cgroups_version="$(podman info --format '{{.Host.CgroupsVersion}}')"
[[ "$cgroups_version" == "v2" ]] || die "Resource-limit checks require cgroup v2; found $cgroups_version."

compose_version="$(podman compose version 2>&1)" || die "No Compose provider is available through podman compose."

for port_name in STEAM_1_WEB_PORT STEAM_2_WEB_PORT; do
  port="${!port_name}"
  [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1024 && "$port" -le 65535 ]] || die "Invalid $port_name: $port"
done
[[ "$STEAM_1_WEB_PORT" != "$STEAM_2_WEB_PORT" ]] || die "The browser ports must differ."

compose() {
  (cd "$SCRIPT_DIR" && env -u BASH_ENV -u ENV podman compose -f compose.yaml "$@")
}

check_port() {
  local port="$1" container="$2" published=""
  command -v ss >/dev/null 2>&1 || return 0
  ss -H -ltn "sport = :$port" | grep -q . || return 0

  published="$(podman port "$container" 8083/tcp 2>/dev/null || true)"
  grep -Fxq "127.0.0.1:$port" <<<"$published" || \
    die "TCP port $port is already listening and is not owned by $container."
}

resolved_config="$(mktemp)"
trap 'rm -f -- "$resolved_config"' EXIT
compose config >"$resolved_config" || die "The Compose provider cannot render compose.yaml."

wait_healthy() {
  local container="$1" status=""
  for _ in {1..60}; do
    status="$(podman inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$container" 2>/dev/null || true)"
    case "$status" in
      healthy) echo "$container is healthy."; return 0 ;;
      unhealthy) die "$container is unhealthy; inspect logs before changing privileges." ;;
    esac
    sleep 2
  done
  die "$container did not become healthy (last status: ${status:-unknown})."
}

echo "Validated provider: $compose_version"
echo "Validated rootless runtime: $oci_runtime, cgroup $cgroups_version"

case "$ACTION" in
  check)
    check_port "$STEAM_1_WEB_PORT" viking-rise-steam-1
    check_port "$STEAM_2_WEB_PORT" viking-rise-steam-2
    echo "Preflight passed; no image was pulled, built, or started."
    ;;
  build) compose build ;;
  up-one)
    check_port "$STEAM_1_WEB_PORT" viking-rise-steam-1
    compose up -d --build steam-1
    wait_healthy viking-rise-steam-1
    ;;
  up-two)
    [[ "$(podman inspect --format '{{.State.Health.Status}}' viking-rise-steam-1 2>/dev/null || true)" == "healthy" ]] || \
      die "steam-1 must be running and healthy before starting steam-2."
    check_port "$STEAM_2_WEB_PORT" viking-rise-steam-2
    compose up -d --build steam-2
    wait_healthy viking-rise-steam-2
    ;;
  down) compose down ;;
esac
