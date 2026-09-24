import Foundation
import Observation

/// 记录"系统上报过哪些 App"。
///
/// v2 起 App 名**只能从这里选**，用户不再手输 —— 这消灭了"本 App 与自动化两处
/// 拼写必须一致"这个静默失败类别（见 docs/03-shortcuts-setup-research.md）。
/// 代价就是必须有这么一处记住系统到底报过哪些名字。
@MainActor
@Observable
final class SeenAppStore {
    static let shared = SeenAppStore()

    /// 条数上限。全选之后每次切 App 都会写一次，不封顶这个文件会跟着用机时长无限长。
    static let maxEntries = 200

    /// 按 `lastSeenAt` 倒序，最新的在最前，便于界面直接展示。
    private(set) var apps: [SeenApp] = []

    private let fileURL: URL

    init(filename: String = "seen-apps.json") {
        let fm = FileManager.default
        let dir = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory

        self.fileURL = dir.appendingPathComponent(filename)

        let stored = Self.read(from: fileURL)
        self.apps = stored.apps
        sortAndTrim()

        // 和 `TodoStore` 同一条规矩：读盘时做过清洗（合并重复、丢空名、截上限）就落回去，
        // 否则磁盘和内存会一直不一致，直到用户下一次触发才对齐。
        // 比较的是**文件字节**而不是中间结果 —— 中间结果已经洗过了，拿它自己跟自己比
        // 永远相等，等于没比。
        if stored.readable, stored.data != Self.encoded(apps) { save() }
    }

    // MARK: - 查询

    /// 供「选择 App」用的列表：排除本 App 自己。
    var detectedApps: [SeenApp] {
        apps.filter { !$0.isOwnApp }
    }

    /// 有没有**任何一次**触发到达过。
    ///
    /// 这是"接线到底通没通"的唯一准确判据：自动化建好、且「运行前询问」关掉之后，
    /// 用户只要切一次 App 就该有记录。为空 = 接线没接好（或"询问"没关），
    /// 界面据此显示橙色警告并引导去看指引。
    ///
    /// 注意本 App 自己的记录也算 —— 打开本 App 同样走那条自动化，
    /// 所以它能证明"自动化是活的"，只是证明不了"别的 App 也报了名"。
    var hasAnyTrigger: Bool {
        !apps.isEmpty
    }

    /// 某个 App 名有没有被系统上报过。
    ///
    /// 用来提示"这条待办绑的名字从没上报过"。措辞必须是**提示**而不是"断线"判决：
    /// 用户还没打开过那个 App 时同样没有记录，那并不代表接线坏了。
    func hasSeen(appNamed name: String) -> Bool {
        let key = TodoBinding.normalize(name)
        guard !key.isEmpty else { return false }
        return apps.contains { $0.id == key }
    }

    // MARK: - 写入

    /// 记一次"看到这个 App 被打开"。按归一化名字 upsert。
    func record(name rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = TodoBinding.normalize(name)

        // 空名**绝不能**进这里。自动化没接「获取当前 App」时报的就是空字符串，
        // 若把它也记下来，`hasAnyTrigger` 就永远为真 —— 接线警告再也不会出现，
        // 诊断恰好指向反面。（空名只进 ActivityLog，那边会单独措辞。）
        guard !key.isEmpty else { return }

        let now = Date()
        if let idx = apps.firstIndex(where: { $0.id == key }) {
            // 保留**最新拼写**：App 改名或设备换语言之后，新的那个才是能匹配上的。
            apps[idx].name = name
            apps[idx].lastSeenAt = now
            apps[idx].seenCount += 1
            apps[idx].isOwnApp = Self.isOwnApp(name)
        } else {
            apps.append(SeenApp(
                name: name,
                firstSeenAt: now,
                lastSeenAt: now,
                seenCount: 1,
                isOwnApp: Self.isOwnApp(name)
            ))
        }

        sortAndTrim()
        save()
    }

    func clear() {
        apps.removeAll()
        save()
    }

    // MARK: - 自识别

    /// 这个名字是不是本 App 自己。
    static func isOwnApp(_ name: String) -> Bool {
        let key = TodoBinding.normalize(name)
        guard !key.isEmpty else { return false }
        return ownAppNames.contains(key)
    }

    /// 本 App 可能以哪些名字出现。
    ///
    /// **别只看 `CFBundleDisplayName`**：本工程用 `GENERATE_INFOPLIST_FILE = YES`
    /// 且没有设 `INFOPLIST_KEY_CFBundleDisplayName`，所以 `CFBundleDisplayName`
    /// 在 Info.plist 里**是缺失的**，桌面显示名取的是 `CFBundleName`。
    /// 几个键都可能被系统报上来，全部收进来比。
    private static let ownAppNames: Set<String> = {
        let bundle = Bundle.main
        let candidates: [String?] = [
            bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
        ]
        return Set(candidates.compactMap { $0 }.map(TodoBinding.normalize).filter { !$0.isEmpty })
    }()

    // MARK: - 排序与淘汰

    private func sortAndTrim() {
        apps.sort { $0.lastSeenAt > $1.lastSeenAt }
        guard apps.count > Self.maxEntries else { return }

        // 淘汰顺序：本 App 自己永远留着（它是"自动化是活的"的证据，且最多占一条）；
        // 仍被某条绑定引用的名字也留着 —— 淘汰掉它们会让用户在选择器里
        // 找不到自己明明绑着的 App。其余按"最久未见"淘汰。
        let protected = Self.protectedKeys()
        var overflow = apps.count - Self.maxEntries
        var kept: [SeenApp] = []

        for app in apps {                   // 已按 lastSeenAt 倒序
            if overflow > 0, !app.isOwnApp, !protected.contains(app.id) {
                overflow -= 1
                continue
            }
            kept.append(app)
        }
        apps = kept
    }

    /// 不能被淘汰的名字：仍被某条绑定引用的 App。
    ///
    /// 这里读了 `TodoStore`，是 store → store 的耦合。之所以接受它：
    /// 「保护集」的定义天然属于绑定数据，另存一份副本只会产生第二处真相，
    /// 而第二处真相迟早会不同步。（`TodoStore` 依赖 `TodoReminder` 是同一笔取舍，
    /// 理由见那边的注释。）
    private static func protectedKeys() -> Set<String> {
        var keys: Set<String> = []
        for binding in TodoStore.shared.bindings {
            keys.formUnion(binding.normalizedAppNames)
        }
        return keys
    }

    // MARK: - 持久化

    private func save() {
        guard let data = Self.encoded(apps) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[SeenAppStore] save failed: \(error)")
        }
    }

    private static func encoded(_ apps: [SeenApp]) -> Data? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(apps)
        } catch {
            print("[SeenAppStore] encode failed: \(error)")
            return nil
        }
    }

    private struct LoadResult {
        var apps: [SeenApp]
        var data: Data?
        /// 文件能不能解析。不能解析时保留原样，不回写。
        var readable: Bool
    }

    /// 读盘时也要清洗：合并同一个 App 的重复记录、丢掉空名。
    ///
    /// **只在写入时截上限是不够的** —— 上限是 v2 才加的，改动之前留下的文件
    /// 可能已经远超它。这里先按条数粗截，`sortAndTrim()` 再做考虑"保护集"的细截。
    private static func read(from url: URL) -> LoadResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let data = try? Data(contentsOf: url) else {
            return LoadResult(apps: [], data: nil, readable: false)
        }
        guard let stored = try? decoder.decode([SeenApp].self, from: data) else {
            print("[SeenAppStore] load failed")
            return LoadResult(apps: [], data: data, readable: false)
        }

        var merged: [String: SeenApp] = [:]
        for app in stored where !TodoBinding.normalize(app.name).isEmpty {
            guard let existing = merged[app.id] else {
                merged[app.id] = app
                continue
            }
            var keeper = existing.lastSeenAt >= app.lastSeenAt ? existing : app
            keeper.firstSeenAt = min(existing.firstSeenAt, app.firstSeenAt)
            keeper.lastSeenAt = max(existing.lastSeenAt, app.lastSeenAt)
            keeper.seenCount = existing.seenCount + app.seenCount
            keeper.isOwnApp = existing.isOwnApp || app.isOwnApp
            merged[app.id] = keeper
        }

        let cleaned = merged.values
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
            .prefix(maxEntries)
            .map { $0 }
        return LoadResult(apps: cleaned, data: data, readable: true)
    }
}
