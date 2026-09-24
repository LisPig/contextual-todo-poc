import AppIntents
import Foundation

/// **产品核心动作**：由 Shortcuts 个人自动化在「目标 App 被打开」时调用，
/// 查出与该 App 绑定的待办，并发出带「完成 / 稍后再说」按钮的提醒。
///
/// 为什么由 Shortcuts 触发而不是 App 自己监听：iOS 没有公开 API 让 App
/// 监听第三方 App 的启动（见 docs/00-feasibility-analysis.md A0/A1）。
/// 真正的监听方是**系统 Shortcuts**，本 Intent 只是被它调用的执行末端。
///
/// `openAppWhenRun = false` 是刻意的：提醒用户不应该把用户从目标 App 弹走。
///
/// **v2 起它每次切换 App 都会被调用**：接线方式改成"一条自动化勾选全部 App"
/// （见 docs/03-shortcuts-setup-research.md），之后新增待办不用再碰 Shortcuts。
/// 代价落在本方法上 —— 绝大多数调用都是没绑定的 App，所以
/// **未命中路径必须绝对静默**：不发通知、不弹任何东西。守不住就从提醒变成骚扰。
struct LogAppOpenedIntent: AppIntent {

    static var title: LocalizedStringResource = "检查待办并提醒"

    static var description: IntentDescription = IntentDescription(
        "查出与该 App 绑定的待办事项，并弹出带「完成 / 稍后再说」的提醒。",
        categoryName: "待办提醒"
    )

    /// 不要抢占前台：提醒应该浮在目标 App 之上，而不是把用户切走。
    static var openAppWhenRun: Bool = false

    /// 为什么是 `String?` 而不是 `String`。
    ///
    /// 真机实测发现：若该参数**必填**，Shortcuts 会在每次自动化触发时
    /// 弹窗要求用户输入 App 名字 —— 这直接破坏了「打开即触发、零交互」的产品前提
    /// （第一次实测就是这样：弹窗后手动输入了 "poc" 才完成记录）。
    ///
    /// 注：App Intents 宏不支持在属性声明处写默认值（`var x: String = "..."` 会报
    /// `extra argument 'wrappedValue'`），所以用 Optional 而非默认值来达成"非必填"。
    @Parameter(title: "App 名称", description: "被打开的目标 App 名称，例如 微信")
    var appName: String?

    init() {}

    init(appName: String?) {
        self.appName = appName
    }

    func perform() async throws -> some IntentResult {
        let name = (appName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let display = name.isEmpty ? "(未指定 App)" : name

        // 一次主线程切换里做完"记录 + 查询"。
        // 拆成几次 `MainActor.run` 在这个方法里没有任何收益，只多付几次上下文切换。
        let binding = await MainActor.run { () -> TodoBinding? in
            // 1) 记一条"见过的 App"。这是用户新增待办时**唯一**的 App 来源，
            //    所以它比下面的日志重要得多。
            //
            //    空名不会被记进去（`record` 内部挡掉）：自动化没接「获取当前 App」时
            //    报的就是空串，若把它也记下来，"接线通没通"的判据就永远为真了。
            SeenAppStore.shared.record(name: name)

            // 2) 事件日志。产品上它不是主角，但用于回答"这次触发到底有没有发生"，
            //    也是 01-poc-verification.md 里所有实测结论的取证来源。
            ActivityLogStore.shared.append(ActivityLog(
                source: .shortcutIntent,
                event: name.isEmpty
                    ? "opened（没拿到 App 名 —— 自动化里可能没接「获取当前 App」）"
                    : "\(display) opened"
            ))

            // 3) 查这个 App 有没有**尚未完成**的待办
            return TodoStore.shared.pendingBinding(forAppNamed: name)
        }

        // 4) 有未完成待办才提醒；没有绑定、或已完成，就静默什么都不做。
        //
        // 这条打点用来回答"用户说不想再被提醒了，为什么还在提醒"：
        // 是压根没查到绑定（数据问题），还是查到了但状态仍是 pending（状态没改成功）。
        guard let binding else {
            POCTrace.log("perform app=\"\(display)\" -> 无未完成绑定，静默返回")
            return .result()
        }

        // 5) 发提醒前**只查权限，不请求权限**。
        //
        //    这是踩过的坑：这个 intent 是被 Shortcuts 在**后台**拉起来执行的，
        //    重装后权限还是 notDetermined，而后台弹不出授权框 ——
        //    `await requestAuthorization()` 会永远不返回，`post()` 根本执行不到，
        //    用户看到的是"什么都不发生"（docs/01 2e 有完整实测记录）。
        //    改成全选所有 App 之后这个 intent 每次切 App 都跑，而免费账号 7 天重签
        //    让"重装"成为常态，所以必须只查不请求。请求授权只从界面发起。
        guard await TodoReminder.canDeliver() else {
            let status = await TodoReminder.authorizationStatus()
            POCTrace.log(
                "perform app=\"\(display)\" -> 命中待办但通知不可用(auth=\(status.rawValue))，不发提醒"
            )
            return .result()
        }

        POCTrace.log("perform app=\"\(display)\" -> 命中待办 \"\(binding.todoText)\"，发提醒")

        // 用待办自身的 id 作投递标识符：同一条待办反复提醒时只保留最新一条通知，
        // 不会在通知中心堆重复（见 TodoReminder.post 的参数说明）。
        //
        // 标题用**本次触发的这个 App**，不是绑定里的第一个：一条待办绑了微信和 QQ 时，
        // 用户在微信里就该看到"打开 微信 时想起"。
        await TodoReminder.post(
            identifier: binding.id.uuidString,
            bindingID: binding.id,
            appName: display,
            todoText: binding.todoText
        )

        return .result()
    }
}

/// 把上面的 Intent 暴露到「快捷指令」，用户在 Shortcuts 里才能选到它。
struct POCShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogAppOpenedIntent(),
            phrases: [
                "用 \(.applicationName) 检查待办",
                "让 \(.applicationName) 检查待办"
            ],
            shortTitle: "检查待办并提醒",
            systemImageName: "checklist"
        )
    }
}
