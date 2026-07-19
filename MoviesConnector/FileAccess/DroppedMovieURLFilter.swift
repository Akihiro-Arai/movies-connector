import Foundation
import UniformTypeIdentifiers

/// Filters Finder-drop URLs into accepted movie files and caller-visible rejections.
///
/// Order of `accepted` matches input order. Duplicate URLs are intentionally kept —
/// joining the same selected movie more than once remains valid.
enum DroppedMovieURLFilter {
    struct Rejection: Equatable, Sendable {
        var url: URL
        var reason: Reason
    }

    enum Reason: Equatable, Sendable, LocalizedError {
        case notAFileURL
        case notAFile
        case unsupportedType

        var errorDescription: String? {
            switch self {
            case .notAFileURL:
                return "Only file URLs can be added."
            case .notAFile:
                return "Folders and non-file items are not supported."
            case .unsupportedType:
                return "Unsupported file type. Choose a movie file."
            }
        }
    }

    struct Result: Equatable, Sendable {
        var accepted: [URL]
        var rejected: [Rejection]
    }

    /// Describes filesystem metadata; injectable for unit tests.
    struct ResourceInfo: Equatable, Sendable {
        var isRegularFile: Bool
        var typeIdentifier: String?
    }

    /// Test seam; when nil, reads URL resource values from the filesystem.
    static var resourceInfoForTesting: ((URL) -> ResourceInfo?)?

    static func resetForTesting() {
        resourceInfoForTesting = nil
    }

    static func filter(_ urls: [URL]) -> Result {
        var accepted: [URL] = []
        var rejected: [Rejection] = []

        for url in urls {
            guard url.isFileURL else {
                rejected.append(Rejection(url: url, reason: .notAFileURL))
                continue
            }

            guard let info = resourceInfo(for: url) else {
                rejected.append(Rejection(url: url, reason: .notAFile))
                continue
            }

            guard info.isRegularFile else {
                rejected.append(Rejection(url: url, reason: .notAFile))
                continue
            }

            guard MovieContentTypes.isSupportedMovie(url: url, typeIdentifier: info.typeIdentifier) else {
                rejected.append(Rejection(url: url, reason: .unsupportedType))
                continue
            }

            accepted.append(url)
        }

        return Result(accepted: accepted, rejected: rejected)
    }

    private static func resourceInfo(for url: URL) -> ResourceInfo? {
        if let resourceInfoForTesting {
            return resourceInfoForTesting(url)
        }

        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .contentTypeKey,
                .typeIdentifierKey,
            ])
            if values.isDirectory == true {
                return ResourceInfo(isRegularFile: false, typeIdentifier: values.typeIdentifier)
            }
            let isFile = values.isRegularFile == true
            let typeIdentifier = values.contentType?.identifier ?? values.typeIdentifier
            return ResourceInfo(isRegularFile: isFile, typeIdentifier: typeIdentifier)
        } catch {
            return nil
        }
    }
}
