# 验证记录

日期：2026-10-11。Xcode 26.3 / Swift 6.2.4；App 与内置扩展最低 iOS / iPadOS 26.0。

## 本轮结果

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

此前版本已在指定 iPhone 14 Pro / iOS 26.5.2 成功安装并启动，主 App 与扩展的 Network Extension 签名通过；开发者模式已开启，DDI 可用。用户反馈旧版本配对持续转圈，已确认根因为设备发起的配对流程仅支持 iOS 27+。当前源码已提供 iOS 26 USB 引导及配对工具，但尚未在手机验证完整链路；手机也尚未更新到本轮界面版本。

下一次按 [设备准备](device-setup.md) 验证：USB 首次配对 → 导入身份 → 内置本地连接 → 连接设备 → 截图 → 受控页面点击/输入/滑动 → 停止与释放。再测试旋转后拒绝旧截图、跨 App 后台任务及中断恢复。

系统实时活动的紧凑布局由 iOS 决定；需真机长按灵动岛检查展开后的副标题、取消与清理。通知授权、后台持续时间及实际设备控制不能由模拟器或离线测试代替。真实模型的图片能力、服务配额和自定义兼容接口亦需按实际账号验收。
