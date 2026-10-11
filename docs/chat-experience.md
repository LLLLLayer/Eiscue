# 对话、附件与语音

## 导航与设备入口

App 以对话为主页面，不再使用底部 Tab。iPhone 从左侧展开历史记录；iPad 在可用宽度至少 820 pt 时默认显示侧栏，按钮可收起/展开，窄窗口使用同一抽屉。对话记录以横向整行排列，长按支持置顶、上移、下移和删除；手动顺序保存在本机，回复更新时间不会覆盖排序。侧栏底部为新对话和设置。按钮、SF Symbols 和文字使用随浅色／深色模式切换的黑白灰，辅助信息使用系统次要文字颜色；状态由图标形状和文案区分。贴纸和 App 图标保留原图颜色。

浮动操作区采用 iOS 26 原生 Liquid Glass：侧栏左下角为新对话玻璃胶囊，右下角为设置透明玻璃圆钮；输入区是加号、输入框、发送三个同级玻璃控件。麦克风使用输入框内的普通图标，避免叠加多层材质。顶部保留系统工具栏玻璃，设备状态徽标和侧栏图标使用统一尺寸的 SF Symbols。设备、引导、模型和技能页面的独立操作按钮使用 `.glass` / `.glassProminent`；正文、消息及设置列表使用语义背景，以保留阅读层次。实现参考 [Apple 自定义视图 Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)。

右上角设备按钮显示未配对、已配对但未连接、连接中、可用或异常。保存配对身份不等于可以控制设备；连接成功才显示勾选。点开按钮进入配对及连接页面。输入框的加号提供“允许 AI 操作设备”开关，默认关闭；Kit 内部保留 observe 能力以兼容其他宿主，普通输入界面只提供是否操作设备的选择。

此布局更新没有消除当前后端的电脑初始化依赖，详见 [真机设备控制](device-setup.md)。

## 照片、拍摄和文件

加号内可选择照片、拍摄或从系统文件选择器导入。PhotosPicker 仅提供用户选择的照片，不申请整个图库权限；拍摄时申请相机权限。没有相机的设备会明确提示，可改用已有照片。

每条消息最多 4 个附件。支持静态图片、文本/代码/JSON/CSV 和可提取文字的 PDF。源文件上限 20 MiB；图片限制 4000 万像素，导入后缩到最长边 2048 像素、单张最多 2 MiB，并重新编码移除 EXIF 定位等元数据。PDF 最多 100 页；单份文档提取文字最多 60000 UTF-8 字节。扫描 PDF、受密码保护或不支持的文件会报错，不会假装已经读到内容。

附件进入 App 私有存储和持久化对话，原文件 URL 不传给模型。Kit 的 AgentAttachment 与运行时无关；图片真实进入多模态模型请求，文档则以提取出的文字提供。模型需要声明支持图片；取消或失败保留草稿，成功才清空，恢复同一请求也遵循这一规则。删除会话同时清理不再引用的私有附件。附件仅在用户按发送后随消息交给所配置的模型服务。

## 本机语音输入

语音使用 Apple Speech 框架的 SFSpeechRecognizer，无需第三方语音 API Key。先检查 supportsOnDeviceRecognition，再设置 requiresOnDeviceRecognition=true；不可用时提示，不回退到云端。[Apple API 文档](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition)

- 点击麦克风开始，再点停止；也可以按住麦克风说话，松开结束。
- 空输入框长按可唤起持续听写；已有文字时保留系统选字/粘贴交互，仍可用麦克风追加语音。
- 识别过程显示实时预览，结束后一次追加到草稿，用户自行发送。
- 首次授权期间松手会取消开始请求；取消、切换对话、退后台和系统音频中断会释放麦克风。语音回调绑定创建时的草稿会话，迟到结果不能写入新对话。
- 音频仅在内存流转，不写成录音文件。单次最多 55 秒，适用于短语音输入。可用语言由设备本机识别支持情况决定。

## 普通聊天与插画素材

普通聊天默认只提供简短的身份、回复语言与简洁性提示，没有工具，也不附加设备操作说明。表情 Skill 已移除，不再向模型提供表情目录或鼓励问候时发送表情。其他 Skill 仍需用户在设置中明确选择；设备工具及对应操作规则只在用户允许操作设备后启用。每次发送都会替换运行时的系统指令，已有对话可继续使用；旧回复仍作为对话历史保留。

用户的四张图片已加入素材目录；其中坐姿图用内置 imagegen 去白底，另外三张保留原透明像素。另用同一风格生成招手表情。全部项目资产位于 `Apps/Eiscue/Resources/Assets.xcassets/Sticker*.imageset`，不依赖 Codex 的生成目录。

`Stickers.json` 保留为插画目录，记录 ID、资源名、本地化名称和含义。设置中可浏览素材，欢迎页和空侧栏继续使用插画。历史消息中已有的 `[[eiscue:wave]]` 等已知标记仍可显示原图；未知标记不会加载远程资源，单条消息最多渲染两张。目录不再注入模型请求。

内置 imagegen 的两次处理提示：

1. 坐姿抠图：`Use case: background-extraction. Edit target: attached seated ice-cube-headed penguin illustration. Remove ONLY the external white background to actual alpha transparency. Preserve exact pose, character, colors, thick navy silhouette, square centered framing, highlights and internal white belly and eyes. Clean antialiased edges, no white fringe, no shadow, no border, no fake checkerboard. No redesign or additions. Transparent PNG sticker for a light and dark iOS chat app.`
2. 招手扩充：`Use case: stylized-concept. Create one new greeting sticker of the exact ice-cube-headed Eiscue penguin mascot from the reference. Match its chunky dark-navy outlines, softly shaded cyan ice cube head with tiny dark two-prong tuft, little white belly, black flippers, yellow feet, and simple faceted blue beak. Friendly hello pose: standing, one flipper raised in a clear wave, the other lowered, cheerful softly curved closed eyes. Same polished cute illustration style. Full character visible, centered square composition with generous clear margins. No words, letters, logos, motion marks, accessories or extra objects. Actual transparent alpha background, no white outline or halo. The pose and friendly eyes may change; preserve the unmistakable mascot design and proportions.`
