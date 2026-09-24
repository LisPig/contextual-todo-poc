import Foundation

/// 一条被记录下来的 activity 事件。
///
/// `source` 必须如实区分来源，否则 PoC 结论会失真（见 docs/00-feasibility-analysis.md A2/C 节）：
/// - `.shortcutIntent`：由 Shortcuts 个人自动化在「目标 App 被打开」时触发。
///   语义 = **App 被打开**。这是 Track B，也是本期唯一实现的路径。
/// - `.deviceActivity`：DeviceActivity 阈值回调。语义 = **累计使用达阈值**，不是「被打开」。
///   本期未实现（免费账号无 family-controls entitlement），保留该 case 以固定数据模型，
///   避免将来补做 Track A 时污染既有日志的语义。
struct ActivityLog: Codable, Identifiable, Hashable {
    enum Source: String, Codable {
        case shortcutIntent
        case deviceActivity

        var displayName: String {
            switch self {
            case .shortcutIntent: "Shortcuts 自动化"
            case .deviceActivity: "DeviceActivity 阈值"
            }
        }
    }

    let id: UUID
    let source: Source
    /// 人类可读的事件描述，例如 "Instagram opened"。
    let event: String
    /// 事件被记录的时刻。Track B 下即「App 被打开」的近似时刻。
    let timestamp: Date

    init(id: UUID = UUID(), source: Source, event: String, timestamp: Date = Date()) {
        self.id = id
        self.source = source
        self.event = event
        self.timestamp = timestamp
    }
}
