# Eiscue

运行在 iPhone / iPad 上的 Agent 设备助手。App 最低 **iOS / iPadOS 26.0**。任务编排和工具执行在手机上，模型通过用户配置的网络服务调用。

内部方案和完整验收记录不随仓库发布；本页保留使用步骤和已验证范围，固件、工具与第三方来源说明保留在各目录的 README 中。

**默认使用蓝牙开发板：** 已配置 Eiscue 蓝牙固件的 ESP32-C3 或 ESP32-S3 开发板接充电器或电脑供电，**不用插到 iPhone，也不用切换手机 Wi-Fi**。正常 App 已接入蓝牙连接、Apple ReplayKit 屏幕共享，以及四点点击和文字输入检查；这条路径不需要配对文件、DDI 或本地 VPN。检查通过后，AI 操作设备能力即可用于新任务；默认开启，可在右上角设备页关闭。升级安装会保留已有连接偏好，可在设备页改选“蓝牙开发板”。S3 也支持在同一页选择“USB 输入”：USB-C 手机用 C-to-C 数据线连接板的原生 USB／OTG 口；Lightning 手机需用带供电的 USB 相机／主机转接器，普通 Lightning 数据线不能替代。COM／UART 口用于电脑，不能提供手机键鼠输入。蓝牙发送指令，USB 提供键鼠输入；Agent 与 ReplayKit 仍在手机内运行。这与“USB 网卡中继”是两条不同路线，不使用 Eiscue VPN。

**代码接入与真机结果：** 新版蓝牙固件已完成构建、烧录读回及加密连接能力查询；在指定 iPhone 14 Pro / iOS 26.5.2 上，普通 App 已通过 ReplayKit 屏幕共享、四点实际点击和中文文字检查，显示已就绪。当前仍需验证蓝牙滑动、完整跨 App 的 Agent 任务和长时间后台行为；本次未重复“禁用蜂窝访问的 Wi-Fi HTTPS”检查，该联网结论来自旧版蓝牙基线。Wi-Fi 开发板的独立控制路径已于 2026-10-11 在指定样机上通过。

iCTRL 已完成源码调研，尚未集成。

## 已实现

- 模型配置：OpenAI Chat Completions 兼容接口、OpenAI Responses、Anthropic Messages，支持保存多组地址、模型 ID 与名称，在对话顶部切换；每组 API Key 独立保存在系统 Keychain。
- Agent：真实 PiDurableKit 运行时、流式回答、多轮对话、图片工具结果、串行工具调用、停止、超时与调用次数限制。
- 会话与任务：发送后立即上屏并清空输入，流式回复、分开的真实工具记录、块级 Markdown、消息时间与选段复制；侧栏历史、长按置顶/排序/删除、恢复、脱敏报告导出，运行记录从对话菜单查看。
- 设备代码：蓝牙 HID 输入与 ReplayKit 屏幕共享通过 `BluetoothDeviceController` 接入同一 DeviceKit / Agent 工具协议。设备页直接提供连接、共享和校验入口，四点触摸与实际文字检查通过前不开放 AI 操作。蓝牙当前公开截图、点击、滑动及经校验的文本输入；新版固件在完成检查后还可开放返回主屏幕和搜索／回车／退出快捷键；应用列表和按 bundle ID 启动未向蓝牙 Agent 开放。
- 其他连接：保留本地 VPN、USB 开发板和 Wi-Fi 开发板的 RemotePairing / CoreDevice 路径。iOS 26 使用 App 内独立 XCTest 会话，已有 Wi-Fi 真机控制记录；这些路径才需要设备配对身份与开发者环境。ESP32-S3 的 [USB 固件](Firmware/NCM-Relay/README.md) 尚无实板 NCM 验证，ESP32-C3 不支持 USB NCM。同一 C3 样机的 [蓝牙固件](Firmware/Passport-BLE/README.md) 与 [Wi-Fi 固件](Firmware/Passport-Relay/README.md) 需要切换应用镜像，不能同时使用。
- 执行边界：右上角设备页的“允许 AI 操作设备”默认开启，手动关闭后会记住选择；设备未就绪时新消息仅聊天，不注入设备工具。任务开始时固定范围，Kit 另保留只读观察范围。坐标操作绑定新截图，单次使用，过期或重连后失效；未知操作结果不自动重发。
- 后台：iOS 26 的 BGContinuedProcessingTask 和系统实时活动，显示真实执行阶段；可选的完成／中断本地通知默认关闭，系统取消与过期统一停止。
- Skill：内置导航、只读搜索和中断核查流程，导入与删除 UTF-8 Markdown；不执行导入文件里的脚本。
- 原生界面：首次全屏入门引导，随浅色／深色模式切换的黑白灰控件与原生 Liquid Glass；对话主页面、左侧历史与设置、右上角设备状态，iPad 宽窗口支持常驻侧栏。使用用户提供的 Eiscue 图片作为图标。
- 附件与语音：照片、拍摄、文本/代码文件和可提取文字的 PDF；Apple Speech 本机听写，切换语音模式后按住说话、松开结束、上滑取消，无需语音 API Key。普通聊天默认使用简短提示，不注入表情 Skill 或设备工具。
- 多语言：Apple String Catalog 和 Swift Package 本地化资源，支持英文、简体中文，跟随系统／App 语言；新增语言无需修改业务逻辑。

**S3 本轮开发：** BLE／USB HID 固件和 App 输出选择已接入，命令与回复逐条认证；首次连接会自动保存本机 Keychain 密钥。首次登记仅在未绑定板上电后一分钟内开放，需在可信的近距离环境完成；已有密钥不能自动覆盖，丢失 App Keychain 时不能重新认领。该开发版的首次登记不提供抗中间人保证。S3 在指定 iPhone 14 Pro 上已通过认证命令、ReplayKit、四点真实触摸和随机中文粘贴校验。USB 曾在 Mac 完成枚举，但该轮手机收到 0 次点击，未通过；改线后确认使用普通 Lightning 数据线，手机没有 USB 主机连接。USB 手机验收等待合适转接器，不能计为通过。最新 USB 状态修复与该 BLE 已验收镜像的区别见固件 README。

**源码接入与真机验收是两件事。** 模拟器可验证 Agent 与 App 流程，但不能代替真机 BLE HID 输入与系统屏幕共享。指定手机的蓝牙四点和文字校验已通过，滑动、跨 App 与后台控制仍需验收；其他连接路径还涉及 DDI、回环 VPN 和配对身份。不同设备与系统版本不能直接沿用样机结果。

## 运行 App

1. 使用 Apple Silicon Mac 和 Xcode 26 或更新版本，打开 `Eiscue.xcodeproj`。
2. 选择 `Eiscue` scheme，在 iOS 26+ 模拟器运行。保留 Xcode 默认的本地签名，Keychain 需要正确的签名环境。
3. 真机运行时，在 Signing & Capabilities 选择自己的开发团队。默认 Bundle ID 为 `org.eiscue.app`。
4. 首次打开会显示全屏引导；在其中或「设置 → 模型配置」填入服务地址、模型 ID 和 API Key。其余参数有默认值，保存配置不会调用模型。
5. 仅对话可直接使用。设备任务先给已刷好蓝牙固件的开发板接电源，并在 iPhone「设置 → 辅助功能 → 触控 → 辅助触控」开启辅助触控。接着打开 App 右上角设备页，选择“蓝牙开发板”，依次连接、通过系统面板开启屏幕共享、完成操作检查；回到对话即可让 AI 操作设备；只想聊天时，可在右上角设备页关闭“允许 AI 操作设备”。

主 App 与 `EiscueBroadcast` 屏幕共享扩展需要匹配的 App Group 签名；仓库默认为 `group.org.eiscue.app`。随包保留的本地 VPN 扩展还需要 Network Extension capability。蓝牙使用过程不添加或启动 VPN。

下面的电脑配对说明只适用于保留的 RemotePairing 路径，不适用于蓝牙：iOS 26 的开发者模式页没有该后端要求的系统配对入口。[USB 配对工具](Scripts/pair-device-usb.md)已在上述测试机上完成身份建立；后续独立 XCTest 会话通过系统自动化授权，并完成 Wi-Fi 开发板控制验证。无需为重试控制而重复生成已经有效的身份。该路径无需额外 UI Test Runner，但依赖设备 DDI 中的开发者框架和私有接口，目前不承诺 App Store 分发。

App 当前仅接受 HTTPS 模型服务地址。OpenAI 兼容接口通常填写带 `/v1` 的地址；Anthropic 默认填写 `https://api.anthropic.com`。Kit 允许宿主自行配置本地 HTTP 服务。测试专用 loopback 配置只在 DEBUG 且显式 UI 测试模式下启用。

## 两个独立 Kit

`Package.swift` 对外提供两个 library product：

| 产品 | 负责 | 独立使用 |
|---|---|---|
| EiscueAgentKit | Eiscue 自有 Agent / 工具 / 事件协议、运行时适配、会话存储 | 注册自己的 Swift 工具，或注入 `AgentEngine` 替换引擎 |
| EiscueDeviceKit | 配对、连接、观察、设备动作与状态 | 直接使用 `DeviceClient`，或注入自己的 `DeviceController` |

App 在 `Integrations/DeviceTools.swift` 组合两者，将模型工具调用转换为自有 `DeviceDecision`，交给 `DeviceTaskRunner` 检查权限、串行执行并自动截图核查。动作及核查共同计入预算，新截图随同一工具结果返回；未知送达停止，无法核查则暂停。没有单独的 Plugin 产品，公开 API 不暴露 Pi 类型。更换引擎使用 `AgentClient(engine:)`，更换设备后端使用 `DeviceClient(controller:)`。

公开接口见 [AgentClient](Sources/EiscueAgentKit/AgentClient.swift) 和 [DeviceClient](Sources/EiscueDeviceKit/DeviceClient.swift)。

## 构建和测试

工程使用 XcodeGen；修改工程配置后重新生成：

```sh
xcodegen generate
swift test
xcodebuild -project Eiscue.xcodeproj -scheme Eiscue \
  -destination 'generic/platform=iOS Simulator' ARCHS=arm64 build
```

完整 App 测试使用真实 Pi 运行时和一个确定性的本地模型响应服务，不需要 API Key、不消耗模型额度：

```sh
# 在另一个终端保持运行，仅监听 127.0.0.1
python3 Scripts/test-model-server.py

# 选择本机已有的 iOS 26+ 模拟器
xcodebuild -project Eiscue.xcodeproj -scheme Eiscue \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' test
```

单独运行不依赖本地模型服务的 UI 用例：

```sh
xcodebuild -project Eiscue.xcodeproj -scheme Eiscue \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' \
  -only-testing:EiscueUITests/EiscueUITests test
```

2026-10-13 本轮软件验证：App 单元测试 **131 项通过**，Swift Kit **101 项通过**；模拟器 `EiscueUITests` **8 项通过、1 项跳过**。跳过的设备操作验证页用例需要真实设备控制就绪，模拟器无法满足。另有两次指定手机的 XCTest Runner 在执行用例前断开（退出 74），未执行测试，不能算通过；上述 S3 BLE 输入结果来自 App 内实际 UIKit 校验。USB 与蓝牙握手、枚举或 ACK 都不能替代实际手机输入验证。

设备后端已经附带 arm64 真机、模拟器和 macOS XCFramework，可直接构建；目前不含 Intel / x86_64 slice。重新构建 Rust 后端：

```sh
bash Scripts/build-device-backend.sh
```

脚本与源码版本说明见[Vendor/DeviceBackend](Vendor/DeviceBackend/README.md)。原始 Rust 测试在 `Vendor/DeviceBackend/rust` 中运行，使用脚本指定的工具链。

## 数据

- 会话、运行时 SQLite、任务记录、导入 Skill：App 沙盒的 `Application Support/Eiscue/`。
- API Key 和配对私钥：本机 Keychain，不写入 UserDefaults、聊天或报告。
- 蓝牙屏幕共享由用户在 Apple 系统面板中启动。扩展仅接收视频，将最新一帧写入受文件保护的 App Group 本地缓存，不保留视频历史、不采集麦克风或 App 音频。停止、暂停或帧过期后旧画面不能继续授权操作。
- 设备任务请求观察时，截图会发给所配置的模型服务；运行时的工具历史可能包含截图与输入结果，随会话删除。仅开启共享或手动截图预览不会自行上传模型。文字输入会覆盖系统剪贴板后请求粘贴。
- 导出报告只包含允许的运行元信息与工具状态，不包含 API Key、配对信息、原始截图或完整输入参数。
- 删除会话会清理对应的运行时文件与任务日志；删除 API Key 不会删除会话。
- 选择的附件进入 App 私有存储，按发送后才提供给模型。语音只在本机识别，音频不写文件，识别文字先进入草稿。

## 后续验证与范围

App 随包包含屏幕共享扩展与保留的本地 VPN 扩展。蓝牙普通流程已接入代码。AX 界面树、PiP、Mac / Android / 鸿蒙控制后端属于后续扩展；它们不是当前可用功能。后台运行上限和本地回环兼容性需实测，系统可能随时终止执行。设备任务由用户在前台发起并申请 BGContinuedProcessingTask；蓝牙和屏幕共享本身不提供 Agent 后台执行许可。

保留的 RemotePairing 控制组件来自 actell 固定版本，保留其 GPL-3.0 和第三方声明；蓝牙固件和 ReplayKit 接入为本项目实现，PiDurableKit 固定到明确 commit。依赖版本见 [Package.swift](Package.swift)，设备后端来源与许可见 [后端说明](Vendor/DeviceBackend/README.md)。这里不替整个 Eiscue 项目作发行许可决定。

**本地连接扩展基于 LocalDevVPN / StosVPN 的 IPv4 反射实现**，归属 Stossy11、SideStore Team 和 jkcoxson，保留其自定义 StosVPN License。详见[来源与许可](Vendor/LocalTunnel/README.md)。
