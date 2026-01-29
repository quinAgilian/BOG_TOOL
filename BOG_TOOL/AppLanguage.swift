import SwiftUI

/// 应用内中英文切换，不跟随系统。通过按钮切换，实时生效。
final class AppLanguage: ObservableObject {
    private let key = "app_language"

    /// 当前语言："zh-Hans" 或 "en"
    @Published var current: String {
        didSet { UserDefaults.standard.set(current, forKey: key) }
    }

    /// 当前语言对应的 Bundle，用于 NSLocalizedString
    var bundle: Bundle {
        guard let path = Bundle.main.path(forResource: current, ofType: "lproj"),
              let b = Bundle(path: path) else { return .main }
        return b
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: key)
        if let s = saved, s == "en" || s == "zh-Hans" {
            self.current = s
        } else {
            self.current = "zh-Hans"
        }
    }

    /// 取当前语言下的文案
    func string(_ key: String) -> String {
        NSLocalizedString(key, bundle: bundle, value: key, comment: "")
    }

    /// 点击语言按钮时切换语言（中↔英）
    func toggle() {
        current = current == "zh-Hans" ? "en" : "zh-Hans"
    }

    /// 语言切换按钮上显示的文字：当前是中文时显示 "English"，当前是英文时显示 "中文"
    var switchButtonTitle: String {
        current == "zh-Hans" ? string("language.switch_to_en") : string("language.switch_to_zh")
    }
}
