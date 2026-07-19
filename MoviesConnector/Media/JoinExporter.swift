import AVFoundation
import Foundation

enum JoinExporterError: Error, LocalizedError, Equatable {
    case emptyInput
    case incompatible([String])
    case cannotCreateComposition
    case cannotCreateExportSession
    case exportFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "No input URLs provided"
        case .incompatible(let reasons):
            return "Inputs are incompatible for passthrough: \(reasons.joined(separator: "; "))"
        case .cannotCreateComposition:
            return "Failed to build AVMutableComposition"
        case .cannotCreateExportSession:
            return "Failed to create AVAssetExportSession for passthrough"
        case .exportFailed(let detail):
            return "Export failed: \(detail)"
        case .cancelled:
            return "Export cancelled"
        }
    }
}

/// Spike / v1 engine: concatenate compatible movies with lossless passthrough.
///
/// Pipeline:
/// 1. Inspect each input → `CompatibilitySignature`
/// 2. Reject if any pair mismatches (no re-encode path)
/// 3. `AVMutableComposition` insert video (and audio if present) in order
/// 4. `AVAssetExportSession` + `AVAssetExportPresetPassthrough` → `.mov`
enum JoinExporter {
    struct Result: Sendable {
        var outputURL: URL
        var elapsedNanoseconds: UInt64
        var inputCount: Int
    }

    /// Joins `inputURLs` in order to `outputURL` using passthrough export.
    /// Caller is responsible for security-scoped access around the URLs.
    ///
    /// Writes to a temporary file first, then replaces/moves into `outputURL` only on success,
    /// so an existing destination is never deleted before a successful export.
    static func join(
        inputURLs: [URL],
        outputURL: URL,
        preflight: Bool = true
    ) async throws -> Result {
        guard !inputURLs.isEmpty else { throw JoinExporterError.emptyInput }

        if preflight {
            try await preflightCompatibility(inputURLs: inputURLs)
        }

        let composition = AVMutableComposition()
        guard
            let compositionVideo = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
            throw JoinExporterError.cannotCreateComposition
        }

        var compositionAudio: AVMutableCompositionTrack?
        var cursor = CMTime.zero

        for url in inputURLs {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.load(.tracks)
            let videoTrack = try firstTrack(in: tracks, mediaType: .video)
            let duration = try await asset.load(.duration)
            let timeRange = CMTimeRange(start: .zero, duration: duration)

            try compositionVideo.insertTimeRange(timeRange, of: videoTrack, at: cursor)

            if let preferredTransform = try? await videoTrack.load(.preferredTransform) {
                compositionVideo.preferredTransform = preferredTransform
            }

            if let audioTrack = optionalTrack(in: tracks, mediaType: .audio) {
                if compositionAudio == nil {
                    compositionAudio = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                }
                try compositionAudio?.insertTimeRange(timeRange, of: audioTrack, at: cursor)
            }

            cursor = CMTimeAdd(cursor, duration)
        }

        guard
            let exportSession = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetPassthrough
            )
        else {
            throw JoinExporterError.cannotCreateExportSession
        }

        exportSession.shouldOptimizeForNetworkUse = false

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("movies-connector-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let started = DispatchTime.now().uptimeNanoseconds
        do {
            try await exportSession.export(to: tempURL, as: .mov)
        } catch is CancellationError {
            throw JoinExporterError.cancelled
        } catch {
            throw JoinExporterError.exportFailed(error.localizedDescription)
        }

        try installExport(from: tempURL, to: outputURL)

        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        return Result(outputURL: outputURL, elapsedNanoseconds: elapsed, inputCount: inputURLs.count)
    }

    /// Immediate preflight before export — reuses `AssetInspector` row-addressable results.
    static func preflightCompatibility(inputURLs: [URL]) async throws {
        let report = await AssetInspector.preflight(urls: inputURLs)
        guard report.canExport else {
            throw JoinExporterError.incompatible(report.formattedReasons)
        }
    }

    /// Atomically replace an existing destination, or move into place when absent.
    private static func installExport(from tempURL: URL, to outputURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: outputURL.path) {
            _ = try fm.replaceItemAt(outputURL, withItemAt: tempURL)
        } else {
            let parent = outputURL.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try fm.moveItem(at: tempURL, to: outputURL)
        }
    }

    private static func firstTrack(in tracks: [AVAssetTrack], mediaType: AVMediaType) throws -> AVAssetTrack {
        if let track = tracks.first(where: { $0.mediaType == mediaType }) {
            return track
        }
        throw JoinExporterError.exportFailed("Missing \(mediaType.rawValue) track")
    }

    private static func optionalTrack(in tracks: [AVAssetTrack], mediaType: AVMediaType) -> AVAssetTrack? {
        tracks.first(where: { $0.mediaType == mediaType })
    }
}
