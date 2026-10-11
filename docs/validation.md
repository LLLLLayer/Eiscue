# 验证记录

日期：2026-10-11。Xcode 26.3 / Swift 6.2.4；App 与内置扩展最低 iOS / iPadOS 26.0。

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
