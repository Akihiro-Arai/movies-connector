import Foundation

/// App-language-aware string lookup (follows Settings → Language).
enum L10n {
    static var locale: Locale {
        AppLanguageStore.effectiveLocale()
    }

    static func string(_ key: String.LocalizationValue) -> String {
        string(key, locale: locale)
    }

    static func string(_ key: String.LocalizationValue, locale: Locale) -> String {
        // Force a concrete language bundle. `String(localized:locale:)` alone can still
        // follow the system preferred language on macOS.
        let languageCode = resolvedLanguageCode(for: locale)
        let force = Locale(identifier: languageCode)
        var resource = LocalizedStringResource(key)
        resource.locale = force
        return String(localized: resource)
    }

    private static func resolvedLanguageCode(for locale: Locale) -> String {
        if let code = locale.language.languageCode?.identifier {
            return code
        }
        return "en"
    }
}
