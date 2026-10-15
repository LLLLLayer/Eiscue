# Eiscue

[English](README.md) | **简体中文**

运行在 **iPhone / iPad** 上的 Agent 设备助手，最低支持 **iOS / iPadOS 26.0**。

对话、任务编排和工具执行都在手机内完成，模型通过用户配置的 HTTPS 服务调用。除了聊天，Eiscue 还可以在用户允许时观察并操作这台设备。

> 当前为开发预览（`0.1.0`），通过 Xcode 开发签名安装，尚未上架或进入 TestFlight。内部方案和完整验收记录不随仓库发布；公开的构建、固件和第三方来源说明见下方链接。

## 主要功能

- **聊天与多模型**：支持 OpenAI Chat Completions、OpenAI Responses、Anthropic Messages；保存多组服务和模型，在对话顶部切换。新配置直接使用模型 ID 显示，不再单独填写名称。每组 API Key 独立保存在 Keychain。
- **设备操作**：模型根据截图决定点击、滑动或输入；每次动作后自动截图供模型核对。首次使用默认选择 **App 内连接（本地 VPN）**，需要首次配对：iOS 26 使用电脑 USB 配对，iOS 27 起可从系统发起配对。也可选 **蓝牙开发板 + 系统屏幕共享**，开发板只需供电，不占手机 Wi-Fi 或 VPN 通道。已保存且仍支持的连接方式会保留。
- **语言**：默认跟随系统；从设置 → App 语言进入 iOS 设置，可单独选择中文或英文。
- **附件与语音**：支持照片、拍摄、文本 / 代码文件、可提取文字的 PDF，以及 Apple Speech 本机听写，无需语音 API Key。点击开始／结束，也可按住说话；识别结果回填草稿后再编辑发送。iOS 27+ 的 App 内／USB 网络控制连接激活时，点击语音保留文字输入并显示提示：App 内连接测试手机上已观察到系统远程控制静音，USB 网络路线共用屏幕服务，但尚未实测麦克风。此限制不适用于 iOS 26 XCTest、蓝牙 HID、USB HID 或未连接设备；这些路线与录音共存仍需真机验收。
- **对话管理**：流式回答、Markdown、工具进展、复制与分享；侧栏支持置顶、排序、重命名和批量删除，iPad 宽窗口支持常驻侧栏。右滑打开、左滑收回；任务详情以一条时间线展示步骤与日志。
- **任务与后台**：支持停止、暂停后显式继续和脱敏报告；任务详情可查看已保存的输入输出、截图，以及原图可用时的点击和滑动位置。正常结束任务后默认保留连接，可在设备页手动断开，或在设置中开启「任务结束后断开」。切换 App 本身不会主动断连，但不保证 iOS 或网络会一直维持闲置会话。使用 iOS 26 系统实时活动显示当前阶段和结束状态；执行期间进度环保持接近空环，任务结束后由 iOS 收起。系统活动收到结果后不重复发送通知，否则可使用完成 / 中断通知，默认关闭。
- **界面与扩展**：原生 Liquid Glass、浅色 / 深色模式、中英文界面；可导入 UTF-8 Markdown Skill。各连接方式的屏幕预览和重复输入检查统一收在设备页的调试分区。设置中的「调试」开关仅 Debug 包可见，默认开启，可关闭并记住选择；Release 包不展示开关及这些诊断入口。必需的 HID 校准在完成前仍对所有版本开放。带 ST7789 屏幕的指定 C3 开发板还可显示表情、任务阶段与已完成步数。

## 当前验证状态

| 能力 | 状态 |
| --- | --- |
| 对话、多模型、流式回答、Markdown、附件、本机听写、中英文界面 | 已实现，有模拟器测试覆盖；已知失败见下方测试基线 |
| C3 / S3 蓝牙连接、ReplayKit、四点触摸与中文输入检查 | 已在指定 iPhone 14 Pro / iOS 26.5.2 真机通过 |
| 蓝牙滑动、完整跨 App Agent 任务、长时间后台 | 代码已接入，**尚未真机验收** |
| S3 USB 输入：命令走蓝牙，键鼠经 USB | 代码与固件已接入；手机端 USB 输入**尚未通过验收** |
| 本地 VPN / USB 网卡 | 代码已接入；各路线仍需分别完成真机验收 |
| iCTRL 等其他后端 | 仅完成源码调研，未集成 |

**源码接入、软件测试和真机验收分别记录。** 模拟器无法验证蓝牙 HID、系统屏幕共享或后台时长；单台样机的结果不能外推到其他机型和系统版本。

## 快速开始

### 运行与配置

1. 准备 Apple Silicon Mac、Xcode 26+ 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.45+。在仓库根目录运行 `xcodegen generate`，再打开 `Eiscue.xcodeproj`，选择 `Eiscue` scheme。
2. 在 iOS 26+ 模拟器运行时保留默认本地签名，否则 Keychain 不可用。真机运行需在 `project.yml` 配置自己的开发团队与 Bundle ID，再重新生成项目。主 App 和屏幕共享扩展共用 App Group；主 App 和本地 VPN 扩展需要 Network Extension 的 `packet-tunnel-provider` 能力。默认标识为 `org.eiscue.app` 和 `group.org.eiscue.app`，修改时需同步后缀、扩展与共享组配置，详见 [AGENTS.md](AGENTS.md)。
3. 首次引导或「设置 → 模型」中填写服务地址、模型 ID 和 API Key。支持保存多组配置；已有 Key 显示为已保存，需要修改时点“更换”。保存配置不会请求模型。

模型服务地址必须使用 HTTPS。OpenAI 兼容服务通常包含 `/v1`；Anthropic 使用 `https://api.anthropic.com`。设备任务还要求模型支持图片和工具调用。只聊天不需要开发板或屏幕共享。

### 让 AI 操作设备

默认的 **App 内连接** 在 iOS 27 起提供系统配对，同时保留导入已有兼容配对文件的入口。在系统配对页选择 Eiscue，点“配对”确认，返回 Eiscue 查看验证码，再到系统输入。iOS 26 使用五步引导：准备 Mac、USB 连接设备、运行可复制的命令、导入配对、连接设备。完整命令和要求见下文。选中连接方式不会自动启动连接。

2026-10-14 已在一台 iOS 27 设备上使用诊断版完成系统配对；该结果不代表默认服务发布配置或截图、输入已验收。开发者模式与兼容 DDI 的准备仍是独立要求，尚不能据此宣称整个首次配置完全不需要电脑。

如需使用蓝牙方案：

1. 按 [C3 / S3 固件说明](Firmware/Passport-BLE/README.md#build-and-flash-layout) 准备蓝牙固件，给开发板供电。
2. 在 iPhone「设置 → 辅助功能 → 触控 → 辅助触控」开启辅助触控。
3. 打开 Eiscue 右上角设备页，选择“ESP32-C3 / S3 键鼠”，依次连接、在系统面板开启屏幕共享、开始检查。检查期间保持页面可见，不触屏、不旋转；App 会验证四次真实触摸和一次文字输入。
4. 就绪后回到对话下达任务。“允许 AI 操作设备”默认开启，可在设备页关闭。设备未就绪时，新消息按普通聊天处理。

连接、共享、校准必须同时有效。断开、旋转、共享会话或画面尺寸变化会使旧校准失效，需要重新检查。路线之间不会自动回退。

### 连接方式

| 路线 | 画面 / 输入 | 首次准备 | 占用 Eiscue VPN 通道 |
| --- | --- | --- | --- |
| 蓝牙开发板（C3 / S3） | ReplayKit / BLE HID | 蓝牙配对、辅助触控、共享与校准；不需要电脑配对文件或 DDI | 否 |
| S3 USB 输入 | ReplayKit / USB HID，控制命令仍走蓝牙 | 同上，另需手机作为 USB 主机连接开发板 | 否 |
| App 内连接（默认，本地 VPN） | 开发者服务截图与输入；iOS 26 使用 App 内 XCTest | iOS 26 电脑 USB 身份建立，或 iOS 27 起系统配对；另需开发者环境 / DDI | 是 |
| S3 USB 网卡 | 同上，经 USB NCM 中继 | 同上，另需 USB 主机连接与网卡配置 | 否 |

原 C3 Wi-Fi 热点中继已移除。旧的已保存选项会回到默认的 App 内连接，但不会自动启动；请手动选择并连接仍支持的路线。

**USB 输入与 USB 网卡是两条不同路线。** S3 USB 输入使用板子的原生 USB / OTG 口；USB-C 手机使用 C-to-C 数据线，Lightning 手机需要带供电的 USB 主机（相机）转接器，普通 Lightning 数据线不适用。COM / UART 口用于电脑烧录与日志。手机、线材和转接器组合仍需实际验证。

开发者服务路线的首次配置见 [USB 配对工具](Scripts/pair-device-usb.md)。日常任务在手机上运行，但这些路线依赖 DDI 开发者框架与私有接口，不承诺 App Store 分发。蓝牙与 S3 USB 输入不需要这套配对流程。

首次引导和设备页直接展示设置步骤，不再另开帮助页。已保存的配对身份会在连接时检查，不代表设备操作已经就绪。卸载后，钥匙串中的配对身份和系统 VPN 配置可能仍然保留。「重新配对」只移除 Eiscue 的配对身份，保留模型配置和密钥；移除 Eiscue 的 VPN 配置需在 iOS 设置中单独操作。

「复制命令」包含先下载源码、再运行配对工具的完整步骤。在 Mac 终端的**任意目录**粘贴整段执行即可；命令会创建新的临时源码目录，不改动已有文件夹：

```sh
eiscue_setup_dir="$(mktemp -d -t eiscue-setup)" &&
git clone --depth 1 https://github.com/LLLLLayer/Eiscue.git "$eiscue_setup_dir" &&
python3 "$eiscue_setup_dir/Scripts/setup-device.py"
```

Mac 需安装 Xcode 26+、Python 3.9+、Rust 1.96.0 并保持联网。设备信任、开发者模式和 Xcode 开发准备仍需完成，命令不会安装这些工具或准备 DDI。它让用户选择并确认 USB 设备，再生成身份并传入已安装的 Eiscue，不覆盖待导入文件、不代替 App 导入或启动 VPN。App 会在同一页面检测收到的文件，点「导入电脑发送的配对」，再点「连接设备」。源码及构建缓存保留在 Mac 临时目录，工具发送后会删除单独保存的私密配对文件；首次编译可能下载已锁定的 Cargo 依赖。

已有源码的开发者仍可在项目文件夹运行 `python3 Scripts/setup-device.py`。便捷工具仅支持 macOS，原有底层配对工具保持独立。

C3 屏幕伙伴仅显示固定阶段、表情和步数，不显示模型文字。短按 OK 键锁存停止；松开后长按约 1.5 秒、再断开连接才解除，随后需要重新连接与校准。

## 架构

```text
Eiscue App（SwiftUI，iOS 26+）
├── 对话、模型设置、附件、语音、Skill、任务记录、后台执行
├── DeviceToolSession：模型工具调用 → DeviceDecision
├── DeviceTaskRunner：权限、预算、串行执行、动作后观察
├── EiscueAgentKit：Agent / 工具 / 事件协议，内部适配 PiDurableKit
└── EiscueDeviceKit：DeviceController 协议
    ├── BluetoothDeviceController：BLE / USB HID + ReplayKit
    └── 开发者服务：RemotePairing → iOS 26 App 内 XCTest 截图与输入

扩展：EiscueBroadcast（屏幕共享）、EiscueTunnel（仅本地 VPN 路线）
固件：Passport-BLE（C3 / S3 HID）、NCM-Relay（S3 USB 网卡）
```

两个 Kit 是独立、互不依赖的 Swift Package library，由 App 集成层连接，没有单独的 Plugin 产品：

| Kit | 职责 | 替换入口 |
| --- | --- | --- |
| [EiscueAgentKit](Sources/EiscueAgentKit/AgentClient.swift) | Agent、工具、事件和会话存储；内部通过 JavaScriptCore 运行 PiDurableKit，每个会话一个 SQLite | `AgentClient(engine:)`，也可注册自己的 Swift 工具 |
| [EiscueDeviceKit](Sources/EiscueDeviceKit/DeviceClient.swift) | 连接、观察、动作和能力状态 | `DeviceClient(controller:)` |

公开 API 不暴露 PiDurableKit 或 actell 类型。贡献与维护规则见 [AGENTS.md](AGENTS.md)。

## 构建与测试

**先保留锁文件现状。** SwiftPM 可能移除 `Package.resolved` 中仅 Xcode 使用的 swift-markdown / swift-cmark 锁定项。运行前记录并保留已有修改，运行后检查差异，只还原本轮产生的变化；不要无条件恢复整个文件。

在仓库根目录执行：

```sh
xcodegen generate

# Kit 测试：使用本地模型 fixture，不调用真实模型
swift test

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

### 已记录的测试基线

保存检查日志时，可使用 `bash Scripts/run-logged-check.sh .build/<唯一名称>.log <命令> [参数...]`。脚本保留已有日志，并返回检查命令的真实退出码；失败不会被包装成成功。

2026-10-14，提交 `efb7703`，Xcode 26.3，iPhone 16e / iOS 26.3 模拟器：

| 套件 | 结果 |
| --- | --- |
| Swift Kit | 149 项 / 19 套件，4 项失败（10 个 issue） |
| App 单元测试 | 226 项通过 |
| UI 测试 | 44 项：34 通过、5 跳过、5 失败 |
| 固件主机测试 | 板端认证 6 组、C3 屏幕伙伴 5 组通过；NCM 中继主机测试本轮未运行 |
| 设备后端 | Rust 库测试 64 项、ObjC 自动化桥 332 项检查通过 |

当时 Kit 的 4 项失败和 UI 的 2 项失败已定位为文案或界面层级断言过时。另 3 项分享测试未找到系统面板标识；截图只能证明面板已打开，不能证明保存、关闭与读回成功。跳过项需要真机或 iPad；上述失败套件在该基线下不能作为绿色门禁。

2026-10-14 后续定向检查通过了 4 项 Kit、12 项 App 和 10 项 UI 用例（iPhone 8 项、iPad 2 项）。覆盖工具图片只读恢复、截图详情与预览、长按菜单、键盘导航、模型参数持久化，以及系统文件分享的打开、关闭和再次打开；保存、读回和照片分享未复跑。这些检查不替代全量基线，也不代表真机控制验收；中间失败记录保留在本地验证文档中。

2026-10-14 移除热点中继后，另通过 21 个 Kit 测试、34 个 App 测试、3 个设备页 UI 测试、14 个离线固件工具测试和 64 个 Rust 库测试，并重建三个原生后端切片。这些定向检查不替代完整基线，也不证明实际 USB／蓝牙行为。

2026-10-15 在 `14d154f` 上完整复核：155 项 Kit 中 4 项失败，242 项 App 单测通过，56 项 UI 中 42 通过、5 失败、9 跳过；Xcode 27 还暴露了 provider 测试 fixture 的并发编译错误。修复后，**Xcode 26.3 和 27 各通过全部 155 项 Kit／19 套件**，**7 项模型配置 App 单测通过**，定向 UI **16 个不同用例通过、1 个真机专项跳过**。覆盖移除自定义名称后的模型配置、密钥保留、时间线／暂停展示、系统文件／照片分享，以及保存到文件后的逐字节读回。中间失败记录保留；修复后未重新跑满 56 项 UI，也不代表真机控制验收。

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

- **C3 BLE**：按 [分区说明](Firmware/Passport-BLE/README.md#build-and-flash-layout) 先完整备份并核对已有布局；在已经核验匹配布局的开发板上更新固件时，只写 `0x20000` 应用分区，保留 `0xF000` 私有配置。当前通用烧录工具没有 C3 BLE profile。
- **S3 HID / 中继固件**：`board-firmware.py` 支持 `s3-hid` 和 `ncm`。需先生成并验证对应固件包，`flash` 必须指定 `--port` 和 `--package`，会完整备份 Flash 再写入和校验，不擦整片、不写 eFuse。参数见 `python3 Scripts/board-firmware.py --help`，布局见各固件 README；S3 不可复用 C3 分区表。

## 权限、数据与隐私

- 任务开始时固定权限范围；普通聊天不注册工具。设备工具只按实际后端能力开放，动作绑定最新有效截图且只能消费一次；送达结果不明时不会自动重发。
- 无进展或达到步数上限时暂停，用户点“继续”后以新请求重新观察。中断恢复只读，不自动续跑。导入的 Skill 只是 Markdown 说明，不能扩大权限或执行脚本。
- 会话、运行时 SQLite、任务记录、Skill 和附件位于 App 沙盒的 `Application Support/Eiscue/`。API Key 与配对私钥保存在仅本设备可用的 Keychain，不进入 UserDefaults、日志或导出报告。
- ReplayKit 扩展只保留最新 JPEG 帧（最长边 ≤ 1600 px），存放于受文件保护的 App Group，不保留录屏历史、不采集音频。**观察工具与动作后的自动观察都会将截图返回给模型**；仅开启共享或手动预览不会上传。工具历史可能把截图保存在会话 SQLite 中，删除会话时一并清理。
- 文字输入会覆盖剪贴板并粘贴，不读取原有内容。附件复制到私有存储，图片重新编码以去除 EXIF，仅在发送时交给模型；语音在本机识别，音频不落盘。
- 导出报告只含允许的元信息和工具状态，不包含 Key、配对信息、原始截图或完整输入参数。删除 API Key 不会删除会话。

后台设备任务通过 `BGContinuedProcessingTask` 申请继续执行，系统可以取消或结束。蓝牙、ReplayKit、VPN 或灵动岛显示本身都不提供后台执行时长保证。AX 界面树、PiP、Mac / Android / 鸿蒙后端仍是后续方向。

## 许可与来源

整个 Eiscue 尚未选定统一发行许可。以下仅记录各组件自带的许可与来源：

| 组件 | 来源 / 许可 |
| --- | --- |
| [DeviceBackend](Vendor/DeviceBackend/README.md) | actell 固定提交，GPL-3.0-only；内含 MIT 的 idevice。App 始终链接此后端，选择蓝牙路线不会将其从二进制中移除 |
| [LocalTunnel](Vendor/LocalTunnel/README.md) | LocalDevVPN / StosVPN 衍生实现，自定义 StosVPN License；来源作者见目录内声明 |
| [Passport-BLE](Firmware/Passport-BLE/README.md#license-and-api-references) | 原创固件代码为 Apache-2.0；依赖声明见固件目录。[表情资源](Firmware/Passport-BLE/Resources/README.md)不因固件代码许可而被授予同样许可 |
| [NCM-Relay](Firmware/NCM-Relay/README.md) | 上游组合项目声明 GPL-3.0-only，本地文件带 GPL-3.0-or-later 头；详见其 `SOURCE_MANIFEST.json` |
| PiDurableKit | 固定 commit，CC0-1.0；嵌入的 JS 依赖另有声明 |
| swift-markdown / swift-cmark | 固定 0.9.0；许可全文随 [App 资源](Apps/Eiscue/Resources/OpenSourceLicenses) 提供 |

依赖版本见 [Package.swift](Package.swift) 与 [project.yml](project.yml)。
