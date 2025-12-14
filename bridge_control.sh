#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_DIR=${PID_DIR:-"$ROOT_DIR/run"}
MAV_PID_FILE="$PID_DIR/mavlink-router.pid"
DDS_PID_FILE="$PID_DIR/socat.pid"
SUP_PID_FILE="$PID_DIR/bridge-supervisor.pid"
MAV_CONFIG=${MAV_CONFIG:-/etc/mavlink-router/main.conf}
MAV_DEV=${MAV_DEV:-/dev/ttyACM0}
DDS_DEV=${DDS_DEV:-/dev/ttyUSB0}
BAUD=${BAUD:-921600}
DDS_PORT=${DDS_PORT:-8888}
MAV_PORT=${MAV_PORT:-14550}
WAIT_INTERVAL=${WAIT_INTERVAL:-3}
DEFAULT_MAVLINK_BIN="$ROOT_DIR/build/bin/mavlink-routerd"
MAVLINK_ROUTER_BIN=${MAVLINK_ROUTER_BIN:-$DEFAULT_MAVLINK_BIN}

ACTION=${1:-status}

mkdir -p "$PID_DIR"

function mavlink_pid() {
  if [[ -f "$MAV_PID_FILE" ]]; then
    cat "$MAV_PID_FILE"
  fi
}

function dds_pid() {
  if [[ -f "$DDS_PID_FILE" ]]; then
    cat "$DDS_PID_FILE"
  fi
}

function process_alive() {
  local pid=$1
  if [[ -z "$pid" ]]; then
    return 1
  fi
  kill -0 "$pid" >/dev/null 2>&1
}

function supervisor_pid() {
  if [[ -f "$SUP_PID_FILE" ]]; then
    cat "$SUP_PID_FILE"
  fi
}

function write_pid() {
  local file=$1
  local pid=$2
  echo "$pid" > "$file"
}

function start_mavlink_router() {
  if [[ -n "$(mavlink_pid)" ]] && process_alive "$(mavlink_pid)"; then
    echo "[SkyBridge] MAVLink router already running with PID $(mavlink_pid)"
    return
  fi

  if ! (command -v "$MAVLINK_ROUTER_BIN" >/dev/null 2>&1 || [[ -x "$MAVLINK_ROUTER_BIN" ]]); then
    echo "skybridge: $MAVLINK_ROUTER_BIN not found" >&2
    exit 1
  fi

  local config_path="$MAV_CONFIG"
  if [[ ! -f "$config_path" ]]; then
    local repo_conf="$ROOT_DIR/config/main.conf"
    if [[ -f "$repo_conf" ]]; then
      config_path="$repo_conf"
    fi
  fi

  echo "[SkyBridge] Starting MAVLink router..."
  if [[ -f "$config_path" ]]; then
    "$MAVLINK_ROUTER_BIN" --conf-file "$config_path" &
  else
    "$MAVLINK_ROUTER_BIN" -e "$MAV_DEV:$BAUD" -e "0.0.0.0:$MAV_PORT" &
  fi
  write_pid "$MAV_PID_FILE" $!
  echo "[SkyBridge] MAVLink router PID $(mavlink_pid)"
}

function start_dds_tunnel() {
  if [[ -n "$(dds_pid)" ]] && process_alive "$(dds_pid)"; then
    echo "[SkyBridge] DDS tunnel already running with PID $(dds_pid)"
    return
  fi

  if ! command -v socat >/dev/null 2>&1; then
    echo "skybridge: socat not installed" >&2
    exit 1
  fi

  echo "[SkyBridge] Starting DDS serial tunnel on TCP port $DDS_PORT"
  nohup socat TCP-LISTEN:"$DDS_PORT",fork,reuseaddr,tcp-nodelay FILE:"$DDS_DEV",b"$BAUD",raw,echo=0 >/dev/null 2>&1 &
  write_pid "$DDS_PID_FILE" $!
  echo "[SkyBridge] DDS tunnel PID $(dds_pid)"
}

function stop_mavlink_router() {
  local pid=$(mavlink_pid)
  if [[ -z "$pid" ]]; then
    echo "[SkyBridge] MAVLink router is not running"
    return
  fi
  if process_alive "$pid"; then
    echo "[SkyBridge] Stopping MAVLink router PID $pid"
    kill "$pid"
    wait "$pid" 2>/dev/null || true
  fi
  rm -f "$MAV_PID_FILE"
}

function stop_dds_tunnel() {
  local pid=$(dds_pid)
  if [[ -z "$pid" ]]; then
    echo "[SkyBridge] DDS tunnel is not running"
    return
  fi
  if process_alive "$pid"; then
    echo "[SkyBridge] Stopping DDS tunnel PID $pid"
    kill "$pid"
    wait "$pid" 2>/dev/null || true
  fi
  rm -f "$DDS_PID_FILE"
}

function status() {
  echo "[SkyBridge] Status:"
  if process_alive "$(supervisor_pid)"; then
    echo " - Supervisor running (PID $(supervisor_pid))"
  else
    echo " - Supervisor stopped"
  fi
  if process_alive "$(mavlink_pid)"; then
    echo " - MAVLink router running (PID $(mavlink_pid))"
  else
    echo " - MAVLink router stopped"
  fi
  if process_alive "$(dds_pid)"; then
    echo " - DDS tunnel running (PID $(dds_pid))"
  else
    echo " - DDS tunnel stopped"
  fi
}

function wait_for_device() {
  local dev="$1"
  while [[ ! -e "$dev" ]]; do
    echo "[SkyBridge] Waiting for device $dev ..."
    sleep "$WAIT_INTERVAL"
  done
}

function supervisor_loop() {
  trap stop_dds_tunnel EXIT
  trap stop_mavlink_router EXIT

  while true; do
    wait_for_device "$MAV_DEV"
    wait_for_device "$DDS_DEV"

    start_mavlink_router
    start_dds_tunnel

    while true; do
      sleep "$WAIT_INTERVAL"
      if [[ ! -e "$MAV_DEV" || ! -e "$DDS_DEV" ]]; then
        echo "[SkyBridge] Device disappeared, restarting stack..."
        break
      fi
      if ! process_alive "$(mavlink_pid)"; then
        echo "[SkyBridge] MAVLink router exited, restarting stack..."
        break
      fi
      if ! process_alive "$(dds_pid)"; then
        echo "[SkyBridge] DDS tunnel exited, restarting stack..."
        break
      fi
    done

    stop_dds_tunnel
    stop_mavlink_router
    echo "[SkyBridge] Restarting in $WAIT_INTERVAL seconds..."
    sleep "$WAIT_INTERVAL"
  done
}

function start_supervisor_background() {
  if process_alive "$(supervisor_pid)"; then
    echo "[SkyBridge] Supervisor already running (PID $(supervisor_pid))"
    return
  fi
  echo "[SkyBridge] Launching supervisor..."
  nohup "$0" supervise >/dev/null 2>&1 &
  local pid=$!
  write_pid "$SUP_PID_FILE" "$pid"
  echo "[SkyBridge] Supervisor PID $pid"
}

function stop_supervisor() {
  local pid
  pid=$(supervisor_pid)
  if [[ -n "$pid" ]] && process_alive "$pid"; then
    echo "[SkyBridge] Stopping supervisor PID $pid"
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -f "$SUP_PID_FILE"
  stop_dds_tunnel
  stop_mavlink_router
}

case "$ACTION" in
  start)
    start_supervisor_background
    ;;
  stop)
    stop_supervisor
    ;;
  restart)
    stop_supervisor
    start_supervisor_background
    ;;
  toggle)
    if process_alive "$(supervisor_pid)"; then
      stop_supervisor
    else
      start_supervisor_background
    fi
    ;;
  status)
    status
    ;;
  supervise)
    write_pid "$SUP_PID_FILE" "$$"
    trap 'rm -f "$SUP_PID_FILE"' EXIT
    supervisor_loop
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|toggle|status|supervise}"
    exit 1
    ;;
esac
