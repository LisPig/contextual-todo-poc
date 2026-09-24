import Foundation

// 从 ContentView.swift 拆出来：`AppPickerSheet` 也要用它，而两个 Tab 各自成文件后
// 它更没理由住在任何一个 Tab 的文件里。

/// 两个标签页共用的时间格式。
///
/// 原来它只写在 `LogTab` 里（`private static let`）。检测到的 App 列表要用同样的格式，
/// 而 `AppPickerSheet` 在另一个文件里、拿不到 file-private 的成员，所以提到文件级。
enum POCFormat {

    /// 日期格式固定用中文，**不跟随系统语言**。
    ///
    /// **为什么必须写死**：本 App 没有任何本地化 —— `Bundle.main` 没声明
    /// `CFBundleLocalizations`，工程里也没有一处 `.strings`（界面文案全是中文字面量）。
    /// 这种情况下 `Locale.current` 会落到开发区域，于是**即使手机语言是中文**，
    /// `Date.RelativeFormatStyle` 也渲染成 "52 minutes ago"，
    /// 和它前后那些写死的中文拼在一起。
    ///
    /// 实测过、不是推测：把模拟器语言切成简体中文（`AppleLanguages = (zh-Hans)`）后重装重启，
    /// 日期照样是英文。详见 docs/01-poc-verification.md 的 v2 UI 证据段。
    ///
    /// 将来真要做多语言时，正确做法是补上本地化再删掉这个常量，
    /// 而不是让它继续跟着开发区域走。
    private static let locale = Locale(identifier: "zh_Hans_CN")

    static let time: Date.FormatStyle = .init(date: .omitted, time: .standard, locale: locale)
    static let relative: Date.RelativeFormatStyle = .init(presentation: .named, locale: locale)
}
