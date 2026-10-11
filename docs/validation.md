# 验证记录

更新日期：2026-10-12。Xcode 26.3 / Swift 6.2.4；App 与内置扩展最低 iOS / iPadOS 26.0。

## 开发板文案更新（2026-10-12）

设备页与首次引导的中英文文案统一使用通用开发板名称，并将现有无线连接明确标为
“Wi-Fi 开发板”。17 个 String Catalog 的 1148 项本地化值均已检查；构建产物中
中英文 Localizable / Onboarding 资源也已核对。Release 签名构建通过，已覆盖安装
并正常启动到指定 iPhone 14 Pro。此次仅调整文案和说明，没有把蓝牙实验接入正式
设备连接流程，也没有重新刷写开发板。

## BLE 真机实验（2026-10-12）

现有 **ESP32-C3 / 8 MiB** 板以纯 BLE 固件，与指定 **iPhone 14 Pro / iOS 26.5.2**
完成加密 GATT → 系统 HID → UIKit 的真实输入验证。三轮各自生成的 12 位数字均由
实际文本框回调确认；最后一轮只发送一次鼠标点击，安全区域内的大按钮收到一次真实
触摸事件。三轮禁用蜂窝的 HTTPS 请求均返回 200，前后网络接口均为 Wi-Fi。

最终报告为 `passed`，但 `absoluteCoordinatesVerified=false`：这是键盘和鼠标点击
传输验证，没有证明精确坐标定位、跨 App、ReplayKit 读屏或 Agent 后台运行。iPhone
未提供预期 hover，且辅助触控状态 API 与用户看到的小圆点不一致，因此保留最初两轮
`partial_pass`，另用显式 Debug 参数验证大目标点击，没有把回执当成点击成功。

板子当前保留 BLE 实验固件；完整 Flash 备份、原有 Wi-Fi 镜像和配置均保留。Debug /
Release 签名构建及指定真机安装通过，没有加装 UI Test Runner。详见
[BLE 实验记录](ble-board-validation-2026-10-12.md)。下方为 10 月 11 日原 Wi-Fi 路径的历史结果。

## 无线真机验收（2026-10-11）

指定 **iPhone 14 Pro / iOS 26.5.2** 经 ESP32-C3 Wi-Fi 开发板完成一次完整动作
闭环，最终报告 `/tmp/eiscue-wireless-final-check-result.json` 为
**`state = passed`、`phase = finished`**。两次连接、两次点击及各自点击后截图、
两次本地断开均通过；另验证合法 `1179 × 2556` PNG、180° 旋转后的旧帧拒绝且
无效果、新帧点击、滑动、Unicode `你好，Eiscue 🧊` 输入、Home 和启动 App。
开始及两次连接时本地 VPN 均为未连接，连接方式保持 `wirelessBoard`。

新固件已刷入，600 秒采集中 6 次发现均 `status = 0`，一次手机关联和预期
`.2` DHCP 租约，没有断开、panic 或错误。最新 Objective-C fixture 为 **220 项
通过**。Home 和文本输入的生产能力限制已移除；更新后的签名 Release 完整构建
通过（17.545 秒），`codesign --verify --deep --strict` 返回 0，覆盖安装和空参数
普通启动均成功。正常 RootView 启动后的进程检查确认 App 仍运行，未自动重跑
Debug 验证。Release 构建、安装和启动证据为
`/tmp/eiscue-wireless-verified-release-build.log`、
`/tmp/eiscue-wireless-verified-release-install.json`、
`/tmp/eiscue-wireless-verified-release-launch.json`。

**通过范围仅为上述实际闭环。** 本地断开不等于远端 daemon 释放 ACK，Home 的
短暂前后台切换不证明长时后台稳定运行；蜂窝模型联网与公司 VPN 共存仍未验收。
首次扫码加入失败的原因仍未知。详细过程、早期失败及证据见
[无线真机验证增量记录](board-validation-2026-10-11.md)。

下面的 Wi-Fi 开发板和 XCTest 小节是同日早期记录，保留其当时的未完成状态和测试
结果；其中“停在授权页”“手机连接待验”不代表当前最新状态。

## Wi-Fi 开发板（同日，早期记录）

**历史范围：本节记录当时的备份、刷写、AP 启动与安装；后续无线关联及动作闭环
已经推进，最新结果见上方小节。**

用户随后接入的真实开发板已由 ROM 确认为 **ESP32-C3 / 8 MB Flash**。其固定
USB Serial/JTAG 不能实现 USB NCM，因此新增 `Firmware/Passport-Relay` 独立
Wi-Fi AP 固件，并保留 S3 USB 固件。两者复用 ND1 / NR1 / NL1；Agent、配对
身份、开发者服务认证和控制仍在 App / Kit 中。App 增加「无线开发板」，开发板
分支不启动本地 VPN，接口变动或地址不符时失败，不自动改用其他网络。

| 验证 | 结果及实际范围 |
|---|---|
| ROM 与原固件备份 | PASS：确认 C3 / 8 MB，完整原 Flash 备份并与 ROM MD5 比较一致；备份在本机受保护目录 `.build/board-backups/20261011T141744.974028Z/`，不提交原内容或密码 |
| 无线固件首次写入 | PASS：固件和独立随机 Wi-Fi 配置完成 `write_flash`、`verify_flash`；配置只保存在私有 NVS 与本机 `wifi-setup.txt`，没有通用默认密码 |
| DHCP 修复及最终固件更新 | 运行时审查发现自建 AP 接口遗漏显式启动 DHCP；修复后仅更新 App 分区，`write_flash`、`verify_flash` 均通过，原 Flash 备份和既有私有 Wi-Fi 配置保留 |
| 实板启动 | PASS：串口启动日志在 352 ms 明确返回 `Private WPA2 AP ready; waiting for one phone` 与 `ND1 diagnostics / NR1 bounded relay; idle until command`；这证明固件走到 AP/relay 就绪，尚未有手机关联或实际 ND1 请求结果 |
| 后端编译 | PASS：PhoneAgentNCM、EiscueDeviceKit 编译通过；Rust arm64 iOS / simulator / macOS 三平台 Release 及 XCFramework 重建通过 |
| 完整 App 编译 | PASS：包含无线入口的无签名和签名 Release 完整构建均 `BUILD SUCCEEDED`；最终签名构建用时 20.436 秒，最低 iOS 26.0 |
| App 签名与安装 | PASS：用户自行解锁登录钥匙串后，既有证书签名及 `codesign --verify --deep --strict` 通过；无线版本已覆盖安装到指定 iPhone 14 Pro，并以空启动参数正常前台启动，未安装额外 UI Test Runner、未读取 API Key。安装和启动结果均为 `info.outcome = success`；约 38 秒后进程仍在，未据此声称界面或无线连接已验收 |
| 手机及网络验收 | 未完成：手机关联、DHCP `.2` 租约、手机 ND1、iOS 26 RemotePairing、实际屏幕/触控、断连撤销、蜂窝模型联网及公司 VPN 共存均待实测 |

Wi-Fi 固件使用 WPA2-PSK / CCMP、最多一个客户端，板子 `.1/30`、唯一 DHCP
地址 `.2`，不发布路由器或 DNS，不提供 NAT 或互联网转发。Swift 只接受所选
Wi-Fi 接口及 `.2/30`；USB 仍严格使用 Ethernet `.2/24`。每次发现保留传输类型、
完整接口和 3 秒有效期，原生连接前重新核对；Rust 仍按指定 index 和源地址绑定。
这些是该阶段的实现边界，实际手机联网效果不由 AP 就绪日志代替。按用户要求，当轮
优先完成实现、构建和实板启动，没有新增单元测试通过数，也未重跑历史完整套件。

本地证据：`/tmp/eiscue-passport-app-partition-update.log`（修复版 App 分区写入、
读回及保留配置），`.build/passport-relay-firmware/boot-20261011-review.log`
（实际启动），`/tmp/eiscue-wifi-backend-xcframework-build.log`（三平台后端），
`/tmp/eiscue-wifi-backend-build.log`（PhoneAgentNCM），
`/tmp/eiscue-passport-app-unsigned-retry.log`（完整无签名 Release），
`/tmp/eiscue-sign-after-manual-unlock.log`（解锁后既有证书签名），
`/tmp/eiscue-passport-signed-final.log`（最终签名 Release），
`/tmp/eiscue-passport-installed-final.json`、`/tmp/eiscue-passport-launched-final.json`
（指定测试机安装和正常启动），`/tmp/eiscue-passport-running-final.json`
（启动后进程存活）。此前从 Xcode GUI Run 后的签名重试仍在
EiscueTunnel CodeSign 失败，`/tmp/eiscue-sign-after-user-run.log` 的
`errSecInternalComponent` 保留为历史失败；用户后来在系统终端直接输入自己的
密码解锁登录钥匙串，未在聊天或代码中提供密码。无线关联与设备控制未随安装
自动执行，当时 App 内 XCTest 的系统密码授权还是另一个待完成步骤。配置和烧录步骤见
[开发板说明](board-setup.md)。

## iOS 26 App 内 XCTest 会话（同日，早期记录）

**历史范围：本节停在当时的系统授权页，保留准备阶段证据；后续授权、触控和重连
已在无线闭环中验证，最新结果见上方小节。**

iOS 26 真机控制已接入普通 App 进程内的独立 XCTest 路径，替换该系统版本上缺失服务的 DisplayService/HID 选择。iOS 27+ 保留原路径。下面区分该阶段代码、当时取得的真机证据和未完成的验收；最新无线动作结果见本文首节。

实现使用既有 RemotePairing 身份与认证隧道，不重新生成身份。Rust 拥有两个 testmanagerd DTX 通道，为同一 UUID 初始化会话，并仅为当前进程的 `getpid()` 请求授权；接受相关请求的明确布尔 `true` 回复，Swift 再校验 UUID、PID 与授权值。独立 Objective-C 桥接动态使用 DDI 中的开发者框架，新建本 App 的 runner/XPC 会话，异步请求启用 UI 自动化。正常 App 不嵌入 Apple 测试 Runner 框架，不需要另装 UI Test Runner；这仍依赖开发者环境和私有接口，不能据此承诺 App Store 分发。

指定 iPhone 14 Pro / iOS 26.5.2（23F84）已经取得的实际结果：

- 既有身份认证、DDI 检查和当前 App PID 的 DTX 会话授权通过。
- DDI 下新建 XPC 会话的工厂回调完成且没有错误，实际服务为 `com.apple.dt.testmanagerd.runner`。
- 异步启用自动化请求后，延迟抓取的画面明确显示 **“为 XCTest 输入 iPhone 密码 / Enable UI Automation”** 系统页。
- 已有认证通道返回合法 Instruments PNG，尺寸 **1179 × 2556**。

**该阶段真机验证停在系统密码授权页。** 当时需要用户直接在手机上输入密码；App、Agent 和聊天不接收密码。该阶段尚未取得启用自动化完成或生产连接 `ready` 的证据，也未发送并验证真实点击、滑动、文本、Home。停止后重新连接、180° 旋转后的旧帧拒绝和持续后台操作当时同样未验收。这些早期证据不能替代后续实际动作记录。

| 验证 | 结果及实际范围 |
|---|---|
| Rust 后端 | 64 项通过；独立通道、请求相关性、严格授权、PNG 校验、取消、清理和父会话保留 |
| vendored idevice | 184 项通过；包含 DTX 解析与相关回复及已有协议回归 |
| DeviceKit | 56 项通过；PNG MIME、能力声明、会话身份、几何与旧帧失效、释放/取消；宿主测试不能证明真机方向回调 |
| Objective-C fixture | 203 项检查通过；执行生产入口与事件构造，替换平台导入并使用模拟运行时类，覆盖 UTF-8、几何修订、请求回执、未知结果、剪贴板提交门禁、迟到回调和清理；不加载 DDI 框架、不连接手机 |
| SDK 编译与安装 | 上述 fixture 脚本同时通过 iOS 真机与模拟器 SDK 的 Objective-C 语法检查；签名 Debug / Release App 构建通过。最终 Release 深度签名校验通过，最低系统 26.0，没有嵌入测试框架；覆盖安装并按普通参数启动到指定 iPhone 14 Pro，没有安装额外 Runner |
| App 单元测试 | iPad 模拟器完整 112 项通过，其中连接生命周期 21 项包含 7 项新增授权/后台用例：连接中的系统页不触发主动取消，返回前台保留结果，后台空闲连接延迟释放，显式停止仍可取消；使用注入 controller 验证，尚未在完成授权的真机上复测。首次 iPhone 模拟器运行卡在安装/启动阶段，被中止，没有计作通过 |
| 真机授权准备 | 新会话工厂与异步系统授权请求得到上方证据；等待密码时超时并清理，没有把准备成功误标为控制就绪 |

坐标输入实现核对本会话的显示 ID、方向、缩放、几何修订和截图尺寸，截图前后几何不一致则拒绝；事件使用递增请求回执，未知结果不自动重试。文本验证实现只在最终提交门禁通过后将给定文字写入系统剪贴板，再发送一个本会话的 Command-V，不读取旧剪贴板；焦点、粘贴授权与可见内容当时仍需真机确认。**该阶段 iOS 26 Release 不声明 Home 和文本输入能力**，仅在显式 Debug 验证入口开放；后续实际验证与生产入口变化见最新小节。

独立审查发现并修复了几何查询完成后的取消检查缺口，以及原生公开方法可绕过 Home / 文本能力限制的问题。等待系统授权超时现在给出系统密码页的中英文指引，不解释为服务缺失或用户拒绝。修复后的 DeviceKit 56 项、App 112 项及最终 Release 构建通过。

`--owned-device-check` 是正常 App 内的显式 Debug 验证页面，不依赖模型或额外 Runner。计划通过截图坐标触发页面上的按钮、滚动与文本框，再检查真实计数、位置、文本及 Home 后的前后台状态，并做停止/重连；该阶段检查在连接准备阶段结束，后续断言当时均未执行。验证页使用实际窗口、场景、屏幕与截图几何计算坐标，额外要求真实横屏方向改变 180°，拒绝转向前的未使用旧帧，再以新截图点击并核对计数；该阶段仅源码和构建检查通过，当时没有真机旋转证据。本地关闭 DTX/XPC 只记录为本地断开，不称为远端释放确认。Debug 为核查授权页保存过受保护的准备截图，图片留在本地；正常截图 API 只在内存返回。密码页图片、配对身份和完整原始手机日志不提交 Git。

本地证据：`/tmp/eiscue-xctest-session-tests.log`（64 项）、`/tmp/eiscue-xctest-idevice-tests.log`（184 项）、`/tmp/eiscue-ios26-devicekit-all.log`（56 项）、`/tmp/eiscue-owned-final-fixtures.log`（203 项）、`/tmp/eiscue-auth-ux-tests.log`（21 项）、`.build/auth-ux-tests/Logs/Test/Test-Eiscue-2026.10.11_19-56-27-+0800.xcresult`。真机准备的构建及阶段日志为 `/tmp/eiscue-owned-async-build.log`、`/tmp/eiscue-owned-device-async-console.log`；失败检查的结构化报告为 `/tmp/eiscue-owned-check-ddi.json`，不把失败报告算作动作通过。

此处关联的早期开发板进度为：用户的 ESP32-C3 开发板已由 ROM 确认为 C3 / 8 MB，完成原 Flash 备份、MD5 校验、无线固件写入及实际 AP/relay 就绪日志，App 已签名安装；当时尚未验证手机关联与操作。后续完整无线动作闭环见本文最新小节，公司 VPN 共存仍未验收。C3 固定 USB Serial/JTAG 不能实现 USB NCM 的硬件限制保持不变。见 [开发板说明](board-setup.md)。

最终补充证据：`/tmp/eiscue-owned-final-devicekit-tests.log`、`/tmp/eiscue-owned-final-app-ipad-tests.log`（112 项）、`.build/auth-ux-tests/Logs/Test/Test-Eiscue-2026.10.11_20-09-37-+0800.xcresult`、`/tmp/eiscue-owned-final-release-build.log`、`/tmp/eiscue-owned-final-release-install.json`、`/tmp/eiscue-owned-final-release-launch.json`。首次中止的完整 App 测试日志为 `/tmp/eiscue-owned-final-app-tests.log`。

## 消息附件分享补齐（同日，当前）

独立审查发现旧分享按钮只发送 `message.text`，纯照片或文件消息会发送空字符串。现在保存有界文档原件和类型/大小元信息，模型仍接收原有提取文本；照片分享规范化后的 JPEG，扩展名与实际类型一致。每次分享使用独立私有副本，保留到原生分享结束、失败或实际关闭后清理，不删除原附件；iPad 使用按钮所在窗口作为弹窗锚点。空消息不能分享，空文字的复制/选段按钮隐藏。旧 PDF 没有原始字节时明确禁用分享，不把提取文本伪造为 PDF；旧文本可按实际保留内容导出 UTF-8。

新增 12 项 App 单元用例，覆盖 PDF 原字节、UTF-16、照片、重复文件名、重载、缺失原件、清理和后台 completion；新增 3 项 UI 用例，覆盖真实系统分享页、取消/重新打开，以及存储到本地文件后通过公开 document picker 再读回完整字节。最后一项使用本轮 UUID 名称和随机内容，读取前验证名称、大小及不属于分享临时目录；fixture 不写保存目标，只读 picker 新授予的文件。独立审查未发现把原件当保存结果的问题。

**解锁 Mac 后，新增 12 项分享单元测试全部实际通过，0 失败。** 包含 PDF 原字节、UTF-16、照片类型、重复文件名、清理、后台回调和无窗口取消。证据为 `/tmp/eiscue-share-unlocked-unit-tests.log` 及 `.build/sharing-validation-no-dylib/Logs/Test/Test-EiscueValidation-2026.10.11_22-02-16-+0800.xcresult`。此前 XCTest 启动多次停在测试宿主暂停和 `wait_for_debugger = 1`，未进入 Test Suite；这些中止结果保留，不计通过。临时无调试器用户 scheme 在 Git 忽略的 `xcuserdata` 下，没有修改正式测试配置。新增 3 项自动 UI 测试仍待执行。

分享修改后的正常 Release 签名校验通过，已覆盖安装并按普通参数启动到指定 iPhone 14 Pro；没有安装额外 Runner，没有读取 API Key。构建/安装/启动证据：`/tmp/eiscue-share-release-build.log`、`/tmp/eiscue-share-release-install.json`、`/tmp/eiscue-share-release-launch.json`。未执行的测试日志：`/tmp/eiscue-share-ipad-tests.log`、`/tmp/eiscue-share-ipad-retry-tests.log`、`/tmp/eiscue-share-ipad-unit-nondebug-tests.log`、`/tmp/eiscue-share-iphone-nondebug-tests.log`、`/tmp/eiscue-share-ipad-isolated-tests.log`。

用户解锁 Mac 后，已通过 Computer Use 在 iPad Pro 11-inch (M5) / iOS 26.3 模拟器手动完成真实系统分享、保存到 On My iPad 和新的公开文件选择器读回。界面返回 `Saved file bytes verified`，完整值为 `verified|Shared notes-85585C84-F626-458F-832F-2A2E8EDCB54D.txt|66`；唯一文件名和全部 66 字节匹配。文件从系统 Recents 选回，fixture 没有直接写入保存位置。照片分享显示实际橙色 JPEG 预览及 1 KB 类型/大小，关闭后重新打开正常，文件分享同样验证取消后重新打开。此次是手动系统流程证据，不冒充 XCTest 通过。普通启动记录为 `/tmp/eiscue-share-manual-isolated-launch.log`；之前 Mac 锁定期间没有完成分享操作。

此前一次提交在公司全局 pre-commit 扫描期间长时间等待，没有给出扫描结果或风险拒绝；该次未生成提交，也没有关闭或绕过钩子。后续交付以实际 Git 提交与远端分支记录为准。

## 对话时间线、语音交互与开发板连接（同日，前一阶段）

聊天发送先上屏并清空草稿，随后才执行保存和请求；保存失败恢复原草稿但不覆盖新输入。完成运行卡移出聊天，记录在对话菜单；流式回答、真实工具条目、消息时间、Markdown、消息操作和原生选段复制已实现。语音使用独立的 50 pt 按住区域，上滑取消，输入框不再挂录音长按手势。

| 验证 | 结果及实际范围 |
|---|---|
| App 单元测试 | 最终 105 项通过，包含发送时序/附件清空/保存失败、时间线、语音与连接方式隔离 |
| AgentKit | 30 项通过；纯文本原请求 ID、相同文本、重试、孤立元信息、旧会话、附件、三种模型请求；精确验证普通聊天指令与零工具 |
| DeviceKit | 49 项通过；USB/VPN 路径、取消/释放、身份、接口与候选有效期；只有媒体启动成功可 ready |
| UI | 11 种场景分别通过，包含多轮/重启、停止、401/503、侧栏排序；真实 SSE 未结束时清空输入和展示部分回答；带前置文字与直接工具调用两种时间线重启恢复 |
| iPhone/iPad | Markdown 标题、引用、列表、代码、表格、时间与操作；实际选词 Copy 后 Paste，内容非空且短于整篇；语音模式切换保留草稿、区域尺寸有效。已看 iPhone 浅色与 iPad 深色截图 |
| S3 固件 | ESP-IDF 5.5.3 构建 390656 字节；6 组协议/localhost 测试、7 项烧录守卫通过，UBSan。ASan 本机初始化死锁，未计通过 |
| 发布构建/安装 | Release、签名校验通过，MinimumOSVersion=26.0；正常 App 已覆盖安装并按普通参数启动到指定 iPhone 14 Pro。未在真机安装 UI Test Runner |

首轮 UI 暴露了工具与回复错序：模型时间戳与主机处理事件的时间不同，不能混用排序。改为消息存储顺序和工具的上一条消息锚点；同锚恢复运行的活动按主机开始时间排序。独立审查还发现纯文本恢复会替换原用户 ID，导致无前置文字工具丢锚；已用现有显示元信息格式保留所有新请求 ID，并验证没有改变模型上下文。首轮失败保留在本地结果中，针对性复测通过。配对时停止 VPN 漏取消监听的回归也已修复，并覆盖连接标记尚为空的情况。

该阶段开发板代码位于 `Firmware/NCM-Relay`，App 可选 USB 板或本地 VPN，USB 分支不会启动 VPN，外部 VPN 回调不终止板会话。**这些软件测试不是开发板实测。** 该开发板参考硬件为 ESP32-C3，其固定 USB Serial/JTAG 不能实现 NCM；当时用户的实际板子尚未读取芯片，Mac 无开发板串口枚举，没有备份、烧录、NCM 枚举或公司 VPN 共存实测，无线中转也尚未实现。后续 C3 ROM 确认、无线固件刷写及 AP 启动证据见本文首节。详见 [硬件与烧录说明](board-setup.md)。此阶段的聊天和连接方式改动没有补齐 iOS 26 触控，后续独立 XCTest 接入与验收范围见上方相应章节。实际真人录音、本地语言识别效果未重新验收。

本地证据：`.build/results/FinalAppAndPlainChat.xcresult`（105 单元 + 普通聊天重启），`.build/results/ChatTemporalProof-iPad.xcresult`（真实流式与工具顺序），`.build/results/ChatTimelineNoProse.xcresult`（直接工具调用重启），`.build/results/TimelinePairingRegression.xcresult`（22 项），`.build/results/ChatPresentationCopyVerified.xcresult`、`.build/results/ChatPresentation-iPad-Dark.xcresult`（各 2 项 UI）；截图 `.build/chat-ui-review-copy/`、`.build/chat-ipad-review/`。日志 `/tmp/eiscue-runtime-message-identity-final.log`、`/tmp/eiscue-ncm-transport-tests.log`、`/tmp/eiscue-board-build.log`、`/tmp/eiscue-board-final-tests.log`、`/tmp/eiscue-chat-release.log`、`/tmp/eiscue-chat-20261011-install.log`、`/tmp/eiscue-chat-20261011-launch.log`。

## iOS 26 本机替代通道实测（同日，控制通道探针）

产品支持要求保持 iOS / iPadOS 26 及以上。之前将 App 可运行与设备控制未完成分开描述，并不能代替这一要求；原先选用的 DisplayService/HID 路径在测试机上缺少必要服务，应修正控制实现。

在指定 iPhone 14 Pro / iOS 26.5.2（23F84）的 Eiscue **App 进程内**执行新探针，复用 Keychain 内已有 RemotePairing 身份和内置 VPN 通道，获得以下真实结果：

- Instruments DTX 握手成功，一次截图返回合法 PNG，尺寸 **1179 × 2556**。
- `com.apple.dt.testmanagerd.remote` 的 DTX 握手成功。
- 无重新配对、无导入 Mac Lockdown 私钥、无额外 Runner 安装；未启用自动化或发送触控。

这证明当时的授权可访问 iOS 26 的另一条截图通道及测试服务。**该探针本身不证明 App 内 XCTest 会话、实际点击或脱离电脑后的持续后台控制已经完成**；此阶段生产设备连接仍使用旧控制后端，探针不会把其标为 ready。后续已接入本 App 的独立测试会话并触发系统授权页，准备阶段见上方「iOS 26 App 内 XCTest 会话」历史章节，最新动作结果见本文首节。

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
