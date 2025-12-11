#!/usr/bin/env bash
set -euo pipefail

PORT=${PORT:-14550}
TIMEOUT=${TIMEOUT:-15}
COMPANION_IP=${COMPANION_IP:-192.168.31.240}

if ! command -v python3 >/dev/null 2>&1; then
  echo "skybridge: python3 is required to run this test script" >&2
  exit 1
fi

echo "[SkyBridge] Sending MAVLink hello from ephemeral port to ${COMPANION_IP}:${PORT}"

python3 <<EOF
import binascii
import socket
import time

companion_ip = "${COMPANION_IP}"
port = ${PORT}
timeout = ${TIMEOUT}

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(timeout)
sock.bind(("0.0.0.0", 0))

sock.sendto(b"SKYBRIDGE-HELLO", (companion_ip, port))

deadline = time.time() + timeout
seen = False
while time.time() < deadline:
    try:
        data, addr = sock.recvfrom(4096)
    except socket.timeout:
        break
    seen = True
    hexdump = binascii.hexlify(data).decode("ascii")
    print(f"[SkyBridge] Received {len(data)} bytes from {addr[0]}:{addr[1]} -> {hexdump}")
    if time.time() + 1 < deadline:
        continue
    else:
        break

if not seen:
    print("[SkyBridge] No UDP packets arrived within timeout.")
EOF

echo "[SkyBridge] Test finished"
