# PX4 SkyBridge Relay

PX4 SkyBridge Relay documents how to operate a companion computer as a transparent network bridge between a PX4 autopilot and other hosts on the LAN. The companion computer exposes the USB CDC (MAVLink) interface as an outbound UDP service and tunnels the UART interface over TCP so that remote agents can interact with the PX4 serial endpoints without direct physical access.

## Architecture

- **MAVLink channel** – `/dev/ttyACM0` (PX4’s USB CDC interface) is routed through `mavlink-routerd`, which listens on UDP `14550` so any LAN host can consume MAVLink traffic.
- **Serial-over-TCP tunnel** – `/dev/ttyUSB0` typically carries PX4 Micro XRCE-DDS or shell data. `bridge_control.sh` launches `socat` to expose the UART on TCP `8888`, enabling remote hosts to recreate the serial link through a TCP socket or PTY.
- **Supervisor** – `bridge_control.sh` contains a watchdog loop that waits for the USB devices to appear, keeps both processes running, and restarts everything automatically if a cable disconnects or a process exits.

## Requirements

Clone the repository with its submodules and install the build-time dependencies plus `socat` (for the UART tunnel):

```bash
git clone https://github.com/GrooveWJH/PX4-SkyBridge-Relay.git --recursive
cd PX4-SkyBridge-Relay
sudo apt update
sudo apt install git meson ninja-build pkg-config gcc g++ systemd socat
```

Ensure the local user belongs to the `dialout` group so it can open `/dev/ttyACM0` and `/dev/ttyUSB0` without elevated privileges.

## Quick start

1. **Build once per platform** – this compiles the bundled `mavlink-router` and drops it into `build/bin/mavlink-routerd`, which the control script uses automatically:

   ```bash
   ./build.sh
   ```

2. **Connect the PX4** – plug the flight controller into the companion computer. By default we expect:
   - `/dev/ttyACM0` – MAVLink (USB CDC)
   - `/dev/ttyUSB0` – XRCE-DDS or other UART stream

   Override those paths via `MAV_DEV=/dev/...` and `DDS_DEV=/dev/...` when calling the control script if your board enumerates differently.

3. **Launch the bridge** – the script runs as a supervisor: it waits for both devices, starts `mavlink-routerd` and the `socat` tunnel, and keeps retrying if anything disconnects.

   ```bash
   ./bridge_control.sh start
   ./bridge_control.sh status
   ```

4. **Stop or restart** when needed:

   ```bash
   ./bridge_control.sh stop      # clean shutdown
   ./bridge_control.sh restart   # stop + start
   ```

Only `build.sh` and `bridge_control.sh` are required for day-to-day usage.

## MAVLink router configuration (`config/main.conf`)

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

Additional endpoint sections can be appended if you want to multicast to multiple UDP clients or mix in TCP connections. Any changes to this file will be honored the next time `bridge_control.sh` launches the router. When no `/etc/mavlink-router/main.conf` exists, the script falls back to `config/main.conf` inside the repository.

For the DDS tunnel `/dev/ttyUSB0`, `bridge_control.sh` exposes the port via `socat` on `TCP 8888`. Remote hosts can connect directly or bind it to a PTY and feed it to `MicroXRCEAgent`.

## Companion computer setup (server)

1. Adjust `/etc/mavlink-router/main.conf` if needed (use `config/main.conf` as guidance).
2. Manage the relay with `bridge_control.sh`:
   - `./bridge_control.sh start` launches the watchdog. It waits for `/dev/ttyACM0` and `/dev/ttyUSB0`, starts `mavlink-routerd` plus the TCP tunnel, and restarts both components automatically if either device disappears.
   - `./bridge_control.sh status` reports the supervisor/MAVLink/tunnel processes.
   - `./bridge_control.sh stop` kills the watchdog and both child services.
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

3. To verify the MAVLink UDP stream is present before you launch a ground station, run `scripts/test_udp_connection.sh` on the remote host (or the companion computer itself). The script sends a short handshake to 14550 so the router replies, then listens for up to 15 seconds and reports bandwidth (or hex payloads when `--hex` is provided).

## Systemd integration (optional)

Place `systemd/skybridge.service` into `/etc/systemd/system`, edit the `WorkingDirectory`/`ExecStart` paths to match your installation, and then enable the service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now skybridge
```

The unit simply runs `bridge_control.sh supervise`, so the same watchdog behavior described above applies when managed by systemd.

## Operational notes

- Wireless LAN latency or jitter affects DDS traffic more than MAVLink; prefer wired Ethernet or a quiet 5GHz network.
- Reserve a static IP or DHCP reservation for the companion computer so remote hosts can rely on a consistent `<COMPANION_IP>`.
- After adding a user to `dialout`, log out and back in (or reboot) before running the bridge to ensure permission changes take effect.

## Scripts

- `build.sh`: compiles `thirdparty/mavlink-router` (Meson/Ninja) and copies the resulting `mavlink-routerd` into `build/bin/`.
- `bridge_control.sh`: supervises the MAVLink router plus the `socat` tunnel (`start|stop|restart|status|toggle|supervise`).
- `scripts/test_udp_connection.sh`: sends a MAVLink hello to UDP 14550 and listens for replies for 15 seconds (Python 3 is required) to confirm the router is broadcasting.

Make the helper scripts executable before use:

```bash
chmod +x build.sh bridge_control.sh scripts/test_udp_connection.sh
```
