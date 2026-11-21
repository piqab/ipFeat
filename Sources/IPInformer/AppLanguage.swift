import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case russian = "ru"
    case simplifiedChinese = "zh-Hans"

    static let preferenceKey = "preferredAppLanguage"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System / Система / 系统"
        case .english: return "English"
        case .russian: return "Русский"
        case .simplifiedChinese: return "简体中文"
        }
    }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .system
    }

    static var locale: Locale {
        current == .system ? .autoupdatingCurrent : Locale(identifier: current.rawValue)
    }

    static func localized(_ key: String) -> String {
        guard current != .system,
              let path = Bundle.main.path(forResource: current.rawValue, ofType: "lproj"),
              let languageBundle = Bundle(path: path) else {
            return Bundle.main.localizedString(forKey: key, value: key, table: nil)
        }
        return languageBundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func applyAtLaunch() {
        let saved = UserDefaults.standard.string(forKey: preferenceKey) ?? system.rawValue
        let selected = AppLanguage(rawValue: saved) ?? .system
        if selected == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([selected.rawValue], forKey: "AppleLanguages")
        }
    }

    static func set(_ rawValue: String) {
        let selected = AppLanguage(rawValue: rawValue) ?? .system
        UserDefaults.standard.set(selected.rawValue, forKey: preferenceKey)
        applyAtLaunch()
    }
}
