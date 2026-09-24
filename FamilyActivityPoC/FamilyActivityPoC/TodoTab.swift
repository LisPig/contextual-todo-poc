import SwiftUI
import UserNotifications

// MARK: - 待办页

struct TodoTab: View {
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

    /// 请求授权，然后把结果状态读回来。
    ///
    /// **两步是一件事**：少了读回来那一步，界面上那句状态会停在「未决定」，
    /// 用户看到的是"点了没反应" —— 而权限其实已经给了。写在按钮闭包里的时候，
    /// 这两行看起来只是"两个并排的 await"，那层因果关系就丢了。
    private func requestPermission() {
        Task {
            await TodoReminder.requestAuthorization()
            notifStatus = await TodoReminder.authorizationStatus()
        }
    }

    private var permissionSection: some View {
        Section {
            // `LabeledContent` 而不是 `HStack { Text; Spacer; Text }`：
            // 这就是"左边标题、右边取值"这个标准形状，系统自己会处理两侧的对齐、
            // Dynamic Type 下的换行、以及将来可能的样式变化。
            LabeledContent("通知权限") {
                Text(notifStatusText)
                    .foregroundStyle(notifStatus == .authorized ? .green : .orange)
            }
            if notifStatus != .authorized {
                Button("请求通知权限", action: requestPermission)
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
                        // `.caption` 而不是 `.caption2`：后者系统自己都建议少用，
                        // 而且待办行那个 chevron 就是 `.caption` —— 同一屏上的两个箭头
                        // 不该是两种大小。
                        .font(.caption)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)          // 不加的话 header 会被渲染成链接蓝
            .foregroundStyle(.secondary)
            // 箭头是装饰、文字只有「已完成（N）」，于是**展开还是收起对 VoiceOver 是缺失的**。
            // 折叠控件不报状态，等于没报。把这层状态并进按钮自己的标签里。
            .accessibilityLabel(completedLabel)
        } footer: {
            // footer 与内容无关地渲染 —— 收着的时候它也在。所以要显式条件化。
            if showCompleted {
                Text("左滑「恢复待办」把它放回待办中，右滑删除。")
            }
        }
    }

    /// 折叠条对 VoiceOver 说的话。
    ///
    /// 必须是 `String` 而不是字面量拼接：`accessibilityLabel` 收到字面量时会走
    /// `LocalizedStringKey` 那条重载，而 `LocalizedStringKey + String` 是编不过的。
    /// 这里先算成一个 `String` 再传，走的就是 `StringProtocol` 那条。
    private var completedLabel: String {
        "已完成，共 \(store.completedBindings.count) 条，" + (showCompleted ? "已展开" : "已折叠")
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
                // 纯装饰的"这行可以点进去"指示符。VoiceOver 读它没有意义，
                // 而按钮本身的标签（待办内容 + App 芯片）已经把内容说全了。
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
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
