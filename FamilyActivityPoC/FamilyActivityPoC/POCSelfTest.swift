import Foundation
import UserNotifications

/// 无头自检开关。
///
/// **为什么需要它**：本机没有开辅助功能权限（`osascript` 报 -1719），
/// `simctl` 也不提供触摸注入，所以「点击横幅上的按钮」这件事没法用真实点击来验证。
/// 于是把可验证的部分抽出来，用启动参数驱动。
///
/// **为什么结论仍然可信**：这些开关调用的不是另写的一套旁路逻辑，而是真实路径上的
/// 同一个函数 —— `LogAppOpenedIntent.perform()` 和 `TodoNotificationHandler.apply()`。
/// 两条路径的行为因此必然一致。
///
/// **它验证不了什么**（必须诚实标注）：iOS 会不会把按钮点击投递给
/// `userNotificationCenter(_:didReceive:)`。那一段是系统行为，只能在真机上用手指确认。
///
/// 用法（simctl / devicectl 均可）：
/// ```
/// --poc-self-test [App名]          走 Intent 完整链路：记日志 → 查绑定 → 发提醒
/// --poc-action-test done|later [App名]  模拟用户点了「完成」/「稍后再说」
/// --poc-dump-state                 把通知类别、已送达通知、绑定状态写入 poc-state.txt
/// ```
enum POCSelfTest {

    /// 解析启动参数并执行对应动作。返回 `true` 表示命中了自检开关。
    ///
    /// 保持 `nonisolated` 是有意的：App 的 `init()` 不是主线程隔离的，
    /// 需要主线程的部分各自用 `Task { @MainActor in ... }` 进入。
    static func runIfRequested(_ args: [String]) -> Bool {
        if let i = args.firstIndex(of: "--poc-self-test") {
            // 支持带一个 App 名参数，便于验证"查表 → 提醒"的完整链路
            let name = args.count > i + 1 ? args[i + 1] : "SelfTest"
            Task { _ = try? await LogAppOpenedIntent(appName: name).perform() }
            return true
        }

        if let i = args.firstIndex(of: "--poc-action-test") {
            // 第一位是按钮（done / later），第二位是 App 名。
            // 非 "done" 一律当 "later"，与产品语义一致：只有「完成」才改变状态。
            let button = args.count > i + 1 ? args[i + 1] : "later"
            let name = args.count > i + 2 ? args[i + 2] : ""
            let identifier = button == "done"
                ? TodoReminder.actionDone
                : TodoReminder.actionLater
            Task { @MainActor in
                TodoNotificationHandler.apply(actionIdentifier: identifier, appName: name)
            }
            return true
        }

        if args.contains("--poc-dump-state") {
            Task { await dumpState() }
            return true
        }

        return false
    }

    /// 把关键状态写成文本文件，便于用 `simctl` / `devicectl copy from` 取出来看。
    ///
    /// 写文件而不是打印到 stdout：真机上 `devicectl` 抓 stdout 很麻烦，
    /// 而读沙盒文件已有现成的取证流程（见 docs/01-poc-verification.md）。
    private static func dumpState() async {
        let center = UNUserNotificationCenter.current()
        let categories = await center.notificationCategories()
        let delivered = await center.deliveredNotifications()
        let bindings = await MainActor.run { TodoStore.shared.bindings }

        var lines: [String] = []

        // 系统侧的通知设置。"送达数有、但横幅看不到"这类问题的答案在这里。
        let settings = await center.notificationSettings()
        lines.append("NOTIFICATION SETTINGS: \(settings.pocSummary)")

        // 通知类别 —— 这是「横幅上有没有那两个按钮」的唯一凭据。
        // 类别里挂不上 action，横幅就只会有系统给的关闭按钮。
        if let category = categories.first(where: { $0.identifier == TodoReminder.categoryID }) {
            let actions = category.actions
                .map { "\($0.identifier) = \"\($0.title)\"" }
                .joined(separator: "; ")
            lines.append("CATEGORY \(TodoReminder.categoryID) ACTIONS: [\(actions)]")
        } else {
            lines.append("CATEGORY \(TodoReminder.categoryID): NOT REGISTERED")
        }

        lines.append("DELIVERED NOTIFICATIONS: \(delivered.count)")
        for note in delivered {
            let content = note.request.content
            lines.append(
                "  - title=\"\(content.title)\" body=\"\(content.body)\" "
                + "category=\(content.categoryIdentifier)"
            )
        }

        lines.append("BINDINGS: \(bindings.count)")
        for binding in bindings {
            lines.append(
                "  - app=\"\(binding.appName)\" isDone=\(binding.isDone) "
                + "todo=\"\(binding.todoText)\""
            )
        }

        let text = lines.joined(separator: "\n") + "\n"
        let fm = FileManager.default
        let dir = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory

        do {
            try text.write(
                to: dir.appendingPathComponent("poc-state.txt"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            print("[POCSelfTest] state write failed: \(error)")
        }
    }
}
