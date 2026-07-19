import Foundation
import UniformTypeIdentifiers

/// Shared content-type policy for open/save panels and Finder drops.
enum MovieContentTypes {
    /// Types accepted as join inputs (open panel + drop filter).
    static let importTypes: [UTType] = [
        .movie,
        .quickTimeMovie,
        .mpeg4Movie,
        .avi,
        .mpeg,
        UTType(filenameExtension: "m4v") ?? .mpeg4Movie,
        UTType(filenameExtension: "mov") ?? .quickTimeMovie,
        UTType(filenameExtension: "mp4") ?? .mpeg4Movie,
    ]

    /// Save panel / export destination type.
    static let exportType: UTType = .quickTimeMovie

    static let exportPathExtension = "mov"

    private static let supportedExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mpg", "mpeg",
    ]

    /// Returns whether `url` should be accepted as a movie input.
    ///
    /// When `typeIdentifier` resolves to a known `UTType`, that result is
    /// definitive (including known non-movie types). Extension fallback applies
    /// only when the identifier is missing or cannot be resolved.
    static func isSupportedMovie(url: URL, typeIdentifier: String?) -> Bool {
        if let typeIdentifier, let type = UTType(typeIdentifier) {
            if type.conforms(to: .movie) {
                return true
            }
            return importTypes.contains(where: { type.conforms(to: $0) })
        }

        let ext = url.pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }
}
