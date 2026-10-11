# 蓝牙普通流程接入与真机验收 — 2026-10-12

本记录区分代码已接入、软件验证与真实手机效果。当前普通 App 已提供蓝牙开发板
入口、Apple ReplayKit 屏幕共享、四点坐标检查、文字输入检查及 Agent 工具接入；
不再需要 Debug 参数才能使用这些页面。新安装默认蓝牙，升级保留原连接偏好。

## 当前结论

| 项目 | 状态 | 证据与范围 |
| --- | --- | --- |
| iOS 模拟器构建 | 通过 | `eiscue-bluetooth-simulator-build.log`：BUILD SUCCEEDED |
| 真机签名构建 | Debug / Release 均通过 | `eiscue-bluetooth-signed-build.log` 与 `eiscue-bluetooth-release-build.log` 均为 BUILD SUCCEEDED |
| App 定向检查 | 27 项通过、0 失败 | `eiscue-bluetooth-focused-tests.log`：TEST SUCCEEDED |
| ScreenBroadcastStore | 3 项通过 | 暂停/恢复需要新帧；停止不可影响新会话；静默或终止的扩展不能留下可操作旧帧 |
| 蓝牙 0.2 固件 | 构建、烧录与读回通过 | 仅写已有应用分区，保留原备份和私有配置；镜像版本与哈希见固件 README |
| 普通 App 蓝牙连接 | 已在真机确认 | 重连修复后 INFO 返回 `3`，表示实际绝对指针、键盘通知均已订阅；App `isConnected` 为 true |
| ReplayKit 实际画面 | 本次真机校验通过 | 竖屏 740 × 1600 pixel，共享 active；校验完成后 App 仍为 ready / connected / sharing active |
| 四点坐标校验 | 真机通过 | 393 × 852 point 窗口收到四个实际触摸位置，报告 `pointCount: 4`、`passed: true`，详见下表 |
| 中文文字校验 | 真机通过 | 实际输入框与含“你好”的预期文本一致，`keyboardVerified: true` |
| 滑动与长时间后台共享 | 待真机验收 | 四点点击通过不能推断拖动或持续后台行为已通过 |
| 跨 App / Agent 完整任务 | 待真机验收 | 完成上述准备后再验证实际任务结果及停止行为 |

本地构建日志在 `/tmp/eiscue-bluetooth-simulator-build.log`、
`/tmp/eiscue-bluetooth-signed-build.log`、`/tmp/eiscue-bluetooth-release-build.log`，存储检查日志在
`/tmp/eiscue-screen-store-tests.log`；27 项 App 检查日志为
`/tmp/eiscue-bluetooth-focused-tests.log`。三项存储测试共耗时约 3.38 秒；未为此次文档
更新重复运行测试。测试使用隔离存储，不连接手机，不证明 ReplayKit 真机生命周期。

导航修复后，最新签名 Debug 构建与 27 项 App 定向检查再次通过，并已安装到指定
测试机。导航修复版安装后，用户重新开启共享并完成检查；02:17:45 状态再次为
`ready: true`、`pointerVerified: true`、`sharing: true`。设备页使用真实根导航栈；
模拟器截图确认原生返回箭头，避免测试入口直接
呈现设备页导致无法返回对话。

## 真机与固件

- 指定测试手机：iPhone 14 Pro，iOS 26.5.2；开发板：已确认的 ESP32-C3 / 8 MB 样机。
- 开发板 USB 连接电脑供电和烧录，运行输入走蓝牙，不插手机，不占手机 Wi-Fi。
- 0.2 固件提供绝对坐标报告、受限 Command-H / Command-V、实际订阅能力查询，
  以及持续按住 250 ms 超时自动释放。正常 App 只按已开放能力注册 Agent 工具，
  当前未开放蓝牙 Home、应用列表或应用启动。
- 烧录前保存完整 8 MB 备份并完成 ROM 校验；只更新 `0x20000` 应用分区，烧录后
  读回校验。私有备份、配对数据与原始屏幕不提交仓库。
- [固件协议与构建证据](../Firmware/Passport-BLE/README.md)记录镜像哈希和本机
  UBSan 检查；这些软件检查不能代替实际坐标和手机按住释放效果。

## 已定位并修复的重连问题

初次运行日志显示，NimBLE 在连接回调之前恢复了 bonded peer 的 HID / Response
订阅；随后原 `on_connect` 把订阅标记全部清空。真实 INFO 因而返回 `0`，即使
系统已经订阅，新 App 仍无法进入可用状态。

修复后，订阅回调带上连接 handle，仅保留同一有效连接提前恢复的订阅；断开或换
连接时清空，旧连接事件不能污染新连接。针对该回调顺序的本机 UBSan 检查通过。
新版应用镜像已重新烧录和读回，真实 INFO 返回 `3`，普通 App 连接状态为 true。
本地硬件记录位于 `.build/bluetooth-verification/`，不公开设备原始日志。

固件还通过标准 GATT Service Changed 请求 iOS 刷新升级后的 HID 描述符。
订阅成功仅证明通道可用，不代表绝对坐标已经正确落到屏幕位置。

## 屏幕共享与操作边界

用户需要在 Apple 系统面板确认“开始直播”；App 不能替用户确认。扩展只处理视频，
不采集麦克风或 App 音频，不向外部推流。在受保护的 App Group 缓存中，仅保留
最新 JPEG 帧。设备任务调用截图工具时才把图像发给所配置的模型服务。

超过 3 秒的旧帧、停止或暂停的共享会话不能授权输入。首次操作校验要求全屏、
页面可见且几何稳定；四个真实触摸检查坐标映射，随后检查真实文字输入。旋转、
重新连接或共享会话改变需要重新校验。输入送出后不得自动重发来“试到成功”。

## 四点与文字的实际结果

本地报告 `.build/bluetooth-verification/last-validation.json` 记录：`passed: true`、
`keyboardVerified: true`、`pointCount: 4`，窗口为 393 × 852 point。以下均为窗口
归一化坐标，观察值来自真实 UIKit 触摸回调：

| 指令目标 | 实际触摸 |
| --- | --- |
| (0.25, 0.25) | (0.250212, 0.250000) |
| (0.75, 0.25) | (0.749788, 0.250000) |
| (0.25, 0.75) | (0.250212, 0.750000) |
| (0.62, 0.61) | (0.620017, 0.609937) |

随后实际输入框收到完整中文检查文本；该检查的预期形式为 `Eiscue 你好 ` 加随机
四位数字。检查完成后的 App 状态为连接 true、共享 active、操作 ready，截图显示
三项检查均通过，手机正常 Wi-Fi 图标仍在。本次没有再次以禁用请求蜂窝访问的 HTTPS
请求验证出网，因此不将 Wi-Fi 图标当作完整联网验证。

此前重启 App 后曾观察到旧共享帧变为 stale，旧帧没有继续被用于操作；此次校验
使用有效新帧。该结果证明本次共享和前台校验链路，不证明跨重启持续共享、长时间
后台或系统锁屏恢复。生产滑动、完整跨 App Agent 任务与这些生命周期行为仍待验证。

## 旧版基线不能替代此次验收

[0.1 蓝牙实验记录](ble-board-validation-2026-10-12.md)已经验证：三次 12 位数字
输入、一次全屏无害测试按钮点击，以及在该请求禁用蜂窝访问时 Wi-Fi HTTPS 返回
200。它使用旧的相对鼠标与 ASCII 路径，没有验证绝对坐标映射、中文粘贴、ReplayKit
共享、Agent 接入或持续后台任务。也不能直接推断其他开发板、iPad 或系统版本兼容。
