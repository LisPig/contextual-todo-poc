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

        let stored = Self.read(from: fileURL)
        self.bindings = stored.bindings

        // 旧文件里同一个 App 可能被两条**待办中**的绑定同时持有（手工改过文件，
        // 或更早版本的 bug）。那种情况下 `pendingBinding` 只会返回其中一条，
        // 另一条**永远不提醒** —— 静默失灵比弹两条更糟。这里按创建时间先到先得
        // 摘掉重复项并留痕。
        sanitizeInvariant()

        // 把文件规范化成 v2 形状：读进来的东西重新编码一遍，和文件不一致就写回。
        //
        // 这一条比较同时覆盖了三种"内存已经是对的、盘上还是旧的"情况 ——
        // v1 的 `appName` 迁移成数组、畸形记录被丢掉、以及上面 sanitize 改过内容，
        // 不必为每种情况单独判断。不这么比的话，那些情况要等到用户**下一次改动**
        // 才会落盘，中间磁盘上和内存里一直不一致。
        //
        // 只在**整体解码成功**时才做：文件彻底不可读时（`readable == false`）
        // 绝不能回写，否则会把用户仅存的那点原始数据抹成空文件。
        if stored.readable, stored.data != Self.encoded(bindings) {
            save()
        }
    }

    // MARK: - 查询

    /// 按 App 名查找**尚未完成**的绑定。
    /// 完成后不再提醒是产品明确要求，所以这里直接过滤掉 `isDone`。
    func pendingBinding(forAppNamed appName: String) -> TodoBinding? {
        let key = TodoBinding.normalize(appName)
        guard !key.isEmpty else { return nil }
        let hits = bindings.filter { !$0.isDone && $0.matches(appNamed: key) }
        if hits.count > 1 {
            // 不变量被破坏。注意它的**失效方向**：`first` 意味着另一条待办永远不提醒，
            // 而不是"弹两条"。真正的兜底在写入与加载时的 claim/sanitize，这里只留证据。
            POCTrace.log("INVARIANT VIOLATED app=\"\(key)\" todos=\(hits.count)")
        }
        return hits.first
    }

    func binding(withID id: UUID) -> TodoBinding? {
        bindings.first { $0.id == id }
    }

    /// 归一化 App 名 → 占用它的待办文本，供选择器标注"已被谁占用"。
    ///
    /// 只看**待办中**的绑定：已完成的待办不再提醒，持有同一个 App 名不构成重复提醒；
    /// 若把它也算作占用，用户每完成一条待办就得先删掉它才能复用那个 App。
    func claimedAppNames(excludingID id: UUID?) -> [String: String] {
        var result: [String: String] = [:]
        for binding in bindings where binding.id != id && !binding.isDone {
            for key in binding.normalizedAppNames {
                result[key] = binding.todoText
            }
        }
        return result
    }

    // MARK: - 变更

    /// 新增一条待办。App 名或待办内容为空则返回 nil。
    @discardableResult
    func add(appNames: [String], todoText: String) -> UUID? {
        let names = TodoBinding.dedupe(appNames)
        let todo = todoText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !names.isEmpty, !todo.isEmpty else { return nil }

        let binding = TodoBinding(appNames: names, todoText: todo)
        bindings.append(binding)
        claim(names, for: binding.id)
        save()
        return binding.id
    }

    /// 修改一条待办的 App 集合与内容。
    ///
    /// `appNames` 允许为空（用户取消勾选全部）：那表示"这条待办当前不会提醒"，
    /// 界面会显示成橙色提示，**不删除**用户的待办。
    func update(id: UUID, appNames: [String], todoText: String) {
        guard let idx = bindings.firstIndex(where: { $0.id == id }) else { return }
        let todo = todoText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !todo.isEmpty else { return }

        bindings[idx].appNames = TodoBinding.dedupe(appNames)
        bindings[idx].todoText = todo
        claim(bindings[idx].appNames, for: id)
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
    ///
    /// 但要重新**抢回**它的 App 名：完成期间这条待办被排除在占用之外
    /// （见 `claimedAppNames`），期间可能有另一条待办把同一个 App 绑走了。
    /// 不重新抢先，两条待办就会同时持有它 —— 一次打开弹两条提醒。
    func markPending(id: UUID) {
        guard let idx = bindings.firstIndex(where: { $0.id == id }) else { return }
        bindings[idx].isDone = false
        claim(bindings[idx].appNames, for: id)
        save()
    }

    func remove(id: UUID) {
        bindings.removeAll { $0.id == id }
        cancelReminder(for: id)
        save()
    }

    /// 按 App 名标记完成的入口。
    ///
    /// v2 起通知里带了绑定 id，优先走 `markDone(id:)`；这条路径用于
    /// **v1 时期发出的老通知**（userInfo 里只有 App 名）以及 `--poc-action-test`。
    func markDone(appNamed appName: String) {
        let key = TodoBinding.normalize(appName)
        guard !key.isEmpty,
              let idx = bindings.firstIndex(where: { !$0.isDone && $0.matches(appNamed: key) })
        else { return }
        bindings[idx].isDone = true
        cancelReminder(for: bindings[idx].id)   // 此路径系统已消掉通知，这里只是保持不变量
        save()
    }

    // MARK: - 不变量：一个 App 只能属于一条待办中的待办

    /// 让 `owner` 独占这些 App 名：从其它**待办中**的绑定里把同名摘掉。
    ///
    /// 采取"后写覆盖"而不是"拒绝写入"：这是用户刚做的显式操作，应该赢。
    /// 被摘空的绑定**保留**（`appNames == []`，界面显示"不会提醒"）——
    /// **绝不**因为摘空而删除用户的待办。
    ///
    /// 放在 store 层而不是界面上：store 是所有写入方的唯一收口
    /// （界面、无头自检、将来任何导入路径）。界面上的排除只能挡住它自己渲染的入口，
    /// 换个调用方就被绕过了。
    @discardableResult
    private func claim(_ names: [String], for owner: UUID) -> [String] {
        let keys = Set(names.map(TodoBinding.normalize))
        var moved: [String] = []

        for idx in bindings.indices where bindings[idx].id != owner && !bindings[idx].isDone {
            let taken = bindings[idx].appNames.filter { keys.contains(TodoBinding.normalize($0)) }
            guard !taken.isEmpty else { continue }
            bindings[idx].appNames.removeAll { keys.contains(TodoBinding.normalize($0)) }
            moved.append(contentsOf: taken)
        }

        if !moved.isEmpty {
            POCTrace.log(
                "claim moved [\(moved.joined(separator: "、"))] -> todo \(owner.uuidString)"
            )
        }
        return moved
    }

    /// 启动时把加载进来的数据也过一遍不变量。返回是否发生了改动。
    ///
    /// 按 `createdAt` 先到先得：先建的那条保住 App 名，后来的被摘掉。
    /// 摘空的绑定同样保留。
    @discardableResult
    private func sanitizeInvariant() -> Bool {
        var owners: [String: UUID] = [:]    // 归一化 App 名 -> 先抢到的那条待办
        var changed = false

        let order = bindings.indices.sorted { bindings[$0].createdAt < bindings[$1].createdAt }
        for idx in order where !bindings[idx].isDone {
            var kept: [String] = []
            var dropped: [String] = []
            for name in bindings[idx].appNames {
                let key = TodoBinding.normalize(name)
                if owners[key] == nil {
                    owners[key] = bindings[idx].id
                    kept.append(name)
                } else {
                    dropped.append(name)
                }
            }
            guard !dropped.isEmpty else { continue }
            POCTrace.log(
                "sanitize dropped [\(dropped.joined(separator: "、"))] "
                + "from todo \(bindings[idx].id.uuidString)"
            )
            bindings[idx].appNames = kept
            changed = true
        }
        return changed
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
        guard let data = Self.encoded(bindings) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[TodoStore] save failed: \(error)")
        }
    }

    /// 磁盘格式的唯一定义。加载时的"要不要回写"比较的也是它 ——
    /// 比较对象和写入内容必须是同一个函数，否则会来回抖。
    private static func encoded(_ bindings: [TodoBinding]) -> Data? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(bindings)
        } catch {
            print("[TodoStore] encode failed: \(error)")
            return nil
        }
    }

    private struct LoadResult {
        var bindings: [TodoBinding]
        /// 文件原始字节。`nil` 表示文件不存在。
        var data: Data?
        /// 文件是不是能解出数组。**为 false 时绝不能回写** —— 那就把用户仅存的
        /// 那点原始数据抹掉了，而这个 store 是唯一的数据来源。
        var readable: Bool
    }

    /// 逐条解码：一条畸形记录只丢掉它自己，不能连累整个文件。
    /// 整体失败（文件根本不是 JSON）才退化成空数组，且**保持文件原样**。
    private static func read(from url: URL) -> LoadResult {
        guard let data = try? Data(contentsOf: url) else {
            return LoadResult(bindings: [], data: nil, readable: false)
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let raw = try decoder.decode([LenientElement<TodoBinding>].self, from: data)
            let dropped = raw.filter { $0.value == nil }.count
            if dropped > 0 {
                POCTrace.log("load dropped \(dropped) malformed binding(s)")
            }
            return LoadResult(bindings: raw.compactMap(\.value), data: data, readable: true)
        } catch {
            print("[TodoStore] load failed: \(error)")
            POCTrace.log("load FAILED 文件整体不可读，保持原样不覆盖")
            return LoadResult(bindings: [], data: data, readable: false)
        }
    }
}
