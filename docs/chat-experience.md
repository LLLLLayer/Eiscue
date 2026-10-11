# 对话、附件与语音

## 导航与设备入口

App 以对话为主页面，不再使用底部 Tab。iPhone 从左侧展开历史记录；iPad 在可用宽度至少 820 pt 时默认显示侧栏，按钮可收起/展开，窄窗口使用同一抽屉。对话记录以横向整行排列，长按支持置顶、上移、下移和删除；手动顺序保存在本机，回复更新时间不会覆盖排序。侧栏底部为新对话和设置。按钮、SF Symbols 和文字使用随浅色／深色模式切换的黑白灰，辅助信息使用系统次要文字颜色；状态由图标形状和文案区分。贴纸和 App 图标保留原图颜色。

浮动操作区采用 iOS 26 原生 Liquid Glass：侧栏左下角为新对话玻璃胶囊，右下角为设置透明玻璃圆钮；输入区是加号、键盘/语音切换、输入框和发送。语音模式用独立的按住区域替换输入框，不给 TextField 添加长按手势。顶部保留系统工具栏玻璃，设备状态徽标和侧栏图标使用统一尺寸的 SF Symbols。设备、引导、模型和技能页面的独立操作按钮使用 `.glass` / `.glassProminent`；正文、消息及设置列表使用语义背景，以保留阅读层次。实现参考 [Apple 自定义视图 Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)。

右上角设备按钮显示未配对、已配对但未连接、连接中、可用或异常。保存配对身份不等于可以控制设备；连接成功才显示勾选。点开按钮进入配对及连接页面。输入框的加号提供“允许 AI 操作设备”开关，默认关闭；Kit 内部保留 observe 能力以兼容其他宿主，普通输入界面只提供是否操作设备的选择。

此布局更新没有消除当前后端的电脑初始化依赖，详见 [真机设备控制](device-setup.md)。

## 消息与流式回复

通过配置、范围与附件验证后，发送立即将用户消息放到对话中，清空文字与附件，并显示回复动画；持久化和模型请求随后执行。本地保存失败会撤销未保存的消息、恢复原草稿，但不覆盖用户新输入。模型请求失败或中断时，已提交消息仍留在对话，不自动重新放回输入框。

回答随真实流式事件更新。每段助手消息与真实工具调用分开排列，工具可展开查看输入、结果和时间，不虚构未提供的命令或文件能力。工具锚定实际事件流中的上一条消息，持久化原用户 ID，避免异源时间戳或重启造成错序。聊天页不显示单独的“已完成”运行卡；记录从顶部对话菜单或消息菜单查看，中断时保留恢复操作，失败时显示错误。

消息使用 swift-markdown 的 CommonMark/GFM 解析，支持标题、段落、强调、链接、引用、列表、代码和表格。每条消息显示时间与复制/分享/更多操作；更多菜单提供“选择文字”，原生 UITextView 支持选词、拖动范围和局部复制。代码块另有复制按钮，长表格与代码可横向滚动。

## 照片、拍摄和文件

加号内可选择照片、拍摄或从系统文件选择器导入。PhotosPicker 仅提供用户选择的照片，不申请整个图库权限；拍摄时申请相机权限。没有相机的设备会明确提示，可改用已有照片。

每条消息最多 4 个附件。支持静态图片、文本/代码/JSON/CSV 和可提取文字的 PDF。源文件上限 20 MiB；图片限制 4000 万像素，导入后缩到最长边 2048 像素、单张最多 2 MiB，并重新编码移除 EXIF 定位等元数据。PDF 最多 100 页；单份文档提取文字最多 60000 UTF-8 字节。扫描 PDF、受密码保护或不支持的文件会报错，不会假装已经读到内容。

附件进入 App 私有存储和持久化对话，原文件 URL 不传给模型。Kit 的 AgentAttachment 与运行时无关；图片真实进入多模态模型请求，文档则以提取出的文字提供。模型需要声明支持图片；发送立即清空附件草稿，本地保存失败才恢复。删除会话同时清理不再引用的私有附件。附件仅在用户按发送后随消息交给所配置的模型服务。

## 本机语音输入

语音使用 Apple Speech 框架的 SFSpeechRecognizer，无需第三方语音 API Key。先检查 supportsOnDeviceRecognition，再设置 requiresOnDeviceRecognition=true；不可用时提示，不回退到云端。[Apple API 文档](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition)

- 点击波形按钮切换语音模式，按住独立区域说话，松开结束；向上拖动进入取消区域，松开取消。VoiceOver 可激活开始、再次激活停止。
- 切换键盘/语音保留文字草稿；输入框长按仍是系统选字/粘贴，不会唤起录音或与放大镜冲突。
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
