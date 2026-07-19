import AppKit
import Foundation
import UniformTypeIdentifiers

/// Multi-selection open panel for movie inputs.
///
/// Returns user-selected file URLs that carry security-scoped access grants.
/// Does not persist bookmarks (v1).
@MainActor
enum MovieOpenPanel {
    /// Test seam; when set, replaces `NSOpenPanel.runModal()`.
    static var presentForTesting: (() -> [URL]?)?

    static func resetForTesting() {
        presentForTesting = nil
    }

    /// Presents a multi-select movie open panel.
    /// - Returns: Selected URLs in panel order, or `nil` if the user cancelled.
    static func present(
        message: String? = nil,
        prompt: String? = nil
    ) -> [URL]? {
        if let presentForTesting {
            return presentForTesting()
        }

        let panel = makePanel(message: message, prompt: prompt)
        let response = panel.runModal()
        guard response == .OK else { return nil }
        return panel.urls
    }

    /// Builds the configured panel (exposed for configuration tests).
    static func makePanel(
        message: String? = nil,
        prompt: String? = nil
    ) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = MovieContentTypes.importTypes
        panel.message = message ?? L10n.string("panel.open.message")
        panel.prompt = prompt ?? L10n.string("panel.open.prompt")
        panel.title = L10n.string("panel.open.title")
        return panel
    }
}
