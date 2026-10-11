# 真机设备控制

EiscueDeviceKit 内置 iPhone / iPad 本机控制后端。上层 App 的最低系统版本为 iOS / iPadOS 26.0。控制使用系统 RemotePairing / CoreDevice 服务，正常 App 可选择本地回环 VPN、USB 开发板或 Wi-Fi 开发板通道。Eiscue 已随包内置 VPN 扩展，无需额外安装 LocalDevVPN；开发板通道不启动 VPN。模拟器不能完成真实配对或设备控制，Mac 目前只支持构建、测试和注入自定义 controller。

## 当前真机兼容性

2026-10-11，iOS 26 真机连接已接入 **App 进程内的独立 XCTest 会话**。它复用 Eiscue 已认证的隧道，通过 Instruments 获取 PNG，并使用开发者镜像（DDI）中的 XCTest 接口准备输入；不再要求 iOS 26 提供旧后端的 DisplayService/HID 服务。iOS 27+ 仍保留原有控制路径。

指定 iPhone 14 Pro（iOS 26.5.2）与 ESP32-C3 / 8 MB 样机已通过 Wi-Fi 开发板完成身份认证、开发环境检查、当前 App 会话授权和连接就绪。真实 PNG 为 **1179 × 2556**；点击后重新截图、横屏触控、180° 旋转后旧帧拒绝、滑动、中文与表情输入、Home / 返回 App，以及断连后第二次连接均通过，本地 VPN 保持断开。首次系统 **“启用 UI 自动化 / Enable UI Automation”** 授权可能要求设备密码，必须由用户直接在手机上输入，不应交给 App、Agent 或聊天。

**支持 iOS / iPadOS 26 及以上仍是产品要求；当前实测兼容范围是上述样机与手机组合。** 持续后台运行、蜂窝模型请求、公司 VPN 共存和其他系统 / 硬件组合仍需验证。关闭本地连接也不等于取得远端会话释放确认。详见 [Wi-Fi 真机验证记录](board-validation-2026-10-11.md)。

这条路径无需额外安装 UI Test Runner；正常 App 动态加载设备 DDI 中的开发者框架，不把测试 Runner 随包分发。但它依赖 Apple 开发者环境和私有接口，不能据此承诺 App Store 分发或任意系统版本的兼容性。iOS 26 正常版本已开放通过 Wi-Fi 真机验证的 Home 和文本输入。

另有独立的 [蓝牙开发板实验](board-setup.md#蓝牙开发板实验)：2026-10-12 验证了三次 12 位数字输入、一次测试按钮点击；禁用该请求的蜂窝访问时，Wi-Fi HTTPS 返回 200。这条 Debug 路径使用 BLE HID，不依赖本节的 RemotePairing / DDI 准备，但尚未接入正常 App 的连接选择或 Agent，也不提供屏幕观察与精确坐标操作。

## 首次准备

**当前实现还没有达到“首次使用起完全不需要电脑”的目标。** 内置 VPN 解决了额外安装 VPN App 的问题，但不负责建立配对身份，也不准备开发者镜像。iOS 26 的电脑工具和文件导入是当前后端的兼容路径；文件用于传递设备授权身份，不是让用户选择控制方案。iOS 27 的系统配对入口解决了机端建立身份这一环，但当前 Kit 仍未接入 DDI 自动准备，不能据此承诺全流程无电脑。这里描述的是 Eiscue 当前实现的边界，不代表已经证明其他实现也无法做到。

1. 在真机启用开发者模式，完成系统要求的重启与确认。
2. 将真机连接 Xcode，完成开发准备并确保对应开发者镜像（DDI）可用。Kit 只检查镜像状态，不下载、个性化或挂载镜像。
3. 在 Eiscue 设备页选择连接方式。本地 VPN 方式需点击「开启本地连接」，首次允许系统添加 VPN 配置；扩展使用本地 `10.7.1.1`、对端 `10.7.0.1`，系统报告已连接后才开放该通道的配对和设备连接。USB / Wi-Fi 开发板方式按[开发板说明](board-setup.md)准备对应固件与网络，不启动 VPN。内置扩展的签名要求与系统边界见 [内置本地连接](local-tunnel.md)。Eiscue 不修改第三方 VPN 配置。
4. 根据系统版本完成首次配对：**iOS 26 先通过下方 USB 工具生成并导入身份**；iOS 27+ 才能从设备页开始系统配对，再到系统设置的配对入口选择 Eiscue、输入 App 显示的 PIN。开发者模式和 VPN 授权均不能代替配对。允许 Eiscue 访问本地网络。
5. 配对完成后回到 Eiscue，点击「连接设备」。Kit 依次发现本机配对服务、认证保存的设备身份、建立隧道、检查开发者模式 / DDI，并准备对应系统的控制会话。iOS 26 若显示“启用 UI 自动化 / Enable UI Automation”，按系统要求直接在手机上输入设备密码。App 在连接期间不会因为这张系统页面进入后台而主动取消准备；授权页出现不代表设备已经就绪。

首次配对与跨 App 操作需要宿主为任务提供 iOS 26 的持续后台执行机会。Kit 不创建 App 后台任务；宿主在后台时间到期或用户停止时调用 `disconnect()`。系统可以拒绝后台执行申请，这种情况下不能宣称任务仍在运行。

宿主 Info.plist 必须包含明确的 `NSLocalNetworkUsageDescription`，并在 `NSBonjourServices` 中声明 `_remotepairing._tcp` 与 `_remotepairing-pairable-host._tcp`。Kit 内部负责 Bonjour 的发现与配对入口发布。

## iOS 26 的首次 USB 配对

iOS 26 的「开发者模式」没有当前后端所需的“由手机发起配对”入口。该流程从 iOS 27 才可用，见 [Apple 设备配对说明](https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub) 和 vendored `remote_pairing/responder.rs`。App 与 Kit 在 iOS 26 会立即给出 USB 指引，不再开启无效监听，也不需要升级 App 的最低系统版本。

以下工具在电脑上执行一次，为 Eiscue 创建自己的新身份。先用 USB 连接这台设备，在 Finder 或 Xcode 完成系统信任，保持解锁和开发者模式开启。工具只选择显式指定的 USB UDID，不会自动改用另一台手机，也不读取其他 App 的 RemotePairing 缓存。

如果这台手机已经信任过当前电脑，没有再次出现“信任此电脑”弹窗是正常的；工具会使用已有的系统 USB 信任继续初始化。无需为了让弹窗出现而还原位置、隐私或网络设置。电脑可以安装 App 并不表示 Eiscue 已有自己的配对身份，后续仍需生成并传入。参见 [Apple 的信任设置说明](https://support.apple.com/zh-cn/109054)。

当前电脑工具仍是开发者命令行工具，尚未提供面向普通用户的一键配置界面。产品化应由电脑助手自动检测已信任状态、生成身份并安全传给 App；用户仅处理插线、解锁及系统要求的授权。下述命令记录当前可用路径，不代表该体验已经完成。

```sh
# 需要 Rust 1.96.0；从仓库根目录运行。将占位符换成自己的设备 UDID。
mkdir -p .build/pairing
Scripts/pair-device-usb.sh --udid '<USB_UDID>' \
  --output .build/pairing/EiscuePairingTransfer.json --enable-wifi

# 通过 Xcode 的受信任 USB 通道传到已安装 Eiscue 的临时目录。
xcrun devicectl device copy to --device '<USB_UDID>' \
  --domain-type appDataContainer --domain-identifier org.eiscue.app \
  --source .build/pairing/EiscuePairingTransfer.json \
  --destination tmp/EiscuePairingTransfer.json
```

回到 Eiscue 设备页，点击「导入电脑发送的配对」。App 读取后立即移除临时传输文件，再校验并存入 Keychain；若导入失败，可从电脑重新传入。也可以在设备页选择已经安全传到本机“文件”中的配对文件。`--enable-wifi` 会为指定设备开启 Wi-Fi 开发连接；本地网络发现需要保持 Wi-Fi 开启。

工具输出文件权限为 `0600`，拒绝覆盖已有文件，只有 Pair Setup 签名验证和重新连接后的 Pair Verify 成功才导出完整身份。文件包含私钥，导入成功后删除电脑上的这份临时文件，不要放进 Git、聊天或网盘。普通 Lockdown 文件和标准 RPPairing 文件不能直接替代 Eiscue 的完整格式。

USB 身份生成不代表设备控制已经验收。2026-10-11 已在指定 iPhone 14 Pro（iOS 26.5.2）完成真实 USB 身份生成、Pair Setup 签名验证、重新连接后的 Pair Verify 和 App 内导入；随后通过 Wi-Fi 开发板完成 App 内 XCTest 授权与真实操作验证，见[验证记录](board-validation-2026-10-11.md)。其他设备仍需分别确认授权与操作结果。

上述传输文件位于 App 私有临时目录，不会显示在系统“文件”App 中。电脑传输完成后，重新打开 Eiscue 右上角的设备页，点击「导入电脑发送的配对」即可，无需在文件选择器里寻找它；停留在设备页时，可返回对话再进入以刷新按钮。

开发版可显式传入 `--import-pairing-transfer` 导入上述固定文件；不会覆盖已有身份。`--device-connection-check` 只在已连接的本地通道上连接、抓取一次截图尺寸并断开，诊断写入 `Library/Caches/EiscueDeviceCheck.json`，不保存屏幕内容或密钥。Release 不包含这些自动化入口；正常用户通过界面操作。

## 独立使用 Kit

```swift
import EiscueDeviceKit

let device = DeviceClient()
for try await event in await device.beginPairing() {
    // 在宿主 UI 显示 PIN / 等待状态；不要记录 PIN。
}
try await device.connectLocalVPN(configuration: .defaults)
let frame = try await device.captureScreenshot()
try await device.tap(at: DevicePoint(x: 120, y: 280), frameID: frame.frameID)
let confirmation = try await device.captureScreenshot()
await device.disconnect()
```

`DeviceController` 是可替换协议，`DeviceClient(controller:)` 支持独立后端 / 测试实现。平台枚举中预留其他设备类型不代表已经实现 Android、鸿蒙或 Mac 控制。

单独导入 DeviceKit 的宿主可以提供回环通道，或选择[开发板通道](board-setup.md)。回环方式可以在自己的 App 中嵌入 `EiscueTunnel` 扩展，也可使用地址兼容的外部 LocalDevVPN。Kit 不替宿主创建系统 VPN 配置；普通远程 VPN 不能代替本机数据包回注。开发板方式使用 `connect(method: .wirelessBoard)` 或 `.usbBoard`，不启动本地 VPN。

截图返回图片数据、准确的 MIME 类型、实际像素尺寸、时间与 frameID；iOS 26 新路径为 PNG，原视频路径为 JPEG。调用方应使用返回的 MIME 类型。坐标使用截图像素，不能使用 UIKit point 或直接传 0…65535 的归一化值。仅最新截图能授权一次点击、滑动或带 frameID 的文本输入，有效期 30 秒；重新截图、断连、重新连接和任何改变屏幕的操作都会撤销旧截图。发送坐标或带 frameID 的文本前还会核对当前画面的几何代次；旋转、可见区域或视频代次变化使旧截图失效，旋转回来也不能复用。iOS 26 还核对独立会话的显示 ID、方向、缩放与几何修订；截图前后不一致则拒绝该帧。滑动时间范围为 0.1…2 秒。正常截图只在内存中返回，Kit 不写入照片或磁盘。

可用动作以连接后报告的能力为准，不能从公开方法的存在推断当前系统已支持。iOS 26 的截图、点击、滑动、Home、文本输入与 App 启动已通过[无线真机验证](board-validation-2026-10-11.md)，正常版本开放这些能力。文本输入将给定文字写入系统剪贴板，再通过本会话发送一次 Command-V，不读取原剪贴板；调用方仍须确认目标焦点、系统粘贴授权和输入后的可见内容。

每个 controller 一次只执行一个操作；并发操作返回 `busy`。`disconnect()` 立即撤销本地代次、输入资格与截图，停止发现 / 配对，然后在最多 5 秒内向旧会话请求远端媒体释放，最后始终关闭旧传输。清理期间新连接返回 `busy`；重复断连等待同一清理任务。取消、超时或未收到明确释放确认时，状态保留“远端屏幕会话释放未确认”，不能把关闭本地 socket 当成远端已经结束观察。已发出的物理触控无法撤回。

动作成功仅表示协议报告已写出，不能据此认定界面产生预期效果。调用方应重新截图确认。非幂等操作发送失败返回 `DeviceControlError.deliveryUnknown`（可通过 `isDeliveryUnknown` 判断），Kit 不自动重试。调用方应停止当前任务、重新连接、重新截图核对后由用户决定下一步。

## 身份存储和导入

默认使用 `KeychainPairingIdentityStore`，存储为不参与同步的 `AfterFirstUnlockThisDeviceOnly` Keychain 项。重启后首次解锁前无法访问；身份不会随设备备份迁移。密钥不会出现在日志或 UserDefaults 中；USB 初始化仅通过受限临时文件交付。宿主可用 `DeviceClient(identityStore:)` 注入自己的受保护存储，测试应使用独立 store，避免清除真实身份。

`importPairingIdentity(_:)` 接受用户明确选择的 JSON 或 plist，格式为上游版本 1 的 `RemotePairRecord`，上限 32 KB，且 `committed` 必须为 true；普通 Lockdown 配对文件不能代替它。导入失败保留旧身份。Kit 不自动搜索其他 App 的身份。导入数据含私钥，宿主不应把它留在未保护的文件、上传、分享或打印。

系统配对协议在最终确认前也需要可靠存储阶段身份。如果用户中途取消且已写入阶段身份，Kit 保留该身份，不误报为有效连接；可通过明确的移除本地身份操作后重新配对。移除本地身份并不等于撤销系统端已保存的授权，系统授权需在系统设置管理。

## 构建及验证

仓库包含 arm64 的 iOS 真机、iOS Simulator、macOS 三个静态库 slice，Intel Mac / x86_64 模拟器当前未提供。构建脚本固定 Rust 1.96.0，不改变机器的默认工具链：

```sh
rustup toolchain install 1.96.0 --profile minimal \
  --target aarch64-apple-ios,aarch64-apple-ios-sim
Scripts/build-device-backend.sh
swift test --filter DeviceKitTests
rustup run 1.96.0 cargo test --locked \
  --manifest-path Vendor/DeviceBackend/rust/Cargo.toml --lib
bash Scripts/test-owned-automation.sh
```

脚本使用 vendor 中的 Rust 全源及 Cargo.lock，按平台构建并移除 debug 符号后生成 `NCMNativeBackend.xcframework`。首次构建需要联网获取 Cargo.lock 固定的依赖。SwiftPM 通过内部 binary / C targets 链接，不使用指向某台机器目录的 unsafe linker flags。

当前验证覆盖 Kit 单元测试、Rust 协议 / 取消 / 会话隔离测试、独立 XCTest 桥接的宿主 fixture、App 授权页后台生命周期测试与编译。指定 C3 / 8 MB 样机与 iPhone 14 Pro 的 Wi-Fi 真机验证已覆盖配对身份、系统授权、连接就绪、截图、点击确认、滑动、中文输入、Home / 返回 App、断连重连及旋转后旧截图拒绝；持续后台任务与公司 VPN 共存仍未验证。宿主 fixture 使用模拟类，不加载开发者框架、不连接手机，不能代替实际输入。上游的真机记录也不能代替 Eiscue 的验收；新设备或系统版本应在可逆操作中重新检查上述流程。

Debug 的 `--owned-device-check` 在正常 App 进程中提供独立验证页面，检查真实按钮计数、滚动位置、文本及前后台状态，不需要 UI Test Runner 或模型请求。它是显式开发入口，不自动用于正常启动，也不把任一步失败记为成功。这个入口可保存受文件保护的准备页截图用于本地核查；该例外不改变正常截图只在内存返回的约定，系统密码页图片和原始设备日志不提交仓库。

## 来源

后端来自 [actell 的固定版本](https://github.com/ja1chen/actell/tree/032864e2339da19ee13025c471f4cf1dfdf4c5cd)，只搬运 NCM 控制后端。完整来源、GPL 与依赖许可证见 [Vendor/DeviceBackend/README.md](../Vendor/DeviceBackend/README.md)。这些声明描述所引入组件的许可，不替整个 Eiscue 项目选择许可证。
