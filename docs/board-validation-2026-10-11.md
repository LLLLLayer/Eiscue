# Wi-Fi 开发板真机验证增量记录

日期：2026-10-11。目标为用户指定的 iPhone 14 Pro 与已通过 ROM 确认的
ESP32-C3 / 8 MB 开发板。此前固件备份、刷写、AP 启动和 App 构建安装
结果见 [验证记录](validation.md)；本页补充后续无线连接、授权及控制回归的实际观察。

**最新完整动作闭环通过：无线连接、截图、点击、180° 旋转旧帧拒绝及新帧点击、
滑动、Unicode 输入、Home、启动 App，以及断开后第二次连接、截图和点击。**
结果仅覆盖本次指定测试机与流程，长时后台、蜂窝模型联网及公司 VPN 共存仍未验收。
首次扫码加入失败的原因没有证据支持，不能把后续重试成功写成某个确定缺陷已修复。

## 本次过程与证据

| 步骤 | 观察及边界 |
|---|---|
| 首次扫码 | 用户反馈 iPhone 无法加入开发板网络；没有取得能定位首次失败原因的诊断证据 |
| 配置核对 | 使用 Apple Vision 解码实际二维码，结果与本机 `wifi-qr.txt` 和私有 Wi-Fi 配置 CSV 一致；字段为 ASCII，没有发现转义或二维码内容不一致。未公开 SSID、密码或二维码载荷 |
| 重启后重试 | 按官方方式 hard reset 开发板后，用户使用同一二维码重试并回复“加上了”；这不证明重置解决了某个已定位的软件问题 |
| 关联事件 | 串口采集记录启动后 **168.882 秒**出现一次 station join |
| DHCP 事件 | 启动后 **170.112 秒**记录一次租约分配，确认为预期地址 **192.168.7.2** |
| 采集窗口内状态 | `join_count = 1`、`leave_count = 0`、`lease_assignment_count = 1`、`error_count = 0`，AP ready；这只描述本次有限采集窗口，不代表长期稳定性 |

关联和租约证据来自受保护的本地文件：

- `.build/passport-relay-firmware/association-join-failure.log`：原始串口日志。
- `.build/passport-relay-firmware/association-join-failure.summary.json`：脱敏事件摘要，记录上述时间、计数及预期 `.2` 地址匹配。

上述早期采集已自动结束。该次加入重试未修改 PMF 或 DHCP 配置；现有记录不足以
将首次失败归因于 PMF、密码、DHCP 或手机系统。
原始日志、Wi-Fi 配置、密码及二维码仍只保留在本机，不作为仓库附件。

## App 到开发板通信与服务发现

指定 iPhone 14 Pro 上的 App 已实际通过开发板 Wi-Fi 发送 `STATUS`，收到
ND1 `layer = ncm`、`result = diagnostic-only`。这证明 App 与开发板之间的
诊断 TCP 通信，回复本身不授予设备控制能力。

首次控制验证的服务发现失败。后续诊断查询中，第一轮 `DISCOVER6` 和随后的
`DISCOVER4` 都明确返回 `no-candidates`；十余秒后再次进行正式服务发现时，
`candidatePresent = true`。两者之间没有重启或重刷开发板。这说明本次服务发现
存在时序不稳定现象，尚不能确定其根因为手机广播时机、组播传输或其他因素。

源码检查同时发现 Swift 把 mDNS 查询的网络 family 与返回端点 family 绑定，
可能忽略跨 family 的合法候选；现已按端点实际 family 选择，并在没有服务时最多
增加一轮有界查询。此缺陷不能解释已经明确返回 `no-candidates` 的那两次结果。
固件每 900 ms 重发 PTR 查询的改进现已通过交叉编译并刷入实板。后续 **600 秒**
采集中，6 次发现均返回 `status = 0`，查询次数为 27 或 33，每次均解析到
PTR、SRV、A、AAAA；窗口内 `join = 1`、`DHCP = 1`、`leave = 0`、
`panic_or_error = 0`，租约为预期 `.2`。证据为
`.build/passport-relay-firmware/discovery-firmware-live.summary.json`。
这是有限窗口的运行与发现证据，不代表长期稳定性；也不能把改版前的偶发成功归功于它。

## 无线授权、几何修复与实际动作

用于无线验证的 Debug App 已安装到指定测试机。用户明确能够处理手机上的系统
自动化密码授权后，后续实测已通过无线服务连接，并收到 XCTest `enabled = 1`
及 `ready`。系统密码仍由用户直接在手机上处理，不交给 App、Agent 或聊天。

早期检查曾在首帧返回 `staleFrame`。控制台显示截图前后
`beforeRevision = afterRevision = 2`、`orientation = 1`、`scale = 3`，屏幕
来源返回的 bounds 为 `1179 × 2556`，PNG 也是 `1179 × 2556`。桥接层误把
像素 bounds 当作 points，再乘 scale，导致尺寸核对失败；该次错误不能被描述为
真机已经发生旋转或旧帧正确失效。

修复在 `finishGeometry` 中先除以 scale 归一化，头文件明确单位为 points。
最新 **220 项 Objective-C fixture 检查通过**；Debug 构建通过。早期动作报告
`/tmp/eiscue-wireless-coordinate-check-result.json` 已通过点击、旋转、滑动和
Unicode 输入，但最后因输入后的 Debug 本地界面几何变化，在纯截图阶段失败；
其 `state = failed`、`failedPhase = text` 保留为历史，不能计作整轮通过。

修复 Debug helper 后，最新报告 `/tmp/eiscue-wireless-final-check-result.json`
明确为 **`state = passed`、`phase = finished`**：

| 检查 | 真实结果 |
|---|---|
| 连接路径 | `wirelessBoard`，`connected_1/2 = true`；开始及两次连接时本地 VPN 均未连接，选择保持 |
| 截图 | 合法 PNG，`1179 × 2556` |
| 点击与截图 | `tapVerified_1/2 = true`，两轮各自点击后截图均通过 |
| 180° 旋转 | 横屏尺寸 `2556 × 1179`；转向前旧帧被拒绝且无效果，新帧点击验证通过；原方向恢复 |
| 滑动 | `swipeVerified = true` |
| 文本输入 | `unicodeTextVerified = true`，验证文字为 `你好，Eiscue 🧊` |
| Home 与启动 App | `homeVerified = true`、`launchVerified = true` |
| 断开与重连 | `locallyDisconnected_1/2 = true`；第一次本地断开后第二次连接、截图、点击和后续截图完成 |

两次断开记录证明本地会话关闭，**不是远端 daemon 释放 ACK**；Home 的短暂
前后台切换也不证明长时后台稳定运行。蜂窝模型联网及公司 VPN 共存仍未验收。
Home 与文本输入的生产能力限制现已移除。更新后的签名 Release 完整构建通过
（17.545 秒），`codesign --verify --deep --strict` 返回 0；已覆盖安装到指定
iPhone 14 Pro，空启动参数进入正常 RootView，后续进程检查确认仍在运行。
安装和启动报告均为 `success`，没有自动运行 Debug 检查。

最终交付证据：`/tmp/eiscue-wireless-verified-release-build.log`、
`/tmp/eiscue-wireless-verified-release-install.json`、
`/tmp/eiscue-wireless-verified-release-launch.json`。上述动作闭环报告与普通 Release
构建、签名、安装、启动证据分开记录，不将安装成功扩大为未执行的网络或后台验收。
