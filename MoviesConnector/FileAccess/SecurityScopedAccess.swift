import Foundation

/// Security-scoped bookmark access is out of scope for v1.
/// Call sites must start/stop access around each user-selected URL for the duration of a join job.
enum SecurityScopedAccess {
    @discardableResult
    static func withAccess<T>(to url: URL, perform: () throws -> T) rethrows -> T {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try perform()
    }

    @discardableResult
    static func withAccess<T>(to urls: [URL], perform: () throws -> T) rethrows -> T {
        let started = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        defer {
            for (url, didStart) in started where didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try perform()
    }
}
