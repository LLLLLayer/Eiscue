# Eiscue 设备 Agent 方案 v0.4

更新时间：2026-10-12。项目基线：`9d43bdb`；iCTRL 源码基线：`9fd0a7cc20819a1612f7d62ffbec5989d23f018e`。本文替代 v0.3 中的路线判断，记录当前实现与下一阶段设计；候选方案不表示已经集成。

后续补充：[不依赖 Mac 的设备 Agent 运行方案](mac-independent-agent-options.md)新增 S3 USB HID 候选，区分 USB 键鼠与本文的 USB NCM 网卡，并细化首次准备、手机独立运行和 Linux 电脑运行的边界。

## 本版结论

Eiscue 继续采用两个独立 Kit：AgentKit 管理可替换的 Agent 引擎，DeviceKit 提供可替换的设备控制。上层 App 管理对话、配置、授权、任务与系统生命周期。公开协议不绑定 Pi；当前引擎仍为 PiDurableKit。

当前可试用的默认路线是“蓝牙开发板 + 系统屏幕共享”。开发板接充电器或电脑供电，不插 iPhone；手机继续使用日常 Wi-Fi。设备操作工具已接回普通 App，用户在输入框“+”中开启“允许 AI 操作设备”后才传给模型。纯聊天不注入设备工具，也不恢复自动表情指令。

iCTRL 已公开 Apache-2.0 源码，升级为优先评估的软件后端。先用独立 Runner 验证其本机接口与准备流程，再决定是否作为软件模式接入；本轮没有安装 iCTRL，也没有将其源码合并进 Eiscue。当前蓝牙路径继续可用，VPN 和有线通道保留为明确选择的兼容路径。

## 相比 v0.3 的事实更新

| v0.3 的判断 | 本版更新 |
| --- | --- |
| iCTRL 只有开源预告 | 官方仓库现已公开；已拉取并阅读固定提交的源码、README、LICENSE 和 NOTICE。 |
| 先复现 actell，再接 Pi | 两个 Kit、真实 Pi 运行时和 App 已实现；不再按“尚未开始原型”排期。 |
| iOS 26 只按 DisplayService/HID 评估 | Eiscue 的开发者服务后端在 iOS 26 使用 App 内独立 XCTest 会话；显示/输入能力不能只按新系统的服务名称判断。 |
| 硬件主要是 USB NCM | 新增已烧录的 ESP32-C3 蓝牙 HID 路线；它与 USB NCM 是不同机制。 |
| 本项目两条路线都未真机验收 | Wi-Fi 开发板的 XCTest 基础动作已验收；蓝牙连接、ReplayKit 画面、四点点击和中文输入已验收；完整后台 Agent 任务仍待验收。 |
| 最低系统、组件和 UI 尚待选型 | App 明确 iOS/iPadOS ≥26；黑白灰原生界面、中英文资源和侧栏导航已落地。 |

真实设备证据限于指定 iPhone 14 Pro / iOS 26.5.2 与 ESP32-C3 / 8 MB 样机。[Wi-Fi 验收](board-validation-2026-10-11.md)和[蓝牙验收](ble-production-validation-2026-10-12.md)分别留存，不能互相替代，也不能外推至所有 iPad、固件或系统版本。

## 先分清三层

| 层 | 解决的问题 | 当前实现或候选 |
| --- | --- | --- |
| Agent 与工具 | 如何调用模型、选择动作、验证结果 | PiDurableKit、Eiscue 自有 AgentEngine / AgentTool、DeviceToolSession |
| 观察与输入后端 | 从哪里得到画面，如何执行点击和输入 | ReplayKit + BLE HID；App 内 XCTest；iCTRL Runner 候选 |
| 准备与连接通道 | 如何完成身份认证并接通所需系统服务 | VPN 回环、USB NCM、Wi-Fi 转发、蓝牙配对；iCTRL 的 DDI 准备 |

VPN 不是点击权限，也不是后台执行许可。蓝牙 HID 是输入设备协议；USB NCM 是网卡协议。因此不能把“蓝牙、有线、XCTest、iCTRL”都当作互斥的同一层选项。Agent 始终运行在手机 App，模型请求可以走用户的正常互联网连接。

## 路线对照

| 路线 | 观察和输入 | Eiscue VPN 占用 | 手机互联网 | 当前边界 |
| --- | --- | --- | --- | --- |
| 蓝牙开发板 | ReplayKit 画面 + BLE HID 指针/键盘 | 不使用 | 保留平常 Wi-Fi/蜂窝 | 当前 C3 实板通过连接、四点、中文；需辅助触控和用户启动共享。 |
| USB 有线开发板 | USB NCM 转发开发者服务；iOS 26 App 内 XCTest | 不使用 | 设计上 Wi-Fi/蜂窝可保留；路由待实板验证 | 需支持 USB OTG 的 ESP32-S3；固件已构建，尚无 S3 实板验收。 |
| Wi-Fi 开发板 | 开发板热点转发开发者服务；iOS 26 App 内 XCTest | 不使用 | 当前固件占用手机 Wi-Fi；板子不提供外网，模型需另有可用出口 | C3 基础操作已验证；不能满足“保持原 Wi-Fi 上网”的首选诉求。 |
| 内置 VPN 回环 | Packet Tunnel 接通开发者服务；iOS 26 App 内 XCTest | 使用系统 Packet Tunnel 配置，可能与其他 VPN 冲突 | 扩展不设置外网默认路由；真实共存取决于系统和其他 VPN 策略 | 已内置扩展；该通道的完整当前组合仍需单独验收。 |
| iCTRL 软件候选 | 手机内 Runner 的截图、UI 树/OCR与 XCUITest；Agent 走本机 HTTP RPC | 控制 RPC 本身走 localhost；手机内 DDI 准备方案使用 LocalDevVPN | 日常可使用正常联网；关闭准备 VPN 后的续跑要实测 | 源码已研究，尚未在本项目安装或验收；仍是独立 Runner。 |

“不使用 Eiscue VPN”表示无需创建或启动我们的 VPN 配置，不保证某个公司 VPN 不会阻断本地网络接口。有线网卡通道尤其需要实际路由验证。蓝牙输入本身不经过 IP 网络。

当前开发板为 ESP32-C3，其 USB Serial/JTAG 不是可编程 USB OTG，不能刷成此项目的 USB NCM 网卡。采用有线 NCM 要换成相应 S3 硬件。iPhone 14 Pro 是 Lightning 机型，还需具有 USB Host 能力且供电适当的适配器；普通充电线不等价。[硬件与接线依据](board-setup.md)

## iCTRL 的“不需要 Mac”到底指什么

以下按固定版本的公开实现拆解，不把作者演示当成本项目实测。[官方安装说明](https://github.com/OpenMinis/iCTRL/blob/9fd0a7cc20819a1612f7d62ffbec5989d23f018e/README.md)

| 生命周期 | iCTRL 已公开的做法 | 对 Eiscue 的含义 |
| --- | --- | --- |
| 首次签名和安装 | SideStore 免费账号，或开发证书 + 签名脚本/Xcode。README 的 SideStore 初装通过电脑与 USB 完成。 | 日常免 Mac 不等于从未需要电脑；也不等于 App Store 下载即用。具体首次方案可不限定为 Mac，但要逐种证明。 |
| 配对身份 | UI 要求导入电脑产生的配对文件；此固定版的导入校验和实际挂载读取格式不一致，详见下文。 | 没有发现自动完成首次身份准备的实现；需先修复格式衔接，再验证准备流程。也不能直接导入 Eiscue 的 RemotePairing JSON。 |
| DDI 首次准备 | 可由 Xcode 挂载；也提供手机内经 LocalDevVPN、配对文件、镜像文件和 Apple 个性化服务挂载的实现。 | 手机内准备值得验证，但上述格式问题尚未闭环；Eiscue 当前后端只检查 DDI。 |
| 日常操作 | Runner 在手机上服务，本机 Agent 请求 127.0.0.1:8200；Mac 可以离开。 | 不需要开发板，也不需要 Mac 持续发指令。 |
| 手机重启后 | DDI 需重新准备，Runner 需重启；文件通常可以复用。 | 可以设计手机内恢复，但不能描述为永久免配置；需实测我们支持的 OS build。 |
| 签名续期 | 免费侧载账号需续签；iCTRL 不提供自己的签名/安装器。 | 签名仍是产品分发依赖，不能把旧版内置签名器当作当前能力。 |

源码还有三个关键点：

- DDI 工具按系统版本分支：iOS 26.0–26.3 走 personalized image-mounter，26.4+ 走 cryptexd。这是 iCTRL 当前实现的版本规则；Eiscue 的验证矩阵应拆开，而不能只写“iOS 26”。[镜像选择](https://github.com/OpenMinis/iCTRL/blob/9fd0a7cc20819a1612f7d62ffbec5989d23f018e/iCTRLApp/DDI/DeveloperDiskImageStore.swift)、[挂载实现](https://github.com/OpenMinis/iCTRL/blob/9fd0a7cc20819a1612f7d62ffbec5989d23f018e/iCTRLApp/DDI/DDIMounter.swift)
- iCTRLCompat 是旧版 XCTest 类符号兼容层。入口仍是 XCTRunner + 嵌套 .xctest，不能把它视为普通 App 中直接初始化控制的 Kit。[兼容层](https://github.com/OpenMinis/iCTRL/blob/9fd0a7cc20819a1612f7d62ffbec5989d23f018e/iCTRLCompat/XCTCompatShim.m)、[构建定义](https://github.com/OpenMinis/iCTRL/blob/9fd0a7cc20819a1612f7d62ffbec5989d23f018e/project.yml)

- 配对文件存在静态接口不一致：导入器要求 Lockdown 字段 `HostID / HostCertificate / HostPrivateKey`；挂载器却调用 `rp_pairing_file_read`，其固定依赖 idevice v0.1.68 要求 RP 字段 `public_key / private_key / identifier`。普通 RP 文件会被导入器拒绝，普通 Lockdown 文件则不能直接通过 RP 读取器。README 也注明需 RP 格式；没有发现官方流程生成同时满足两者的文件。这是源码审查结论，尚未在手机上复现，不应将此版本的手机内挂载描述为已经跑通。[导入校验](https://github.com/OpenMinis/iCTRL/blob/9fd0a7cc20819a1612f7d62ffbec5989d23f018e/iCTRLApp/DDI/PairingFileStore.swift#L74-L92)、[实际读取](https://github.com/OpenMinis/iCTRL/blob/9fd0a7cc20819a1612f7d62ffbec5989d23f018e/iCTRLApp/DDI/DDIMounter.swift#L240-L264)、[RP 格式定义](https://github.com/jkcoxson/idevice/blob/d32c8189c51c2789496b0768039419c3705498c3/idevice/src/remote_pairing/rp_pairing_file.rs#L89-L129)

本机 HTTP 与 DDI 准备是不同路径。Runner 的本机 RPC 监听不经 DDI 的 RSD 通道，挂载结束会释放该 RSD 连接，但没有自动关闭 LocalDevVPN 的实现；这不等于已经证明关闭 VPN 后全链路持续运行。“挂载后关闭 VPN、切到其他 App、持续运行并在重启后恢复”必须作为完整实验，当前不能承诺已经通过。[本机监听](https://github.com/OpenMinis/iCTRL/blob/9fd0a7cc20819a1612f7d62ffbec5989d23f018e/iCTRLKit/JSONRPCServer.swift#L62-L68)、[RSD 释放](https://github.com/OpenMinis/iCTRL/blob/9fd0a7cc20819a1612f7d62ffbec5989d23f018e/iCTRLApp/DDI/DDIMounter.swift#L268-L270)、[VPN 启动接口](https://github.com/OpenMinis/iCTRL/blob/9fd0a7cc20819a1612f7d62ffbec5989d23f018e/iCTRLApp/DDI/LocalDevVPN.swift#L11-L20)

## 开源项目如何取舍

| 项目 | 已确认角色/许可 | 本项目采用方式 |
| --- | --- | --- |
| PiDurableKit | Agent 运行时；根许可 CC0，嵌入依赖另有声明 | 已固定依赖；通过 AgentEngine 隔离，后续可自研替换。 |
| actell | 开发者连接与控制实现，GPL-3.0 | 已选取后端源码，保留来源；Eiscue 对 iOS 26 会话做了独立补充。 |
| iCTRL | Agent 友好的手机内 Runner 与 RPC，当前 Apache-2.0 | 优先做软件模式对照与 DDI 恢复研究，尚未合入。其 NOTICE 说明早期 AGPL 版本与当前版本的差别。 |
| Pilot | 当前代码为直接 BLE GATT + 绝对坐标 HID + ReplayKit；固定提交无明确 LICENSE | 参考机制，不复制源码。我们的固件独立实现绝对指针、命令回执和释放逻辑。 |
| TouchSynthesis | 手机内 XCTest self-runner 参考；此前固定版本未找到许可证 | 不复制；不因为存在演示就替换已工作的会话。 |
| idevice / StikDebug / LocalDevVPN | 分别提供协议库、手机内开发准备参考、回环通信 | 分别核对协议库、参考 App 和 VPN 的许可；iCTRL 的 NOTICE 未断言外部 VPN 许可，Eiscue 自己集成的固定版回环组件采用自定义 StosVPN License。iCTRL 的 Apache 许可不覆盖整个 Eiscue。 |
| iphone-use / WebDriverAgent | 外部控制及回归基准 | 可用于能力对照，不代替单手机独立运行的验收。 |

来源：[依赖清单](dependencies.md)、[actell 固定源码](https://github.com/ja1chen/actell/tree/032864e2339da19ee13025c471f4cf1dfdf4c5cd)、[iCTRL NOTICE](https://github.com/OpenMinis/iCTRL/blob/9fd0a7cc20819a1612f7d62ffbec5989d23f018e/NOTICE.md)、[Pilot 参考提交](https://github.com/arihanv/pilot/tree/fd6b652d9bbbd99d95407861a5adfa1a3fdebb22)、[TouchSynthesis 参考提交](https://github.com/willfaust/TouchSynthesis/tree/688c0f40c270d71166db3fd6858071f09003627d)。

Pilot 的旧演示资料曾描述 Wi-Fi/云端转发，不代表当前源码。现版手机直接通过 BLE GATT 发命令，固件无需 Wi-Fi；其 ASCII 键码映射也不能当作中文输入支持。[手机命令入口](https://github.com/arihanv/pilot/blob/fd6b652d9bbbd99d95407861a5adfa1a3fdebb22/ios/Pilot/Pilot/LiveModeManager.swift#L127-L150)、[HID 固件](https://github.com/arihanv/pilot/blob/fd6b652d9bbbd99d95407861a5adfa1a3fdebb22/esp32/esp32-pilot.ino)

actell 当前主线声明 iOS 27；Eiscue 使用的是表中固定旧版本并补充 iOS 26 后端。因此，上游主线支持范围与 Eiscue 样机结果要分别记录。[上游系统要求](https://github.com/ja1chen/actell/blob/7429967c47eb0f763bb14b95d68350ef2dc27f5c/README.md)

## 模块与进程设计

保留两个公开 Kit，不再新增“连接 Plugin”产品。Plugin 在本方案中指 Agent 注册的一组原生工具；第三方既可以独立使用 Kit，也可以在自己的宿主注册同样的工具。

| 模块/进程 | 职责 | 替换边界 |
| --- | --- | --- |
| Eiscue App | SwiftUI、会话展示、Keychain 配置、附件、语音、设置与向导 | 不让 UI 直接发送 HID 或绑定 Pi 类型。 |
| EiscueAgentKit | AgentEngine、请求/事件/工具协议、运行时持久化适配 | 当前 PiDurableKit，未来自研引擎；不接管系统设备授权。 |
| DeviceToolSession（App 组合层） | 将 DeviceKit 能力转换为 AgentTool；权限、帧、超时、日志及停止门控 | 同时依赖两个 Kit；不是额外安装包。 |
| EiscueDeviceKit | DeviceController、设备类型、能力查询、观察与动作 | 当前本机开发者后端和 BluetoothDeviceController；未来可增加 iCTRL RPC adapter。 |
| EiscueBroadcast 扩展 | ReplayKit 视频帧处理与受保护的最新帧缓存 | 不执行 Agent、不采集音频、不保存视频历史。 |
| EiscueTunnel 扩展 | 本地 Packet Tunnel 回注 | 只服务选择此通道的开发者连接，不作为 Agent 保活进程。 |
| 开发板 / iCTRL Runner | 外部 HID 输入设备 / 手机内候选自动化服务 | 分别有独立生命周期，不冒充主 App 的执行时间。 |

建议演进时将“控制后端”和“连接方式”分开建模：developerServices 后端选 VPN/USB NCM/Wi-Fi 通道；bluetoothHID 后端选 BLE + ReplayKit；iCTRL 后端选经配对的本机 RPC。当前四项连接枚举保留兼容，迁移时保留用户偏好，不自动启动新后端。

DeviceKit 当前仍编译链接开发者后端。选择蓝牙运行不等于二进制已经移除 GPL 或私有开发者组件。若后续要做纯蓝牙分发，需另做内部 target/构建配置拆分，并核对最终二进制与许可；不必因此增加第三个公开 Kit。

## 工具恢复与使用契约

已安装版本中：设备页连接 → 系统开启屏幕共享 → 操作检查通过 → 返回对话 → 输入框“+”开启“允许 AI 操作设备” → 输入明确任务。关闭该开关后恢复普通聊天。模型需支持图片与工具调用；本次没有更改用户的 Key、服务地址或模型。

工具不是仅靠提示词开启：App 每次开始任务读取 DeviceStatus.capabilities，再创建 DeviceToolSession 和 AgentClient；Pi 运行时注册原生工具，模型返回调用后交给当前 DeviceController。蓝牙当前提供 device_screenshot、device_tap、device_swipe，以及实际键盘校验后的 device_type_text；Home、列出/启动 App 不会在未支持时传给模型。开发者服务后端可按自己的能力集合开放更多工具。

本轮新增一个本地集成验证，覆盖真实 Pi 运行时通过 Google 兼容 Chat Completions 编码发送工具、接收截图调用、执行 Swift 工具、把图片带入下一次请求并取得最终回答；同时确认保留工具字段、移除 Google 不接受的 `store` 字段。`ProviderIntegrationTests` 全部通过。该测试使用本地 HTTP fixture，不消耗 API 额度，不代表 Google 实际模型或跨 App 操作已经验收。

截图包含帧 ID、尺寸与采集时间；每个触控必须使用最新截图并消费该帧。动作后重新观察，不用回执代替成功验证。共享停止、连接变化、旋转或几何变化撤销旧帧/校验；未知送达不自动重试。业务工具和 Skill 不能扩大这组权限。当前不恢复自动表情 Skill，也不让原 Pi 桌面插件获得 Shell。

## 后台、状态与恢复

设备任务由用户在前台发起，使用 iOS 26 BGContinuedProcessingTask；系统进度展示真实阶段，取消与过期走同一停止入口。灵动岛仍显示不代表 Agent 仍有运行时间。ReplayKit 和蓝牙后台模式不能代替主 App 的持续执行许可。

BLE 的连接、共享、操作检查和任务状态分开。成功任务结束时发送确认的释放命令，保留连接便于下一条任务；用户停止或异常时释放输入，撤销观察条件。固件对持续按住设置 250 ms 失效释放；不同连接不复用输入状态。

iCTRL 若接入，也必须有配对、版本/能力检查、请求超时、停止和错误诊断。只开放本机 endpoint 为默认；远程访问为显式选择。程序重启不自动恢复动作，后端切换先停止旧任务，重新观察后才可接纳新任务。

## 实施顺序与验收

| 阶段 | 交付 | 退出条件 |
| --- | --- | --- |
| 当前交付 | 普通 App 设备工具、BLE 设置与导航、固件和使用说明 | 已通过签名 Debug/Release 构建、定向检查、真机四点与中英文输入；用户可自行试用。 |
| 下一步：完整 BLE 任务 | 同一手机上模型调用、截图、点击、滑动、输入、切 App 与停止 | 受控任务逐项读回结果；无 USB 控制、无 Eiscue VPN；模型等待及后台 5/15 分钟分别验证。 |
| 软件候选验证 | 先修配对格式衔接；固定版本 Runner、只读能力与停止接口，再做受控动作 | 本机 RPC 不依赖 Mac 发请求；DDI 准备、VPN 关闭后续跑、重启恢复与签名到期单列证据。 |
| DDI 恢复改进 | 独立开发准备模块，按 26.0–26.3/26.4+ 选路径 | 校验身份格式和镜像来源，区分“无法探测”和“未挂载”；不能用重复配对掩盖其他故障。 |
| 有线硬件验证 | ESP32-S3 USB NCM + 正确手机适配器 | 枚举、供电、目标路由、普通 Wi-Fi 上网、开发者连接、基础操作和断开恢复全部真机通过。 |
| 默认路线再决策 | 按实际新用户任务比较 BLE 与软件模式 | 比较首次配置步骤、人工介入、任务成功率、恢复耗时和模型费用；不凭仓库宣传决定迁移。 |

当前未验收项包括：蓝牙真实滑动、完整跨 App 模型任务、长时间后台、iCTRL 在本项目的运行与恢复、S3 实板与其他 iPad。它们是下一阶段工作，不被四点点击或构建通过替代。系统升级按机型与 OS build 重新记录兼容性。

回退方式：保留已验证固件和旧后端选择；新候选故障时停止任务并明确提示用户切换，不静默改走 VPN、其他设备或电脑。迁移不删除已有身份或对话；引擎替换迁移产品消息，不重放旧引擎中未确认的工具动作。

## 当前建议

继续用现有蓝牙版本调试具体任务，先完成端到端验收。并行把 iCTRL 作为软件模式的首选研究对象，重点借鉴其手机内 DDI 准备、可发现的工具接口和诊断；只有它确实减少配置与恢复成本，才推进集成或调整默认路线。USB NCM 作为需要有线连接时的硬件选项，等待合适 S3 实板后再承诺支持。
