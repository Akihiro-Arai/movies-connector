import Foundation

/// Security-scoped bookmark access is out of scope for v1.
/// Call sites must start/stop access around each user-selected URL for the duration of a join job.
enum SecurityScopedAccess {
    /// Test seam; when nil, uses Foundation security-scoped APIs.
    static var startAccessingForTesting: ((URL) -> Bool)?
    /// Test seam; when nil, uses Foundation security-scoped APIs.
    static var stopAccessingForTesting: ((URL) -> Void)?

    static func resetAccessorsForTesting() {
        startAccessingForTesting = nil
        stopAccessingForTesting = nil
    }

    @discardableResult
    static func withAccess<T>(to url: URL, perform: () throws -> T) rethrows -> T {
        try withAccess(to: [url], perform: perform)
    }

    @discardableResult
    static func withAccess<T>(to urls: [URL], perform: () throws -> T) rethrows -> T {
        let started = urls.map { ($0, startAccessing($0)) }
        defer { stopAccessing(started) }
        return try perform()
    }

    /// Keeps security-scoped access alive across the full async job (including suspension points).
    @discardableResult
    static func withAccess<T>(to url: URL, perform: () async throws -> T) async rethrows -> T {
        try await withAccess(to: [url], perform: perform)
    }

    /// Keeps security-scoped access alive across the full async job (including suspension points).
    @discardableResult
    static func withAccess<T>(to urls: [URL], perform: () async throws -> T) async rethrows -> T {
        let started = urls.map { ($0, startAccessing($0)) }
        defer { stopAccessing(started) }
        return try await perform()
    }

    private static func startAccessing(_ url: URL) -> Bool {
        if let startAccessingForTesting {
            return startAccessingForTesting(url)
        }
        return url.startAccessingSecurityScopedResource()
    }

    private static func stopAccessing(_ started: [(URL, Bool)]) {
        for (url, didStart) in started where didStart {
            if let stopAccessingForTesting {
                stopAccessingForTesting(url)
            } else {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }
}
