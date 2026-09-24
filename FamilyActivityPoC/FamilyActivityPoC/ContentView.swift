import SwiftUI
import UserNotifications

/// 最小可用界面。两个标签页：
/// - **待办**：管理「App ↔ 待办」绑定（产品的核心数据）
/// - **日志**：查看触发记录（验证/排查用）
@MainActor
struct ContentView: View {

    // 用普通引用而非 @State/@Bindable：两者都是单例，且界面只调用它们的方法、
    // 不需要属性级 Binding。@Observable 会在读取属性时自动建立依赖并触发刷新。
    private let todoStore = TodoStore.shared
    private let logStore = ActivityLogStore.shared
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        TabView {
            TodoTab(store: todoStore, notifStatus: $notifStatus)
                .tabItem { Label("待办", systemImage: "checklist") }

            LogTab(store: logStore)
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
    @Binding var notifStatus: UNAuthorizationStatus

    @State private var newAppName = ""
    @State private var newTodoText = ""

    /// 通知权限是否已就绪。中文提示比原始枚举值对用户友好。
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

    private var canAdd: Bool {
        !newAppName.trimmingCharacters(in: .whitespaces).isEmpty
            && !newTodoText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                permissionSection
                addSection
                bindingSection
            }
            .navigationTitle("待办提醒")
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
            Text("提醒必须靠通知弹出（Shortcuts 的对话框不支持自定义按钮），所以这个权限是必须的。")
        }
    }

    private var addSection: some View {
        Section {
            TextField("App 名称（须与自动化里填的完全一致）", text: $newAppName)
                .autocorrectionDisabled()
            TextField("待办内容，例如：给张总回消息", text: $newTodoText, axis: .vertical)
                .lineLimit(1...3)
            Button("添加绑定") {
                store.add(appName: newAppName, todoText: newTodoText)
                newAppName = ""
                newTodoText = ""
            }
            .disabled(!canAdd)
        } header: {
            Text("新增")
        } footer: {
            Text("同一个 App 只能有一条绑定。再次添加会覆盖原内容并重置为「待办中」。")
        }
    }

    private var bindingSection: some View {
        Section {
            if store.bindings.isEmpty {
                Text("还没有绑定任何待办。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.bindings) { binding in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(binding.todoText)
                            .font(.body)
                            .strikethrough(binding.isDone, color: .secondary)
                            .foregroundStyle(binding.isDone ? Color.secondary : Color.primary)
                        HStack(spacing: 8) {
                            Text(binding.appName)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                            Text(binding.isDone ? "已完成" : "待办中")
                                .font(.caption)
                                .foregroundStyle(binding.isDone ? Color.secondary : Color.orange)
                        }
                    }
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
            }
        } header: {
            Text("绑定（\(store.bindings.count)）")
        } footer: {
            Text("左滑标记完成/恢复，右滑删除。")
        }
    }
}

// MARK: - 日志页

private struct LogTab: View {
    let store: ActivityLogStore

    private static let timeFormat = Date.FormatStyle(date: .omitted, time: .standard)

    var body: some View {
        NavigationStack {
            List {
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
                                Text(log.timestamp.formatted(Self.timeFormat))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("触发日志（\(store.logs.count)）")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空", role: .destructive) { store.clear() }
                        .disabled(store.logs.isEmpty)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
