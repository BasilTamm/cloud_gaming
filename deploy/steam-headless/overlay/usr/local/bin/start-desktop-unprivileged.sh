#!/usr/bin/env bash
set -euo pipefail

: "${RENDER_DEVICE:?RENDER_DEVICE is required}"

if [[ ! -r "$RENDER_DEVICE" || ! -w "$RENDER_DEVICE" ]]; then
  echo "ERROR: desktop user cannot read/write $RENDER_DEVICE after privilege drop." >&2
  exit 1
fi

exec /usr/bin/start-desktop.sh
