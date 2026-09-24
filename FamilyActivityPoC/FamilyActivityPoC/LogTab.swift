import SwiftUI

// MARK: - 日志页

struct LogTab: View {
    let store: ActivityLogStore
    let seenStore: SeenAppStore

    var body: some View {
        NavigationStack {
            List {
                seenSection
                eventSection
            }
            .navigationTitle("日志")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // 只清事件日志。「检测到的 App」不清 —— 它是新增待办时唯一的
                    // App 来源，误清一次就得靠重新打开一堆 App 才长得回来。
                    Button("清空日志", action: store.clear)
                        .disabled(store.logs.isEmpty)
                }
            }
        }
    }

    private var seenSection: some View {
        Section {
            if seenStore.apps.isEmpty {
                Text("还没有检测到任何 App。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(seenStore.apps) { app in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(app.name)
                            if app.isOwnApp {
                                Text("本 App")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        Text("共 \(app.seenCount) 次 · 最近 \(app.lastSeenAt.formatted(POCFormat.relative))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("检测到的 App（\(seenStore.apps.count)）")
        } footer: {
            Text("自动化每次把「当前 App」报上来就记一条，按名字去重、最多留 \(SeenAppStore.maxEntries) 条。"
                 + "本 App 自己也会出现在这里 —— 自动化勾了全部 App，所以这是正常的，"
                 + "它不会出现在选择器里。")
        }
    }

    private var eventSection: some View {
        Section {
            if store.logs.isEmpty {
                Text("尚无记录。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.logs) { log in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(log.event)
                        HStack(spacing: 8) {
                            Text(log.source.displayName)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                            Text(log.timestamp.formatted(POCFormat.time))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("触发日志（\(store.logs.count)）")
        }
    }
}
