# 开发板连接与烧录

开发板方案的目标是通过外接 USB 网卡传输设备控制数据，让 Eiscue 不再占用
手机的 VPN 配置。板子只负责连接，Agent、配对身份和设备操作逻辑仍在 App / Kit 中。
公司 VPN 是否允许本地网络仍取决于它的路由策略，需要在实际手机上验证。

## TRAE Passport 的硬件限制

TRAE 中文社区的[联名活动说明](https://forum.trae.cn/t/topic/180446)将 TRAE Passport
关联到 FoloToy AI Passport；社区帖子用于核对产品名称，芯片规格以厂商资料为准。
[FoloToy 官方 TRAE 开发引导](https://ai-passport.folotoy.cn/en/guides/create-a-play-with-trae/)
也指向其官方开源仓库。
[FoloToy 官方规格](https://github.com/FoloToy/ai-passport/blob/main/docs/hardware-design/specifications.md)
明确其芯片为 **ESP32-C3、8 MB Flash、无 PSRAM**。板上的 USB-C 用于供电及
USB Serial/JTAG；[Espressif 官方文档](https://docs.espressif.com/projects/esp-idf/en/v5.5.3/esp32c3/api-guides/usb-serial-jtag-console.html)
说明该 USB 外设是固定硬件功能，不能改成网卡。因此，**不能通过给这块板刷固件，
实现本项目的 USB NCM 回环**。烧录工具读取 ROM 芯片后会拒绝 C3，保留原固件。

本项目的 [`Firmware/NCM-Relay`](../Firmware/NCM-Relay/README.md) 是 **ESP32-S3**
固件，保留 actell 固定版本的 ND1 / NR1 / NL1 协议源码和许可证。构建 S3 固件
不等于 TRAE Passport 已经支持，也不等于 iPhone 设备操作已经验证成功。

没有找到在这款 C3 板上已验证、满足 NCM 数据通道的软 USB 实现。可查到的
[espusb 原作者项目](https://github.com/cnlohr/espusb) 面向 ESP8266，只有低速 USB，
作者明确不适合网络设备；它不能作为 C3 NCM 支持依据。加入可编程 USB OTG
外部控制器或另一颗 MCU 属于硬件改造，现有产品接口没有提供这样的通道。

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
2. 从选中串口读取真实芯片与 Flash 容量，拒绝 C3、容量不足或已开启加密/安全启动的板。
3. 将**完整原 Flash**备份到 `.build/board-backups/时间戳/`，对照 ROM 的 Flash
   MD5 校验读回内容。目录权限为 `0700`，文件为 `0600`；不提交备份。
4. 确认 USB 身份没有变化，再写入三段镜像并执行 Flash 读回验证。

备份/校验失败时不会写入固件。烧录不使用 `erase_flash`，不写 eFuse。
若需恢复原 Flash，使用已确认的同一块板、原备份和 Espressif `write_flash`
工具；完整备份可能包含设备专属身份，不能上传到 GitHub 或发给别人。

## 接到手机与连接诊断

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

## TRAE Passport 的无线方案评估

ESP32-C3 [官方 Wi-Fi 文档](https://docs.espressif.com/projects/esp-idf/en/v5.5.3/esp32c3/api-reference/network/esp_wifi.html)
支持 STA、AP 和 AP+STA，从芯片能力上可以研究 TCP 回转，但它属于独立的无线
传输适配，当前 USB NCM 固件与 App 网卡绑定规则不能直接用在 Wi-Fi 上。

AP 模式需要手机连板子的 Wi-Fi，可能离开公司内网 Wi-Fi；STA 模式则要求板子
与手机在同一局域网，并新增安全配网、手机地址发现与身份绑定。无论哪种方式，
还要实测 iOS Wi-Fi 开发者服务的发现/准入、后台数据与公司 VPN 的本地路由。
当前没有这些证据，也没有刷写无线实验固件，因此不承诺 TRAE Passport 已实现
设备控制或公司 VPN 共存。

## 已完成的验证与待实测项

2026-10-11：S3 交叉编译、协议/localhost 测试和烧录工具守卫测试通过。当前 Mac
USB registry 没有开发板，USB 串口候选为空；没有进行物理板子备份、烧录、NCM
枚举或公司 VPN 共存测试。完整结果见 [固件验证表](../Firmware/NCM-Relay/README.md#validation-status-2026-10-11)。
