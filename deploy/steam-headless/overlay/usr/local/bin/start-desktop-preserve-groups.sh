#!/usr/bin/env bash
set -euo pipefail

: "${PUID:?PUID is required}"
: "${PGID:?PGID is required}"

# Podman's keep-groups applies to PID 1. Upstream supervisord normally uses
# setgroups() while switching to the desktop user, discarding those host GPU
# groups. Keep the inherited supplementary groups while dropping UID/GID.
exec /usr/bin/setpriv \
  --reuid "$PUID" \
  --regid "$PGID" \
  --keep-groups \
  /usr/local/bin/start-desktop-unprivileged.sh
