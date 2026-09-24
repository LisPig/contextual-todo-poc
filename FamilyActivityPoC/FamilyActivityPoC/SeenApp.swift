import Foundation

/// 系统上报过的一个 App。
///
/// **它从哪来**：Shortcuts 自动化每次调用 `LogAppOpenedIntent` 时，
/// 「获取当前 App」动作把触发者的**显示名**报进来，这里就记一条。
///
/// **为什么必须单独存**（不能从 `ActivityLog` 里推）：自动化改成"全选所有 App"之后，
/// 用户每切一次 App 都会触发一次 intent，事件日志会飞速增长、必须封顶；
/// 而"见过哪些 App"要求**长期不丢** —— 它是「新增待办」唯一的 App 来源
/// （v2 起用户不再手输 App 名）。两者的保留策略正好相反，所以拆成两个存储。
struct SeenApp: Codable, Identifiable, Hashable {
    /// 系统上报的**原样**名字（本地化显示名）。
    /// 之所以不只留归一化结果：这是要展示给用户看、并原样写进绑定的值。
    var name: String
    var firstSeenAt: Date
    var lastSeenAt: Date
    var seenCount: Int
    /// 是不是本 App 自己。自动化全选之后，打开本 App 也会触发一次。
    var isOwnApp: Bool = false

    /// 按归一化名字去重：同一台设备上 "WeChat" 和 "wechat" 是同一个 App。
    var id: String { TodoBinding.normalize(name) }
}
