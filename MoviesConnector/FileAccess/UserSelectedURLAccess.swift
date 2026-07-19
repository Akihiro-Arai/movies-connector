import Foundation

/// Errors when preparing local or iCloud user-selected URLs for reading/writing.
enum UserSelectedURLAccessError: Error, LocalizedError, Equatable {
    case securityScopedAccessDenied(URL)
    case iCloudDownloadFailed(URL, String)
    case iCloudItemUnavailable(URL)

    var errorDescription: String? {
        switch self {
        case .securityScopedAccessDenied(let url):
            return "Could not access “\(url.lastPathComponent)”. Reselect the file in the open or save panel."
        case .iCloudDownloadFailed(let url, let detail):
            return "Could not download “\(url.lastPathComponent)” from iCloud: \(detail)"
        case .iCloudItemUnavailable(let url):
            return "“\(url.lastPathComponent)” is not available locally. Download it from iCloud Drive and try again."
        }
    }
}

/// Prepares user-selected URLs (local or iCloud) and holds security-scoped access
/// for the full async operation lifetime. No bookmark persistence in v1.
enum UserSelectedURLAccess {
    /// Test seam for ubiquity detection.
    static var isUbiquitousItemForTesting: ((URL) -> Bool)?
    /// Test seam that replaces iCloud download/wait behavior.
    static var ensureLocalCopyForTesting: ((URL) async throws -> Void)?
    /// When true in tests, a failed `startAccessing` throws instead of being ignored.
    static var requireSecurityScopedAccessForTesting = false

    static func resetForTesting() {
        isUbiquitousItemForTesting = nil
        ensureLocalCopyForTesting = nil
        requireSecurityScopedAccessForTesting = false
        SecurityScopedAccess.resetAccessorsForTesting()
    }

    /// Starts security-scoped access, materializes iCloud items when needed,
    /// runs `perform`, then always releases access (success, error, or cancellation).
    @discardableResult
    static func withPreparedAccess<T>(
        to urls: [URL],
        requireSecurityScopedAccess: Bool = false,
        perform: () async throws -> T
    ) async throws -> T {
        let requireAccess = requireSecurityScopedAccess || requireSecurityScopedAccessForTesting

        return try await SecurityScopedAccess.withAccess(
            to: urls,
            onStartResult: { url, didStart in
                if requireAccess, !didStart {
                    throw UserSelectedURLAccessError.securityScopedAccessDenied(url)
                }
            },
            perform: {
                for url in urls {
                    try await ensureLocalCopyIfNeeded(for: url)
                }
                return try await perform()
            }
        )
    }

    @discardableResult
    static func withPreparedAccess<T>(
        to url: URL,
        requireSecurityScopedAccess: Bool = false,
        perform: () async throws -> T
    ) async throws -> T {
        try await withPreparedAccess(
            to: [url],
            requireSecurityScopedAccess: requireSecurityScopedAccess,
            perform: perform
        )
    }

    private static func ensureLocalCopyIfNeeded(for url: URL) async throws {
        if let ensureLocalCopyForTesting {
            try await ensureLocalCopyForTesting(url)
            return
        }

        guard isUbiquitousItem(url) else { return }

        if let error = ubiquitousDownloadingError(for: url) {
            throw UserSelectedURLAccessError.iCloudDownloadFailed(url, error.localizedDescription)
        }

        if isUbiquitousDownloadCurrent(for: url) {
            return
        }

        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            throw UserSelectedURLAccessError.iCloudDownloadFailed(url, error.localizedDescription)
        }

        // Poll briefly for a local copy; surface a clear error if still unavailable.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if Task.isCancelled {
                throw CancellationError()
            }
            if let error = ubiquitousDownloadingError(for: url) {
                throw UserSelectedURLAccessError.iCloudDownloadFailed(url, error.localizedDescription)
            }
            if isUbiquitousDownloadCurrent(for: url) {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        throw UserSelectedURLAccessError.iCloudItemUnavailable(url)
    }

    private static func isUbiquitousItem(_ url: URL) -> Bool {
        if let isUbiquitousItemForTesting {
            return isUbiquitousItemForTesting(url)
        }
        return (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
    }

    private static func isUbiquitousDownloadCurrent(for url: URL) -> Bool {
        guard
            let values = try? url.resourceValues(forKeys: [
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemIsDownloadingKey,
            ])
        else {
            return FileManager.default.isReadableFile(atPath: url.path)
        }

        if values.ubiquitousItemDownloadingStatus == URLUbiquitousItemDownloadingStatus.current {
            return true
        }
        if values.ubiquitousItemIsDownloading == true {
            return false
        }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    private static func ubiquitousDownloadingError(for url: URL) -> Error? {
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey])
        return values?.ubiquitousItemDownloadingError
    }
}
