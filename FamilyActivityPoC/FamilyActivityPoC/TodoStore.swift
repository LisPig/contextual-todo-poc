import Foundation
import Observation

/// 待办绑定的持久化 + 内存缓存。
///
/// 与 `ActivityLogStore` 同样直接写沙盒 `Application Support`，不用 App Group
/// （Track B 无 extension，Intent 与 UI 同进程，见 docs/00-feasibility-analysis.md C 节）。
///
/// **关键**：这个 store 会被两个上下文访问 —— SwiftUI 界面，以及 Shortcuts 在后台
/// 调起 Intent 时的 `perform()`。两者都在主线程（`@MainActor`），因此不需要额外加锁。
@MainActor
@Observable
final class TodoStore {
    static let shared = TodoStore()

    private(set) var bindings: [TodoBinding] = []

    private let fileURL: URL

    init(filename: String = "todo-bindings.json") {
        let fm = FileManager.default
        let dir = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory

        self.fileURL = dir.appendingPathComponent(filename)
        self.bindings = Self.load(from: fileURL)
    }

    // MARK: - 查询

    /// 按 App 名查找**尚未完成**的绑定。
    /// 完成后不再提醒是产品明确要求，所以这里直接过滤掉 `isDone`。
    func pendingBinding(forAppNamed appName: String) -> TodoBinding? {
        let key = TodoBinding.normalize(appName)
        guard !key.isEmpty else { return nil }
        return bindings.first { $0.normalizedAppName == key && !$0.isDone }
    }

    // MARK: - 变更

    func add(appName: String, todoText: String) {
        let trimmedApp = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTodo = todoText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedApp.isEmpty, !trimmedTodo.isEmpty else { return }

        // 同一个 App 只保留一条绑定：已存在则覆盖内容并重置为待办中。
        let key = TodoBinding.normalize(trimmedApp)
        if let idx = bindings.firstIndex(where: { $0.normalizedAppName == key }) {
            bindings[idx].appName = trimmedApp
            bindings[idx].todoText = trimmedTodo
            bindings[idx].isDone = false
        } else {
            bindings.append(TodoBinding(appName: trimmedApp, todoText: trimmedTodo))
        }
        save()
    }

    func markDone(id: UUID) {
        guard let idx = bindings.firstIndex(where: { $0.id == id }) else { return }
        bindings[idx].isDone = true
        cancelReminder(for: id)
        save()
    }

    /// 重新变为"待办中"。**不撤销**已有提醒：重新待办之后本就该被提醒，
    /// 留着那条通知反而与状态一致。
    func markPending(id: UUID) {
        guard let idx = bindings.firstIndex(where: { $0.id == id }) else { return }
        bindings[idx].isDone = false
        save()
    }

    func remove(id: UUID) {
        bindings.removeAll { $0.id == id }
        cancelReminder(for: id)
        save()
    }

    /// 通知里的「完成」按钮只知道 App 名，不知道 binding id，所以单独提供一个按名完成的入口。
    func markDone(appNamed appName: String) {
        let key = TodoBinding.normalize(appName)
        guard let idx = bindings.firstIndex(where: { $0.normalizedAppName == key }) else { return }
        bindings[idx].isDone = true
        cancelReminder(for: bindings[idx].id)   // 此路径系统已消掉通知，这里只是保持不变量
        save()
    }

    /// 待办结束时顺手撤掉通知中心里它残留的那条提醒。
    ///
    /// 放在 store 里、而不是交给各个调用点，是为了让"状态变成已结束 → 不再有活的提醒"
    /// 成为一个**漏不掉的约束**：以后新增调用点（比如批量完成、后台同步）不必记得这件事。
    /// 代价是 store 依赖了通知层 —— 对当前的规模来说，这个取舍比到处补调用划算。
    private func cancelReminder(for id: UUID) {
        TodoReminder.cancel(identifier: id.uuidString)
    }

    // MARK: - 持久化

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(bindings).write(to: fileURL, options: .atomic)
        } catch {
            print("[TodoStore] save failed: \(error)")
        }
    }

    private static func load(from url: URL) -> [TodoBinding] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([TodoBinding].self, from: data)
        } catch {
            print("[TodoStore] load failed: \(error)")
            return []
        }
    }
}
