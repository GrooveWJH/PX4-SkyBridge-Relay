# PX4 SkyBridge Relay

PX4 SkyBridge Relay documents how to operate a companion computer as a transparent network bridge between a PX4 autopilot and other hosts on the LAN. The companion computer exposes the USB CDC (MAVLink) interface as an outbound UDP service and tunnels the UART interface over TCP so that remote agents can interact with the PX4 serial endpoints without direct physical access.

## Architecture

- **MAVLink channel**: the companion computer routes `/dev/ttyACM0` (the PX4 USB CDC interface) through `mavlink-routerd`, which listens for MAVLink packets and forwards them as UDP server traffic on port `14550`. This allows ground control stations on the same network to receive heartbeats and send control messages without touching the flight controller’s USB connection.
- **Serial-over-TCP tunnel**: `/dev/ttyUSB0` typically carries DDS or `nsh` data from PX4. `scripts/start_bridge.sh` runs `socat` to expose that UART on TCP port `8888`, preserving the raw byte stream and enabling remote hosts to recreate it as a pseudo-terminal.

## Requirements

Clone the repository with its submodules and install the build-time dependencies plus `socat` (the UART tunnel still relies on it):

```bash
git clone https://github.com/GrooveWJH/PX4-SkyBridge-Relay.git --recursive
cd PX4-SkyBridge-Relay
sudo apt update
sudo apt install git meson ninja-build pkg-config gcc g++ systemd socat
```

Ensure the local user belongs to the `dialout` group so it can open `/dev/ttyACM0` and `/dev/ttyUSB0` without elevated privileges.

## Building `mavlink-router` from source

Use `scripts/build_mavlink_router.sh` to compile the code stored inside the `thirdparty/mavlink-router` submodule. The script respects an optional `MAVLINK_ROUTER_REF` and runs Meson/Ninja via that workspace:

```bash
scripts/build_mavlink_router.sh
```

Set `DEST` or `MAVLINK_ROUTER_REF` before invoking the script if you need to override the repository location or build tag. The script prints the path to the compiled binary (`${DEST:-thirdparty/mavlink-router}/build/src/mavlink-routerd`). Run that binary with `-c /path/to/config/main.conf` to verify its endpoints and then export `MAVLINK_ROUTER_BIN` so `scripts/start_bridge.sh` uses it.

## Configuration reference (`config/main.conf`)

The companion computer’s default configuration declares one UART endpoint and a single UDP server endpoint:

```ini
[General]
# Log=/var/log/mavlink-router

[UartEndpoint px4_usb]
Device = /dev/ttyACM0
Baud = 921600

[UdpEndpoint qgc_lan]
Mode = Server
Address = 0.0.0.0
Port = 14550
```

- `[General]`: optional global settings. Uncomment `Log` to enable flight logging to file.
- `[UartEndpoint px4_usb]`: names the PX4 USB CDC device and configures the baud rate. You can duplicate this block if additional UARTs should be exposed through the router.
- `[UdpEndpoint qgc_lan]`: defines the UDP server that listens on all interfaces and waits for incoming ground station connections on port `14550`. `Mode = Server` ensures the companion computer answers the first client that connects and keeps relaying MAVLink data to that socket.

Additional endpoint sections can be appended if you want to multicast to multiple UDP clients or mix in TCP connections. Any changes to this file will be honored the next time `scripts/start_bridge.sh` launch the router.

## Companion computer setup (server)

1. Adjust `/etc/mavlink-router/main.conf` if needed (use `config/main.conf` as guidance).
2. Run `scripts/start_bridge.sh`:
   - It starts `mavlink-routerd` with the chosen configuration (either `/etc/mavlink-router/main.conf` or the inline endpoints).
   - It launches `socat` in the background so `/dev/ttyUSB0` is available on TCP `8888`.
3. For persistent deployments, copy `systemd/skybridge.service` into `/etc/systemd/system`, adjust the paths, and enable the service so the bridge starts automatically on boot.

Logs:
- `mavlink-router` logs can be recorded by enabling the `Log` option in the configuration or by passing `--log`/`--telemetry-log` parameters when invoking the binary.
- `socat` runs via `nohup` with its output redirected to `/dev/null`; wrap it if you need bespoke logging.

## Remote-host access (DDS)

On any remote Linux host that consumes PX4’s UART data:

1. Create a pseudo-terminal linked to the companion computer’s TCP tunnel (replace `<COMPANION_IP>` with the actual LAN IP):

```bash
socat PTY,link=/tmp/ttyVIRT_DDS,raw,echo=0 TCP:<COMPANION_IP>:8888
```

2. Run `MicroXRCEAgent` (or other DDS client) pointing to the newly created device:

```bash
MicroXRCEAgent serial --dev /tmp/ttyVIRT_DDS -b 921600
```

These commands keep running until interrupted; when the agent exits, `socat` terminates and the tunnel closes.

## Systemd integration (optional)

Place `systemd/skybridge.service` into `/etc/systemd/system`, edit the `WorkingDirectory`/`ExecStart` paths to match your installation, and then enable the service:

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now skybridge
```

The unit is configured as a forking service so it can manage the background `socat` process started by the script.

## Operational notes

- Wireless LAN latency or jitter affects DDS traffic more than MAVLink; prefer wired Ethernet or a quiet 5GHz network.
- Reserve a static IP or DHCP reservation for the companion computer so remote hosts can rely on a consistent `<COMPANION_IP>`.
- After adding a user to `dialout`, log out and back in (or reboot) before running the bridge to ensure permission changes take effect.

## Scripts

- `scripts/start_bridge.sh`: launches `mavlink-routerd` (respecting `MAVLINK_ROUTER_BIN` when set) and runs `socat` to tunnel `/dev/ttyUSB0` over TCP.
- `scripts/build_mavlink_router.sh`: clones the upstream GitHub repository (`https://github.com/mavlink-router/mavlink-router.git`), checks out the pinned ref, and builds the binary with Meson/Ninja.

Make the scripts executable before use:

```bash
chmod +x scripts/start_bridge.sh scripts/build_mavlink_router.sh
```
