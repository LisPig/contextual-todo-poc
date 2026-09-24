import SwiftUI

/// 接线指引：把「快捷指令」里要做的四步讲清楚。
///
/// **为什么这件事值得单独做一个界面**：整条链路上最容易失败的地方不在代码里，
/// 而在这四步有没有一次做对 —— 尤其第 4 步（「运行前询问」必须关掉）。
/// 漏掉它，每次打开目标 App 都会先弹一个确认框，功能等于不可用，
/// 而用户不会知道是自己漏了一步，只会觉得"这 App 没反应"。
///
/// 这条自动化**只需要建一次**：触发器勾选全部 App，之后新增待办都在本 App 里做，
/// 不用再碰 Shortcuts。
///
/// 注：正文一律不用 markdown 语法。拼接出来的字符串是 `String` 而不是
/// `LocalizedStringKey`，`**加粗**` 不会被解析、会原样显示出来 —— 与其记住
/// "哪些能拼哪些不能拼"，不如一开始就不用。要强调就用「」或字体字重。
struct SetupGuideView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("建一条自动化就够了。触发器勾选全部 App，之后新增待办都在本 App 里完成，不用再回到「快捷指令」。")
                        .font(.callout)
                }

                stepsSection
                warningSection
                troubleshootSection
            }
            .navigationTitle("接线指引")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: - 四步

    private var stepsSection: some View {
        Section {
            step(1, "新建自动化") {
                Text("打开「快捷指令」，底部切到「自动化」标签，右上角 ＋，选「App」。")
            }
            step(2, "勾选全部 App") {
                Text("点「选取」，把所有 App 都选上。选多选少只决定「系统会不会把这次打开告诉我们」，"
                     + "不决定提醒谁 —— 漏选的 App 打开时不会有任何反应，和没绑待办长得一模一样。")
            }
            step(3, "选「已打开」") {
                Text("勾选「已打开」，然后选「立即运行」。")
            }
            step(4, "按顺序加三个动作") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("① 获取当前 App")
                    Text("② 从输入获取文本，属性选「名称」")
                    Text("③ 检查待办并提醒（在动作列表里搜本 App 的名字），把它的「App 名称」参数设成 ② 的输出")
                    Text("顺序不能换：② 读的是 ① 的结果，③ 读的是 ② 的结果。")
                        .foregroundStyle(.secondary)
                }
            }
            step(5, "回到桌面，打开一个 App 试试") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("退回桌面，打开任意一个 App（比如微信），然后回到本 App。"
                         + "「日志」页的「检测到的 App」里出现它，才算接通。")
                    Text("这一步不能省：这条自动化是被动的，只在「某个 App 被打开」的那一刻触发。"
                         + "刚建完时系统还不知道任何 App 的名字，列表必然是空的。")
                    // 这一步不写成"注意：…"而是带一个 ⚠️：`step` 的 detail 整体是 secondary 色，
                    // 加 `foregroundStyle` 不生效，但 ⚠️ 本身就能把这个坑拎出来。
                    Text("⚠️ 在「快捷指令」里点运行按钮不算 —— 那一刻没有「当前 App」，"
                         + "「获取当前 App」拿不到东西，列表不会变。")
                }
            }
        } header: {
            Text("五步")
        } footer: {
            Text("第 ① 步要求 iOS 18.2 或更高。系统版本太低的话，动作列表里搜不到「获取当前 App」。")
        }
    }

    private func step<Content: View>(
        _ number: Int,
        _ title: String,
        @ViewBuilder detail: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                detail()
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 最容易漏的一步

    private var warningSection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("「运行前询问」必须关掉").font(.headline)
                    Text("它默认是开着的。只要没关，每次打开目标 App 都会先弹一个确认框 —— "
                         + "提醒功能等于不可用。建完自动化后点进去检查一遍。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("最容易漏的一步")
        }
    }

    // MARK: - 排查

    private var troubleshootSection: some View {
        Section {
            bullet(
                "先确认接线通了没",
                "回到本 App 的「日志」页，看「检测到的 App」里有没有东西。随便打开一个 App 再切回来；"
                + "出现了就说明通了，一直空着就说明自动化没建好，或者「运行前询问」没关。"
            )
            bullet(
                "有反应但没有横幅",
                "先看手机是不是开着专注模式或睡眠模式 —— 那种状态下通知会被静默送进通知中心、不弹横幅，"
                + "看起来就像没发出去。把本 App 加进允许列表。"
            )
            bullet(
                "某些 App 从来不提醒",
                "去第 2 步确认它在自动化的勾选范围内。没勾选的 App 是完全静默的，"
                + "和「没绑待办」的表象一模一样。"
            )
            bullet(
                "按钮要点开横幅才看得到",
                "iOS 的通知横幅收起时只显示标题和正文，「完成 / 稍后再说」需要下拉或长按展开。"
                + "这是系统行为，改不了。"
            )
            bullet(
                "重装 App 之后就不灵了",
                "免费 Apple 账号的证书 7 天过期，重新安装会打断 Shortcuts 自动化，需要回来重建这条自动化。"
            )
        } header: {
            Text("不灵的时候按这个顺序查")
        } footer: {
            Button {
                openShortcuts()
            } label: {
                Label("打开「快捷指令」", systemImage: "arrow.up.forward.app")
            }
        }
    }

    private func bullet(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 深链

    /// 打开「快捷指令」。
    ///
    /// `shortcuts://create-automation` 是未公开的端点，有人报告可用但**不能预选触发器类型**，
    /// 而且随时可能失效（见 docs/03-shortcuts-setup-research.md 第 1 节）。
    /// 所以只用它 best-effort 少点一步，失败就退回 `shortcuts://` 打开应用本体。
    private func openShortcuts() {
        guard let direct = URL(string: "shortcuts://create-automation") else { return }
        openURL(direct) { opened in
            guard !opened, let fallback = URL(string: "shortcuts://") else { return }
            openURL(fallback)
        }
    }
}

#Preview {
    SetupGuideView()
}
