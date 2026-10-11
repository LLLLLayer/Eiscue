# 验证记录

日期：2026-10-11。Xcode 26.3 / Swift 6.2.4；App 与内置扩展最低 iOS / iPadOS 26.0。

## iOS 26 本机替代通道实测（同日，最新）

产品支持要求保持 iOS / iPadOS 26 及以上。之前将 App 可运行与设备控制未完成分开描述，并不能代替这一要求；原先选用的 DisplayService/HID 路径在测试机上缺少必要服务，应修正控制实现。

在指定 iPhone 14 Pro / iOS 26.5.2（23F84）的 Eiscue **App 进程内**执行新探针，复用 Keychain 内已有 RemotePairing 身份和内置 VPN 通道，获得以下真实结果：

- Instruments DTX 握手成功，一次截图返回合法 PNG，尺寸 **1179 × 2556**。
- `com.apple.dt.testmanagerd.remote` 的 DTX 握手成功。
- 无重新配对、无导入 Mac Lockdown 私钥、无额外 Runner 安装；未启用自动化或发送触控。

这证明当前授权可访问 iOS 26 的另一条截图通道及测试服务。**它不证明 App 内 XCTest 会话、实际点击或脱离电脑后的持续后台控制已经完成**；生产设备连接仍使用旧控制后端，探针不会把其标为 ready。下一项工作是完成本 App 的测试会话与授权、验证一次自有页面点击及停止，再接入生产控制流程。

探针仅由 Debug 启动参数 `--legacy-device-probe` 显式触发；`--resume-existing-local-tunnel` 只恢复安装更新后断开的、已启用的本应用 VPN 配置，不创建或保存配置，不申请新授权。首次探针在 VPN 断开时直接结束；恢复既有配置后的第二次实测才得到上述结果。测试完成后已按正常参数重新启动 App，不会自动再执行探针。

同时修复新启用的 vendored DTX 解析器长度边界：单帧和聚合限制 64 MiB，验证分片身份/顺序、payload 与 Aux 内层范围，拒绝溢出和不完整报文。8 项 DTX 测试、52 项后端测试、35 项 DeviceKit 测试通过；包含独立固定字节的正常分片和损坏长度回归。交叉审查发现的解析器问题已修复并复核。Debug / Release 签名构建、签名验证通过；真机运行的是普通 App 的 Debug 构建，没有安装 UI Test Runner。

本地结果：`/tmp/eiscue-ios26-probe-result.json`；日志：`/tmp/eiscue-dtx-framing-tests.log`、`/tmp/eiscue-legacy-probe-all-tests.log`、`/tmp/eiscue-ios26-probe-swift-tests.log`、`/tmp/eiscue-ios26-probe-debug-build.log`、`/tmp/eiscue-ios26-probe-release-build.log`。诊断仅有系统版本、握手结果和截图尺寸，截图字节不落盘。

## 真机控制服务兼容性与状态提示（同日）

通过 Xcode 对指定 iPhone 14 Pro 截图，确认实际界面显示“屏幕或触控服务未就绪（阶段 10，原因 4）”，本机通道已连接。该错误只会在身份验证、隧道、服务发现和开发环境检查通过后出现；临时导入文件也已被 App 消费。因此配对导入已完成，无需重复生成。确认后已删除电脑上本次生成的临时身份副本。

使用 `remotectl show` 读取并按 UDID 核对该测试机的服务表：没有 `com.apple.coredevice.displayservice`、`com.apple.coredevice.hid.universalhidservice`、`com.apple.coredevice.screencaptureservice`，存在 App 服务和 XCTest 服务。`devicectl device info ddiServices --no-auto-mount-ddis` 报告当前镜像兼容且可用。结论是当前后端与这台 iOS 26.5.2 的屏幕/触控服务不兼容；本轮没有完成设备操作，也没有通过重新配对或修改系统版本规避问题。

界面修正：已有身份时明确显示授权已保存，避免把本地保存当作已验证；隐藏首次配对说明和重复导入入口；未连接时按钮明确表示开启/重试设备控制，控制验证入口仅在控制就绪时出现。Kit 主错误文案区分缺少屏幕服务、缺少触控服务与超时，中英文同步，保留继续聊天的说明。阶段/原因编号改为 `org.eiscue.device` / `connection` 本地 OSLog，只记录操作名及数值，不记录身份、凭据或原始协议内容。

35 项 DeviceKit 测试通过，包含 5 项新增状态/中英文文案回归。原始画面只保存在本地 `.build/diagnostics/device-services/iphone14-service-unavailable.png`；服务清单和 DDI 结果保存在 `/tmp/eiscue-14pro-rsd.txt`、`/tmp/eiscue-14pro-ddiservices.json`，不提交设备私有记录。

签名 Release 构建及签名验证通过，正常 App 已覆盖安装并启动到指定 iPhone 14 Pro。日志：`/tmp/eiscue-device-error-copy-tests.log`、`/tmp/eiscue-device-guidance-release-final.log`、`/tmp/eiscue-device-guidance-install.log`、`/tmp/eiscue-device-guidance-launch.log`。本轮修正状态和指引，没有宣称已修复底层服务缺失。

## 首次真机 USB 身份生成与传输（同日）

指定 iPhone 14 Pro 已通过系统 USB 信任，开发者模式开启且开发服务可用。本次使用现有电脑工具，显式指定该测试机，完成创建 Eiscue 自有身份、Pair Setup 签名校验、断开后重新建立会话的 Pair Verify；为本机服务发现启用并读回确认 Wi-Fi 开发连接。生成文件权限为 `0600`，只保存在 Git 忽略的本地构建目录，没有读取或输出私钥内容。

已通过受信任的 CoreDevice 通道传入 App 的 `tmp/EiscuePairingTransfer.json`，重新列举目录确认存在。它不会出现在系统“文件”App，Release 设备页在重新进入后显示「导入电脑发送的配对」。此记录只确认生成和交付；App 内导入、VPN、本机服务发现、截图与输入仍未在本轮验收。桌面临时副本在确认导入成功后清理。

本地脱敏日志：`/tmp/eiscue-usb-pair-20261011.log`、`/tmp/eiscue-usb-transfer-20261011.log`。没有把配对文件提交仓库。

## 普通聊天移除表情 Skill（同日）

用户报告“你好”长时间等待后收到回复。指定 iPhone 14 Pro 的任务记录显示该轮以 `completed` 结束，耗时约 25 秒，只有 `run.started` 事件，没有设备工具调用。原 App 会无条件提供表情 Skill、表情目录和设备说明；此次移除表情 Skill 资源及注入，普通聊天只保留简短的身份、语言和简洁回复提示。设备规则只在非聊天范围加入，其他 Skill 仍由用户明确选择。插画资产及旧消息显示保留。

定向 UI 回归 `testPlainChatWithoutPluginsSurvivesRelaunch` 通过：首轮发送、重启恢复、第二轮继续聊天全部完成。本地 HTTP fixture 对真实运行时生成的两轮请求精确检查唯一的简短指令（含 Pi 固定 `<instructions>` 包装）、没有 tools/functions，以及重启后保留完整历史。UI 检查文本回复、任务结束和未显示表情；未调用真实模型服务。测试先后发现未签名模拟器构建无法访问 Keychain，以及 fixture 预期漏算 Pi 包装；修正测试签名和精确预期后复测通过，未为通过测试修改生产行为。

签名 Release 构建和签名验证通过，正常 App 已覆盖安装并启动到指定 iPhone 14 Pro，原配置与对话保留。最终测试产物为 `.build/results/PlainChatWithoutPluginsVerified.xcresult`、`/tmp/eiscue-plain-chat-verified-test.log`；构建、安装与启动日志为 `/tmp/eiscue-plain-chat-release.log`、`/tmp/eiscue-plain-chat-install.log`、`/tmp/eiscue-plain-chat-launch.log`。

USB 配对核对：指定测试机的电脑侧状态为 `paired`、`wired`，开发者模式已启用且 DDI 服务可用。电脑信任正常不等于 App 已取得自己的身份；本文没有进行 Eiscue 身份生成、导入或设备控制验收。已补充文档，说明既有信任无需重复弹窗，以及当前命令行流程尚不是面向普通用户的一键配置体验。

## Gemini Chat Completions 400 修正（同日）

闪退修复后的真机任务记录提供了实际失败原因：Google 返回 `INVALID_ARGUMENT`，明确拒绝 JSON 中的 `store` 字段。该请求为普通聊天，接口和模型为用户配置的官方 Gemini OpenAI 兼容端点及 `gemini-3.8-flash`。此次只读取任务错误详情，没有读取 Keychain 凭据。

AgentKit 对该官方 HTTPS 端点的 Chat Completions 请求设置 Pi 的 `supportsStore=false`，使发出的 JSON 完全省略 `store`。匹配限定协议、精确域名、路径和默认 HTTPS 端口；不改用户配置，不把规则套用到其他自定义服务或 Responses / Messages。

`swift test --filter ProviderIntegrationTests` 的 2 项参数化测试、共 11 个用例全部通过。测试使用 URLProtocol 截获真实运行时生成的请求，验证 Google 端点省略 `store`、普通 OpenAI / 相似域名 / 不同路径及其他协议保持原行为，同时检查模型、图片、鉴权、请求路径和模拟流式回复。所有请求均在本地拦截，未使用真实凭据，也未验证 Google 账号的实际请求结果。

签名 Release 构建和 `codesign --verify --deep --strict` 通过。正常 App 已覆盖安装并启动到指定 iPhone 14 Pro，保留现有配置与对话。可使用原配置再次发送消息验证 Google 的实际响应。

本地产物：`/tmp/eiscue-google-provider-tests.log`、`/tmp/eiscue-gemini-store-release.log`、`/tmp/eiscue-gemini-store-install.log`、`/tmp/eiscue-gemini-store-launch.log`。

## 普通聊天请求失败时闪退修正（同日）

指定 iPhone 14 Pro 的 16:05:31、16:05:40 两份崩溃报告与本地 Release dSYM UUID 匹配，符号化均定位到 `AppModel.perform` 的错误处理分支。可选链修改 `activeRun?.state` 时，赋值右侧又读取 `activeRun?.submission`，触发 Swift 独占访问冲突并终止进程；普通发送和继续中断任务共用此路径。修正为先读取并计算状态，再单独写入，保留原有失败/中断语义。

新增本地 HTTP 401、503 错误 fixture 与端到端 UI 回归。未修版本在 401 用例中复现 App 退出；修正版两项错误用例与原停止/重启用例共 3 项通过。覆盖具体错误可见、草稿保留、解除忙碌状态、假凭据脱敏，以及同一 App 会话内新建对话后正常收到回复。签名 Release 构建与签名验证通过，正常 App 已更新并启动到指定 iPhone 14 Pro。

用户提供的 Gemini 兼容接口地址及 `gemini-3.8-flash` 与 [Google 官方兼容接口文档](https://ai.google.dev/gemini-api/docs/openai) 一致。本次没有读取或使用用户的真实 API Key；在此阶段尚未取得请求失败的具体原因，后续 400 修正见上节，修复崩溃本身不代表已验证 Google 模型请求成功。

本地产物：`.build/results/ChatFailureReproduction.xcresult`（修复前失败）、`.build/results/ChatFailureFixTests.xcresult`（修复后 3 项通过）、`.build/diagnostics/chat-crash/`（仅本地崩溃报告及匹配符号）、`/tmp/eiscue-chat-failure-release.log`、`/tmp/eiscue-chat-failure-install.log`、`/tmp/eiscue-chat-failure-launch.log`。

## 黑白灰配色更新（同日）

根据最新配色要求，将 AccentColor 调整为浅色近黑、深色近白；按钮、SF Symbols、麦克风和运行状态统一灰阶。错误提示增加感叹号，设备状态保留不同图形与文字，角标随主题反转前景/背景；系统确认弹窗保留原生 destructive 语义。贴纸和 App 图标保留原图。

模拟器与签名 Release 构建通过，签名验证通过。已查看浅色 iPhone 主页面、模型设置以及深色 iPad 侧栏/输入区，检查文字、图标和玻璃背景的对比。正常 App 已更新并启动到指定 iPhone 14 Pro。本次为颜色和提示样式调整，没有新增或重复运行功能测试；交互回归结果见下方 Liquid Glass 记录。

本地产物：`.build/review/monochrome-*.png`、`/tmp/eiscue-monochrome-final-build.log`、`/tmp/eiscue-monochrome-release.log`、`/tmp/eiscue-monochrome-install.log`、`/tmp/eiscue-monochrome-launch.log`。

## Liquid Glass 界面调整（同日）

- 顶部沿用系统工具栏玻璃；侧栏底部改为左侧新对话玻璃胶囊、右侧设置透明玻璃圆钮。输入区及设备、引导、模型、技能等页面的独立按钮使用原生玻璃材质，统一 SF Symbols 尺寸；正文与列表保留语义背景。
- 首轮 iPad 输入测试发现输入框边缘点击不聚焦。为带内边距的 TextField 明确设置矩形命中范围，保留原来的 `input.tap()` 断言，最终在 iPhone 与 iPad 均通过输入、附件菜单、设备操作开关、导航返回及草稿保留测试。
- 8 项语音回调/会话单元测试通过。7 种 UI 场景通过，覆盖引导与模型设置返回、技能选择、高级选项、侧栏底部布局和设置导航、宽屏侧栏展开/收起、输入框交互。iPhone 首轮 6 项 UI 全通过；iPad 的 2 项侧栏测试通过，输入问题修正后的最终双端复测通过。
- 最终中文浅色 iPhone 与深色 iPad 截图已检查：输入文字及麦克风清晰，侧栏底部按钮同排且无重叠。签名 Release 构建与 `codesign --verify --deep --strict` 通过，正常 App 已覆盖安装并启动到指定 iPhone 14 Pro，未在真机安装 UI Test Runner。

本地产物：`.build/results/LiquidGlassTests.xcresult`（8 项单元 + 6 项 UI）、`.build/results/LiquidGlassIPadTests.xcresult`（含首轮输入失败与 2 项侧栏通过）、`.build/results/LiquidGlassComposerFinalTests.xcresult`（最终 iPhone/iPad 输入复测）；截图 `.build/review/glass-verified-*.png`；Release 日志 `/tmp/eiscue-glass-release-verified.log`、安装及启动日志 `/tmp/eiscue-glass-verified-install.log`、`/tmp/eiscue-glass-verified-launch.log`。

## 真机语音闪退修正（同日）

指定 iPhone 14 Pro 的四份 Eiscue 崩溃报告确认：首次语音授权在系统后台队列回调，后续三次在 AVAudioEngine 音频队列收到首帧时，均触发 `_dispatch_assert_queue_fail`。原因是旧版 Swift 6 代码在 `@MainActor` 方法中创建了未标记并发边界的 Objective-C 回调，编译器为它们插入主线程执行器检查。识别结果回调也有同样的潜在问题；在回调内部启动 `Task { @MainActor ... }` 无法避免入口处先发生断言。

修正将授权、音频、识别结果的回调明确创建为不隔离于主线程的可发送闭包，只有提取后的识别文本和状态进入 MainActor 更新 UI。回归直接在后台队列调用生产使用的回调，覆盖此前只验证会话代次、未执行系统回调的缺口。原始崩溃报告留在本地，没有提交设备日志。

验证结果：74 项 App 单元测试通过，包含 4 项新增后台回调用例；Release 构建、签名验证通过。Release 优化编译的 SIL 复核确认三种回调不再插入错误的 MainActor 入口断言。修正版正常 App 已覆盖安装并启动到指定 iPhone 14 Pro。此次没有采集真人音频，实际听写效果仍由用户确认。

本地产物：`.build/results/SpeechCallbackFixTests.xcresult`、`/tmp/eiscue-speech-callback-tests.log`、`/tmp/eiscue-speech-fix-release.log`、`/tmp/eiscue-speech-fix-install.log`、`/tmp/eiscue-speech-fix-launch.log`。

## 对话布局、附件、语音与 iPad 更新（同日）

- 移除底部 Tab，改为左侧历史与设置、右上角设备状态。历史支持长按置顶、移动和删除；iPad 宽窗口常驻侧栏，窄窗口使用侧滑抽屉。
- 照片、拍摄与文件入口使用系统选择器；导入和多模态请求有大小、类型与数量验证。Kit 的 54 项测试、9 个套件通过，包含三种模型协议的真实附件请求格式和持久化恢复。
- 接入 Apple Speech 本机听写，提供点击、按住说话与空输入框长按入口。取消/松手/授权延迟使用会话身份门禁，避免迟到回调启动麦克风或写入另一段草稿。没有启动真机录音，识别语言可用性与实际效果仍需用户主动授权后验收。
- 加入四张用户表情和一张生成的招手表情，透明资源通过浅色与深色 iPad 截图检查。内置 Skill 与目录、素材编辑提示记录在 [对话体验说明](chat-experience.md)。
- UI 首轮发现父消息气泡的辅助功能标识覆盖贴纸图片标识；实际图片与持久化均正常。已将消息与流式回复改为包含独立子元素的辅助功能容器，保留原贴纸断言复测。
- 最终 App 单元测试 70 项全部通过；20 个不同 UI 场景通过（完整首轮加针对性修复复测，iPhone 上跳过的宽屏场景由 iPad 验证）。最终复测包含真实 Pi 多轮回复、表情渲染与重启恢复、加号菜单、设备开关与草稿保存；另在 iPad mini 验证了窄窗口侧滑与设置导航。
- 正常 App 的签名 Release 构建和 `codesign --verify --deep --strict` 通过。已成功覆盖安装并启动到指定 iPhone 14 Pro，没有安装 UI Test Runner。相机实拍、真人语音、当前 iOS 26 配对及整机控制的完整链路，不在本轮模拟器验证范围内。

本轮本地产物：Kit 日志 `/tmp/eiscue-attachment-tests.log`；完整 UI 首轮 `.build/results/ChatRedesignUITests.xcresult`、iPad 首轮 `.build/results/ChatRedesignIPadTests.xcresult`；Release 日志 `/tmp/eiscue-chat-redesign-release-final.log`；界面截图 `.build/review/chat-redesign-*.png`。

最终通过结果：`.build/results/ChatRedesignFinalTests.xcresult`（70 项单元 + 3 项 UI）、`.build/results/ChatRedesignIPadRetest.xcresult`（2 项 UI）、`.build/results/ChatRedesignIPadMiniTests.xcresult`（1 项 UI）。安装与启动记录为 `/tmp/eiscue-chat-redesign-iphone14-install.log`、`/tmp/eiscue-chat-redesign-iphone14-launch.log`。

## 初次完整实现结果

| 项目 | 结果 | 覆盖范围 |
|---|---|---|
| 两个 Swift Kit | 51 项、8 个套件通过 | 真实 Pi 运行时、模型协议、恢复/取消/超时、设备身份与截图代次、iOS 26/27 配对边界、中英文资源 |
| App 单元测试 | 51 项通过 | VPN 状态与路由、通知竞态、后台标题/副标题缓存、真实进度、配对阶段隐私、USB 临时文件导入、配对版本门禁 |
| App UI | 15 个不同用例通过，合并完整首轮及修复后的针对性复测 | 真实 Pi + 本地 SSE、多轮与持久化/停止、配置、外观、技能、历史、设备诊断、iOS 26 USB 指引、高级选项、中英文、首次引导与完成状态保存 |
| 桌面 USB 工具 | 230 项 Rust 库/工具离线测试通过 | 181 项 idevice、45 项 native、4 项 CLI；指定 USB 设备、证书固定、TLS 签名验证、首次配对握手、完整身份格式、0600 与不覆盖文件 |
| Release | 真机 SDK 构建通过 | 无签名构建；内置扩展、中英文资源、图标；不包含 DEBUG 自动导入/检查入口 |
| 图标与外观 | 资源编译及模拟器截图检查通过 | 用户提供的图，1024 × 1024、不透明；白色/深色中性背景和蓝色强调；首次引导与主界面 |
| 代码审查 | 交叉审查后修复并复核 | iOS 26 错误配对入口、导入刷新、重装后 Keychain 与配置不一致、折叠区无障碍标识、后台阶段更新、USB TLS 信任链 |
| 本轮真机验收 | 未执行 | 用户选择次日测试；没有继续要求系统授权、安装或操作真机 |

UI 首轮发现折叠容器与引导容器的无障碍标识覆盖内部控件；修复 UI 标识归属后，保持原控件断言复测通过。截图检查时移除了引导步骤间文字重叠的淡入淡出，并复测首次引导。深色截图通过模拟器系统外观切换获取，不把语言测试的命名当作深色验证。

Rust 使用 `--workspace --features desktop-bootstrap --lib --bins` 验证库与工具。另一次包含文档示例的全量 `cargo test` 有 6 个既有 vendor doctest 编译失败（示例缺少变量或 async 上下文）；这些无关示例未修改，不能宣称整个 vendor 文档测试通过。

## 本地产物

- Kit：`/tmp/eiscue-final-kit-tests.log`。
- App/UI 完整首轮：`.build/results/SimplifiedExperienceTests.xcresult`。
- 单元及受影响 UI 复测：`.build/results/SimplifiedExperienceRetest.xcresult`，51 项单元、8 项 UI 全部通过。
- 最终引导与截图复查：`.build/results/OnboardingFinalReview.xcresult`。
- Rust 最终离线结果：`/tmp/eiscue-usb-final-tests.log`；其他检查为 `/tmp/eiscue-usb-default-check.log`、`/tmp/eiscue-usb-host-help.log`。
- 最终 Release：`/tmp/eiscue-final-release-build.log`。
- 模拟器截图：`.build/review/`。

`.build/` 与临时日志不进入 Git。UI 测试使用独立 UserDefaults、目录与模型 Keychain 项；模型 fixture 只监听 `127.0.0.1`，不使用真实云模型账号。后台和通知测试没有申请真机系统权限。

## 真机状态与次日验收

当前版本已在指定 iPhone 14 Pro / iOS 26.5.2 成功安装并启动，主 App 与扩展的 Network Extension 签名通过；开发者模式已开启，DDI 可用。用户反馈旧版本配对持续转圈，已确认根因为当前后端所用的设备发起配对流程仅支持 iOS 27+。当前源码已提供 iOS 26 USB 引导及配对工具，但尚未在手机验证完整链路。

下一次按 [设备准备](device-setup.md) 验证：USB 首次配对 → 导入身份 → 内置本地连接 → 连接设备 → 截图 → 受控页面点击/输入/滑动 → 停止与释放。再测试旋转后拒绝旧截图、跨 App 后台任务及中断恢复。

系统实时活动的紧凑布局由 iOS 决定；需真机长按灵动岛检查展开后的副标题、取消与清理。通知授权、后台持续时间及实际设备控制不能由模拟器或离线测试代替。真实模型的图片能力、服务配额和自定义兼容接口亦需按实际账号验收。

## 引导修正与真机更新（同日）

- 首图和 App 内的角色标记改用 `MascotCutout.imageset`，RGBA 1254 × 1254，四角 alpha 为 0；原图和不透明 AppIcon 保留。使用内置 imagegen，编辑要求为“仅移除外部白底，保留角色、轮廓、颜色、构图和角色内部白色区域，输出真实透明背景，避免白边”。已查看模拟器浅色和深色页面。
- 移除引导返回按钮，保留全屏引导及禁止滑动关闭；iOS 27 的常规引导不再显示选择配对文件。中英文文案说明当前版本的电脑依赖，产品的完整无电脑初始化目标尚未完成。
- 2 项 Onboarding UI 测试通过：逐步推进、可交互导航返回/关闭入口为零、模型配置弹窗返回、完成状态持久化。首轮断言把全屏引导下不可交互的主页面按钮算入，修正为检查可交互导航按钮后复测通过。结果：`.build/results/OnboardingCutoutRetest.xcresult`。
- 签名 Release 构建及 `codesign --verify --deep --strict` 通过：`/tmp/eiscue-cutout-device-build.log`。正常 App 已覆盖安装并启动到用户指定的 iPhone 14 Pro，没有在真机安装或运行 UI Test Runner，也未执行配对或控制操作。
