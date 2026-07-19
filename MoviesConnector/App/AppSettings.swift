import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case japanese

    var id: String { rawValue }
}

enum AppLanguageStore {
    static let defaultsKey = "appLanguage"

    /// Test seam for UserDefaults (unit tests only).
    nonisolated(unsafe) static var defaultsForTesting: UserDefaults?

    static var defaults: UserDefaults {
        defaultsForTesting ?? .standard
    }

    static var storedLanguage: AppLanguage {
        let raw = defaults.string(forKey: defaultsKey) ?? ""
        return AppLanguage(rawValue: raw) ?? .system
    }

    /// Locale for `String(localized:)` — safe from any isolation domain.
    static func effectiveLocale() -> Locale {
        switch storedLanguage {
        case .english:
            return Locale(identifier: "en")
        case .japanese:
            return Locale(identifier: "ja")
        case .system:
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                return Locale(identifier: "en")
            }
            return .autoupdatingCurrent
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var language: AppLanguage {
        didSet {
            AppLanguageStore.defaults.set(language.rawValue, forKey: AppLanguageStore.defaultsKey)
        }
    }

    var effectiveLocale: Locale {
        AppLanguageStore.effectiveLocale()
    }

    init() {
        language = AppLanguageStore.storedLanguage
    }

    static func resetForTesting() {
        AppLanguageStore.defaultsForTesting?.removeObject(forKey: AppLanguageStore.defaultsKey)
        AppLanguageStore.defaultsForTesting = nil
        shared.language = .system
    }
}
