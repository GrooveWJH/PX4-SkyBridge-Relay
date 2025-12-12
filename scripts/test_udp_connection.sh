#!/usr/bin/env bash
set -euo pipefail

PORT=${PORT:-14550}
TIMEOUT=${TIMEOUT:-15}
COMPANION_IP=${COMPANION_IP:-192.168.31.240}

PRINT_HEX=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    hex|--hex)
      PRINT_HEX=1
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [hex]"
      echo "  hex    print each received UDP payload as hex"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [hex]" >&2
      exit 1
      ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "skybridge: python3 is required to run this test script" >&2
  exit 1
fi

echo "[SkyBridge] Sending MAVLink hello from ephemeral port to ${COMPANION_IP}:${PORT}"
echo "[SkyBridge] Listening for traffic and calculating bandwidth..."
if [[ "${PRINT_HEX}" -ne 0 ]]; then
  echo "[SkyBridge] Hex dump mode enabled."
else
  echo "[SkyBridge] Printing bandwidth statistics at 2 Hz."
fi

python3 <<EOF
import binascii
import socket
import time

companion_ip = "${COMPANION_IP}"
port = ${PORT}
timeout = ${TIMEOUT}
print_hex = ${PRINT_HEX} != 0
report_interval = 0.5  # 打印间隔(秒)

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
# 设置较短的socket超时以便能频繁检查 loop 状态，
# 但要注意这不影响总体的 timeout (deadline)
sock.settimeout(0.5) 
sock.bind(("0.0.0.0", 0))

# 发送 Hello 包
try:
    sock.sendto(b"SKYBRIDGE-HELLO", (companion_ip, port))
except Exception as e:
    print(f"[Error] Failed to send hello: {e}")

deadline = time.time() + timeout
start_time = time.time()
last_report_time = start_time
total_bytes_interval = 0
packet_count = 0
seen = False

print(f"[SkyBridge] Monitor started. Timeout in {timeout} seconds.")

while time.time() < deadline:
    try:
        # 接收数据
        data, addr = sock.recvfrom(65535) # 65535 是 UDP 最大包长
        packet_len = len(data)
        total_bytes_interval += packet_len
        packet_count += 1
        seen = True
        
        if print_hex:
            hex_payload = binascii.hexlify(data).decode("ascii")
            print(f"[UDP] {addr[0]}:{addr[1]} len={packet_len} bytes -> {hex_payload}")

    except socket.timeout:
        # socket 超时只是为了让循环继续检查时间，不是错误
        pass
    except Exception as e:
        print(f"[Error] Socket error: {e}")
        break

    # 计算并打印带宽
    current_time = time.time()
    time_diff = current_time - last_report_time

    if not print_hex and time_diff >= report_interval:
        if total_bytes_interval > 0:
            # 基础计算
            bits = total_bytes_interval * 8
            bytes_val = total_bytes_interval

            # 单位换算
            # 网络速度通常使用 1000 进制 (SI)，存储速度通常使用 1024 进制 (IEC)
            # 这里按照一般习惯：
            kbps = (bits / 1000) / time_diff
            mbps = (bits / 1000000) / time_diff
            kb_s = (bytes_val / 1024) / time_diff
            mb_s = (bytes_val / 1048576) / time_diff

            print(f"[Speed] {kbps:8.2f} Kbps | {mbps:8.2f} Mbps | {kb_s:8.2f} KB/s | {mb_s:8.2f} MB/s")
        
        # 重置计数器
        total_bytes_interval = 0
        last_report_time = current_time

if not seen:
    print("[SkyBridge] No UDP packets arrived within timeout.")
else:
    print(f"[SkyBridge] Test finished. Total packets received: {packet_count}")

EOF

echo "[SkyBridge] Script execution completed"
