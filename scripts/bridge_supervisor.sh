#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PID_DIR=${PID_DIR:-"$ROOT_DIR/run"}
MAV_DEV=${MAV_DEV:-/dev/ttyACM0}
DDS_DEV=${DDS_DEV:-/dev/ttyUSB0}
WAIT_INTERVAL=${WAIT_INTERVAL:-3}

MAV_PID_FILE="$PID_DIR/mavlink-router.pid"
DDS_PID_FILE="$PID_DIR/socat.pid"

stop_stack() {
  "$ROOT_DIR/bridge_control.sh" stop || true
}

trap stop_stack EXIT TERM INT

wait_for_device() {
  local dev="$1"
  while [[ ! -e "$dev" ]]; do
    echo "[SkyBridge] Waiting for device $dev ..."
    sleep "$WAIT_INTERVAL"
  done
}

pid_alive() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  local pid
  pid=$(cat "$file" 2>/dev/null || true)
  if [[ -z "$pid" ]]; then
    return 1
  fi
  kill -0 "$pid" >/dev/null 2>&1
}

while true; do
  wait_for_device "$MAV_DEV"
  wait_for_device "$DDS_DEV"

  echo "[SkyBridge] Launching bridge stack"
  "$ROOT_DIR/bridge_control.sh" start

  while true; do
    sleep "$WAIT_INTERVAL"
    if ! pid_alive "$MAV_PID_FILE"; then
      echo "[SkyBridge] mavlink-routerd stopped or missing, restarting..."
      break
    fi
    if ! pid_alive "$DDS_PID_FILE"; then
      echo "[SkyBridge] socat tunnel stopped or missing, restarting..."
      break
    fi
    if [[ ! -e "$MAV_DEV" || ! -e "$DDS_DEV" ]]; then
      echo "[SkyBridge] Device disappeared, restarting..."
      break
    fi
  done

  stop_stack
  echo "[SkyBridge] Bridge stack stopped, will retry in $WAIT_INTERVAL seconds"
  sleep "$WAIT_INTERVAL"
done
