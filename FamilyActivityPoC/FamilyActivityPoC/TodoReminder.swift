import Foundation
import UserNotifications

/// 待办提醒的通知通道。
///
/// **为什么必须用本地通知，而不是 Intent 的 `.result(dialog:)`**：
/// Shortcuts 弹出的对话框横幅**不支持自定义按钮**（只有系统给的关闭按钮）。
/// 产品要求「完成 / 稍后再说」两个选择，只有 `UNNotificationCategory` +
/// `UNNotificationAction` 能做到。
///
/// 本地通知不需要任何 entitlement，免费 Apple 账号可用（对照表中 Push notifications
/// 仅付费列有勾，本地通知不受此限）。
enum TodoReminder {

    /// 通知类别 ID。两个按钮挂在这个类别下。
    static let categoryID = "TODO_REMINDER"
    static let actionDone = "TODO_ACTION_DONE"
    static let actionLater = "TODO_ACTION_LATER"

    /// userInfo 里携带 App 名的 key。**v1 时期发出的通知只有这一个**，所以它必须一直能解析。
    static let appNameKey = "appName"

    /// userInfo 里携带绑定 id 的 key。v2 起优先用它定位待办。
    ///
    /// 为什么要加它：App 名只在"这条待办绑了哪些 App"没被改过时才靠得住。
    /// 用户改完绑定再点旧通知，按名字可能解析到别的待办、甚至解析不到；
    /// id 是稳定的。（App 名仍然要写进去：横幅标题要显示"打开 X 时想起"。）
    static let bindingIDKey = "bindingID"

    // MARK: - 注册

    /// 注册通知类别与按钮。**必须在发出任何提醒前调用**，否则通知不会带按钮。
    static func registerCategory() {
        let done = UNNotificationAction(
            identifier: actionDone,
            title: "完成",
            options: []          // 不需要跳前台：Handler 在后台直接改数据
        )
        let later = UNNotificationAction(
            identifier: actionLater,
            title: "稍后再说",
            options: []          // 不改变状态，下次打开该 App 会再次提醒
        )

        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [done, later],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: - 授权

    /// 请求通知权限。**只由界面调用**，绝不放在 Shortcuts 触发的路径上。
    ///
    /// 不加 `.provisional`：临时授权是**静默投递**（只进通知中心、不弹横幅），
    /// 而横幅正是这个功能的全部 —— 用户按了授权却什么都看不到，比明确没授权更难查。
    @discardableResult
    static func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            POCTrace.log("requestAuthorization granted=\(granted)")
            return granted
        } catch {
            POCTrace.log("requestAuthorization FAILED error=\(error)")
            print("[TodoReminder] requestAuthorization failed: \(error)")
            return false
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// 现在能不能真的把提醒弹出去。**只查不问。**
    ///
    /// 给"不该请求授权"的路径用 —— 也就是 Shortcuts 在后台拉起的那个 intent。
    /// 后台进程弹不出授权框，`requestAuthorization()` 会**永远不返回**
    /// （实测记录见 docs/01-poc-verification.md 2e），于是 `post()` 根本执行不到，
    /// 用户看到的是"什么都不发生"。请求授权只由界面发起。
    static func canDeliver() async -> Bool {
        switch await authorizationStatus() {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    // MARK: - 撤销

    /// 撤掉某条待办残留在通知中心的提醒。幂等，重复调用无副作用。
    ///
    /// **为什么需要它**：只有**点通知上的「完成」按钮**时，系统才会顺手把那条通知消掉。
    /// 在 App 界面里左滑标记完成、或删除绑定，系统都不管 —— 通知中心会留下一条
    /// "已经做完了的待办"。所以这两条路径必须显式调用本方法。
    static func cancel(identifier: String) {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    // MARK: - 发送

    /// 发出一条待办提醒。
    ///
    /// - Parameters:
    ///   - identifier: 投递标识符。**必须稳定**，这里传待办自身的 id。
    ///     iOS 的规则是「identifier 相同 → 覆盖旧通知；不同 → 新建一条」。
    ///     用随机 UUID 会让每次打开目标 App 都在通知中心留下一条，很快堆成十几条重复
    ///     （实测堆到 16 条）。改用待办 id 后只保留最新一条，
    ///     **而横幅照常每次都弹** —— 产品的提醒规则完全不变，只是不再堆积。
    ///   - appName: **本次触发它的那个 App 名**，用于横幅标题与点击时反查。
    ///     注意不是"绑定里的第一个 App"—— 一条待办绑了微信和 QQ 时，
    ///     用户在微信里就该看到"打开 微信 时想起"。
    ///   - bindingID: 待办自身的 id，写进 `userInfo` 供点击时精确定位
    ///   - todoText: 待办内容，即通知正文
    static func post(identifier: String, bindingID: UUID, appName: String, todoText: String) async {
        // 发送前先记下系统侧的通知设置。若真机上横幅不显示，这一行能直接指出
        // 是"权限/样式"被改了，而不是我们的代码没发出去。
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        POCTrace.log("post \(settings.pocSummary)")

        let content = UNMutableNotificationContent()
        content.title = "打开 \(appName) 时想起"
        content.body = todoText
        content.sound = .default
        content.categoryIdentifier = categoryID
        content.userInfo = [
            appNameKey: appName,
            bindingIDKey: bindingID.uuidString,
        ]

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil    // 立即送达
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            POCTrace.log("post FAILED app=\"\(appName)\" error=\(error)")
            print("[TodoReminder] post failed: \(error)")
        }
    }
}

extension UNNotificationSettings {

    /// 一行摘要，用于排查「通知明明发出去了，用户却说没看到」。
    ///
    /// **为什么不能只看送达数**：`deliveredNotifications()` 里有记录，
    /// 只能证明"通知进了通知中心"，**不能证明"横幅弹出来了"**。以下两个开关
    /// 会让通知静默进通知中心而不弹横幅，此时送达数照样增长：
    /// - `alertStyle == .none` —— 横幅被关掉
    /// - `scheduledDelivery == .enabled` —— 被「定时摘要」扣住，不即时弹出
    /// 真机上这两项都可能在重装 App 后被重置，所以必须单独取出来看。
    var pocSummary: String {
        "auth=\(Self.text(authorizationStatus))"
        + " alertStyle=\(Self.text(alertStyle))"
        + " alertSetting=\(Self.text(alertSetting))"
        + " center=\(Self.text(notificationCenterSetting))"
        + " lockScreen=\(Self.text(lockScreenSetting))"
        + " scheduledDelivery=\(Self.text(scheduledDeliverySetting))"
        + " sound=\(Self.text(soundSetting))"
    }

    private static func text(_ value: UNAuthorizationStatus) -> String {
        switch value {
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        @unknown default: "unknown(\(value.rawValue))"
        }
    }

    private static func text(_ value: UNNotificationSetting) -> String {
        switch value {
        case .notSupported: "notSupported"
        case .disabled: "DISABLED"
        case .enabled: "enabled"
        @unknown default: "unknown(\(value.rawValue))"
        }
    }

    private static func text(_ value: UNAlertStyle) -> String {
        switch value {
        case .none: "NONE(不弹横幅)"
        case .banner: "banner"
        case .alert: "alert"
        @unknown default: "unknown(\(value.rawValue))"
        }
    }
}

/// 处理用户对提醒的操作（「完成」/「稍后再说」）。
///
/// 必须在 App 启动早期设为 `UNUserNotificationCenter.delegate`，否则
/// App 被通知唤醒时收不到回调。
@MainActor
final class TodoNotificationHandler: NSObject, UNUserNotificationCenterDelegate {

    static let shared = TodoNotificationHandler()

    /// 把「用户按了哪个按钮」翻译成数据变更。
    ///
    /// 抽成独立函数是刻意的：本机无法做 UI 自动化（辅助功能权限未开），
    /// 点击按钮这件事没法用真实点击验证，只能从 `--poc-action-test` 无头调用。
    /// 让无头自检与 `didReceive` 共用**同一个函数**，两条路径的行为才必然一致；
    /// 否则"测试通过"不能推出"真机点击也正确"。
    ///
    /// - Parameters:
    ///   - bindingID: 通知里带的待办 id。v2 起优先用它；v1 的老通知没有，传 nil 走名字。
    ///   - appName: 通知里带的 App 名。只作为回退路径的匹配键。
    static func apply(actionIdentifier: String, bindingID: UUID?, appName: String) {
        // 打点位置很关键：这一行能执行，就证明"系统把点击投递过来了"。
        // 反之若真机日志里根本没有这一行，问题就不在业务逻辑，而在系统没拉起本 App。
        // `resolvedBy` 则回答另一个问题：「点了完成但没生效」是没定位到待办，
        // 还是定位到了但没改成功。
        POCTrace.log(
            "apply action=\(actionIdentifier) bindingID=\(bindingID?.uuidString ?? "nil") "
            + "app=\"\(appName)\" resolvedBy=\(resolution(bindingID: bindingID, appName: appName)) "
            + "before=\(snapshot())"
        )

        switch actionIdentifier {
        case TodoReminder.actionDone:
            // 完成后不再提醒 —— 产品明确要求
            if let bindingID, TodoStore.shared.binding(withID: bindingID) != nil {
                TodoStore.shared.markDone(id: bindingID)
            } else {
                TodoStore.shared.markDone(appNamed: appName)
            }

        case TodoReminder.actionLater, UNNotificationDefaultActionIdentifier:
            // 「稍后再说」保持"待办中"，下次切回该 App 会再次提醒。
            // 点通知本体（没点按钮）同样不改状态。两者都无需改动数据。
            break

        default:
            break
        }

        POCTrace.log("apply finished action=\(actionIdentifier) after=\(snapshot())")
    }

    /// 这一次点击能按 id 还是按 App 名定位到待办。纯粹用于取证。
    private static func resolution(bindingID: UUID?, appName: String) -> String {
        if let bindingID, TodoStore.shared.binding(withID: bindingID) != nil { return "id" }
        let key = TodoBinding.normalize(appName)
        if TodoStore.shared.bindings.contains(where: { $0.matches(appNamed: key) }) { return "name" }
        return "none"
    }

    /// 把当前绑定状态压成一行，用于对比操作前后。
    private static func snapshot() -> String {
        TodoStore.shared.bindings
            .map { "\($0.displayAppNames):\($0.isDone ? "done" : "pending")" }
            .joined(separator: ",")
    }

    /// 用户点击通知按钮（或点通知本体）时调用。
    /// 注意：App 可能因此被系统在后台拉起，这时也要能正确处理。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let appName = userInfo[TodoReminder.appNameKey] as? String ?? ""
        // v1 发出的通知没有这个键，读出来就是 nil，`apply` 会回退到按名字解析。
        let bindingID = (userInfo[TodoReminder.bindingIDKey] as? String)
            .flatMap(UUID.init(uuidString:))

        // 两个都没有就无从下手了（不该发生，但别把空名当匹配键传下去）。
        guard bindingID != nil || !appName.isEmpty else { return }

        Self.apply(actionIdentifier: response.actionIdentifier, bindingID: bindingID, appName: appName)
    }

    /// App 在前台时也把提醒显示成横幅，否则用户在 App 内就看不到提醒了。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
