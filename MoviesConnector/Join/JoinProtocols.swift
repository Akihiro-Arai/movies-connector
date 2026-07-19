import AVFoundation
import Foundation

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
        try await UserSelectedURLAccess.withPreparedAccess(to: url) {
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

/// Open-panel adapter over `MovieOpenPanel` (FileAccess).
final class SystemVideoFileSelector: VideoFileSelecting {
    func selectVideos() async -> [URL] {
        await MainActor.run {
            MovieOpenPanel.present() ?? []
        }
    }
}

/// Save-panel adapter over `MovieSavePanel` (FileAccess), including `.mov` normalization.
final class SystemOutputDestinationSelector: OutputDestinationSelecting {
    func selectOutputDestination(suggestedName: String) async -> URL? {
        await MainActor.run {
            MovieSavePanel.present(suggestedName: suggestedName)
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
        try await UserSelectedURLAccess.withPreparedAccess(to: scoped) {
            try await JoinExporter.join(inputURLs: inputURLs, outputURL: outputURL)
        }
    }
}
