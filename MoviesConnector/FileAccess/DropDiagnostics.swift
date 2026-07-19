import Foundation

/// Thread-safe transcript builder for drop / import debugging.
/// Shown in the UI as selectable, copyable text.
final class DropDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var transcript: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lines.isEmpty
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }

    func section(_ title: String) {
        append("—— \(title) ——")
    }

    func log(_ message: String) {
        append(message)
    }

    func logError(_ prefix: String, _ error: Error) {
        let ns = error as NSError
        append(
            "\(prefix): \(error.localizedDescription) | domain=\(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)"
        )
    }

    private func append(_ message: String) {
        let stamp = Self.timestamp()
        lock.lock()
        lines.append("[\(stamp)] \(message)")
        lock.unlock()
        // Also emit to Console.app / Xcode for developers.
        NSLog("[MoviesConnector] %@", message)
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func timestamp() -> String {
        formatter.string(from: Date())
    }
}
