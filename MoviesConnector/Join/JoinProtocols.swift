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

enum AssetInspectionTimeoutError: Error, LocalizedError {
    case timedOut(URL)

    var errorDescription: String? {
        switch self {
        case .timedOut(let url):
            return L10n.string("status.inspect_timeout \(url.lastPathComponent)")
        }
    }
}

/// Production inspector seam — wraps `AssetInspector` without modifying Media/.
struct DefaultAssetInspector: AssetInspecting {
    /// AVFoundation can hang forever on some assets; bound the wait.
    static var inspectTimeout: TimeInterval = 45
    static var inspectTimeoutForTesting: TimeInterval?

    static func resetForTesting() {
        inspectTimeoutForTesting = nil
        inspectTimeout = 45
    }

    func inspect(url: URL) async throws -> JoinInspectionResult {
        let timeout = Self.inspectTimeoutForTesting ?? Self.inspectTimeout
        return try await withThrowingTaskGroup(of: JoinInspectionResult.self) { group in
            group.addTask {
                try await Self.inspectUnbounded(url: url)
            }
            group.addTask {
                let ns = UInt64(max(timeout, 0.1) * 1_000_000_000)
                try await Task.sleep(nanoseconds: ns)
                try Task.checkCancellation()
                throw AssetInspectionTimeoutError.timedOut(url)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func inspectUnbounded(url: URL) async throws -> JoinInspectionResult {
        try await UserSelectedURLAccess.withPreparedAccess(to: url) {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            try Task.checkCancellation()
            let seconds: TimeInterval
            if duration.isValid && !duration.isIndefinite {
                seconds = duration.seconds
            } else {
                seconds = 0
            }
            let signature = try await AssetInspector.makeSignature(for: asset)
            try Task.checkCancellation()
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
            MovieSavePanel.present(
                suggestedName: suggestedName,
                directoryURL: DefaultOutputDirectory.managedDirectoryURL()
            )
        }
    }
}

// MARK: - Export

protocol JoinExporting: Sendable {
    /// - Parameter replaceExistingDestination: When `false`, commit never replaces an
    ///   existing file (managed defaults — #18). May write to a uniquified sibling path.
    /// - Returns: The URL actually written (may differ from `outputURL` when uniquified).
    func join(
        inputURLs: [URL],
        outputURL: URL,
        replaceExistingDestination: Bool,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL
}

extension JoinExporting {
    func join(
        inputURLs: [URL],
        outputURL: URL,
        replaceExistingDestination: Bool = true
    ) async throws -> URL {
        try await join(
            inputURLs: inputURLs,
            outputURL: outputURL,
            replaceExistingDestination: replaceExistingDestination,
            progress: nil
        )
    }
}

/// Production export seam — forwards to `JoinExporter` (access + preflight + passthrough).
struct DefaultJoinExporter: JoinExporting {
    func join(
        inputURLs: [URL],
        outputURL: URL,
        replaceExistingDestination: Bool,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let result = try await JoinExporter.join(
            inputURLs: inputURLs,
            outputURL: outputURL,
            replaceExistingDestination: replaceExistingDestination,
            progress: progress
        )
        return result.outputURL
    }
}
