#!/usr/bin/env bash
#
# Manage ser2net so PX4's /dev/ttyUSB0 is exposed over TCP for remserial clients.
# Usage:
#   scripts/ser2net_bridge.sh start|stop|restart|status
# Env:
#   SER2NET_CONF   Override config path (default config/ser2net_skybridge.conf)
#   PID_DIR        Directory for PID file (default run/)
#
# Remote host:
#   remserial -r <COMPANION_IP> -p 8889 -l /tmp/ttyVIRT_DDS -s "921600 raw"
#   MicroXRCEAgent serial --dev /tmp/ttyVIRT_DDS -b 921600

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PID_DIR=${PID_DIR:-"$ROOT_DIR/run"}
PID_FILE="$PID_DIR/ser2net.pid"
SER2NET_CONF=${SER2NET_CONF:-"$ROOT_DIR/config/ser2net_skybridge.conf"}
SER2NET_BIN=${SER2NET_BIN:-"$ROOT_DIR/build/bin/ser2net"}
ACTION=${1:-status}

mkdir -p "$PID_DIR"

function current_pid() {
  if [[ -f "$PID_FILE" ]]; then
    cat "$PID_FILE"
  fi
}

function process_alive() {
  local pid=$1
  [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1
}

function start_ser2net() {
  local pid
  pid=$(current_pid)
  if process_alive "$pid"; then
    echo "[SkyBridge][ser2net] already running (PID $pid)"
    return
  fi

  if [[ ! -x "$SER2NET_BIN" ]]; then
    echo "skybridge: ser2net binary not found at $SER2NET_BIN (run ./build.sh first?)" >&2
    exit 1
  fi

  if [[ ! -f "$SER2NET_CONF" ]]; then
    echo "skybridge: ser2net config $SER2NET_CONF missing" >&2
    exit 1
  fi

  echo "[SkyBridge][ser2net] launching $SER2NET_BIN with config $SER2NET_CONF"
  "$SER2NET_BIN" -c "$SER2NET_CONF" -P "$PID_FILE"
  pid=$(current_pid)
  if process_alive "$pid"; then
    echo "[SkyBridge][ser2net] running (PID $pid)"
  else
    echo "[SkyBridge][ser2net] failed to start, check syslog" >&2
    exit 1
  fi
}

function stop_ser2net() {
  local pid
  pid=$(current_pid)
  if [[ -z "$pid" ]]; then
    echo "[SkyBridge][ser2net] not running"
    return
  fi
  if process_alive "$pid"; then
    echo "[SkyBridge][ser2net] stopping PID $pid"
    kill "$pid"
    wait "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
}

function status_ser2net() {
  local pid
  pid=$(current_pid)
  if process_alive "$pid"; then
    echo "[SkyBridge][ser2net] running (PID $pid)"
  else
    echo "[SkyBridge][ser2net] stopped"
  fi
}

case "$ACTION" in
  start)
    start_ser2net
    ;;
  stop)
    stop_ser2net
    ;;
  restart)
    stop_ser2net
    start_ser2net
    ;;
  status)
    status_ser2net
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}"
    exit 1
    ;;
esac
