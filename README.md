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
用户在 Shortcuts 里建一条个人自动化
        │  触发器 = 打开「微信」
        ↓
iOS 系统（Shortcuts）
        │  调用我们的 App Intent：LogAppOpenedIntent
        ↓
本 App（被系统在后台拉起）
        │  1. 查 TodoStore：微信有没有未完成的待办？
        │       没有 → 静默返回，不打扰
        │       有   → 2. 发一条本地通知（带两个按钮）
        ↓
横幅弹出：打开 微信 时想起 / 给张总回消息
        │
        ├─ 点「完成」    → TodoStore 标记完成 → 以后不再提醒
        └─ 点「稍后再说」→ 状态不变 → 下次打开微信会再次提醒
```

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

### 2. 在 App 里建绑定

「待办」页 → 填入 App 名（如 `微信`）和待办内容 → 添加。

### 3. 在 Shortcuts 里建自动化（**这一步是产品能否工作的关键**）

在 iPhone 上打开「快捷指令」App：

1. 「自动化」标签 → 新建自动化 → 选「**App**」
2. 「App」选你要绑定的那个（如微信），勾选「**已打开**」→ 立即运行（关掉「运行前询问」）
3. 动作里搜本项目，选「**检查待办并提醒**」
4. App 名称参数填 `微信`（与 App 里绑定的名字一致）

> **App 名称参数必须填**，且两边拼写要一致 —— 它是绑定的唯一关联键（大小写和首尾空格会被忽略）。

### 4. 验证

退出到桌面，打开微信。横幅应该弹出。

---

## 项目结构

```
FamilyActivityPoC/           Xcode 工程（objectVersion 77 的文件系统同步组，新增/改名 .swift 自动纳入编译）
└── FamilyActivityPoC/
    ├── FamilyActivityPoCApp.swift   入口：注册通知类别、设 delegate、无头自检钩子
    ├── ContentView.swift            两个 Tab：「待办」绑定管理 /「日志」事件记录
    ├── TodoBinding.swift            绑定模型
    ├── TodoStore.swift              绑定的持久化（沙盒 Application Support）
    ├── TodoReminder.swift           通知类别、按钮、发送与撤销
    ├── LogAppOpenedIntent.swift     ★ 被 Shortcuts 调用的那个 App Intent
    ├── ActivityLog.swift            事件日志模型
    ├── ActivityLogStore.swift       事件日志持久化
    ├── POCTrace.swift               排查用追踪日志（非产品逻辑）
    └── POCSelfTest.swift            无头自检开关（非产品逻辑）
docs/
├── 00-feasibility-analysis.md       动工前的 A–E 分析：API 可行性、免费账号限制、架构、Target、步骤
├── 01-poc-verification.md           ★ 实测记录与证据链，含真机端到端追踪原文
└── 02-original-brief.md             原始需求存档
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
| **必须用 Shortcuts 中转** | 只有 Shortcuts 的个人自动化能拿到「App 被打开」事件。这意味着用户必须手动建一条自动化 |
| **通知中心只保留最新一条** | 同一条待办的提醒用同一个 `identifier`，重复提醒会覆盖而非堆积（横幅照常每次都弹） |
| **App 图标/名称由系统读取** | App 名称是纯文本匹配，拼写不一致就静默不提醒。这是当前设计最脆的一环 |

### 免费 Apple 账号的（本项目的现实约束）

| 限制 | 影响 |
|---|---|
| **描述文件 7 天过期** | 每 7 天要重新装一次 App，否则自动化调用会失败 |
| **重装后 Shortcuts 自动化大概率要重建** | 这是目前最影响日常使用的一条 |
| 3 台设备 / 10 个 App ID | 够用 |
| **拿不到 FamilyControls entitlement** | 所以 Track A（Screen Time API 那条路）本期未实现，也无法用免费账号验证 |

### 架构上尚未解决的

- **App 名称是关联键**，不是 bundle ID。Intent 拿不到被打开 App 的 bundle ID，
  只能靠用户手填的名称做字符串匹配，所以两侧拼写必须一致。
  更稳的做法待下一版讨论。

---

## 文档

| 文档 | 读它的时机 |
|---|---|
| [`docs/01-poc-verification.md`](docs/01-poc-verification.md) | **想知道"到底验证了什么"** —— 11 项实测清单、真机端到端追踪原文、两个真机大坑（VPN/OCSP、专注模式） |
| [`docs/00-feasibility-analysis.md`](docs/00-feasibility-analysis.md) | **想知道"为什么选这条路"** —— A–E 分析、7 条技术论断的一手文档核验、免费/付费/App Store 三档能力对照 |
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
