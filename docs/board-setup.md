# 开发板连接与烧录

开发板方案提供 USB 网卡和独立 Wi-Fi 两种传输，让 Eiscue 不再占用手机的 VPN
配置。S3 使用 USB NCM；TRAE Passport 的 C3 使用独立 Wi-Fi AP。板子只负责
连接，Agent、配对身份和设备操作逻辑仍在 App / Kit 中。
公司 VPN 是否允许本地网络仍取决于它的路由策略，需要在实际手机上验证。

**当前进度（2026-10-11）：** 用户的板子已由 ROM 确认为 **ESP32-C3 / 8 MB**；
完整原 Flash 备份及 ROM MD5 校验完成。首次刷写后的运行时审查发现 DHCP 服务
遗漏显式启动；修复后的 App 分区已通过 `write_flash`、`verify_flash`，保留原
备份和私有 Wi-Fi 配置。实板启动日志确认 AP/relay 就绪并等待手机。手机接入、
RemotePairing 和实际屏幕/触控尚待实测。无线 App 无签名及签名 Release 构建、
深度签名校验均通过，已覆盖安装并正常启动到指定 iPhone 14 Pro；不能把固件
和 App 启动成功当作设备控制完成。

## TRAE Passport 的硬件限制

TRAE 中文社区的[联名活动说明](https://forum.trae.cn/t/topic/180446)将 TRAE Passport
关联到 FoloToy AI Passport；社区帖子用于核对产品名称，芯片规格以厂商资料为准。
[FoloToy 官方 TRAE 开发引导](https://ai-passport.folotoy.cn/en/guides/create-a-play-with-trae/)
也指向其官方开源仓库。
[FoloToy 官方规格](https://github.com/FoloToy/ai-passport/blob/main/docs/hardware-design/specifications.md)
明确其芯片为 **ESP32-C3、8 MB Flash、无 PSRAM**。板上的 USB-C 用于供电及
USB Serial/JTAG；[Espressif 官方文档](https://docs.espressif.com/projects/esp-idf/en/v5.5.3/esp32c3/api-guides/usb-serial-jtag-console.html)
说明该 USB 外设是固定硬件功能，不能改成网卡。因此，**不能通过给这块板刷固件，
实现本项目的 USB NCM 回环**。烧录工具按固件目标校验 ROM：USB `ncm` 目标
拒绝 C3；无线 `passport` 目标只接受 C3，不会将 S3 USB 镜像刷入 Passport。

本项目的 [`Firmware/NCM-Relay`](../Firmware/NCM-Relay/README.md) 是 **ESP32-S3**
固件，保留 actell 固定版本的 ND1 / NR1 / NL1 协议源码和许可证。构建 S3 固件
不等于 TRAE Passport 已经支持，也不等于 iPhone 设备操作已经验证成功。

没有找到在这款 C3 板上已验证、满足 NCM 数据通道的软 USB 实现。可查到的
[espusb 原作者项目](https://github.com/cnlohr/espusb) 面向 ESP8266，只有低速 USB，
作者明确不适合网络设备；它不能作为 C3 NCM 支持依据。加入可编程 USB OTG
外部控制器或另一颗 MCU 属于硬件改造，现有产品接口没有提供这样的通道。

## 给 Passport 烧录无线固件

[`Firmware/Passport-Relay`](../Firmware/Passport-Relay/README.md) 为 C3 / 8 MB
提供独立 WPA2 Wi-Fi AP，复用 S3 固件的 ND1 / NR1 / NL1 协议，不模拟 USB 网卡。
安装 ESP-IDF v5.5.3 与 `esp32c3` RISC-V 工具链后，在项目根目录执行：

```sh
export IDF_PATH=/path/to/esp-idf-v5.5.3
export IDF_TOOLS_PATH=/path/to/espressif-tools
bash Scripts/build-passport-firmware.sh
source "$IDF_PATH/export.sh"
python Scripts/board-firmware.py inspect
python Scripts/board-firmware.py probe --target passport \
  --port /dev/cu.REPLACE_WITH_BOARD_PORT
```

构建脚本已包含打包，不打开串口、不烧录。若只需重新打包已有构建：

```sh
python Scripts/board-firmware.py package --target passport \
  --build-dir .build/passport-relay-firmware
python Scripts/board-firmware.py verify-package \
  --package .build/passport-relay-firmware/release/eiscue-passport-relay-1.0.0
python Scripts/board-firmware.py flash \
  --port /dev/cu.REPLACE_WITH_BOARD_PORT \
  --package .build/passport-relay-firmware/release/eiscue-passport-relay-1.0.0
```

`flash` 从已校验的固件包读取目标，不另传 `--target`。端口必须来自 `inspect`
的实际 USB 串口候选，不能照抄占位符。工具先备份完整原 Flash 并核对 ROM MD5，
然后生成每块板独有的 `Eiscue-xxxxxx` SSID 和强随机密码，写入独立 NVS 配置区，
最后执行 `write_flash`、`verify_flash`。SSID 和密码保存在本机
`.build/board-backups/时间戳/wifi-setup.txt`；备份目录权限为 `0700`，文件为
`0600`。固件包不包含实际密码，备份、Wi-Fi 配置及二维码内容都不要提交或公开。

## 手机连接 Passport

无线版本已安装到指定测试机，以下连接步骤仍需在手机上验收。

1. 给开发板供电，在手机「设置 → Wi-Fi」加入本机 `wifi-setup.txt` 中的网络。
2. 输入该文件里的密码；板子只提供本地连接，保持蜂窝数据开启以供模型请求使用。
3. 回到 Eiscue，在设备页选择「无线开发板」并连接。配对、开发者模式和 DDI
   准备仍需完成；Wi-Fi 已连接不代表手机已允许屏幕或触控服务。

固件采用 WPA2-PSK / CCMP，最多接入一台手机。板子地址 `192.168.7.1/30`，
手机通过 DHCP 获取唯一地址 `192.168.7.2`，掩码为 `255.255.255.252`。
ESP-IDF 5.5.3 不接受起止地址相同的显式租约范围，因此用 `/30` 限制默认池，
并读回确认池里只有 `.2`；检查失败就停止 AP。它不发布 DHCP 路由器或 DNS，
不设置默认路由、不提供 NAT 或互联网转发。App 仅绑定这个 Wi-Fi 接口和地址，
不会自动切换到 USB、VPN 或默认网络。

加入板子的 AP 会占用手机的 Wi-Fi，不能同时保留原公司 Wi-Fi 连接。蜂窝模型
联网、公司 VPN 的本地网络放行以及 iOS 26 RemotePairing 服务的可用性仍待
真机验证。此版本未提供板子加入公司局域网的 STA 模式。

开发时可在 Mac 加入同一 Wi-Fi 后做只读诊断；`enX` 换成实际 Wi-Fi 接口：

```sh
python Scripts/board-firmware.py check-link --target passport --interface enX
```

该命令绑定 Wi-Fi 接口和 `.2/30`，只发送 `STATUS`；ND1 回复不能证明手机控制成功。

## 支持的 USB 硬件

固件要求 **ESP32-S3、至少 4 MB Flash、连接到芯片 GPIO19/20 的原生 USB OTG
接口**。应根据板子的官方原理图确认 USB 口，而不是根据包装名称判断。
[Espressif S3 USB 文档](https://docs.espressif.com/projects/esp-idf/en/v5.5.3/esp32s3/api-reference/peripherals/usb_device.html)
说明双 USB 开发板通常有一个原生 USB 口和一个 USB-UART 调试口：

- 原生 USB 口供手机识别为 NCM 网卡，运行时手机是 USB Host、板子是 USB Device。
- USB-UART 口可供电脑烧录和查看日志。它不会向手机暴露 NCM 网卡。
- 烧录后运行不需要一直连接电脑。只有单个原生 USB 口的板子刷入 NCM 后可能
  不再出现串口，再刷时需要按该板官方说明进入 ROM 下载模式。

iPhone 14 Pro 使用 Lightning 接口，需要提供 **USB Host 能力**的适配器，普通
充电线不能替代。[Apple USB 3 相机转换器官方说明](https://support.apple.com/en-ae/111811)
支持部分 USB 以太网设备，并提供外接供电方式。它不是对本固件 NCM 枚举的保证；
Lightning 适配器、供电和这块具体 S3 板仍需要一起实测。

## 给支持的 S3 板烧录

先安装 ESP-IDF v5.5.3 与 esp32s3 工具链，然后从项目根目录执行：

```sh
export IDF_PATH=/path/to/esp-idf-v5.5.3
export IDF_TOOLS_PATH=/path/to/espressif-tools
bash Scripts/build-board-firmware.sh
bash Scripts/test-board-firmware.sh
source "$IDF_PATH/export.sh"
python Scripts/board-firmware.py inspect
```

`inspect` 只读取系统 USB 与串口列表，不打开端口、不重置或烧录任何设备。只有
`serial_candidates` 中的明确 USB 串口才能用于下一步。USB VID/名称不能证明
芯片或板型；`probe` 读取 ROM 进一步确认，可能重置选中的开发板：

```sh
python Scripts/board-firmware.py probe --port /dev/cu.REPLACE_WITH_BOARD_PORT
python Scripts/board-firmware.py verify-package \
  --package .build/ncm-relay-firmware/release/eiscue-ncm-relay-1.0.0
python Scripts/board-firmware.py flash \
  --port /dev/cu.REPLACE_WITH_BOARD_PORT \
  --package .build/ncm-relay-firmware/release/eiscue-ncm-relay-1.0.0
```

不要照抄占位端口。烧录流程会：

1. 校验固件包的芯片、版本、镜像长度和 SHA-256。
2. 从选中串口读取真实芯片与 Flash 容量；S3 USB 包拒绝 C3，Passport 包拒绝非
   C3。两种包均拒绝容量不足或已开启加密/安全启动的板。
3. 将**完整原 Flash**备份到 `.build/board-backups/时间戳/`，对照 ROM 的 Flash
   MD5 校验读回内容。目录权限为 `0700`，文件为 `0600`；不提交备份。
4. 确认 USB 身份没有变化，再写入三段镜像并执行 Flash 读回验证。

备份/校验失败时不会写入固件。烧录不使用 `erase_flash`，不写 eFuse。
若需恢复原 Flash，使用已确认的同一块板、原备份和 Espressif `write_flash`
工具；完整备份可能包含设备专属身份，不能上传到 GitHub 或发给别人。

## USB S3 接到手机与连接诊断

板子为 `192.168.7.1/24`，手机 USB 以太网接口应为 `192.168.7.2/24`。
首次接入后，在系统“设置 → 以太网 → 该 USB 网卡”配置手动 IPv4：

- IP 地址：`192.168.7.2`
- 子网掩码：`255.255.255.0`
- 路由器、DNS：留空

固件不提供 DHCP、不设置默认路由、不做 NAT，不负责转发公司的网络流量。
App 的开发板入口会使用该以太网接口绑定 `.2`，连接板子 `.1:28767`。
手机的配对和系统开发者准备仍是另一项要求；诊断成功不能代替它。

在 Mac 上验证 USB 网卡时，同样先给对应 USB Ethernet 接口设置 `.2/24`，再执行
以下只读诊断。`enX` 必须换成实际 USB 网卡，不能使用 Wi-Fi 或 VPN 接口：

```sh
python Scripts/board-firmware.py check-link --interface enX
```

这条命令同时绑定网卡与源地址，只发送 `STATUS`，要求收到 diagnostic-only ND1
回复。它不调用截图、点击或其他手机操作，不把传输层 ACK 显示成设备控制成功。

## 已完成的验证与待实测项

2026-10-11：S3 交叉编译、协议/localhost 测试和原烧录工具守卫测试通过。当天
早期 USB registry 中没有板子或串口候选，这是当时的阻塞记录。用户随后接入
Passport，ROM 已确认 C3 / 8 MB，完整原 Flash 备份与 ROM MD5 校验完成，
无线初版已通过实际写入和读回校验。DHCP 显式启动遗漏已修复，后续仅更新 App
分区并通过写入/读回校验，原备份和私有配置保留。实板启动日志在 352 ms 显示
`Private WPA2 AP ready; waiting for one phone` 和 ND1/NR1 relay 等待命令。

C3 固件、App/Kit 无线入口和完整无签名 Release App 已编译通过。此前签名因
钥匙串授权失败；用户自行解锁登录钥匙串后，使用既有证书完成签名 Release
构建和深度签名校验，正常 App 已覆盖安装并启动到指定 iPhone 14 Pro，没有
安装额外 UI Test Runner。手机关联、DHCP `.2` 租约、手机 ND1、RemotePairing、
屏幕/触控、断连撤销、蜂窝联网和公司 VPN 共存均待实测。S3 仍没有实板
烧录或 USB NCM 枚举证据。完整结果见 [固件验证表](../Firmware/NCM-Relay/README.md#validation-status-2026-10-11)
和 [验证记录](validation.md)。
