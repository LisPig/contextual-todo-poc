import SwiftUI
import UserNotifications

/// 两个标签页共用的时间格式。
///
/// 原来它只写在 `LogTab` 里（`private static let`）。检测到的 App 列表要用同样的格式，
/// 而 `AppPickerSheet` 在另一个文件里、拿不到 file-private 的成员，所以提到文件级。
enum POCFormat {

    /// 日期格式固定用中文，**不跟随系统语言**。
    ///
    /// **为什么必须写死**：本 App 没有任何本地化 —— `Bundle.main` 没声明
    /// `CFBundleLocalizations`，工程里也没有一处 `.strings`（界面文案全是中文字面量）。
    /// 这种情况下 `Locale.current` 会落到开发区域，于是**即使手机语言是中文**，
    /// `Date.RelativeFormatStyle` 也渲染成 "52 minutes ago"，
    /// 和它前后那些写死的中文拼在一起。
    ///
    /// 实测过、不是推测：把模拟器语言切成简体中文（`AppleLanguages = (zh-Hans)`）后重装重启，
    /// 日期照样是英文。详见 docs/01-poc-verification.md 的 v2 UI 证据段。
    ///
    /// 将来真要做多语言时，正确做法是补上本地化再删掉这个常量，
    /// 而不是让它继续跟着开发区域走。
    private static let locale = Locale(identifier: "zh_Hans_CN")

    static let time: Date.FormatStyle = .init(date: .omitted, time: .standard, locale: locale)
    static let relative: Date.RelativeFormatStyle = .init(presentation: .named, locale: locale)
}

/// 最小可用界面。两个标签页：
/// - **待办**：写待办、从检测到的 App 里选绑谁（产品的核心数据）
/// - **日志**：检测到的 App + 触发记录（验证/排查用）
@MainActor
struct ContentView: View {

    // 用普通引用而非 @State/@Bindable：都是单例，且界面只调用它们的方法、
    // 不需要属性级 Binding。@Observable 会在读取属性时自动建立依赖并触发刷新。
    private let todoStore = TodoStore.shared
    private let logStore = ActivityLogStore.shared
    private let seenStore = SeenAppStore.shared
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        TabView {
            TodoTab(store: todoStore, seenStore: seenStore, notifStatus: $notifStatus)
                .tabItem { Label("待办", systemImage: "checklist") }

            LogTab(store: logStore, seenStore: seenStore)
                .tabItem { Label("日志", systemImage: "list.bullet.rectangle") }
        }
        .task {
            notifStatus = await TodoReminder.authorizationStatus()
        }
    }
}

// MARK: - 待办页

private struct TodoTab: View {
    let store: TodoStore
    let seenStore: SeenAppStore
    @Binding var notifStatus: UNAuthorizationStatus

    /// 一个视图上只挂**一个** `.sheet(item:)`。
    ///
    /// 两个独立的 `.sheet(isPresented:)` 挂在同一个视图上时，能不能都弹得出来
    /// 取决于渲染时序，是个很难查的坑。用一个枚举把"现在该弹哪个"说明白，就不用赌它。
    private enum Sheet: Identifiable {
        case guide
        /// 新增待办。输入框、草稿、选择器全在 `NewTodoSheet` 里面，本视图不持有它们。
        case newTodo
        /// 只用于**已有**待办的改绑。新建流程走 `NewTodoSheet` 里 push 的选择器，
        /// 不再经过这里，所以 id 不再是 optional。
        case picker(UUID)

        var id: String {
            switch self {
            case .guide: "guide"
            case .newTodo: "newTodo"
            case .picker(let id): "picker-\(id.uuidString)"
            }
        }
    }

    @State private var sheet: Sheet?
    /// 「已完成」那段是否展开。默认收着；不落盘、不跨启动保留。
    @State private var showCompleted = false

    var body: some View {
        NavigationStack {
            List {
                wiringSection
                permissionSection
                pendingSection
                // 已完成为空时**整段不出现**：「已完成（0）」点开什么都没有，是纯噪音；
                // 而且这样一来，没有已完成条目时界面与改造前一模一样。
                if !store.completedBindings.isEmpty {
                    completedSection
                }
            }
            .navigationTitle("待办提醒")
            .toolbar {
                // 一个 `ToolbarItemGroup` 而不是两个 `ToolbarItem`：组内按声明顺序从左到右，
                // 于是 ＋ 确定落在最右（"右上角 ＋"）。两个同 placement 的独立 item
                // 横向顺序由 bar 决定，而且 iOS 26 下会渲染成两个各带间隙的玻璃胶囊，
                // 看起来不像相邻的两个图标。
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { sheet = .guide } label: {
                        Label("接线指引", systemImage: "questionmark.circle")
                    }
                    Button { sheet = .newTodo } label: {
                        Label("新增待办", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $sheet) { which in
                switch which {
                case .guide:
                    SetupGuideView()
                case .newTodo:
                    NewTodoSheet(store: store, seenStore: seenStore)
                case .picker(let id):
                    AppPickerSheet(
                        title: "改绑 App",
                        apps: seenStore.detectedApps,
                        claimed: store.claimedAppNames(excludingID: id),
                        currentNames: store.binding(withID: id)?.appNames ?? [],
                        onCommit: { commit($0, for: id) }
                    )
                }
            }
        }
    }

    /// 改绑弹窗按下「完成」：立刻写回。
    ///
    /// 只有**已有**待办走这里。新建流程在 `NewTodoSheet` 里就地攒草稿，选了 App 也不落库，
    /// 直到点「添加」才 `store.add` —— 所以这里不再有"改草稿还是改库"的分支。
    private func commit(_ selection: Set<String>, for id: UUID) {
        guard let binding = store.binding(withID: id) else { return }
        store.update(id: id, appNames: selection.sorted(), todoText: binding.todoText)
    }

    // MARK: 接线状态

    /// 只在"一次触发都没到过"时报警。
    ///
    /// 这是唯一能准确判断"自动化没建好 / 「运行前询问」没关"的信号：
    /// 接线真的通了的话，用户切一次 App 就会留下记录。
    private var wiringSection: some View {
        Section {
            Button { sheet = .guide } label: {
                if seenStore.hasAnyTrigger {
                    Label("自动化接线指引", systemImage: "questionmark.circle")
                } else {
                    Label("接线还没通 —— 点这里看步骤", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        } footer: {
            if seenStore.hasAnyTrigger {
                Text("已检测到 \(seenStore.detectedApps.count) 个 App。接线只需做一次，"
                     + "以后新增待办都不用再碰「快捷指令」。")
            } else {
                Text("一次触发都还没收到过。先把「快捷指令」里的那条自动化建好"
                     + "（关键是关掉「运行前询问」），之后随便打开一个 App，这里就会变。")
            }
        }
    }

    // MARK: 通知权限

    private var notifStatusText: String {
        switch notifStatus {
        case .authorized: "已授权"
        case .denied: "已拒绝（提醒无法弹出）"
        case .provisional: "临时授权"
        case .ephemeral: "临时"
        case .notDetermined: "未决定"
        @unknown default: "未知"
        }
    }

    private var permissionSection: some View {
        Section {
            HStack {
                Text("通知权限")
                Spacer()
                Text(notifStatusText)
                    .foregroundStyle(notifStatus == .authorized ? .green : .orange)
            }
            if notifStatus != .authorized {
                Button("请求通知权限") {
                    Task {
                        await TodoReminder.requestAuthorization()
                        notifStatus = await TodoReminder.authorizationStatus()
                    }
                }
            }
        } footer: {
            Text("提醒必须靠通知弹出（Shortcuts 的对话框不支持自定义按钮），所以这个权限是必须的。"
                 + "注意：Shortcuts 在后台调起本 App 时弹不出授权框，所以只能在这里授权 —— "
                 + "没授权的话，打开目标 App 会毫无反应。")
        }
    }

    // MARK: 待办中

    private var pendingSection: some View {
        Section {
            if store.pendingBindings.isEmpty {
                // 两种情况分开说：一条待办都没有，vs 只剩已完成的。
                // 后者不能只留一个光秃秃的 header —— 看起来像渲染坏了。
                Text(store.completedBindings.isEmpty ? "还没有待办。" : "没有待办中的条目。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.pendingBindings) { binding in
                    row(binding)
                }
            }
        } header: {
            Text("待办中（\(store.pendingBindings.count)）")
        } footer: {
            Text("点一条可以改它绑的 App。左滑标记完成，右滑删除。")
        }
    }

    // MARK: 已完成（默认折叠）

    /// 手搓折叠，不用 `DisclosureGroup`、也不用 `Section(isExpanded:)`：
    /// - `DisclosureGroup` 在 List 里把内容当作**那一行的 content** 渲染，子行的 `swipeActions`
    ///   不再表现为"对这一行滑动"，而这里必须有左滑「恢复待办」/右滑「删除」。
    /// - `Section(isExpanded:)` 是平台原生的折叠 Section，但万一 header 的展开控件在某种
    ///   list style 下不渲染，section 会变成**永久折叠且无法展开** —— 一个"看起来正常、
    ///   内容永远消失"的失败。手搓十行，确定性优先。
    private var completedSection: some View {
        Section {
            if showCompleted {
                ForEach(store.completedBindings) { binding in
                    row(binding)
                }
            }
        } header: {
            // 整行可点，而不是只有那个小箭头可点 —— 折叠条的点击目标就该有一行那么高。
            Button { showCompleted.toggle() } label: {
                HStack(spacing: 6) {
                    Text("已完成（\(store.completedBindings.count)）")
                    Image(systemName: showCompleted ? "chevron.down" : "chevron.forward")
                        .font(.caption2)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)          // 不加的话 header 会被渲染成链接蓝
            .foregroundStyle(.secondary)
        } footer: {
            // footer 与内容无关地渲染 —— 收着的时候它也在。所以要显式条件化。
            if showCompleted {
                Text("左滑「恢复待办」把它放回待办中，右滑删除。")
            }
        }
    }

    /// 两段共用同一份行构造（与改造前逐字相同），所以"swipeActions 还能不能用"不存在。
    private func row(_ binding: TodoBinding) -> some View {
        bindingRow(binding)
            .swipeActions(edge: .trailing) {
                Button("删除", role: .destructive) { store.remove(id: binding.id) }
            }
            .swipeActions(edge: .leading) {
                if binding.isDone {
                    Button("恢复待办") { store.markPending(id: binding.id) }
                        .tint(.orange)
                } else {
                    Button("标记完成") { store.markDone(id: binding.id) }
                        .tint(.green)
                }
            }
    }

    private func bindingRow(_ binding: TodoBinding) -> some View {
        Button { sheet = .picker(binding.id) } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(binding.todoText)
                        .strikethrough(binding.isDone, color: .secondary)
                        .foregroundStyle(binding.isDone ? Color.secondary : Color.primary)

                    if binding.appNames.isEmpty {
                        // 空数组是合法状态（App 被另一条待办抢走了），不是错误。
                        // 如实说清"不会提醒"，但**绝不**替用户把它删掉。
                        Text("未选择 App（不会提醒）")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        AppChipsView(
                            names: binding.appNames,
                            tint: binding.isDone ? .secondary : .accentColor
                        )
                    }

                    if let missing = neverSeenName(in: binding) {
                        Text("「\(missing)」系统还没上报过 —— 可能改过名或换了设备语言，点这里重选")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Text(binding.isDone ? "已完成" : "待办中")
                        .font(.caption)
                        .foregroundStyle(binding.isDone ? Color.secondary : Color.orange)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    /// 这条待办绑的名字里，有没有系统从没上报过的。
    ///
    /// 只在**已经有过任何触发**的前提下才提示。一次都没触发过的话，问题在接线，
    /// 界面顶部那条橙色警告已经在说了 —— 这里再报一遍只会让人以为"这条待办坏了"。
    ///
    /// 措辞是提示、不是断线判决：用户还没打开过那个 App 时同样没有记录。
    private func neverSeenName(in binding: TodoBinding) -> String? {
        guard seenStore.hasAnyTrigger else { return nil }
        return binding.appNames.first { !seenStore.hasSeen(appNamed: $0) }
    }
}

// MARK: - 日志页

private struct LogTab: View {
    let store: ActivityLogStore
    let seenStore: SeenAppStore

    var body: some View {
        NavigationStack {
            List {
                seenSection
                eventSection
            }
            .navigationTitle("日志")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // 只清事件日志。「检测到的 App」不清 —— 它是新增待办时唯一的
                    // App 来源，误清一次就得靠重新打开一堆 App 才长得回来。
                    Button("清空日志") { store.clear() }
                        .disabled(store.logs.isEmpty)
                }
            }
        }
    }

    private var seenSection: some View {
        Section {
            if seenStore.apps.isEmpty {
                Text("还没有检测到任何 App。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(seenStore.apps) { app in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(app.name)
                            if app.isOwnApp {
                                Text("本 App")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        Text("共 \(app.seenCount) 次 · 最近 \(app.lastSeenAt.formatted(POCFormat.relative))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("检测到的 App（\(seenStore.apps.count)）")
        } footer: {
            Text("自动化每次把「当前 App」报上来就记一条，按名字去重、最多留 \(SeenAppStore.maxEntries) 条。"
                 + "本 App 自己也会出现在这里 —— 自动化勾了全部 App，所以这是正常的，"
                 + "它不会出现在选择器里。")
        }
    }

    private var eventSection: some View {
        Section {
            if store.logs.isEmpty {
                Text("尚无记录。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.logs) { log in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(log.event)
                        HStack(spacing: 8) {
                            Text(log.source.displayName)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                            Text(log.timestamp.formatted(POCFormat.time))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("触发日志（\(store.logs.count)）")
        }
    }
}

#Preview {
    ContentView()
}
