import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

// MARK: - Inspection

/// Join-owned inspection payload (independent of Media/ preflight types).
struct JoinInspectionResult: Equatable, Sendable {
    var duration: TimeInterval
    var signature: CompatibilitySignature
}

protocol AssetInspecting: Sendable {
    func inspect(url: URL) async throws -> JoinInspectionResult
}

/// Production inspector seam — wraps `AssetInspector` without modifying Media/.
struct DefaultAssetInspector: AssetInspecting {
    func inspect(url: URL) async throws -> JoinInspectionResult {
        try await SecurityScopedAccess.withAccess(to: url) {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let seconds: TimeInterval
            if duration.isValid && !duration.isIndefinite {
                seconds = duration.seconds
            } else {
                seconds = 0
            }
            let signature = try await AssetInspector.makeSignature(for: asset)
            return JoinInspectionResult(duration: seconds, signature: signature)
        }
    }
}

// MARK: - File selection

protocol VideoFileSelecting: AnyObject {
    func selectVideos() async -> [URL]
}

protocol OutputDestinationSelecting: AnyObject {
    func selectOutputDestination(suggestedName: String) async -> URL?
}

/// Open-panel wrapper. Panel UI runs on the main actor; type itself is not `@MainActor`.
final class SystemVideoFileSelector: VideoFileSelecting {
    func selectVideos() async -> [URL] {
        await MainActor.run {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowedContentTypes = Self.videoContentTypes
            panel.message = "Select videos to join"
            panel.prompt = "Add"
            guard panel.runModal() == .OK else { return [] }
            return panel.urls
        }
    }

    static let videoContentTypes: [UTType] = {
        var types: [UTType] = [.movie, .quickTimeMovie, .mpeg4Movie, .avi, .mpeg]
        if let m4v = UTType(filenameExtension: "m4v") { types.append(m4v) }
        return types
    }()
}

/// Save-panel wrapper. Panel UI runs on the main actor; type itself is not `@MainActor`.
final class SystemOutputDestinationSelector: OutputDestinationSelecting {
    func selectOutputDestination(suggestedName: String) async -> URL? {
        await MainActor.run {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.quickTimeMovie]
            panel.nameFieldStringValue = suggestedName
            panel.message = "Choose output movie destination"
            panel.prompt = "Select"
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        }
    }
}

// MARK: - Export

protocol JoinExporting: Sendable {
    func join(inputURLs: [URL], outputURL: URL) async throws
}

/// Production export seam — wraps `JoinExporter` without modifying Media/.
struct DefaultJoinExporter: JoinExporting {
    func join(inputURLs: [URL], outputURL: URL) async throws {
        var scoped = inputURLs
        scoped.append(outputURL)
        _ = try await SecurityScopedAccess.withAccess(to: scoped) {
            try await JoinExporter.join(inputURLs: inputURLs, outputURL: outputURL)
        }
    }
}
