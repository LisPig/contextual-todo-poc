import Foundation
import Observation

/// 日志持久化 + 内存缓存。
///
/// **为什么不用 App Group**：Track B 只有主 App target，`App Intent` 与 SwiftUI 界面
/// 运行在同一进程、同一沙盒容器内，不存在跨进程共享需求。App Group 是为
/// 「主 App ↔ Extension」通信引入的，本期没有 extension，故直接写沙盒
/// `Application Support`，少一个 capability、少一处签名风险。
/// （若将来补做 Track A，再改为 App Group 容器即可。）
@MainActor
@Observable
final class ActivityLogStore {
    static let shared = ActivityLogStore()

    /// 条数上限。
    ///
    /// **为什么必须封顶**：自动化改成"全选所有 App"之后，用户每切换一次 App
    /// 都会追加一条，而每次追加都会把整个数组重写成 JSON。不封顶的话这个文件
    /// 会跟着用机时长一起长，写入成本也跟着涨。封顶后它退化为**排查工具**，
    /// 不再是产品主角 —— 产品侧"有哪些 App"看 `SeenAppStore`。
    static let maxEntries = 300

    /// 最新的在最前，便于 UI 直接展示。
    private(set) var logs: [ActivityLog] = []

    private let fileURL: URL

    init(filename: String = "activity-log.json") {
        let fm = FileManager.default
        let dir = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory

        self.fileURL = dir.appendingPathComponent(filename)

        let stored = Self.read(from: fileURL)
        self.logs = stored.logs

        // 和 `TodoStore` 同一条规矩：读盘时截过上限就落回去，否则磁盘上会一直留着
        // 那个超长的旧文件。比较的是**文件字节**而不是中间结果 —— 中间结果已经被
        // 截过了，拿它自己跟自己比永远相等，等于没比。
        if stored.readable, stored.data != Self.encoded(logs) { save() }
    }

    /// 追加一条日志并落盘。
    func append(_ log: ActivityLog) {
        logs.insert(log, at: 0)
        if logs.count > Self.maxEntries {
            logs.removeLast(logs.count - Self.maxEntries)
        }
        save()
    }

    func clear() {
        logs.removeAll()
        save()
    }

    // MARK: - 持久化

    private func save() {
        guard let data = Self.encoded(logs) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // PoC 阶段不引入错误 UI；失败时留痕即可。
            print("[ActivityLogStore] save failed: \(error)")
        }
    }

    private static func encoded(_ logs: [ActivityLog]) -> Data? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(logs)
        } catch {
            print("[ActivityLogStore] encode failed: \(error)")
            return nil
        }
    }

    private struct LoadResult {
        var logs: [ActivityLog]
        var data: Data?
        /// 文件能不能解析。不能解析时保留原样，不回写。
        var readable: Bool
    }

    /// 读盘时也要截到上限：上限是后加的，改动之前留下的文件可能已经远超它，
    /// 不在这里截，它就永远瘦不回去。
    private static func read(from url: URL) -> LoadResult {
        guard let data = try? Data(contentsOf: url) else {
            return LoadResult(logs: [], data: nil, readable: false)
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let stored = try decoder.decode([ActivityLog].self, from: data)
            return LoadResult(logs: Array(stored.prefix(maxEntries)), data: data, readable: true)
        } catch {
            print("[ActivityLogStore] load failed: \(error)")
            return LoadResult(logs: [], data: data, readable: false)
        }
    }
}
