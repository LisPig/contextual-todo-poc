# 情境化待办提醒 · iOS 可行性 PoC

**打开某个 App 时，弹出你为它绑定的待办。**

你在「微信」上总忘记回某个人的消息？把「给张总回消息」绑到微信上。
下次打开微信，横幅就会弹出来：

```
打开 微信 时想起
给张总回消息
```

下拉横幅可见两个按钮：**完成** / **稍后再说**。

> 本仓库是**技术可行性验证**，不是完整产品。第一阶段要回答的只有一个问题：
> iOS 上到底能不能做到「打开第三方 App → 弹出提醒」，以及**免费的 Apple 账号够不够**。
> 答案是：**能，而且免费账号就够** —— 但实现路径和直觉完全不同。
>
> 第一阶段结论见 [`docs/01-poc-verification.md`](docs/01-poc-verification.md)。
> 之后做了 v2，专门解决**接线太麻烦**：自动化从"每个 App 建一条"压成"只建一条"，
> App 名改为由系统上报、从列表里选（不再手打）。见下方「快速开始」。

---

## 结论先行

| 直觉上的做法 | 实际结论 |
|---|---|
| 我的 App 监听其他 App 的启动 | ❌ iOS 没有这样的公开 API，任何第三方 App 都做不到 |
| 用 DeviceActivity 检测"打开事件" | ❌ 它的语义是"**累计使用时长**超过阈值"，不是启动事件。方向错了，不是权限问题 |
| 用 FamilyControls 选 App | ⚠️ API 可用，但需要 `com.apple.developer.family-controls` entitlement，**免费账号申请不到**，因此本期未实现 |
| **Shortcuts 个人自动化 + App Intent** | ✅ **唯一可行路径，已在真机端到端验证** |

关键在于：**真正的监听方是系统自带的 Shortcuts，不是我们的 App。**
Shortcuts 的个人自动化有「当 App 被打开时」这个触发器 —— 这是 iOS 上唯一能拿到"打开事件"的地方。
我们的 App 只是提供那个被调用的动作。

```
用户在 Shortcuts 里建**一条**个人自动化（只需建一次，触发器勾选全部 App）
        │  触发器 = 打开任意 App
        │  动作   = 获取当前 App → 从输入获取文本(名称) → 检查待办并提醒
        ↓
iOS 系统（Shortcuts）
        │  调用我们的 App Intent：LogAppOpenedIntent，参数 = 刚才那个 App 的系统名
        ↓
本 App（被系统在后台拉起）
        │  1. 记下「见过这个 App」，再查 TodoStore：它有没有未完成的待办？
        │       没有 → 静默返回，不打扰（绝大多数触发都属于这一类）
        │       有   → 2. 发一条本地通知（带两个按钮）
        ↓
横幅弹出：打开 微信 时想起 / 给张总回消息
        │
        ├─ 点「完成」    → TodoStore 标记完成 → 以后不再提醒
        └─ 点「稍后再说」→ 状态不变 → 下次打开微信会再次提醒
```

App 名**由系统上报**（「获取当前 App」动作），用户一个字都不用打；新增待办也不用再回到
「快捷指令」。代价是 intent 会在**每次切换 App** 时被调用，所以未命中的路径必须绝对静默。

**为什么用本地通知而不是 Intent 的 `.result(dialog:)`**：Shortcuts 弹出的对话框横幅
**不支持自定义按钮**，只有系统给的关闭按钮。产品要的「完成 / 稍后再说」只有
`UNNotificationCategory` + `UNNotificationAction` 能做。本地通知也不需要任何 entitlement，
免费账号可用。

---

## 快速开始

需要 macOS + Xcode + 一台 iPhone。**只跑模拟器的话，检测链路是验证不了的**
（Shortcuts 自动化的触发器在模拟器上不可用），必须真机。

### 1. 构建并装到手机

```bash
cd FamilyActivityPoC
open FamilyActivityPoC.xcodeproj
```

在 Xcode 里选中 `FamilyActivityPoC` target → Signing & Capabilities → 把 Team 改成
你自己的 Apple ID（免费 Personal Team 即可）。然后选真机运行。

> 首次运行需要在 iPhone 上「设置 → 通用 → VPN与设备管理」里信任你的开发者证书。

### 2. 在 Shortcuts 里建那条自动化（**只需一次**，这一步是产品能否工作的关键）

先做这一步：因为 App 名只能"系统上报过"才选得到，而系统上报靠的就是这条自动化。

在 iPhone 上打开「快捷指令」App：

1. 「自动化」标签 → 新建自动化 → 选「**App**」
2. 点「选取」，**把所有 App 都勾上**，勾选「**已打开**」→ 选「立即运行」，
   并确认「**运行前询问**」是**关**的（它默认开着，不关的话每次打开 App 都会先弹确认框）
3. 按顺序加三个动作：
   - ① 获取当前 App
   - ② 从输入获取文本，属性选「名称」
   - ③ 检查待办并提醒（搜本 App 的名字），把它的「App 名称」参数设成 ② 的输出

> 顺序不能换：② 读的是 ① 的结果，③ 读的是 ② 的结果。第 ① 步要求 iOS 18.2 或更高。
> App 里「接线指引」有同样的五步，只是更啰嗦。

4. **回到桌面，打开任意一个 App（比如微信）**，再切回本 App —— 「日志」页的「检测到的 App」
   里出现它，才算接通。

这一条不能省：自动化是**被动**的，只在"某个 App 被打开"的那一刻触发。刚建完时系统还
不知道任何 App 的名字，列表必然是空的。**在「快捷指令」里点运行按钮不算** ——
那一刻没有"当前 App"，「获取当前 App」拿不到东西。

### 3. 在 App 里建待办

回到本 App，「待办」页 → 点右上角 **＋** → 填待办内容 → 点「选择 App」，
从**检测到的 App** 列表里勾（可以勾多个，比如「回消息」同时绑微信和企业微信）→「添加」。

列表里没有你要的 App，就先去打开它一次；打开过还没有，说明第 2 步没勾上它。

待办列表分两段：**待办中**在上（左滑标记完成，右滑删除），**已完成**在下、默认折叠。
点一条待办可以改它绑的 App。顶部的「自动化接线指引」和导航栏右上角的 ❓ 是同一个入口。

> 一个 App 只能属于一条待办 —— 否则两条待办同时命中会重复提醒。
> 从别的待办手里把 App 抢过来是允许的，被抢的那条会显示橙色「未选择 App（不会提醒）」，不会被删掉。

### 4. 验证

退出到桌面，打开微信。横幅应该弹出。

「日志」页的「检测到的 App」是判断接线通没通的凭据：随便切几个 App 再回来，
列表里有东西就是通了。

---

## 项目结构

```
FamilyActivityPoC/           Xcode 工程（objectVersion 77 的文件系统同步组，新增/改名 .swift 自动纳入编译）
└── FamilyActivityPoC/
    ├── FamilyActivityPoCApp.swift   入口：注册通知类别、设 delegate、无头自检钩子
    ├── ContentView.swift            两个 Tab：「待办」/「日志」；文件级 POCFormat 供两处共用
    ├── SetupGuideView.swift         接线指引 sheet：五步 + 「运行前询问」警告 + 排查清单
    ├── NewTodoSheet.swift           新增待办 sheet（右上角 ＋）：内容 + 内推「选择 App」
    ├── AppPickerSheet.swift         选择 App：可复用的 AppPickerList（多选、已占用置灰）
    │                                   + 一个 sheet 外壳（改绑已有待办走它）
    ├── AppChipsView.swift           绑定的 App 芯片 + 自写的换行 Layout
    ├── TodoBinding.swift            绑定模型（appNames 集合 + v1 迁移 + 宽容解码）
    ├── TodoStore.swift              绑定的持久化与「一个 App 只属于一条待办」不变量
    ├── SeenApp.swift                见过的 App 模型
    ├── SeenAppStore.swift           「系统上报过哪些 App」的持久化与淘汰
    ├── TodoReminder.swift           通知类别、按钮、发送与撤销
    ├── LogAppOpenedIntent.swift     ★ 被 Shortcuts 调用的那个 App Intent
    ├── ActivityLog.swift            事件日志模型
    ├── ActivityLogStore.swift       事件日志持久化
    ├── POCTrace.swift               排查用追踪日志（非产品逻辑）
    └── POCSelfTest.swift            无头自检开关（非产品逻辑）
docs/
├── 00-feasibility-analysis.md       动工前的 A–E 分析：API 可行性、免费账号限制、架构、Target、步骤
├── 01-poc-verification.md           ★ 实测记录与证据链，含真机端到端追踪原文
├── 02-original-brief.md             原始需求存档
└── 03-shortcuts-setup-research.md   接线体验的调研：触发器能力、两条候选路线
```

### 排查工具（`POCTrace` / `POCSelfTest`）

真机上没法打断点也没法做 UI 自动化，所以包里留了两个调试钩子。
它们**不参与产品逻辑**，产品化时应删除或 `#if DEBUG`。

```bash
# 追踪日志：每条都在 Application Support/poc-trace.log 里带 ISO 时间戳 + PID
xcrun devicectl device process launch --terminate-existing --device <UDID> \
  com.example.FamilyActivityPoC --poc-self-test 微信

# 一次性 dump 系统侧状态：通知权限、横幅样式、已注册按钮、送达数、绑定状态
xcrun devicectl device process launch --terminate-existing --device <UDID> \
  com.example.FamilyActivityPoC --poc-dump-state
```

`--poc-dump-state` 特别值得留着：它能区分「通知没发出去」和
「发出去了但被系统静默了」—— 后者是真机上最常见的假故障（见下）。

---

## 已知限制

### 平台层面的（改代码解决不了）

| 限制 | 说明 |
|---|---|
| **按钮要下拉横幅才能看到** | iOS 的通知横幅收起时只显示标题和正文，操作按钮必须下拉/长按展开。这是系统行为，App 无法改变 |
| **专注模式会静默投递** | 手机开着专注/睡眠模式时，通知**进了通知中心但没有横幅**，看起来像代码没发出去。本机日常就处于专注模式，务必把本 App 加入允许列表 |
| **必须用 Shortcuts 中转** | 只有 Shortcuts 的个人自动化能拿到「App 被打开」事件。这意味着用户必须手动建一条自动化（只需一次） |
| **通知中心只保留最新一条** | 同一条待办的提醒用同一个 `identifier`，重复提醒会覆盖而非堆积（横幅照常每次都弹） |
| **App 名仍是一个本地化显示名** | 「获取当前 App」给的是**名字**、不是 bundle ID，所以系统换语言或 App 改名后名字会变。v2 已把它的来源收窄成"系统上报过的列表"（不再手打，消灭拼写不一致），但名字本身仍是匹配键 |
| **漏勾的 App 完全静默** | 触发器里没勾上的 App，打开时不会有任何反应 —— 和"没绑待办"的表象一模一样。所以第 2 步建议勾全部 |

### 免费 Apple 账号的（本项目的现实约束）

| 限制 | 影响 |
|---|---|
| **描述文件 7 天过期** | 每 7 天要重新装一次 App，否则自动化调用会失败 |
| **重装后 Shortcuts 自动化大概率要重建** | 这是目前最影响日常使用的一条。重装还会把通知权限打回"未决定"，此时打开目标 App 会**毫无反应** —— 需要回本 App 重新授权 |
| 3 台设备 / 10 个 App ID | 够用 |
| **拿不到 FamilyControls entitlement** | 所以 Track A（Screen Time API 那条路）本期未实现，也无法用免费账号验证 |

### 架构上尚未解决的

- **App 名是**本地化显示名**，不是 bundle ID** —— intent 拿不到被打开 App 的 bundle ID
  （见 `docs/03`）。v2 已经把用户侧的拼写风险消掉了（名字只能从系统上报过的列表里选），
  但名字本身仍会被系统换语言/App 改名改掉，届时要重新选一次（界面会提示"系统还没上报过"）。
  真正的解法是 iOS 27 的 bundle id，留待升级后再说。
- **一条待办绑多个 App 时，在其中一个里点「完成」，别的也不提醒了** ——
  它们是同一条待办，这是有意为之。

---

## 文档

| 文档 | 读它的时机 |
|---|---|
| [`docs/01-poc-verification.md`](docs/01-poc-verification.md) | **想知道"到底验证了什么"** —— 11 项实测清单、真机端到端追踪原文、两个真机大坑（VPN/OCSP、专注模式） |
| [`docs/00-feasibility-analysis.md`](docs/00-feasibility-analysis.md) | **想知道"为什么选这条路"** —— A–E 分析、7 条技术论断的一手文档核验、免费/付费/App Store 三档能力对照 |
| [`docs/03-shortcuts-setup-research.md`](docs/03-shortcuts-setup-research.md) | **想改接线体验** —— Shortcuts「App」触发器的真实能力（拆二进制查实，Apple 文档在"能否多选"这点上是错的；「获取当前 App」已在真机验证）、两条候选路线 |
| [`docs/02-original-brief.md`](docs/02-original-brief.md) | 原始需求存档 |

两条最值得先看的结论：

- 免费账号能做什么、付费账号才能做什么、上 App Store 需要什么 entitlement ——
  `01-poc-verification.md` 第 5.3 节
- 为什么 DeviceActivity 走不通（不是权限问题，是语义不匹配）—— `00-feasibility-analysis.md` A 节

---

## 开发环境

macOS · Xcode 26.4 · Swift / SwiftUI · 部署目标 iOS 18.0 ·
免费 Apple Personal Team · 真机 iPhone 15 Pro / iOS 26.7

无需付费开发者账号，无需任何 entitlement。
