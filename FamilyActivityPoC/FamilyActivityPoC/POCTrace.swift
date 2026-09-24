import Foundation

/// 极简事件追踪，用于回答"这一步到底有没有发生"。
///
/// **为什么需要它**：真机上无法附加调试器。"用户点了「完成」但状态没变"这个问题，
/// 至少有三种完全不同的病因，且它们的修法互不相同：
///   ① 系统根本没把点击投递给 `didReceive`（App 压根没被拉起来）
///   ② 回调被调用了，但 `appName` 没匹配上（归一化/数据问题）
///   ③ 匹配上了也改了内存，但没落盘（持久化问题）
/// 靠猜无法区分。只有分别打点，才能把病因缩小到一个。
///
/// **与 `ActivityLog` 的区别**：`ActivityLog` 是产品语义的触发记录（进 UI、给人看）；
/// 这里是无结构的排查流水，只为取证，不参与任何产品逻辑，随时可以删。
enum POCTrace {

    private static let filename = "poc-trace.log"

    /// 追加一条带时间戳的记录。
    ///
    /// 每次调用都重新读-拼-原子写，写完立刻落盘：处理通知回调时进程随时可能被系统杀掉，
    /// 把内容缓冲在内存里就等于丢证据。
    /// 文件很小（每条一行），这个朴素写法不值得为性能做优化。
    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        // PID 必须带上：同一个 App 可能被系统反复拉起/回收，
        // 只有看 PID 才能判断"点按钮那次"和"打开 App 那次"是不是同一个进程，
        // 进而区分"内存状态没更新"和"根本没走到这段代码"。
        let pid = ProcessInfo.processInfo.processIdentifier
        write("[\(stamp)] pid=\(pid) \(message)")
    }

    private static func write(_ line: String) {
        let fm = FileManager.default
        guard let dir = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return }

        let url = dir.appendingPathComponent(filename)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (existing + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
