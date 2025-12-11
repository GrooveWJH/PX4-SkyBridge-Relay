#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_DEST="$ROOT_DIR/thirdparty/mavlink-router"
DEFAULT_BUILD="$ROOT_DIR/build/mavlink-router"
DEST=${DEST:-$DEFAULT_DEST}
BUILD_DIR=${BUILD_DIR:-$DEFAULT_BUILD}
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

rm -rf "$BUILD_DIR"
meson setup "$BUILD_DIR" "$DEST" --wipe
ninja -C "$BUILD_DIR"

echo "[SkyBridge] Built binary available at ${BUILD_DIR}/src/mavlink-routerd"
