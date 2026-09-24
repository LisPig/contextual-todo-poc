import SwiftUI

/// 选择这条待办要绑哪些 App —— **列表本体**。
///
/// 没有 `NavigationStack`、没有工具栏、不调 `dismiss`：它现在有两个宿主。
/// - `AppPickerSheet`（本文件下面那个壳）—— 以 sheet 形式弹出，改绑**已有**待办走它；
/// - `NewTodoSheet` 里 push 进去的那一层 —— 新建流程走它。
///
/// 行渲染、占用置灰、"已选但系统从没上报过"的补行、空状态两份宿主共用，
/// 不然"某天只改了其中一份"是必然的。
///
/// **列表内容只能来自系统上报过的 App**（`SeenAppStore`），不提供手输 —— 这是 v2 的核心：
/// 名字两边各打一遍、拼写不一致就静默不提醒，是这个功能原来最脆的一环。
struct AppPickerList: View {

    /// 已排除本 App 自己的检测列表
    let apps: [SeenApp]
    /// 归一化 App 名 → 占用它的待办文本。已被别的待办占用的 App 不能选。
    let claimed: [String: String]

    /// 进入这个界面时**已经选中**的名字。**是快照，不是 `selection` 的镜像。**
    ///
    /// 必须单独传：用户在这里取消勾选一个"系统从没上报过"的名字之后，那一行要
    /// **留在屏幕上**让他能反悔。跟着 `selection` 走的话那一行会当场消失，等于没有撤销 ——
    /// 而这个名字是用户自己绑过的，丢了没有任何提示。
    ///
    /// 宿主侧要保证它真的冻住：push 的话必须把种子放进**导航值**里，
    /// 不能写成 `navigationDestination` 闭包里的 `Array(appNames)` —— 闭包会随父视图
    /// `body` 重新求值，名字一取消种子就跟着缩水。
    let seedNames: [String]

    /// 存**原样名字**而不是归一化 key：这个值最终要原样写进绑定。
    @Binding var selection: Set<String>

    var body: some View {
        List {
            if rows.isEmpty {
                emptyState
            } else {
                Section {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                } footer: {
                    Text("一个 App 只能属于一条待办 —— 两条待办抢同一个 App 会重复提醒。"
                         + "要改一条待办绑的 App，就点它本身。"
                         + "列表里没有你要的 App？先去打开它一次，回到这里就会出现。")
                }
            }
        }
    }

    // MARK: - 行

    private struct Row: Identifiable {
        let name: String
        let detail: String
        /// 非 nil 表示已被别的待办占用（值是那条待办的文本）
        let owner: String?
        var id: String { TodoBinding.normalize(name) }
    }

    /// 检测到的 App，外加 `seedNames ∪ selection` 里那些**系统从没上报过**的名字。
    ///
    /// 后者必须显示出来：不显示的话用户在这个界面里根本看不到它，
    /// 一按「完成」就把一个自己绑过的名字悄悄弄丢了。
    /// 取并集而不是只取 `selection`：取消勾选之后那一行要留下（见 `seedNames`）。
    private var rows: [Row] {
        var result: [Row] = []
        var seen: Set<String> = []

        for app in apps where !app.isOwnApp {
            seen.insert(app.id)
            result.append(Row(
                name: app.name,
                detail: "共 \(app.seenCount) 次 · 最近 \(app.lastSeenAt.formatted(POCFormat.relative))",
                owner: claimed[app.id]
            ))
        }

        // 顺序必须确定：`selection` 是 `Set`，直接迭代的话每次渲染都可能换位。
        // 先按快照给的顺序（原样），再把这次新勾上、快照里没有的补在后面（排序过）。
        var extras: [String] = []
        func appendExtra(_ name: String) {
            let key = TodoBinding.normalize(name)
            guard !seen.contains(key) else { return }
            seen.insert(key)
            extras.append(name)
        }
        seedNames.forEach(appendExtra)
        selection.sorted().forEach(appendExtra)

        for name in extras {
            result.append(Row(
                name: name,
                detail: "还没检测到过 —— 打开它一次，这里就会出现它的打开记录",
                owner: nil
            ))
        }
        return result
    }

    private func rowView(_ row: Row) -> some View {
        let isSelected = selection.contains(row.name)
        let isLocked = row.owner != nil && !isSelected

        return Button {
            if isSelected { selection.remove(row.name) } else { selection.insert(row.name) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isLocked ? Color.secondary : Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.name)
                        .foregroundStyle(isLocked ? Color.secondary : Color.primary)
                    if let owner = row.owner {
                        Text("已被「\(owner)」占用")
                            .font(.caption)
                            .foregroundStyle(isLocked ? Color.secondary : Color.orange)
                    } else {
                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
    }

    // MARK: - 空状态

    /// 空状态必须同时说清两种成因，否则"自动化里没勾选它"会变成一个全新的静默失败类别 ——
    /// 和这个功能原来那个（拼写不一致就不提醒）一模一样。
    private var emptyState: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("还没有检测到任何 App")
                    .font(.headline)
                Text("这里只列系统上报过的 App，不能手输 —— 名字对不上的话是不会有任何提示的，"
                     + "所以我们干脆不让名字由人来定。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("两种情况：")
                    .font(.callout.weight(.medium))
                Text("1. 还没打开过任何 App。随便打开一个再回来。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("2. 打开过了还是没有。那就是「快捷指令」里那条自动化没有勾选它，"
                     + "或者压根还没建。去「接线指引」按五步做一遍。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}

/// 选择这条待办要绑哪些 App —— **以 sheet 形式**弹出的那个壳。
///
/// 公开 init 与 `onCommit` 签名刻意保持不变：待办行点进来的改绑路径因此不需要任何改动。
/// 新建流程不再走这里，而是把 `AppPickerList` push 进 `NewTodoSheet` 的导航栈 ——
/// 于是这个壳的存在理由只剩"改绑已有待办"一个，`newTodoSheet` 里也因此没有嵌套 presentation。
struct AppPickerSheet: View {

    let title: String
    let apps: [SeenApp]
    let claimed: [String: String]
    let currentNames: [String]
    let onCommit: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selection: Set<String>

    init(
        title: String,
        apps: [SeenApp],
        claimed: [String: String],
        currentNames: [String],
        onCommit: @escaping (Set<String>) -> Void
    ) {
        self.title = title
        self.apps = apps
        self.claimed = claimed
        self.currentNames = currentNames
        self.onCommit = onCommit
        _selection = State(initialValue: Set(currentNames))
    }

    var body: some View {
        NavigationStack {
            AppPickerList(
                apps: apps,
                claimed: claimed,
                seedNames: currentNames,
                selection: $selection
            )
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onCommit(selection)
                        dismiss()
                    }
                }
            }
        }
    }
}
