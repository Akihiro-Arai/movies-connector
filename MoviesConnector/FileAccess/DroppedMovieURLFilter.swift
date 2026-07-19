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
                return L10n.string("filter.not_file_url")
            case .notAFile:
                return L10n.string("filter.not_a_file")
            case .unsupportedType:
                return L10n.string("filter.unsupported_type")
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

    static func filter(_ urls: [URL], diagnostics: DropDiagnostics? = nil) -> Result {
        diagnostics?.section("DroppedMovieURLFilter")
        diagnostics?.log("input count=\(urls.count)")

        var accepted: [URL] = []
        var rejected: [Rejection] = []

        for (index, url) in urls.enumerated() {
            diagnostics?.log("[\(index)] path=\(url.path) isFileURL=\(url.isFileURL)")

            guard url.isFileURL else {
                rejected.append(Rejection(url: url, reason: .notAFileURL))
                diagnostics?.log("[\(index)] REJECT notAFileURL")
                continue
            }

            guard let info = resourceInfo(for: url, diagnostics: diagnostics) else {
                rejected.append(Rejection(url: url, reason: .notAFile))
                diagnostics?.log("[\(index)] REJECT notAFile (no resource info)")
                continue
            }

            diagnostics?.log(
                "[\(index)] isRegularFile=\(info.isRegularFile) typeIdentifier=\(info.typeIdentifier ?? "nil") ext=\(url.pathExtension)"
            )

            guard info.isRegularFile else {
                rejected.append(Rejection(url: url, reason: .notAFile))
                diagnostics?.log("[\(index)] REJECT notAFile (not regular file)")
                continue
            }

            let supported = MovieContentTypes.isSupportedMovie(
                url: url,
                typeIdentifier: info.typeIdentifier
            )
            guard supported else {
                rejected.append(Rejection(url: url, reason: .unsupportedType))
                diagnostics?.log("[\(index)] REJECT unsupportedType")
                continue
            }

            accepted.append(url)
            diagnostics?.log("[\(index)] ACCEPT")
        }

        diagnostics?.log("accepted=\(accepted.count) rejected=\(rejected.count)")
        return Result(accepted: accepted, rejected: rejected)
    }

    private static func resourceInfo(
        for url: URL,
        diagnostics: DropDiagnostics? = nil
    ) -> ResourceInfo? {
        if let resourceInfoForTesting {
            return resourceInfoForTesting(url)
        }

        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .contentTypeKey,
                .typeIdentifierKey,
                .fileSizeKey,
                .isReadableKey,
            ])
            diagnostics?.log(
                "resourceValues size=\(values.fileSize.map(String.init) ?? "?") readable=\(values.isReadable.map(String.init(describing:)) ?? "?") isDirectory=\(values.isDirectory.map(String.init(describing:)) ?? "?")"
            )
            if values.isDirectory == true {
                return ResourceInfo(isRegularFile: false, typeIdentifier: values.typeIdentifier)
            }
            let isFile = values.isRegularFile == true
            let typeIdentifier = values.contentType?.identifier ?? values.typeIdentifier
            return ResourceInfo(isRegularFile: isFile, typeIdentifier: typeIdentifier)
        } catch {
            diagnostics?.logError("resourceValues(\(url.lastPathComponent))", error)
            return nil
        }
    }
}
