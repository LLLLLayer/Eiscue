# Eiscue 不依赖 Mac 的设备 Agent 运行方案

更新日期：2026-10-12。适用范围：Eiscue 的 iOS / iPadOS 26+ App。实现基线：`bb0bf79`；本项目实机证据限于 iPhone 14 Pro / iOS 26.5.2 与 ESP32-C3 / 8 MB 样机。本文补充 [方案 v0.4](design-v0.4.md)，新增 S3 USB 键鼠候选路线，并统一解释 Mac、电脑、VPN 和 XCTest 的关系。

## 先看结论

我们的目标是：Agent 的任务编排和设备操作在 iPhone App 内完成，日常运行不连接 Mac，也不让电脑持续代发指令。模型仍可以通过手机正常的 Wi-Fi / 蜂窝网络调用云端 API；“手机内运行 Agent”不等于“在手机或开发板上运行大模型”。

建议按以下顺序推进：

- **当前可试用：C3 蓝牙键鼠 + ReplayKit。** 不占用 VPN 和手机 Wi-Fi，不需要开发者配对文件或 DDI。普通 App 已接入，真实点击和中文输入检查通过；完整跨 App Agent 任务仍待验收。
- **优先验证的有线候选：S3 USB 键鼠 + ReplayKit。** 手机通过蓝牙向 S3 发指令，S3 通过 USB 执行键鼠输入。目标仍是手机独立运行、不使用 VPN / DDI；需要新增固件和真机适配，当前不能直接使用。
- **保留的软件路线：开发者服务 + XCTest。** 使用已有 VPN 通道，或由开发板提供 USB 网卡 / Wi-Fi 通道。控制逻辑可以在手机内运行，但首次开发环境准备及重启恢复较复杂。
- **iCTRL：同属 XCTest 技术体系的候选实现。** 主要研究独立 Runner、界面元素树、诊断和手机内 DDI 准备，不因为它使用了回环机制而重复开发一套 VPN。

`esp32-iphone-agent` 原版可以在 Linux 上运行，因而不限定 Mac；但需要电脑持续接收画面并运行 Agent。它是 USB 键鼠的参考，不直接满足“只有手机独立运行”的目标。[项目原版说明](https://github.com/onehumanbeing/esp32-iphone-agent/blob/27f36ce0f5d2d520ad5a45a0eea6eb99abbbe6f7/README.md)

## “不依赖 Mac”需要分清三件事

| 判断 | 含义 | 本项目的要求 |
| --- | --- | --- |
| 日常不需要 Mac | 准备完成后，不连接 Mac 也能执行任务 | 目标必须满足；电脑不能持续代发控制指令。 |
| 日常不需要任何电脑 | 任务编排、画面处理与动作都由手机 App 承担 | 首选手机内 Agent；Linux 上的电脑 Agent 单独列为参考。 |
| 首次也不需要电脑 | 下载 App、准备开发环境、开发板刷固件全部无需电脑 | 当前开发交付尚未覆盖；不能由“日常免 Mac”推导出来。 |

本项目当前 App 通过 Xcode 开发签名安装，开发板首次烧录也在电脑上完成。预装 App、预刷固件可以减少最终用户准备步骤，但尚未建立这样的分发流程。HID 路线不需要签名 XCTest Runner，并不免除 Eiscue App 本身的安装要求；当前包含开发者后端的二进制也不能直接视为已具备 App Store 分发条件。

## 全部路线对照

“可独立运行”下表指架构与准备完成后的目标，不等于完整任务已经验收。每条路线的当前证据单独列出。

| 路线 | Agent 与日常电脑依赖 | 读屏与输入 | VPN 使用 | 当前状态 |
| --- | --- | --- | --- | --- |
| C3 蓝牙键鼠 | 手机；日常无需电脑，板子只需供电 | ReplayKit + BLE HID | 不使用 | 已接普通 App；四点真实点击与中文输入通过。 |
| S3 蓝牙键鼠 | 手机；日常无需电脑 | ReplayKit + BLE HID | 不使用 | 芯片支持；现有 C3 固件不能混刷 S3，需适配验证。 |
| S3 USB 键鼠候选 | 手机；日常无需电脑 | ReplayKit + BLE 指令 → USB HID | 不使用 | 本项目尚未实现；参考项目原版依赖电脑和 Wi-Fi。 |
| 内置 VPN + XCTest | 手机；准备完成后目标为独立运行 | Instruments 截图 + App 内 XCTest | 使用内置 Packet Tunnel | 扩展与后端已实现；当前完整 VPN 组合尚未单独验收。 |
| C3 Wi-Fi 开发板 + XCTest | 手机；板子运行时只需供电 | 转发开发者服务，复用 Instruments / XCTest | 不使用 | 基础动作闭环通过；当前热点占用手机 Wi-Fi，模型互联网出口待验收。 |
| S3 USB 网卡 + XCTest | 手机；日常无需电脑，板子接手机 | USB NCM 转发开发者服务 | 不使用 | 固件已构建；无 S3 实板、手机枚举与控制验收。 |
| iCTRL + 手机内 Agent | 手机 Agent 与独立 Runner；日常目标无需电脑 | Runner 的 XCUITest、截图、元素树/OCR | 手机内 DDI 准备使用外部 LocalDevVPN；日常关闭后续跑待验证 | 已研究固定源码，未集成或在本项目实测。 |
| esp32-iphone-agent 原版 | Mac 或 Linux 电脑；需要持续运行 | AirPlay → 电脑；Wi-Fi 指令 → S3 USB HID | 不使用 | 源码已研究；不是手机独立运行实现。 |

当前代码状态与实机记录见 [蓝牙普通流程验收](ble-production-validation-2026-10-12.md)、[Wi-Fi 开发板验收](board-validation-2026-10-11.md)、[S3 NCM 固件](../Firmware/NCM-Relay/README.md)。没有任何路线完成公司 VPN 共存的全面验收；“不启动 Eiscue VPN”不能写成“与任意公司 VPN 一定兼容”。

当前 C3 样机运行蓝牙固件，恢复 Wi-Fi 路线需要切换到保存的 Wi-Fi 镜像，两者不同时运行。不同芯片的固件不能混刷；S3 新路线不会自动出现在当前已安装版本中。

## 两类控制机制，三种读屏方式

### HID：把开发板当鼠标和键盘

蓝牙 HID 和 USB HID 都让 iOS 识别一个外部输入设备，通过辅助触控执行指针操作。它们不是 XCTest，也不依赖 DDI。App 仍需要知道输入是否真正落到正确位置，并在动作后重新读屏确认结果。

当前 C3 路线：

```text
读屏：iPhone 屏幕 → ReplayKit 扩展 → 手机 App / Agent
输入：手机 App / Agent → 蓝牙指令 → C3 → 蓝牙 HID → 同一台 iPhone
```

拟验证的 S3 USB 键鼠路线：

```text
读屏：iPhone 屏幕 → ReplayKit 扩展 → 手机 App / Agent
输入：手机 App / Agent → 蓝牙指令 → S3 → USB HID → 同一台 iPhone
```

第二条是 Eiscue 的适配设计，不是 `esp32-iphone-agent` 已经提供的手机实现。参考项目原版以电脑的 Python 服务发送 Wi-Fi TCP 指令，S3 以相对鼠标报告和键盘报告输入手机；改为手机蓝牙指令后，仍需实现并验证 USB 枚举、坐标映射、中文粘贴、停止释放及两条链路的断开恢复。[参考固件](https://github.com/onehumanbeing/esp32-iphone-agent/blob/27f36ce0f5d2d520ad5a45a0eea6eb99abbbe6f7/hardware/hid_bridge/hid_bridge.ino)

HID 当前以屏幕像素和视觉定位为主。按钮元素树、应用列表和启动 App 不是换成 S3 后自动获得的能力；C3 蓝牙版当前也未向 Agent 开放 Home、应用列表或应用启动。

### 开发者服务：通过 XCTest 执行操作

我们在 iOS 26 上，通过 Instruments 服务截图，在主 App 内建立自有 XCTest 会话执行点击、滑动、文字和 Home；应用查询与启动由相应开发者服务提供。VPN、USB NCM 网卡和 Wi-Fi 开发板只负责提供连接通道，三者复用同一个控制后端。[当前后端代码](../Vendor/DeviceBackend/Sources/PhoneAgentNCM/NativeDeveloperServices.swift)

```text
手机 App / Agent → VPN 或开发板网络通道 → 设备开发者服务
                                             ├─ Instruments：截图
                                             └─ XCTest：触控与输入
```

iCTRL 同样基于 XCTest，主要差别是控制放在独立 Runner，并用本机 HTTP RPC 提供给手机 Agent。它不是一种比 XCTest 更独立的底层输入机制；它的 Runner 也不自动解决宿主 Agent 的后台运行问题。[iCTRL 机制说明](https://github.com/OpenMinis/iCTRL/blob/9fd0a7cc20819a1612f7d62ffbec5989d23f018e/README.md#how-it-works)

### 三种读屏的用途

| 方式 | 画面送到哪里 | 需要用户做什么 | 适合的路线 |
| --- | --- | --- | --- |
| ReplayKit | 手机内，扩展把最新帧提供给 App | 在系统面板开启共享；停止、暂停或画面失效时停止操作 | 当前蓝牙与拟开发的 USB HID。 |
| Instruments | 经已认证开发者连接取得截图 | 完成配对、开发者环境与自动化授权 | VPN / USB NCM / Wi-Fi 的 XCTest 路线。 |
| AirPlay + UxPlay | 画面投到电脑，由电脑处理 | 开启屏幕镜像；保持电脑接收程序运行 | esp32-iphone-agent 原版。 |

最初的 Eiscue VPN 路线没有使用 ReplayKit；是在新增蓝牙后端时才加入 ReplayKit。两种后端保留各自的画面来源。当前 ReplayKit 是本地屏幕共享，并不自行向外部直播；Agent 请求截图时，才把画面发给用户配置的模型服务。[ReplayKit 实现](../Apps/EiscueBroadcast/SampleHandler.swift)、[AirPlay 参考实现](https://github.com/onehumanbeing/esp32-iphone-agent/blob/27f36ce0f5d2d520ad5a45a0eea6eb99abbbe6f7/server/hidagent/screen.py)

## 首次准备、日常运行与重启恢复

| 路线族 | 首次准备 | 日常任务 | 重启或断开后 |
| --- | --- | --- | --- |
| C3 蓝牙 HID | 安装 App、给板子刷固件、系统蓝牙配对、开启辅助触控 | 板子供电，开启 ReplayKit，共享与操作检查通过后发任务 | 重新连接、重新共享并检查；不生成开发者配对文件。 |
| S3 USB HID 候选 | 安装 App、适配固件、正确 USB 接口/适配器、辅助触控、蓝牙命令通道 | 手机运行 Agent，USB 执行输入；具体步骤须实测后确定 | 检查 USB 与蓝牙连接、共享及坐标；不能重放断开前未知送达的动作。 |
| Eiscue 开发者服务 | 当前 iOS 26 需首次 USB 身份初始化、开发者模式、DDI 与系统自动化授权；现有电脑工具在 Mac 验证 | 选 VPN、USB NCM 或 Wi-Fi 通道，手机执行 Agent；无需电脑持续代发指令 | 检查身份和 DDI；重启后的准备恢复尚未形成完整手机内流程。 |
| iCTRL 软件候选 | 分别签名安装 App / Runner、准备开发者配对记录与 DDI；README 的 SideStore 初装使用电脑 | 启动 Runner，手机 Agent 访问本机 RPC；无开发板 | 重启后重新挂载 DDI、启动 Runner；侧载签名需按所用方式续期。 |
| esp32-iphone-agent 原版 | 电脑刷 S3、安装 UxPlay 与 Python 服务、配置网络和模型 | 电脑一直运行；手机开启 AirPlay、辅助触控并连接 S3 | 恢复电脑接收、网络及指针校准；锁屏会停止镜像。 |

iCTRL 的手机内 DDI 准备仍使用 LocalDevVPN 和配对文件。所研究固定版的导入器按 Lockdown 记录校验，挂载器却按 RemotePairing 记录读取，存在格式衔接问题；这是静态审查结论，未在手机复现。关闭准备 VPN 后继续控制、重启恢复和续签要分别验证，不能统一宣称“首次到日常完全免电脑”。[导入校验](https://github.com/OpenMinis/iCTRL/blob/9fd0a7cc20819a1612f7d62ffbec5989d23f018e/iCTRLApp/DDI/PairingFileStore.swift#L74-L92)、[挂载读取](https://github.com/OpenMinis/iCTRL/blob/9fd0a7cc20819a1612f7d62ffbec5989d23f018e/iCTRLApp/DDI/DDIMounter.swift#L240-L264)

App 的安装签名、开发者服务的配对身份、系统蓝牙配对和 Agent 的模型配置是四件不同的事。向导应按所选路线只展示必要步骤，不能让 HID 用户寻找开发者配对文件。

## S3 比 C3 增加的能力

S3 的关键增量是可编程 USB，可作为 USB HID 或 USB NCM；C3 的内置 USB 是固定 Serial/JTAG，不能刷成这些设备类型。C3 已能提供蓝牙输入，换成 S3 不会自动增加手机权限，也没有现成证据证明蓝牙操作更快或更准。[C3 USB 限制](https://docs.espressif.com/projects/esp-idf/en/v5.5.3/esp32c3/api-guides/usb-serial-jtag-console.html)、[S3 USB 能力与示例](https://docs.espressif.com/projects/esp-idf/en/v5.5.3/esp32s3/api-reference/peripherals/usb_device.html)

| 有线用途 | S3 USB HID | S3 USB NCM |
| --- | --- | --- |
| 手机把板子当什么 | 鼠标和键盘 | 网卡 |
| 操作由谁执行 | 外部输入设备 + 辅助触控 | 开发者服务 + XCTest |
| 如何读屏 | 我们拟保留 ReplayKit | Instruments |
| 是否需要 DDI / 开发者身份 | 不需要 | 需要 |
| 是否使用 VPN | 不使用 | 不使用 |
| 本项目进度 | 设计候选，尚未实现 | 固件已构建，尚无实板验收 |

两条路线都要求板子的原生 USB 数据口；某些 S3 板的 USB-UART 口不能提供上述功能。指定 iPhone 14 Pro 使用 Lightning，还需要具有 USB Host 能力的转换器及适当供电。Apple 支持部分 USB 外设不等于已经证明本项目固件兼容；USB-C 手机的线材和供电组合也需验证。[硬件要求](board-setup.md#支持的-usb-硬件)、[Apple 转换器说明](https://support.apple.com/en-us/111811)

## 开源项目的采用边界

| 项目与研究版本 | 可参考内容 | 对 Eiscue 的作用 |
| --- | --- | --- |
| esp32-iphone-agent · 27f36ce | MIT；USB HID、相对指针纠偏、AirPlay 读屏、规划与执行循环 | 优先参考 USB 输入和指针反馈；不直接搬电脑服务作为手机 Agent。 |
| Pilot · fd6b652 | 当前源码为手机直接 BLE GATT + HID + ReplayKit；固定版未找到明确 LICENSE | 验证同类架构思路，不复制授权不明的实现。 |
| actell · 032864e | 已集成的开发者协议后端，GPL；Eiscue 补充 iOS 26 自有 XCTest 会话 | 保留软件控制后端；不把上游当前 iOS 27 要求误写成本项目的支持范围。 |
| iCTRL · 9fd0a7c | 当前 Apache-2.0；独立 Runner、RPC、元素树/OCR、DDI 准备 | 候选后端与开发环境研究；本项目尚未安装或集成。 |

来源：[USB HID 项目](https://github.com/onehumanbeing/esp32-iphone-agent/tree/27f36ce0f5d2d520ad5a45a0eea6eb99abbbe6f7)、[Pilot](https://github.com/arihanv/pilot/tree/fd6b652d9bbbd99d95407861a5adfa1a3fdebb22)、[actell](https://github.com/ja1chen/actell/tree/032864e2339da19ee13025c471f4cf1dfdf4c5cd)、[iCTRL](https://github.com/OpenMinis/iCTRL/tree/9fd0a7cc20819a1612f7d62ffbec5989d23f018e)。固定版本用于复核，不表示所有后续版本保持相同行为。

USB HID 参考项目只支持 ASCII 直接输入；中文需要保留我们已有的剪贴板粘贴思路并另做验证。其指针检测失败后仍会继续点击，画面差异检查也只能说明画面变了；移植时不能用这些信号代替坐标确认与任务成功验证。[指针与输入实现](https://github.com/onehumanbeing/esp32-iphone-agent/blob/27f36ce0f5d2d520ad5a45a0eea6eb99abbbe6f7/server/hidagent/phone.py)、[画面检查](https://github.com/onehumanbeing/esp32-iphone-agent/blob/27f36ce0f5d2d520ad5a45a0eea6eb99abbbe6f7/server/hidagent/vision.py)

路线选择只改变运行路径。当前 DeviceKit 仍链接 GPL 开发者后端；纯 HID 分发若要去除该依赖，需要独立构建拆分与依赖核对。研究项目的许可不等于当前 App 整体许可。[依赖清单](dependencies.md)

## 实现组织、后台与停止

继续保留两个独立 Kit：AgentKit 负责可替换引擎、消息事件和工具；DeviceKit 负责观察、动作与能力。App 中的 DeviceToolSession 组合两者，普通聊天不注册设备工具。新增 S3 路线应实现同一 DeviceController 协议，不再增加一层面向用户的连接 Plugin。[模块边界](architecture.md)

建议在内部区分“输入/观察后端”和“指令/网络通道”：HID 的蓝牙命令不等于蓝牙键鼠报告，USB HID 不等于 USB 网卡。界面仍只展示简单选项，如“蓝牙开发板”“有线键鼠”，并提供与真实能力一致的状态。

所有手机内路线都受主 App 后台执行时间限制。Eiscue 使用 iOS 26 BGContinuedProcessingTask 为用户在前台发起的设备任务申请继续执行；系统可以取消或结束它。ReplayKit 扩展、蓝牙连接、VPN 或独立 Runner 都不能替代 Agent 本身的执行许可，灵动岛显示也不等于任务仍在运行。[后台实现与边界](background.md)、[Apple 持续任务说明](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)

停止、过期、共享失效和后端切换先关输入门控，释放按住状态并取消 Agent。未知送达的动作不自动重发；恢复后取得新画面、检查连接及坐标，再接纳新任务。手机重启不自动重放之前的任务。ReplayKit 仅保存受保护的最新帧，任务截图会送给所配置模型；配对私钥与 API Key 不进入文档或导出报告。

## 建议推进与验收

| 顺序 | 交付 | 验收必须证明 |
| --- | --- | --- |
| 当前：完成 C3 蓝牙任务 | 手机内模型 → 截图 → 点击/滑动/中文输入 → 读回结果 → 停止 | 完整跨 App 闭环，无电脑代发指令；前台与 5 / 15 分钟后台分开记录。 |
| 下一条：S3 USB HID | BLE 指令 + USB 输入 + ReplayKit 的手机版后端 | 原生 USB 枚举、Lightning/USB-C 接线供电、真实坐标、拖动、中文、停止释放、拔线恢复、正常 Wi-Fi 模型请求。 |
| 并行：软件准备与 iCTRL 对照 | 核对格式，验证 DDI、Runner / 自有会话及本机接口 | 首次准备、关闭准备 VPN 后继续控制、重启恢复、签名续期分别留证；不因 RPC 有回复就算操作成功。 |
| 保留：S3 USB NCM | 验证已构建网卡固件与开发者后端 | 手机识别网卡、目标路由与普通联网、DDI/身份、基础控制、拔线恢复；不得用 C3 Wi-Fi 结果代替。 |

当前没有足够证据按速度或稳定性排序各路线。比较时使用同一手机、系统、模型与任务，记录首次人工步骤、动作落点误差、任务成功率、断线恢复耗时、模型费用和后台终止情况。现有四点与文字检查、软件测试和构建成功不能替代上述验收。

新候选只在验收通过后考虑调整默认选项；此前保留 C3 蓝牙默认和已验证固件。切换失败时停止任务并允许用户回到原路线，不静默改走 VPN、其他设备或电脑。重启与重连后的恢复先确认新画面，不接续未知副作用。

## 现在如何选择

想马上在现有硬件上试任务，使用 C3 蓝牙版。想开发无需 DDI 的有线体验，优先验证 S3 USB HID。想避免额外硬件，继续完善已有 XCTest 软件路线并研究 iCTRL 的准备与恢复。可以接受 Linux 电脑持续参与，才直接采用 esp32-iphone-agent 原版。

这几条路线可以共用 Agent 协议和工具语义；区别在设备后端、前置条件与生命周期。后续替换 Pi 或增加其他平台时，不需要因某条硬件路线重做 Agent 协议。
