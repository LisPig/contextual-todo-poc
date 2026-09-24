# iOS「检测第三方 App activity」技术可行性分析（阶段 0，写代码前）

对应 `README.md` 要求：先输出 A–E，不做完整产品实现。

核对日期：本机 macOS 26.6.2；资料以 Apple 官方文档为主，论坛/第三方仅作补充并已标注。

> **修订记录**
>
> - **r5（2026-09-23，真机端到端验收完成）**：最小闭环在**真机上用真实手指点击**验证通过 —— 点「完成」后 `isDone` 翻转、再次打开目标 App 静默；点「稍后再说」状态不变、再次打开仍提醒。此前"按钮点击能否被系统投递"是唯一未覆盖环节，现已由真机追踪日志证实。过程中定位两个**非代码**的真机坑：① **专注模式**会把通知静默投递（表现为"通知发了但看不到"，且 Shortcuts 对话框不受影响，极易误判为代码 bug）；② **收起的横幅不显示操作按钮**，必须下拉展开，这是平台约束，产品化时必须纳入体验设计。详见 `01-poc-verification.md` 2e/2f/2g。
> - **r4（2026-09-23，产品最小闭环）**：按产品的真实意图（**打开某个 App 时弹出横幅提醒该 App 绑定的待办事项**，而非"记录事件"）实现并验证了最小闭环。要点：① 提醒改用**本地通知**而非 Shortcuts 对话框 —— 对话框横幅**不支持自定义按钮**，而产品要求「完成 / 稍后再说」；② 新增 `TodoBinding` / `TodoStore` 数据模型与「App 名 ↔ 待办」绑定 UI；③ `appName` 参数改 Optional（必填时 Shortcuts 每次触发都弹窗，破坏零交互前提）。模拟器与真机均实测通过：绑定 → 打开 → 弹待办 → 完成则不再提醒 / 稍后则仍提醒。C 节架构图与双轨对比表已按此更新，详见 `01-poc-verification.md` 2e 节。
> - **r3（2026-09-23，真机实测结论）**：Track B 由 ⚠️ 升级为 ✅ **已验证成立**。在 iPhone 15 Pro / iOS 26.7 上实测：打开微信 → Shortcuts 个人自动化自动触发 → 调用本 App 的 `LogAppOpenedIntent` → 事件落盘，**全程无人工交互**。A0/A3 节的判断（iOS 无 API 直接监听，Shortcuts 是唯一可行路径）获得实证。**仍成立的两点限制**：① 自动化需用户手动配置一次，App 无法程序化创建；② 免费账号描述文件 7 天过期，需定期重装（重装会打断自动化绑定，需重建）。详见 `01-poc-verification.md`。
> - **r2（2026-09-23）**：① 勘误 Phase 0 环境判断——初稿"未安装 Xcode"为误判，实测 Xcode 26.4 与 iOS SDK 26.4 均已就绪，唯一阻塞是 `xcode-select` 指向错误；② 依 README 需求 6，把 Track B 由 ✅ 降为 ⚠️ **待实测**；③ 免费账号额度（7 天过期 / 3 设备 / 每设备 3 App / 10 App ID）由官方页面确证，去掉"待确认"标记；④ 按"免费账号只做 Track B"决策收敛范围，Track A 本期不实现；⑤ 因 Track B 无跨进程共享，**取消 App Group 依赖**，改用沙盒 `Application Support`；⑥ 全部 A 节技术论断经独立核验对照 Apple 一手文档，**7 条无一被推翻**（核验方式见文末）。
> - **r1**：初稿（A–E 分析）。

---

## A. 当前 iOS API 可行性分析

### A0. 总纲（必须先接受的前提）

iOS **没有**任何公开 API 让普通 App 监听「某个第三方 App 被启动」这一事件。

- `FamilyActivityPicker` 返回的是不可逆的 opaque token（`ApplicationToken`），App 既拿不到 bundle id，也拿不到「谁被打开了」。
- `DeviceActivity` 的语义是**「累计使用时长」**，不是「启动事件」。
- 唯一能做到「打开即触发」的，是 **Shortcuts 个人自动化**（由系统 Shortcuts 负责监听 App 打开，再调用你的 App Intent）。

因此「打开目标 App → 立刻检测到」在原生 Screen Time API 上**不可行**，这一点与账号是否付费无关，是 API 语义决定的。

### A1. 官方文档原文与含义

`DeviceActivityEvent.threshold` 的官方定义（Device Activity framework）：

> "The amount of time to monitor the provided applications, categories, and web domains."

`DeviceActivityEvent` 概览进一步定义 activity 的含义：

> "Device activity is the amount of time an application, category, or web domain is frontmost on the screen and accumulates based on the time zone of the scheduled start date."

→ `threshold` 是**时长**（`DateComponents`），达到累计使用时长后才触发。**没有「started/launched」类回调。**

`DeviceActivityMonitor`（必须放在 Device Activity Monitor Extension 内，作为 extension 的 principal class）提供的全部回调：

| 回调 | 含义 | 与「App 被打开」的关系 |
| --- | --- | --- |
| `intervalDidStart(for:)` | 监控时间段开始 | 无关（是日历时间，例如 09:00） |
| `intervalDidEnd(for:)` | 监控时间段结束 | 无关 |
| `intervalWillStartWarning(for:)` | 时间段开始前预警 | 无关 |
| `intervalWillEndWarning(for:)` | 时间段结束前预警 | 无关 |
| `eventDidReachThreshold(_:activity:)` | 选定 App/Category/WebDomain 的**累计使用时长**达到阈值 | 最接近，但有累积窗口 + 系统调度延迟 |
| `eventWillReachThresholdWarning(_:activity:)` | 即将达到阈值 | 同上 |

`DeviceActivitySchedule` 是「日历时间段 + 是否重复 + warningTime」，官方文档中**未出现任何 minimum 时长的明文要求**（本次核对未找到「15 分钟」的官方出处，故不写进结论）。

`DeviceActivityEvent.includesPastActivity`：

> "Whether the system takes into account the person's device activity before your app starts monitoring the event."

→ 设 `false` 可避免把「开始监控前已积累的使用量」计入，从而减少阈值被瞬间打满的情况。

### A2. 各框架/组件的真实能力边界

| 组件 | 能做到 | 不能做到 |
| --- | --- | --- |
| `FamilyControls` / `AuthorizationCenter` | 请求/撤销 Screen Time 授权（`.individual`）、拿到授权状态 | 读取被选中 App 的身份（token 是不透明且不可逆的） |
| `FamilyActivityPicker` | 让用户选择要监控的 App / 类别 / 网站 | 返回 bundle id；返回「哪个 App 刚被打开」 |
| `DeviceActivity`（Center + Schedule + Event） | 注册「时间段 + 时长阈值」监控；查询已注册监控 | 注册「App 启动」事件；实时（毫秒/秒级）回调；后台常驻监听 |
| `DeviceActivityMonitor`（extension） | 在 interval / threshold 回调里做逻辑（写共享容器、发本地通知、施加 shield） | 拿到精确的「打开时刻」；被系统按时唤醒的保证 |
| `ManagedSettings` | 施加 shield / 限制（屏蔽 App、web 过滤等），写 `ManagedSettingsStore` | 读取 activity 事件；作为触发器 |
| `App Intents` + `AppShortcutsProvider` | 把 action 暴露到「快捷指令」，可被 Shortcuts 自动化调用；可写共享容器、发本地通知 | 自己监听其他 App 的启动 |
| Shortcuts 个人自动化（App 打开/关闭触发器） | **系统级**监听「某 App 被打开」→ 运行含你 App Intent 的快捷指令 | 由用户手动配置；不能由你的 App 程序化创建；跨设备需重新启用 |

Shortcuts 官方说明（Apple Support，Intro to shortcuts with automations）：

> "Shortcuts with automations provide a way to run actions based on events such as time of day, arrival at a location, or **the opening of an app**."
> "…when an event occurs you'll receive a notification asking you to run the automation. You can also enable an automation to run without asking."
> "Automation shortcuts are specific to a device."

→ 这是「打开即触发」唯一可验证路径，代价是**用户手动建一次自动化**，且触发时系统可能显示横幅提示。

### A3. 「打开即触发」可行性判定（需求 7 的直接回答）

| 目标 | 判定 | 说明 |
| --- | --- | --- |
| 原生 API 直接监听 App 启动 | ❌ 不可能 | 无该 API |
| DeviceActivity `eventDidReachThreshold` 实现「打开 N 秒后触发」 | ⚠️ 理论可行 | 需付费 entitlement；且触发时刻由系统调度，**延迟不可控、不保证实时**（论坛报告 iOS 26.x 有「立即触发」与「不触发」两类现象，属社区证据，非官方承诺） |
| `intervalDidStart` 当「打开」用 | ❌ 语义错误 | 那是时间段开始，与 App 是否打开无关 |
| Shortcuts 自动化 + App Intent | ✅ **已验证成立**（2026-09-23 真机实测，见 `01-poc-verification.md` 2d） | 唯一能做到「打开即触发」的路径；依赖用户手动配置一次 |

**结论：PoC 必须双轨。Track B（Shortcuts）先做，Track A（DeviceActivity）作为 API 原生上限的证据。**

---

## B. 免费 Apple Account 的限制

官方依据：Apple《Supported capabilities (iOS)》表格（已核对页面 HTML 结构，三列为 ADP / ADEP / Apple Developer）。

### B1. 决定性一条：Family Controls (development) 需要付费账号

表格中 `Family Controls (development) *` 一行**只有第一列（ADP，Apple Developer Program，付费）有勾**，ADEP 与「Apple Developer」（免费 Apple Account，no cost）两列**均为空**。同一列打勾的还有 Apple Pay、Game Center 等付费专属能力。

→ **即使只是开发 / 真机调试，只要用到 Screen Time API，就必须加入付费 Apple Developer Program（$99/年）。免费 Personal Team 做不到。**

配套的第三方实测记录（非官方，作为交叉验证）：Personal Team 在真机签名阶段即被拒，模拟器只能验证编译与不直接调用 `FamilyControls` 的逻辑。

### B2. 免费账号能力对照（与 PoC 相关）

| 能力 | 免费 Apple Account / Personal Team | 说明 |
| --- | --- | --- |
| App Groups | ✅ 支持（表格三列均有勾） | 主 App ↔ Extension 共享日志的前提 |
| 本地通知 `UNUserNotificationCenter` | ✅ 支持 | 不需要 entitlement，是 PoC 的「测试事件/提醒」出口 |
| App Intents / Shortcuts action | ✅ 支持 | Track B 的全部依赖 |
| Family Controls (development) | ❌ 不支持 | Track A 的硬门槛 |
| Push notifications | ❌ 不支持（仅付费列有勾） | 本 PoC 用本地通知，无影响 |
| App Store / TestFlight 分发 | ❌ 不可能 | 免费账号只能装到自己的设备 |

### B2b. 免费 Personal Team 的硬性额度（已核验为官方明文，2026-09-23）

来源：Apple 官方 `Developer account overview` → "Enable a personal team in Xcode"（https://developer.apple.com/help/account/basics/about-your-developer-account），原文：

> "If your account is not associated with a developer program membership, Xcode will indicate it's a Personal Team. Your account's App IDs, devices, certificates, and provisioning profiles are managed directly in Xcode, and you'll be required to reprovision your apps to a device periodically. You can register up to **10 App IDs, which expire after 7 days**. You can register up to **3 devices, which expire after 7 days**. You can install up to **3 apps per device**. **Provisioning profiles that enable apps to be installed on a device will expire 7 days from issuance.** You'll need to rebuild and reinstall your app to your device after expiration."

初稿把"7 天过期 / 3 个 App"标为待确认，现已由官方页面证实。对 Track B 的直接影响：

| 额度 | 数值 | 对 PoC 的含义 |
| --- | --- | --- |
| 描述文件有效期 | **7 天** | Track B 真机 PoC **每周必须重新 build + 安装一次**，否则 App 无法启动。这是"免费账号方案能否长期使用"的决定性约束。 |
| 设备数 | 3 台 / 7 天 | 够用 |
| 每设备 App 数 | 3 个 | 主 App + 未来的 extension 会占用额度，需留意 |
| App ID 数 | 10 个 / 7 天 | 够用 |

**结论**：Track B 在免费账号下**可用于一次性技术验证**，但不是可长期运行的产品形态。这一点必须写进最终结论，不能当成"免费即可"。

### B3. 模拟器能验证到哪一步

- ✅ 可以：编译、SwiftUI 界面、日志模型、App Group 读写、本地通知、App Intent 在快捷指令中可见。
- ❌ 不可以：`AuthorizationCenter` 授权弹窗、`FamilyActivityPicker` 真实选择、`ManagedSettings` shield 效果、`DeviceActivityMonitor` 回调——这些**必须真机**，且都需要付费 entitlement。

---

## C. PoC 架构

两条腿共用同一套日志与 UI，互不污染。

```
共享层 (Shared/)
  TodoBinding.swift         // **产品核心模型**：App 名 ↔ 待办文本 {id, appName, todoText, isDone, createdAt}
  TodoStore.swift           // 绑定的持久化 + pendingBinding(forAppNamed:)：按 App 名查「未完成」的待办
  ActivityLog.swift         // Codable: {id, source: .deviceActivity | .shortcutIntent, event, timestamp}
  ActivityLogStore.swift    // 持久化：本期用 App 沙盒 Application Support（Track B-only 无跨进程需求，不用 App Group）
  POCNotifier.swift         // TodoReminder（本地通知出口）+ TodoNotificationHandler（「完成/稍后再说」回调）
  POCSelfTest.swift         // 无头自检开关（本机无法 UI 自动化时的取证手段）
```

> `ActivityLog` 不是产品主角，但它是**验证证据的来源**（"这次触发到底有没有发生"）。
> 同时 `source` 字段必须如实区分 `.shortcutIntent` / `.deviceActivity`，
> 否则 Track A 的"累计达阈值"会被误读成 Track B 的"打开即触发"，PoC 结论就失真了。

### Track A — Screen Time API 原生路径（**本期不实现**；需付费账号，见 B1 与 E-Phase 2）

```
主 App (SwiftUI)
  [1] FamilyActivityPicker  选择目标 App  -> ApplicationToken（不透明）
  [2] AuthorizationCenter.shared.requestAuthorization(for: .individual)
  [3] DeviceActivityCenter.startMonitoring(activityName, schedule, events)
        schedule: intervalStart/intervalEnd 覆盖当前时刻, repeats: true
        event:    DeviceActivityEvent(applications: [token], threshold: 1 分钟, includesPastActivity: false)
        |
        v  (系统自行调度，App 不需要在运行)
  DeviceActivityMonitor Extension
  eventDidReachThreshold  -> 写 ActivityLog(source: .deviceActivity) + 本地通知
        |
        v
  主 App 读 App Group，展示时间线：打开目标 App -> 阈值回调到达（记录两者时间差）
```

关键诚实标注：这里记录的是「**累计使用达阈值被检测到**」，**不是「打开被检测到」**。日志里必须如实区分，否则 PoC 结论会失真。

### Track B — Shortcuts / App Intents（免费账号即可真机验证，「打开即触发」）

```
主 App 暴露 App Intent: LogAppOpenedIntent(appName: String?)   // openAppWhenRun = false
  + AppShortcutsProvider 让它出现在「快捷指令」
        |
        v  用户在 Shortcuts 里手动建一次个人自动化：
           「当 微信 被打开」-> 运行「检查待办并提醒」 -> LogAppOpenedIntent(appName: "微信")
        |
        v
  LogAppOpenedIntent.perform():
     [1] 写 ActivityLog(source: .shortcutIntent)          // 验证证据
     [2] TodoStore.pendingBinding(forAppNamed: "微信")     // 查「未完成」的待办
     [3] 有 -> TodoReminder.post(appName:todoText:)        // 本地通知，带两个按钮
         没有 -> 静默返回，什么都不弹
        |
        v
  用户点通知上的按钮 -> TodoNotificationHandler.didReceive
     「完成」     -> markDone  -> 之后打开该 App 不再提醒
     「稍后再说」 -> 不改状态 -> 下次切回该 App 仍会提醒
```

**关键实现选择（有依据，不是随意定的）**：

- 提醒**必须用本地通知**，不能用 Shortcuts 的 `.result(dialog:)`。对话框横幅
  **不支持自定义按钮**（只有系统给的关闭按钮），而产品要求「完成 / 稍后再说」两个选择，
  只有 `UNNotificationCategory` + `UNNotificationAction` 能做到。
- `appName` 必须是 **Optional**。真机实测：声明为必填 `String` 时，Shortcuts 每次触发
  都会弹窗要求输入 App 名字，直接破坏"打开即触发、零交互"的产品前提。
- `openAppWhenRun = false`：提醒应浮在目标 App 之上，而不是把用户从目标 App 切走。

Track B 的已知代价（必须写进结论，不能当成「原生能力」）：
1. 需用户手动配置一次，你的 App 无法程序化创建自动化。
2. 自动化属于设备级，换设备需重新启用。
3. 可设为「不询问直接运行」，但系统仍可能显示横幅 —— 当前实现里横幅是**有意保留**的，
   它就是产品要的那个提醒。
4. **重装 App 会打断自动化绑定**，需重建。对免费账号有实际影响：描述文件 7 天过期，
   每次重签安装后大概率都要重建一次。

### 双轨对比（PoC 最终要产出的结论矩阵）

| 维度 | Track A (DeviceActivity) | Track B (Shortcuts) |
| --- | --- | --- |
| 能否检测到 activity | 能，但语义是「累计使用达阈值」 | 能，语义是「App 打开」 |
| 是否「打开即触发」 | ❌ 否 | ✅ 是 |
| 延迟 | 系统调度，不可控 | 较小，但非零 |
| 免费账号可验证 | ❌ 不能（entitlement 缺失，已核验） | ✅ **能，已真机验证通过** |
| 用户配置成本 | 仅授权 + 选择 App | 需手动建自动化 |
| 分发限制 | 需 Family Controls distribution 审批 | 无额外 entitlement |
| **弹出带按钮的待办提醒** | 未实测（被 entitlement 阻塞） | ✅ **能，已实测**：本地通知 +「完成 / 稍后再说」两个 action |
| **最小闭环**（绑定 → 打开 → 提醒 → 完成/稍后） | 未验证 | ✅ **已验证**，见 `01-poc-verification.md` 2e 节 |

> 上表是 PoC 要产出的结论矩阵。Track B 的 ✅ 均为**真机实测**结论，取证方式见 `01-poc-verification.md`；
> Track A 的空白格是**被免费账号 entitlement 阻塞**所致，不代表 API 层面不可行（见 B1 与 E-Phase 2）。

---

## D. 需要创建的 Xcode Target / Extension

工程名：`FamilyActivityPoC`（Xcode，iOS App，SwiftUI，Swift）

> **范围决策（2026-09-23）**：经确认走**免费 Apple 账号、只做 Track B**。因此本表**只创建 #1**；
> Track A 所需的 `DeviceActivityMonitorExtension` **本期不创建**（免费账号勾不上 Family Controls capability，建了也无法真机运行）。
> Track A 在本期以"被 entitlement 阻塞"的书面结论入库，不作为待实现项。

| # | Target | 类型 | 关键配置 |
| --- | --- | --- | --- |
| 1 | `FamilyActivityPoC` | iOS App (SwiftUI) | **无任何 capability 需求**；Track B 只需 `AppIntent` + `AppShortcutsProvider`（都写在主 App target 内） |
| ~~2~~ | ~~`DeviceActivityMonitorExtension`~~ | ~~Device Activity Monitor Extension~~ | **本期不创建**（Track A 专用；免费账号下 family-controls capability 不可用） |
| 3 | `Shared` | 无独立 target | 一组 `.swift` 文件。**Track A 时才需勾选两个 target**；本期只有主 App target，故无需 target membership 配置 |

**对初稿架构的一处简化（重要）**：初稿 C 节把 `ActivityLogStore` 设计为"App Group 容器读写"。在 **Track B-only** 形态下这是**不必要的**——App Intent 与主 App 运行在**同一进程/同一容器**，不存在跨进程共享需求，App Group 是仅为"主 App ↔ Extension"通信而引入的。
因此本期实现**不申请 App Group capability**，直接用 App 沙盒容器（`Application Support`）持久化。
好处：少一个 capability、少一处签名风险，免费账号下更少变数。若将来补做 Track A，再引入 App Group 即可。

第一阶段**不创建**（避免范围膨胀）：Device Activity Report Extension、Shield Configuration Extension、Shield Action Extension、ManagedSettings 相关的任何 UI，以及上述 Device Activity Monitor Extension。

---

## E. 最小实现步骤

### Phase 0 — 环境

> **勘误（2026-09-23 实测修正）**：本节初稿曾断言"本机未安装 Xcode，工具链不可用"。**该判断错误。**
> 实测：`/Applications/Xcode.app` 已安装（Xcode 26.4 / 17E192，4.8 GB），iOS SDK 26.4 齐全，license 已接受，iOS 26.4 模拟器 runtime 及 iPhone 17 系列机型可用。
> 真实病因只是 `xcode-select -p` 指向 `/Library/Developer/CommandLineTools`。以 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 覆盖后实测通过：
> `xcrun --sdk iphoneos --show-sdk-version` → `26.4`；`swiftc -target arm64-apple-ios18.0 -parse` SwiftUI 文件 → 通过。
> 因此 **Phase 0 不是"安装 20 GB Xcode"，而是一条命令。**

本机当前状态：

| 项 | 状态 |
| --- | --- |
| Xcode | ✅ 26.4 (17E192)，已安装 |
| iOS SDK | ✅ 26.4（`iphoneos26.4` / `iphonesimulator26.4`） |
| Xcode license | ✅ 已接受（`IDELastGMLicenseAgreedTo = EA1990`） |
| 模拟器 runtime | ✅ iOS 26.4 已安装，机型齐全 |
| `xcode-select` | ✅ 已修正为 `/Applications/Xcode.app`（`DEVELOPER_DIR` 绕行已不再需要） |
| Apple ID / 开发者证书 | ✅ 免费个人团队 Team ID `NXAY2Q2YH2`，Xcode 自动管理证书与描述文件 |
| 实体 iPhone | ✅ 已连接：iPhone 15 Pro (iPhone16,1) / iOS 26.7 / UDID `<已隐去>` |
| 已有构建产物 | ✅ 模拟器与真机构建均通过 |

1. ~~**修正工具链指向（唯一阻塞项，需 sudo）**：`sudo xcode-select -s /Applications/Xcode.app`~~ ✅ 已执行。
2. ~~准备实体 iPhone + Apple ID~~ ✅ 已完成，走免费账号，只做 Track B。
3. ~~建空 SwiftUI 工程跑到真机，先证明签名链路通~~ ✅ 已完成（签名链路见 `01-poc-verification.md` 2b 节）。

> ⚠️ 签名链路上踩到的真实坑：**手机开着 VPN 会导致证书 OCSP 校验被阻断**，
> 表现为「尚未验证的开发者」且反复点"信任"无效。诊断与解法见 `01-poc-verification.md` 2c 节。

> 注：Apple ID 未登录 / 无证书**不阻塞模拟器阶段的全部工作**（编译、SwiftUI 界面、日志模型、本地通知均可模拟器验证）。它只阻塞"真机安装"这一步，而那是 Track B 端到端验收的必要条件。

### Phase 1 — Track B（免费账号就能跑通，产出「打开即触发」的实证）✅ 已完成

实际实现与本节初稿的差异（两处偏离，理由见 C 节）：
**① 不用 App Group**（Track B 无 extension、无跨进程需求，改用沙盒 `Application Support`）；
**② 不止于"记录日志"**，而是做到了产品的最小闭环（绑定待办 → 弹出待办 → 完成/稍后）。

1. ~~建工程 `FamilyActivityPoC`，加 App Group~~ → 建了工程，**未加 App Group**。
2. `ActivityLog` / `ActivityLogStore` / `TodoBinding` / `TodoStore` / `POCNotifier` / `POCSelfTest`。
3. 主 App：两个标签页 —— 「待办」管理 App↔待办绑定，「日志」看触发记录。
4. `LogAppOpenedIntent`（`AppIntent`，参数 `appName: String?`）+ `AppShortcutsProvider`。
5. 真机运行 → 快捷指令中确认 action 可见 → 手动执行一次 → 看到日志。
6. 手动建个人自动化「当 [目标 App] 被打开 → 运行「检查待办并提醒」」，设为不询问直接运行。
7. 验收：打开目标 App → 弹出该 App 绑定的待办；点「完成」不再提醒，点「稍后再说」仍提醒。

→ 这一步直接回答「能否检测到 activity 并触发测试事件」：**能，但靠 Shortcuts，不是 App 自身监听。**
→ 并额外回答了产品问题：「打开 App 弹出待办横幅」**能实现**，且免费账号即可，
但提醒载体必须是**本地通知**（Shortcuts 对话框不支持自定义按钮）。

### Phase 2 — Track A（本期**不实现**，仅书面结论）

> **范围决策**：走免费账号，Track A 本期不建 target、不写代码、不做"撞墙取证"。理由：entitlement 缺失已由 Apple 官方能力表**确证**（见 B1），再花成本去复现一个已知结论不产生新信息。以下保留为**将来若付费时的执行清单**。

**已确证结论（需求 6 要求明确标记的部分）**：
- Track A **在免费 Apple 账号下无法实现，也无法验证**——不是"可能不行"，而是 Apple 能力表中 `Family Controls (development)` 一行在免费列**明确为空**。
- 即便付费，Track A 的语义仍是"**累计使用达阈值**"，**不具备「打开即触发」能力**（见 A0/A3）。

将来若付费（$99/年）再执行：
1. Signing 里勾上 Family Controls (development)，真机安装成功。
2. `FamilyActivityPicker` 选一个目标 App → `requestAuthorization(for: .individual)`。
3. `startMonitoring`：interval 覆盖当前时刻、`threshold: 1 分钟`、`includesPastActivity: false`。
4. 打开目标 App 并保持前台超过 1 分钟，记录：
   - `eventDidReachThreshold` 是否触发；
   - 触发时刻与「打开时刻」的差值（延迟量化）；
   - activity 名称是否与注册的一致。
5. 反复 3 次以上，判断延迟是否稳定 → 决定 Track A 是否具备产品级可用性。

### Phase 3 — 结论矩阵

把 Phase 1 / 2 的实测数据填进 C 节的对比表，明确写出：
- API 能做到什么 / 免费账号能做到什么 / 付费账号才能做到什么；
- App Store 发布还需要什么（见下）。

---

## 附：App Store 发布所需的 entitlement（需求 3 的第四问）

官方文档《Requesting the Family Controls entitlement》原文：

> "Before you distribute an app that uses Family Controls, your Apple Developer Account Holder must request permission to use the `com.apple.developer.family-controls` entitlement, and update your Xcode project to use the entitlement."

- 申请入口：Family Controls distribution 表单（developer.apple.com/contact/request/family-controls-distribution），或 Apple Developer 账号的 Capability Requests 标签页。
- 关键点：**若 App 含 Screen Time extension（Device Activity Monitor / Device Activity Report / Shield Action / Shield Configuration），必须为扩展提交同一份申请。**
- 审批通过后 entitlement 以 **managed capability** 形式加到账号，Certificates, Identifiers & Profiles 显示 Assigned 状态。
- 补充：开发阶段用的 capability 与分发用的是同一条 entitlement 的不同授权方式；若 Xcode 工程已包含 development 版 capability 且用自动签名，获批后 Xcode 会自动切到分发版。
- Track B 不涉及该 entitlement，但也不需要（它走的是 Shortcuts/App Intents 的公开能力）。

---

## 参考来源

Apple 官方：
- Requesting the Family Controls entitlement — https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement
- DeviceActivityMonitor — https://developer.apple.com/documentation/deviceactivity/deviceactivitymonitor
- DeviceActivityEvent / threshold / includesPastActivity — https://developer.apple.com/documentation/deviceactivity/deviceactivityevent
- DeviceActivitySchedule — https://developer.apple.com/documentation/deviceactivity/deviceactivityschedule
- Supported capabilities (iOS) — https://developer.apple.com/help/account/reference/supported-capabilities-ios/
- com.apple.developer.family-controls — https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.family-controls
- Intro to shortcuts with automations — https://support.apple.com/guide/shortcuts/intro-to-shortcuts-with-automations-apd690170742/ios

Apple 官方（r2 新增，用于确证 A/B 节论断）：
- Developer account overview（Personal Team 额度：7 天过期 / 3 设备 / 每设备 3 App / 10 App ID）— https://developer.apple.com/help/account/basics/about-your-developer-account
- Setting triggers in Shortcuts on iPhone or iPad（App 触发器 / Is Opened）— https://support.apple.com/guide/shortcuts/setting-triggers-apde31e9638b/ios
- Add automations to Shortcuts on iPhone or iPad（可自动运行的触发器清单，含 App）— https://support.apple.com/guide/shortcuts/apdfbdbd7123/ios
- FamilyActivitySelection（"holds opaque values"）— https://developer.apple.com/documentation/familycontrols/familyactivityselection
- NSWorkspace.didLaunchApplicationNotification（平台元数据仅 macOS）— https://developer.apple.com/documentation/appkit/nsworkspace/didlaunchapplicationnotification
- DeviceActivityReport（"privacy-preserving"，extension 沙盒）— https://developer.apple.com/documentation/deviceactivity/deviceactivityreport
- DeviceActivityEvent.init(applications:categories:webDomains:threshold:includesPastActivity:)（入参为不透明 token）— https://developer.apple.com/documentation/deviceactivity/deviceactivityevent

**r2 核验方式说明**：`developer.apple.com` 对 WebFetch 有域名拦截，故改用 Apple DocC JSON API（`developer.apple.com/tutorials/data/documentation/....json`）与 `developer.apple.com/help/` 的 HTML 直解；`Supported capabilities (iOS)` 以解析真实 `<table>`（58 行 × 4 列，勾选为 `icon-checksolid`）方式确认，非依赖页面渲染文本。Apple 论坛（bot 拦截，无法直取）相关内容已明确标注为"官方adjacent、非文档"。

非官方（仅作交叉验证，已在正文标注）：
- deviceactivity monitor extension 在 Personal Team 下的限制实测 — https://hsb.horse/en/blog/personal-team-family-controls-limitation/
- eventDidReachThreshold 触发时机异常（iOS 26.x）— https://developer.apple.com/forums/thread/838510
- eventDidReachThreshold 不稳定 — https://developer.apple.com/forums/thread/737741
