import AppKit
import Foundation

/// First-run permission UX for writing into `~/Movies/Movies Connector`.
///
/// Access itself comes from `com.apple.security.assets.movies.read-write`.
/// macOS does not show a system TCC dialog for that entitlement, so we present
/// an explicit Allow / Not Now confirmation before creating the folder.
@MainActor
enum MoviesOutputAccess {
    static let grantedDefaultsKey = "moviesOutputDirectoryGranted"

    /// Test seam replacing the confirmation alert (`true` = Allow).
    static var confirmForTesting: (() -> Bool)?
    /// Test seam for UserDefaults persistence.
    static var defaultsForTesting: UserDefaults?

    static func resetForTesting() {
        confirmForTesting = nil
        if let defaultsForTesting {
            defaultsForTesting.removeObject(forKey: grantedDefaultsKey)
        }
        defaultsForTesting = nil
    }

    private static var defaults: UserDefaults {
        defaultsForTesting ?? .standard
    }

    static var hasGrantedAccess: Bool {
        defaults.bool(forKey: grantedDefaultsKey)
    }

    /// Ensures the managed Movies subdirectory exists after an Allow confirmation.
    /// Returns `nil` when the user chooses Not Now or creation fails.
    static func requestDefaultDirectoryIfNeeded() -> URL? {
        if hasGrantedAccess {
            return try? DefaultOutputDirectory.ensureManagedDirectoryExists()
        }

        // App launches as TEST_HOST during unit tests — never block on NSAlert there.
        if confirmForTesting == nil, isRunningUnderXCTest {
            return nil
        }

        guard confirmAccess() else {
            return nil
        }

        do {
            let directory = try DefaultOutputDirectory.ensureManagedDirectoryExists()
            defaults.set(true, forKey: grantedDefaultsKey)
            return directory
        } catch {
            presentCreationFailure(error)
            return nil
        }
    }

    private static func confirmAccess() -> Bool {
        if let confirmForTesting {
            return confirmForTesting()
        }

        let moviesName = DefaultOutputDirectory.moviesDirectoryURL()?.lastPathComponent ?? "Movies"
        let folder = "\(moviesName)/\(DefaultOutputDirectory.folderName)"

        let alert = NSAlert()
        alert.messageText = L10n.string("permission.movies.title \(moviesName)")
        alert.informativeText = L10n.string("permission.movies.body \(folder)")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.string("permission.allow"))
        alert.addButton(withTitle: L10n.string("permission.not_now"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func presentCreationFailure(_ error: Error) {
        if confirmForTesting != nil || isRunningUnderXCTest {
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.string("permission.create_failed.title")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("permission.ok"))
        alert.runModal()
    }

    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
