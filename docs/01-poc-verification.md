# Track B 最小 PoC · 实现与实测记录

对应原始需求第一阶段（`docs/02-original-brief.md`）："选择一个 App → 授权 → 开始监控 → 打开目标 App → 记录是否检测到 activity"。
范围决策：**免费 Apple 账号，只做 Track B**（Shortcuts / App Intents），Track A 本期不实现。

实测环境：macOS 26.6.2 (25G83) · Xcode 26.4 (17E192) · iOS SDK 26.4 · 模拟器 iPhone 17 / iOS 26.4 (23E244)

---

## 1. 交付物

```
FamilyActivityPoC/
├── FamilyActivityPoC.xcodeproj/project.pbxproj   # 手写；objectVersion 77，file-system-synchronized 组
└── FamilyActivityPoC/
    ├── FamilyActivityPoCApp.swift   # @main；注册通知类别 + delegate
    ├── ContentView.swift            # 两个标签页：待办（绑定管理）/ 日志（触发记录 + 检测到的 App）
    ├── SetupGuideView.swift         # v2：接线指引 sheet（四步＋「运行前询问」警告＋排查清单）
    ├── AppPickerSheet.swift         # v2：选择 App sheet（多选、已占用置灰）
    ├── AppChipsView.swift           # v2：绑定芯片 + 自写的换行 Layout
    ├── TodoBinding.swift            # **产品核心模型**：App 名集合 ↔ 待办文本 绑定（含 v1 迁移）
    ├── TodoStore.swift              # 绑定的持久化 + 查未完成待办 + 「一个 App 只属于一条待办」不变量
    ├── SeenApp.swift                # v2：见过的 App（系统上报过哪些名字）
    ├── SeenAppStore.swift           # v2：上者的持久化 + 上限 + 淘汰 + 自识别本 App
    ├── ActivityLog.swift            # 事件日志模型；source 区分 shortcutIntent / deviceActivity
    ├── ActivityLogStore.swift       # 沙盒 Application Support 持久化（非 App Group）
    ├── TodoReminder.swift           # TodoReminder（本地通知出口）+ TodoNotificationHandler（按钮回调）
    ├── LogAppOpenedIntent.swift     # AppIntent + AppShortcutsProvider
    ├── POCSelfTest.swift            # 无头自检开关（见 2e / 2h）
    └── POCTrace.swift               # 取证用事件追踪，带 PID/时间戳（排查 2f 类问题）
```

### 三处相对 `00-feasibility-analysis.md` 初稿的主动偏离

1. **不用 App Group**（初稿 C 节原设计）。Track B 无 extension，Intent 与 UI 同进程同容器，
   不存在跨进程共享需求，App Group 是为"主 App ↔ Extension"引入的。改为直接写沙盒
   `Library/Application Support/activity-log.json`。少一个 capability、少一处签名风险。
2. **新增无头自检开关**（初稿未提）。`--poc-self-test` 启动参数会调用与 Shortcuts 自动化
   **完全相同**的 `LogAppOpenedIntent.perform()`，使"记录是否落盘"可被脚本化验证，
   无需 XCUITest 或辅助功能权限。
3. **v2 起 App 名由系统上报，不再手输**（初稿假设用户填 App 名）。
   代价是多了一个 `SeenAppStore`（记录系统上报过的名字），换来的是消灭
   "本 App 与自动化两处拼写必须一致"这一类静默失败。见 2h。

---

## 2. 已实测通过（附证据）

| # | 验证项 | 结果 | 证据 |
| --- | --- | --- | --- |
| 1 | 工程可被 `xcodebuild` 解析 | ✅ | `xcodebuild -list` 正确列出 target `FamilyActivityPoC` 与同名 scheme |
| 2 | 编译到 iOS 模拟器 | ✅ | `** BUILD SUCCEEDED **`，**0 error 0 warning** |
| 3 | 自动纳入源文件 | ✅ | file-system-synchronized 组生效：10 个 `.swift` 全部参与编译，未改 pbxproj（新增文件时验证通过；后改名 `POCNotifier.swift` → `TodoReminder.swift` 同样无需改 pbxproj） |
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
      0 => { "key" => "用 ${applicationName} 检查待办" }
      1 => { "key" => "让 ${applicationName} 检查待办" }
    ]
    "shortTitle" => { "key" => "检查待办并提醒" }
    "systemImageName" => "checklist"
  }
]
```

> 这三处文案是产品化改名后的现值（原名 `记录 App 打开`，动作只记日志；现在会发提醒）。
> 从当前构建产物 `FamilyActivityPoC.app/Metadata.appintents/extract.actionsdata` 重新提取。
> **注意 `actionIdentifier` 仍是 `LogAppOpenedIntent`** —— 它是 Shortcuts 自动化的绑定键，
> 改类型名会让手机上已建的自动化失效，故保留（见第 5 节）。

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

### 对原始需求问题的回答

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

#### 补充验收：待办结束后，残留的通知会被撤掉（2026-09-24）

上面三条路径里，只有**点通知上的「完成」按钮**会让系统顺手消掉那条通知。
另外两条路径系统不管，会在通知中心留下一条"已经做完的待办"：

- 在 App 界面里左滑标记完成
- 直接删除绑定

修法是在 `TodoStore` 里统一加 `cancelReminder`（而不是让每个调用点自己记得），
调 `TodoReminder.cancel(identifier:)` → `removeDeliveredNotifications(withIdentifiers:)`。

**这里有个容易写错的地方**：`removeDeliveredNotifications` 撤的是**已送达**的通知，
`removePendingNotificationRequests` 撤的是**尚未送达**的。本项目用 `trigger: nil`
立即送达，通知属于前者 —— **写成后者会静默失效，什么都不报**。
所以这一条必须实测，不能只看编译通过：

| 步骤 | 动作 | `DELIVERED NOTIFICATIONS` |
| --- | --- | --- |
| 1 | 触发一次提醒 | **1**（`title="打开 微信 时想起" category=TODO_REMINDER`） |
| 2 | 走 `apply` → `markDone` → `cancel` | — |
| 3 | 重新读回状态 | **0** ✅ |

步骤 2 是无头调用，系统并没有"用户点了通知"这件事，所以**送达数归零只可能是
我们那次 `cancel()` 干的** —— 这条证据能成立，靠的正是它不经过系统路径。

> 复现时的一个坑：`simctl uninstall` 会**重置通知权限**（`auth=notDetermined`），
> 而无头启动弹不出授权框，`requestAuthorization` 会一直等下去，
> 后续 `post()` 根本不执行（追踪日志里连 `post` 行都没有）。
> 本地验证时用**临时**加上 `.provisional` 选项绕过（无需弹窗、静默送达即可，
> 撤销通知不依赖横幅），验完立即改回 `[.alert, .sound, .badge]`。

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

## 2h. v2 证据：集合化绑定、接线检测、以及三个真 bug

v2 把"每绑一个 App 建一条自动化"压成"只建一条"，App 名改为从系统上报的列表里选。
改动面覆盖数据模型（`appName` → `appNames`）、三个 store、通知解析路径与界面。
**迁移写错的后果是"用户所有绑定静默消失"**，所以下面每一条都在模拟器上实跑过。
除注明外，均为 iPhone 17 / iPhone 17 Pro Max 模拟器。

### 数据迁移（`--poc-migration-test` ＋ 真容器实跑）

没有测试 target（工程只有 app target），所以把 fixture 过**真实的解码器**，
结果写进 `poc-state.txt`。7 个 fixture 全对，关键两条：

| fixture | 期望 | 结果 |
| --- | --- | --- |
| 一条坏记录**夹在两条好的中间**（`isDone` 写成字符串） | 好的两条保住，坏的单独丢 | ✅ `解出 2 条，丢掉 1 条` |
| 整个文件不是 JSON | 整体失败 → 兜底 `[]`（数据全丢，这条**必须**能区分出来） | ✅ 明确输出"整体解码失败" |

第一条**实测确认了一个本来只是假设的行为**：`[LenientElement<T>]` 里 `try?` 失败后，
JSON 解码器的游标**能恢复到数组的下一元素**（否则坏的后面那条也会跟着丢）。
没有测试 target 的情况下，这个行为只能靠实跑确认，不能想当然。

真容器实跑（把 v1 形状的 `todo-bindings.json` 写进去 → `--poc-dump-state`）：
`appName:"微信"` → `appNames:["微信"]`；`"  QQ  "` → `["QQ"]`；畸形记录被单独丢掉，
其余两条完好；追踪日志出现 `load dropped 1 malformed binding(s)`；
**读完之后磁盘上的文件立刻被改写成规范的 v2 形状**（只写 `appNames`，不再写 `appName`）。

> 这里踩过一个自己的坑：清洗后只在 `sanitizeInvariant()` 返回 true 时才 `save()`，
> 结果"迁移读对了但没落盘"。修法是比较**文件原始字节**与重新编码后的字节
> （拿已经洗过的内存值自己跟自己比永远相等）。三个 store 都有这个问题，一起改了。

### `auth=notDetermined` 时必须"不发提醒且不挂起"（本版最重要的一条回归）

**这是 v2 之前就存在的真 bug**，只是在旧形态下很少撞上。

`LogAppOpenedIntent.perform()` 发货前会 `await TodoReminder.requestAuthorization()`。
App 被 Shortcuts 在**后台**拉起时弹不出授权框，这个 await **永远不返回**（见 2e），
`post()` 根本执行不到。以前只有命中绑定时才会走到；v2 改成"触发器勾选全部 App"后
**每次切换 App 都会走到**，而免费账号 7 天重签让"重装"成为常态（重装会把权限打回未决定），
于是症状变成"打开什么 App 都毫无反应"—— 正是这个功能要消灭的东西。

改法：intent 路径只**查**不**问**（`canDeliver()`），未授权时只记追踪日志；
`requestAuthorization()` 只保留在界面路径上调用。

| 步骤（卸载重装后 `auth=notDetermined`） | 结果 |
| --- | --- |
| `--poc-self-test 企业微信`（该 App 有未完成待办） | ✅ 追踪日志 `perform app="企业微信" -> 命中待办但通知不可用(auth=0)，不发提醒` |
| 4 秒后进程是否还在 | ✅ 还在 —— **没有挂死**（改之前会永久挂在这里） |
| `DELIVERED NOTIFICATIONS` | ✅ `0` |
| `SEEN APPS` | ✅ 非空 —— 接线检测**不依赖通知权限**，这一点很重要（否则未授权时接线警告会误报成"没接通"） |

`--poc-grant-notifications` / 选项里的 `.provisional` 是验证期间临时加的入口，
**已全部删除**，仓库里 `grep -rn "TEMP-VERIFY\|--poc-grant-notifications"` 为 0 命中。
`.provisional` 也不该留在产品里：临时授权是**静默投递**（只进通知中心、不弹横幅），
而横幅正是这个功能的全部 —— 用户按了授权却什么都看不到，比明确未授权更难查。

### 多 App 绑定 ＋ 通知去重

| 操作 | 结果 |
| --- | --- |
| 一条待办绑 `["微信","QQ"]`，先后触发微信、QQ | ✅ 两次都发文，`DELIVERED` 始终是 **1**（identifier 是待办 id，后一次覆盖前一次） |
| 横幅标题 | ✅ `打开 QQ 时想起` —— 是**本次触发的那个 App**，不是数组里的第一个 |
| `userInfo` | ✅ 同时带 `appName` 与 `bindingID` |
| `--poc-action-test done 微信 <绑定id>` | ✅ `resolvedBy=id`，送达数 → 0 |
| 随后打开 QQ | ✅ `无未完成绑定，静默返回` —— 同一条待办的另一个 App 也不再提醒（决策 3 的既定后果） |
| `--poc-action-test done 微信`（不传 id） | ✅ `resolvedBy=name` —— v1 老通知的回退路径仍然可用 |

### 「一个 App 只属于一条待办」不变量

两个执行点都验了。**加载时**：两条绑定都声称微信 → 后一条的微信被摘掉并留痕
`sanitize dropped [微信] from todo BBBB0000-…`。**写入时**（`--poc-claim-test`，走真实 store API，
用独立临时文件，不碰真实数据）6 步全部符合设计，其中三步是重点：

- 新建 B 声称微信 → 微信**从 A 手里被摘走**（后写覆盖）
- 把 B 标记完成 → 它不再占着微信，A 可以拿走
- 把 B 恢复待办 → 它把微信抢回来，而 A 被摘空后**仍然存在**（显示橙色「未选择 App（不会提醒）」），
  **绝不静默删除用户的待办**

### 封顶与截断（"触发器全选"之后这不再是理论问题）

| 项 | 上限 | 实测 |
| --- | --- | --- |
| `ActivityLogStore` | 300 | ✅ 连打 400 次触发后恰好 300 |
| `SeenAppStore` | 200 | ✅ 恰好 200 |
| `POCTrace` | ~64 KB 文件 | ✅ 再打 1500 次后超过上限，截断生效：保留最新一半、首行不是残行（`App986`，文件 47274 字节，首字节 `[`） |

三处的 `load` 路径也各截一次 —— 只在上限加入写入路径的话，改动之前留下的老文件永远瘦不回去。

### 界面（**只有截图，没有真实点击**）

本机没有触摸注入（`simctl` 不提供，辅助功能权限被拒 `-1719`），所以两个 sheet
是加**临时启动参数**弹出来截的图，参数已删除。**"点击能打开 sheet"这件事本身没有验证过。**

| 截图 | 确认了什么 |
| --- | --- |
| 待办页（未接线） | 橙色「接线还没通 —— 点这里看步骤」横幅 ＋ 两种成因的脚注；`appNames == []` 的绑定渲染成橙色「未选择 App（不会提醒）」；已接线的变体顶部换成普通「自动化接线指引」 |
| 待办页（已接线） | 脚注变成「已检测到 N 个 App」，且 **N 不含本 App 自己**（9 条记录 → 显示 8），自过滤生效 |
| 芯片换行 | 8 个长名字的绑定分成两行（5 + 3），左对齐 —— 自写的 `AppChipFlow: Layout` 正确换行 |
| 接线指引 sheet | 四步 ＋ ⚠️「运行前询问」必须关掉 ＋ 排查清单标题。⚠️ **排查清单的正文在屏幕外，没有截图确认** |
| 选择 App sheet | 被占用的 5 项置灰并标「已被「回客户消息」占用」，空闲的 3 项可选；本 App 自己不出现在列表里 |

### 一个只有截图才能发现的真 bug：日期渲染成英文

选择器里显示 **「共 7 次 · 最近 52 minutes ago」** —— 中英混排。

原因不在 `Date.RelativeFormatStyle` 的用法，而在**本 App 没有任何本地化**：
`Bundle.main` 未声明 `CFBundleLocalizations`，工程里也没有一处 `.strings`
（界面文案全是中文字面量）。这种情况下 `Locale.current` 会落到**开发区域**，
于是即使手机语言是中文也拿不到中文日期。

**没有当成"模拟器的错觉"放过去**：把模拟器语言切成简体中文
（`defaults write -g AppleLanguages -array zh-Hans` ＋ 重启）后重装重跑，**日期照样是英文**。

改法是在 `POCFormat` 里把语系写死成 `zh_Hans_CN`。验证方式不是再截一张图
（临时开关已经删了，不为看一眼格式再挂回去），而是让 `--poc-dump-state` 顺手把它打印出来：

```
LOCALE: current=en_CN relative="52分钟前" time="20:01:16"
```

`current` 是**不写死语系时会用的那个值**，与右边固定中文的输出并列 —— 一眼能判该不该跟随系统。
左边那个 `en_CN` 正是 bug 的根：语言部分是 `en`，区域部分才是 `CN`。

### 2h 补记：真机上跑出来的两个缺陷（2026-09-24 用户反馈）

v2 的验证全在模拟器上，**没有触摸注入**，所以下面这两类问题一条都测不出来。
用户装到 iPhone 上第一次走接线流程，两个都撞上了。

**1. 指引漏了最后一步："打开一个 App 才算接通"。** 用户建完自动化回来看列表，是空的，
于是问"是不是要先运行一遍"。实际上：这条自动化是**被动**的，只在"某个 App 被打开"
那一刻触发；而且「检测到的 App」唯一的来源就是这种触发，所以刚建完必然是空的。
更糟的是，他很自然地去「快捷指令」里点了那个 ▶️ 运行按钮 —— **那样反而拿不到 App 名**
（那一刻没有"当前 App"），列表照样是空的。原来的措辞只出现在**排查清单**里，
不在主流程上，等于要用户先失败一次才会读到。

改法：`SetupGuideView` 的四步变**五步**，第 5 步就叫「回到桌面，打开一个 App 试试」，
并把"点运行按钮不算"单独拎出来。README 的快速开始同样补上。

**2. 待办输入框的键盘收不起来。** 这是个 `axis: .vertical` 的多行输入框：
**回车是换行不是提交**（`onSubmit` 不会触发），List 里点空白处也不收键盘 ——
等于用户输完字之后**没有任何退路**，`添加待办` 按钮还可能被键盘挡住。

改法：加 `@FocusState`，键盘正上方挂一个「完成」按钮（`ToolbarItemGroup(placement: .keyboard)`），
`List` 加 `.scrollDismissesKeyboard(.interactively)` 作为第二条出口，
并在点「选择 App」和「添加待办」时主动清焦点。

**这一条我没法自己验证** —— 键盘行为必须靠真实点击，本机做不了。改的是标准写法，
但要由用户在真机上确认。**下面「没有验证的」一节因此又多了一条。**

### 本次**没有**验证的（不许当成已验证）

- **真实触摸交互**：点行打开选择器、点「完成」提交、左滑删除/标记完成、切标签页 —— 全部没验。
- **键盘行为**：收键盘的「完成」按钮、下滑收键盘（见上面 2h 补记第 2 条）—— 同样只能真机确认。
- **真机**：v2 的所有验证都在模拟器上。真机侧需要重做的见 2b 与本节末尾的清单。
- **接线指引 sheet 里排查清单的正文**：在屏幕外，只有标题可见。
- **「触发器勾选全部 App」这个前提**：见 `docs/03` 第 4 节的开放项 ——
  当初真机验的是**勾 2 个 App**，不是勾全部。**这是 v2 最大的开放项。**

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
| **v2 的模拟器验证** | ✅ **已验证** | 见 2h 节：数据迁移、不变量、封顶、`auth=notDetermined` 回归、界面截图。 |
| **v2 改动后的真机手指点击** | ⏳ **需要重验** | 上面那条"手指真实点击"发生在 **v2 之前**，当时通知里只带 App 名。现在优先按 `bindingID` 解析，**解析路径换了一条，旧证据不能沿用**。 |
| **触发器勾选全部 App** | ⏳ **未验证** | 当初真机验的是勾 **2 个** App；v2 的前提是勾全部。见 `docs/03` 第 4 节。 |
| **v2 改动的真机端到端** | ⏳ **需要重验** | v2 的验证全在模拟器上。真机至少要过一遍：重建那条全选自动化、打开 3~5 个 App 看检测列表、重装后重授权再触发一次。 |

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

# 预置一条绑定（正常流程是在 App 的「待办」页里点选，脚本化验证时直接写文件）
SUPPORT="$(xcrun simctl get_app_container $DEV com.example.FamilyActivityPoC data)/Library/Application Support"
cat > "$SUPPORT/todo-bindings.json" <<'JSON'
[ { "id":"11111111-1111-1111-1111-111111111111", "appNames":["微信"],
    "todoText":"给张总回消息", "isDone":false, "createdAt":"2026-09-23T10:00:00Z" } ]
JSON

# 触发（每条命令前**必须**先 terminate，见下方两个坑）
xcrun simctl terminate $DEV com.example.FamilyActivityPoC 2>/dev/null
xcrun simctl launch $DEV com.example.FamilyActivityPoC --poc-self-test 微信     # 应弹提醒
xcrun simctl terminate $DEV com.example.FamilyActivityPoC 2>/dev/null
xcrun simctl launch $DEV com.example.FamilyActivityPoC --poc-action-test done 微信  # 模拟点「完成」
xcrun simctl terminate $DEV com.example.FamilyActivityPoC 2>/dev/null
xcrun simctl launch $DEV com.example.FamilyActivityPoC --poc-dump-state        # 落状态文件

# 查看结果
cat "$SUPPORT/poc-state.txt"
```

**三个消耗过真实时间的坑，写下来省下一次：**

1. **`simctl launch` 对已经在跑的 App 不会带新参数重新拉起** —— 它只是把那个进程切到前台，
   **参数被静默忽略**，然后你看到"什么都没发生"，很容易误判成代码有问题。
   上面每条命令前的 `terminate` 不是保险，是必需的。
2. **装之前先看产物的时间戳**，别假设 `xcodebuild` 一定刷新了
   `Build/Products/*/FamilyActivityPoC.app`。曾经出现过产物是**隔天**的旧包、
   `simctl install` 老老实实把它装进模拟器，于是截图里跑的是**上一代的界面**。
   装之前 `stat -f '%Sm size=%z' <产物>/FamilyActivityPoC`，装之后再 `stat` 一次设备上的那份，两边一致才往下走。
3. 顺带：**`simctl install` 会把数据容器换一个 UUID**。所有路径都要用
   `get_app_container` **现取**，不能缓存。

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
>
> **残留通知也已修复（同日）**：去重解决的是"反复提醒堆很多条"，还剩一个反向问题 ——
> 在 App 界面里标记完成/删除绑定时，那条已经没意义的通知会**留在通知中心**（只有点通知上的
> 「完成」按钮系统才会顺手消掉）。修法是在 `TodoStore` 里统一撤销，实测送达数 1 → 0。
> 详见 2e 末尾「补充验收」。

### 5.1b v2 的产品决策（2026-09-24）

| # | 议题 | 决策 | 影响 |
| --- | --- | --- | --- |
| 1 | 触发器勾哪些 App | **全选**，约束放在本 App 里 | intent 每次切 App 都跑，未命中必须绝对静默 |
| 2 | App 名怎么来 | **只能从检测列表选**，彻底去掉手输 | 消灭"两处拼写必须一致"这个静默失败类别 |
| 3 | 一条待办绑几个 App | **可以绑多个**（如「回消息」绑微信＋企业微信） | 数据模型 1:N；在其中一个里点「完成」，别的也不提醒（用户已明确接受） |
| 4 | 一个 App 能属于几条待办 | **只能一条** | 否则两条同时命中会重复提醒。后写覆盖，被摘空的待办**保留**并显橙色提示，绝不静默删除 |

### 5.2 工程上仍然存在的限制

- **免费账号描述文件 7 天过期**：届时需重新 build 安装（见 `00-feasibility-analysis.md` B2b）；
  **重装后自动化绑定大概率要重建**，这是当前形态下最影响日常使用的一条。
  重装还会把通知权限打回 `notDetermined`，此时打开目标 App 完全没反应（v2 已保证它至少不再挂死，
  见 2h），需要回 App 里重新授权。
- **App 名仍是本地化显示名**，不是 bundle id：系统换语言或 App 改名后名字会变，
  需要重新选一次（界面会提示「系统还没上报过」）。真正的解法是 iOS 27 的 bundle id。
- **「触发器勾选全部 App」未经真机验证**：当初验的是勾 2 个 App（见 `docs/03` 第 4 节开放项）。
- **触发延迟未量化**：无外部插桩点，只能靠 `poc-trace.log` 的时间戳粗略观察。
- **取证工具仍在包里**：`POCTrace` / `POCSelfTest` 是为排查而加的，不参与产品逻辑，
  进入产品化阶段应移除或 `#if DEBUG` 包起来。

### 5.3 交付物边界（回答原始需求第 3、6 条）

| 问题 | 结论 |
| --- | --- |
| API 能做到什么 | 检测"某 App 被打开"只能靠 Shortcuts 自动化；**App 自身无公开 API 监听第三方 App 启动** |
| 免费账号能做到什么 | 上述全链路**已验证可用**，含带两个按钮的本地通知 |
| 付费账号才有的 | Screen Time 系（FamilyControls / DeviceActivity / ManagedSettings）的 entitlement；本项目未使用 |
| 上架 App Store 还需要什么 | 本地通知无需额外 entitlement；但**要求用户手动建 Shortcuts 自动化**这一点，是产品化时最大的体验障碍 |

> 更完整的可行性边界见 `00-feasibility-analysis.md`。
