# PX4 SkyBridge Relay

PX4 SkyBridge Relay documents how to operate a companion computer as a transparent network bridge between a PX4 autopilot and other hosts on the LAN. The companion computer exposes the USB CDC (MAVLink) interface as an outbound UDP service and tunnels the UART interface over TCP so that remote agents can interact with the PX4 serial endpoints without direct physical access.

## Architecture

- **MAVLink channel**: the companion computer routes `/dev/ttyACM0` (the PX4 USB CDC interface) through `mavlink-routerd`, which listens for MAVLink packets and forwards them as UDP server traffic on port `14550`. This allows ground control stations on the same network to receive heartbeats and send control messages without touching the flight controller’s USB connection.
- **Serial-over-TCP tunnel**: `/dev/ttyUSB0` typically carries the PX4-side Micro XRCE-DDS stream; `scripts/bridge_control.sh` launches a dedicated `socat` process that listens on TCP port `8888` and forwards those raw bytes so any downstream TCP-capable XRCE Agent can treat the link as a serial transport.
- **Serial-over-TCP tunnel**: `/dev/ttyUSB0` typically carries DDS or `nsh` data from PX4. `scripts/bridge_control.sh` (via its `start` command) runs `socat` to expose that UART on TCP port `8888`, preserving the raw byte stream and enabling remote hosts to recreate it as a pseudo-terminal.

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

Set `DEST` or `MAVLINK_ROUTER_REF` before invoking the script if you need to override the repository location or build tag. The script prints the path to the compiled binary (default `build/mavlink-router/src/mavlink-routerd`). Run that binary with `-c /path/to/config/main.conf` to verify its endpoints; `scripts/bridge_control.sh` already defaults to that build location unless you override `MAVLINK_ROUTER_BIN`.

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

For `/dev/ttyUSB0`, `scripts/bridge_control.sh` (start command) creates a raw TCP endpoint (`TCP 8888`) via `socat`. Remote hosts can connect to that port, optionally re-encapsulate it as UDP if needed, or simply expose it locally as a pseudo-serial device before feeding the stream into DDS or `nsh`. The MAVLink router remains responsible for UDP streaming of `/dev/ttyACM0`, while the `socat` tunnel keeps the UART traffic untouched and available on the LAN.

Additional endpoint sections can be appended if you want to multicast to multiple UDP clients or mix in TCP connections. Any changes to this file will be honored the next time `scripts/bridge_control.sh` launches the router.

## Companion computer setup (server)

1. Adjust `/etc/mavlink-router/main.conf` if needed (use `config/main.conf` as guidance).
2. Manage the relay with `scripts/bridge_control.sh`:
   - `./scripts/bridge_control.sh start` launches `mavlink-routerd` (using the repo config if `/etc/mavlink-router/main.conf` is missing) and starts the `socat` tunnel.
   - `./scripts/bridge_control.sh stop` kills both services; `status` and `toggle` are also available.
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

3. To verify the MAVLink UDP stream is present before you launch a ground station, run `scripts/test_udp_connection.sh` on the remote host (or the companion computer itself). The script sends a short handshake to 14550 so the router replies, then listens for up to 15 seconds and prints the hex of any packets it receives.

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

## Scripts

- `scripts/bridge_control.sh`: manages the MAVLink router and `socat` tunnel with `start|stop|status|toggle|restart` arguments, printing each PID and current state.
- `scripts/build_mavlink_router.sh`: clones the upstream GitHub repository (`https://github.com/mavlink-router/mavlink-router.git`), checks out the pinned ref, and builds the binary with Meson/Ninja.
- `scripts/test_udp_connection.sh`: sends a MAVLink hello to UDP 14550 and listens for replies for 15 seconds (Python 3 is required) to confirm the router is broadcasting.

Make the scripts executable before use:

```bash
chmod +x scripts/bridge_control.sh scripts/build_mavlink_router.sh scripts/test_udp_connection.sh
```
