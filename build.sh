#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
BIN_DIR="$BUILD_DIR/bin"
MAVLINK_SRC="$ROOT_DIR/thirdparty/mavlink-router"
MAVLINK_BUILD_DIR="$BUILD_DIR/mavlink-router"
NPROC=${NPROC:-$(nproc || echo 4)}

function ensure_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "skybridge: missing required tool '$1'" >&2
    exit 1
  fi
}

function ensure_submodule() {
  if [[ ! -d "$MAVLINK_SRC" ]]; then
    echo "[SkyBridge] Initializing mavlink-router submodule"
    git -C "$ROOT_DIR" submodule update --init --recursive thirdparty/mavlink-router
  else
    git -C "$ROOT_DIR" submodule update --init thirdparty/mavlink-router
  fi
}

function build_mavlink_router() {
  echo "[SkyBridge] Building mavlink-router via Meson/Ninja"
  rm -rf "$MAVLINK_BUILD_DIR"
  meson setup "$MAVLINK_BUILD_DIR" "$MAVLINK_SRC" --buildtype release
  ninja -C "$MAVLINK_BUILD_DIR" -j"$NPROC"

  mkdir -p "$BIN_DIR"
  cp "$MAVLINK_BUILD_DIR/src/mavlink-routerd" "$BIN_DIR/mavlink-routerd"
  echo "[SkyBridge] Binary available at $BIN_DIR/mavlink-routerd"
}

function main() {
  ensure_tool git
  ensure_tool meson
  ensure_tool ninja

  ensure_submodule
  build_mavlink_router
}

main "$@"
