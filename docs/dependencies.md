# 固定依赖与来源

| 组件 | 版本 | 使用位置 |
|---|---|---|
| PiDurableKit | 6e7f267181500943db328bbe2a262ae17b39bef1 | AgentKit 内部运行时，SwiftPM 远程依赖 |
| actell 控制后端 | 032864e2339da19ee13025c471f4cf1dfdf4c5cd | Vendor/DeviceBackend，Swift/C/Rust，GPL-3.0 |
| LocalDevVPN / StosVPN 回环实现 | af3fd697803ada4ac2b8d518358f5ab0a534844c | 内置 EiscueTunnel 扩展的实现参考与来源，自定义 StosVPN License；无需额外安装 App |

PiDurableKit 来源：[finnvoor/PiDurableKit](https://github.com/finnvoor/PiDurableKit/tree/6e7f267181500943db328bbe2a262ae17b39bef1)。根许可为 CC0-1.0；其嵌入 JS 包另有第三方许可，查看依赖仓库中的 LICENSE / ThirdPartyNotices。Xcode/SwiftPM 锁文件随工程保存。

控制后端来源：[ja1chen/actell](https://github.com/ja1chen/actell/tree/032864e2339da19ee13025c471f4cf1dfdf4c5cd)。保留完整相关源代码、Cargo.lock、GPL LICENSE、第三方来源与补丁说明；详见 [vendor 说明](../Vendor/DeviceBackend/README.md) 和 [UPSTREAM_THIRD_PARTY.md](../Vendor/DeviceBackend/UPSTREAM_THIRD_PARTY.md)。

没有复制 TouchSynthesis。引入组件的许可证不等同于已经确定整个 Eiscue 的分发方式；公开发行前需要按实际组合方式履行相关许可义务。开发签名也不等于 App Store 分发可行。

本地连接扩展基于 LocalDevVPN / StosVPN，保留来源与自定义许可，并在 README / App 关于页面署名，见 [LocalTunnel 说明](../Vendor/LocalTunnel/README.md)。它与 actell 控制后端是两项不同组件。
