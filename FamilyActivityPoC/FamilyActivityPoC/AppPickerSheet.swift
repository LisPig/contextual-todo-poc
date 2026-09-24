import SwiftUI

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
