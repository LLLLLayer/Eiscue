# 开发板连接与烧录

正常 App 默认提供“蓝牙开发板”流程。使用已配置 Eiscue 蓝牙固件的 ESP32-C3
开发板，USB 接充电器或电脑供电即可，**不用插到 iPhone，不用加入开发板 Wi-Fi**。
手机继续使用平常的 Wi-Fi 或蜂窝网络访问模型。蓝牙负责点击和键盘输入，Apple
ReplayKit 屏幕共享负责观察；这条路径不使用 VPN、RemotePairing 配对文件或 DDI。
升级安装会保留原有连接偏好，需要时在设备页改选“蓝牙开发板”。

**当前进度（2026-10-12）：** 普通 App 的蓝牙连接、系统屏幕共享、四点点击与
文字输入校验、Agent 工具接入已开发。新版 0.2 固件已完成构建和真机烧录读回；
修复重连时订阅恢复顺序后，能力查询返回绝对指针和键盘均已订阅，App 显示已连接。
指定手机已通过 ReplayKit 有效画面、四点实际点击与中文文字检查，App 显示已就绪。
蓝牙滑动、完整跨 App 的 Agent 任务和长时间后台共享仍待验收。
详见 [蓝牙普通流程验收记录](ble-production-validation-2026-10-12.md)。

较早的 0.1 蓝牙 Debug 实验仅证明数字输入、一次无害按钮点击和 Wi-Fi HTTPS；
不能当作新版坐标操作通过的证据。独立 Wi-Fi 方案已在指定样机通过控制检查；
USB NCM 尚无 S3 实板验证。所有结论均限于各自记录的硬件和系统组合。

## 蓝牙开发板连接

1. 给已刷入 [Eiscue 蓝牙固件](../Firmware/Passport-BLE/README.md) 的 ESP32-C3
   开发板供电。USB 线接充电器或电脑，**不接 iPhone**；电脑在正常运行时仅供电。
2. 手机保持平常上网的 Wi-Fi 与蓝牙开启，到「设置 → 辅助功能 → 触控 →
   辅助触控」开启辅助触控。
3. 在 Eiscue 右上角设备页选择“蓝牙开发板”，点“连接蓝牙开发板”。首次允许
   蓝牙权限，系统出现 **Eiscue BLE** 配对请求时点“配对”。无需选择配对文件。
4. 在“开启屏幕共享”步骤点击录屏图标，在系统面板中点“开始直播”。这是 Apple
   的屏幕共享授权入口，必须由用户确认。Eiscue 不录制麦克风或 App 音频；仅在
   设备任务请求观察时，将截图发送给你配置的模型服务。
5. 点“开始检查”，让 App 在专用全屏页面完成四点点击和文字输入检查。期间不要
   手动触碰、旋转或切走页面；iPad 也需要完整屏幕空间。等待“设备操作已就绪”，
   不能只凭蓝牙“已连接”开始设备任务。
6. 回到对话，点击输入框左侧“+”，开启“允许 AI 操作设备”，再描述任务。普通
   聊天默认不操作手机。需要结束观察时，在设备页点“停止屏幕共享”。

四点检查通过真实触摸回调建立并复核坐标映射，文字检查比对实际输入框内容。
重新连接、旋转屏幕、共享会话改变或失效后需重新检查。没有通过检查时，App
不会把固件确认消息当成操作成功，也不自动改用其他设备连接路径。

### 蓝牙固件与升级

构建入口为 `bash Scripts/build-passport-ble.sh`，仅构建，不打开串口或烧录。
蓝牙与当前 C3 Wi-Fi 固件共用分区布局；切换前检查真实板子与分区，只更新
`0x20000` 的 App 分区，保留完整 Flash 备份、Wi-Fi 镜像和 `0xF000` 私有配置。
芯片、Flash 容量和接线必须以实际板子为准，不能将任意 C3 / S3 固件混刷。

0.2 固件增加绝对鼠标报告和受限键盘快捷键，并带 250 ms 按住超时自动释放。
App 必须先检查实际 HID 订阅能力，再做屏幕校验。升级后固件通过标准 Service
Changed 通知请求 iOS 刷新旧描述符；若仍只发现旧报告，开发者需协助重新配对，
不能靠清空整个开发板修复。具体协议、缓存处理与构建证据见 [蓝牙固件说明](../Firmware/Passport-BLE/README.md)。

## 其他连接方案

下文保留 Wi-Fi 开发板与 USB NCM 的开发者配置说明。**使用上面的蓝牙流程不需要
执行这些配对、网络或插线步骤。** 这两条旧通道由开发板转发设备连接，屏幕和
输入使用 RemotePairing / 开发者服务；它们与蓝牙 HID + ReplayKit 是不同路径。

## 芯片与 USB 限制

当前样机的[官方硬件规格](https://github.com/FoloToy/ai-passport/blob/main/docs/hardware-design/specifications.md)
明确其芯片为 **ESP32-C3、8 MB Flash、无 PSRAM**；
[官方开发引导](https://ai-passport.folotoy.cn/en/guides/create-a-play-with-trae/)
提供开源仓库入口，[社区设备说明](https://forum.trae.cn/t/topic/180446)仅作背景参考。
板上的 USB-C 用于供电及
USB Serial/JTAG；[Espressif 官方文档](https://docs.espressif.com/projects/esp-idf/en/v5.5.3/esp32c3/api-guides/usb-serial-jtag-console.html)
说明该 USB 外设是固定硬件功能，不能改成网卡。因此，**不能通过给这块板刷固件，
实现本项目的 USB NCM 回环**。烧录工具按固件目标校验 ROM：USB `ncm` 目标
拒绝 C3；Wi-Fi `passport` 目标只接受 C3，不会将 S3 USB 镜像刷入 C3 开发板。

本项目的 [USB 固件](../Firmware/NCM-Relay/README.md) 是 **ESP32-S3**
固件，保留 actell 固定版本的 ND1 / NR1 / NL1 协议源码和许可证。构建 S3 固件
不等于 C3 已支持 USB NCM，也不等于 S3 与手机的连接已经验证成功。

没有找到在这款 C3 板上已验证、满足 NCM 数据通道的软 USB 实现。可查到的
[espusb 原作者项目](https://github.com/cnlohr/espusb) 面向 ESP8266，只有低速 USB，
作者明确不适合网络设备；它不能作为 C3 NCM 支持依据。加入可编程 USB OTG
外部控制器或另一颗 MCU 属于硬件改造，现有产品接口没有提供这样的通道。

## 给 ESP32-C3 开发板烧录 Wi-Fi 固件

[Wi-Fi 固件](../Firmware/Passport-Relay/README.md) 为 C3 / 8 MB
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

## 手机连接 Wi-Fi 开发板

以下步骤已在上述 C3 / 8 MB 样机和指定测试机上完成；其他板子仍需核对硬件及固件。
当前样机已切换到蓝牙固件，使用 Wi-Fi 方案前需恢复保存的 Wi-Fi App 分区镜像。

1. 给开发板供电，在手机「设置 → Wi-Fi」加入本机 `wifi-setup.txt` 中的网络。
2. 输入该文件里的密码；板子只提供本地连接，保持蜂窝数据开启以供模型请求使用。
3. 回到 Eiscue，在设备页选择「Wi-Fi 开发板」并连接。配对、开发者模式和 DDI
   准备仍需完成；Wi-Fi 已连接不代表手机已允许屏幕或触控服务。

固件采用 WPA2-PSK / CCMP，最多接入一台手机。板子地址 `192.168.7.1/30`，
手机通过 DHCP 获取唯一地址 `192.168.7.2`，掩码为 `255.255.255.252`。
ESP-IDF 5.5.3 不接受起止地址相同的显式租约范围，因此用 `/30` 限制默认池，
并读回确认池里只有 `.2`；检查失败就停止 AP。它不发布 DHCP 路由器或 DNS，
不设置默认路由、不提供 NAT 或互联网转发。App 仅绑定这个 Wi-Fi 接口和地址，
不会自动切换到 USB、VPN 或默认网络。

加入板子的 AP 会占用手机的 Wi-Fi，不能同时保留原公司 Wi-Fi 连接。蜂窝模型
联网、公司 VPN 的本地网络放行仍待真机验证。当前样机的 iOS 26 RemotePairing
与真实控制已经通过验证。此版本未提供板子加入公司局域网的 STA 模式。

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
2. 从选中串口读取真实芯片与 Flash 容量；S3 USB 包拒绝 C3，C3 Wi-Fi 包拒绝非
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

- Wi-Fi：2026-10-11，当前 C3 / 8 MB 样机与 iPhone 14 Pro / iOS 26.5.2 通过
  AP/DHCP、设备发现与授权、截图、横竖屏点击、旧帧拒绝、滑动、中文与表情输入、
  Home / 返回 App 和第二次连接。本地 VPN 全程断开；600 秒板端记录只有一次
  关联与租约，无断连或错误。见 [Wi-Fi 真机记录](board-validation-2026-10-11.md)。
- 蓝牙：2026-10-12，同一样机通过三次 12 位数字输入、一次真实测试按钮点击；
  禁用每次请求的蜂窝访问时，三次 Wi-Fi HTTPS 均返回 200。这是旧版 0.1 的
  [Debug 基线记录](ble-board-validation-2026-10-12.md)。新版 0.2 与普通 App 已接入，
  已通过能力查询、普通连接、共享、四点点击及中文文字检查，完整结果与待验收项见
  [普通流程验收记录](ble-production-validation-2026-10-12.md)，不能沿用旧实验结论。
- USB：S3 交叉编译、协议 / localhost 测试与原烧录工具守卫测试通过；尚无 S3
  实板烧录、USB NCM 枚举或手机控制证据。见 [固件验证表](../Firmware/NCM-Relay/README.md#validation-status-2026-10-12)。
- 持续后台任务、Wi-Fi 开发板下的蜂窝模型请求和公司 VPN 共存仍未验证。本地
  断连不等于远端服务已确认释放。其他板型与系统版本需独立验收。

App 构建、签名、安装与完整限制见 [验证记录](validation.md)。
