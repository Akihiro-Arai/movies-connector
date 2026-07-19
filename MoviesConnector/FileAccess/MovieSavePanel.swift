import AppKit
import Foundation
import UniformTypeIdentifiers

/// Save panel for a single QuickTime Movie (`.mov`) output destination.
///
/// Relies on `NSSavePanel` for existing-file confirmation; callers must not
/// overwrite a destination without that user approval.
/// Does not persist bookmarks (v1).
@MainActor
enum MovieSavePanel {
    /// Test seam; when set, replaces `NSSavePanel.runModal()`.
    static var presentForTesting: ((String) -> URL?)?

    static func resetForTesting() {
        presentForTesting = nil
    }

    /// Presents a save panel and returns a user-approved `.mov` URL, or `nil` if cancelled.
    static func present(
        suggestedName: String = "Joined",
        message: String = "Choose output movie destination",
        prompt: String = "Select"
    ) -> URL? {
        if let presentForTesting {
            let raw = presentForTesting(suggestedName)
            return raw.map(normalizeOutputURL)
        }

        let panel = makePanel(
            suggestedName: suggestedName,
            message: message,
            prompt: prompt
        )
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }
        return normalizeOutputURL(url)
    }

    /// Builds the configured panel (exposed for configuration tests).
    static func makePanel(
        suggestedName: String = "Joined",
        message: String = "Choose output movie destination",
        prompt: String = "Select"
    ) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [MovieContentTypes.exportType]
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedFileName(from: suggestedName)
        panel.message = message
        panel.prompt = prompt
        panel.title = "Export Movie"
        return panel
    }

    /// Ensures the destination uses a `.mov` extension without changing the basename.
    static func normalizeOutputURL(_ url: URL) -> URL {
        if url.pathExtension.lowercased() == MovieContentTypes.exportPathExtension {
            return url
        }
        return url.deletingPathExtension().appendingPathExtension(MovieContentTypes.exportPathExtension)
    }

    /// Normalizes a suggested name so the save panel shows a `.mov` filename.
    static func suggestedFileName(from suggestedName: String) -> String {
        let trimmed = suggestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Joined" : trimmed
        let url = URL(fileURLWithPath: base)
        if url.pathExtension.lowercased() == MovieContentTypes.exportPathExtension {
            return (url as NSURL).lastPathComponent ?? base
        }
        if url.pathExtension.isEmpty {
            return "\(base).\(MovieContentTypes.exportPathExtension)"
        }
        return url.deletingPathExtension()
            .appendingPathExtension(MovieContentTypes.exportPathExtension)
            .lastPathComponent
    }
}
