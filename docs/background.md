# iOS 26 后台任务接入

`Apps/Eiscue/Services/BackgroundExecution.swift` 管理一个由用户发起的 `BGContinuedProcessingTask`。它负责申请、真实进度、系统到期与完成通知，不负责执行 Agent 或设备操作。此 API 的系统界面允许用户查看进度并取消；系统也可能提前结束任务。[Apple 说明](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)

## 工程配置

App 的 Info.plist 必须包含以下数组，展开后的值需要与 `BackgroundExecution.shared.identifier` 一致：

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER).agent.continued-processing</string>
</array>
```

默认 Bundle ID 下的标识是 `org.eiscue.app.agent.continued-processing`。使用单个静态标识与单例服务，每个进程只注册一次。Apple 同时支持静态和动态标识；这里无需给每条会话建立系统注册项。[WWDC25 接入说明](https://developer.apple.com/videos/play/wwdc2025/227/)

当前只使用默认的 CPU、网络资源，不申请 GPU entitlement。Xcode 26.3 SDK 的 `BGContinuedProcessingTask` 声明及 Apple 接入指引未要求额外的 `UIBackgroundModes` 值；`processing` 的要求写在另外的 `BGProcessingTask` API 上。本实现不注册该类型，也不添加音频、定位后台模式。

## 宿主调用

App 启动时调用 `try BackgroundExecution.shared.register()`，并保存或展示注册错误。方法可重复调用，成功后不会重复注册。可放在 App 初始化或 `application(_:didFinishLaunchingWithOptions:)` 中。

用户在前台明确发起任务后：

1. 为本次执行创建新的 UUID，调用 `try await begin(taskID:title:subtitle:totalUnitCount:onExpiration:)`。
2. 只有 `begin` 返回成功后，才把本次任务视为已获得系统后台执行机会。
3. 工作推进时调用 `update(taskID:completedUnitCount:totalUnitCount:title:subtitle:)`，上报实际完成量。进度无效、任务已结束或 UUID 过期时返回 `false`。等待系统启动期间的有效更新会被缓存；launch handler 收到任务后，立即应用最新标题、副标题和真实进度。空白副标题会回退到本地化的运行状态。
4. 正常完成调用 `end(taskID:success: true)`，失败或 App 内停止调用 `end(taskID:success: false)`。宿主同时负责停止 Agent、网络请求和设备操作。

`onExpiration` 是 `@Sendable () -> Void`，在系统到期回调中同步执行。它应立即取消宿主的工作，且不能做耗时清理。Swift Task 的 `cancel()` 可以直接调用；更新 App 状态需要通过 `Task { @MainActor in ... }`。服务随后以失败状态完成系统任务，任务完成通知只发送一次。

`begin` 使用 `.fail` 策略；系统无法立即运行时，提交错误直接抛给宿主。服务不会自行排队或选择前台降级。宿主可以明确提示用户，并按产品规则决定是否仅在前台继续。

## 取消与异常边界

取消等待 `begin` 的 Swift Task，会撤销尚未启动的请求；已有系统任务则立即完成为失败。宿主调用 `end` 也具有相同的资源清理效果。延迟到达的取消和完成操作由内部 token 隔离，不会结束后来的任务。

系统提交成功后若 10 秒内没有执行 launch handler，服务抛出 `launchTimedOut`，撤销请求并释放等待 continuation。取消或超时发生在 launch handler 到达之前时，静态标识会暂时停止接受新请求：系统没有提供把晚到的静态标识回调关联到原始提交的方法，因此必须避免让旧回调错误启动新任务。晚到回调出现后会被完成为失败并解除该限制；如果没有晚到回调，需要重启 App 才重新申请后台执行。在此期间，宿主仍可明确选择前台执行。

用户从 App 切换器强制退出时，系统可以直接终止任务，App 不一定收到取消回调；关键记录仍需及时持久化。此服务不承诺无限运行或进程终止后的自动恢复。[Apple 任务完成说明](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)

宿主在设备任务正常结束、失败或停止时先关闭输入门控，再等待有时限的屏幕服务释放，最后结束后台任务。闲置连接和仅对话任务在 App 进入后台时也会断开；正在配对或已取得后台执行机会的设备任务继续由各自任务管理。下一次设备任务需要重新连接。若释放没有得到确认，设备页保留该状态，不把本地 socket 关闭当作远端媒体已停止。

## 验证范围

源码可独立使用 iOS 26 SDK 编译，并启用 Swift 6 完整并发检查。实际后台授权、系统进度界面、系统取消和切到其他 App 后的运行，需要在真机上验证；模拟器或仅编译成功不能证明已获得后台执行权限。

## 运行状态与可选通知

设备任务使用 iOS 26 `BGContinuedProcessingTask` 自带的系统实时活动，不重复申请另一个 ActivityKit 活动。系统决定它在灵动岛、锁屏等界面的呈现；App 上报标题、当前阶段和实际完成的执行单元。紧凑灵动岛不保证显示副标题，可以长按展开查看更详细的系统任务界面；App 无法强制系统展示特定布局。该系统活动由后台执行机制管理，没有伪装成可关闭的自定义开关。

`TaskStatusPresentation` 仅输出简短的当前操作，如「等待 AI 回复」「正在查看屏幕」「正在执行步骤」「正在保存结果」。它不包含用户提示词、截图、输入内容、模型名称、错误详情或应用标识，也不向用户展示工具调用术语或调用计数。内部仍以已结束的调用（包括返回错误的调用）统计真实进度，计数不代表用户目标成功；总执行量随已发现的调用增加，不把调用预算当作目标完成百分比，也不使用定时器虚增进度。系统结束状态在媒体释放和最终记录保存之后更新，保存失败不会发布成功状态。

支持系统配对的设备会同步准备、等待系统设置、等待用户确认、配对记录已保存、配对完成等阶段。副标题来自固定的中英文资源，不展示 PIN 或配对记录；进度只随收到的配对事件推进。

设置中的「完成与中断通知」默认关闭。用户明确打开后才申请 iOS 通知权限；拒绝、撤销或关闭会如实更新设置。通知使用本地 `UNUserNotificationCenter`，无需推送服务器、APNs Token 或额外 entitlement。仅在 App 确实处于后台时投递固定的结束状态，每次执行最多一次；用户回到前台或取消通知开关时抑制迟到通知。前台被系统弹窗覆盖的 `.inactive` 状态也不投递通知。

通知不会扩大后台运行权限。系统直接终止进程时，App 可能没有机会发出结束通知。纯对话仍沿用进入后台暂停的策略；设备任务才申请持续后台执行。系统活动、通知显示位置与真实设备后台运行效果需真机验收。
