import SwiftUI
import UserNotifications

@main
struct FamilyActivityPoCApp: App {

    init() {
        // 记录每次进程启动。排查"点了按钮没反应"时，这一行决定了排查方向：
        // 若点击后没有新的启动记录，说明系统压根没拉起本 App（问题在系统侧或用户已上划杀掉 App）；
        // 若有，才能继续往下看 apply 那条打点。
        POCTrace.log("app launched args=\(Array(CommandLine.arguments.dropFirst()))")

        // 通知类别必须在发出任何提醒前注册，否则通知不会带「完成 / 稍后再说」按钮。
        TodoReminder.registerCategory()

        // delegate 必须在 App 启动早期设置。
        // 用户点击通知上的按钮时，系统可能在后台把 App 拉起来 —— 那种情况下
        // 只有 delegate 已就位，点击回调才会被送达（见 TodoNotificationHandler）。
        UNUserNotificationCenter.current().delegate = TodoNotificationHandler.shared

        // 无头自检开关。具体开关与理由见 POCSelfTest.swift。
        _ = POCSelfTest.runIfRequested(CommandLine.arguments)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
