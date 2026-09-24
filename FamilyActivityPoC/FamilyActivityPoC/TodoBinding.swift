import Foundation

/// 「App ↔ 待办」的绑定。
///
/// 生命周期（对应产品设计）：
/// - `isDone == false`：**待办中**。每次打开对应 App 都会提醒（"稍后再说"就是保持这个状态）。
/// - `isDone == true`：**已完成**。不再提醒。
///
/// 关于 `appNames`：v2 起它是**数组** —— 一条待办可以绑到多个 App
/// （例如「给客户回消息」同时绑微信和企业微信）。
///
/// 元素是**系统上报的 App 显示名**，不是 bundle id —— iOS 不给我们 bundle id
/// （见 00-feasibility-analysis.md A2）。v2 起用户不再手输，名字来自 Shortcuts 的
/// 「获取当前 App」动作，所以"两处拼写不一致"这个静默失败类别已经消失；
/// 但仍需归一化匹配，因为设备语言一变、或 App 改了名，同一个 App 的显示名就会变。
///
/// 空数组是**合法状态**（比如某条待办引用的 App 被另一条抢走），
/// 表示"这条待办当前不会提醒"。界面必须如实提示，不能静默删除。
struct TodoBinding: Codable, Identifiable, Hashable {
    let id: UUID
    /// 绑定的 App 名，来自本 App 的「检测到的 App」列表（即系统上报的显示名）
    var appNames: [String]
    /// 待办内容，即横幅/通知上要显示的文本
    var todoText: String
    /// 是否已完成。完成后不再提醒。
    var isDone: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        appNames: [String],
        todoText: String,
        isDone: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.appNames = Self.dedupe(appNames)
        self.todoText = todoText
        self.isDone = isDone
        self.createdAt = createdAt
    }

    // MARK: - 编解码

    /// `appName` 只读不写：它是 v1 的字段，仅为读旧文件而保留。
    private enum CodingKeys: String, CodingKey {
        case id, appNames, appName, todoText, isDone, createdAt
    }

    /// 自定义解码，**唯一目的是把 v1 的单个 `appName` 迁移成数组**。
    ///
    /// 为什么非做不可：`TodoStore.load` 在解码失败时兜底 `return []`，
    /// 也就是**静默清空用户的全部绑定**。v1 的 JSON 里只有 `appName`，
    /// 若用合成的解码器，`appNames` 缺失 → 抛错 → 绑定全丢且界面毫无提示。
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        todoText = try c.decode(String.self, forKey: .todoText)
        isDone = try c.decode(Bool.self, forKey: .isDone)
        createdAt = try c.decode(Date.self, forKey: .createdAt)

        if let names = try c.decodeIfPresent([String].self, forKey: .appNames) {
            appNames = Self.dedupe(names)              // v2 文件；空数组合法
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .appName) {
            appNames = Self.dedupe([legacy])           // v1 文件
        } else {
            appNames = []
        }
    }

    /// 显式写 `encode`：只输出 `appNames`，不回写 `appName`。
    /// 留一个已经没人读的旧字段，只会让下一个人以为它还有用。
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(appNames, forKey: .appNames)
        try c.encode(todoText, forKey: .todoText)
        try c.encode(isDone, forKey: .isDone)
        try c.encode(createdAt, forKey: .createdAt)
    }

    // MARK: - 名称处理

    /// 归一化：去首尾空白 + 忽略大小写。
    /// "WeChat" 与 "wechat" 是同一个 App，不应因此漏提醒。
    static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 清洗一组 App 名：去空白、丢空串、按归一化去重，保持原顺序。
    static func dedupe(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalize(name)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(name)
        }
        return result
    }

    /// 归一化后的 App 名集合，供匹配用。
    var normalizedAppNames: Set<String> {
        Set(appNames.map(Self.normalize))
    }

    /// 这个 App 是否属于本绑定。
    ///
    /// 参数是**已经归一化**的 key —— 调用方在循环外归一化一次即可，
    /// 不必每条绑定都重复归一化一遍。
    func matches(appNamed normalizedKey: String) -> Bool {
        !normalizedKey.isEmpty && normalizedAppNames.contains(normalizedKey)
    }

    /// 展示用的一串 App 名。空的时候给一句人话，别让界面出现空白。
    var displayAppNames: String {
        appNames.isEmpty ? "未选择 App" : appNames.joined(separator: "、")
    }
}

/// 逐条解码的包装：一条坏记录不应该让**整个数组**解码失败。
///
/// `TodoStore.load` 在整体解码失败时兜底返回 `[]`，也就是用户的绑定全部消失、
/// 且没有任何提示。套上这层之后，畸形的记录被单独丢掉，好的照常保留。
///
/// **只对数组元素成立**：每个元素拿到独立的 container，`try?` 失败不会污染后续元素。
/// 这一点靠 `--poc-migration-test` 的"一条坏的夹在两条好的中间"fixture 实测过，
/// 不是想当然。
struct LenientElement<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}
