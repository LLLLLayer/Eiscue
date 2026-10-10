# 独立使用 AgentKit

在 Xcode 添加此仓库的 Swift Package，给宿主 target 选择 `EiscueAgentKit` 产品即可。它不依赖 EiscueDeviceKit，也不包含 Eiscue App 的界面、Keychain 配置或系统后台任务。

## 配置与工具

```swift
import EiscueAgentKit
import Foundation

func makeAgent(configuration: AgentConfiguration, storage: URL) -> AgentClient {
    let clock = AgentTool(
        name: "current_time",
        description: "Read the current UTC time.",
        parameters: ["type": "object", "properties": [:], "additionalProperties": false],
        mayHaveSideEffects: false
    ) { _ in
        .text(Date().ISO8601Format())
    }
    return AgentClient(configuration: configuration, storageDirectory: storage, tools: [clock])
}
```

`AgentConfiguration` 接受接口类型、服务地址、模型 ID、密钥、图片能力和 token 上限。宿主负责从自己的安全存储获取密钥，避免把包含密钥的配置写入普通文件。实例在内存中保存配置，修改配置后创建新的 client；先停止旧 client，避免两个运行时同时写同一会话。

工具的参数和结果使用 Eiscue 自有类型。副作用工具将 `mayHaveSideEffects` 保持为默认的 `true`；图片通过 `AgentToolResult.image(data,mimeType:caption:)` 返回。权限、用户确认、设备输入门控和结果未知后的停止，由提供工具的宿主落实。

## 执行与停止

```swift
func run(agent: AgentClient, conversationID: UUID, requestID: UUID, prompt: String) async throws {
    let request = AgentRequest(
        conversationID: conversationID,
        requestID: requestID,
        prompt: prompt,
        maxToolCalls: 10,
        timeoutSeconds: 120
    )
    for try await event in try await agent.run(request: request) {
        switch event {
        case .requestAccepted(let id): print("Accepted:", id)
        case .assistantText(let text): print(text) // 本轮完整流式文本，替换上一次 partial。
        case .message(let message): print(message.text)
        case .toolStarted(let call): print("Tool:", call.name)
        case .toolFinished: break
        case .finished: break
        }
    }
}
```

每条用户请求在落盘前生成并保存 `requestID`。重试未确认提交的请求沿用原 ID；同一会话的后续新消息使用新 ID。单个 client 一次运行一轮；主动停止调用 `try await agent.cancel()` 并等待返回，之后才能开启下一轮或删除会话。不要只停止界面更新。

`recover(conversationID:)` 只读取，不启动模型或重放工具。如果 `hasInterruptedRun` 为 true，由用户核查当前状态，再提交 `mode: .resume` 的请求，或调用 `cancel(conversationID:)` 结束旧任务。已被取消的任务不能直接 resume；提交新的核查指令继续业务目标。

只读管理旧记录可用 `AgentClient(storageDirectory:)`，无需模型凭据。`removeConversation(id:)` 删除对应运行时文件，宿主自己保存的聊天展示和任务日志也需由宿主删除。

## 替换引擎

自研实现遵守 `AgentEngine` 的执行、事件、恢复、取消和删除协议，然后传入 `AgentClient(engine:)`。公开 API 没有 Pi 类型，调用方无需更改设备工具或 UI。当前实现使用 PiDurableKit 的 SQLite 保存执行上下文；换引擎时可以迁移 Eiscue 消息，但不能直接把 Pi 的进行中任务交给其他引擎重放。
