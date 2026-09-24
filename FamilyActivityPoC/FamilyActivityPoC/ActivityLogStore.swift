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
        self.logs = Self.load(from: fileURL)
    }

    /// 追加一条日志并落盘。
    func append(_ log: ActivityLog) {
        logs.insert(log, at: 0)
        save()
    }

    func clear() {
        logs.removeAll()
        save()
    }

    // MARK: - 持久化

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(logs)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // PoC 阶段不引入错误 UI；失败时留痕即可。
            print("[ActivityLogStore] save failed: \(error)")
        }
    }

    private static func load(from url: URL) -> [ActivityLog] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([ActivityLog].self, from: data)
        } catch {
            print("[ActivityLogStore] load failed: \(error)")
            return []
        }
    }
}
