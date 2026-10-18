import Foundation

/// Content languages: what YouTube is asked for titles, search and feeds in
/// (`hl`, following the device's language) and what caption downloads
/// offer. The interface itself is English only — this fork ships no
/// translations.
enum AppLanguage: String, CaseIterable {
    case english = "en"
    case russian = "ru"
    case ukrainian = "uk"
    case german = "de"
    case spanish = "es"
    case french = "fr"
    case italian = "it"
    case japanese = "ja"
    case portuguese = "pt"
    case turkish = "tr"
    case vietnamese = "vi"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"

    /// The closest supported match to the device's language, else English.
    static var effective: AppLanguage {
        let preferred = Locale.preferredLanguages.first ?? "en"
        if let lang = AppLanguage(rawValue: preferred) {
            return lang
        }
        let parts = preferred.split(separator: "-")
        if parts.count >= 2 {
            let withoutRegion = parts.prefix(2).joined(separator: "-")
            if let lang = AppLanguage(rawValue: withoutRegion) {
                return lang
            }
        }
        let langCode = String(preferred.prefix(2))
        return AppLanguage(rawValue: langCode) ?? .english
    }
}

// MARK: - Display names

extension AppLanguage {
    /// Native-script name, for the caption-language list.
    var displayName: String {
        switch self {
        case .english:
            return "English"
        case .russian:
            return "Русский"
        case .ukrainian:
            return "Українська"
        case .german:
            return "Deutsch"
        case .spanish:
            return "Español"
        case .french:
            return "Français"
        case .italian:
            return "Italiano"
        case .japanese:
            return "日本語"
        case .portuguese:
            return "Português"
        case .turkish:
            return "Türkçe"
        case .vietnamese:
            return "Tiếng Việt"
        case .chineseSimplified:
            return "简体中文"
        case .chineseTraditional:
            return "繁體中文"
        }
    }
}
