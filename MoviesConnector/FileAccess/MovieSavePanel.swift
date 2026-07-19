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
        directoryURL: URL? = nil,
        message: String? = nil,
        prompt: String? = nil
    ) -> URL? {
        if let presentForTesting {
            let raw = presentForTesting(suggestedName)
            return raw.map(normalizeOutputURL)
        }

        let panel = makePanel(
            suggestedName: suggestedName,
            directoryURL: directoryURL,
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
        directoryURL: URL? = nil,
        message: String? = nil,
        prompt: String? = nil
    ) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [MovieContentTypes.exportType]
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedFileName(from: suggestedName)
        panel.message = message ?? L10n.string("panel.save.message")
        panel.prompt = prompt ?? L10n.string("panel.save.prompt")
        panel.title = L10n.string("panel.save.title")
        if let directoryURL {
            panel.directoryURL = directoryURL
        } else if let managed = DefaultOutputDirectory.managedDirectoryURL() {
            panel.directoryURL = managed
        }
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
