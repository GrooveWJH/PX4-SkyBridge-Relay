# PX4 SkyBridge Relay（中文说明）

本项目介绍如何将伴随计算机配置为 PX4 飞控与局域网之间的透明桥接器。伴随计算机将 USB CDC（MAVLink）接口以 UDP 服务的形式暴露在网内，并将 UART 串口通过 TCP 隧道发送给远端主机，使其能够在不与飞控直接相连的前提下访问串口数据流。

## 架构

- **MAVLink 通道**：伴随计算机通过 `mavlink-routerd` 将 `/dev/ttyACM0`（PX4 USB CDC）以 UDP 服务的形式暴露在 `14550` 端口，地面站可直接订阅来自飞控的心跳与控制信息。
- **串口到 TCP 隧道**：`/dev/ttyUSB0` 上通常承载 Micro XRCE-DDS 或 `nsh` 数据，`bridge_control.sh` 内置的 `socat` 会把此串口透传到 TCP `8888`，方便远端主机建立虚拟串口或直接用 TCP 读取。
- **守护监控**：`bridge_control.sh` 本身包含一个 watchdog 循环，会等待设备出现、监控进程存活，并在串口拔插或程序退出时自动重启，确保桥接链路持续可用。

## 依赖

```bash
git clone https://github.com/GrooveWJH/PX4-SkyBridge-Relay.git --recursive
cd PX4-SkyBridge-Relay
sudo apt update
sudo apt install git meson ninja-build pkg-config gcc g++ systemd socat
```

请确保运行时用户属于 `dialout` 组，以无需 sudo 即可打开 `/dev/ttyACM0` 与 `/dev/ttyUSB0`。

## 快速开始

1. **编译一次**：执行仓库根目录的 `build.sh`，它会运行 Meson/Ninja 并将 `mavlink-routerd` 输出到 `build/bin/`。只要更换平台或更新子模块时再重新执行即可。

   ```bash
   ./build.sh
   ```

2. **连接飞控**：默认假定
   - `/dev/ttyACM0` → PX4 USB CDC (MAVLink)
   - `/dev/ttyUSB0` → XRCE-DDS/其他串口

   如果设备号不同，可在运行控制脚本时通过 `MAV_DEV=/dev/...`、`DDS_DEV=/dev/...` 覆盖。

3. **启动桥接**：`bridge_control.sh start` 会启动守护循环，等待串口上线后拉起 `mavlink-routerd` 与 `socat`，若串口掉线会自动重试。

   ```bash
   ./bridge_control.sh start
   ./bridge_control.sh status
   ```

4. **停止/重启**：

   ```bash
   ./bridge_control.sh stop
   ./bridge_control.sh restart
   ```

日常仅需 `build.sh` 与 `bridge_control.sh` 两个脚本。

## 配置文件说明（`config/main.conf`）

配置文件包含以下三个部分：

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

- `[General]`：全局设置。解除 `Log` 注释即可将日志写入指定目录。
- `[UartEndpoint px4_usb]`：定义 PX4 USB CDC 设备及波特率。可复制该块暴露更多串口。
- `[UdpEndpoint qgc_lan]`：在所有接口以 Server 模式监听 14550，与首个连入的地面站建立 UDP 通道。

仓库内自带的 `config/main.conf` 会在 `/etc/mavlink-router/main.conf` 缺失时作为默认配置被 `bridge_control.sh` 读取；如已在系统级安装了配置，则自动优先使用系统路径。

`/dev/ttyUSB0` 的串口透传由控制脚本启动的 `socat` 完成（TCP 8888）。远端主机可直接连接或映射成伪终端后交给 `MicroXRCEAgent`。

你可以添加更多 `UdpEndpoint`/`TcpEndpoint` 来支持多客户端或 TCP 连接；修改后重启 `bridge_control.sh` 即可应用。

## 伴随计算机端（服务端）

1. 按需修订 `/etc/mavlink-router/main.conf`（可参考 `config/main.conf`）。
2. 使用 `bridge_control.sh` 管理：
   - `./bridge_control.sh start`：启动 watchdog，等待串口上线、拉起 `mavlink-routerd` 与 `socat`，并在设备掉线或进程退出时自动重启。
   - `./bridge_control.sh status`：查看守护进程、MAVLink Router、串口隧道的 PID 状态。
   - `./bridge_control.sh stop`：终止守护与子进程。
3. 若需开机自启，将 `systemd/skybridge.service` 拷贝到 `/etc/systemd/system`，调整路径后启用。

日志说明：
- `mavlink-router` 的日志由配置文件中 `Log` 选项控制，也可以通过命令行参数定向日志。
- `socat` 使用 `nohup` 后台运行并将输出重定向到 `/dev/null`，如需记录可自行封装。

## 远端访问（DDS）

在需要 PX4 UART 数据的远端主机上：

1. 运行以下命令，创建指向伴随计算机的虚拟串口（替换 `<COMPANION_IP>` 为实际地址）：

```bash
socat PTY,link=/tmp/ttyVIRT_DDS,raw,echo=0 TCP:<COMPANION_IP>:8888
```

2. 启动 `MicroXRCEAgent` 或其他 DDS 客户端，指向 `/tmp/ttyVIRT_DDS`：

```bash
MicroXRCEAgent serial --dev /tmp/ttyVIRT_DDS -b 921600
```

当 DDS 客户端退出后，`socat` 也会结束，从而断开 TCP 隧道。

3. 在启动地面站前可以运行 `scripts/test_udp_connection.sh` 来确认 MAVLink UDP 14550 是否有流量（脚本会发送握手并在 15 秒内输出速率或十六进制payload）。

## Systemd 集成（可选）

将 `systemd/skybridge.service` 复制到 `/etc/systemd/system`，根据所在路径调整 `WorkingDirectory` 与 `ExecStart`，然后启用服务：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now skybridge
```

Systemd 单元直接执行 `bridge_control.sh supervise`，因此会继承相同的守护行为。

## 运行须知

- 无线局域网的延迟或抖动会影响 DDS，因此建议使用有线或 5GHz 网络。
- 建议在路由器中为伴随计算机分配静态 IP，以便远端主机使用固定 `<COMPANION_IP>`。
- 添加用户到 `dialout` 后请重新登录或重启以确保权限生效。

## 脚本说明

- `build.sh`：编译 `thirdparty/mavlink-router` 并将 `mavlink-routerd` 放到 `build/bin/`。
- `bridge_control.sh`：提供 `start|stop|restart|status|toggle|supervise`，负责启动/守护 MAVLink Router 与 `socat`。
- `scripts/test_udp_connection.sh`：Python 3 脚本，向 UDP 14550 发一个握手再监听 15 秒，将收到的 MAVLink 报文以十六进制打印出来，便于验证 UDP 流。

使用前请将脚本设为可执行：

```bash
chmod +x build.sh bridge_control.sh scripts/test_udp_connection.sh
```
