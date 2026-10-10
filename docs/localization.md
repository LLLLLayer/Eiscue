# 本地化

App 与系统扩展使用 Apple String Catalog（`.xcstrings`），英文为开发语言，提供简体中文（`zh-Hans`）翻译。使用系统的语言选择与回退机制；设置中的「App 语言」打开 iOS 的 Eiscue 设置。没有独立语言字典或自定义切换引擎。

## 资源归属

| 资源 | 内容 |
|---|---|
| `Apps/Eiscue/Resources/Localizable.xcstrings` | 主要界面、设备操作提示、模型配置、技能名称和运行记录 |
| `Apps/Eiscue/Resources/Runtime.xcstrings` | App 执行流程、设置、后台任务错误 |
| `Apps/Eiscue/Resources/Connections.xcstrings` | 本地连接管理、通知权限与结束通知 |
| `Apps/Eiscue/Resources/TaskStatus.xcstrings` | 系统实时活动的阶段、动作类别和调用计数 |
| `Apps/Eiscue/Resources/InfoPlist.xcstrings` | 系统本地网络权限说明 |
| `Apps/EiscueTunnel/Resources/` | 扩展名称和扩展错误 |
| 两个 Kit 的 `Resources/{en,zh-Hans}.lproj/Localizable.strings` | 可独立分发的错误、状态与默认文案 |

SwiftUI 的静态文字使用本地化 key；动态字符串和 `LocalizedError` 使用 Foundation 的 `String(localized:)`。可变参数保留在官方格式化／插值机制中，数量使用 Catalog 的 plural variations，日期和时长使用 Foundation 的地区格式。Kit 通过 `Bundle.module` 读取自己的资源，避免依赖宿主 App 的文案表。Swift Package 的 `.strings` 资源兼容命令行 `swift test` 和 Xcode 构建。

模型协议、工具标识、文件名、Bundle ID 和系统提示词不翻译。用户的会话、导入 Skill 及既有自由文本记录保留原文；内置 Skill 的名称和摘要已本地化，其 Markdown 指令按资源原文提供。运行记录使用稳定事件类型，展示时选择本地语言；系统实时活动不会展示原始日志或用户内容。

## 增加语言

1. 在 Xcode 中选中各 String Catalog，添加语言（例如 `ja`），填写翻译并按需要添加复数变体。保留语义 key 和参数类型；参数可以通过位置标识重排。
2. 为两个 Kit 添加相应的 `<语言>.lproj/Localizable.strings`，保持 key 与英文表一致。
3. 将语言加入 `project.yml` 的 `CFBundleLocalizations`，执行 `xcodegen generate`。不要在 Swift 中新增按语言判断的分支。
4. 使用 Scheme 的 Application Language / Application Region，或 UI 测试的 `-AppleLanguages` / `-AppleLocale`，验证布局、插值、数量以及系统权限说明。

当前测试验证中英资源打包、复数规则、动态值保留，以及中英界面启动和通知默认关闭。新增翻译可以通过 Xcode 导出／导入 `.xcloc`，无需改变执行逻辑。

参考：[Apple String Catalog](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog)、[Swift Package 本地化](https://developer.apple.com/documentation/xcode/localizing-package-resources)。
