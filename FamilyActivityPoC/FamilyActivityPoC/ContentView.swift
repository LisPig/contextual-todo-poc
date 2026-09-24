import SwiftUI
import UserNotifications

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

#Preview {
    ContentView()
}
