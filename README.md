# Eiscue

运行在 iPhone / iPad 上的 Agent 设备助手。App 最低 **iOS / iPadOS 26.0**。任务编排和工具执行在手机上，模型通过用户配置的网络服务调用。

## 已实现

- 模型配置：OpenAI Chat Completions 兼容接口、OpenAI Responses、Anthropic Messages，自定义地址和模型 ID，API Key 使用系统 Keychain。
- Agent：真实 PiDurableKit 运行时、流式回答、多轮对话、图片工具结果、串行工具调用、停止、超时与调用次数限制。
- 会话与任务：本地持久化、恢复、删除、执行记录、脱敏报告导出；重启不自动继续任务，未提交消息保留并可重试。
- 设备：内置本地 VPN 扩展、iOS 26 的 USB 首次配对工具和身份导入、iOS 27+ 系统配对、开发者模式/DDI 检查、截图、点击、拖动、文字粘贴、App 列表、启动 App 和 Home。
- 执行边界：仅对话 / 观察屏幕 / 操作设备三种任务范围；坐标操作绑定新截图，单次使用，过期或重连后失效；未知操作结果不自动重发。
- 后台：iOS 26 的 BGContinuedProcessingTask 和系统实时活动，显示真实执行阶段；可选的完成／中断本地通知默认关闭，系统取消与过期统一停止。
- Skill：内置导航、只读搜索和中断核查流程，导入与删除 UTF-8 Markdown；不执行导入文件里的脚本。
- 原生界面：首次全屏入门引导，白色／深色背景配蓝色强调色；助手、设备连接和设置，较少使用的配置收在高级选项中。使用用户提供的 Eiscue 图片作为图标。
- 多语言：Apple String Catalog 和 Swift Package 本地化资源，支持英文、简体中文，跟随系统／App 语言；新增语言无需修改业务逻辑。见 [本地化说明](docs/localization.md)。

**源码接入与真机验收是两件事。** 模拟器可验证 Agent 与 App 流程，但不能进行本机整机控制。DDI、回环 VPN、新身份配对、后台持续时间及不同系统版本的控制效果，需要在目标真机上验收。没有自动降级成电脑控制，也不会生成假的设备成功结果。

## 运行 App

1. 使用 Apple Silicon Mac 和 Xcode 26 或更新版本，打开 `Eiscue.xcodeproj`。
2. 选择 `Eiscue` scheme，在 iOS 26+ 模拟器运行。保留 Xcode 默认的本地签名，Keychain 需要正确的签名环境。
3. 真机运行时，在 Signing & Capabilities 选择自己的开发团队。默认 Bundle ID 为 `org.eiscue.app`。
4. 首次打开会显示全屏引导；在其中或「设置 → 模型配置」填入服务地址、模型 ID 和 API Key。其余参数有默认值，保存配置不会调用模型。
5. 仅对话可直接使用；设备任务需先按 [设备准备说明](docs/device-setup.md) 完成 DDI，在设备页开启内置本地连接并配对，再连接设备。无需额外安装 LocalDevVPN。

内置扩展与主 App 都需要匹配 Network Extension capability 的签名。首次添加 VPN 配置仍需系统授权，详见 [内置本地连接](docs/local-tunnel.md)。

iOS 26 的开发者模式页没有本后端要求的系统配对入口。首次连接请使用 [USB 配对步骤](docs/device-setup.md#ios-26-的首次-usb-配对)，不要等待系统显示不存在的菜单。USB 首配、内置连接与真实控制的完整链路仍待真机验收。

App 当前仅接受 HTTPS 模型服务地址。OpenAI 兼容接口通常填写带 `/v1` 的地址；Anthropic 默认填写 `https://api.anthropic.com`。Kit 允许宿主自行配置本地 HTTP 服务。测试专用 loopback 配置只在 DEBUG 且显式 UI 测试模式下启用。

## 两个独立 Kit

`Package.swift` 对外提供两个 library product：

| 产品 | 负责 | 独立使用 |
|---|---|---|
| EiscueAgentKit | Eiscue 自有 Agent / 工具 / 事件协议、运行时适配、会话存储 | 注册自己的 Swift 工具，或注入 `AgentEngine` 替换引擎 |
| EiscueDeviceKit | 配对、连接、观察、设备动作与状态 | 直接使用 `DeviceClient`，或注入自己的 `DeviceController` |

App 在 `Integrations/DeviceTools.swift` 组合两者。没有单独的 Plugin 产品，公开 API 不暴露 Pi 类型。具体结构与更换引擎方式见 [架构说明](docs/architecture.md)。

接入示例：[AgentKit](docs/agent-kit.md)、[DeviceKit](docs/device-setup.md)。

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

本轮实际测试结果和待完成的真机验收见 [验证记录](docs/validation.md)。

设备后端已经附带 arm64 真机、模拟器和 macOS XCFramework，可直接构建；目前不含 Intel / x86_64 slice。重新构建 Rust 后端：

```sh
bash Scripts/build-device-backend.sh
```

脚本与源码版本说明见 [Vendor/DeviceBackend](Vendor/DeviceBackend/README.md)。原始 Rust 测试在 `Vendor/DeviceBackend/rust` 中运行，使用脚本指定的工具链。

## 数据

- 会话、运行时 SQLite、任务记录、导入 Skill：App 沙盒的 `Application Support/Eiscue/`。
- API Key 和配对私钥：本机 Keychain，不写入 UserDefaults、聊天或报告。
- 启用屏幕观察时，截图会发给所配置的模型服务；运行时的工具历史可能包含截图与输入结果，随会话删除。手动截图预览不会发给模型。
- 导出报告只包含允许的运行元信息与工具状态，不包含 API Key、配对信息、原始截图或完整输入参数。
- 删除会话会清理对应的运行时文件与任务日志；删除 API Key 不会删除会话。

## 后续验证与范围

本轮实现首版核心路径，并随 App 打包本地 VPN Extension。AX 界面树、语音、PiP、Mac / Android / 鸿蒙控制后端属于后续扩展；它们不是当前可用功能。后台运行上限和本地回环兼容性需实测，系统可能随时终止执行。[后台策略](docs/background.md) 说明了当前实现。

控制组件来自 actell 固定版本，保留其 GPL-3.0 和第三方声明；PiDurableKit 固定到明确 commit。详见 [依赖说明](docs/dependencies.md)。这里不替整个 Eiscue 项目作发行许可决定。

**本地连接扩展基于 LocalDevVPN / StosVPN 的 IPv4 反射实现**，归属 Stossy11、SideStore Team 和 jkcoxson，保留其自定义 StosVPN License。详见 [来源与许可](Vendor/LocalTunnel/README.md)。
