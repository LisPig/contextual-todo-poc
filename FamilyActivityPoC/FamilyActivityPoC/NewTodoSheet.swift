import SwiftUI

/// 新增待办：一个独立 sheet，入口是待办页导航栏右上角的 ＋。
///
/// **为什么从待办页搬出来**：原来「新增」是页面上的一个 Section —— 它得跟
/// 「接线状态 / 通知权限」抢顶部位置，而「添加待办」按钮在页面中段，
/// 键盘一弹就把列表顶上去、按钮还可能被盖住（v2 真机上撞到的原话）。
/// 搬进 sheet 之后提交按钮进了**导航栏**，键盘永远盖不住它；
/// 输入框在列表最上面，也不会被挡。
///
/// 状态全部是本结构体的 `@State`，靠"每次呈现都是一棵新视图树"来重置：
/// `TodoTab` 用 `.sheet(item:)` 呈现，item 走 nil → .newTodo → nil。
/// 所以**不要**把 `text` / `appNames` 提到 `TodoTab` 上去 —— 那样就得手写重置，
/// 而"忘了重置"的表现是上次的草稿又冒出来，静默、且很像用户的错觉。
struct NewTodoSheet: View {

    let store: TodoStore
    let seenStore: SeenAppStore

    @Environment(\.dismiss) private var dismiss

    @State private var path: [Step] = []
    @State private var text = ""
    @State private var appNames: Set<String> = []

    /// 与待办页上原来那个输入框同一个理由：`axis: .vertical` 的多行输入框回车是**换行**、
    /// `onSubmit` 不触发，只有这个状态能提供"收起键盘"这个动作。
    @FocusState private var textFocused: Bool

    private enum Step: Hashable {
        /// 种子**必须随导航值一起冻结**。
        ///
        /// 不能写成 `navigationDestination` 闭包里的 `Array(appNames)`：那个闭包会随父视图
        /// `body` 重新求值，于是用户在选择器里取消勾选一个"系统从没上报过"的名字时，
        /// 种子跟着缩水、那一行当场消失 —— 正是 `AppPickerList.seedNames` 要防的事，
        /// 等于快照没冻住。
        case pickApps(seed: [String])
    }

    /// 判据与 `TodoStore.add` 对齐。
    ///
    /// **这里必须用 `.whitespacesAndNewlines`，不能沿用待办页那个 `.whitespaces`**：
    /// `CharacterSet.whitespaces` 不含换行符，所以一个只敲了回车的输入框
    /// （中文输入法下先换行再打字很常见）会通过旧判据 → `add` 里被
    /// `.whitespacesAndNewlines` 裁空 → 返回 nil → **sheet 关掉、什么都没加、
    /// 也没有任何提示**。那是搬过来之前就存在的静默失败，顺手修掉。
    private var canAdd: Bool {
        !appNames.isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    HStack(spacing: 8) {
                        TextField("待办内容，例如：给张总回消息", text: $text, axis: .vertical)
                            .lineLimit(1...3)
                            .focused($textFocused)

                        // 键盘附件的**兜底**出口。
                        //
                        // 它走的是内容通道，不经过键盘附件那条通道，所以不受 sheet 的呈现上下文
                        // 影响。存在的唯一理由：下面「完成」那条 `placement: .keyboard` 工具栏
                        // 在 sheet 里能否渲染是本次唯一没把握的点，而它一旦失效，失败模式正是
                        // 用户已经撞过的那个 —— 多行输入框回车是换行、点空白不收键盘，
                        // 没有任何出口。成本 5 行，不赌。
                        if textFocused {
                            Button { textFocused = false } label: {
                                Image(systemName: "keyboard.chevron.compact.down")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("收起键盘")
                        }
                    }

                    Button { openPicker() } label: {
                        HStack {
                            Text("选择 App")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(appNames.isEmpty ? "未选择" : "已选 \(appNames.count) 个")
                                .foregroundStyle(appNames.isEmpty ? Color.secondary : Color.accentColor)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    if !appNames.isEmpty {
                        AppChipsView(names: appNames.sorted())
                    }
                } header: {
                    Text("待办内容")
                } footer: {
                    if !appNames.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // 「App 名为什么不能手打」的唯一解释，从待办页搬过来，别顺手删掉。
                        Text("App 只能从选择器里那个列表选 —— 名字由系统上报，不用手打，也就不会拼错。"
                             + "一条待办可以绑多个 App，比如「回消息」同时绑微信和企业微信。")
                    } else {
                        // 独立成一步之后，灰掉的「添加」更难解释了：用户打了字、没选 App，
                        // 只看到一个灰按钮，不知道缺什么。
                        Text("还需要至少选择一个 App 才能添加。")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("新增待办")
            .navigationBarTitleDisplayMode(.inline)
            // 收键盘的第二条出口（第一条是键盘上的「完成」，第三条是下面那个按钮）。
            .scrollDismissesKeyboard(.interactively)
            // 工具栏挂在 **List 上而不是 NavigationStack 上**：挂在 Stack 上的 item 在 push
            // 之后会留在导航栏里，于是选择器那屏会同时有「添加」和「完成」两个 trailing。
            // 挂在内容上，push 后 root 的 item 自然让位给目标页。
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { add() }
                        .disabled(!canAdd)
                }
            }
            .toolbar {
                // 键盘正上方那个「完成」，与待办页上原来那条一模一样。
                // **必须在 sheet 自己的视图树里重新声明**：sheet 是另一套呈现上下文，
                // 不会继承外面那条工具栏。
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { textFocused = false }
                }
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .pickApps(let seed):
                    AppPickerList(
                        apps: seenStore.detectedApps,
                        // 还没建的待办，谁也排除不了 —— 与旧代码 commit(_:for: nil) 的语义一致
                        claimed: store.claimedAppNames(excludingID: nil),
                        seedNames: seed,
                        selection: $appNames
                    )
                    .navigationTitle("选择 App")
                    .navigationBarTitleDisplayMode(.inline)
                    .scrollDismissesKeyboard(.immediately)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            // 在 push 出来的这一层里，`dismiss()` 是**出栈**、不是关掉 sheet；
                            // 显式 removeLast 更直白。
                            Button("完成") { path.removeLast() }
                        }
                    }
                }
            }
        }
    }

    private func openPicker() {
        // 先把键盘收掉再换屏：键盘要是跟着跨屏留下去，选择器那屏没有输入框、
        // 也没有键盘工具栏，用户就没有出口了。
        textFocused = false
        path.append(.pickApps(seed: Array(appNames)))
    }

    private func add() {
        // 先落库、再关。反过来的话 `@State` 会在 dismiss 之后继续被读到，
        // 而 dismiss 有可能让 body 在动画期间再求值一次 —— 顺序反了很容易写出
        // "先在关掉的视图上取值"这种偶发 bug。
        store.add(appNames: Array(appNames), todoText: text)
        dismiss()
    }
}
