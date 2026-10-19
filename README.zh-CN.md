# Eiscue

[English](README.md) | **简体中文**

运行在 **iPhone / iPad** 上的 Agent 设备助手，最低支持 **iOS / iPadOS 26.0**。

对话、任务编排和工具执行都在手机内完成，模型通过用户配置的 HTTPS 服务调用。除了聊天，Eiscue 还可以在用户允许时观察并操作这台设备。

> 当前为开发预览（`0.1.0`），通过 Xcode 开发签名安装，尚未上架或进入 TestFlight。内部方案和完整验收记录不随仓库发布；公开的构建、固件和第三方来源说明见下方链接。

## 主要功能

- **聊天与多模型**：支持 OpenAI Chat Completions、OpenAI Responses、Anthropic Messages；保存多组服务和模型，在对话顶部切换。新配置直接使用模型 ID 显示，不再单独填写名称。每组 API Key 独立保存在 Keychain。
- **设备操作**：模型根据截图决定点击、滑动或输入；每次动作后自动截图供模型核对。首次使用默认选择 **App 内连接（本地 VPN）**，需要首次配对：iOS 26 使用电脑 USB 配对，iOS 27 起可从系统发起配对。也可选 **蓝牙开发板 + 系统屏幕共享**，开发板只需供电，不占手机 Wi-Fi 或 VPN 通道。已保存且仍支持的连接方式会保留。
- **语言**：默认跟随系统；从设置 → App 语言进入 iOS 设置，可单独选择中文或英文。
- **附件与语音**：支持照片、拍摄、文本／代码文件、可提取文字的 PDF，以及 Apple Speech 本机听写，无需语音 API Key。点击开始／结束，也可按住说话；识别结果回填草稿后再编辑发送。录音时灰色背景延伸到导航栏与玻璃输入框后方，波形反馈真实麦克风音量，不改变输入框布局。切换到语音模式会保留设备连接。iOS 27+ 的 CoreDevice 已连接时，开始录音会在授权通过后暂时释放控制，确认释放后才开始收音；结束后自动恢复控制，保留配对和 VPN。转写完成后语音按钮立即恢复，设备重连通过独立提示展示并支持取消；重连或取消清理结束后可发送。其他控制方式不受影响。切后台或失联会取消待恢复连接，释放未确认单独提示；连接失败保留草稿。以前 App 进程遗留会话的恢复仍未实现。
- **对话管理**：流式回答、Markdown、工具进展与分享；长按文字消息直接全选并显示系统编辑菜单，可拖动选区调整范围；图片和文件保留长按分享入口；侧栏显示最近更新时间，支持置顶、排序、重命名，长按会话进入多选后可批量操作，iPad 宽窗口支持常驻侧栏。右滑打开、左滑收回；删除会话会同步删除其任务记录；顶部会话菜单可查看当前会话的任务记录。任务详情以一条时间线展示步骤与日志，并显示供应商实际返回的输入／输出及缓存 token 用量；缺失项保持未知，中断／恢复记录的汇总标为部分，不估算费用。全屏截图支持捏合、双击缩放；未放大时向任意方向滑动关闭，短距离拖动回弹。
- **任务与后台**：支持停止、暂停后显式继续和脱敏报告；任务详情可查看已保存的输入输出、截图，以及原图可用时的点击和滑动位置。正常结束任务后默认保留连接，可在设备页手动断开，或在设置中开启「任务结束后断开」。切换 App 本身不会主动断连，但不保证 iOS 或网络会一直维持闲置会话。使用 iOS 26 系统实时活动显示当前阶段和结束状态；进度环按固定规模记录真实完成步骤，执行期间保持接近空环；iOS 可能提前结束后台执行，并控制完成后的收起（[Apple API](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)、[WWDC25](https://developer.apple.com/videos/play/wwdc2025/227/)）。系统活动收到结果后不重复发送通知，否则可使用完成 / 中断通知，默认关闭。
- **界面与扩展**：原生 Liquid Glass、浅色 / 深色模式、中英文界面；可导入 UTF-8 Markdown Skill。设置按小标题分区；三套[矢量头部形象](Artwork/EiscueHeads/README.md)支持眨眼、左右看和随朝向改变各面形状的立方体转头，未连接时闭眼缓慢转头；对话欢迎区保留静态插画，右上角设备按钮和设备页用动画表情展示连接状态，并遵循系统「减少动态效果」。各连接方式的屏幕预览和重复输入检查统一收在设备页的调试分区。设置中的「调试」开关仅 Debug 包可见，默认开启，可关闭并记住选择；Release 包不展示开关及这些诊断入口。必需的 HID 校准在完成前仍对所有版本开放。带 ST7789 屏幕的指定 C3 开发板还可显示表情、任务阶段与已完成步数。

## 当前验证状态

| 能力 | 状态 |
| --- | --- |
| 对话、多模型、流式回答、Markdown、附件、本机听写、中英文界面 | 已实现，有模拟器测试覆盖；带日期的结果和待完成的真机检查见下文 |
| C3 / S3 蓝牙连接、ReplayKit、四点触摸与中文输入检查 | 已在指定 iPhone 14 Pro / iOS 26.5.2 通过；2026-10-18 在 iPhone 12 mini / iOS 27 上，C3／S3 多次人工四点／中文检查通过；S3 的有限 BLE 滑动通过见下文 |
| App 内连接，iOS 26 + XCTest | 2026-10-13 在 iPhone 14 Pro / iOS 26.5.2 的 Eiscue 自有检查页通过确定性检查：两轮连接、点击、滑动、Unicode 文字、旋转后拒绝旧截图，以及短时后台截图 |
| App 内连接，iOS 27 | 2026-10-18 在 iPhone 12 mini 上，XCTest 自有检查页 full 通过；CoreDevice 有单次 full 通过，也反复出现旋转／输入失败，一次真实模型计算器任务通过；更广稳定性和任务覆盖仍待验收 |
| C3 蓝牙滑动、更广的跨 App Agent 覆盖、真实模型长后台 | 代码已接入，**尚未真机验收** |
| S3 蓝牙滑动 | 单次竖屏自有页面点击、中文、六个相对探针及零模型宿主实际滑动通过；更广覆盖仍待验收 |
| S3 USB 输入：命令走蓝牙，键鼠经 USB | 单次竖屏自有页面四点、中文、六个相对探针及实际滑动通过；更广覆盖仍待验收 |
| S3 USB 网卡 | iPhone 12 mini / iOS 27 上 CoreDevice／XCTest 各单次前台滑动，CoreDevice 停止门控／确认清理及短后台观察通过；更广覆盖仍待验收 |
| iCTRL 等其他后端 | 仅完成源码调研，未集成 |

**源码接入、软件测试和真机验收分别记录。** 模拟器无法验证蓝牙 HID、系统屏幕共享或后台时长；单台样机的结果不能外推到其他机型和系统版本。

## 快速开始

### 运行与配置

1. 准备 Apple Silicon Mac、Xcode 26+ 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.45+。在仓库根目录运行 `xcodegen generate`，再打开 `Eiscue.xcodeproj`，选择 `Eiscue` scheme。
2. 在 iOS 26+ 模拟器运行时保留默认本地签名，否则 Keychain 不可用。真机运行需在 `project.yml` 配置自己的开发团队与 Bundle ID，再重新生成项目。主 App 和屏幕共享扩展共用 App Group；主 App 和本地 VPN 扩展需要 Network Extension 的 `packet-tunnel-provider` 能力。默认标识为 `org.eiscue.app` 和 `group.org.eiscue.app`，修改时需同步后缀、扩展与共享组配置，详见 [AGENTS.md](AGENTS.md)。
3. 首次引导或「设置 → 模型」中填写服务地址、模型 ID 和 API Key。支持保存多组配置；已有 Key 显示为已保存，需要修改时点“更换”。保存配置不会请求模型。

模型服务地址必须使用 HTTPS。OpenAI 兼容服务通常包含 `/v1`；Anthropic 使用 `https://api.anthropic.com`。设备任务还要求模型支持图片和工具调用。只聊天不需要开发板或屏幕共享。

### 仅 HID 构建

选择 `EiscueHID` scheme 可构建独立 App，只包含 ESP32 BLE / USB HID 与 ReplayKit。它默认使用 ESP32 键鼠，采用 `org.eiscue.hid`、`group.org.eiscue.hid`，仅嵌入自己的屏幕共享扩展。包依赖和编译产物不包含开发者服务后端、XCTest 桥或 VPN 扩展；完整 `Eiscue` App 运行时选择蓝牙并不会移除这些组件。两种 App 的模型配置、会话和共享授权互相独立；一个 App 保存的 S3 认证密钥不会自动迁移给另一个，也不会自动覆盖已有注册。这次构建拆分不代表 App Store 已批准，也不授予新的图片或组件许可。

其他宿主可依赖 `EiscueHIDKit` product，`import EiscueDeviceCore`，并创建 `let board = BluetoothDeviceController(); let client = DeviceClient(actuator: board, hidSetup: board)`。完整 `EiscueDeviceKit` 保留 `DeviceClient()` 和 `DeviceClient(identityStore:)`。可通过 `python3 Scripts/check-hid-boundary.py --app <EiscueHID.app路径>` 检查构建边界。

### 让 AI 操作设备

默认的 **App 内连接** 在 iOS 27 起提供系统配对，同时保留导入已有兼容配对文件的入口。点“开始配对”，前往「设置 → 隐私与安全性 → 开发者模式」，选择 Eiscue 并点“配对”确认，返回 Eiscue 查看验证码，再到系统输入。iOS 26 使用五步引导：准备 Mac、USB 连接设备、运行可复制的命令、导入配对、连接设备。完整命令和要求见下文。选中连接方式不会自动启动连接。

2026-10-14 已在一台 iOS 27 设备上使用诊断版完成系统配对；该结果不代表默认服务发布配置或截图、输入已验收。开发者模式与兼容 DDI 的准备仍是独立要求，尚不能据此宣称整个首次配置完全不需要电脑。

如需使用蓝牙方案：

1. 按 [C3 / S3 固件说明](Firmware/Passport-BLE/README.md#build-and-flash-layout) 准备蓝牙固件，给开发板供电。
2. 在 iPhone「设置 → 辅助功能 → 触控 → 辅助触控」开启辅助触控。
3. 打开 Eiscue 右上角设备页，选择“ESP32 键鼠”；S3 还需选择“蓝牙输入”或“USB 输入”。依次连接、在系统面板开启屏幕共享、开始检查。检查期间保持页面可见，不触屏、不旋转；App 会验证四次真实触摸和一次文字输入；支持相对拖动的固件还会自动做六次短移动检查。移动检查通过后才提供滑动能力，旧固件或移动检查未通过时仍保留已验证的点击和输入。
4. 就绪后回到对话下达任务。“允许 AI 操作设备”默认开启，可在设备页关闭。设备未就绪时，新消息按普通聊天处理。

连接、共享、校准必须同时有效。断开、旋转、共享会话或画面尺寸变化会使旧校准失效，需要重新检查。路线之间不会自动回退。

### 连接方式

| 路线 | 画面 / 输入 | 首次准备 | 占用 Eiscue VPN 通道 |
| --- | --- | --- | --- |
| 蓝牙开发板（C3 / S3） | ReplayKit / BLE HID | 蓝牙配对、辅助触控、共享与校准；不需要电脑配对文件或 DDI | 否 |
| S3 USB 输入 | ReplayKit / USB HID，控制命令仍走蓝牙 | 同上，另需手机作为 USB 主机连接开发板 | 否 |
| App 内连接（默认，本地 VPN） | 可选 DisplayService 或 XCTest | iOS 26 电脑 USB 身份建立，或 iOS 27 起系统配对；另需开发者环境 / DDI | 是 |
| S3 USB 网卡 | 同上，经 USB NCM 中继 | 同上，另需 USB 主机连接与网卡配置 | 否 |

**控制方式**与连接通道、配对分开选择。App 内连接和 USB 网卡中继提供 **DisplayService（CoreDevice）、XCTest**。首次默认选择在 iOS 26 为 XCTest、iOS 27 起为 DisplayService；旧的自动选项直接显示其实际方式。iOS 26 仍显示 DisplayService 入口，但不可选，并标注“需要 iOS 27 或更新版本”，仅更新 App 不能启用。选择当前实际使用的方式会保留连接。切换到另一种方式会释放当前连接、保留配对身份，需要重新连接，不会自动回退。各次检查与剩余边界见下方[真机记录](#真机记录)。

原 C3 Wi-Fi 热点中继已移除。旧的已保存选项会回到默认的 App 内连接，但不会自动启动；请手动选择并连接仍支持的路线。

**USB 输入与 USB 网卡是两条不同路线。** S3 USB 输入使用板子的原生 USB / OTG 口；USB-C 手机使用 C-to-C 数据线，Lightning 手机需要带供电的 USB 主机（相机）转接器，普通 Lightning 数据线不适用。COM / UART 口用于电脑烧录与日志。手机、线材和转接器组合仍需实际验证。

开发者服务路线的首次配置见 [USB 配对工具](Scripts/pair-device-usb.md)。日常任务在手机上运行，但这些路线依赖 DDI 开发者框架与私有接口，不承诺 App Store 分发。蓝牙与 S3 USB 输入不需要这套配对流程。

首次引导和设备页直接展示设置步骤，不再另开帮助页。已保存的配对身份会在连接时检查，不代表设备操作已经就绪。卸载后，钥匙串中的配对身份和系统 VPN 配置可能仍然保留。「设置 → 连接修复 → 重置配对」只移除 Eiscue 的配对身份，保留模型配置和密钥；需先断开连接，再确认重置。移除 Eiscue 的 VPN 配置需在 iOS 设置中单独操作。

「复制命令」包含先下载源码、再运行配对工具的完整步骤。在 Mac 终端的**任意目录**粘贴整段执行即可；命令会创建新的临时源码目录，不改动已有文件夹：

```sh
eiscue_setup_dir="$(mktemp -d -t eiscue-setup)" &&
git clone --depth 1 https://github.com/LLLLLayer/Eiscue.git "$eiscue_setup_dir" &&
python3 "$eiscue_setup_dir/Scripts/setup-device.py" --app-pairing-schema 1
```

Mac 需安装 Xcode 26+、Python 3.9+、Rust 1.96.0 并保持联网。设备信任、开发者模式和 Xcode 开发准备仍需完成，命令不会安装这些工具或准备 DDI。它让用户选择并确认 USB 设备，再生成身份并传入已安装的 Eiscue，不覆盖待导入文件、不代替 App 导入或启动 VPN。工具协商支持的配对 schema 并在发送前校验；保留 v1 JSON／plist 兼容，App 导入时拒绝未知版本。App 会在同一页面检测收到的文件，点「导入电脑发送的配对」，再点「连接」（首次引导中为「连接设备」）。源码及构建缓存保留在 Mac 临时目录，工具发送后会删除单独保存的私密配对文件；首次编译可能下载已锁定的 Cargo 依赖。

已有源码的开发者仍可在项目文件夹运行 `python3 Scripts/setup-device.py --app-pairing-schema 1`。便捷工具仅支持 macOS，原有底层配对工具保持独立。

C3 屏幕伙伴仅显示固定阶段、表情和步数，不显示模型文字。短按 OK 键锁存停止；松开后长按约 1.5 秒、再断开连接才解除，随后需要重新连接与校准。

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
固件：Passport-BLE（C3 / S3 HID）、NCM-Relay（S3 USB 网卡）
```

Agent 与 Device 库互不依赖，由 App 集成层连接；两个 Device product 共享 Core 模块，没有单独的 Plugin 产品：

| Kit | 职责 | 替换入口 |
| --- | --- | --- |
| [EiscueAgentKit](Sources/EiscueAgentKit/AgentClient.swift) | Agent、工具、事件和会话存储；内部通过 JavaScriptCore 运行 PiDurableKit，每个会话一个 SQLite | `AgentClient(engine:)`，也可注册自己的 Swift 工具 |
| [EiscueDeviceKit](Sources/EiscueDeviceCore/DeviceClient.swift) | 连接、观察、动作和能力状态 | `DeviceClient(actuator:networkSetup:hidSetup:)` |

集成 DeviceKit XCTest 后端的 App 需在真机 target 的 `LD_RUNPATH_SEARCH_PATHS` 中保留继承路径，并添加 `/System/Developer/usr/lib` 和 `/Developer/usr/lib`。Xcode 27 的开发镜像通过这些路径加载 Testing 互操作依赖。Eiscue 已在 `project.yml` 配置；Apple 测试库从已挂载 DDI 动态加载，不随 App 打包。

公开 API 不暴露 PiDurableKit 或 actell 类型。贡献与维护规则见 [AGENTS.md](AGENTS.md)。

## 构建与测试

Kit 测试优先使用下面的隔离脚本，它不会改写实际的 `Package.resolved` 或暂存状态；直接运行 `swift test` 可能移除仅 Xcode 使用的锁定项。每套工具链使用独立 scratch 目录。[CI 配置说明](Scripts/ci.md)列出两套 Xcode/iOS 门禁、所需的自托管 runner 及本地运行方式；提交工作流不代表已经配置 runner 或分支保护。

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

### 已记录的测试基线

保存检查日志时，可使用 `bash Scripts/run-logged-check.sh .build/<唯一名称>.log <命令> [参数...]`。脚本保留已有日志，并返回检查命令的真实退出码；失败不会被包装成成功。

**2026-10-17 架构迭代复核**，分别使用 Xcode 26.3 / Swift 6.2.4 与 Xcode 27 / Swift 6.4。本轮未使用真机、开发板或真实模型：

| 检查 | 结果 |
| --- | --- |
| Swift Kit | 两套工具链各 209 项通过 |
| App 单元测试，iOS 26.3.1 | 426 通过、0 失败 |
| App 单元测试，iOS 27.0 | 425 通过、1 项系统专用跳过、0 失败 |
| 连接 / 引导 / 听写 / 结果未知 UI，iOS 26.3.1 | 10 通过、5 项 iOS 27 专用跳过、0 失败 |
| 同组专项 UI，iOS 27.0 | 15 项全通过；最后的编排错误归类窄修后，两系统各重跑结果未知的 2 项并通过 |
| Release App 构建 | 完整版和纯 HID 版均在两套 Xcode 构建通过；HID 依赖图与产物边界审计通过 |
| HID App 单元测试 | 本轮 3 项通过；最后编排窄修后补了 Release 检查 |
| 生成工程 | 重新生成无差异 |

成功命令均返回 exit 0，跳过不计为通过。日志和结果包仅保留在本地 `.build/`。当前为相关 UI 专项检查，没有重新跑整套 UI。此前 `c4fc538` 基线的 iPhone 完整 UI 已在两系统通过（iOS 26：59 通过 / 13 跳过；iOS 27：63 通过 / 9 跳过），iPad 侧栏 / 会话 / 分享为 10 通过 / 1 项布局跳过；这些历史结果不能证明后续变更已验收。

更广的硬件验收仍待补充：C3/S3 手势与旋转、外部失联、真实模型长后台和更广的 Agent 任务。下方 10 月 18／19 日的局部手机结果覆盖有限确定性脚本与一次实际模型计算器任务。hosted Ubuntu 工作流配置为在 main push、PR 和手动触发时运行离线 Python helper；Apple 检查要求 `EISCUE_APPLE_RUNNERS_ENABLED=true` 和已注册自托管 runner，目前尚无 runner 或分支保护。hosted helper 不验证 Swift 或 Apple 构建。更早的失败和中间运行保留在本地验证记录中。

2026-10-20 软件迭代加入可取消的语音恢复、配对 schema 协商、可选供应商用量、侧栏缓存与异步图片预览解码。完整 Kits 两套工具链各通过 242 项；App 单测 iOS 26 通过 501 项、iOS 27 通过 500 项并有 1 项平台跳过；23 项离线 Python 检查通过。iOS 27 四项聚焦 UI、Xcode 26 HID Release 构建／边界审计和 Xcode 27 完整版 Release 构建通过；上述软件检查未使用手机、开发板或真实模型，随后进行的手机检查另记如下。

### 真机记录

- **2026-10-18，iPhone 12 mini / iOS 27.0（24A437），本地 VPN**：同一 App 版本、同一竖直持机条件下，XCTest full 通过旋转旧帧拒绝、新帧输入、滑动、Unicode、短后台／返回及两轮确认释放，CoreDevice 的新横屏点击仍失败。未解决的点击问题由此收窄到 CoreDevice 输入路径；根因仍未确定，横屏控制仍未验收。恢复的后端通过 79 项 Rust 测试，Geometry 在 Xcode 26.3／27 各通过八项。清理后的完整版／HID Release 构建与 HID 边界审计通过。
- **同机同日的一次实际模型计算器任务**：CoreDevice 完成 17×23=391，已目视核查计算器画面，并自动返回 Eiscue，约 106.5 秒，无清理失败。模型直接启动 Eiscue，没有调用 Home；此前 Home／核验失败保留。只计 A1 单次通过，不证明横屏稳定、XCTest 实际模型验收或更广任务覆盖。
- **同机同日的有限后台与停止检查**：两后端各通过一个约十分钟的零模型正常宿主脚本窗口，并确认清理；各有一次真实滑动在途中停止通过，工作结果保持 unknown，并完成确认清理，已提交的触控仍按原计划完成。最新按路线判断的清理改动在 iOS 26.3.1 与 iOS 27 各通过 80 项 App 专项单测，保留 HID 原始确认状态和独立清理错误，网络路线仍严格要求释放确认。这些结果不覆盖真实模型长后台、系统取消、外部失联或全部停止／继续路径。

- **同机同日的 C3 BLE 检查**：加密命令／状态通道、ReplayKit、人工启动的四点／中文输入检查通过。已修复并真机复验校准页退出误清除已有映射的问题。确定性滑动仍未通过可见滚动检查，一次正常工具序列完成后保留 BLE、共享和校准，但滑动目标仍失败。相对拖动固件与校准修改尚未经硬件验收；校准和诊断相关回归在两套 Xcode 工具链通过。没有更新固件或调用模型 API。
- **同机 2026-10-18/19 的 S3 HID 检查**：当前固件 BLE 与 USB 输出各单次通过竖屏自有页面点击／中文／六探针及零模型实际滑动；各通过一次在途停止门控／本地清理，工作结果保持 unknown。USB 另通过 60.773 秒只截图后台检查；BLE 后台准备超时、未提交；后续一轮实际入后台 1.322 秒即 expiration，没有后台样本。最新 DEBUG 切后台／取图和 expiration 分类修正在两套 Xcode 工具链通过聚焦软件检查，尚未真机复测。HID 原始清理确认=false，由本地策略接受；正常诊断 teardown 结束共享。早期失败保留，真实模型、跨 App、后台输入、旋转和多轮稳定仍待验收，C3 未操作。
- **2026-10-19，同机 S3 USB NCM**：CoreDevice／XCTest 各单次前台滑动、CoreDevice 停止门控／确认清理和 61.429 秒后台观察窗口通过，零模型调用。已提交的两秒拖动仍走完，stop 后约 1.471 秒才结束触点。USB 接口绑定排除 Wi-Fi／VPN 回退；公司 VPN 共存未验。此次为保留现有 16 MB HID 布局的已验证 app-only 镜像，与默认 4 MB NCM 包不同，不能跨布局直接刷写默认包。XCTest 后台／停止、iOS 26 与更广覆盖仍待验收。
- **iOS 27 受控时的麦克风**：2026-10-15 在 iPhone 12 mini / iOS 27 上，CoreDevice 连接前收到非零音频，连接期间全部为零且系统报告远程控制静音，确认释放屏幕会话后恢复非零音频；配对和 VPN 保持不变。Apple 官方记录了 [Device Hub 的相机／麦克风冲突](https://developer.apple.com/documentation/xcode/interacting-with-your-app-in-device-hub#Handle-camera-and-microphone-access-conflicts-on-physical-devices)。10 月 18 日两后端各一次按住录音／取消检查均记录到非零 PCM、草稿保留和所选路线恢复就绪。两后端还各通过一次模式切换／按住后松手正常结束的生命周期检查，包含非零 PCM 与所选连接恢复或保持就绪。检查期间存在外部 XCTest runner；转写和多轮稳定性尚未验收。
- **2026-10-20 语音复验，同一手机与本地 VPN**：两后端各一次模式切换／按住后松手检查通过，均收到非零 PCM、草稿未变，结束后所选连接就绪；另各通过一次实际录音中退后台取消。返回时 CoreDevice 控制保持断开、VPN 保留，XCTest 保持就绪。外部操作器确认本轮非零收音后才启动计算器；没有调用模型 API 或使用开发板。这些自动检查不代表转写、多轮稳定性、无外部 runner 或跨进程遗留会话恢复验收。
- **同机同日的手动转写**：用户按 CoreDevice 语音步骤试用，反馈识别出文字且连接恢复。计一次用户反馈通过；连续使用和其他路线的实际转写仍待验证。
- **同机同日的活会话状态复查**：一次 DEBUG 专用的 CoreDevice 只读查询，确认调用方 client-session UUID 和两个活屏幕流标识在同一条服务器会话中匹配；导出的文件只含计数和布尔值。Rust 库测试通过 88 项，诊断格式在两套工具链各通过 4 项，语音／连接回归在两套模拟器系统各通过 93 项。预览 UI helper 因 Debug 工具关闭而跳过，未执行预览；未使用模型或开发板。这没有实现或验收 App 进程重启后的清理，持久启动／停止记录与启动媒体前的审计入口仍待开发。
- **被终止进程遗留的会话**：同一手机在 App 重启后仍收到全零音频，系统继续报告远程控制静音。配对和 VPN 可以复用，但仅凭配对无法恢复或释放之前进程的屏幕会话；重启手机后恢复收音。跨 App 进程重启的自动清理尚未实现。
- **设置 → 连接修复 → 重置连接并检查**会释放 Eiscue 当前的控制连接，保留配对、VPN 和聊天记录，再短暂采样麦克风，不进行语音识别或保存音频。连接释放与收音结果分别显示，二者都不能证明不存在更早遗留的会话。2026-10-20 从已连接 CoreDevice 开始的一次修复 UI 检查报告释放成功、检测到麦克风输入，路线／后端保留且 UI 占用已解除；没有独立 PCM 导出或远端会话审计。先保持 Eiscue 前台再次检查，仅在控制已断开但仍无法收音时重启，保留配对和 VPN。

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

会话存储使用小型索引、每会话一个记录文件和共享的 SHA-256 附件数据。加载时隔离损坏的会话并报告 ID；无法完整校验时暂停回收，保留原始数据。运行日志采用带序号和校验的只追加事件，结束时生成摘要；旧日志仍可读。SQLite 中的接收状态用于重建提交缓存，未提交任务的用户放弃决定单独保留在宿主日志中。旧版在首次写入时迁移并保留原始备份；首次明确删除会话后移除旧备份、清理不再引用的附件。中断的删除清理会在读取或后续写入时继续。原始文档保留以支持按原字节分享。新运行时元数据引用已有附件，不再重复存一份；旧 SQLite 记录仍可读取。

模型请求只保留最新两张设备截图，文字、工具调用关联与服务商签名保持完整，用户上传的图片不受影响。完整历史截图仍保存在会话 SQLite，供任务详情查看，删除会话时清理。`Runtime/` 不再进入设备备份；会话和原始附件沿用原有备份行为。任务记录增加系统指令版本。

- 任务开始时固定权限范围；普通聊天不注册工具。设备工具只按实际后端能力开放，动作绑定最新有效截图且只能消费一次。送达结果不明时停止并释放连接，对话显示“操作结果未确认”；用户核查屏幕、重新连接后才能明确继续，不提供重试该动作的按钮。继续设备任务时重新检查权限和就绪状态；设备任务清理结束前不能切换连接方式。
- 无进展或达到步数上限时暂停，用户点“继续”后以新请求重新观察。中断恢复只读，不自动续跑。导入的 Skill 只是 Markdown 说明，不能扩大权限或执行脚本。
- 会话、运行时 SQLite、任务记录、Skill 和附件位于 App 沙盒的 `Application Support/Eiscue/`。API Key 与配对私钥保存在仅本设备可用的 Keychain，不进入 UserDefaults、日志或导出报告。
- ReplayKit 扩展只保留最新 JPEG 帧（最长边 ≤ 1600 px），存放于受文件保护的 App Group，不保留录屏历史、不采集音频。**观察工具与动作后的自动观察都会将截图返回给模型**；仅开启共享或手动预览不会上传。工具历史可能把截图保存在会话 SQLite 中，删除会话时一并清理。
- Owned XCTest 通过启用内容脱敏的原生 Unicode 事件输入文字，不访问剪贴板。CoreDevice 与 ESP32 HID 的文字输入仍会覆盖剪贴板并粘贴，不读取原有内容。附件复制到私有存储，图片重新编码以去除 EXIF，仅在发送时交给模型；语音在本机识别，音频不落盘。
- 导出报告只含允许的元信息和工具状态，不包含 Key、配对信息、原始截图或完整输入参数。删除 API Key 不会删除会话。

后台设备任务通过 `BGContinuedProcessingTask` 申请继续执行，系统可以取消或结束。蓝牙、ReplayKit、VPN 或灵动岛显示本身都不提供后台执行时长保证。AX 界面树、PiP、Mac / Android / 鸿蒙后端仍是后续方向。

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
