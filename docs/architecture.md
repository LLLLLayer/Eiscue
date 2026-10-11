# 架构与模块边界

```text
Eiscue App (iOS 26+)
├── SwiftUI / AppModel / Keychain 配置 / 任务日志 / Skill
├── BackgroundExecution（系统执行租约）
├── BluetoothDeviceController → BLE 开发板（HID 输入）
├── ScreenBroadcastStore ← EiscueBroadcast.appex（ReplayKit 最新画面）
├── LocalTunnelManager → EiscueTunnel.appex（选择 VPN 路径时启用）
├── DeviceToolSession（任务权限、日志、停止门控）
├── EiscueAgentKit
│   ├── AgentEngine / AgentClient / AgentTool / AgentEvent
│   ├── 自有消息、会话与 JSON 会话仓库
│   └── Internal/Runtime → PiDurableKit → JavaScriptCore
└── EiscueDeviceKit
    ├── DeviceController / DeviceClient / 自有设备类型
    ├── BluetoothDeviceController / BluetoothBoardClient / ScreenBroadcastStore
    ├── KeychainPairingIdentityStore / SnapshotLedger
    └── 开发者后端 → PhoneAgentNCM → C ABI → Rust 原生后端
```

两个 Kit 不互相依赖；Swift Package 提供两个可独立导入的 library product。目录只是代码组织，`public` 访问控制才定义对外 API。Pi 和 actell 类型都留在内部实现。没有单独的连接 Plugin 或以 Pi 命名的公开 adapter。

ReplayKit 与 VPN 分别是独立扩展 target，由主 App 打包和签名，不是额外的公开 Kit。默认蓝牙路径使用 ReplayKit 和 BLE，不启动 VPN；开发者服务路径可选择本地 VPN、USB NCM 或 Wi-Fi 开发板通道。第三方使用时需为所选后端配置宿主扩展和系统授权。

路线取舍、iCTRL 源码研究与分阶段验收见 [方案 v0.4](design-v0.4.md)。iCTRL 是候选后端，没有进入当前构建。

## AgentKit

`AgentClient(configuration:storageDirectory:tools:)` 使用当前运行时；`AgentClient(engine:)` 接受其他 `AgentEngine`，未来自研实现只需满足相同协议。`AgentClient(storageDirectory:)` 可在没有模型密钥时恢复或删除已有记录，不启动模型请求。

`run(request:)` 返回异步事件流，包括持久化接纳、流式文本、完整消息、工具开始/结束和完成；`cancel()` 取消实际运行时，而不只是 UI 的 Swift Task。每个会话使用独立 SQLite，固定工具串行执行，带工具调用次数和时长预算。

运行时始终以 `resume:false` 打开。查询与恢复不会自动执行任务。进程中断后，由 App 核查状态、重新取得执行条件，再通过 `.resume` 显式继续。已停止、超时或预算用尽的任务被 abort；用户继续时提交新的核查指令，不重播之前的输入。未被接纳的消息使用相同 requestID 重试。

副作用工具使用 unsafe replay。这个运行时策略之外，宿主仍有独立设备门控，避免模型在未知结果后重新发送同类动作。

## DeviceKit

默认 `DeviceClient()` 使用本机开发者服务后端，支持配对、身份管理、服务发现、认证、DDI 检查、画面和输入。App 默认选择蓝牙，通过 `DeviceClient(controller:)` 注入 `BluetoothDeviceController`；原开发者服务实例保留给其他连接方式。模拟器/macOS 不会伪造真机就绪；第三方也可注入自己的 `DeviceController`。

蓝牙后端从 ReplayKit 取得画面，通过加密 GATT 向开发板发送 HID 命令。连接、屏幕共享和真实触摸检查均满足后才开放截图/点击/滑动；文本输入还要求独立文字检查通过。它不提供应用列表、启动 App 或 Home。当前只有四点点击与中英文输入完成真机验收，完整任务与后台行为仍待验证。

截图对外提供 frameID、时间、像素尺寸和 JPEG；内部以单调时钟记录 30 秒时效与连接代次。坐标使用截图像素，由 Kit 换算成原生归一化坐标。输入消费截图，动作后/重连后必须重新观察。

设备动作串行，断开和取消优先撤销连接代次。发送结果未知以 `DeviceControlError.deliveryUnknown` 报告并阻断重试。成功返回仅表示命令提交，不等同于业务结果被验证。

开发者服务的身份存放在系统 Keychain。iOS 26 首次准备走 USB 初始化，不能要求用户在开发者模式页寻找不存在的配对入口。DDI 只检查，不下载或挂载。蓝牙路径不使用这些身份和 DDI，而是系统蓝牙配对、辅助触控与用户启动 ReplayKit 共享。配置与实机边界见 [device-setup.md](device-setup.md)。

## App 与原生工具接入

App 管理 API Key、模型配置、会话选择、消息展示、运行日志、Skill 及系统生命周期。AgentKit 的 JSON 仓库由 App 指定保存位置。只有 App 的 DeviceToolSession 同时依赖两个 Kit，负责工具 schema、参数、作用范围和结果转换。

输入框“+”提供“允许 AI 操作设备”，默认关闭；普通聊天不会注册设备工具，也不注入自动表情 Skill。Kit 内部保留仅对话、观察屏幕、操作设备三种范围，任务开始后不能更改。App 每次依据真实能力建立工具集合，通过 Pi 原生工具注册调用；Google 兼容适配不会移除工具。Skill 只提供流程文字，不扩大权限、不获得 Shell。主 App 使用 BGContinuedProcessingTask 获得系统执行许可后才开放设备任务；VPN 不是后台租约。

动作日志先记录准备和发送边界，再调用设备；结果确认在下一次模型调用前落盘。发送和磁盘无法构成跨系统原子事务：崩溃或记录失败时保守停止，显示不确定结果，不承诺 exactly-once 或自动回滚。

停止回调携带 runID，旧任务不能取消新任务；配对和设备请求也有代次校验。宿主事件消费/保存失败时显式取消并等待引擎关闭，避免同一 SQLite 被下一轮引擎同时打开。

## 持久化与替换

可见消息使用 Eiscue 自有模型；Pi SQLite 保存引擎上下文和工具链。恢复时以运行时已确认的回答为准，同时保留本地未提交用户消息。未提交消息不会被静默视为发送成功。更换引擎可迁移产品消息；不承诺跨引擎恢复进行中的工具调用。

平台版本各自管理：App iOS26，Swift Kit iOS17/macOS14。这个声明是编译最低版本，不代表底层开发者服务在所有系统版本上通过验收。Android/鸿蒙可复用接口语义，需要各自语言和设备后端。

DeviceKit 当前仍链接 GPL 开发者后端。切换为蓝牙只改变运行路径；如果需要独立的纯蓝牙发行构建，还要拆分内部 target 并核对最终链接依赖，不能把运行时开关视为许可隔离。
