# v2 调研：把 Shortcuts 接线的步骤压到最少

> **状态：调研已完成，方案未实施。** 本文只记录"什么是真的"，以及两条候选路线。
> 最终选哪条，取决于一节那个**待真机验证**的实验结果。
>
> 起因：当前形态下，用户每绑一个 App 就要走一遍 Shortcuts 自动化向导，
> 且 App 名要在**两个地方各打一遍**，拼写不一致就**静默不提醒**（无任何报错）。
> 这是整条链路上体验最差、也最脆的一环。

**证据标注约定**（沿用 `00` / `01` 的规矩）：

- **【二进制】** —— 直接拆 Apple 随系统发布的二进制得到，置信度最高
- **【官方】** —— Apple 文档 / 版本说明原文
- **【一手】** —— 第三方但亲历亲为的记述（含截图/实测结果）
- **【推断】** —— 我的推理，未被直接观测

---

## 1. 三条硬约束（决定了"能省到什么程度"）

| 约束 | 结论 | 证据 |
| --- | --- | --- |
| 自动化能导入 / 分享吗 | **不能。** Personal automation 绑设备，只 iCloud 备份；iOS 26 与 27 的分享页都没有 automation 相关内容 | 【官方】`intro-to-personal-automation`（26 版写 "will not sync"，27 版改为 "will sync to other devices with the automation disabled"，说的是**自己多设备**同步且同步过去是禁用态） |
| `shortcuts://` 能直达"新建自动化"吗 | **官方无任何自动化端点。** 未文档化的 `shortcuts://create-automation` 有人报告可用（2021 年，iOS 15/16 时代），但**不能预选触发器类型** | 【官方】`open-create-and-run-a-shortcut` 完整端点表里没有 automation；【一手】StackOverflow 69969746 |
| 有 API 能建自动化吗 | **没有。** 公开的、entitlement 门控的、已知私有的都没有 | 【官方】AppIntents 文档索引里零个 automation 符号 |

> **推论**：`shortcuts://create-automation` 只能当 **best-effort** 用（点了能少找一步），
> 必须降级到 `shortcuts://`，且**不能依赖它存在**。
>
> 顺带否掉一个传闻：网上说 iOS 27 起自动化能跟着分享的快捷指令走。我核了 Apple 原文 ——
> 没有这回事，那段话讲的是自己多设备同步。**不采信。**

---

## 2. 「App」触发器的真实能力（本节是重点，Apple 文档在这一点上是错的）

### 2.1 可以一次勾选多个 App —— Apple 文档写错了

Apple 文档写的是 "App: Tap Choose, then select **an app** from the list"（单数），
**从 iOS 14 到 27 的每一个版本、每一个语言都是单数**。同一页上 Wi-Fi 写 "one or more
Wi-Fi networks"、Bluetooth 写 "one or more Bluetooth devices" —— 也就是说 Apple 在支持多选时
是会明说的。这里纯粹是文档没跟上。

二进制证据（iOS 26.4 模拟器运行时 + 26.7 真机符号缓存，两份都在）：

- `WFAppInFocusTrigger` 的 ivar 是 **`_selectedBundleIdentifiers`，类型 `NSArray`**
- `-localizedDescriptionWithConfigurationSummary` 里对 count 分支：`count == 1` 走单数取名字，
  `count != 1` 是**另一条独立分支** —— 说明 N>1 是真实可达状态，不是死代码
- 选择器构造处：`initWithAppSearchType:omittedAppBundleIDs:**allowMultipleSelection:YES** selectedApps:`
- 导航标题是 **"Choose Apps"**
- 系统本地化 `Localizable.stringsdict` 里有复数形式：
  `"When any of %lu apps are opened"` / `"are closed"` / `"are opened or closed"`
- **没有 feature flag 包裹**

结论：**N 个 App 放在同一条自动化里，是可行的，在 26.4 与 26.7 上都成立。**
具体哪个版本引入的**无法确定**（本机只装了 26.4 模拟器与 26.7 符号，没法二分）。

⚠️ **但单靠它没用** —— 原因见下一条。

### 2.2 触发器**不告诉**动作是哪个 App 触发的

这是代码级证据，不是传闻：

```
+[WFTrigger shortcutInputContentItemClass]   →  mov x0, #0x0 ; ret   （返回 nil）
```

基类返回 nil，全系统**只有四个**触发器覆盖它：
`WFEmailTrigger`、`WFMessageTrigger`、`WFExternalDisplayTrigger`、`WFWalletTransactionTrigger`。
**`WFAppInFocusTrigger` 不在其中**（`WFAppInBackgroundTrigger` 也不在）。

所以「App」触发器**不提供任何 shortcut input**。选中 N 个 App 时，那个数组只是
*配置*，事件本身不带任何"这次是哪个"的载荷。

这正好解释了社区里那条经验：邮件/信息自动化能拿到内容，App 自动化不能。
Apple 对 `Shortcut Input` 的定义也自洽 —— "applicable for shortcuts that are set to run **in another app**"。

> **推论**：`one-sec` / `Jomo` 那类 App 的文档都要求"**一条自动化只能选一个 App**"，
> 根因就在这里，不是它们偷懒。

### 2.3 App 值转成文本 = **本地化显示名**，不是 bundle id

```
+[WFAppStoreAppContentItem stringConversionBehavior]
   → coercingToStringWithDescription: @"Name and Store URL"
```

所以把一个 App 值丢进 `String` 参数，拿到的是「微信」（中文设备）而不是 `com.tencent.xin`。
**Bundle Identifier 是一个必须显式选择的属性**，不是默认值。
WorkflowKit 里定义的属性名有 `Bundle Identifier` / `App Name` / `Store URL`，
但 Apple 没有为 "App" 这个内容类型发布任何属性表。

⚠️ **本地化隐患**：设备语言一变，匹配键就变。任何要稳定标识的设计都必须用 bundle id。

### 2.4 AppIntents 没有 "App" 类型的参数（双向确认）

- 本机 iOS 26.4 `AppIntents.swiftinterface`（11752 行）里 grep
  `AppIdentifier` / `IntentAppDefinition` / `SystemIntentAppIdentifier` / `InstalledApp` / `struct App` —— **全部不存在**
- Apple 的 "Common data types" 页只有 `IntentPerson` / `IntentFile` / 媒体 / `IntentCurrencyAmount` /
  `IntentPaymentMethod` / `IntentItem*`，**没有 app 类型**
- OS 内部确实有 `IntentAppDefinition` / `SystemIntentAppIdentifier` 这两个名字，但它们**只作为
  系统内置 intent 的本地化 key** 存在于 WorkflowKit，**不在公开 SDK 里**，第三方无法声明
- 唯一能表示已安装 App 的公开类型是 `SystemShortcut`，但它**不透明**、只给配置 UI 用、
  只能在 widget 的 Button 里用，拿不到任何 App 身份

**可行的替代**：自己写 `AppEntity` + `EntityQuery` 暴露 App 列表，或者**直接收 `String`**。

---

## 3. 两条候选路线

两条路喂给 AppIntent 的都是**同一个 `String` 参数** —— 所以 **AppIntents 侧不用改结构**，
差别只在"匹配键是显示名还是 bundle id"，以及**用户在 Shortcuts 里怎么连**。

### 路线 A：留在 iOS 26.7，用「获取当前 App」

```
一条自动化
  触发器：App → 勾选全部想提醒的 App → 已打开 → 运行前询问【关】
  动作1：获取当前 App
  动作2：从输入获取文本（属性 = 名称）
  动作3：检查待办并提醒（App 名称 = 动作2 的输出）
```

- 「获取当前 App」是 **iOS 18.2 引入的官方动作**（iPadOS 18.2 / macOS 15.2 / watchOS 11.2 / visionOS 2.2 同期）
- 【一手】有亲历记述：在"立即运行 + 关通知"的**后台**自动化里，多选 App + 该动作能正确拿到
  触发者（打开设置 → 变量变成「设置」；打开照片 → 变成「照片」），**没有观察到竞态**
- **风险 1**：Apple **完全没有文档**说明它能在自动化里用，更没说后台场景下的行为
- **风险 2**：拿到的是**本地化显示名**
- **风险 3**：【一手】同一作者在 iOS 27 上**放弃了这个做法**，改用触发器自身的值。
  不过他那篇是讲 App 切换历史，"触发器更可靠"在那里是必然的，**不算干净的反证**
- **已排除**：**「已关闭」触发器不能用它**（App 关了就没有"当前 App"了），只能在"打开"时取值

### 路线 B：升到 iOS 27，用触发器自带的「Bundle Identifier」

```
一条自动化
  触发器：App → 勾选全部 App → 已打开 → 运行前询问【关】
  动作1：把【触发器变量】的「Bundle Identifier」属性拖进 → 检查待办并提醒
```

- 【一手】iOS 27 把触发器"统一并动作化"后，触发器可以**把自己的内容传给后续动作**；
  当触发器是「App」时，可用属性为：
  `名称(默认) / 运行中 / 隐藏 / 最前面 / 图标 / **バンドル識別子(Bundle Identifier)** /
  进程标识符 / 包路径 / 启动日期 / 窗口 / 显示器`
- 稳定、不受语言影响（原作者特意选 bundle id，理由是"应用名可能重名"）
- **风险 1**：**只有这一份来源**，Apple 一个字都没写。我亲自核过该文原文，
  `バンドル識別子` 确实在属性列表里，但**孤证**
- **风险 2**：iOS 27 把自动化从独立标签页搬进了快捷指令编辑器，
  【一手】社区有报告说升级后旧自动化（尤其"条件 + 快捷指令"型）会报错、需要重建
- **风险 3**：iOS 26 上**不存在**这个能力（二进制已证触发器不传任何东西），必须升级才行

### 附：路线 C（兜底，退无可退时）

每条自动化只选一个 App，App 名在自动化里**手打**——即当前形态。
若连 App 值 → String 的转换都不可用，这是我们已知能工作的最后手段。

---

## 4. ⏳ 待真机验证的实验（决定走 A 还是 B）

**5 分钟，纯 Shortcuts，不需要改任何代码。**

在手机上新建一条自动化：

| 设置 | 值 |
| --- | --- |
| 触发器 | App → **同时勾选两个 App**（如微信 + 支付宝）→ 勾「已打开」 |
| 动作 1 | 「获取当前 App」 |
| 动作 2 | 「从输入获取文本」，属性选**名称** |
| 动作 3 | 「显示通知」，内容填动作 2 |
| 运行前询问 | **关掉** |

然后**分别**打开那两个 App，看通知报的是不是对应的名字。

- **报对了** → 路线 A 成立（并且顺手证明了 2.1 的多选在真机可用）
- **报错了**（Shortcuts 自己 / 上一个 App / 空） → A 不成立，只剩 B 或 C
- **搜不到「获取当前 App」** → 系统低于 18.2

**顺便看一眼两件事**：

1. 在触发器那个变量上点开，属性列表里有没有 **Bundle Identifier**（有 → 你的系统已支持路线 B）
2. 该动作在当前系统上是否真的存在（`设置 → 通用 → 关于本机` 确认版本）

---

## 5. 无论走哪条路都要做的三件事

这三件事与上面的分叉无关，可以并行开工：

1. **连通性反馈** —— 绑定列表显示每条绑定的**最后触发时间**；从未触发过的标成
   「⚠️ 未接通」并给出排查步骤。当前最难受的症状就是"什么都不发生"，用户无从下手。
2. **内置图文向导** —— 分步说明，带 `shortcuts://create-automation` 深链
   （best-effort + 降级到 `shortcuts://`）。
3. **「运行前询问」单独占一屏强调** —— 漏掉这一步，每次打开目标 App 都弹确认框，
   功能等于不可用，而用户不会知道是自己漏了一步。

配套的数据模型改动：绑定需要同时保存**匹配键**（系统给的原样字符串，可能是显示名或 bundle id）
与**展示名**，匹配时按归一化后的键比。

---

## 6. 其他值得记住的坑

- **iOS 26.6 回归**：App 开关自动化大面积失效；26.6.1 修，报告不一。重装 Shortcuts 应用可恢复。【一手】
- **低电量模式 / 专注模式**会延迟甚至抑制自动化。【一手】
  这与 `01-poc-verification.md` 2f 那个专注模式静默投递的坑**同源**。
- **开机后约 2 分钟**内自动化不触发。【一手】
- **URL scheme / 深链打开 App 会触发**，且是已知的**无限循环陷阱**（自动化里再打开同一个 App 就会绕回去）。【一手】
- **控制中心 / 通知中心**在 26.6 上会误触发「已关闭」自动化（DTS 工程师在帖子里回复过）。【一手】
- **框架层有循环检测**：`-[WFTriggerManager storeLoopDetectionForTriggerWithIdentifier:loopDetected:]`，
  `WFConfiguredTrigger` 带 `potentialLoopDetected` / `shouldRecur` / `shouldPrompt`。[二进制]
- **没有任何 Apple 文档记载的速率限制或最小间隔**（但别当成"不存在"）。[二进制：无固定间隔常量]

---

## 7. 来源

**本地二进制（最高置信度，本次自行拆解）**
iOS 26.4 模拟器运行时 `WorkflowKit` / `WorkflowUI`；iOS 26.4 `AppIntents.swiftinterface`；
iOS 26.7 真机符号缓存 `~/Library/Developer/Xcode/iOS DeviceSupport/`。

**Apple 官方**
[Setting triggers](https://support.apple.com/guide/shortcuts/setting-triggers-apde31e9638b/ios) ·
[Add automations](https://support.apple.com/guide/shortcuts/add-automations-apdfbdbd7123/ios) ·
[Intro to personal automation](https://support.apple.com/guide/shortcuts/intro-to-personal-automation-apd690170742/ios) ·
[Enable or disable a personal automation](https://support.apple.com/guide/shortcuts/enable-or-disable-a-personal-automation-apd602971e63/9.0/ios/26) ·
[Content Graph engine](https://support.apple.com/guide/shortcuts/the-content-graph-engine-apd4618db957/ios) ·
[Share shortcuts](https://support.apple.com/guide/shortcuts/share-shortcuts-apdf01f8c054/ios) ·
[What's new in Shortcuts for iOS 18.2](https://support.apple.com/en-us/121131) ·
[What's new in Shortcuts 26](https://support.apple.com/en-us/125148) ·
[AppIntents common data types](https://developer.apple.com/documentation/appintents/common-data-types) ·
[SystemShortcut](https://developer.apple.com/documentation/appintents/systemshortcut)

**第三方（已在上文逐条标注置信度）**
[iOS 27 触发器属性（日）](https://blog.thetheorier.com/entry/ios27-automation) ·
[「获取当前 App」用法（日）](https://blog.thetheorier.com/entry/shortcuts-get-current-app) ·
[StackOverflow 69969746](https://stackoverflow.com/questions/69969746/) ·
[one-sec 教程](https://tutorials.one-sec.app/en/articles/3310146) ·
[Jomo 帮助](https://help.jomo.so/en/article/setup-an-automation-to-count-app-opens-117s5wo/) ·
[Apple 论坛 841128](https://developer.apple.com/forums/thread/841128)（正文被反爬挡住，仅搜索摘要）
