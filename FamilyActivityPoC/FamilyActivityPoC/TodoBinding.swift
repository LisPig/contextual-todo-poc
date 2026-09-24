import Foundation

/// 「App 名 ↔ 待办」的绑定。
///
/// 这是产品的核心数据模型：用户为某个 App 绑一条待办，打开那个 App 时收到提醒。
///
/// 生命周期（对应产品设计）：
/// - `isDone == false`：**待办中**。每次打开对应 App 都会提醒（"稍后再说"就是保持这个状态）。
/// - `isDone == true`：**已完成**。不再提醒。
///
/// 注意 `appName` 是**用户手写的字符串**（在「快捷指令」自动化的「App 名称」框里填的），
/// 不是 bundle id —— 因为 iOS 不给我们 bundle id（见 00-feasibility-analysis.md A2）。
/// 因此匹配时必须做归一化处理，见 `normalizedAppName`。
struct TodoBinding: Codable, Identifiable, Hashable {
    let id: UUID
    /// 绑定的 App 名，与自动化里填写的名字一致
    var appName: String
    /// 待办内容，即横幅/通知上要显示的文本
    var todoText: String
    /// 是否已完成。完成后不再提醒。
    var isDone: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        appName: String,
        todoText: String,
        isDone: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.appName = appName
        self.todoText = todoText
        self.isDone = isDone
        self.createdAt = createdAt
    }

    /// 用于匹配的归一化名称：去首尾空白 + 忽略大小写。
    /// 用户在自动化里可能写成 "WeChat" 或 "wechat"，不应因此漏提醒。
    var normalizedAppName: String {
        Self.normalize(appName)
    }

    static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
