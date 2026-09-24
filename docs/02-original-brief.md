# 原始需求（存档）

> 这是本项目**动工前**收到的需求原文，2026-09-24 从 `README.md` 归档至此。
> 保留它是因为 `00-feasibility-analysis.md` 与 `01-poc-verification.md` 的结论
> 都是逐条对着它写的 —— 若干处标注「对应原始需求第 N 条」，指的就是下面这七条要求。
>
> 原文一字未改。当前项目说明见仓库根目录的 `README.md`。
> 下文里「在开始写代码之前，先输出 A–E」已由 `00-feasibility-analysis.md` 完成。

---

我要验证一个 iOS App 的技术可行性。

目标不是开发完整产品。

只验证：

用户在 iPhone 上打开指定的第三方 App
        ↓
我的测试 App 能否检测到这个 App 的 activity
        ↓
随后能够触发一个测试事件/提醒

技术方向优先研究：

- FamilyControls
- DeviceActivity
- DeviceActivityMonitor
- ManagedSettings
- FamilyActivityPicker
- App Intents / Shortcuts（作为备用方案）

开发环境：

- macOS
- Xcode
- Swift
- SwiftUI
- 免费 Apple Personal Team
- 实体 iPhone

要求：

1. 优先使用 Apple 官方文档
2. 不要假设普通 App 可以直接监听其他 App 的启动事件
3. 明确区分：
   - API 能做到什么
   - 免费开发账号能做到什么
   - 付费 Apple Developer Program 才能做到什么
   - App Store 发布需要什么 entitlement
4. 先做最小 PoC，不做完整 Todo UI
5. 每一步都能够实际 build/run
6. 如果某个方案理论上可行但免费账号无法验证，明确标记
7. 如果 DeviceActivity 无法实现"打开即触发"，继续验证 Shortcuts/App Intents 方案

第一阶段只需要做到：

选择一个 App
↓
授权
↓
开始监控
↓
打开目标 App
↓
记录是否检测到 activity

在开始写代码之前，先输出：
A. 当前 iOS API 可行性分析
B. 免费 Apple Account 的限制
C. PoC 架构
D. 需要创建的 Xcode Target/Extension
E. 最小实现步骤

不要一次性实现完整产品。
