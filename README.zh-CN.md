# Eiscue

[English](README.md) | **简体中文**

运行在 **iPhone / iPad** 上的 Agent 设备助手，最低支持 **iOS / iPadOS 26.0**。

对话、任务编排和工具执行都在手机内完成，模型通过用户配置的 HTTPS 服务调用。用户允许时，Agent 还可以查看屏幕并操作这台设备，包括其他 App。

> 当前为开发预览（`0.1.0`），通过 Xcode 开发签名安装，尚未上架或进入 TestFlight。内部方案和完整验收记录不随仓库发布；公开的构建、固件和第三方来源说明见下方链接。

## 工作方式

设备任务是在手机上运行的循环：

1. 模型收到任务和当前截图，调用设备工具（点击、滑动、输入文字、回到主屏幕、打开 App 等），给出截图像素坐标和该截图的 `frameID`。
2. Eiscue 校验该截图是最新一张、仍在时效内，且方向、尺寸和会话与当前一致，然后换算坐标并发送输入。每张截图只能授权一次动作。
3. Eiscue 随即重新截图，在同一个工具结果中返回。模型从新画面核对结果，再决定下一步。

动作送达结果不确定时，任务停止，不重试；命令回执不会被当作操作成功。

iOS 没有供 App 操作其他 App 的公开接口，因此设备控制走以下路线之一，路线之间不会自动回退：

| 路线 | 画面 / 输入 | 首次准备 | 额外硬件 |
| --- | --- | --- | --- |
| **App 内连接**（默认，本地 VPN） | 经 Eiscue 自带的回环 VPN 使用开发者服务；可选 **DisplayService**（iOS 27+）或 **XCTest** | 开发者模式、配对（iOS 26 用 Mac + USB，iOS 27 起可系统配对）、开发者磁盘映像（DDI） | 无；占用 VPN 通道 |
| **S3 USB 网卡** | 同样的开发者服务，经 ESP32-S3 USB 网卡中继 | 同上，另需中继固件并在手机上手动配置 IPv4 | ESP32-S3 开发板；不占 VPN |
| **ESP32 键鼠**·蓝牙（C3 / S3） | ReplayKit 屏幕共享 / 蓝牙键鼠（HID） | 蓝牙配对、辅助触控、屏幕共享和屏幕校准 | ESP32-C3 或 S3 开发板；不需要 VPN、配对文件或 DDI |
| **ESP32 键鼠**·USB（S3） | ReplayKit / USB 键鼠；控制命令仍走蓝牙 | 同上，另需手机作为 USB 主机连接开发板 | ESP32-S3 开发板 |

开发者服务路线依赖私有接口和开发者磁盘映像，不承诺 App Store 分发。HID 路线在手机上只用公开功能，但不能回到主屏幕、列出应用或按 bundle ID 打开 App，需要通过辅助触控菜单等可见控件导航。

## 主要功能

- **聊天与模型**：支持 OpenAI Chat Completions、OpenAI Responses、Anthropic Messages。可保存多组服务和模型，每组 API Key 独立保存在 Keychain，在对话顶部切换。只聊天不需要开发板或屏幕共享。
- **设备操作**：只按当前路线实际支持的能力注册工具。设备页的「允许 AI 操作设备」默认开启；设备未就绪时，新消息按普通聊天处理。任务开始时即固定权限范围。
- **任务**：支持停止、暂停后显式继续和脱敏报告。任务详情以一条时间线展示步骤与日志、带点击／滑动位置的截图，以及服务商实际返回的输入／输出／缓存 token 用量；缺失项保持未知，中断记录的汇总标为部分，不估算费用。正常结束后默认保留连接，可在「设置 → 任务结束后断开」中更改。
- **后台执行**：设备任务申请 iOS 26 的 `BGContinuedProcessingTask`，系统实时活动显示当前阶段；进度环按固定规模只记录真实完成的步骤，结束前保持接近空环。iOS 可能提前结束后台执行，并控制完成后的收起（[Apple API](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)、[WWDC25](https://developer.apple.com/videos/play/wwdc2025/227/)）。可选的「任务通知」默认关闭，只在系统活动没有收到结果时发送。
- **附件与语音**：支持照片、拍摄、文本／代码文件和可提取文字的 PDF。Apple Speech 本机听写，无需语音 API Key；点击开始／结束或按住说话，识别结果回填草稿。iOS 27+ 的 DisplayService 连接期间系统会静音麦克风（[Apple 说明](https://developer.apple.com/documentation/xcode/interacting-with-your-app-in-device-hub#Handle-camera-and-microphone-access-conflicts-on-physical-devices)），因此开始录音会在授权后暂时释放控制，结束后恢复，保留配对和 VPN。恢复有独立的可取消状态，失败时保留草稿。
- **对话管理**：流式 Markdown、工具进展与分享。长按文字消息可选择文字；侧栏支持置顶、排序、重命名和多选（右滑打开、左滑收回），iPad 宽窗口可常驻侧栏。全屏截图支持捏合和双击缩放。
- **界面**：原生 Liquid Glass、浅色／深色模式、中英文界面（默认跟随系统，「设置 → App 语言」打开 iOS 的单 App 语言设置）。可导入 UTF-8 Markdown Skill。动态[矢量头部形象](Artwork/EiscueHeads/README.md)展示连接状态，并遵循「减少动态效果」。带 ST7789 屏幕的指定 C3 开发板可显示表情、任务阶段和步数。Debug 包在设备页「调试」分区提供屏幕预览和重复输入检查，Release 包不包含这些入口。

## 当前状态

截至 2026-10-21。源码接入、软件测试和真机验收分别记录。真机结果来自一到两台测试手机（主要是 iPhone 12 mini / iOS 27），且多为单次有限检查，不能外推到其他机型、系统版本或反复使用。模拟器无法验证蓝牙 HID、屏幕共享、后台时长或开发者服务控制。

| 能力 | 状态 |
| --- | --- |
| 对话、模型、附件、语音、界面 | 已实现；完整 Kit 与 App 单元测试在 iOS 26 和 27 模拟器通过 |
| App 内连接 + XCTest | iPhone 14 Pro / iOS 26.5.2 与 iPhone 12 mini / iOS 27 的自有检查页通过：点击、滑动、Unicode 文字、旋转后拒绝旧截图、短时后台。12 mini 另通过约十分钟后台脚本、滑动途中停止和一次真实模型计算器任务 |
| App 内连接 + DisplayService（iOS 27） | 12 mini 上范围同上，但**新横屏点击间歇失败**，根因未定 |
| VPN 丢失后恢复、显式继续 | 每种控制方式各单次同进程通过：不会自动恢复，显式连接可恢复就绪；停止后继续时重新截图，不重放原动作。重连进程中的实际输入尚未验证 |
| 语音交接 | 正常结束、取消、切键盘、页面切换和退后台的生命周期检查在每种控制方式各通过一次，均收到非零音频；DisplayService 有一次用户反馈的实际转写 |
| S3 蓝牙 / USB 输入 | 竖屏自有页面的点击、中文和滑动各单次通过，另有滑动途中停止。USB 通过一分钟后台截图；**蓝牙后台约一秒即被系统结束** |
| S3 USB 网卡 | 每种控制方式各单次前台滑动；DisplayService 停止及一分钟后台观察通过 |
| C3 蓝牙输入 | 点击、中文和屏幕共享通过；**滑动尚未通过** |
| 更广的跨 App 任务、真实模型长后台、锁屏、系统取消 | 尚未验收 |
| 释放已终止 App 进程遗留的屏幕会话 | **未实现** |
| 其他后端（iCTRL、元素树、本机 OCR） | 仅调研 |

### 已知限制

- **已终止进程遗留的会话**：DisplayService 控制期间 Eiscue 若退出，重新打开的 App 无法释放旧屏幕会话，麦克风会保持静音直到手机重启；配对和 VPN 仍可使用。同一进程内，Eiscue 在 VPN 丢失后仍保留会话所有权，可通过「设置 → 连接修复 → 重置连接并检查」释放。该检查释放控制，保留配对、VPN 和聊天记录，再短暂采样麦克风，不做识别、不保存音频。释放未确认时先保持 Eiscue 在前台再次检查；仅在控制已断开但麦克风仍无输入时重启手机。
- **不自动重试或回退**：送达结果不明的动作会停止任务并释放连接，对话显示“操作结果未确认”；需要核查屏幕、重新连接后再明确继续。停止不能撤回已经发出的触控。
- **后台时长**只由 iOS 决定，VPN、蓝牙、ReplayKit 或实时活动都不会延长它。
- **文字输入**：DisplayService 和 HID 会覆盖剪贴板并粘贴，不读取原有内容；XCTest 输入不经剪贴板。
- **开发板信任边界**：C3 接受任何已加密、已绑定蓝牙连接发来的命令，没有 S3 那样的逐连接应用级认证。S3 首次登记密钥只在开发板上电后 60 秒内开放，采用 Just Works 配对，不防中间人。请只在可信的手机和环境中使用开发板。
- **未验证的环境**：iPad、其他 iPhone 机型与系统版本、USB 线材与转接器组合、公司 VPN 共存。

## 快速开始

### 运行与配置

1. 准备 Apple Silicon Mac、Xcode 26+ 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.45+。在仓库根目录运行 `xcodegen generate`，再打开 `Eiscue.xcodeproj`，选择 `Eiscue` scheme。
2. 在 iOS 26+ 模拟器运行时保留默认本地签名，否则 Keychain 不可用。真机运行需在 `project.yml` 配置自己的开发团队与 Bundle ID，再重新生成项目。主 App 和屏幕共享扩展共用 App Group；主 App 和本地 VPN 扩展需要 Network Extension 的 `packet-tunnel-provider` 能力。默认标识为 `org.eiscue.app` 和 `group.org.eiscue.app`，修改时需同步后缀、扩展与共享组配置，详见 [AGENTS.md](AGENTS.md)。
3. 首次引导或「设置 → 模型」中填写服务地址、模型 ID 和 API Key。已有 Key 显示为已保存，需要修改时点“更换”。保存配置不会请求模型。

模型服务地址必须使用 HTTPS。OpenAI 兼容服务通常包含 `/v1`；Anthropic 使用 `https://api.anthropic.com`。设备任务还要求模型支持图片和工具调用。

### 仅 HID 构建

选择 `EiscueHID` scheme 可构建独立 App，只包含 ESP32 BLE / USB HID 与 ReplayKit。它默认使用 ESP32 键鼠，采用 `org.eiscue.hid`、`group.org.eiscue.hid`，仅嵌入自己的屏幕共享扩展。包依赖和编译产物不包含开发者服务后端、XCTest 桥或 VPN 扩展；完整 `Eiscue` App 运行时选择蓝牙并不会移除这些组件。两种 App 的模型配置、会话和共享授权互相独立；一个 App 保存的 S3 认证密钥不会自动迁移给另一个，也不会自动覆盖已有注册。这次构建拆分不代表 App Store 已批准，也不授予新的图片或组件许可。

其他宿主可依赖 `EiscueHIDKit` product，`import EiscueDeviceCore`，并创建 `let board = BluetoothDeviceController(); let client = DeviceClient(actuator: board, hidSetup: board)`。完整 `EiscueDeviceKit` 保留 `DeviceClient()` 和 `DeviceClient(identityStore:)`。可通过 `python3 Scripts/check-hid-boundary.py --app <EiscueHID.app路径>` 检查构建边界。

### 配置设备操作

打开 Eiscue 右上角设备页，在「连接方式」中选择路线。选中路线不会自动连接。首次引导和设备页会直接展示设置步骤。已保存的配对身份会在连接时检查，不代表设备操作已经就绪。

#### App 内连接（本地 VPN）

点「连接」时 Eiscue 启动自带的 VPN；首次会由 iOS 确认添加 VPN 配置，期间不能同时使用其他 VPN。

- **iOS 27+**：点「开始配对」，前往「设置 → 隐私与安全性 → 开发者模式」，选择 Eiscue 并点“配对”确认，再输入 Eiscue 显示的验证码。仍可导入已有的兼容配对文件。
- **iOS 26**：按五步完成：准备 Mac、USB 连接设备、运行复制的命令、导入配对、连接设备。

系统配对只建立 Eiscue 的身份，不准备开发者磁盘映像；开发者模式和兼容的 DDI 仍是独立要求，因此首次配置尚不能完全脱离电脑。

iOS 26 上的「复制命令」会先下载源码、再运行配对工具。在 Mac 终端的**任意目录**粘贴整段执行即可；命令会创建新的临时源码目录，不改动已有文件夹：

```sh
eiscue_setup_dir="$(mktemp -d -t eiscue-setup)" &&
git clone --depth 1 https://github.com/LLLLLayer/Eiscue.git "$eiscue_setup_dir" &&
python3 "$eiscue_setup_dir/Scripts/setup-device.py" --app-pairing-schema 1
```

Mac 需安装 Xcode 26+、Python 3.9+、Rust 1.96.0 并保持联网。设备信任、开发者模式和 Xcode 开发准备仍需完成，命令不会安装这些工具或准备 DDI。它让用户选择并确认 USB 设备，再生成身份并传入已安装的 Eiscue，不覆盖待导入文件、不代替 App 导入或启动 VPN。工具协商支持的配对 schema 并在发送前校验；保留 v1 JSON／plist 兼容，App 导入时拒绝未知版本。App 会在同一页面检测收到的文件，点「导入电脑发送的配对」，再点「连接」（首次引导中为「连接设备」）。工具发送后会删除单独保存的私密配对文件；首次编译可能下载已锁定的 Cargo 依赖。已有源码时可在项目文件夹运行 `python3 Scripts/setup-device.py --app-pairing-schema 1`。底层步骤见 [USB 配对工具](Scripts/pair-device-usb.md)。

卸载后，Keychain 中的配对身份和系统 VPN 配置可能仍然保留。「设置 → 连接修复 → 重置配对」只移除 Eiscue 的配对身份，保留模型配置和密钥；需先断开连接，再确认重置。移除 Eiscue 的 VPN 配置需在 iOS 设置中单独操作。

#### ESP32 键鼠（蓝牙 / USB）

1. 按 [C3 / S3 固件说明](Firmware/Passport-BLE/README.md#build-and-flash-layout) 准备固件，给开发板供电。
2. 在 iPhone「设置 → 辅助功能 → 触控 → 辅助触控」开启辅助触控。
3. 在设备页选择「ESP32 键鼠」；S3 还需选择「蓝牙输入」或「USB 输入」。依次连接、在系统面板开启屏幕共享、开始检查。检查期间保持页面可见，不触屏、不旋转：App 会验证四次真实触摸和一次文字输入。支持相对拖动的固件还会做六次短移动检查，通过后才提供滑动；旧固件或移动检查未通过时仍保留已验证的点击和输入。
4. 回到对话下达任务。

连接、共享、校准必须同时有效。断开、旋转、新的共享会话或画面尺寸变化会使校准失效，需要重新检查。

**USB 输入**使用开发板的原生 USB / OTG 口。USB-C 手机使用 C-to-C 数据线；Lightning 手机需要带供电的 USB 主机（相机）转接器，普通 Lightning 线不适用。COM / UART 口用于烧录和日志。

C3 屏幕伙伴只显示固定阶段、表情和步数，不显示模型文字。短按 OK 键锁存停止；松开后长按约 1.5 秒、再断开连接才解除，随后需要重新连接与校准。

#### S3 USB 网卡

这条路线与 USB 输入不同。刷入 [NCM 中继固件](Firmware/NCM-Relay/README.md)，把开发板的原生 USB 口接到手机，在 iOS 设置中把该 USB 以太网接口配置为手动 IPv4：地址 `192.168.7.2`，子网掩码 `255.255.255.0`，路由器和 DNS 留空（开发板为 `192.168.7.1`）。与「App 内连接」一样仍需配对和开发者磁盘映像。连接绑定在 USB 接口上，不会回退到 Wi-Fi 或 VPN。

#### 控制方式

「App 内连接」和「S3 USB 网卡」在「控制方式」中提供 **DisplayService**（CoreDevice）和 **XCTest**，与路线和配对分开选择。首次默认在 iOS 26 为 XCTest、iOS 27 起为 DisplayService；旧的自动选项直接显示其实际方式。iOS 26 仍显示 DisplayService 入口，但不可选，并标注“需要 iOS 27 或更新版本”，仅更新 App 不能启用。选择当前方式会保留连接；切换会释放当前连接、保留配对身份，需要重新连接，不会自动回退。

原 C3 Wi-Fi 热点中继已移除。旧的已保存选项会回到「App 内连接」，但不会自动连接。

## 架构

```text
Eiscue App（SwiftUI，iOS 26+）
├── 对话、模型设置、附件、语音、Skill、任务记录、后台执行
├── RunCoordinator / RunSession：每次运行独享引擎、设备占用、清理与可等待的结束点
├── DeviceSession / DictationSession：连接状态、占用权和录音交接
├── DeviceToolSpec / DeviceToolSession：统一工具描述 → DeviceDecision
├── DeviceTaskRunner：权限、预算、串行执行、动作后观察
├── EiscueAgentKit：Agent / 工具 / 事件协议，内部适配 PiDurableKit
└── EiscueDeviceCore：DeviceActuator、GuardedDevice、可注入的 DeviceClient、BLE / USB HID + ReplayKit
    ├── EiscueHIDKit product：仅 Core
    └── EiscueDeviceKit 外观层：Core + 开发者服务 / 默认客户端

扩展：EiscueBroadcast（屏幕共享）、EiscueTunnel（仅本地 VPN 路线）
固件：Passport-BLE（C3 / S3 HID）、NCM-Relay（S3 USB 网卡中继）
```

Agent 与 Device 库互不依赖，由 App 集成层连接；两个 Device product 共享 Core 模块，没有单独的 Plugin 产品：

| Kit | 职责 | 替换入口 |
| --- | --- | --- |
| [EiscueAgentKit](Sources/EiscueAgentKit/AgentClient.swift) | Agent、工具、事件和会话存储；内部通过 JavaScriptCore 运行 PiDurableKit，每个会话一个 SQLite | `AgentClient(engine:)`，也可注册自己的 Swift 工具 |
| [EiscueDeviceKit](Sources/EiscueDeviceCore/DeviceClient.swift) | 连接、观察、动作和能力状态 | `DeviceClient(actuator:networkSetup:hidSetup:)` |

集成 DeviceKit XCTest 后端的 App 需在真机 target 的 `LD_RUNPATH_SEARCH_PATHS` 中保留继承路径，并添加 `/System/Developer/usr/lib` 和 `/Developer/usr/lib`。Xcode 27 的开发镜像通过这些路径加载 Testing 互操作依赖。Eiscue 已在 `project.yml` 配置；Apple 测试库从已挂载 DDI 动态加载，不随 App 打包。

公开 API 不暴露 PiDurableKit 或 actell 类型。贡献与维护规则见 [AGENTS.md](AGENTS.md)。

## 构建与测试

Kit 测试优先使用下面的隔离脚本，它不会改写实际的 `Package.resolved` 或暂存状态；直接运行 `swift test` 可能移除仅 Xcode 使用的锁定项。每套工具链使用独立 scratch 目录。

在仓库根目录执行：

```sh
xcodegen generate

# Kit 测试：指定 Xcode，隔离锁文件及构建产物
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
python3 Scripts/test-swift-package.py --scratch-path .build/kit-xcode26

# App 构建
xcodebuild -project Eiscue.xcodeproj -scheme Eiscue \
  -destination 'generic/platform=iOS Simulator' ARCHS=arm64 build

# App 单元测试
xcodebuild -project Eiscue.xcodeproj -scheme Eiscue \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' \
  -only-testing:EiscueAppTests test
```

完整 App + UI 测试需要先在另一个终端启动本地模型服务，无需 API Key：

```sh
python3 Scripts/test-model-server.py
```

```sh
xcodebuild -project Eiscue.xcodeproj -scheme Eiscue \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' test
```

保存检查日志时，可使用 `bash Scripts/run-logged-check.sh .build/<唯一名称>.log <命令> [参数...]`。脚本保留已有日志，并返回检查命令的真实退出码；失败不会被包装成成功。

### 已记录的测试基线

| 检查 | 最近一次完整结果 |
| --- | --- |
| Swift Kit（2026-10-20） | Xcode 26.3 / Swift 6.2.4 与 Xcode 27 / Swift 6.4 各通过 242 项 / 24 个 suite |
| App 单元测试（2026-10-20） | iOS 26：501 通过；iOS 27：500 通过、1 项平台专用跳过 |
| 离线 Python 工具（2026-10-20） | 23 通过 |
| Release 构建（2026-10-20） | 纯 HID Release 构建与边界审计（Xcode 26）；完整版 Release 构建（Xcode 27） |
| iPhone 完整 UI（2026-10-17） | iOS 26.3.1：59 通过 / 13 跳过；iOS 27：63 通过 / 9 跳过；0 失败 |

之后的改动只运行了连接、语音、清理等聚焦测试（两套工具链）。跳过不计为通过；日志和结果包仅保留在本地 `.build/`。

hosted Ubuntu 工作流在 main push、PR 和手动触发时运行离线 Python 工具测试。[CI 配置说明](Scripts/ci.md)中的 Apple 检查需要已注册的自托管 Apple Silicon runner 并设置 `EISCUE_APPLE_RUNNERS_ENABLED=true`；目前尚无 runner 或分支保护，hosted 工具测试不验证 Swift 或 Apple 构建。

### 后端与固件

设备后端附带 arm64 iOS、模拟器和 macOS XCFramework，不含 x86_64。仅在修改后端源码时重建；使用固定 Rust 1.96.0 工具链：

```sh
bash Scripts/build-device-backend.sh
CARGO_TARGET_DIR=.build/device-rust rustup run 1.96.0 cargo test --locked \
  --manifest-path Vendor/DeviceBackend/rust/Cargo.toml --lib
```

固件构建需要 ESP-IDF **v5.5.3**，设置 `IDF_PATH`：

```sh
bash Scripts/build-passport-ble.sh esp32c3  # 或 esp32s3
bash Scripts/test-board-auth.sh           # 主机测试，无需硬件
bash Scripts/test-board-companion.sh
```

构建不会打开串口或烧录。烧录流程按固件区分：

- **C3 BLE**：按 [分区说明](Firmware/Passport-BLE/README.md#build-and-flash-layout) 先完整备份并核对已有布局；在已核验匹配布局的开发板上更新时，只写 `0x20000` 应用分区，保留 `0xF000` 私有配置。通用烧录工具没有 C3 BLE profile。
- **S3 HID / 中继固件**：`board-firmware.py` 支持 `s3-hid` 和 `ncm`。需先生成并验证对应固件包，`flash` 必须指定 `--port` 和 `--package`，会完整备份 Flash 再写入和校验，不擦整片、不写 eFuse。默认 `ncm` 包使用 4 MB 布局，不能写入已刷 16 MB S3 HID 布局的开发板；S3 也不可复用 C3 分区表。参数见 `python3 Scripts/board-firmware.py --help`，布局见各固件 README。

## 权限、数据与隐私

- 任务开始时固定权限范围；普通聊天不注册工具。设备工具只按当前后端实际支持的能力开放。继续设备任务时重新检查权限和就绪状态；设备任务清理结束前不能切换连接方式。
- 无进展或达到步数上限时暂停，点“继续”会以新请求重新观察。中断恢复只读，不自动续跑。导入的 Skill 只是 Markdown 说明，不能扩大权限或执行脚本。
- **观察工具与动作后的自动观察都会把截图发给模型**；仅开启屏幕共享或手动预览不会。模型请求只保留最新两张设备截图，但包括截图在内的完整工具历史保存在会话 SQLite 中，删除会话时清理。
- ReplayKit 扩展只保留最新 JPEG 帧（最长边 ≤ 1600 px），存放于受文件保护的 App Group，不保留录屏历史、不采集音频。
- 会话、运行时 SQLite、任务记录、Skill 和附件位于 App 沙盒的 `Application Support/Eiscue/`。`Runtime/` 与任务记录不进入设备备份。API Key 与配对私钥保存在仅本设备可用的 Keychain，不进入 UserDefaults、日志或导出报告；删除 API Key 不会删除会话。
- 会话存储使用小型索引、每会话一个记录文件和共享的 SHA-256 附件数据。加载时隔离损坏的会话；无法完整校验时暂停回收、保留原始数据。任务记录采用带序号和校验的只追加事件，结束时生成摘要。旧版数据在首次写入时迁移并保留原始备份，首次明确删除会话后移除该备份。
- 附件复制到私有存储，图片重新编码以去除 EXIF，仅在发送时交给模型。语音在本机识别，音频不落盘。
- 导出报告只含允许的元信息和工具状态，不包含 Key、配对信息、原始截图或完整输入参数。

AX 界面树、PiP、Mac / Android / 鸿蒙后端仍是后续方向。

## 许可与来源

整个 Eiscue 尚未选定统一发行许可。以下仅记录各组件自带的许可与来源：

| 组件 | 来源 / 许可 |
| --- | --- |
| [DeviceBackend](Vendor/DeviceBackend/README.md) | actell 固定提交，GPL-3.0-only；内含 MIT 的 idevice。完整 `Eiscue` App 链接此后端，选择蓝牙路线不会将其移除；独立 `EiscueHID` 构建不链接此后端 |
| [LocalTunnel](Vendor/LocalTunnel/README.md) | LocalDevVPN / StosVPN 衍生实现，自定义 StosVPN License；来源作者见目录内声明 |
| [Passport-BLE](Firmware/Passport-BLE/README.md#license-and-api-references) | 原创固件代码为 Apache-2.0；依赖声明见固件目录。[表情资源](Firmware/Passport-BLE/Resources/README.md)不因固件代码许可而被授予同样许可 |
| [NCM-Relay](Firmware/NCM-Relay/README.md) | 上游组合项目声明 GPL-3.0-only，本地文件带 GPL-3.0-or-later 头；详见其 `SOURCE_MANIFEST.json` |
| PiDurableKit | 固定 commit，CC0-1.0；嵌入的 JS 依赖另有声明 |
| swift-markdown / swift-cmark | 固定 0.9.0；许可全文随 [App 资源](Apps/Eiscue/Resources/OpenSourceLicenses) 提供 |

依赖版本见 [Package.swift](Package.swift) 与 [project.yml](project.yml)。
