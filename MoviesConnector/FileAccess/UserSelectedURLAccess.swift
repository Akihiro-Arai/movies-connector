import Foundation

/// Errors when preparing local or iCloud user-selected URLs for reading/writing.
enum UserSelectedURLAccessError: Error, LocalizedError, Equatable {
    case securityScopedAccessDenied(URL)
    case iCloudDownloadFailed(URL, String)
    case iCloudItemUnavailable(URL)
    case iCloudDownloadTimedOut(URL)

    var errorDescription: String? {
        switch self {
        case .securityScopedAccessDenied(let url):
            return L10n.string("error.access_denied \(url.lastPathComponent)")
        case .iCloudDownloadFailed(let url, let detail):
            return L10n.string("error.icloud_download_failed \(url.lastPathComponent) \(detail)")
        case .iCloudItemUnavailable(let url):
            return L10n.string("error.icloud_unavailable \(url.lastPathComponent)")
        case .iCloudDownloadTimedOut(let url):
            return L10n.string("error.icloud_timeout \(url.lastPathComponent)")
        }
    }
}

/// Snapshot of ubiquity resource values used by the iCloud download state machine.
struct UbiquitousItemState: Equatable, Sendable {
    var isUbiquitous: Bool
    var downloadingStatus: URLUbiquitousItemDownloadingStatus?
    var isDownloading: Bool
    var downloadingErrorDescription: String?
    var isReadable: Bool
}

/// Prepares user-selected URLs (local or iCloud) and holds security-scoped access
/// for the full async operation lifetime. No bookmark persistence in v1.
enum UserSelectedURLAccess {
    /// Test seam for ubiquity resource values (production path).
    static var ubiquitousItemStateForTesting: ((URL) -> UbiquitousItemState)?
    /// Test seam for `FileManager.startDownloadingUbiquitousItem`.
    static var startDownloadingForTesting: ((URL) throws -> Void)?
    /// Test seam for poll sleep.
    static var sleepForTesting: ((UInt64) async throws -> Void)?
    /// Test seam for optional caller timeout clock.
    static var nowForTesting: (() -> Date)?

    static func resetForTesting() {
        ubiquitousItemStateForTesting = nil
        startDownloadingForTesting = nil
        sleepForTesting = nil
        nowForTesting = nil
        SecurityScopedAccess.resetAccessorsForTesting()
    }

    /// Starts security-scoped access, materializes iCloud items when needed,
    /// runs `perform`, then always releases access (success, error, or cancellation).
    ///
    /// - Parameters:
    ///   - requireSecurityScopedAccess: Defaults to `true`. Denial throws
    ///     `securityScopedAccessDenied`. Pass `false` only for explicit opt-out.
    ///   - iCloudDownloadTimeout: Optional caller policy. `nil` waits until the
    ///     item is current, an explicit download error occurs, the item is
    ///     unavailable (not downloading), or the task is cancelled.
    @discardableResult
    static func withPreparedAccess<T>(
        to urls: [URL],
        requireSecurityScopedAccess: Bool = true,
        iCloudDownloadTimeout: TimeInterval? = nil,
        perform: () async throws -> T
    ) async throws -> T {
        try await SecurityScopedAccess.withAccess(
            to: urls,
            onStartResult: { url, didStart in
                if requireSecurityScopedAccess,
                   !didStart,
                   requiresSecurityScopedAccess(for: url)
                {
                    throw UserSelectedURLAccessError.securityScopedAccessDenied(url)
                }
            },
            perform: {
                for url in urls {
                    try await ensureLocalCopyIfNeeded(
                        for: url,
                        downloadTimeout: iCloudDownloadTimeout
                    )
                }
                return try await perform()
            }
        )
    }

    /// Security-scoped access is only required for files outside the app container that
    /// are not already readable (e.g. open/save panel picks). Photos / file-promise drops
    /// are copied into the container first — those must not demand a security scope.
    /// Movies-folder paths are covered by `com.apple.security.assets.movies.read-write`.
    static func requiresSecurityScopedAccess(for url: URL) -> Bool {
        guard url.isFileURL else { return true }
        if isAppManagedFileURL(url) {
            return false
        }
        if DefaultOutputDirectory.isInsideMoviesDirectory(url) {
            return false
        }
        if FileManager.default.isReadableFile(atPath: url.path) {
            return false
        }
        return true
    }

    /// Sandbox container paths (tmp / caches / Application Support / container home).
    static func isAppManagedFileURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.standardizedFileURL.path
        let roots = appManagedDirectoryPaths()
        return roots.contains { root in
            path == root || path.hasPrefix(root + "/")
        }
    }

    private static func appManagedDirectoryPaths() -> [String] {
        var roots: [String] = [
            FileManager.default.temporaryDirectory.standardizedFileURL.path,
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path,
        ]
        let search: [FileManager.SearchPathDirectory] = [
            .cachesDirectory,
            .applicationSupportDirectory,
            .documentDirectory,
        ]
        for directory in search {
            if let url = FileManager.default.urls(for: directory, in: .userDomainMask).first {
                roots.append(url.standardizedFileURL.path)
            }
        }
        return roots
    }

    @discardableResult
    static func withPreparedAccess<T>(
        to url: URL,
        requireSecurityScopedAccess: Bool = true,
        iCloudDownloadTimeout: TimeInterval? = nil,
        perform: () async throws -> T
    ) async throws -> T {
        try await withPreparedAccess(
            to: [url],
            requireSecurityScopedAccess: requireSecurityScopedAccess,
            iCloudDownloadTimeout: iCloudDownloadTimeout,
            perform: perform
        )
    }

    private static func ensureLocalCopyIfNeeded(
        for url: URL,
        downloadTimeout: TimeInterval?
    ) async throws {
        let initial = itemState(for: url)
        guard initial.isUbiquitous else { return }

        if let detail = initial.downloadingErrorDescription {
            throw UserSelectedURLAccessError.iCloudDownloadFailed(url, detail)
        }

        if isDownloadSatisfied(initial) {
            return
        }

        do {
            try startDownloading(url)
        } catch {
            throw UserSelectedURLAccessError.iCloudDownloadFailed(url, error.localizedDescription)
        }

        let deadline = downloadTimeout.map { now().addingTimeInterval($0) }

        while true {
            if Task.isCancelled {
                throw CancellationError()
            }

            let state = itemState(for: url)

            if let detail = state.downloadingErrorDescription {
                throw UserSelectedURLAccessError.iCloudDownloadFailed(url, detail)
            }

            if isDownloadSatisfied(state) {
                return
            }

            // In-progress transfers are never treated as unavailable.
            if state.isDownloading {
                if let deadline, now() >= deadline {
                    throw UserSelectedURLAccessError.iCloudDownloadTimedOut(url)
                }
                try await sleep(nanoseconds: 100_000_000)
                continue
            }

            // Not current/readable and not downloading → unavailable.
            throw UserSelectedURLAccessError.iCloudItemUnavailable(url)
        }
    }

    private static func isDownloadSatisfied(_ state: UbiquitousItemState) -> Bool {
        if state.downloadingStatus == URLUbiquitousItemDownloadingStatus.current {
            return true
        }
        if state.isDownloading {
            return false
        }
        return state.isReadable
    }

    private static func itemState(for url: URL) -> UbiquitousItemState {
        if let ubiquitousItemStateForTesting {
            return ubiquitousItemStateForTesting(url)
        }

        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemDownloadingErrorKey,
        ])

        return UbiquitousItemState(
            isUbiquitous: values?.isUbiquitousItem == true,
            downloadingStatus: values?.ubiquitousItemDownloadingStatus,
            isDownloading: values?.ubiquitousItemIsDownloading == true,
            downloadingErrorDescription: values?.ubiquitousItemDownloadingError?.localizedDescription,
            isReadable: FileManager.default.isReadableFile(atPath: url.path)
        )
    }

    private static func startDownloading(_ url: URL) throws {
        if let startDownloadingForTesting {
            try startDownloadingForTesting(url)
            return
        }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    private static func sleep(nanoseconds: UInt64) async throws {
        if let sleepForTesting {
            try await sleepForTesting(nanoseconds)
            return
        }
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    private static func now() -> Date {
        if let nowForTesting {
            return nowForTesting()
        }
        return Date()
    }
}
