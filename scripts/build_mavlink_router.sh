#!/usr/bin/env bash
set -euo pipefail

DEFAULT_DEST="$(cd "$(dirname "$0")/.." && pwd)/thirdparty/mavlink-router"
DEST=${DEST:-$DEFAULT_DEST}
REF=${MAVLINK_ROUTER_REF:-}

if [[ ! -d "$DEST" ]]; then
  echo "skybridge: thirdparty repo not found at $DEST" >&2
  echo "Please run 'git submodule update --init --recursive thirdparty/mavlink-router'." >&2
  exit 1
fi

echo "[SkyBridge] Building mavlink-router in ${DEST}"
cd "$DEST"

if [[ -n "$REF" ]]; then
  git fetch origin "$REF"
  git checkout "$REF"
fi

git submodule update --init --recursive

meson setup build . --wipe
ninja -C build

echo "[SkyBridge] Built binary available at ${DEST}/build/src/mavlink-routerd"
