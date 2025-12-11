#!/usr/bin/env bash
set -euo pipefail

MAV_DEV=${MAV_DEV:-/dev/ttyACM0}
DDS_DEV=${DDS_DEV:-/dev/ttyUSB0}
BAUD=${BAUD:-921600}
DDS_PORT=${DDS_PORT:-8888}
MAV_PORT=${MAV_PORT:-14550}
MAV_CONFIG=${MAV_CONFIG:-/etc/mavlink-router/main.conf}
MAVLINK_ROUTER_BIN=${MAVLINK_ROUTER_BIN:-mavlink-routerd}

function start_mavlink_router() {
  if ! (command -v "$MAVLINK_ROUTER_BIN" >/dev/null 2>&1 || [[ -x "$MAVLINK_ROUTER_BIN" ]]); then
    echo "skybridge: $MAVLINK_ROUTER_BIN not found" >&2
    exit 1
  fi

  echo "[SkyBridge] Starting MAVLink router..."
  if [[ -f "$MAV_CONFIG" ]]; then
    "$MAVLINK_ROUTER_BIN" --conf "$MAV_CONFIG" &
  else
    "$MAVLINK_ROUTER_BIN" -e "$MAV_DEV:$BAUD" -e "0.0.0.0:$MAV_PORT" &
  fi
  MAV_PID=$!
  echo "[SkyBridge] MAVLink router PID $MAV_PID"
}

function start_dds_tunnel() {
  if ! command -v socat >/dev/null 2>&1; then
    echo "skybridge: socat is not installed" >&2
    exit 1
  fi

  echo "[SkyBridge] Starting DDS serial tunnel on TCP port $DDS_PORT"
  nohup socat TCP-LISTEN:"$DDS_PORT",fork,reuseaddr FILE:"$DDS_DEV",b"$BAUD",raw,echo=0 >/dev/null 2>&1 &
  DDS_PID=$!
  echo "[SkyBridge] DDS tunnel PID $DDS_PID"
}

start_mavlink_router
start_dds_tunnel

echo "[SkyBridge] MAVLink UDP $MAV_PORT -> $MAV_DEV"
echo "[SkyBridge] DDS TCP $DDS_PORT -> $DDS_DEV"
