import Foundation
import Observation
import SwiftUI

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// Keep language names native so the picker remains understandable while
    /// the rest of the interface is switching languages.
    var displayName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }
}

@Observable
private final class LocalizationState {
    var language: AppLanguage

    init(language: AppLanguage = .english) {
        self.language = language
    }
}

enum Localization {
    private static let state = LocalizationState()

    /// SwiftUI tracks reads of this observable value, so views that use
    /// `Localization.string` are invalidated as soon as Settings changes the
    /// app language instead of retaining the previous language's strings.
    static var current: AppLanguage {
        get { state.language }
        set { state.language = newValue }
    }

    /// Use the first preferred system language only when the user has not
    /// selected a language in Settings. Chinese locales use Simplified
    /// Chinese; every other locale falls back to English.
    static var systemDefaultLanguage: AppLanguage {
        defaultLanguage(for: Locale.preferredLanguages)
    }

    static func defaultLanguage(for preferredLanguages: [String]) -> AppLanguage {
        guard let preferredLanguage = preferredLanguages.first else {
            return .english
        }

        let languageCode = preferredLanguage
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init)?
            .lowercased()

        return languageCode == "zh" ? .simplifiedChinese : .english
    }

    static func string(_ key: String) -> String {
        let language = state.language
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return key
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

private struct AppLanguageLocaleModifier: ViewModifier {
    func body(content: Content) -> some View {
        // Reading Localization.current here makes SwiftUI update localized
        // string literals as well as strings resolved through Localization.
        content.environment(\.locale, Localization.current.locale)
    }
}

extension View {
    /// Applies Captures' in-app language to a SwiftUI hierarchy and refreshes
    /// it immediately when that language changes.
    func appLanguageLocale() -> some View {
        modifier(AppLanguageLocaleModifier())
    }
}

extension Notification.Name {
    static let languageChanged = Notification.Name("languageChanged")
}
