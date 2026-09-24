# Track B 最小 PoC · 实现与实测记录

对应 `README.md` 第一阶段："选择一个 App → 授权 → 开始监控 → 打开目标 App → 记录是否检测到 activity"。
范围决策：**免费 Apple 账号，只做 Track B**（Shortcuts / App Intents），Track A 本期不实现。

实测环境：macOS 26.6.2 (25G83) · Xcode 26.4 (17E192) · iOS SDK 26.4 · 模拟器 iPhone 17 / iOS 26.4 (23E244)

---

## 1. 交付物

```
FamilyActivityPoC/
├── FamilyActivityPoC.xcodeproj/project.pbxproj   # 手写；objectVersion 77，file-system-synchronized 组
└── FamilyActivityPoC/
    ├── FamilyActivityPoCApp.swift   # @main；注册通知类别 + delegate
    ├── ContentView.swift            # 两个标签页：待办（绑定管理）/ 日志（触发记录）
    ├── TodoBinding.swift            # **产品核心模型**：App 名 ↔ 待办文本 绑定
    ├── TodoStore.swift              # 绑定的持久化 + 按 App 名查未完成待办
    ├── ActivityLog.swift            # 事件日志模型；source 区分 shortcutIntent / deviceActivity
    ├── ActivityLogStore.swift       # 沙盒 Application Support 持久化（非 App Group）
    ├── POCNotifier.swift            # TodoReminder（本地通知出口）+ TodoNotificationHandler（按钮回调）
    ├── LogAppOpenedIntent.swift     # AppIntent + AppShortcutsProvider
    ├── POCSelfTest.swift            # 无头自检开关（见 2e）
    └── POCTrace.swift               # 取证用事件追踪，带 PID/时间戳（排查 2f 类问题）
```

### 两处相对 `00-feasibility-analysis.md` 初稿的主动偏离

1. **不用 App Group**（初稿 C 节原设计）。Track B 无 extension，Intent 与 UI 同进程同容器，
   不存在跨进程共享需求，App Group 是为"主 App ↔ Extension"引入的。改为直接写沙盒
   `Library/Application Support/activity-log.json`。少一个 capability、少一处签名风险。
2. **新增无头自检开关**（初稿未提）。`--poc-self-test` 启动参数会调用与 Shortcuts 自动化
   **完全相同**的 `LogAppOpenedIntent.perform()`，使"记录是否落盘"可被脚本化验证，
   无需 XCUITest 或辅助功能权限。

---

## 2. 已实测通过（附证据）

| # | 验证项 | 结果 | 证据 |
| --- | --- | --- | --- |
| 1 | 工程可被 `xcodebuild` 解析 | ✅ | `xcodebuild -list` 正确列出 target `FamilyActivityPoC` 与同名 scheme |
| 2 | 编译到 iOS 模拟器 | ✅ | `** BUILD SUCCEEDED **`，**0 error 0 warning** |
| 3 | 自动纳入源文件 | ✅ | file-system-synchronized 组生效：5 个 `.swift` 全部参与编译，未改 pbxproj |
| 4 | 安装到模拟器 | ✅ | `simctl install` → INSTALL OK |
| 5 | 启动运行 | ✅ | `simctl launch` → PID 正常返回 |
| 6 | UI 渲染 | ✅ | 截图确认三步界面完整（授权 / 触发 / 结果） |
| 7 | `perform()` 全链路执行 | ✅ | 自检启动后 `activity-log.json` 生成 |
| 8 | 记录持久化 | ✅ | 见下方 JSON 原文 |
| 9 | UI 实时反映新记录 | ✅ | 截图显示"步骤 3 · 记录结果（**1 条**）"，条目 `SelfTest opened` + 来源标签 + 时间戳 |
| 10 | App Intent 元数据正确 | ✅ | `extract.actionsdata`：`isDiscoverable = true`、`openAppWhenRun = false`、参数 `appName` 齐备 |
| 11 | AppShortcutsProvider 已注册 | ✅ | `autoShortcutProviderMangledName = 17FamilyActivityPoC20POCShortcutsProviderV`，`autoShortcuts` 绑定 `LogAppOpenedIntent` |

### 第 8 项证据：落盘 JSON 原文

```json
[
  {
    "event" : "SelfTest opened",
    "id" : "50ACF798-A886-4B0A-A128-CB6838E894BD",
    "source" : "shortcutIntent",
    "timestamp" : "2026-09-23T14:11:46Z"
  }
]
```

路径：`<app data container>/Library/Application Support/activity-log.json`

### 第 11 项证据：编译进 bundle 的快捷指令短语

```
"autoShortcuts" => [
  0 => {
    "actionIdentifier" => "LogAppOpenedIntent"
    "phraseTemplates" => [
      0 => { "key" => "用 ${applicationName} 记录 App 打开" }
      1 => { "key" => "让 ${applicationName} 记录 App 打开" }
    ]
    "shortTitle" => { "key" => "记录 App 打开" }
    "systemImageName" => "eye.trianglebadge.exclamationmark"
  }
]
```

→ 该 action 具备被系统「快捷指令」发现的条件（`AppShortcutsProvider` 编译产物的直接证据）。

---

## 2b. 真机验证（iPhone 15 Pro / iOS 26.7）

环境：iPhone 15 Pro (iPhone16,1)，iOS 26.7 (23H24)，开发者模式已启用，UDID `<已隐去>`。
免费个人团队 Team ID `NXAY2Q2YH2`（Xcode 自动写入）。

| # | 验证项 | 结果 | 证据 |
| --- | --- | --- | --- |
| 12 | 签名链路 | ✅ | `codesign --verify` 通过；Authority = `Apple Development: <已隐去> (4ACNSTLRZU)`；TeamIdentifier `NXAY2Q2YH2` |
| 13 | 描述文件覆盖本机 | ✅ | `ProvisionedDevices` 含本机 UDID `<已隐去>`；TTL 7 天（免费账号正常值） |
| 14 | 真机构建 | ✅ | `** BUILD SUCCEEDED **`，Profile = `iOS Team Provisioning Profile: com.example.FamilyActivityPoC` |
| 15 | 安装到真机 | ✅ | `devicectl install` → bundleID `com.example.FamilyActivityPoC` |
| 16 | 启动运行 | ✅ | `Launched application with ... bundle identifier` |
| 17 | 设备端 `perform()` 全链路 | ✅ | 带 `--poc-self-test` 启动后，用 `devicectl copy from` 取回 `activity-log.json`，内容见下 |

### 第 17 项证据：从真机取回的日志原文

```json
[
  {
    "event" : "SelfTest opened",
    "id" : "4E0B22C2-0DBD-4B08-9EDB-486A24574814",
    "source" : "shortcutIntent",
    "timestamp" : "2026-09-23T14:49:28Z"
  }
]
```

取回命令：
```bash
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier com.example.FamilyActivityPoC \
  --source "Library/Application Support/activity-log.json" --destination ./device-log.json
```

---

## 2c. ⚠️ 操作坑：VPN 会导致「尚未验证的开发者」且无法通过信任

**现象**：App 装到真机后点图标，弹出「`<Apple ID>` 尚未被验证为受信任的开发者」；
进 设置 → VPN与设备管理 点「信任」**无效**，反复重装、反复信任都无效。

**原因**：iOS 在信任开发者证书时需要联网向 Apple 做证书状态在线校验（OCSP）。
**设备开着 VPN 时该请求被阻断**，证书永远无法通过验证，于是"信任"操作表面上成功、实际不生效。

**解决**：**关掉 iPhone 上的 VPN**，再点图标即可正常验证并打开。

**为什么必须记下来**：免费账号描述文件 **7 天过期**（见 `00-feasibility-analysis.md` B2b），
每次重新 build 安装后都要重新走一次证书验证流程。不知道这个坑的话，
每次重签都会被同一个现象卡住，并误判为签名配置错误。

**诊断要点**：这种情况的特征是「证书、描述文件、设备归属全部正确，但设备端就是不认」。
先用 `codesign --verify` 与描述文件的 `ProvisionedDevices` 排除签名问题，
确认无误后直接查 VPN —— 不要在 Xcode 签名设置里反复折腾。

---

## 2d. 🎯 Track B 端到端验收（第一阶段完成）

**这是整个 PoC 要回答的核心问题**，已在真机走通。

### 验收动作

1. 在 iPhone「快捷指令」→「自动化」建个人自动化：
   触发器 = **App** → 选择**微信** → **「已打开」** → 设为**「立即运行」**
   → 动作 = **「记录 App 打开」** → 「App 名称」填 `微信`
2. 打开微信。

### 验收结果

设备上取回的日志**自动新增一条**（无任何人工交互）：

```json
{
  "event" : "微信 opened",
  "id" : "4CB16E87-C8A4-4006-A2FA-F9048EAA022D",
  "source" : "shortcutIntent",
  "timestamp" : "2026-09-23T14:59:58Z"
}
```

### 对 README 原始问题的回答

> 用户在 iPhone 上打开指定的第三方 App → 我的测试 App 能否检测到这个 App 的 activity
> → 随后能够触发一个测试事件/提醒

**能。** 但必须精确表述其实现方式：

| 问题 | 答案 |
| --- | --- |
| App 自己能监听第三方 App 启动吗？ | ❌ **不能**，iOS 无此公开 API（A0/A1 已核验） |
| 那这次是怎么检测到的？ | ✅ **由系统 Shortcuts 监听**，再调用本 App 的 App Intent |
| 整个过程需要人工干预吗？ | ❌ **不需要**（前提是自动化设为"立即运行"，且参数已填固定值） |
| 免费 Apple 账号够用吗？ | ✅ **够用**，全程无 Screen Time entitlement |

### 验收过程中发现并修复的真实缺陷

**首次实测时自动化弹窗要求输入 App 名字**，破坏了"零交互"前提。

根因：`appName` 参数声明为必填 `String`，Shortcuts 视为必填项，每次触发都询问。
修复：改为 `String?`（Optional），参数变为非必填。

> 注：不能靠在属性声明处写默认值来解决——App Intents 宏会报
> `extra argument 'wrappedValue' in call`。该错误已实际踩到并记录。

修复后元数据确认 `isOptional => true`，再次实测**不再弹窗**，且「App 名称」在自动化中填一次即长期生效。

## 2e. 🎯 最小闭环验收：绑定待办 → 打开 App → 弹出待办

2d 节验收时，横幅弹出的还是 PoC 调试文案（`已记录：微信 被打开`）。
而产品的真实目标是：**打开某个 App 时，横幅提醒与它绑定的待办事项**。本节补上这部分内容。

#### 产品行为定义（用户确认）

| 用户操作 | 期望行为 |
| --- | --- |
| 打开已绑定且**待办中**的 App | 弹出提醒，正文 = 该 App 的待办文本 |
| 点提醒上的**「完成」** | 该待办标记为已完成，**之后打开该 App 不再提醒** |
| 点提醒上的**「稍后再说」** | 待办状态不变，**下次切回该 App 仍会提醒** |

#### 为什么提醒改用本地通知，而不是 Shortcuts 的对话框

因为产品要求两个按钮，而 **Shortcuts 的对话框横幅不支持自定义按钮**
（只有系统给的关闭按钮，这是 `docs/00-feasibility-analysis.md` 里核验过的结论）。
只有 `UNNotificationCategory` + `UNNotificationAction` 能提供「完成 / 稍后再说」。
本地通知不需要任何 entitlement，免费账号可用。

#### 实测证据

三步骤脚本化验证，状态从设备读回（以下是模拟器输出，真机同款）：

| 步骤 | 动作 | 观测到的状态 |
| --- | --- | --- |
| 1 | 打开微信 | 通知送达：`title="打开 微信 时想起" body="给张总回消息" category=TODO_REMINDER` |
| 2 | 点「稍后再说」→ 再次打开微信 | `isDone=false`，**通知数 2 → 3**（再次提醒）✅ |
| 3 | 点「完成」→ 再次打开微信 | `isDone=true`，**通知数停在 3**（不再提醒）✅ |

通知类别注册结果 —— 这是"横幅上有没有那两个按钮"的唯一凭据：

```
CATEGORY TODO_REMINDER ACTIONS: [TODO_ACTION_DONE = "完成"; TODO_ACTION_LATER = "稍后再说"]
```

真机（iPhone 15 Pro / iOS 26.7）同样通过：`--poc-self-test 微信` 后从设备读回的状态里，
新提醒 `打开 微信 时想起 / 给张总回消息` 已送达，类别与按钮同上。

#### 如何在没有 UI 自动化的情况下验证"点按钮"

本机辅助功能权限被拒（`osascript` 报 `-1719`），`simctl` 也不提供触摸注入，
**所以"点按钮"这个动作无法用真实点击来验证**。于是把可验证的部分抽成启动参数（见 `POCSelfTest.swift`）：

```bash
--poc-self-test [App名]                  # Intent 完整链路：记日志 → 查绑定 → 发提醒
--poc-action-test done|later [App名]     # 模拟用户点了「完成」/「稍后再说」
--poc-dump-state                         # 通知类别 / 已送达通知 / 绑定状态 → poc-state.txt
```

这些开关之所以有证据价值，是因为它们调用的是真实路径上的**同一个函数**
（`LogAppOpenedIntent.perform()`、`TodoNotificationHandler.apply()`），
而不是另写一套旁路逻辑 —— 否则"测试通过"推不出"真机点击也正确"。

#### 最终验收：真机手指点击的完整追踪（2026-09-23 23:30~23:33）

前面用 `--poc-action-test` 验证的是"逻辑正确"，但**系统会不会把手指点击投递过来**
是系统行为，脚本无法覆盖。以下是从真机取回的 `poc-trace.log` 原文（截取关键片段），
三次**真实手指点击**，三条路径全部走通：

```
23:30:34  apply action=com.apple.UNNotificationDefaultActionIdentifier   ← 点了横幅本体
          before=微信:pending  after=微信:pending        状态不变（设计如此）

23:32:51  apply action=TODO_ACTION_LATER                 ← 点「稍后再说」
          before=微信:pending  after=微信:pending
23:32:53  perform app="微信" -> 命中待办 "给张总回消息"，发提醒   再次打开仍提醒 ✅

23:33:00  apply action=TODO_ACTION_DONE                  ← 点「完成」
          before=微信:pending  after=微信:done
23:33:02  perform app="微信" -> 无未完成绑定，静默返回           不再提醒 ✅
```

`apply` 是按钮回调 `didReceive` 的第一行代码，它出现了即证明**系统投递链路成立**。
落盘的 `todo-bindings.json` 同步变为 `"isDone" : true`，持久化也对上了。

> 三条路径的分工值得注意：点**横幅本体**（默认动作）与点**「稍后再说」**的效果都是
> "状态不变、下次仍提醒"，但走的是不同 `actionIdentifier`。两者都被显式处理，
> 没有依赖"什么都不做"的默认行为。

### 仍未覆盖

- **触发延迟未量化**：日志记录的是 `perform()` 执行时刻，无法从外部测得"用户点击图标 → 记录落盘"的真实延迟。iOS 侧无对应插桩点。
- **App 重装会打断自动化绑定**：修参数时重装了 App，随后的自动化测试未产生记录；重建自动化后恢复。
  这对免费账号有实际影响——**描述文件 7 天过期，每次重装后可能都要重建自动化**。
  ⚠️ 本次改动（新增待办模型 + 改用本地通知）**同样需要重装 App**，因此自动化很可能又要重建一次。
- ~~通知中心的重复堆积~~ **已于 2026-09-24 修复**：改用稳定的投递标识符，见 5.1。
  提醒规则（每次打开都提醒）未改变，仅通知中心不再堆积。

---

## 2f. ⚠️ 操作坑：专注模式会让通知「静默投递」，看起来像通知没发出来

**现象**：真机上开好自动化后打开目标 App，**屏幕上什么都不弹** —— 没有横幅、没有声音、
没有按钮。但 App 侧一切正常：`deliveredNotifications()` 里有记录、权限 `authorized`、
`alertStyle = banner`、`scheduledDelivery = disabled`。

**原因**：手机开着**专注模式（勿扰 / 睡眠）**。专注模式把通知**静默**投递到通知中心，不弹横幅。
此时通知确实"送达"了，所以只看送达数量会误判成"代码没跑"。

**为什么特别容易误判**：Shortcuts 自动化自己的对话框**不是通知**，不受专注模式影响。
于是会出现「Shortcuts 的横幅看得见、我们 App 的通知看不见」这种极像代码 bug 的现象。

**解决**：把本 App 加入专注模式的允许名单（设置 → 专注模式 → 选模式 → 允许通知 → App），
或先关掉专注模式验证。

**诊断要点**（本次实际走的三条证据链）：

| 观察到 | 结论 |
| --- | --- |
| `deliveredNotifications()` 有记录 | 通知发出去了 → 排除"代码没执行" |
| `UNNotificationSettings.pocSummary` 全部正常 | 排除"权限/样式/定时摘要被改" |
| 以上都正常但仍无横幅 | **去查专注模式**，不要再改代码 |

> 这个坑与 2c 的 VPN 坑同类：**证据链在 App 侧全部自洽，问题在 App 之外。**

---

## 2g. ⚠️ iOS 限制：「完成 / 稍后再说」按钮不会出现在收起的横幅上

**现象**：横幅正常弹出，但只有标题和正文，**看不到两个按钮**，看起来像通知类别没挂上。

**原因**：这是 iOS 通知横幅的固有交互，不是缺陷。**收起的横幅只显示标题与正文**，
操作按钮必须**把横幅向下拉展开**（或**长按**通知）才会出现。
（依据：iOS 通知横幅的标准交互；Apple 文档本次因网络受限无法引用。
**2026-09-23 真机实测确认**：向下拉展开后「完成 / 稍后再说」两个按钮正常出现且功能正常。）

**对产品的实际影响（必须写进结论）**：产品要求的"弹出横幅 + 两个按钮"，
在 iOS 上**做不到"一弹出就看见按钮"**，用户必须多做一步（下拉或长按）。
这是平台约束，换任何实现方式都绕不开。若这一步的摩擦不可接受，
替代形态是：通知只做提醒，用户点击后进入 App 内的待办卡片再操作。

**确认按钮确实已注册的方式**：`--poc-dump-state` 输出的第一行：

```
CATEGORY TODO_REMINDER ACTIONS: [TODO_ACTION_DONE = "完成"; TODO_ACTION_LATER = "稍后再说"]
```

有这一行 = 按钮已挂到通知类别上，剩下的就只是"展开横幅"这一步交互。

---

## 3. 未验证 / 无法在模拟器验证（诚实标注）

| 项 | 状态 | 原因 |
| --- | --- | --- |
| 通知横幅**实际弹出** | ✅ **已验证** | 模拟器截图确认渲染出真实横幅（`打开 微信 时想起 / 给张总回消息`）；真机由 `deliveredNotifications()` 确认送达。⚠️ 首次授权仍需人工点「允许」——`simctl privacy` 不支持 `notifications` 服务，本机辅助功能权限被拒（`-1719`）。 |
| Shortcuts 个人自动化「当 X App 被打开」 | ✅ **已验证** | 见 2d 节，真机实测通过。 |
| 自动化能否"不询问直接运行" | ✅ **已验证** | 设为"立即运行"后打开微信，无任何弹窗即完成记录。 |
| 自动化的触发可靠性 | ✅ **已验证（4 次连续成功）** | 14:59:58 / 15:02:44 / 15:03:01 / 15:04:02 四次打开微信均自动记录，无遗漏。 |
| 触发延迟量化 | ❌ **未验证** | 无外部插桩点，"点击图标 → 落盘"的真实延迟无法测得。 |
| 自动化触发时的画面 | ✅ **已验证（形态已变更）** | 2d 节当时是 Shortcuts 对话框横幅，文案 = `.result(dialog:)` 返回值，只有系统给的关闭按钮。**当前版本已不再使用对话框**，改为本地通知，见 2e 节。 |
| 通知上的「完成」/「稍后再说」按钮**是否注册** | ✅ **已验证** | `--poc-dump-state` 读回通知类别：两个 action 均已挂上，见 2e 节。 |
| 点「完成」后不再提醒 | ✅ **已验证** | 见 2e 节步骤 3：`isDone` 转 true，再次打开该 App 通知数不变。 |
| 点「稍后再说」后再打开仍提醒 | ✅ **已验证** | 见 2e 节步骤 2：`isDone` 保持 false，再次打开该 App 通知数 +1。 |
| **手指真实点击**通知按钮 | ✅ **已验证** | 见 2e 节末：真机三次真实点击，「完成 / 稍后再说 / 点横幅本体」三条路径的 `apply()` 均有追踪记录，状态流转正确。 |
| 专注模式下的静默投递 | ✅ **已定位并解决** | 见 2f 节：通知送达但不弹横幅，根因是专注模式；把 App 加入允许名单后正常。 |
| 收起的横幅上是否直接显示按钮 | ✅ **已确认：不显示** | 见 2g 节：必须下拉展开才会出现按钮，这是平台约束。 |
| 真机安装（签名链路） | ✅ **已验证** | 见 2b 节第 12~16 项。 |
| 设备端证书信任 | ✅ **已解决** | 由 VPN 阻断 OCSP 导致，关闭 VPN 后正常，详见 2c 节。 |

> **结论边界**：Track B 的**前提**（系统 Shortcuts 能在目标 App 被打开时调起这个 Intent）
> 已在 2d 节真机验证通过；产品的**最小闭环**（绑定待办 → 打开 App → 弹出待办 →
> 点「完成」不再提醒 / 点「稍后再说」仍提醒）已在 2e 节端到端验证，
> 其中"手指点击能否被系统投递到 App"这一段也已用真机追踪日志证实。
>
> **本阶段的核心问题已经答完**：产品设想的交互在 iOS 上**能实现，且免费账号即可**。
> 剩下的是体验层面的取舍与工程化，见 2g 节末尾与第 5 节。

---

## 4. 复现方式

```bash
cd FamilyActivityPoC

# 构建
xcodebuild -project FamilyActivityPoC.xcodeproj -scheme FamilyActivityPoC \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/fapoc-dd build

# 安装
DEV=$(xcrun simctl list devices booted | grep -o "[0-9A-F-]\{36\}" | head -1)
APP=/tmp/fapoc-dd/Build/Products/Debug-iphonesimulator/FamilyActivityPoC.app
xcrun simctl install $DEV $APP

# 预置一条绑定（正常流程是在 App 的「待办」页里手填，脚本化验证时直接写文件）
SUPPORT="$(xcrun simctl get_app_container $DEV com.example.FamilyActivityPoC data)/Library/Application Support"
cat > "$SUPPORT/todo-bindings.json" <<'JSON'
[ { "id":"11111111-1111-1111-1111-111111111111", "appName":"微信",
    "todoText":"给张总回消息", "isDone":false, "createdAt":"2026-09-23T10:00:00Z" } ]
JSON

# 触发（每条命令前先 terminate，因为自检开关跑在 App.init() 里）
xcrun simctl terminate $DEV com.example.FamilyActivityPoC 2>/dev/null
xcrun simctl launch $DEV com.example.FamilyActivityPoC --poc-self-test 微信     # 应弹提醒
xcrun simctl terminate $DEV com.example.FamilyActivityPoC 2>/dev/null
xcrun simctl launch $DEV com.example.FamilyActivityPoC --poc-action-test done 微信  # 模拟点「完成」
xcrun simctl terminate $DEV com.example.FamilyActivityPoC 2>/dev/null
xcrun simctl launch $DEV com.example.FamilyActivityPoC --poc-dump-state        # 落状态文件

# 查看结果
cat "$SUPPORT/poc-state.txt"
```

真机同理，把 `simctl` 换成 `devicectl`（`device install app` / `device process launch` /
`device copy from`），UDID 用 `xcrun devicectl list devices` 查。

> 工具链指向问题已解决（`sudo xcode-select -s /Applications/Xcode.app` 已执行），
> 不再需要 `DEVELOPER_DIR` 绕行。

---

## 5. 下一步

**第一阶段的验收已经全部走通**（2d 证明"打开即触发"成立，2e 证明产品最小闭环成立，
含真机手指点击的投递链路）。剩下的不再是"能不能做到"，而是**产品取舍与工程化**。

### 5.1 已确认的产品决策（2026-09-24）

| # | 议题 | 决策 | 理由 |
| --- | --- | --- | --- |
| 1 | 提醒频率 | **保持"未完成则每次打开都提醒"** | 这是产品语义本身：「稍后再说」的含义就是"下次还提醒"。曾评估过"每天只提醒一次"，与语义冲突，**已否决** |
| 2 | 按钮需下拉横幅 | **接受，维持现状** | 已确认为 iOS 平台约束（见 2g），非实现问题，绕不开 |
| 3 | 提醒文案 | **维持「打开 X 时想起」** | 暂可接受，后续如需再改 |

> **通知堆积已修复（2026-09-24）**
>
> 按决策 1 实现后，通知中心会随打开次数累积同一条待办的重复通知（实测 16 条）。
> 根因是每条提醒都用 `UUID().uuidString` 作 `UNNotificationRequest.identifier`，
> 于是每次都是"新建通知"而非"覆盖旧通知"。
>
> **修法**：改用待办自身的 `id` 作标识符 —— iOS 的规则是 identifier 相同则覆盖。
> **横幅行为完全不变**（仍是每次打开都弹），只是通知中心只保留最新一条。
>
> 实测证据（模拟器，连续触发 6 次）：
>
> ```
> 送达总数            4      ← 3 条是改动前用随机 ID 堆下的旧通知，第 4 条被反复替换
> trace 里 post ok    6 次   ← 每次打开都真的发了提醒，产品的提醒规则未被削弱
> ```
>
> 两个数字合起来才说明问题：**只 +1 证明去重生效，post ok 有 6 次证明提醒照常发**。

### 5.2 工程上仍然存在的限制

- **免费账号描述文件 7 天过期**：届时需重新 build 安装（见 `00-feasibility-analysis.md` B2b）；
  **重装后自动化绑定大概率要重建**，这是当前形态下最影响日常使用的一条。
- **触发延迟未量化**：无外部插桩点，只能靠 `poc-trace.log` 的时间戳粗略观察。
- **取证工具仍在包里**：`POCTrace` / `POCSelfTest` 是为排查而加的，不参与产品逻辑，
  进入产品化阶段应移除或 `#if DEBUG` 包起来。

### 5.3 交付物边界（回答 README 需求 3、6）

| 问题 | 结论 |
| --- | --- |
| API 能做到什么 | 检测"某 App 被打开"只能靠 Shortcuts 自动化；**App 自身无公开 API 监听第三方 App 启动** |
| 免费账号能做到什么 | 上述全链路**已验证可用**，含带两个按钮的本地通知 |
| 付费账号才有的 | Screen Time 系（FamilyControls / DeviceActivity / ManagedSettings）的 entitlement；本项目未使用 |
| 上架 App Store 还需要什么 | 本地通知无需额外 entitlement；但**要求用户手动建 Shortcuts 自动化**这一点，是产品化时最大的体验障碍 |

> 更完整的可行性边界见 `00-feasibility-analysis.md`。
