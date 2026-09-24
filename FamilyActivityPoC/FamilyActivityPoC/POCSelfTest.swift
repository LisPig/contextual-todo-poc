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
/// --poc-action-test done|later [App名] [绑定id]  模拟用户点了「完成」/「稍后再说」
/// --poc-dump-state                 把通知类别、已送达通知、绑定、检测到的 App 写入 poc-state.txt
/// --poc-migration-test             用真实解码器跑一组迁移 fixture，结果追加进 poc-state.txt
/// --poc-claim-test                 用临时文件跑一遍"一个 App 只属于一条待办"的写入路径
/// --poc-bulk-test [N]              连续调 N 次 perform()，验证日志/检测列表/追踪日志的封顶
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
            // 第一位是按钮（done / later），第二位是 App 名，第三位可选：绑定 id。
            // 非 "done" 一律当 "later"，与产品语义一致：只有「完成」才改变状态。
            //
            // 为什么 id 也要能传：v2 起通知里带的 id 是**首选**的解析路径，
            // 而"按名字解析"退化成了给 v1 老通知用的回退。两条路都得能无头验，
            // 否则"测试通过"只能推出回退分支是对的。
            let button = args.count > i + 1 ? args[i + 1] : "later"
            let name = args.count > i + 2 ? args[i + 2] : ""
            let bindingID = (args.count > i + 3 ? args[i + 3] : "").isEmpty
                ? nil
                : UUID(uuidString: args[i + 3])
            let identifier = button == "done"
                ? TodoReminder.actionDone
                : TodoReminder.actionLater
            Task { @MainActor in
                TodoNotificationHandler.apply(
                    actionIdentifier: identifier,
                    bindingID: bindingID,
                    appName: name
                )
            }
            return true
        }

        if args.contains("--poc-dump-state") {
            Task { await dumpState() }
            return true
        }

        if args.contains("--poc-migration-test") {
            Task { migrationTest() }
            return true
        }

        if args.contains("--poc-claim-test") {
            Task { await claimTest() }
            return true
        }

        if let i = args.firstIndex(of: "--poc-bulk-test") {
            // 在一个进程里连续调 N 次真实 `perform()`，用来看封顶有没有生效。
            // 逐次 `simctl launch` 也能测，但一次要几秒，几百次就不现实了。
            let count = args.count > i + 1 ? (Int(args[i + 1]) ?? 400) : 400
            Task {
                for n in 0..<count {
                    _ = try? await LogAppOpenedIntent(
                        appName: String(format: "App%03d", n)
                    ).perform()
                }
                await dumpState()
            }
            return true
        }

        return false
    }

    // MARK: - 状态快照

    /// 把关键状态写成文本文件，便于用 `simctl` / `devicectl copy from` 取出来看。
    ///
    /// 写文件而不是打印到 stdout：真机上 `devicectl` 抓 stdout 很麻烦，
    /// 而读沙盒文件已有现成的取证流程（见 docs/01-poc-verification.md）。
    private static func dumpState() async {
        let center = UNUserNotificationCenter.current()
        let categories = await center.notificationCategories()
        let delivered = await center.deliveredNotifications()
        let bindings = await MainActor.run { TodoStore.shared.bindings }
        let seenApps = await MainActor.run { SeenAppStore.shared.apps }

        var lines: [String] = []

        // 系统侧的通知设置。"送达数有、但横幅看不到"这类问题的答案在这里。
        let settings = await center.notificationSettings()
        lines.append("NOTIFICATION SETTINGS: \(settings.pocSummary)")

        // 日期到底渲染成什么语言。
        //
        // **为什么要在这里探一下**：界面上"共 7 次 · 最近 52 minutes ago"这种
        // 中英混排，只有跑起来才看得见，而本机没有触摸注入、日志页的第二个标签点不到
        // （`--poc-show-picker` 那类临时开关已经删掉，不为看一眼格式再挂回去）。
        // 同时打印 `Locale.current`：它是**没写死语系时会用的那个值**，
        // 与右侧固定中文的输出放在一起，"该不该跟随系统"一眼可判。
        let probe = Date(timeIntervalSinceNow: -52 * 60)
        lines.append(
            "LOCALE: current=\(Locale.current.identifier)"
            + " relative=\"\(probe.formatted(POCFormat.relative))\""
            + " time=\"\(probe.formatted(POCFormat.time))\""
        )

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
            let bindingID = content.userInfo[TodoReminder.bindingIDKey] as? String ?? "nil"
            lines.append(
                "  - title=\"\(content.title)\" body=\"\(content.body)\" "
                + "category=\(content.categoryIdentifier) bindingID=\(bindingID)"
            )
        }

        // 括号里的两个数是**展示投影**的划分（`pendingBindings` / `completedBindings`）。
        // 下面逐条列表仍是**存储顺序** —— 那三处取证输出依赖它，不能动；
        // 这两个数只是让"投影是对 bindings 的划分"这件事进入取证链。
        let split = await MainActor.run {
            (pending: TodoStore.shared.pendingBindings.count,
             done: TodoStore.shared.completedBindings.count)
        }
        lines.append("BINDINGS: \(bindings.count) (pending=\(split.pending) done=\(split.done))")
        for binding in bindings {
            lines.append(
                "  - id=\(binding.id.uuidString) apps=[\(binding.displayAppNames)] "
                + "isDone=\(binding.isDone) todo=\"\(binding.todoText)\""
            )
        }

        // 「见过的 App」—— 接线到底通没通的判据就在这里。
        lines.append("SEEN APPS: \(seenApps.count)")
        for app in seenApps {
            lines.append(
                "  - name=\"\(app.name)\" count=\(app.seenCount) own=\(app.isOwnApp) "
                + "last=\(ISO8601DateFormatter().string(from: app.lastSeenAt))"
            )
        }

        write(lines.joined(separator: "\n") + "\n", append: false)
    }

    // MARK: - 迁移测试

    /// 拿一组固定输入过**真实的解码器**，把结果写下来。
    ///
    /// **为什么值得为它单独开一个开关**：本工程没有测试 target（只有一个 app target），
    /// 而"旧文件还能不能读回来"这件事只能靠实跑 —— 迁移写错的后果是
    /// `TodoStore.load` 兜底 `return []`，也就是**用户所有绑定静默消失**，
    /// 界面上看不出任何异常。宁可在这里把边界摆出来跑一遍。
    ///
    /// 注意它验证的是 `TodoBinding` 的解码 + `LenientElement` 的逐条容错，
    /// **不经过** `TodoStore` 的实例（否则会污染真实数据）。
    private static func migrationTest() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // 三条 id 固定下来，便于在输出里对照哪个 fixture 的哪一条被丢了
        let a = UUID().uuidString
        let b = UUID().uuidString
        let c = UUID().uuidString

        let fixtures: [(String, String)] = [
            ("v1：单个 appName（旧文件）", """
             [{"id":"\(a)","appName":"微信","todoText":"给张总回消息","isDone":false,"createdAt":"2026-09-24T00:00:00Z"}]
             """),
            ("v2：多 App", """
             [{"id":"\(a)","appNames":["微信","QQ"],"todoText":"回消息","isDone":false,"createdAt":"2026-09-24T00:00:00Z"}]
             """),
            ("v2：空数组（合法）", """
             [{"id":"\(a)","appNames":[],"todoText":"还没选 App","isDone":false,"createdAt":"2026-09-24T00:00:00Z"}]
             """),
            ("归一化：空白 + 大小写 + 空串去重", """
             [{"id":"\(a)","appNames":[" 微信 ","微信","","WeChat","wechat"],"todoText":"去重","isDone":false,"createdAt":"2026-09-24T00:00:00Z"}]
             """),
            ("一条坏的夹在两条好的中间", """
             [{"id":"\(a)","appNames":["微信"],"todoText":"好的1","isDone":false,"createdAt":"2026-09-24T00:00:00Z"},
              {"id":"\(b)","appNames":["QQ"],"todoText":"坏的：isDone 是字符串","isDone":"yes","createdAt":"2026-09-24T00:00:00Z"},
              {"id":"\(c)","appNames":["支付宝"],"todoText":"好的2","isDone":false,"createdAt":"2026-09-24T00:00:00Z"}]
             """),
            ("缺 todoText（必填字段缺失）", """
             [{"id":"\(a)","appNames":["微信"],"isDone":false,"createdAt":"2026-09-24T00:00:00Z"}]
             """),
            ("整个文件不是 JSON", "not json at all"),
        ]

        var lines = ["", "MIGRATION TEST (走真实的 TodoBinding 解码器):"]
        for (label, json) in fixtures {
            let data = Data(json.utf8)
            guard let decoded = try? decoder.decode([LenientElement<TodoBinding>].self, from: data) else {
                // 这条走的是 `TodoStore.load` 的兜底分支：文件整体不可读 → 返回 []。
                lines.append("  [\(label)] 整体解码失败 → TodoStore 会兜底返回 []（数据全丢）")
                continue
            }
            let good = decoded.compactMap(\.value)
            let dropped = decoded.count - good.count
            lines.append("  [\(label)] 解出 \(good.count) 条，丢掉 \(dropped) 条")
            for binding in good {
                lines.append("      apps=[\(binding.displayAppNames)] todo=\"\(binding.todoText)\"")
            }
        }

        write(lines.joined(separator: "\n") + "\n", append: true)
    }

    // MARK: - 不变量（写入侧）

    /// 走**真实的 store API**，把"一个 App 只能属于一条待办"这条不变量的写入路径跑一遍。
    ///
    /// **为什么要单独做这个**：这条不变量有两个执行点 —— 写入时（`add` / `update` /
    /// `markPending` 里的 `claim`）和加载时（`sanitizeInvariant`）。加载时那条只对
    /// 旧数据/被手工改过的文件生效，**日常走的恰恰是写入那条**，而写入路径只有界面能触发，
    /// 本机点不了。不验它，就等于把最常走的那条路留成了未验证。
    ///
    /// 用**独立的临时文件**建一个 store 实例，绝不碰用户的真实绑定。
    @MainActor
    private static func claimTest() async {
        let url = stateFileURL.deletingLastPathComponent()
            .appendingPathComponent("poc-claim-test.json")
        try? FileManager.default.removeItem(at: url)   // 每次从空开始，结果可重复

        var out: [String] = []
        let store = TodoStore(filename: "poc-claim-test.json")

        func snapshot(_ label: String) {
            let state = store.bindings
                .map { "\($0.todoText)→[\($0.displayAppNames)]\($0.isDone ? "(done)" : "")" }
                .joined(separator: "   ")
            out.append("  \(label)：\(state)")
        }

        let a = store.add(appNames: ["微信", "QQ"], todoText: "待办A")
        snapshot("1 建 A＝微信+QQ")

        let b = store.add(appNames: ["微信", "支付宝"], todoText: "待办B")
        snapshot("2 建 B＝微信+支付宝（微信应从 A 被摘走）")

        if let a { store.update(id: a, appNames: ["支付宝", "QQ"], todoText: "待办A") }
        snapshot("3 A 改绑＝支付宝+QQ（支付宝应从 B 被摘走）")

        if let b { store.markDone(id: b) }
        snapshot("4 B 完成（完成期间不再占着微信，但自己仍记着）")

        if let a { store.update(id: a, appNames: ["微信"], todoText: "待办A") }
        snapshot("5 A 改绑＝微信（B 已完成，不构成冲突）")

        if let b { store.markPending(id: b) }
        snapshot("6 B 恢复待办（B 抢回微信，A 应变空但**不消失**）")

        write("\nCLAIM TEST（真实 store 的写入路径）:\n" + out.joined(separator: "\n") + "\n", append: true)
    }

    // MARK: - 文件

    private static var stateFileURL: URL {
        let fm = FileManager.default
        let dir = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        return dir.appendingPathComponent("poc-state.txt")
    }

    private static func write(_ text: String, append: Bool) {
        let url = stateFileURL
        let payload = append ? ((try? String(contentsOf: url, encoding: .utf8)) ?? "") + text : text
        do {
            try payload.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("[POCSelfTest] state write failed: \(error)")
        }
    }
}
