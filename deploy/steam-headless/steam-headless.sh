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

readonly IMAGE="localhost/viking-rise-steam-headless:xwayland"
readonly PROJECT_LABEL="io.openclaw.viking-rise.project"
readonly PROJECT_VALUE="steam-headless"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./steam-headless.sh ACTION [--env-file PATH]

Actions:
  check     Validate the host and exact instance configuration.
  build     Build the pinned derivative image containing Weston + Xwayland.
  up-one    Recreate steam-1 and wait for container health.
  up-two    Recreate steam-2 after steam-1 has been accepted physically.
  down      Remove both managed containers and networks; preserve volumes.
EOF
}

case "$ACTION" in
  check|build|up-one|up-two|down) ;;
  -h|--help|"") usage; exit 0 ;;
  *) usage >&2; die "unknown action: $ACTION" ;;
esac

[[ "$(uname -m)" == "x86_64" ]] || die "Steam Headless image is amd64-only; host is $(uname -m)."
command -v podman >/dev/null 2>&1 || die "podman is not installed or not on PATH."

for remote_var in CONTAINER_HOST CONTAINER_CONNECTION DOCKER_HOST; do
  [[ -z "${!remote_var:-}" ]] || die "$remote_var must be unset; this spike targets local Podman."
done

rootless="$(podman info --format '{{.Host.Security.Rootless}}')"
[[ "$rootless" == "true" ]] || die "Run with rootless Podman, not sudo/rootful Podman."
service_is_remote="$(podman info --format '{{.Host.ServiceIsRemote}}')"
[[ "$service_is_remote" == "false" ]] || die "A local Podman service is required; ServiceIsRemote=$service_is_remote."

container_label() {
  podman inspect --format "{{index .Config.Labels \"$PROJECT_LABEL\"}}" "$1" 2>/dev/null || true
}

network_label() {
  podman network inspect --format "{{index .Labels \"$PROJECT_LABEL\"}}" "$1" 2>/dev/null || true
}

volume_label() {
  podman volume inspect --format "{{index .Labels \"$PROJECT_LABEL\"}}" "$1" 2>/dev/null || true
}

remove_managed_container() {
  local container="$1"
  podman container exists "$container" || return 0
  [[ "$(container_label "$container")" == "$PROJECT_VALUE" ]] || \
    die "Refusing to remove unmanaged container named $container."
  podman rm -f -t 30 "$container"
}

remove_managed_network() {
  local network="$1"
  podman network exists "$network" || return 0
  [[ "$(network_label "$network")" == "$PROJECT_VALUE" ]] || \
    die "Refusing to remove unmanaged network named $network."
  podman network rm "$network"
}

if [[ "$ACTION" == "down" ]]; then
  remove_managed_container viking-rise-steam-2
  remove_managed_container viking-rise-steam-1
  remove_managed_network viking-rise-steam-2-net
  remove_managed_network viking-rise-steam-1-net
  echo "Managed containers and networks removed; named volumes preserved."
  exit 0
fi

if [[ "$ACTION" == "build" ]]; then
  podman build --pull=missing -t "$IMAGE" -f "${SCRIPT_DIR}/Containerfile" "$SCRIPT_DIR"
  exit 0
fi

oci_runtime="$(podman info --format '{{.Host.OCIRuntime.Name}}')"
[[ "$oci_runtime" == "crun" ]] || die "--group-add keep-groups requires crun; selected runtime is $oci_runtime."
cgroups_version="$(podman info --format '{{.Host.CgroupsVersion}}')"
[[ "$cgroups_version" == "v2" ]] || die "Resource limits require cgroup v2; found $cgroups_version."

[[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || die "$ENV_FILE must be a regular file, not a symlink."
owner_uid="$(stat -c '%u' "$ENV_FILE")"
permissions="$(stat -c '%a' "$ENV_FILE")"
[[ "$owner_uid" == "$(id -u)" ]] || die "$ENV_FILE must be owned by UID $(id -u), not $owner_uid."
[[ "$permissions" == "600" ]] || die "$ENV_FILE must have mode 600, not $permissions."

declare -A allowed=(
  [TZ]=1 [PUID]=1 [PGID]=1 [RENDER_DEVICE]=1 [DNS_SERVER]=1 [DISPLAY_WIDTH]=1 [DISPLAY_HEIGHT]=1
  [SHM_SIZE]=1 [PIDS_LIMIT]=1
  [STEAM_1_WEB_PORT]=1 [INSTANCE_1_OS_PASSWORD]=1 [STEAM_1_CPUS]=1 [STEAM_1_MEM_LIMIT]=1
  [STEAM_2_WEB_PORT]=1 [INSTANCE_2_OS_PASSWORD]=1 [STEAM_2_CPUS]=1 [STEAM_2_MEM_LIMIT]=1
)
declare -A values=(
  [TZ]="Etc/UTC" [PUID]="$(id -u)" [PGID]="$(id -g)"
  [RENDER_DEVICE]="/dev/dri/renderD128" [DNS_SERVER]="1.1.1.1" [DISPLAY_WIDTH]="1600" [DISPLAY_HEIGHT]="900"
  [SHM_SIZE]="1g" [PIDS_LIMIT]="2048"
  [STEAM_1_WEB_PORT]="15901" [INSTANCE_1_OS_PASSWORD]="" [STEAM_1_CPUS]="3.0" [STEAM_1_MEM_LIMIT]="5g"
  [STEAM_2_WEB_PORT]="15902" [INSTANCE_2_OS_PASSWORD]="" [STEAM_2_CPUS]="3.0" [STEAM_2_MEM_LIMIT]="5g"
)
declare -A seen=()

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

TZ_VALUE="${values[TZ]}"
PUID_VALUE="${values[PUID]}"
PGID_VALUE="${values[PGID]}"
RENDER_DEVICE_VALUE="${values[RENDER_DEVICE]}"
DNS_SERVER_VALUE="${values[DNS_SERVER]}"
DISPLAY_WIDTH_VALUE="${values[DISPLAY_WIDTH]}"
DISPLAY_HEIGHT_VALUE="${values[DISPLAY_HEIGHT]}"
SHM_SIZE_VALUE="${values[SHM_SIZE]}"
PIDS_LIMIT_VALUE="${values[PIDS_LIMIT]}"
STEAM_1_WEB_PORT_VALUE="${values[STEAM_1_WEB_PORT]}"
INSTANCE_1_OS_PASSWORD_VALUE="${values[INSTANCE_1_OS_PASSWORD]}"
STEAM_1_CPUS_VALUE="${values[STEAM_1_CPUS]}"
STEAM_1_MEM_LIMIT_VALUE="${values[STEAM_1_MEM_LIMIT]}"
STEAM_2_WEB_PORT_VALUE="${values[STEAM_2_WEB_PORT]}"
INSTANCE_2_OS_PASSWORD_VALUE="${values[INSTANCE_2_OS_PASSWORD]}"
STEAM_2_CPUS_VALUE="${values[STEAM_2_CPUS]}"
STEAM_2_MEM_LIMIT_VALUE="${values[STEAM_2_MEM_LIMIT]}"

[[ "$TZ_VALUE" =~ ^[A-Za-z0-9_+./-]+$ && "$TZ_VALUE" != *..* ]] || die "Invalid TZ: $TZ_VALUE"
[[ "$PUID_VALUE" == "$(id -u)" ]] || die "PUID must equal invoking UID $(id -u)."
[[ "$PGID_VALUE" == "$(id -g)" ]] || die "PGID must equal invoking primary GID $(id -g)."

validate_ipv4() {
  local name="$1" value="$2" octet
  local -a octets
  IFS=. read -r -a octets <<<"$value"
  [[ "${#octets[@]}" -eq 4 ]] || die "Invalid $name IPv4 address: $value"
  for octet in "${octets[@]}"; do
    if [[ ! "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] || (( 10#$octet > 255 )); then
      die "Invalid $name IPv4 address: $value"
    fi
  done
}
validate_ipv4 DNS_SERVER "$DNS_SERVER_VALUE"

validate_dimension() {
  local name="$1" value="$2" minimum="$3" maximum="$4"
  if [[ ! "$value" =~ ^(0|[1-9][0-9]*)$ ]] || \
      (( 10#$value < minimum || 10#$value > maximum )); then
    die "$name must be an integer between $minimum and $maximum."
  fi
}
validate_dimension DISPLAY_WIDTH "$DISPLAY_WIDTH_VALUE" 640 3840
validate_dimension DISPLAY_HEIGHT "$DISPLAY_HEIGHT_VALUE" 480 2160

validate_password() {
  local name="$1" password="$2"
  [[ "$password" =~ ^[[:xdigit:]]{16,}$ ]] || die "$name must be at least 16 hexadecimal characters."
}
validate_password INSTANCE_1_OS_PASSWORD "$INSTANCE_1_OS_PASSWORD_VALUE"
validate_password INSTANCE_2_OS_PASSWORD "$INSTANCE_2_OS_PASSWORD_VALUE"
[[ "${INSTANCE_1_OS_PASSWORD_VALUE:0:8}" != "${INSTANCE_2_OS_PASSWORD_VALUE:0:8}" ]] || \
  die "The first eight password characters must differ because VNC truncates there."

parse_size_mib() {
  local value="$1" number unit
  [[ "$value" =~ ^([0-9]+)([mMgG])$ ]] || die "Invalid size: $value (use an integer plus m or g)."
  number="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2],,}"
  if [[ "$unit" == "g" ]]; then echo $((number * 1024)); else echo "$number"; fi
}

validate_cpu() {
  local name="$1" value="$2"
  [[ "$value" =~ ^([0-9]+)(\.[0-9]+)?$ ]] || die "Invalid $name: $value"
  awk -v value="$value" 'BEGIN { exit !(value >= 0.25 && value <= 8.0) }' || \
    die "$name must be between 0.25 and 8.0."
}

validate_port() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[0-9]+$ && "$value" -ge 1024 && "$value" -le 65535 ]] || die "Invalid $name: $value"
}

validate_port STEAM_1_WEB_PORT "$STEAM_1_WEB_PORT_VALUE"
validate_port STEAM_2_WEB_PORT "$STEAM_2_WEB_PORT_VALUE"
[[ "$STEAM_1_WEB_PORT_VALUE" != "$STEAM_2_WEB_PORT_VALUE" ]] || die "Browser ports must differ."
validate_cpu STEAM_1_CPUS "$STEAM_1_CPUS_VALUE"
validate_cpu STEAM_2_CPUS "$STEAM_2_CPUS_VALUE"
[[ "$PIDS_LIMIT_VALUE" =~ ^[0-9]+$ && "$PIDS_LIMIT_VALUE" -ge 256 && "$PIDS_LIMIT_VALUE" -le 8192 ]] || \
  die "PIDS_LIMIT must be between 256 and 8192."
shm_mib="$(parse_size_mib "$SHM_SIZE_VALUE")"
[[ "$shm_mib" -ge 64 && "$shm_mib" -le 4096 ]] || die "SHM_SIZE must be between 64m and 4g."
for memory in "$STEAM_1_MEM_LIMIT_VALUE" "$STEAM_2_MEM_LIMIT_VALUE"; do
  memory_mib="$(parse_size_mib "$memory")"
  [[ "$memory_mib" -ge 1024 && "$memory_mib" -le 12288 ]] || die "Memory limits must be between 1g and 12g."
  [[ "$shm_mib" -le "$memory_mib" ]] || die "SHM_SIZE cannot exceed a container memory limit."
done

canonical_device="$(readlink -f -- "$RENDER_DEVICE_VALUE")" || die "Cannot resolve $RENDER_DEVICE_VALUE."
[[ "$canonical_device" == "$RENDER_DEVICE_VALUE" ]] || die "RENDER_DEVICE must be canonical, not a symlink."
[[ "$RENDER_DEVICE_VALUE" =~ ^/dev/dri/renderD[0-9]+$ ]] || die "RENDER_DEVICE must be /dev/dri/renderD<number>."
[[ -c "$RENDER_DEVICE_VALUE" ]] || die "$RENDER_DEVICE_VALUE is not a character device."
device_hex="$(stat -c '%t:%T' "$RENDER_DEVICE_VALUE")"
major_hex="${device_hex%%:*}"
minor_hex="${device_hex##*:}"
(( 16#$major_hex == 226 && 16#$minor_hex >= 128 )) || die "$RENDER_DEVICE_VALUE is not a DRM render node."
[[ -d "/sys/class/drm/$(basename -- "$RENDER_DEVICE_VALUE")/device" ]] || die "$RENDER_DEVICE_VALUE has no DRM sysfs device."
[[ -r "$RENDER_DEVICE_VALUE" && -w "$RENDER_DEVICE_VALUE" ]] || die "Current user cannot read/write $RENDER_DEVICE_VALUE."

check_port() {
  local port="$1" container="$2" published=""
  command -v ss >/dev/null 2>&1 || return 0
  ss -H -ltn "sport = :$port" | grep -q . || return 0
  published="$(podman port "$container" 8083/tcp 2>/dev/null || true)"
  grep -Fxq "127.0.0.1:$port" <<<"$published" || die "TCP port $port is already occupied."
}

ensure_image() {
  podman image exists "$IMAGE" || die "Image $IMAGE is missing; run ./steam-headless.sh build first."
}

ensure_network() {
  local network="$1" expected_container="$2" driver attached
  if ! podman network exists "$network"; then
    podman network create --driver bridge --label "$PROJECT_LABEL=$PROJECT_VALUE" "$network" >/dev/null
  fi
  [[ "$(network_label "$network")" == "$PROJECT_VALUE" ]] || die "Network $network is not managed by this project."
  driver="$(podman network inspect --format '{{.Driver}}' "$network")"
  [[ "$driver" == "bridge" ]] || die "Network $network must use bridge, not $driver."
  attached="$(podman network inspect --format '{{range .Containers}}{{println .Name}}{{end}}' "$network" 2>/dev/null || true)"
  while IFS= read -r name; do
    [[ -z "$name" || "$name" == "$expected_container" ]] || die "Network $network is shared with $name."
  done <<<"$attached"
}

ensure_volume() {
  local volume="$1" instance="$2" purpose="$3" expected actual
  expected="$instance/$purpose"
  if ! podman volume exists "$volume"; then
    podman volume create --label "$PROJECT_LABEL=$PROJECT_VALUE" --label "io.openclaw.viking-rise.volume=$expected" "$volume" >/dev/null
  fi
  [[ "$(volume_label "$volume")" == "$PROJECT_VALUE" ]] || die "Volume $volume is not managed by this project."
  actual="$(podman volume inspect --format '{{index .Labels "io.openclaw.viking-rise.volume"}}' "$volume")"
  [[ "$actual" == "$expected" ]] || die "Volume $volume has unexpected purpose label: $actual."
}

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

run_instance() {
  local instance="$1" port="$2" password="$3" cpus="$4" memory="$5"
  local container="viking-rise-steam-$instance"
  local network="viking-rise-steam-$instance-net"
  local home_volume="viking-rise-steam-$instance-home"
  local games_volume="viking-rise-steam-$instance-games"
  local runtime_env

  ensure_image
  check_port "$port" "$container"
  ensure_network "$network" "$container"
  ensure_volume "$home_volume" "steam-$instance" home
  ensure_volume "$games_volume" "steam-$instance" games
  remove_managed_container "$container"

  runtime_env="$(mktemp)"
  chmod 600 "$runtime_env"
  printf 'USER_PASSWORD=%s\n' "$password" >"$runtime_env"
  trap 'rm -f -- "$runtime_env"' EXIT

  podman run -d \
    --name "$container" \
    --hostname "$container" \
    --label "$PROJECT_LABEL=$PROJECT_VALUE" \
    --label "io.openclaw.viking-rise.instance=steam-$instance" \
    --network "$network" \
    --dns "$DNS_SERVER_VALUE" \
    --device "$RENDER_DEVICE_VALUE:$RENDER_DEVICE_VALUE" \
    --group-add keep-groups \
    --publish "127.0.0.1:$port:8083" \
    --volume "$home_volume:/home/default:Z" \
    --volume "$games_volume:/mnt/games:Z" \
    --env-file "$runtime_env" \
    --env "TZ=$TZ_VALUE" \
    --env 'USER_LOCALES=en_US.UTF-8 UTF-8' \
    --env DISPLAY=:55 \
    --env "DISPLAY_SIZEW=$DISPLAY_WIDTH_VALUE" \
    --env "DISPLAY_SIZEH=$DISPLAY_HEIGHT_VALUE" \
    --env XAUTHORITY=/tmp/.X11-unix/run/viking-rise-Xauthority \
    --env "PUID=$PUID_VALUE" \
    --env "PGID=$PGID_VALUE" \
    --env UMASK=022 \
    --env MODE=secondary \
    --env WEB_UI_MODE=vnc \
    --env ENABLE_VNC_AUDIO=true \
    --env PORT_NOVNC_WEB=8083 \
    --env ENABLE_STEAM=true \
    --env STEAM_ARGS=-silent \
    --env ENABLE_SUNSHINE=false \
    --env ENABLE_EVDEV_INPUTS=false \
    --env FORCE_X11_DUMMY_CONFIG=false \
    --env NVIDIA_VISIBLE_DEVICES= \
    --env NVIDIA_DRIVER_CAPABILITIES= \
    --env "RENDER_DEVICE=$RENDER_DEVICE_VALUE" \
    --cpus "$cpus" \
    --memory "$memory" \
    --pids-limit "$PIDS_LIMIT_VALUE" \
    --shm-size "$SHM_SIZE_VALUE" \
    --ulimit nofile=1024:524288 \
    --restart unless-stopped \
    --stop-timeout 30 \
    --health-cmd /usr/local/bin/healthcheck-steam-headless.sh \
    --health-interval 10s \
    --health-timeout 3s \
    --health-retries 12 \
    --health-start-period 45s \
    "$IMAGE" >/dev/null

  rm -f -- "$runtime_env"
  trap - EXIT
  wait_healthy "$container"
  echo "Open http://127.0.0.1:$port/"
}

echo "Validated local rootless Podman: runtime=$oci_runtime, cgroup=$cgroups_version"

case "$ACTION" in
  check)
    check_port "$STEAM_1_WEB_PORT_VALUE" viking-rise-steam-1
    check_port "$STEAM_2_WEB_PORT_VALUE" viking-rise-steam-2
    echo "Preflight passed; no image was pulled, built, or started."
    ;;
  up-one)
    run_instance 1 "$STEAM_1_WEB_PORT_VALUE" "$INSTANCE_1_OS_PASSWORD_VALUE" "$STEAM_1_CPUS_VALUE" "$STEAM_1_MEM_LIMIT_VALUE"
    ;;
  up-two)
    [[ "$(container_label viking-rise-steam-1)" == "$PROJECT_VALUE" ]] || die "steam-1 is not managed by this project."
    [[ "$(podman inspect --format '{{.State.Health.Status}}' viking-rise-steam-1 2>/dev/null || true)" == "healthy" ]] || \
      die "steam-1 must be running and healthy before starting steam-2."
    run_instance 2 "$STEAM_2_WEB_PORT_VALUE" "$INSTANCE_2_OS_PASSWORD_VALUE" "$STEAM_2_CPUS_VALUE" "$STEAM_2_MEM_LIMIT_VALUE"
    ;;
esac
