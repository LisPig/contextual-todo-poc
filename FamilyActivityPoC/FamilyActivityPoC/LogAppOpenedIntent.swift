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

        // 1) 保留事件日志。产品上它不是主角，但用于验证"这次触发有没有发生"很有价值，
        //    也是 01-poc-verification.md 里所有实测结论的取证来源。
        let log = ActivityLog(source: .shortcutIntent, event: "\(display) opened")
        await MainActor.run {
            ActivityLogStore.shared.append(log)
        }

        // 2) 查这个 App 是否绑定了**尚未完成**的待办。
        let binding = await MainActor.run {
            TodoStore.shared.pendingBinding(forAppNamed: display)
        }

        // 3) 有未完成待办才提醒；没有绑定、或已完成，就静默什么都不做。
        //
        // 这两条打点用来回答"用户说不想再被提醒了，为什么还在提醒"：
        // 是压根没查到绑定（数据问题），还是查到了但状态仍是 pending（状态没改成功）。
        guard let binding else {
            POCTrace.log("perform app=\"\(display)\" -> 无未完成绑定，静默返回")
            return .result()
        }
        POCTrace.log("perform app=\"\(display)\" -> 命中待办 \"\(binding.todoText)\"，发提醒")

        await TodoReminder.requestAuthorization()
        await TodoReminder.post(appName: binding.appName, todoText: binding.todoText)

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
