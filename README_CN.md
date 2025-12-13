# PX4 SkyBridge Relay（中文说明）

[![Build amd64](https://img.shields.io/github/actions/workflow/status/GrooveWJH/PX4-SkyBridge-Relay/build.yml?branch=main&label=amd64)](https://github.com/GrooveWJH/PX4-SkyBridge-Relay/actions/workflows/build.yml)
[![Build arm64](https://img.shields.io/github/actions/workflow/status/GrooveWJH/PX4-SkyBridge-Relay/build.yml?branch=main&label=arm64)](https://github.com/GrooveWJH/PX4-SkyBridge-Relay/actions/workflows/build.yml)

本项目介绍如何将伴随计算机配置为 PX4 飞控与局域网之间的透明桥接器。伴随计算机将 USB CDC（MAVLink）接口以 UDP 服务的形式暴露在网内，并将 UART 串口通过 TCP 隧道发送给远端主机，使其能够在不与飞控直接相连的前提下访问串口数据流。

## 架构

- **MAVLink 通道**：伴随计算机通过 `mavlink-routerd` 将 `/dev/ttyACM0`（PX4 USB CDC）以 UDP 服务的形式暴露在 `14550` 端口，Ground Control Station 可直接订阅来自飞控的心跳与控制信息。
- **串口到 TCP 隧道**：`/dev/ttyUSB0` 上通常承载 DDS 或 `nsh` 的原始串口数据，`scripts/bridge_control.sh`（通过 `start` 命令）利用 `socat` 将其映射到 TCP `8888`，保持字节流的透明性，供远端主机复原为伪终端。

## 依赖

```bash
git clone https://github.com/GrooveWJH/PX4-SkyBridge-Relay.git --recursive
cd PX4-SkyBridge-Relay
sudo apt update
sudo apt install git meson ninja-build pkg-config gcc g++ systemd socat
```

请确保运行时用户属于 `dialout` 组，以无需 sudo 即可打开 `/dev/ttyACM0` 与 `/dev/ttyUSB0`。

## 构建项目所需的可执行文件

仓库根目录提供 `build.sh`，一次性完成所有第三方依赖（`mavlink-routerd`、`ser2net`、`remserial` 等）的编译，并将最终二进制复制到 `build/bin/`：

```bash
./build.sh
ls build/bin
```

如更新了子模块或切换新平台，请重新执行该脚本。`scripts/bridge_control.sh` 默认查找 `build/bin/mavlink-routerd`，`scripts/ser2net_bridge.sh` 也会使用 `build/bin/ser2net`。

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
- `[UartEndpoint px4_usb]`：针对 PX4 USB CDC 设备定义了设备路径和波特率。若需通过路由暴露其他串口，可复制该块并修改属性。
- `[UdpEndpoint qgc_lan]`：以服务器模式在所有接口监听 14550 端口，等待地面站建立连接。首次收到数据后会将 MAVLink 包返回发送者地址。
- `/dev/ttyUSB0` 的处理由 `scripts/bridge_control.sh` 内的 `socat` 完成（通过 `start` 命令）：它把原始 UART 流保持不变地转发到 TCP 8888，局域网内的其他主机可以根据需要将这一路由封装成 UDP，或者在本地创建伪终端再供 DDS/nsh 使用；而 MAVLink 路由器继续负责 `/dev/ttyACM0` 的 UDP 服务。

你可以在该文件中添加更多 `UdpEndpoint`/`TcpEndpoint` 配置来支持多客户端或 TCP 连接；修改后重新启动 `scripts/bridge_control.sh start` 即可生效。

## 伴随计算机端（服务端）

1. 按需修订 `/etc/mavlink-router/main.conf`（可参考 `config/main.conf`）。
2. 通过 `scripts/bridge_control.sh start` 启动：
   - 启动 `mavlink-routerd`（依据配置文件或内联端点）。
   - 以后台方式运行 `socat`，将 `/dev/ttyUSB0` 映射到 TCP `8888`。
3. 若需在系统启动时自动运行，可将 `systemd/skybridge.service` 拷贝到 `/etc/systemd/system`，调整路径后启用该服务。

日志说明：
- `mavlink-router` 的日志由配置文件中 `Log` 选项控制，也可以通过命令行参数定向日志。
- `socat` 使用 `nohup` 后台运行并将输出重定向到 `/dev/null`，如需记录可自行封装。

## 远端访问（DDS）

在需要 PX4 UART 数据的远端主机上：

1. 运行以下命令，创建指向伴随计算机的虚拟串口（替换 `<COMPANION_IP>` 为实际地址）：

```bash
socat PTY,link=/tmp/ttyVIRT_DDS,raw,echo=0,waitslave TCP:<COMPANION_IP>:8888,tcp-nodelay
```

其中 `waitslave` 可确保 PTY 被 Agent 打开后再开始传输，`tcp-nodelay` 则与伴随端的隧道设置一致，以最大程度减少缓冲导致的 XRCE-DDS 帧破碎。

2. 启动 `MicroXRCEAgent` 或其他 DDS 客户端，指向 `/tmp/ttyVIRT_DDS`：

```bash
MicroXRCEAgent serial --dev /tmp/ttyVIRT_DDS -b 921600
```

当 DDS 客户端退出后，`socat` 也会结束，从而断开 TCP 隧道。

3. 在启动地面站前可以先运行 `scripts/test_udp_connection.sh` 来确认 MAVLink UDP 14550 在本机或远端是否有流量（脚本会先发送握手，监听 15 秒并输出抓到的报文片段）。

## Systemd 集成（可选）

将 `systemd/skybridge.service` 复制到 `/etc/systemd/system`，根据所在路径调整 `WorkingDirectory` 与 `ExecStart`，然后启用服务：

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now skybridge
```

该单元配置为 forking 模式，以便管理脚本内启动的后台 `socat` 进程。

## 运行须知

- 无线局域网的延迟或抖动会影响 DDS，因此建议使用有线或 5GHz 网络。
- 建议在路由器中为伴随计算机分配静态 IP，以便远端主机使用固定 `<COMPANION_IP>`。
- 添加用户到 `dialout` 后请重新登录或重启以确保权限生效。

## 脚本说明

- `build.sh`：统一构建第三方依赖，并把生成的可执行文件放在 `build/bin/`。
- `scripts/bridge_control.sh`：通过 `start|stop|status|toggle|restart` 管理 `mavlink-routerd` 和 `socat`，并打印当前进程状态。
- `scripts/ser2net_bridge.sh`：在伴随计算机上启动/停止 RFC2217 隧道，让 `/dev/ttyUSB0` 可被远端 remserial 使用。
- `scripts/test_udp_connection.sh`：Python 3 脚本，向 UDP 14550 发一个握手再监听 15 秒，将收到的 MAVLink 报文以十六进制打印出来，便于验证 UDP 流。

使用前请将脚本设为可执行：

```bash
chmod +x build.sh scripts/bridge_control.sh scripts/ser2net_bridge.sh scripts/test_udp_connection.sh
```
