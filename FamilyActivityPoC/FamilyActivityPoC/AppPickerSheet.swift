import SwiftUI

/// 选择这条待办要绑哪些 App。
///
/// **列表内容只能来自系统上报过的 App**（`SeenAppStore`），不提供手输 —— 这是 v2 的核心：
/// 名字两边各打一遍、拼写不一致就静默不提醒，是这个功能原来最脆的一环。
///
/// 只负责"选"，不负责"存"：提交时回调出去，由调用方决定是写进新建待办的草稿，
/// 还是写回某条已有待办。同一份列表因此能同时服务两个入口。
struct AppPickerSheet: View {

    let title: String
    /// 已排除本 App 自己的检测列表
    let apps: [SeenApp]
    /// 归一化 App 名 → 占用它的待办文本。已被别的待办占用的 App 不能选。
    let claimed: [String: String]
    /// 本条目当前已选的 App 名（原样）
    let currentNames: [String]
    let onCommit: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss

    /// 存**原样名字**而不是归一化 key：这个值最终要原样写进绑定。
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
                             + "要改一条待办绑的 App，就点它本身。")
                    }
                }
            }
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

    // MARK: - 行

    private struct Row: Identifiable {
        let name: String
        let detail: String
        /// 非 nil 表示已被别的待办占用（值是那条待办的文本）
        let owner: String?
        var id: String { TodoBinding.normalize(name) }
    }

    /// 检测到的 App，外加**本条目已选、但系统从没上报过**的名字。
    ///
    /// 后者必须显示出来：不显示的话用户在这个界面里根本看不到它，
    /// 一按「完成」就把一个自己绑过的名字悄悄弄丢了。
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

        for name in currentNames where !seen.contains(TodoBinding.normalize(name)) {
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
                     + "或者压根还没建。去「接线指引」按四步做一遍。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}
