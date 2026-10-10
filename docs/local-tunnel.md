# 内置本地连接

Eiscue 将本地回环网络打包为 `EiscueTunnel.appex`，随主 App 安装。用户无需另装 LocalDevVPN。在设备页点击「开启本地连接」，首次保存配置时由 iOS 显示添加 VPN 配置的授权。读取状态和启动 App 不会自动创建或开启 VPN。

## 结构

- `Apps/EiscueTunnel/`：系统 Packet Tunnel Extension，负责受限的 IPv4 回注。
- `Apps/Shared/LocalTunnelConfiguration.swift`：主 App 与扩展使用的地址和配置版本。
- `Apps/Eiscue/Services/LocalTunnelManager.swift`：系统配置、状态通知、显式启动与停止。
- `EiscueDeviceKit`：继续通过本地网络接口连接设备；不依赖主 App 的扩展，也能由其他宿主提供兼容通道。

这是系统扩展 target，不是额外的 App 或公开 Plugin。第三方单独使用 DeviceKit 时，需要在自己的宿主中嵌入并签名扩展，或自行提供兼容的回环网络；只导入 Swift Package 不会自动安装系统扩展。

## 路由与生命周期

扩展固定使用本地 `10.7.1.1/24` 和对端 `10.7.0.1/32`，只把对端主机路由送入 tunnel，不设置互联网默认路由或 DNS。只反射地址匹配的有效 IPv4 数据包，不记录包内容、转发外网流量或共享配对密钥。

主 App 只操作 provider bundle ID 与自己匹配的配置。保存配置后重新读取，再启动并等到系统报告已连接。系统可能拒绝授权或启动；界面以真实状态为准。其他 VPN 可能与本地连接冲突，Eiscue 不声称能够枚举、停用或恢复所有其他 App 的 VPN。

关闭本地连接时先停止设备任务、释放远端屏幕服务，再关闭 VPN。意外丢失 VPN 时立即关闭设备工具门控并停止依赖设备的任务，纯对话任务不受此事件影响。VPN 本身不提供 Agent 的后台执行许可；现有 BGContinuedProcessingTask 仍然负责后台时限。

## 签名

主 App 和扩展都声明 `com.apple.developer.networking.networkextension = [packet-tunnel-provider]`，需要开发团队为两个 App ID 提供匹配描述文件。默认标识为 `org.eiscue.app` 与 `org.eiscue.app.tunnel`。更换主 App 的 Bundle ID 时，也要同步扩展 ID 并保留 `.tunnel` 后缀。

签名能力来自开发团队，编译通过不能证明设备获准运行扩展。配对身份只由主 App 的 DeviceKit 管理，无需 App Group 或共享 Keychain。参见 [Apple 扩展部署说明](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)。

## 系统边界

本机数据包反射沿用 LocalDevVPN 的方案。Apple 对 Packet Tunnel 的预期用途是连接远程网络，并在 [TN3120](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers) 中明确提醒不要将截获包直接重注入本机。因此此实现需要在目标系统上实际验证，不能承诺未来系统兼容或 App Store 分发可行。

内置解决的是额外安装问题。开发者模式、DDI、系统设备配对和首次 VPN 授权仍然需要完成。源代码与许可归属见 [LocalTunnel 说明](../Vendor/LocalTunnel/README.md)。
