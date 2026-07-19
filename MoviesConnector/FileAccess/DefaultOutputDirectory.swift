import Foundation

/// Default joined-video location: `~/Movies/Movies Connector/`.
enum DefaultOutputDirectory {
    static let folderName = "Movies Connector"

    /// Test seam replacing the system Movies directory.
    static var moviesDirectoryForTesting: URL?

    static func resetForTesting() {
        moviesDirectoryForTesting = nil
    }

    /// `~/Movies` (or the test seam).
    static func moviesDirectoryURL() -> URL? {
        if let moviesDirectoryForTesting {
            return moviesDirectoryForTesting
        }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
    }

    /// `~/Movies/Movies Connector`
    static func managedDirectoryURL() -> URL? {
        moviesDirectoryURL()?.appendingPathComponent(folderName, isDirectory: true)
    }

    static func isInsideManagedDirectory(_ url: URL) -> Bool {
        guard let root = managedDirectoryURL()?.standardizedFileURL.path else { return false }
        let path = url.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    /// True for any path under the user's Movies folder (entitlement-backed).
    static func isInsideMoviesDirectory(_ url: URL) -> Bool {
        guard let root = moviesDirectoryURL()?.standardizedFileURL.path else { return false }
        let path = url.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    static func fileURL(in directory: URL, fileName: String) -> URL {
        directory.appendingPathComponent(normalizedFileName(fileName))
    }

    /// Picks `name.mov`, then `name-2.mov`, `name-3.mov`, … so automatic defaults never
    /// silently replace an existing export (#18).
    static func uniqueFileURL(
        in directory: URL,
        fileName: String,
        fileManager: FileManager = .default
    ) -> URL {
        let normalized = normalizedFileName(fileName)
        let preferred = directory.appendingPathComponent(normalized)
        if !fileManager.fileExists(atPath: preferred.path) {
            return preferred
        }

        let stem = (normalized as NSString).deletingPathExtension
        let ext = (normalized as NSString).pathExtension
        var suffix = 2
        while true {
            let candidate = directory.appendingPathComponent("\(stem)-\(suffix).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    private static func normalizedFileName(_ fileName: String) -> String {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "joined" : trimmed
        let candidate = URL(fileURLWithPath: base)
        if candidate.pathExtension.lowercased() == MovieContentTypes.exportPathExtension {
            return candidate.lastPathComponent
        }
        if candidate.pathExtension.isEmpty {
            return "\(base).\(MovieContentTypes.exportPathExtension)"
        }
        return candidate
            .deletingPathExtension()
            .appendingPathExtension(MovieContentTypes.exportPathExtension)
            .lastPathComponent
    }

    /// Creates `Movies/Movies Connector` when missing.
    @discardableResult
    static func ensureManagedDirectoryExists() throws -> URL {
        guard let directory = managedDirectoryURL() else {
            throw DefaultOutputDirectoryError.moviesDirectoryUnavailable
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}

enum DefaultOutputDirectoryError: Error, LocalizedError, Equatable {
    case moviesDirectoryUnavailable

    var errorDescription: String? {
        switch self {
        case .moviesDirectoryUnavailable:
            return L10n.string("error.movies_unavailable")
        }
    }
}
